# 13. Loops: `for_each`, `count` e expressões `for`

O HCL não tem `while` nem `for` como numa linguagem de programação. Para "repetir" existem duas ferramentas diferentes:

| Ferramenta | Onde se usa | Para que serve |
|------------|-------------|----------------|
| `for_each` / `count` | **Dentro de um `resource`** (ou `module`, `data`) | Criar **vários recursos** a partir de um bloco só |
| Expressão `for` | Em **qualquer valor** (output, local, argumento) | Transformar uma lista ou mapa em outra lista ou mapa |

Neste projeto, as duas aparecem juntas: `for_each` cria as subnets e `for` monta os outputs.

## Antes x depois

**Antes:** 3 blocos quase iguais e 6 outputs.

```hcl
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.algadelivery.id
  cidr_block        = var.subnet_pub_config[0].cidr_block
  availability_zone = "${var.aws_region}${var.subnet_pub_config[0].az}"
  tags = { Name = var.subnet_pub_config[0].name }
}
# ... public_b com [1], public_c com [2]
```

**Depois** (`networking.tofu`): 1 bloco.

```hcl
resource "aws_subnet" "public" {
  for_each          = var.subnet_pub_config
  vpc_id            = aws_vpc.algadelivery.id
  cidr_block        = each.value.cidr_block
  availability_zone = "${var.aws_region}${each.value.az}"

  tags = {
    Name = "${local.context_name}-pub-${each.value.az}"   # algadelivery-pub-a
  }
}
```

Com a variável virando um **mapa** (`variables.tofu`):

```hcl
variable "subnet_pub_config" {
  type = map(object({
    cidr_block = string
    az         = string
  }))
  default = {
    "public_a" = { cidr_block = "172.25.1.0/24", az = "a" }
    "public_b" = { cidr_block = "172.25.2.0/24", az = "b" }
    "public_c" = { cidr_block = "172.25.3.0/24", az = "c" }
  }
}
```

Nova subnet = **um item a mais no mapa**. Nenhum bloco ou output novo.

> O nome (tag `Name`) era um campo `name` do objeto; hoje é montado com `local.context_name` + AZ, então o mapa só precisa de `cidr_block` e `az`.

`for_each` também aceita **um mapa de recursos**. O projeto usa isso nas associations: `for_each = aws_subnet.public` cria uma associação de route table por subnet, com as mesmas chaves (`aws_route_table_association.public["public_a"]`…). Ver [16-route-tables.md](16-route-tables.md).

## `for_each` passo a passo

`for_each` recebe um **mapa** (ou um conjunto de strings) e cria **uma instância do recurso por item**. Dentro do bloco existe o objeto `each`:

| Expressão | Na 1ª volta | Na 2ª | Na 3ª |
|-----------|-------------|-------|-------|
| `each.key` | `"public_a"` | `"public_b"` | `"public_c"` |
| `each.value` | o objeto inteiro | … | … |
| `each.value.cidr_block` | `"172.25.1.0/24"` | `"172.25.2.0/24"` | `"172.25.3.0/24"` |
| `each.value.az` | `"a"` | `"b"` | `"c"` |

### O endereço muda: agora tem chave

```bash
$ tofu state list
aws_subnet.public["public_a"]
aws_subnet.public["public_b"]
aws_subnet.public["public_c"]
aws_vpc.algadelivery
```

- `aws_subnet.public` sozinho é um **mapa de recursos**, não um recurso.
- Para um item específico: `aws_subnet.public["public_a"].id`.
- No terminal, use aspas simples por causa dos colchetes e aspas duplas:
  ```bash
  tofu state show 'aws_subnet.public["public_a"]'
  tofu plan -target='aws_subnet.public["public_b"]'
  ```

### Por que mapa e não lista?

`for_each` **não aceita lista**. E isso é proposital: a chave (`"public_a"`) é a **identidade** de cada instância.

- Removeu a `public_b` do mapa? Só ela é destruída.
- Com uma lista e índices (`[0]`, `[1]`, `[2]`), remover o item do meio **desloca** os seguintes: o `[2]` vira `[1]` e o plan quer recriar subnets que não mudaram.

Se você tiver uma lista, dá para converter: `for_each = toset(["a", "b", "c"])`. Nesse caso `each.key` e `each.value` são iguais.

## `count`: a alternativa por número

```hcl
resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.algadelivery.id
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, count.index + 1)   # .1, .2, .3
  availability_zone = "${var.aws_region}${["a", "b", "c"][count.index]}"
}
```

- Endereços: `aws_subnet.public[0]`, `[1]`, `[2]`; dentro do bloco, `count.index`.

| | `for_each` | `count` |
|---|---|---|
| Recebe | mapa ou set | número |
| Identidade | chave (`["public_a"]`) | posição (`[0]`) |
| Remover um do meio | só ele sai | desloca os outros e recria |
| Bom para | itens com identidade (subnets, usuários, buckets) | N cópias idênticas ou **liga/desliga**: `count = var.criar_nat ? 1 : 0` |

Regra prática: **`for_each` por padrão**; `count` para "0 ou 1" (recurso opcional).

> Não dá para usar `count` e `for_each` no mesmo bloco.

## Expressões `for`: transformar coleções

Sintaxe parecida com *list comprehension* do Python:

```hcl
[for ITEM in COLEÇÃO : VALOR]               # gera uma LISTA
{for CHAVE, ITEM in COLEÇÃO : CHAVE => VALOR}  # gera um MAPA
[for ITEM in COLEÇÃO : VALOR if CONDIÇÃO]   # com filtro
```

### Os outputs atuais (`outputs.tofu`)

```hcl
output "subnet_public_id" {
  description = "The IDs of the public subnet "
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "subnet_public_arn" {
  description = "The ARNs of the public subnets"
  value       = [for subnet in aws_subnet.public : subnet.arn]
}
```

Lendo em voz alta: "para cada `subnet` em `aws_subnet.public`, pegue `subnet.id`, e devolva uma lista".

Saída real (account ID trocado por `123456789012`):

```bash
$ tofu output
subnet_public_arn = [
  "arn:aws:ec2:us-east-1:123456789012:subnet/subnet-0e01e77ec2f8b7351",
  "arn:aws:ec2:us-east-1:123456789012:subnet/subnet-091d4378f833c0cb5",
  "arn:aws:ec2:us-east-1:123456789012:subnet/subnet-03015cb81720e7f7c",
]
subnet_public_id = [
  "subnet-0e01e77ec2f8b7351",
  "subnet-091d4378f833c0cb5",
  "subnet-03015cb81720e7f7c",
]
vpc_arn = "arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0a768d2dbdfb3b9cb"
vpc_id = "vpc-0a768d2dbdfb3b9cb"
```

Ao percorrer um mapa, o `for` segue a **ordem alfabética das chaves**: `public_a`, `public_b`, `public_c`.

### Variações úteis

```hcl
# Mapa: chave → id (sabe-se qual ID é de qual subnet)
{ for k, subnet in aws_subnet.public : k => subnet.id }
# { "public_a" = "subnet-0e01...", "public_b" = "subnet-091d...", ... }

# Filtro: só as da AZ "a"
[for k, cfg in var.subnet_pub_config : k if cfg.az == "a"]
# ["public_a"]

# Splat: atalho para "pegue o atributo de todos"
values(aws_subnet.public)[*].id
# mesma lista do output subnet_public_id
```

> O splat `[*]` funciona direto em listas (recursos com `count`). Com `for_each` o recurso é um mapa, por isso o `values(...)` antes.

Teste tudo no `tofu console` (ele lê o state, então mostra os IDs reais):

```bash
$ tofu console
> [for s in aws_subnet.public : s.cidr_block]
> { for k, s in aws_subnet.public : k => s.availability_zone }
```

## Migrar sem recriar: blocos `moved`

Ao trocar `aws_subnet.public_a` por `aws_subnet.public["public_a"]`, o endereço muda. Para o OpenTofu é **outro recurso**: o plan mostraria 3 destroy e 3 create. Para só renomear no state:

```hcl
moved {
  from = aws_subnet.public_a
  to   = aws_subnet.public["public_a"]
}
# um bloco moved por subnet
```

O plan passa a mostrar `has moved to` em vez de `-/+`. Depois do apply os blocos `moved` podem ser removidos. Neste estudo não foi preciso, porque a VPC tinha sido destruída antes e tudo foi criado do zero. Na refatoração para **módulos** o `moved` passou a ser essencial: sem ele, o plan recriava a rede inteira (26 add / 27 destroy). Ver [21-modules.md](21-modules.md#refatorar-sem-destruir-blocos-moved).

## Para ir além

- Tipos de coleção (list, tuple, set, map, object), for aninhado, `merge([...]...)` e exercícios: [types_expression.md](types_expression.md).
- Esses conceitos aplicados ao módulo VPC (subnets em grupos): [22-modulo-vpc-grupos-de-subnets.md](22-modulo-vpc-grupos-de-subnets.md).

## Pegadinhas

- **Mudar a chave do mapa** (`public_a` → `pub_a`) = destruir e recriar aquela subnet. A chave é a identidade.
- O valor de `for_each` precisa ser **conhecido no plan**. Usar algo `(known after apply)`, como IDs de outros recursos, como chave dá `Invalid for_each argument`. Use valores de variáveis ou fixos.
- `each` só existe dentro do bloco que tem `for_each`. Fora dele, referencie `aws_subnet.public["public_a"]`.
- Hoje a AZ aparece duas vezes: na chave (`public_a`) e em `az = "a"`. Dá para enxugar usando a chave como AZ (`a = {...}` + `"${var.aws_region}${each.key}"`), ao custo de renomear os endereços.
- Output como **lista** perde a associação chave → valor. Se outra camada precisar do ID "da subnet da AZ b", um output como **mapa** (`{ for k, s in ... : k => s.id }`) é mais útil.
