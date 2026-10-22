# 3. Providers e `tofu init`

## O que é um provider?

O OpenTofu sozinho não sabe falar com a AWS. Quem sabe é o **provider**: um plugin que traduz os blocos `resource` em chamadas de API. Há providers para AWS, Azure, GCP, Kubernetes, GitHub, Cloudflare etc.

## O bloco `terraform`

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

| Parte | Significado |
|-------|-------------|
| `aws = { ... }` | Nome local do provider. É o prefixo dos recursos (`aws_s3_bucket`, `aws_instance`…) |
| `source = "hashicorp/aws"` | De onde baixar. Por padrão vem do registry do OpenTofu: `registry.opentofu.org/hashicorp/aws` |
| `version = "~> 6.0"` | Restrição de versão (veja abaixo) |

> Mesmo no OpenTofu o nome do bloco continua `terraform { }`: é compatibilidade com o Terraform.

### Restrições de versão

| Expressão | Aceita |
|-----------|--------|
| `"6.69.1"` | exatamente essa |
| `">= 6.0"` | 6.0 ou qualquer maior (inclusive 7.x, perigoso) |
| `"~> 6.0"` | `>= 6.0` e `< 7.0` → recebe melhorias, mas não a próxima versão *major* |
| `"~> 6.69.0"` | `>= 6.69.0` e `< 6.70.0` → só correções |

### Mais de um provider

O projeto hoje usa **quatro**: `aws` (a nuvem), `http` (ler uma URL, doc 18), `tls` (gerar chave SSH) e `local` (gravar arquivo na sua máquina, doc 19). Os dois primeiros:

```hcl
required_providers {
  aws = {
    source  = "hashicorp/aws"
    version = "~> 6.0"
  }
  http = {
    source  = "hashicorp/http"     # faz GET em URLs (data source, doc 18)
    version = "~> 3.0"
  }
}
```

Cada provider novo exige **rodar `tofu init` de novo** (senão: `Error: Missing required provider`), e o `.terraform.lock.hcl` passa a listar todos. Nem todo provider precisa de um bloco `provider "..." { }`: o `http` não tem configuração.

## O bloco `provider`

```hcl
provider "aws" {
  region = "us-east-1"
}
```

Configura o provider: aqui só a região. As credenciais **não** ficam aqui, elas vêm do ambiente (ver [02-credenciais-aws.md](02-credenciais-aws.md)).

## `tofu init`

```bash
tofu init
```

Precisa rodar:
- na primeira vez em um projeto (ou após clonar);
- ao adicionar/trocar provider ou versão;
- ao adicionar módulos ou mudar o backend.

O que ele faz:

1. Lê `required_providers`.
2. Escolhe a versão mais nova que satisfaz a restrição (hoje: **6.69.1**).
3. Baixa o binário para `.terraform/providers/...`.
4. Cria/atualiza o **`.terraform.lock.hcl`**.

Saída esperada (resumida):

```
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 6.0"...
- Installing hashicorp/aws v6.69.1...
- Installed hashicorp/aws v6.69.1 (signed, key ID ...)

OpenTofu has been successfully initialized!
```

### `.terraform/` x `.terraform.lock.hcl`

| Arquivo | O que é | Vai pro git? |
|---------|---------|--------------|
| `.terraform/` | Binários baixados (centenas de MB, específicos do seu SO/CPU) | **Não** |
| `.terraform.lock.hcl` | Versão escolhida + hashes de verificação | **Sim**: garante que todo mundo usa a mesma versão |

### Atualizar o provider

O lock "congela" a versão. Para pegar uma mais nova dentro da restrição:

```bash
tofu init -upgrade
```

## Pegadinhas

- `Error: Inconsistent dependency lock file` → mudou a `version` mas não rodou `init` de novo.
- Mac M1/M2 e Linux têm hashes diferentes. Se outra pessoa usa outro SO: `tofu providers lock -platform=darwin_arm64 -platform=linux_amd64`.
- `init` não toca na AWS, só baixa plugins. Pode rodar sem medo.
