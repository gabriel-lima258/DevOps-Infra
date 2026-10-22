# 6. Variáveis

Variáveis tiram valores fixos do código. Assim o mesmo código serve para outra faixa de IPs, outro nome ou outro ambiente sem editar os recursos.

## Onde ficam

No `variables.tofu`. O OpenTofu lê todos os `.tofu` da pasta juntos, então qualquer arquivo usa `var.*` sem import (ver [10-organizacao-dos-arquivos.md](10-organizacao-dos-arquivos.md)).

## Declarar (`variables.tofu`)

```hcl
variable "aws_region" {
  default = "us-east-1"
}

variable "environment" {
  description = "The environment for the S3 bucket (development, homolog, production)"
  type        = string
  default     = "development"
}

variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "172.25.0.0/16"
}

variable "vpc_name" {
  description = "The name of the VPC"
  type        = string
  default     = "algadelivery-vpc-devops"
}
```

> As variáveis `bucket_name` e `bucket_versioning` saíram junto com o S3. A *description* de `environment` ainda fala em "S3 bucket": vale atualizar.

| Argumento | Para que serve |
|-----------|----------------|
| `description` | Documenta a variável. Aparece no prompt e em ferramentas |
| `type` | Tipo esperado: `string`, `number`, `bool`, `list(string)`, `map(string)`, `object({...})` |
| `default` | Valor usado se ninguém passar outro. **Sem `default` a variável é obrigatória** |
| `validation` | Regra extra (ver abaixo) |
| `sensitive` | `true` esconde o valor no plan e nos logs (senhas, tokens) |

> A `aws_region` funciona sem `type` e `description`: o tipo vira `any` e é deduzido do valor. Mas é má prática, porque perde a documentação e a checagem de tipo. Prefira:
> ```hcl
> variable "aws_region" {
>   description = "AWS region for the provider and the state backend"
>   type        = string
>   default     = "us-east-1"
> }
> ```

## Usar (`networking.tofu`)

```hcl
resource "aws_vpc" "algadelivery" {
  cidr_block = var.vpc_cidr_block
  tags = {
    Name = var.vpc_name
  }
}
```

Também no provider e no backend:

```hcl
provider "aws" {
  region = var.aws_region
}
```

Usar variáveis **dentro do bloco `backend`** é exclusivo do OpenTofu ≥ 1.8. É assim que este projeto separa o state por ambiente (ver [09-backend-remoto-s3.md](09-backend-remoto-s3.md)).

Sintaxe: `var.<nome>`. Dentro de um texto, use interpolação: `"${var.vpc_name}-${var.environment}"`.

## Passar valores (do mais fraco para o mais forte)

Se o mesmo valor vier de vários lugares, **vence o último da lista**:

| # | Fonte | Exemplo |
|---|-------|---------|
| 1 | `default` na declaração | `default = "development"` |
| 2 | Variável de ambiente `TF_VAR_<nome>` | `export TF_VAR_environment=homolog` |
| 3 | Arquivo `terraform.tfvars` (carregado automaticamente) | `environment = "homolog"` |
| 4 | Arquivos `*.auto.tfvars` (automáticos, em ordem alfabética) | `dev.auto.tfvars` |
| 5 | Linha de comando: `-var` e `-var-file` | `tofu plan -var 'environment=production'` |

Sem `default` e sem valor em nenhuma fonte, o `plan`/`apply` **pergunta no terminal**.

### Exemplo: arquivo de valores por ambiente

`dev.tfvars`:
```hcl
environment    = "development"
vpc_cidr_block = "172.25.0.0/16"
vpc_name       = "algadelivery-vpc-development"
```

```bash
tofu plan -var-file=dev.tfvars
```

> Mesmo no OpenTofu, os arquivos de valores continuam com extensão `.tfvars`.

## Tipos complexos

Além de `string`, `number` e `bool`, uma variável pode agrupar valores. As subnets usam um **mapa de objetos**:

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

Acesso: `var.subnet_pub_config["public_a"].cidr_block` → `"172.25.1.0/24"`. Dentro de um `for_each`, `each.value.cidr_block`.

> A primeira versão era `list(object(...))`, acessada por índice (`var.subnet_pub_config[0]`). Trocou-se por mapa para usar `for_each` (ver [13-loops-for-each-e-for.md](13-loops-for-each-e-for.md)).

| Tipo | Exemplo de valor | Acesso |
|------|------------------|--------|
| `list(string)` | `["a", "b"]` | `var.x[0]` |
| `map(string)` | `{ a = "172.25.1.0/24" }` | `var.x["a"]` ou `var.x.a` |
| `object({...})` | `{ cidr_block = "...", name = "..." }` | `var.x.cidr_block` |
| `list(object({...}))` | lista de objetos (a 1ª versão) | `var.x[0].name` |
| `map(object({...}))` | objetos com chave (o caso atual) | `var.x["public_a"].name`; ideal para `for_each` |

O `type` faz o OpenTofu checar a estrutura: esquecer o campo `az` num item dá erro já no `plan`. Por que `map(object)` é melhor que `list(object)` para criar vários recursos: ver [13-loops-for-each-e-for.md](13-loops-for-each-e-for.md#por-que-mapa-e-não-lista).

## Validação

Hoje `vpc_cidr_block` aceita qualquer texto: um `"172.25.0.0"` sem o `/16` só daria erro na hora do apply, na AWS. Com `validation`, o erro aparece já no `plan`:

```hcl
variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "172.25.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "vpc_cidr_block deve ser um CIDR válido, ex.: 172.25.0.0/16."
  }
}
```

`can(...)` devolve `false` se a expressão der erro, e `cidrhost` dá erro com um CIDR inválido.

Outro exemplo, da fase do S3: aceitar só uma lista de valores.

```hcl
variable "bucket_versioning" {
  description = "The versioning status for the S3 bucket"
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Suspended", "Disabled"], var.bucket_versioning)
    error_message = "bucket_versioning deve ser Enabled, Suspended ou Disabled."
  }
}
```

## Pegadinhas

- **Mudar `vpc_cidr_block` recria a VPC** (`-/+`) e tudo dentro dela.
- (S3) **Mudar `bucket_name` recria o bucket** (`-/+`): o nome é imutável no S3. Com versionamento, o destroy do antigo falha se houver objetos.
- `TF_VAR_` diferencia maiúsculas: `TF_VAR_vpc_name`, não `TF_VAR_VPC_NAME`.
- `.tfvars` com segredos **não** vai para o git. Valores sem segredo (`dev.tfvars`) podem e devem ser versionados.
- Variável não pode referenciar outra variável no `default`. Para valores derivados, use `locals` (ver seção abaixo).
- Rode `tofu fmt`: ele padroniza a indentação e alinha os `=` (o código atual já passa no `tofu fmt -check`).

## `locals`: valores derivados

`variable` é **entrada** (quem roda o `tofu` pode mudar). `local` é um valor **calculado dentro do código**, que ninguém sobrescreve de fora. Serve para não repetir expressões.

No projeto, os locals ficam em `local.tofu`:

```hcl
locals {
  context_name = "algadelivery"
}
```

Uso: `local.context_name` (singular no uso, plural no bloco `locals`).

```hcl
Name = "${local.context_name}-pub-${each.value.az}"   # algadelivery-pub-a  (subnets)
Name = "${local.context_name}-igw"                    # algadelivery-igw    (internet gateway)
```

Um prefixo comum em todos os nomes, definido num lugar só. Para incluir o ambiente: `context_name = "algadelivery-${var.environment}"` → `algadelivery-development-pub-a`.

### Variáveis das EC2

```hcl
variable "instance_type" {
  description = "The type of instance to use"
  type        = string
  default     = "t3.micro"
}

variable "keypair_name" {
  type    = string
  default = "algadelivery-iac"
}

variable "ami_id" {
  description = "The ID of the AMI to use for the instance"
  type        = string
  default     = "ami-04680790a315cd58d"
}
```

- `instance_type` como variável: trocar o tamanho sem editar o recurso (`-var instance_type=t3.small`).
- `keypair_name` também define o nome do arquivo `.pem`.
- ⚠️ `ami_id` **não é usado**: as EC2 usam `data.aws_ami.ubuntu.id` ([doc 19](19-ec2-bastion-e-vm-privada.md)). Variável sem uso confunde quem lê; remova ou use como alternativa ao data source.

### Lista de objetos com padrão no local

As regras do SG do bastion usam um padrão útil: a **variável** começa vazia, e o **local** decide entre o que foi passado e os valores padrão:

```hcl
variable "bastion_ingress_rules" {
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}

locals {
  bastion_ingress_rules = length(var.bastion_ingress_rules) > 0 ? var.bastion_ingress_rules : [ /* regras padrão */ ]
}
```

Os padrões ficam no local porque usam `local.my_public_ip` e `aws_vpc.algadelivery.cidr_block`, e o `default` de variável só aceita valor fixo. Passar a variável **substitui** todos os padrões. Explicação completa em [20-dynamic-blocks.md](20-dynamic-blocks.md).

### Locals com functions e data sources

```hcl
locals {
  my_public_ip = "${trimspace(data.http.my_public_ip.response_body)}/32"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}
```

- `my_public_ip`: um local **pode** ler um data source e aplicar functions. Uma `variable` não pode: o `default` só aceita valor fixo.
- `common_tags`: um **mapa** reaproveitado em todos os recursos com `merge()`.

Explicação em [18-data-sources-e-functions.md](18-data-sources-e-functions.md).

### Constantes com nome

`local.tofu` também guarda valores fixos que aparecem em vários lugares, com um nome que explica o que são:

```hcl
locals {
  internet_cidr_block = "0.0.0.0/0"
}
```

Usado nas duas route tables (`cidr_block = local.internet_cidr_block`, doc 16). Ler `internet_cidr_block` é mais claro que `"0.0.0.0/0"`, e muda-se num lugar só.

### Variável `bool` + operador ternário

O projeto também usa um local para **traduzir** uma variável booleana no texto que a AWS espera:

```hcl
variable "ngw_regional_mode" {
  description = "The availability mode regional"
  type        = bool
  default     = true
}

locals {
  ngw_regional_mode = var.ngw_regional_mode ? "regional" : "zonal"
}
```

Operador ternário: `condição ? valor_se_true : valor_se_false`. Com `-var 'ngw_regional_mode=false'`, o local vira `"zonal"`. Quem usa o módulo pensa em "liga/desliga"; o detalhe da API fica escondido no local. Uso real em [15-subnets-privadas-e-nat-gateway.md](15-subnets-privadas-e-nat-gateway.md#zonal-x-regional).

Pegadinhas:
- Declarar é `locals { ... }`, referenciar é `local.nome`. Usar sem declarar dá `Reference to undeclared local value`.
- Pode referenciar variáveis, outros locals e atributos de recursos; só não pode haver ciclo.
- Diferente de variável, não aparece em `-var`, `.tfvars` nem `TF_VAR_`.
