# 24. Múltiplos ambientes: `envs/dev` e `envs/prod`

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Módulos: [21-modules.md](21-modules.md)

## Por que separar ambientes

Até aqui havia **um** root module na raiz do projeto, que era o ambiente. Agora há duas pastas, cada uma um ambiente completo e independente:

| Benefício | Na prática |
|-----------|------------|
| **States separados** | Um `apply` em dev nunca toca no state de prod |
| **Raio de impacto menor** | Um erro em dev fica em dev |
| **Testar antes** | Muda o módulo → testa em dev → depois aplica em prod |
| **Configuração própria** | Prod pode ter CIDR, tamanho de instância e regras diferentes |

## A estrutura

```
devops/
├── .env                        ← credenciais (compartilhadas)
├── modules/                    ← o "código" (compartilhado pelos dois)
│   ├── vpc/
│   └── ec2/
└── envs/                       ← os "ambientes" (um root module cada)
    ├── dev/
    │   ├── providers.tofu      ← backend: algadelivery/development/remote.tfstate
    │   ├── variables.tofu      ← environment = "development", VPC 172.25.0.0/16
    │   ├── vpc.tofu            ← module "vpc" { source = "../../modules/vpc" }
    │   ├── ec2.tofu            ← module "bastion" { source = "../../modules/ec2" }
    │   ├── data.tofu, local.tofu, outputs.tofu
    │   ├── .terraform.lock.hcl ← próprio
    │   ├── .terraform/         ← próprio (fora do git)
    │   └── development-algadelivery-bastion.pem   ← próprio (fora do git)
    └── prod/
        └── ... mesmos arquivos ← environment = "production", VPC 172.26.0.0/16
```

| Compartilhado | De cada ambiente |
|---------------|------------------|
| `modules/vpc`, `modules/ec2` (a "receita") | `variables.tofu` (os valores) |
| `.env` (credenciais) | o **state** (key no S3) |
| | `.terraform/`, `.terraform.lock.hcl` |
| | o `.pem` (gerado em `path.root`, a pasta do env, doc 23) |

O `source` dos módulos agora sobe duas pastas: `"../../modules/vpc"` (de `envs/dev` até a raiz).

## Como cada ambiente ganha seu próprio state

```hcl
# envs/<env>/providers.tofu
backend "s3" {
  bucket = "algadelivery-tfstate-devops"
  key    = "algadelivery/${var.environment}/remote.tfstate"
  region = var.aws_region
}
```

| Pasta | `var.environment` (default) | State no S3 |
|-------|-----------------------------|-------------|
| `envs/dev` | `development` | `algadelivery/development/remote.tfstate` |
| `envs/prod` | `production` | `algadelivery/production/remote.tfstate` |

Variável no backend é recurso do OpenTofu ≥ 1.8 (doc 09).

## Como rodar

O OpenTofu sempre trabalha na **pasta atual**. Para escolher o ambiente, entre na pasta dele:

```bash
# Dev
cd envs/dev
source ../../.env       # o .env continua na raiz do projeto
tofu init
tofu plan
tofu apply

# Prod (primeira vez: ver o aviso abaixo)
cd ../prod
tofu init -reconfigure
tofu plan
```

### ⚠️ Prod: rode `tofu init -reconfigure`

A pasta `envs/prod/.terraform/` foi **copiada** do antigo root e ainda aponta para o backend antigo (`development/networking/remote.tfstate`). Por isso o `plan` em prod falha hoje:

```
Error: Backend initialization required: please run "tofu init"
```

- `tofu init -reconfigure`: usa a configuração **atual** do backend (`algadelivery/production/...`) **sem copiar** nada do backend antigo. É o certo aqui.
- `tofu init -migrate-state`: copiaria o state antigo para o novo. **Não** use: prod deve nascer vazio.

> **Dica:** não copie a pasta `.terraform/` entre ambientes. Ela é gerada pelo `init`, e cada env deve ter a sua.

## dev x prod

| Item | dev | prod |
|------|-----|------|
| `environment` | `development` | `production` |
| VPC | `172.25.0.0/16` | `172.26.0.0/16` |
| Subnets | `172.25.1-12.0/24` | `172.26.1-12.0/24` |
| Nome da VPC | `development-algadelivery-vpc` | `production-algadelivery-vpc` |
| Instância bastion (`name`) | `bastion` | `production-bastion` |
| Key pair | `development-algadelivery-bastion` | `algadelivery-bastion` |
| Subnet do bastion | `subnet_pub_ids["public"][0]` | `subnet_pub_ids["public"]["0"]` |
| Rancher | comentado | comentado |

Os **CIDRs não se sobrepõem** (`172.25` x `172.26`). Isso permite, no futuro, conectar as duas VPCs (peering, Transit Gateway) sem conflito de IPs (doc 11).

## Situação real

| Ambiente | Status |
|----------|--------|
| **dev** | ✅ Aplicado. State `algadelivery/development/remote.tfstate`, **35 recursos**, `tofu plan` → `No changes`. `validate` e `fmt` ok |
| **prod** | ⏸️ Não inicializado (precisa de `tofu init -reconfigure`). `validate` ok |

Conferido na AWS (só leitura):

- Só existe **1 VPC** (`development-algadelivery-vpc`), 1 NAT Gateway e 1 EC2 (`bastion`).
- 2 Elastic IPs: o do bastion e o do NAT regional (marcado pela AWS como `ServiceManaged: rnat`).
- **Nenhum recurso órfão** do código antigo. O dev foi criado do zero num state novo, e o state antigo (`development/networking/...`) não existe mais no bucket. Com isso, a migração com blocos `moved` dos docs 21–23 deixou de ser necessária na prática.

## ⚠️ Pontos de atenção

### 1. A key do backend depende de uma variável

O state é escolhido pelo **default** de `var.environment`. Se alguém rodar dentro de `envs/prod`:

```bash
tofu init -var environment=development
```

o backend de prod passa a apontar para o **state de dev**. A pasta é prod, mas o state é dev: um `apply` aí misturaria os ambientes.

Proteções (testadas com `tofu validate` numa cópia de `envs/prod`):

```hcl
# Opção A: key fixa por pasta (o mais simples e seguro)
backend "s3" {
  bucket = "algadelivery-tfstate-devops"
  key    = "algadelivery/production/remote.tfstate"
  region = var.aws_region
}

# Opção B: travar a variável na pasta
variable "environment" {
  type    = string
  default = "production"

  validation {
    condition     = var.environment == "production"
    error_message = "Esta pasta e do ambiente production."
  }
}
```

Com a pasta definindo o ambiente, a variável `environment` deixa de ser algo que "se troca": ela é fixa por pasta.

### 2. Código duplicado (os ambientes já divergiram)

Cada env tem uma cópia de `vpc.tofu`, `ec2.tofu`, `local.tofu` etc. O `diff` entre as pastas mostra que **elas já divergiram** em coisas que não são configuração:

- o nome do bastion (`bastion` x `${var.environment}-bastion`);
- o key pair (com e sem o prefixo do ambiente);
- o índice da subnet (`[0]` x `["0"]`);
- o bloco do rancher comentado é diferente nas duas pastas.

Toda mudança precisa ser feita **duas vezes**, e é fácil esquecer uma. Opções:

| Abordagem | Como fica | Prós | Contras |
|-----------|-----------|------|---------|
| **Pastas por env** (o atual) | `envs/dev`, `envs/prod` com tudo | Isolamento total; dá para diferir de propósito | Duplicação |
| **Envs "finos"** | Cada env só com `providers.tofu`, `terraform.tfvars` e as chamadas de módulo; a lógica toda nos módulos | Menos duplicação; a diferença fica nos `.tfvars` | Ainda há um pouco de repetição |
| **Uma pasta + `-var-file`** | `tofu init -backend-config=prod.hcl` + `tofu apply -var-file=prod.tfvars` | Zero duplicação | Mais fácil errar o ambiente no comando |
| **Workspaces** | `tofu workspace select prod` (doc 09) | Zero duplicação | O ambiente fica "invisível" na pasta |

Para estudo, as pastas por env são ótimas, porque deixam a separação explícita. O passo seguinte natural é afinar os envs: tudo que é **valor** vai para um `terraform.tfvars` e tudo que é **lógica** fica igual.

### 3. Nomes inconsistentes entre os envs

> **RDS:** o `db_subnet_group_name` e o `db_parameter_group_name` são **iguais** em dev e prod, e são únicos por conta/região: o apply do segundo ambiente falharia. Além disso, o provider `random` foi adicionado só em `envs/dev`. Ver [26-modulo-rds.md](26-modulo-rds.md).

Defina um padrão único, por exemplo `"${var.environment}-${local.context_name}-<recurso>"`, e aplique nos dois. Key pairs são únicos **por região da conta**: hoje não colidem (`development-algadelivery-bastion` x `algadelivery-bastion`), mas o de prod não tem o prefixo do ambiente.

### 4. Bug no rancher comentado (dev)

```hcl
#   instance_type         = "${var.environment}-${var.keypair_name}"
```

Se for descomentado, o `instance_type` vira `"development-algadelivery-bastion"`, que não é um tipo de instância válido, e o apply falha. Provavelmente as linhas de `instance_type` e `keypair_name` trocaram de lugar.

### 5. Custo

Cada ambiente tem o próprio NAT Gateway, EIPs e EC2. Subir o prod **dobra** o custo. Em estudo: `tofu destroy` em cada pasta ao terminar.

> ⚠️ Com `prevent_destroy = true` no módulo `ec2`, o `tofu destroy` **falha nos dois ambientes**. Use uma variável por ambiente (`false` no dev, `true` no prod): ver [25-lifecycle.md](25-lifecycle.md#prevent_destroy-por-ambiente-com-variável).

### 6. Commitar a reorganização

O `git status` mostra os `.tofu` da raiz apagados e a pasta `envs/` nova, ainda sem commit. Faça o commit das duas coisas juntas. Os `.pem` e os `.terraform/` dentro de `envs/` já são ignorados pelo `.gitignore` (`*.pem`, `.terraform/`).

## Pegadinhas

- **A pasta define o ambiente.** Confira onde você está antes de `apply` (`pwd`, ou o `Name` da VPC no plan).
- **`source ../../.env`**: dentro de `envs/<env>`, o `.env` está duas pastas acima.
- **`path.root` mudou:** agora é a pasta do env, por isso cada env tem o seu `.pem`.
- **`.terraform.lock.hcl` por env:** atualizar um provider em dev não atualiza o de prod. Rode `tofu init -upgrade` em cada um.
- **Módulos compartilhados:** mudar `modules/` afeta **os dois** ambientes no próximo `plan`. Teste em dev primeiro.
- **Outputs são por env:** `tofu output` em `envs/dev` mostra só o dev.
