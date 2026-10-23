# 23. Módulo EC2: uma "receita de servidor" reutilizável

> **Atualização (ambientes):** a migração com blocos `moved` descrita aqui **não foi necessária na prática**. Com a reorganização em `envs/` (doc 24), o ambiente dev foi criado do zero num state novo (`algadelivery/development/remote.tfstate`), e a AWS foi conferida sem recursos órfãos do código antigo. O conteúdo continua válido como conceito, para quando a infraestrutura não puder ser recriada.

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Módulos (inputs/outputs): [21-modules.md](21-modules.md)

> **Atualização (ambientes):** em `envs/dev` e `envs/prod`, o `module "rancher"` está **comentado**, e o `keypair_name` agora leva o prefixo do ambiente no dev. Ver [24-multiplos-ambientes.md](24-multiplos-ambientes.md).

> 🔴 (histórico) **Antes do próximo `apply`, leia [Migração do state](#migração-do-state).** Sem blocos `moved`, o `plan` atual quer **destruir 30 e criar 41** recursos.

## Por que um módulo de EC2

Até aqui, o bastion era um conjunto de recursos soltos na raiz: chave, key pair, arquivo `.pem`, Security Group, instância e Elastic IP. Para criar um **segundo** servidor (o `rancher`), seria preciso copiar e colar tudo, trocando nomes.

Com o módulo `modules/ec2`, o servidor vira uma **receita**: cada chamada `module "..."` cria um servidor completo.

```
module "bastion"  ─┐                         ┌─► chave + key pair + .pem
                   ├─► [ modules/ec2 ] ──────┼─► Security Group (regras dinâmicas)
module "rancher"  ─┘                         ├─► EC2
                                             └─► Elastic IP (opcional)
```

## Estrutura

```
devops/
├── ec2.tofu                    ← chama o módulo 2x: bastion e rancher
├── local.tofu                  ← configs de SG (bastion e rancher)
├── outputs.tofu                ← repassa module.bastion.*
└── modules/
    └── ec2/
        ├── main.tofu           ← chave, key pair, .pem, EIP, instância
        ├── security_group.tofu ← SG com dynamic blocks
        ├── variables.tofu      ← INPUTS
        └── outputs.tofu        ← OUTPUTS
```

O `security_group.tofu` da raiz **saiu**: o SG agora nasce dentro do módulo, junto com a instância que ele protege.

## O que entra e o que sai

### Inputs (`modules/ec2/variables.tofu`)

| Input | Tipo | Obrigatório? | Para que serve |
|-------|------|--------------|----------------|
| `name` | `string` | sim | Nome da instância (tag `Name`) |
| `ami_id` | `string` | sim | Sistema operacional (a raiz passa `data.aws_ami.ubuntu.id`) |
| `instance_type` | `string` | não (`t3.micro`) | Tamanho |
| `keypair_name` | `string` | sim | Nome do key pair **e** do arquivo `.pem` |
| `subnet_id` | `string` | sim | Onde a instância mora |
| `vpc_id` | `string` | sim | VPC do Security Group |
| `security_group_config` | `object` | sim | Nome, descrição e listas de regras do SG |
| `enabled_eip` | `bool` | não (`true`) | Liga/desliga o Elastic IP |
| `common_tags` | `map(string)` | sim | Tags comuns |

### Outputs (`modules/ec2/outputs.tofu`)

| Output | Valor |
|--------|-------|
| `id`, `arn` | Da instância |
| `public_ip` | IP do Elastic IP se `enabled_eip = true`; senão, o IP público automático da instância |
| `keypair_arn` | Do key pair |
| `security_group_id` | Do SG criado pelo módulo |

Na raiz, `outputs.tofu` repassa os do bastion (`module.bastion.id`, `module.bastion.public_ip`…), como no doc 21.

## O código explicado

### 1. O Security Group entra como um `object`

```hcl
variable "security_group_config" {
  type = object({
    name        = string
    description = string
    ingress_rules = list(object({
      description = string
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = list(string)
    }))
    egress_rules = list(object({ ... mesmos campos ... }))
  })
}
```

Um único input carrega **tudo** sobre o SG. Dentro do módulo, as regras viram blocos com `dynamic` (doc 20):

```hcl
resource "aws_security_group" "main" {
  name        = var.security_group_config.name
  description = var.security_group_config.description
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.security_group_config.ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      # ...
    }
  }
  # dynamic "egress" igual, com egress_rules
}
```

### 2. Padrão na raiz: `default = null` + ternário

```hcl
# variables.tofu (raiz)
variable "bastion_security_group_config" {
  type    = object({ ... })
  default = null
}

# local.tofu
bastion_security_group_config = var.bastion_security_group_config != null ? var.bastion_security_group_config : {
  name        = "bastion-sg"
  description = "Security group for bastion host"
  ingress_rules = [ ... SSH do seu IP, 80/443 da VPC ... ]
  egress_rules  = [ ... saída liberada ... ]
}
```

- `default = null` quer dizer "ninguém passou nada".
- O ternário escolhe: o que foi passado **ou** o padrão. É a mesma ideia do `length(...) > 0` do doc 20, agora para um objeto inteiro.
- O padrão fica no `local` porque usa `local.my_public_ip` (data source) e `var.vpc_cidr_block`.

### 3. O rancher reaproveita as regras, com nome próprio

```hcl
# o rancher reaproveita as regras do bastion, com nome proprio
# (nome de security group precisa ser unico dentro da VPC)
rancher_security_group_config = merge(local.bastion_security_group_config, {
  name        = "rancher-sg"
  description = "Security group for rancher host"
})
```

`merge` com objetos: o segundo **sobrescreve** `name` e `description` e mantém as listas de regras (doc 18).

### 4. `count` como liga/desliga do Elastic IP

```hcl
resource "aws_eip" "main" {
  count    = var.enabled_eip ? 1 : 0
  instance = aws_instance.main.id
  domain   = "vpc"
}
```

- `count = 1` cria; `count = 0` não cria nada. É o uso clássico de `count` (doc 13).
- Com `count`, o endereço ganha índice: `module.bastion.aws_eip.main[0]`.
- Por isso o output precisa de cuidado: `aws_eip.main[0]` **não existe** quando `enabled_eip = false`. O output usa um ternário:
  ```hcl
  value = var.enabled_eip ? aws_eip.main[0].public_ip : aws_instance.main.public_ip
  ```

### 5. `path.root` x `path.module`

```hcl
filename = "${path.root}/${var.keypair_name}.pem"
```

| | Aponta para | `.pem` iria para |
|---|---|---|
| `path.root` | a pasta onde você roda o `tofu` (raiz) | `./algadelivery-bastion.pem` ✅ |
| `path.module` | a pasta **do módulo** | `./modules/ec2/algadelivery-bastion.pem` |

Dentro de módulo, `path.root` é o certo para arquivos que o usuário vai usar. (Na raiz, os dois são iguais; por isso o código antigo usava `path.module`.)

### 6. A chamada na raiz (`ec2.tofu`)

```hcl
module "bastion" {
  source = "./modules/ec2"

  name                  = "bastion"
  ami_id                = data.aws_ami.ubuntu.id
  vpc_id                = module.vpc.vpc_id
  common_tags           = local.common_tags
  instance_type         = var.instance_type
  keypair_name          = var.keypair_name                   # "algadelivery-bastion"
  enabled_eip           = true
  subnet_id             = module.vpc.subnet_pub_ids["public"][0]
  security_group_config = local.bastion_security_group_config
}

module "rancher" {
  source = "./modules/ec2"

  name                  = "rancher"
  # ...
  keypair_name          = "${local.context_name}-rancher"    # "algadelivery-rancher"
  security_group_config = local.rancher_security_group_config
}
```

Repare: **um módulo, duas chamadas.** O `init` registra cada chamada em `.terraform/modules/modules.json` (`bastion` e `rancher`, ambos com `Source: ./modules/ec2`). Um output do módulo vira um valor por chamada: `module.bastion.public_ip`, `module.rancher.public_ip`.

Os módulos se conectam pelos outputs: `module.vpc.vpc_id` e `module.vpc.subnet_pub_ids` (doc 22) entram como inputs do módulo `ec2`.

## 🔴 Validação: os conflitos (corrigidos)

O código original passava no `tofu validate` e no `tofu plan`, mas **o apply falharia**: as duas chamadas tinham argumentos **idênticos**. O plan mostrava:

```
      + key_name = "algadelivery-bastion"        # bastion
      + name     = "bastion-sg"
      + filename = "./algadelivery-bastion.pem"
      + key_name = "algadelivery-bastion"        # rancher (igual!)
      + name     = "bastion-sg"                  # (igual!)
      + filename = "./algadelivery-bastion.pem"  # (igual!)
```

| Conflito | O que aconteceria |
|----------|-------------------|
| Mesmo key pair `algadelivery-bastion` | `InvalidKeyPair.Duplicate`: o 2º falha |
| Mesmo SG `bastion-sg` na mesma VPC | `InvalidGroup.Duplicate`: o 2º falha |
| Mesmo arquivo `./algadelivery-bastion.pem` | Os dois `local_sensitive_file` gravando chaves **diferentes** no mesmo arquivo: um apaga o outro |
| Mesma tag `Name = "bastion"` | Não quebra, mas confunde no console |

> **Lição:** `validate` e `plan` não consultam a AWS sobre nomes únicos. Conflito de nome só aparece no **apply**. Ao chamar um módulo várias vezes, tudo que é "nome" precisa vir de um input diferente por chamada.

**Correções aplicadas no código:**

| Arquivo | Mudança |
|---------|---------|
| `ec2.tofu` | `module "rancher"`: `name = "rancher"`, `keypair_name = "${local.context_name}-rancher"`, `security_group_config = local.rancher_security_group_config` |
| `local.tofu` | Novo `rancher_security_group_config` (merge com `name = "rancher-sg"`) |
| `ec2.tofu` | `subnet_pub_ids["public"]["0"]` → `["public"][0]` (a string `"0"` funcionava por conversão automática, mas o índice numérico é o idiomático) |
| `modules/ec2/outputs.tofu` | `public_ip` com ternário (não quebra com `enabled_eip = false`) + `tofu fmt` |

Plan depois da correção, cada um com seu nome:

```
      + key_name = "algadelivery-bastion"   · name = "bastion-sg"   · filename = "./algadelivery-bastion.pem"
      + key_name = "algadelivery-rancher"   · name = "rancher-sg"   · filename = "./algadelivery-rancher.pem"
```

`validate` ✅ · `fmt -check -recursive` ✅.

## Migração do state

O state ainda é o de antes dos módulos. Sem `moved`, o plan atual é:

```
Plan: 41 to add, 0 to change, 30 to destroy.
```

Além dos 23 `moved` da VPC ([doc 22](22-modulo-vpc-grupos-de-subnets.md#migração-do-state-moved-por-chave)), o bastion precisa de mais 5:

```hcl
moved {
  from = aws_instance.bastion
  to   = module.bastion.aws_instance.main
}
moved {
  from = aws_security_group.bastion
  to   = module.bastion.aws_security_group.main
}
moved {
  from = aws_key_pair.algadelivery
  to   = module.bastion.aws_key_pair.main
}
moved {
  from = tls_private_key.algadelivery
  to   = module.bastion.tls_private_key.main
}
moved {
  from = local_sensitive_file.private_key
  to   = module.bastion.local_sensitive_file.private_key
}
```

(O `aws_eip.bastion` nunca foi aplicado, então não precisa de `moved`.)

Testado numa cópia com o state real (baixado com `tofu state pull` e apagado depois), com os 28 `moved`: **17 add / 7 change / 5 destroy**. A rede é preservada, mas **o bastion ainda é substituído**, por 3 motivos ("forces replacement"):

```
~ ami         = "ami-09db1e291cef3f1ef" -> "ami-033ea4ff4a9c726dc"              # forces replacement
~ key_name    = "algadelivery-iac" -> "algadelivery-bastion"                    # forces replacement
~ name        = "bastion_sg" -> "bastion-sg"                                    # forces replacement
~ description = "Allow TLS inbound traffic and all outbound traffic" -> "Security group for bastion host"   # forces replacement
```

| Motivo | De onde vem |
|--------|-------------|
| AMI nova | `most_recent = true` no data source (doc 19) |
| Key pair renomeado | `var.keypair_name` mudou de `algadelivery-iac` para `algadelivery-bastion` |
| SG recriado | `name` e `description` do SG são imutáveis (doc 17) |

**Decisão:** como é estudo, aceitar a recriação do bastion é razoável (ele não guarda dados). Para **evitar**, seria preciso manter `keypair_name = "algadelivery-iac"`, o SG `bastion_sg` com a description antiga e um `lifecycle { ignore_changes = [ami] }` na instância.

## Melhorias sugeridas (ainda não aplicadas)

Testadas com `tofu validate` numa cópia:

```hcl
# modules/ec2/main.tofu
resource "aws_instance" "main" {
  # ...
  key_name                    = aws_key_pair.main.key_name   # referência: dispensa o depends_on
  associate_public_ip_address = var.associate_public_ip      # hoje está fixo em true

  tags = merge(var.common_tags, {
    Name = var.name                                          # "${var.name}" é interpolação desnecessária
  })

  lifecycle {
    ignore_changes = [ami]                                   # AMI nova não recria a instância
  }
}

# modules/ec2/variables.tofu
variable "associate_public_ip" {
  description = "Se a instancia recebe IP publico automatico"
  type        = bool
  default     = false
}
```

Outros pontos:

- **`associate_public_ip_address = true` fixo** impede usar o módulo para uma VM em subnet privada.
- **Uma chave por instância:** cada chamada gera um key pair e um `.pem`. É mais isolado, mas multiplica arquivos. Alternativa: gerar a chave uma vez na raiz e passar `keypair_name` como input.
- **O rancher também tem SSH só do seu IP e as regras 80/443 da VPC.** Se ele vai servir a interface web do Rancher (443) para você, as regras dele vão divergir das do bastion: aí vale um `rancher_security_group_config` próprio.
- **As duas instâncias estão na mesma subnet** (`["public"][0]`, a `pub_a`). Para alta disponibilidade, distribua entre AZs.
- **`var.ami_id` da raiz continua sem uso.**
- **Outputs só do bastion:** a raiz não expõe `module.rancher.public_ip`.
- **Inputs sem `description`** (`name`, `keypair_name`, `subnet_id`, `vpc_id`, `security_group_config`).

## Prévia: muitas instâncias com `for_each` no módulo

Em vez de um bloco `module` por servidor:

```hcl
locals {
  instances = {
    bastion = { sg = local.bastion_security_group_config }
    rancher = { sg = local.rancher_security_group_config }
  }
}

module "ec2" {
  source   = "./modules/ec2"
  for_each = local.instances

  name                  = each.key
  keypair_name          = "${local.context_name}-${each.key}"
  security_group_config = each.value.sg
  # ...
}
# endereços: module.ec2["bastion"], module.ec2["rancher"]
```

Com isso, os nomes únicos saem **automaticamente** da chave do mapa.

## Pegadinhas

- **Conflitos de nome só aparecem no apply** (key pair, SG, nomes globais). `validate` e `plan` não os pegam.
- **`count` muda o endereço:** `aws_eip.main` vira `aws_eip.main[0]`. Mudar de `count` para recurso simples (ou vice-versa) também pede `moved`.
- **Referenciar `[0]` de recurso com `count` quebra quando `count = 0`.** Use ternário, `one(aws_eip.main[*].public_ip)` ou `try(...)`.
- **Cada chamada de módulo tem seus próprios recursos.** `module.bastion.aws_key_pair.main` e `module.rancher.aws_key_pair.main` são recursos diferentes, mesmo com o mesmo código.
- **Os dois `.pem` ficam na raiz** e estão cobertos pelo `*.pem` do `.gitignore` ✅.
- 💲 **Duas instâncias + dois Elastic IPs + NAT:** o custo dobrou em relação a um bastion. `tofu destroy` ao terminar.
