# 04.04 — Tipos de Coleção e For Expressions no OpenTofu

> Material de apoio (anotações da aula 04.04). Os resultados dos exercícios foram conferidos no `tofu console` do projeto. A aplicação prática está em [22-modulo-vpc-grupos-de-subnets.md](22-modulo-vpc-grupos-de-subnets.md).

## Objetivo da aula

Entender os tipos de coleção `list`, `tuple`, `set`, `map` e `object` do OpenTofu/HCL e aprender a
transformar coleções com **for expressions**, base necessária para o próximo passo de
melhoria do módulo VPC.

---

## Tipos de coleção

### list

Sequência ordenada onde **todos os elementos têm o mesmo tipo**.

```hcl
variable "azs" {
  type    = list(string)
  default = ["a", "b", "c"]
}
```

- Acesso por índice: `var.azs[0]` → `"a"`
- Tamanho: `length(var.azs)` → `3`

---

### tuple

Sequência ordenada onde **cada posição pode ter um tipo diferente**.

```hcl
# declaração implícita — OpenTofu infere o tipo
["texto", 42, true]
```

No console:

```
> type(["texto", 42, true])
tuple([
    string,
    number,
    bool,
])
```

Não é declarada explicitamente em variáveis com frequência; aparece como resultado
intermediário de for expressions e ao trabalhar com `splat`. Todo `[for ...]` gera uma **tuple**:

```
> type([for az in ["a","b"] : az])
tuple([
    string,
    string,
])
```

Quando o valor entra numa variável `list(...)`, o OpenTofu converte a tuple em list automaticamente.

---

### set

Coleção **sem duplicados** e **sem índice**. Todos os elementos têm o mesmo tipo.

```
> toset(["b", "a", "b"])
toset([
  "a",
  "b",
])
```

- Remove repetidos e não tem `[0]`: para acessar, percorra com `for` ou converta com `tolist()`.
- É o que o `for_each` de recurso aceita quando os itens são strings simples (doc 13).

---

### map

Coleção de pares chave → valor onde todos os valores têm o mesmo tipo.

```hcl
variable "tags" {
  type = map(string)
  default = {
    Environment = "dev"
    Owner       = "algaworks"
  }
}
```

- Acesso por chave: `var.tags["Environment"]` → `"dev"`
- Chaves: `keys(var.tags)` → `["Environment", "Owner"]`
- Valores: `values(var.tags)` → `["dev", "algaworks"]`

> **Ordem:** um map não tem ordem "de inserção", mas o OpenTofu sempre percorre as chaves em **ordem alfabética**. Por isso `keys({ "y" = 2, "x" = 1 })` devolve `["x", "y"]`, e um `for` sobre um map é previsível. (Isso importa quando alguém usa `[0]` numa lista gerada a partir de um map.)

---

### object

Semelhante ao map, mas **cada chave pode ter um tipo diferente**. Usado para
estruturar objetos com campos nomeados.

```hcl
variable "subnet_config" {
  type = object({
    cidr_block = string
    az         = string
  })
  default = {
    cidr_block = "172.25.0.0/24"
    az         = "a"
  }
}
```

Com `type = object(...)`, **só existem os campos declarados**. Ler um campo que não está no tipo dá `Unsupported attribute` (aconteceu neste estudo, ver o CHANGELOG).

---

### Tipos aninhados

Os tipos se combinam. O módulo VPC usa um **mapa de mapas de objetos**:

```hcl
type = map(map(object({
  cidr_block = string
  az         = string
})))

# valor
{
  management = {
    "pvt_mgmt_a" = { cidr_block = "172.25.4.0/24", az = "a" }
  }
  cluster = {
    "pvt_cluster_a" = { cidr_block = "172.25.7.0/24", az = "a" }
  }
}
```

Lê-se de fora para dentro: **grupo** (`management`) → **subnet** (`pvt_mgmt_a`) → **campos** (`cidr_block`, `az`).

---

### Comparativo rápido

| Tipo    | Ordem                      | Tipos dos elementos  | Duplicados | Acesso        |
|---------|----------------------------|----------------------|------------|---------------|
| list    | sim (posição)              | todos iguais         | sim        | índice `[0]`  |
| tuple   | sim (posição)              | podem ser diferentes | sim        | índice `[0]`  |
| set     | não (sem índice)           | todos iguais         | **não**    | só percorrendo |
| map     | percorrido em ordem alfabética | todos iguais     | chaves únicas | chave `["k"]` |
| object  | percorrido em ordem alfabética | podem ser diferentes | campos únicos | `.campo` ou `["campo"]` |

Conversões: `tolist()`, `toset()`, `tomap()`, `tostring()`, `tonumber()`.

---

## For expressions

For expressions permitem **transformar** coleções sem precisar de loops imperativos.

### Produzindo uma tuple (lista)

```hcl
[for <valor> in <coleção> : <expressão>]

# exemplos
[for az in ["a", "b", "c"] : "us-east-1${az}"]
# => ["us-east-1a", "us-east-1b", "us-east-1c"]

[for k, v in { "x" = 1, "y" = 2 } : "${k}=${v}"]
# => ["x=1", "y=2"]
```

Sobre uma lista, a forma com dois nomes dá **índice e valor**: `[for i, az in ["a","b"] : "${i}-${az}"]` → `["0-a", "1-b"]`.

### Produzindo um mapa

```hcl
{for <chave>, <valor> in <coleção> : <nova_chave> => <novo_valor>}

# exemplos
{for k, v in { "a" = 1, "b" = 2 } : k => v * 10}
# => { "a" = 10, "b" = 20 }

{for idx, az in ["a", "b", "c"] : az => idx}
# => { "a" = 0, "b" = 1, "c" = 2 }
```

### Com filtro (cláusula `if`)

```hcl
[for v in [1, 2, 3, 4, 5] : v if v > 2]
# => [3, 4, 5]

{for k, v in { "a" = 1, "b" = 2, "c" = 3 } : k => v if v > 1}
# => { "b" = 2, "c" = 3 }
```

### Agrupando chaves repetidas (`...` depois do valor)

Num `{for ...}`, cada chave só pode aparecer uma vez. Com `...` depois do valor, as repetidas viram **lista**:

```
> {for k, v in {a=1, b=2} : "grupo" => v...}
{
  "grupo" = [
    1,
    2,
  ]
}
```

### For aninhado

Um `for` dentro de outro percorre estruturas aninhadas (como o `map(map(object))`):

```hcl
[for grupo, subnets in var.subnet_pvt_config : {
  for chave, subnet in subnets : chave => merge(subnet, { group = grupo })
}]
# => uma LISTA com um MAPA por grupo, cada subnet ganhando o campo "group"
```

---

## Juntando coleções: `merge`, `flatten` e o operador `...`

### `merge` — junta mapas

```
> merge({ a = 1 }, { b = 2 })
{ "a" = 1, "b" = 2 }

> merge({ x = 1 }, { x = 2 })      # chave repetida: o ÚLTIMO vence, sem erro
{ "x" = 2 }
```

### `flatten` — achata listas de listas

```
> flatten([[1, 2], [3]])
[1, 2, 3]
```

### `...` — expansão de argumentos

`merge` recebe **vários mapas como argumentos separados**, não uma lista. Quando você tem uma **lista de mapas** (resultado de um `for`), o `...` "espalha" a lista em argumentos:

```
> merge([{a=1},{b=2}]...)          # equivale a merge({a=1}, {b=2})
{ "a" = 1, "b" = 2 }
```

Sem o `...`, o `merge` receberia **um** argumento (a lista) e daria erro de tipo.

---

## Praticando no console

Abra o console na raiz do projeto (na aula: pasta `04.04-melhorando-modulo-vpc`; aqui: `devops/`):

```bash
cd devops
tofu console
```

### Exercícios — execute no console

Os resultados abaixo são as saídas reais do `tofu console` (formatados em uma linha).

```hcl
# 1. list simples
["a", "b", "c"]
# => ["a", "b", "c"]

# 2. acesso por índice
["a", "b", "c"][1]
# => "b"

# 3. map simples
{ "us-east-1a" = "172.25.0.0/24", "us-east-1b" = "172.25.1.0/24" }

# 4. keys e values (repare: ordem alfabética)
keys({ "y" = 2, "x" = 1 })
# => ["x", "y"]
values({ "y" = 2, "x" = 1 })
# => [1, 2]

# 5. for produzindo lista
[for az in ["a", "b", "c"] : "us-east-1${az}"]
# => ["us-east-1a", "us-east-1b", "us-east-1c"]

# 6. for produzindo mapa (index() devolve a posição: 0, 1, 2)
{for az in ["a", "b", "c"] : az => "172.25.${index(["a","b","c"], az)}.0/24"}
# => { "a" = "172.25.0.0/24", "b" = "172.25.1.0/24", "c" = "172.25.2.0/24" }

# 7. for com filtro
[for v in [1, 2, 3, 4, 5] : v if v % 2 == 0]
# => [2, 4]

# 8. for sobre mapa — invertendo chave e valor
{for k, v in { "mgmt" = "10.0.0.0/24", "cluster" = "10.0.1.0/24" } : v => k}
# => { "10.0.0.0/24" = "mgmt", "10.0.1.0/24" = "cluster" }

# 9. mapa de objetos (padrão que usaremos nas subnets)
{
  "pvt_mgmt_a" = { cidr_block = "172.25.4.0/24", az = "a" }
  "pvt_mgmt_b" = { cidr_block = "172.25.5.0/24", az = "b" }
}

# 10. for sobre mapa de objetos — extraindo só o cidr_block
{for k, v in {
  "pvt_mgmt_a" = { cidr_block = "172.25.4.0/24", az = "a" }
  "pvt_mgmt_b" = { cidr_block = "172.25.5.0/24", az = "b" }
} : k => v.cidr_block}
# => { "pvt_mgmt_a" = "172.25.4.0/24", "pvt_mgmt_b" = "172.25.5.0/24" }
```

### Exercícios extras (do módulo VPC)

```hcl
# 11. tipo de uma tuple
type(["texto", 42, true])
# => tuple([string, number, bool])

# 12. set remove duplicados e ordena
toset(["b", "a", "b"])
# => toset(["a", "b"])

# 13. merge com chave repetida (cuidado!)
merge({x=1}, {x=2})
# => { "x" = 2 }

# 14. expansão de uma lista de mapas
merge([{a=1}, {b=2}]...)
# => { "a" = 1, "b" = 2 }

# 15. os grupos de subnets privadas do projeto
keys(var.subnet_pvt_config)
# => ["cluster", "database", "management"]

# 16. o "achatamento" usado no módulo: só as chaves do resultado
keys(merge([for group_name, subnets in var.subnet_pvt_config : {
  for subnet_key, subnet in subnets : subnet_key => merge(subnet, { group = group_name })
}]...))
# => ["pvt_cluster_a", "pvt_cluster_b", "pvt_cluster_c", "pvt_db_a", "pvt_db_b", "pvt_db_c",
#     "pvt_mgmt_a", "pvt_mgmt_b", "pvt_mgmt_c"]
```

> Os `locals` de dentro do módulo (`local.subnet_pvt_config` do `modules/vpc`) **não** aparecem no console da raiz: o console só enxerga o root module. Por isso o exercício 16 repete a expressão usando `var.subnet_pvt_config` da raiz.

---

## Aplicando no módulo VPC deste projeto

Esses conceitos viraram código em `modules/vpc`: subnets agrupadas em `map(map(object))`, achatadas com `merge([for ... { for ... }]...)`, e outputs agrupados com `for` + `if`. Explicação passo a passo, migração do state e pegadinhas em [22-modulo-vpc-grupos-de-subnets.md](22-modulo-vpc-grupos-de-subnets.md).
