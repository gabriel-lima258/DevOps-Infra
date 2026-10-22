# 9. Backend remoto no S3 (um state por ambiente)

Até o doc 08, o state era um arquivo na pasta do projeto. Agora ele fica num **bucket S3**, com um arquivo separado para cada ambiente (development, homolog, production…).

## Por que tirar o state da máquina

| Problema do state local | Como o backend remoto resolve |
|-------------------------|-------------------------------|
| Só existe no seu computador | Qualquer pessoa ou pipeline (CI/CD) acessa |
| Apagou a pasta, perdeu o controle dos recursos | Fica guardado na AWS |
| `.backup` guarda só 1 versão | Com versionamento no bucket, **todas** as versões ficam guardadas |
| Duas pessoas rodando `apply` ao mesmo tempo | Lock (trava) impede |
| Um state só para tudo | Uma *key* (caminho) por ambiente |

## O código (`providers.tofu`)

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "algadelivery-tfstate-devops"
    key    = "${var.environment}/networking/remote.tfstate"
    region = var.aws_region
  }
}

provider "aws" {
  region = var.aws_region
}
```

| Argumento | Valor | Significado |
|-----------|-------|-------------|
| `bucket` | `algadelivery-tfstate-devops` | Bucket que **guarda** o state. Não é o bucket que o projeto cria |
| `key` | `${var.environment}/networking/remote.tfstate` | Caminho do arquivo dentro do bucket |
| `region` | `var.aws_region` | Região do bucket de state |

### A key: um state por ambiente (e por camada)

Com os valores padrão, a key vira:

```
development/networking/remote.tfstate
└─ ambiente ┘└─ camada ─┘
```

Conteúdo real do bucket de state agora:

```bash
$ aws s3 ls s3://algadelivery-tfstate-devops --recursive
2026-10-19 21:41:44   1526 development/networking/remote.tfstate
```

Com `environment = "homolog"`, o OpenTofu usaria `homolog/networking/remote.tfstate`: outro arquivo, outro state, recursos independentes. O mesmo código serve para todos os ambientes. Por que separar por camada: ver [10-organizacao-dos-arquivos.md](10-organizacao-dos-arquivos.md).

> Na fase do S3, a key era `${var.environment}/s3/${var.bucket_name}/remote.tfstate` (→ `development/s3/algadelivery-teste-devops/remote.tfstate`). Esse arquivo foi removido junto com o bucket.

### Variáveis dentro do `backend` (exclusivo do OpenTofu ≥ 1.8)

No Terraform, o bloco `backend` **não aceita** variáveis: tudo tem que ser fixo ou passado via `-backend-config`. O OpenTofu, desde a 1.8, avalia algumas expressões antes do resto do código (*early evaluation*). Por isso `var.environment` funciona aqui.

Restrição: só funciona com **variáveis e locals**. Atributos de recurso (`aws_s3_bucket.x.id`) não podem ser usados, porque o backend precisa existir antes de qualquer recurso.

## O problema do ovo e da galinha

O bucket `algadelivery-tfstate-devops` precisa **existir antes** do `tofu init`, já que é nele que o state será gravado. Por isso ele não pode ser criado por este mesmo projeto. Opções:

1. Criar à mão (console/CLI), uma vez só.
2. Um projeto *bootstrap* separado, com state local, que cria só o bucket de state (com versionamento e criptografia).

## Migrar do state local para o remoto

Ao adicionar o bloco `backend` num projeto que já tinha `terraform.tfstate`:

```bash
tofu init -migrate-state
```

O OpenTofu pergunta se quer copiar o state local para o S3 (`yes`). Depois disso:

- `terraform.tfstate` e `.backup` deixam de ser usados (podem ser apagados depois de conferir o remoto).
- A configuração do backend fica gravada em `.terraform/terraform.tfstate`. **Esse arquivo não é o seu state**, apesar do nome: ele só diz onde o state está.

Conferindo:

```bash
$ tofu state list
aws_s3_bucket.algadelivery-teste-devops
aws_s3_bucket_versioning.algadelivery-teste-devops-versioning

$ tofu state pull | head -5      # baixa e mostra o JSON do state remoto
```

## Trocar de ambiente

A forma mais organizada é um `.tfvars` por ambiente (ver [06-variaveis.md](06-variaveis.md)):

`homolog.tfvars`
```hcl
environment    = "homolog"
vpc_cidr_block = "172.26.0.0/16"            # faixa diferente de dev: permite conectar as redes depois
vpc_name       = "algadelivery-vpc-homolog"
```

```bash
tofu init  -reconfigure -var-file=homolog.tfvars   # aponta o backend para homolog/...
tofu plan  -var-file=homolog.tfvars
tofu apply -var-file=homolog.tfvars
```

- `-reconfigure`: troca a configuração do backend **sem copiar** o state atual. É o que você quer ao trocar de ambiente.
- `-migrate-state`: troca **e copia** o state. É para mudança de lugar, não de ambiente.

> Use **o mesmo** `-var-file` no `init`, no `plan` e no `apply`. Se os valores do backend mudarem entre os comandos, o OpenTofu acusa que a configuração do backend mudou e pede um novo `init`. Isso é uma proteção contra aplicar em produção um plano feito para dev.

## Recomendações para o bucket de state

Hoje o bucket `algadelivery-tfstate-devops` está **sem versionamento** (`get-bucket-versioning` retorna vazio). Sem ele, não há histórico: cada `apply` sobrescreve o arquivo.

```hcl
backend "s3" {
  bucket       = "algadelivery-tfstate-devops"
  key          = "${var.environment}/networking/remote.tfstate"
  region       = var.aws_region
  encrypt      = true   # criptografia do lado do servidor
  use_lockfile = true   # lock nativo no S3 (cria um .tflock ao lado do state)
}
```

| Recomendação | Por quê |
|--------------|---------|
| Versionamento **no bucket de state** | Histórico de verdade: dá para restaurar qualquer versão anterior do state |
| `use_lockfile = true` | Impede dois `apply` simultâneos. Antes isso exigia uma tabela DynamoDB (`dynamodb_table`), hoje considerada legada |
| `encrypt = true` | State tem dados sensíveis |
| Bloquear acesso público | Padrão em buckets novos; confira |

## Backend com key por ambiente x `tofu workspace`

O OpenTofu também tem *workspaces* (`tofu workspace new homolog`), que guardam states diferentes no mesmo backend, em `env:/homolog/...`. Este projeto usa outro caminho: **variável na key**. As duas formas funcionam. A da key por ambiente deixa o caminho explícito e combina com um `.tfvars` por ambiente. Hoje o projeto está no workspace `default` (`tofu workspace list`).

## Pegadinhas

- **Nomes globais** (como bucket S3): o mesmo nome em dev e homolog falha no segundo ambiente com `BucketAlreadyExists`. Inclua o ambiente no nome. A VPC não tem esse problema, mas use CIDRs diferentes por ambiente.
- **Mudar a key = mudar de state.** Recursos do state antigo ficam órfãos na AWS se não forem destruídos ou migrados antes (ver doc 10).
- Esqueceu o `-reconfigure` ao trocar de ambiente → o OpenTofu pergunta se quer migrar o state. Responder `yes` copiaria o state de dev para homolog. Responda **no** e rode com `-reconfigure`.
- Credenciais: o backend usa as mesmas do provider (`source .env`). O usuário IAM precisa de `s3:ListBucket` no bucket de state e de `s3:GetObject`/`s3:PutObject` (e `DeleteObject`, por causa do lock) na key.
- Apagar o bucket de state = perder o controle de **todos** os ambientes. Proteja-o.
- O `.terraform/` continua fora do git. Quem clonar o projeto roda `tofu init` e o backend é configurado de novo.
