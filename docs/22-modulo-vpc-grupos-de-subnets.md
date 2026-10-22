# 22. Módulo VPC com grupos de subnets (coleções e expressions na prática)

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Teoria dos tipos e for expressions: [types_expression.md](types_expression.md)

> 🔴 **Antes do próximo `apply`, leia [Migração do state](#migração-do-state-moved-por-chave).** Sem blocos `moved`, o `plan` atual quer **destruir 27 e criar 32** recursos.

## O porquê da mudança

Antes, cada grupo de subnets tinha **sua própria variável, seu próprio recurso e seus próprios outputs** (`subnet_pvt_management_config` + `aws_subnet.private_management` + `subnet_pvt_mgmt_ids`…). Um grupo novo exigiria mexer em 4 arquivos.

Agora os grupos são **dados**, não código. Para criar o grupo `database`, bastou acrescentar um bloco na variável:

```hcl
database = {
  "pvt_db_a" = { cidr_block = "172.25.10.0/24", az = "a" },
  "pvt_db_b" = { cidr_block = "172.25.11.0/24", az = "b" },
  "pvt_db_c" = { cidr_block = "172.25.12.0/24", az = "c" }
}
```

Nenhum recurso, variável ou output novo no módulo.

## 1. A variável: mapa de grupos de subnets

**Antes** (dois mapas separados, um por grupo):

```hcl
variable "subnet_pvt_management_config" {
  type = map(object({ cidr_block = string, az = string }))
}
variable "subnet_pvt_cluster_config" {
  type = map(object({ cidr_block = string, az = string }))
}
```

**Agora** (`variables.tofu` da raiz e do módulo):

```hcl
variable "subnet_pvt_config" {
  description = "Configuration for private subnets grouped by name (e.g. management, cluster)"
  type = map(map(object({
    cidr_block = string
    az         = string
  })))
  default = {
    management = {
      "pvt_mgmt_a" = { cidr_block = "172.25.4.0/24", az = "a" },
      "pvt_mgmt_b" = { cidr_block = "172.25.5.0/24", az = "b" },
      "pvt_mgmt_c" = { cidr_block = "172.25.6.0/24", az = "c" }
    },
    cluster = {
      "pvt_cluster_a" = { cidr_block = "172.25.7.0/24", az = "a" },
      # ...
    },
    database = {
      "pvt_db_a" = { cidr_block = "172.25.10.0/24", az = "a" },
      # ...
    }
  }
}
```

`map(map(object))` se lê de fora para dentro: **grupo → subnet → campos**. O `subnet_pub_config` segue o mesmo formato, com um grupo só (`public` = `pub_a/b/c`).

## 2. O "achatamento" (`modules/vpc/locals.tofu`)

O `for_each` de um recurso precisa de **um mapa plano**: uma chave por subnet. Mas a variável tem dois níveis. O local faz a conversão:

```hcl
subnet_pvt_config = merge([
  for group_name, subnets in var.subnet_pvt_config : {
    for subnet_key, subnet in subnets : subnet_key => merge(subnet, { group = group_name })
  }
]...)
```

Passo a passo, com as saídas reais do `tofu console`:

**Passo 1, o `for` de fora** percorre os grupos (`cluster`, `database`, `management`, em ordem alfabética) e gera **uma lista com um mapa por grupo**.

**Passo 2, o `for` de dentro** percorre as subnets do grupo e acrescenta o campo `group` com `merge(subnet, { group = group_name })`. O primeiro mapa da lista (grupo `cluster`):

```
{
  "pvt_cluster_a" = { "az" = "a", "cidr_block" = "172.25.7.0/24", "group" = "cluster" }
  "pvt_cluster_b" = { "az" = "b", "cidr_block" = "172.25.8.0/24", "group" = "cluster" }
  "pvt_cluster_c" = { "az" = "c", "cidr_block" = "172.25.9.0/24", "group" = "cluster" }
}
```

**Passo 3, `merge([...]...)`:** o `...` espalha a lista de mapas como argumentos do `merge`, que junta tudo num mapa só. As chaves finais:

```
["pvt_cluster_a", "pvt_cluster_b", "pvt_cluster_c",
 "pvt_db_a", "pvt_db_b", "pvt_db_c",
 "pvt_mgmt_a", "pvt_mgmt_b", "pvt_mgmt_c"]
```

E cada item sabe de qual grupo veio:

```
> ...["pvt_db_a"]
{ "az" = "a", "cidr_block" = "172.25.10.0/24", "group" = "database" }
```

> Por que guardar o `group`? Porque, depois de achatar, o nome do grupo "sumiria". Ele é usado nas tags e nos outputs.

## 3. Um recurso para todas as privadas (`modules/vpc/main.tofu`)

```hcl
resource "aws_subnet" "private" {
  for_each          = local.subnet_pvt_config
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr_block
  availability_zone = "${var.aws_region}${each.value.az}"

  tags = merge(var.common_tags, {
    Name = "${var.context_name}-pvt-${each.value.group}-${each.value.az}"
  })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
```

- `aws_subnet.private_management` e `aws_subnet.private_cluster` viraram **um** `aws_subnet.private` com 9 instâncias (`["pvt_mgmt_a"]`…`["pvt_db_c"]`). O mesmo vale para as associations.
- O `Name` agora usa o grupo: `algadelivery-pvt-management-a`, `algadelivery-pvt-cluster-a`, `algadelivery-pvt-database-a`, e nas públicas `algadelivery-pub-public-a`.
- Todas as privadas usam a mesma route table (→ NAT), inclusive o grupo database. Se no futuro o banco **não** puder sair para a internet, ele precisará de uma route table própria, sem rota para o NAT.

## 4. Outputs agrupados (`modules/vpc/outputs.tofu`)

```hcl
output "subnet_pvt_ids" {
  value = {
    for group_name in keys(var.subnet_pvt_config) :
    group_name => [
      for k, subnet in aws_subnet.private : subnet.id
      if local.subnet_pvt_config[k].group == group_name
    ]
  }
}
```

Lendo em voz alta: "para cada grupo, monte uma lista com os IDs das subnets **cujo `group` é esse grupo**". Resultado (formato):

```
{
  "cluster"    = ["subnet-…", "subnet-…", "subnet-…"]
  "database"   = ["subnet-…", "subnet-…", "subnet-…"]
  "management" = ["subnet-…", "subnet-…", "subnet-…"]
}
```

Na raiz, lê-se por grupo:

```hcl
module.vpc.subnet_pvt_ids["management"]     # lista dos 3 IDs de management
module.vpc.subnet_pub_ids["public"][0]      # o ID usado pelo bastion (pub_a)
```

Técnicas usadas: `for` produzindo **mapa** (de fora), `for` produzindo **lista** (de dentro), filtro `if` e `keys()` (ver [types_expression.md](types_expression.md)).

## Migração do state (`moved` por chave)

### O problema

O state ainda tem a versão de antes dos módulos (`aws_subnet.private_management["private_a"]`…). Agora mudaram **três coisas ao mesmo tempo**: o módulo (`module.vpc.`), o **nome do recurso** (`private_management` → `private`) e a **chave** (`private_a` → `pvt_mgmt_a`). O plan atual:

```
Plan: 32 to add, 0 to change, 27 to destroy.
```

O `moved.tofu` do doc 21 movia o recurso inteiro e não serve mais: as chaves mudaram, então é preciso **um `moved` por chave**.

### O mapeamento

| Antes | Depois |
|-------|--------|
| `aws_vpc.algadelivery` | `module.vpc.aws_vpc.main` |
| `aws_internet_gateway.algadelivery` | `module.vpc.aws_internet_gateway.main` |
| `aws_nat_gateway.algadelivery` | `module.vpc.aws_nat_gateway.main` |
| `aws_route_table.public` / `.private` | `module.vpc.aws_route_table.public` / `.private` |
| `aws_subnet.public["public_a"]` | `module.vpc.aws_subnet.public["pub_a"]` |
| `aws_subnet.private_management["private_a"]` | `module.vpc.aws_subnet.private["pvt_mgmt_a"]` |
| `aws_subnet.private_cluster["private_a"]` | `module.vpc.aws_subnet.private["pvt_cluster_a"]` |
| `aws_route_table_association.public["public_a"]` | `module.vpc.aws_route_table_association.public["pub_a"]` |
| `aws_route_table_association.private_management["private_a"]` | `module.vpc.aws_route_table_association.private["pvt_mgmt_a"]` |
| `aws_route_table_association.private_cluster["private_a"]` | `module.vpc.aws_route_table_association.private["pvt_cluster_a"]` |

(… e o mesmo para `b` e `c`.)

### O `moved.tofu` (23 blocos)

```hcl
moved {
  from = aws_vpc.algadelivery
  to   = module.vpc.aws_vpc.main
}
moved {
  from = aws_internet_gateway.algadelivery
  to   = module.vpc.aws_internet_gateway.main
}
moved {
  from = aws_nat_gateway.algadelivery
  to   = module.vpc.aws_nat_gateway.main
}
moved {
  from = aws_route_table.public
  to   = module.vpc.aws_route_table.public
}
moved {
  from = aws_route_table.private
  to   = module.vpc.aws_route_table.private
}

# públicas
moved {
  from = aws_subnet.public["public_a"]
  to   = module.vpc.aws_subnet.public["pub_a"]
}
moved {
  from = aws_route_table_association.public["public_a"]
  to   = module.vpc.aws_route_table_association.public["pub_a"]
}
# ... repetir para public_b → pub_b e public_c → pub_c

# privadas: management
moved {
  from = aws_subnet.private_management["private_a"]
  to   = module.vpc.aws_subnet.private["pvt_mgmt_a"]
}
moved {
  from = aws_route_table_association.private_management["private_a"]
  to   = module.vpc.aws_route_table_association.private["pvt_mgmt_a"]
}
# ... repetir para b e c

# privadas: cluster
moved {
  from = aws_subnet.private_cluster["private_a"]
  to   = module.vpc.aws_subnet.private["pvt_cluster_a"]
}
moved {
  from = aws_route_table_association.private_cluster["private_a"]
  to   = module.vpc.aws_route_table_association.private["pvt_cluster_a"]
}
# ... repetir para b e c
```

> Os blocos `moved` **não aceitam `for_each`**: cada um é escrito à mão (ou gerado por um script).

### O resultado (testado)

Numa cópia do projeto com o state real (baixado com `tofu state pull` e apagado depois), o plan caiu de **32/27** para:

```
Plan: 8 to add, 8 to change, 3 to destroy.
```

| Mudança | Qtd | Motivo |
|---------|-----|--------|
| + subnets e associations do grupo `database` | 6 | Grupo novo, esperado |
| + `aws_eip.bastion` | 1 | Elastic IP (doc 19) |
| + `aws_instance.bastion` (substituição) | 1 | ⚠️ Ver abaixo |
| ~ tags `Name` | 7 | `algadelivery-pub-a` → `algadelivery-pub-public-a`, `algadelivery-pvt-mgmt-a` → `algadelivery-pvt-management-a`, VPC `algadelivery-vpc-devops` → `algadelivery-vpc`. As do cluster continuam iguais |
| ~ `aws_security_group.bastion` | 1 | Regras via dynamic blocks (doc 20) |
| − `aws_instance.bastion` (substituição), `vm_private` EC2 e SG | 3 | A VM privada saiu do código (doc 19) |

### ⚠️ O bastion vai ser substituído por causa da AMI

No plan de teste:

```
  # aws_instance.bastion must be replaced
      ~ ami = "ami-09db1e291cef3f1ef" -> "ami-033ea4ff4a9c726dc" # forces replacement
```

É exatamente o risco descrito no doc 19: o `data "aws_ami"` com `most_recent = true` achou um build novo do Ubuntu, e trocar a AMI **recria** a instância. Isso não tem relação com o módulo. Para evitar:

```hcl
resource "aws_instance" "bastion" {
  # ...
  lifecycle {
    ignore_changes = [ami]
  }
}
```

## Pegadinhas e melhorias

1. **Chaves repetidas entre grupos se sobrescrevem em silêncio.** O `merge` mantém a **última**: se `management` e `cluster` tiverem uma chave `"pvt_a"`, só uma subnet é criada, sem nenhum erro. Uma `validation` no módulo impede isso (testada: com chaves duplicadas, o plan falha com `Invalid value for variable`):
   ```hcl
   variable "subnet_pvt_config" {
     # ... type ...
     validation {
       condition = (
         length(flatten([for g in var.subnet_pvt_config : keys(g)])) ==
         length(distinct(flatten([for g in var.subnet_pvt_config : keys(g)])))
       )
       error_message = "As chaves das subnets privadas precisam ser unicas entre todos os grupos."
     }
   }
   ```
2. **O grupo `database` não aparece nos outputs da raiz.** O `outputs.tofu` repassa só `["public"]`, `["management"]` e `["cluster"]`. Opções: repassar o mapa inteiro (`value = module.vpc.subnet_pvt_ids`), que já inclui os grupos futuros, ou criar `subnet_pvt_db_ids`.
3. **Descriptions erradas no módulo:** `subnet_pvt_ids` e `subnet_pvt_arns` dizem "private management subnets", mas trazem todos os grupos.
4. **`subnet_pub_ids["public"][0]` depende da ordem** (alfabética: `pub_a` primeiro). Um output por chave (`{ for k, s in aws_subnet.public : k => s.id }`) permitiria `["pub_a"]` explícito (doc 21).
5. **Nomes de outputs na raiz** continuam misturados (`subnet_public_arn`, `subnet_pvt_cluster_id`…), e `var.vpc_name` continua sem uso (a chamada usa `"${local.context_name}-vpc"`).
6. **Chaves das públicas mudaram** (`public_a` → `pub_a`): qualquer referência antiga por chave precisa ser atualizada.

## Resumo das técnicas usadas

| Técnica | Onde | Doc |
|---------|------|-----|
| `map(map(object))` | Variáveis de subnets | [types_expression.md](types_expression.md#tipos-aninhados) |
| `for` aninhado | Local de achatamento | [types_expression.md](types_expression.md#for-aninhado) |
| `merge(subnet, { group = ... })` | Acrescentar o campo `group` | 18 |
| `merge([...]...)` (expansão) | Juntar os mapas por grupo | [types_expression.md](types_expression.md#juntando-coleções-merge-flatten-e-o-operador-) |
| `for` → mapa + `for` → lista + `if` | Outputs agrupados | 13 |
| `for_each` sobre mapa de recursos | Associations | 13 |
| `moved` por chave | Migração do state | 21 |
