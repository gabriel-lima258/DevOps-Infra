# 5. Bucket S3 versionado

> **Doc de referência.** O bucket S3 saiu do código em 2026-10-19 (o projeto agora cria uma VPC, ver [11-vpc.md](11-vpc.md)). Os conceitos daqui (anatomia de `resource`, referências, dependência implícita, plan/apply) continuam valendo.

Dois recursos trabalhando juntos: o **bucket** e a **configuração de versionamento** dele. Os valores vêm de variáveis (ver [06-variaveis.md](06-variaveis.md)).

## O código (`main.tofu`)

```hcl
# Criação do bucket S3
resource "aws_s3_bucket" "algadelivery-teste-devops" {
  bucket = var.bucket_name

  tags = {
    Name        = var.bucket_name
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "algadelivery-teste-devops-versioning" {
  bucket = aws_s3_bucket.algadelivery-teste-devops.id
  versioning_configuration {
    status = var.bucket_versioning
  }
}
```

## Anatomia de um `resource`

```
resource "<TIPO>" "<NOME_LÓGICO>" {
  <argumentos>
}
```

| Parte | No exemplo | Para que serve |
|-------|-----------|----------------|
| Tipo | `aws_s3_bucket` | O que criar. Prefixo `aws_` = provider AWS |
| Nome lógico | `algadelivery-teste-devops` | Como **o OpenTofu** chama o recurso (no state e nas referências). A AWS nunca vê esse nome |
| `bucket` | `var.bucket_name` → `"algadelivery-teste-devops"` | Nome **real** do bucket na AWS |
| `tags` | `Name`, `Environment` | Etiquetas chave/valor: organização, custos, filtros no console |

O endereço completo do recurso é `tipo.nome_lógico` → `aws_s3_bucket.algadelivery-teste-devops`. É esse endereço que aparece no `plan` e no `tofu state list`.

> Os argumentos disponíveis de cada recurso estão na doc do provider: https://search.opentofu.org/provider/hashicorp/aws/latest

## Versionamento

Com o versionamento ligado, o S3 guarda **todas as versões** de um objeto. Sobrescreveu ou apagou um arquivo? A versão anterior continua lá e pode ser restaurada.

No provider AWS v4+, o versionamento **não** é mais um argumento dentro do `aws_s3_bucket`. Ele é um recurso separado, `aws_s3_bucket_versioning`. O mesmo vale para criptografia, lifecycle, policy, website etc.: cada um é um recurso `aws_s3_bucket_*`.

| `status` | Efeito |
|----------|--------|
| `Enabled` | Guarda todas as versões |
| `Suspended` | Para de criar versões novas, mas **mantém** as que já existem |
| `Disabled` | Só vale para bucket que **nunca** teve versionamento. Depois de `Enabled`, só dá para ir para `Suspended` (regra da AWS) |

### Referência entre recursos

```hcl
bucket = aws_s3_bucket.algadelivery-teste-devops.id
```

Formato: `<tipo>.<nome_lógico>.<atributo>`. O versionamento pega o `id` do bucket criado acima (para S3, o `id` é o nome do bucket).

Isso cria uma **dependência implícita**: o OpenTofu entende que precisa criar o bucket **antes** do versionamento, e no `destroy` faz o contrário. Você não precisa dizer a ordem; ela sai das referências. (Existe `depends_on = [...]` para dependências explícitas, mas só se usa quando não há referência.)

Por que não escrever `bucket = "algadelivery-teste-devops"` direto? Funcionaria, mas o OpenTofu não saberia da dependência: poderia tentar configurar o versionamento antes de o bucket existir, e o nome ficaria duplicado no código.

## Rodando o fluxo com este bucket

O passo a passo geral (init → plan → apply → show → destroy) está em [04-fluxo-de-trabalho.md](04-fluxo-de-trabalho.md). Aqui fica o que é específico deste recurso.

### `tofu plan`

Saída real deste projeto (resumida):

```
  # aws_s3_bucket.algadelivery-teste-devops will be created
  + resource "aws_s3_bucket" "algadelivery-teste-devops" {
      + arn                         = (known after apply)
      + bucket                      = "algadelivery-teste-devops"
      + region                      = "us-east-1"
      + tags                        = {
          + "Environment" = "Development"
          + "Name"        = "algadelivery-teste-devops"
        }
      ...
    }

  # aws_s3_bucket_versioning.algadelivery-teste-devops-versioning will be created
  + resource "aws_s3_bucket_versioning" "algadelivery-teste-devops-versioning" {
      + bucket = (known after apply)
      + region = "us-east-1"
      + versioning_configuration {
          + status     = "Enabled"
        }
    }

Plan: 2 to add, 0 to change, 0 to destroy.
```

Repare: no versionamento, `bucket = (known after apply)`. O valor vem de outro recurso que ainda não existe.

Símbolos do plan:

| Símbolo | Significa |
|---------|-----------|
| `+` | criar |
| `-` | destruir |
| `~` | alterar no lugar |
| `-/+` | destruir e recriar (*replace*): cuidado, perde dados! |
| `(known after apply)` | valor que só a AWS vai definir (ex.: ARN) |

### `tofu apply`

Mostra o mesmo plano e pede confirmação. Digite `yes`. Saída esperada (repare na ordem: o bucket primeiro, por causa da dependência):

```
aws_s3_bucket.algadelivery-teste-devops: Creating...
aws_s3_bucket.algadelivery-teste-devops: Creation complete after 2s [id=algadelivery-teste-devops]
aws_s3_bucket_versioning.algadelivery-teste-devops-versioning: Creating...
aws_s3_bucket_versioning.algadelivery-teste-devops-versioning: Creation complete after 2s [id=algadelivery-teste-devops]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

## State e drift

Depois do `apply`, os dois recursos ficam registrados no state, hoje guardado no S3 (ver [09-backend-remoto-s3.md](09-backend-remoto-s3.md)). A anatomia do arquivo, o histórico, o drift (o bucket que foi apagado pelo console) e os comandos `tofu state` estão em [08-state.md](08-state.md).

> Neste estudo, o nome lógico foi de `algadelivery-teste-devops` para `algadelivery-teste-tofu` e depois **voltou** para `algadelivery-teste-devops`. Como a cada troca o bucket antigo já não existia na AWS (drift ou `destroy`), o plan só propôs criar o novo. Se ele existisse, o plan mostraria **destruir um e criar outro** (ver abaixo).

## Renomear ≠ editar

| Mudança | Efeito |
|---------|--------|
| Muda uma `tag` | `~` alteração no lugar |
| Muda o `bucket` (nome real) | `-/+` replace: bucket antigo apagado, novo criado |
| Muda só o **nome lógico** | OpenTofu acha que é outro recurso: destrói um e cria outro. Para evitar, use um bloco `moved { from = ... to = ... }` ou `tofu state mv` |

## Pegadinhas

- **Nome de bucket é global** (todas as contas AWS do mundo). `BucketAlreadyExists` = alguém já usa esse nome. Regras: 3–63 caracteres, minúsculas, números, `-` e `.`.
- `destroy` falha com `BucketNotEmpty` se houver objetos. **Com versionamento ligado, cada versão antiga também conta**: apagar o arquivo no console não basta. Use `force_destroy = true` no bucket (só em teste!), que apaga todas as versões.
- Convenção: nomes lógicos costumam usar `_` (`aws_s3_bucket.algadelivery_teste`). Hífen funciona, mas `_` é o padrão da comunidade.
- Tags repetidas em todo recurso? Dá para defini-las uma vez no provider:
  ```hcl
  provider "aws" {
    region = var.aws_region
    default_tags {
      tags = { Environment = "Development" }
    }
  }
  ```
  É por isso que o plan mostra `tags` (as do recurso) e `tags_all` (recurso + `default_tags`).
- Rode `tofu fmt` antes de cada commit. Hoje o código já está formatado (`tofu fmt -check` passa).
- Versionamento custa: cada versão guardada ocupa espaço cobrado. Em produção, combine com `aws_s3_bucket_lifecycle_configuration` para expirar versões antigas.
