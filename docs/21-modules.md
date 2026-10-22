# 21. Modules: a rede virou um módulo

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

> **Atualização (2026-10-22):** os inputs de subnets viraram `subnet_pub_config` e `subnet_pvt_config` **agrupados** (`map(map(object))`), e as privadas viraram um único `aws_subnet.private`. Por isso o `moved.tofu` desta página **ficou desatualizado**: as chaves mudaram. Use o de [22-modulo-vpc-grupos-de-subnets.md](22-modulo-vpc-grupos-de-subnets.md#migração-do-state-moved-por-chave).

> 🔴 **Antes do próximo `apply`, leia a seção [Refatorar sem destruir](#refatorar-sem-destruir-blocos-moved).** Do jeito que está, o `plan` quer **destruir e recriar a rede inteira**.

## O que é um módulo

Um **módulo** é uma **pasta de `.tofu` que funciona como uma caixa**: entram valores (**inputs**), ela cria recursos e devolve valores (**outputs**). Parece uma função de programação:

```
             inputs (variable)                       outputs (output)
 vpc_cidr_block, subnets, tags...  ──►  [ modules/vpc ]  ──►  vpc_id, subnet_public_ids...
                                     cria VPC, subnets,
                                     IGW, NAT, rotas
```

| Termo | O que é no projeto |
|-------|--------------------|
| **Root module** (módulo raiz) | A pasta `devops/`, onde você roda `tofu plan`. Sempre existiu (doc 10) |
| **Child module** (módulo filho) | `modules/vpc/`, chamado pela raiz com um bloco `module` |
| **Chamada** | `module "vpc" { source = "./modules/vpc" ... }` em `vpc.tofu` |

Por que fazer isso: **organização** (a rede fica isolada num lugar), **reuso** (a mesma "caixa" cria a VPC de dev, homolog e prod) e um **contrato claro** (só entra e sai o que está declarado).

## A estrutura agora

```
devops/                      ← root module
├── vpc.tofu                 ← CHAMA o módulo (passa os inputs)
├── outputs.tofu             ← repassa outputs do módulo + outputs da raiz
├── security_group.tofu      ← usa module.vpc.vpc_id
├── ec2.tofu                 ← usa module.vpc.subnet_public_ids[0]
├── local.tofu, variables.tofu, data.tofu, providers.tofu
└── modules/
    └── vpc/                 ← child module
        ├── main.tofu        ← os recursos (VPC, subnets, IGW, NAT, rotas)
        ├── variables.tofu   ← os INPUTS
        ├── outputs.tofu     ← os OUTPUTS
        └── locals.tofu      ← internet_cidr_block
```

O `networking.tofu` sumiu: tudo dele está agora em `modules/vpc/main.tofu`.

## Inputs: como os valores entram

Cada `variable` do módulo vira um **argumento** do bloco `module`:

```hcl
# modules/vpc/variables.tofu          (a "assinatura" do módulo)
variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
}
```

```hcl
# vpc.tofu (raiz)                     (a "chamada", passando os valores)
module "vpc" {
  source = "./modules/vpc"

  aws_region                   = var.aws_region
  context_name                 = local.context_name
  vpc_cidr_block               = var.vpc_cidr_block
  vpc_name                     = "${local.context_name}-vpc"
  subnet_pub_config            = var.subnet_pub_config
  subnet_pvt_management_config = var.subnet_pvt_management_config
  subnet_pvt_cluster_config    = var.subnet_pvt_cluster_config
  ngw_regional_mode            = local.ngw_regional_mode
  common_tags                  = local.common_tags
}
```

| Input do módulo | Vem de (raiz) | Observação |
|-----------------|---------------|------------|
| `aws_region` | `var.aws_region` | Monta o nome da AZ (`us-east-1` + `a`) |
| `context_name` | `local.context_name` | Prefixo dos nomes (`algadelivery`) |
| `vpc_cidr_block` | `var.vpc_cidr_block` | `172.25.0.0/16` |
| `vpc_name` | `"${local.context_name}-vpc"` | ⚠️ Vira `algadelivery-vpc`; antes era `algadelivery-vpc-devops` (`var.vpc_name`, agora sem uso) |
| `subnet_*_config` | `var.subnet_*_config` | Os 3 mapas de subnets |
| `ngw_regional_mode` | `local.ngw_regional_mode` | A raiz traduz o `bool` em `"regional"`/`"zonal"`; o módulo recebe a **string** (`type = string`) |
| `common_tags` | `local.common_tags` | As tags comuns entram por input |

Regras dos inputs:

- **Sem `default` = obrigatório.** Todos os inputs do módulo vpc são obrigatórios: esquecer um na chamada dá `Missing required argument`.
- O **`type` valida** o que chega: passar um `bool` em `ngw_regional_mode` daria erro de tipo.
- O nome do argumento na chamada precisa ser **igual** ao nome da `variable` do módulo.

## Outputs: como os valores saem

Dentro do módulo, o `output` funciona como o `return` de uma função:

```hcl
# modules/vpc/outputs.tofu
output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}
```

Na raiz, o valor é lido como **`module.<nome>.<output>`**:

```hcl
# security_group.tofu
vpc_id = module.vpc.vpc_id

# ec2.tofu
subnet_id = module.vpc.subnet_public_ids[0]
```

### Para aparecer no `tofu output`, precisa repassar

O `tofu output` só mostra os outputs **do root module**. Os do módulo filho ficam "dentro da caixa". Por isso o `outputs.tofu` da raiz **repassa**:

```hcl
# outputs.tofu (raiz)
output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}
```

O caminho completo de um valor:

```
aws_vpc.main.id ──► output "vpc_id" (módulo) ──► module.vpc.vpc_id ──► output "vpc_id" (raiz) ──► tofu output
   recurso            sai da caixa               lido na raiz           sai do projeto
```

A raiz também ganhou outputs próprios (não vêm do módulo): `security_group_bastion_id`, `bastion_id`, `bastion_arn`, `bastion_public_ip` (do Elastic IP ✅) e `keypair_arn`.

## Escopo isolado: o módulo não enxerga a raiz

Dentro de `modules/vpc/`, **não existe** `var.environment`, `local.context_name` nem `local.common_tags` da raiz. O módulo só conhece **os próprios** `variable`, `local` e recursos. Consequências no código:

- As tags chegam por input: `merge(var.common_tags, {...})`, e não `local.common_tags`.
- O `internet_cidr_block = "0.0.0.0/0"` foi **declarado de novo** em `modules/vpc/locals.tofu`. Não é erro: é o isolamento.
- Da mesma forma, a raiz não enxerga `aws_vpc.main` diretamente; só os **outputs** do módulo.
- Exceção: o **provider `aws`** é herdado da raiz automaticamente. O módulo cria os recursos na mesma região e com as mesmas credenciais.

## Endereços novos no state

Os recursos do módulo ganham o prefixo `module.vpc.`, e o nome lógico mudou de `algadelivery` para `main`:

| Antes | Agora |
|-------|-------|
| `aws_vpc.algadelivery` | `module.vpc.aws_vpc.main` |
| `aws_subnet.public["public_a"]` | `module.vpc.aws_subnet.public["public_a"]` |
| `aws_internet_gateway.algadelivery` | `module.vpc.aws_internet_gateway.main` |
| `aws_nat_gateway.algadelivery` | `module.vpc.aws_nat_gateway.main` |
| `aws_route_table.private` | `module.vpc.aws_route_table.private` |

## `tofu init` com módulos

Adicionar um módulo (ou mudar o `source`) exige `tofu init`. Ele registra o módulo em `.terraform/modules/modules.json`:

```json
{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"vpc","Source":"./modules/vpc","Dir":"modules/vpc"}]}
```

Sem o init: `Error: Module not installed`.

## Refatorar sem destruir: blocos `moved`

### O problema (plan real)

Para o OpenTofu, endereço novo = **recurso novo**. Ele não sabe que `aws_vpc.algadelivery` e `module.vpc.aws_vpc.main` são a mesma VPC. O `plan` atual:

```
  # aws_vpc.algadelivery will be destroyed
  # (because aws_vpc.algadelivery is not in configuration)
  ...
  # module.vpc.aws_vpc.main will be created
  ...
  # aws_instance.bastion must be replaced
  # aws_security_group.bastion must be replaced
Plan: 26 to add, 0 to change, 27 to destroy.
```

Ou seja: apagar e recriar **VPC, 9 subnets, IGW, NAT, rotas**, e ainda **substituir o bastion e o SG** (eles dependem da VPC/subnet nova). IPs mudam, o NAT é recriado e tudo passa por um tempo fora do ar.

### A solução: avisar que só mudou o endereço

Crie um `moved.tofu` na raiz:

```hcl
moved {
  from = aws_vpc.algadelivery
  to   = module.vpc.aws_vpc.main
}
moved {
  from = aws_subnet.public
  to   = module.vpc.aws_subnet.public
}
moved {
  from = aws_subnet.private_management
  to   = module.vpc.aws_subnet.private_management
}
moved {
  from = aws_subnet.private_cluster
  to   = module.vpc.aws_subnet.private_cluster
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
moved {
  from = aws_route_table_association.public
  to   = module.vpc.aws_route_table_association.public
}
moved {
  from = aws_route_table_association.private_management
  to   = module.vpc.aws_route_table_association.private_management
}
moved {
  from = aws_route_table_association.private_cluster
  to   = module.vpc.aws_route_table_association.private_cluster
}
```

- Para recursos com `for_each`, um `moved` do **recurso inteiro** (sem `["chave"]`) leva todas as instâncias de uma vez.
- **Testado** numa cópia, com o state real baixado via `tofu state pull` (cópia apagada depois). O plan caiu de **26/0/27** para:

```
  # aws_vpc.algadelivery has moved to module.vpc.aws_vpc.main
  # aws_subnet.public["public_a"] has moved to module.vpc.aws_subnet.public["public_a"]
  ... (22 "has moved to")
  # module.vpc.aws_vpc.main will be updated in-place
      ~ "Name" = "algadelivery-vpc-devops" -> "algadelivery-vpc"
  # aws_security_group.bastion will be updated in-place
Plan: 2 to add, 2 to change, 2 to destroy.
```

O que sobra é **esperado**:

| Mudança | Motivo |
|---------|--------|
| + `aws_eip.bastion` | Elastic IP novo (doc 19) |
| + `local_sensitive_file` | Só na cópia de teste (o `.pem` não estava lá); no projeto real não deve aparecer |
| ~ `module.vpc.aws_vpc.main` | Só a tag `Name` (`algadelivery-vpc-devops` → `algadelivery-vpc`) |
| ~ `aws_security_group.bastion` | Regras novas via dynamic blocks (doc 20) |
| − `aws_instance.vm_private`, `aws_security_group.vm_private` | Saíram do código (doc 19) |

E a rota privada **não aparece mais**: o módulo usa `nat_gateway_id`, e o diff permanente do doc 16 acabou ✅.

Depois do apply, os blocos `moved` podem ficar (documentam a história) ou ser removidos.

**Alternativa por comando** (altera o state na hora, sem passar pelo plan):

```bash
tofu state mv 'aws_vpc.algadelivery' 'module.vpc.aws_vpc.main'
tofu state mv 'aws_subnet.public' 'module.vpc.aws_subnet.public'
# ... um por recurso
```

O `moved` é preferível: fica no código, passa por revisão e mostra o resultado no `plan` antes de aplicar.

## Melhorias sugeridas

1. **Nomes de outputs consistentes.** Na raiz há `subnet_public_ids` e `subnet_public_arn` (sem s), `subnet_pvt_mgmt_ids` e `subnet_pvt_cluster_id` (singular). Escolha um padrão (plural para listas) e use em todos.
2. **`subnet_public_ids[0]` é frágil.** A lista segue a ordem alfabética das chaves (`public_a` primeiro). Se alguém adicionar `"public_0"`, o bastion muda de subnet e é recriado. Um output em **mapa** deixa explícito (testado com `validate`):
   ```hcl
   # modules/vpc/outputs.tofu
   output "subnet_public_ids_by_key" {
     description = "IDs das subnets publicas, por chave"
     value       = { for k, s in aws_subnet.public : k => s.id }
   }

   # ec2.tofu
   subnet_id = module.vpc.subnet_public_ids_by_key["public_a"]
   ```
3. **`var.vpc_name` da raiz ficou sem uso** (assim como `var.ami_id`). Ou passe `vpc_name = var.vpc_name` para manter a tag antiga, ou remova a variável.
4. **`description` em todos os inputs** (`aws_region` e `context_name` estão sem). Num módulo, a `description` é a documentação para quem vai usá-lo.
5. **Defaults para inputs opcionais**, ex.: `ngw_regional_mode` com `default = "regional"` e `validation` (`contains(["regional","zonal"], ...)`).
6. **`versions.tofu` no módulo** com `required_providers { aws = { source = "hashicorp/aws", version = "~> 6.0" } }`: declara do que o módulo precisa.
7. **`tofu fmt -recursive`**: o `modules/vpc/variables.tofu` está fora do padrão. O `tofu fmt` sem `-recursive` **não entra** em subpastas.

## Reuso: o mesmo módulo, outros lugares

> **Na prática:** o projeto já reusa um módulo. `modules/ec2` é chamado duas vezes (`module.bastion` e `module.rancher`), e cada chamada cria seus próprios recursos. Ver [23-modulo-ec2.md](23-modulo-ec2.md), inclusive o cuidado com **nomes únicos** por chamada.

```hcl
# Dois ambientes no mesmo projeto (exemplo)
module "vpc_homolog" {
  source         = "./modules/vpc"
  vpc_cidr_block = "172.26.0.0/16"
  # ...
}

# Módulo vindo de um repositório git, travado numa versão
module "vpc" {
  source = "git::https://github.com/sua-org/tofu-modules.git//vpc?ref=v1.2.0"
  # ...
}

# Módulo público do registry
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  # ...
}
```

Também dá para usar `for_each` e `count` direto no bloco `module` (um módulo por ambiente, por exemplo).

## Pegadinhas

- **Output do módulo não aparece no `tofu output`** se a raiz não repassar.
- **Endereço mudou = destruir e recriar**, a menos que exista `moved` (ou `tofu state mv`). Sempre leia o `plan` depois de refatorar.
- **Mudou o `source`? `tofu init`.** O init também precisa rodar quando um módulo novo é adicionado.
- **`depends_on` num bloco `module`** faz **todos** os recursos do módulo esperarem. Prefira referências a outputs.
- **O módulo não vê a raiz:** usar `local.common_tags` dentro do módulo dá `Reference to undeclared local value`.
- `tofu state list` agora mostra `module.vpc.aws_vpc.main`; nos comandos, use o endereço completo entre aspas simples: `tofu state show 'module.vpc.aws_subnet.public["public_a"]'`.
