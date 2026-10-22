# 8. O state (`terraform.tfstate`)

O state é a **memória** do OpenTofu: um JSON que liga cada recurso do código (`aws_s3_bucket.algadelivery-teste-devops`) ao objeto real na AWS (bucket `algadelivery-teste-devops`). Sem ele, o OpenTofu não saberia que o bucket já existe e tentaria criar de novo.

> **Situação atual:** o state saiu da pasta do projeto e está no S3, em `development/s3/algadelivery-teste-devops/remote.tfstate` (ver [09-backend-remoto-s3.md](09-backend-remoto-s3.md)). Os exemplos abaixo vêm da fase em que o state era local (`terraform.tfstate` + `.backup`), mas o formato do JSON é o mesmo. Para ver o remoto: `tofu state pull`.

## Os três lados que o OpenTofu compara

```
  código (.tofu)        state (.tfstate)          AWS (realidade)
  o que você QUER  ←→   o que ele ACHA que existe  ←→  o que EXISTE
```

- `plan`: faz refresh (state ← AWS) e compara com o código.
- `apply`: muda a AWS e grava o resultado no state.
- `show` / `output`: leem **só** o state.

## Anatomia do arquivo

State vazio, como está agora, depois do `destroy`:

```json
{
  "version": 4,
  "terraform_version": "1.13.1",
  "serial": 4,
  "lineage": "9391dd44-af5a-16aa-345a-756cac0ab14d",
  "outputs": {},
  "resources": [],
  "check_results": null
}
```

| Campo | Significado |
|-------|-------------|
| `version` | Formato do arquivo (4 = atual) |
| `terraform_version` | Versão do OpenTofu que gravou por último. O nome do campo veio do Terraform |
| `serial` | **Contador**: aumenta a cada gravação. Aqui foi 1 → 2 (apply) → 3 (apply versionado) → 4 (destroy) |
| `lineage` | ID único criado no 1º apply. Evita misturar states de projetos diferentes |
| `outputs` | Valores dos `output` (ver [07-outputs.md](07-outputs.md)) |
| `resources` | Um item por recurso gerenciado |

Um recurso dentro de `resources` (do `.backup`, serial 3, resumido):

```json
{
  "mode": "managed",
  "type": "aws_s3_bucket_versioning",
  "name": "algadelivery-teste-tofu-versioning",
  "provider": "provider[\"registry.opentofu.org/hashicorp/aws\"]",
  "instances": [
    {
      "schema_version": 0,
      "attributes": {
        "bucket": "algadelivery-teste-devops",
        "id": "algadelivery-teste-devops",
        "region": "us-east-1",
        "versioning_configuration": [{ "mfa_delete": "Disabled", "status": "Enabled" }]
      },
      "dependencies": ["aws_s3_bucket.algadelivery-teste-tofu"]
    }
  ]
}
```

| Campo | Significado |
|-------|-------------|
| `mode` | `managed` = `resource` (criado por você); `data` = `data source` (só leitura) |
| `type` + `name` | O endereço: `aws_s3_bucket_versioning.algadelivery-teste-tofu-versioning` |
| `provider` | Qual provider gerencia o recurso |
| `attributes` | **Todos** os atributos, inclusive os que você não escreveu (`arn`, `hosted_zone_id`…) |
| `dependencies` | A dependência implícita que a referência criou (ver doc 05). É ela que garante a ordem no `destroy` mesmo depois que o código mudou |

> Repare: o `aws_s3_bucket` no mesmo backup diz `"versioning": [{"enabled": false}]`. O bucket foi lido logo após ser criado, **antes** de o recurso de versionamento rodar. O state é uma foto do momento da leitura; o próximo `plan` faz refresh e corrige.

## Histórico: o que o state guarda (e o que não guarda)

O `terraform.tfstate` **não é um histórico**: ele guarda só a foto **atual**.

| Arquivo | Conteúdo |
|---------|----------|
| `terraform.tfstate` | Estado atual (serial 4: vazio) |
| `terraform.tfstate.backup` | **Só a versão imediatamente anterior** (serial 3: bucket + versionamento) |

O próximo apply sobrescreve o `.backup`. Para ter histórico de verdade:

- **Backend remoto em bucket S3 com versionamento** (o padrão em equipe): cada gravação vira uma versão do objeto e dá para voltar a qualquer uma. É exatamente o recurso do doc 05 usado para guardar o próprio state.
- O `git` **não** é o lugar: o state tem dados sensíveis e dá conflito com mais de uma pessoa.

Este projeto já usa um backend S3: ver [09-backend-remoto-s3.md](09-backend-remoto-s3.md).

## Comandos para explorar

```bash
tofu state list                                         # endereços dos recursos
tofu state show aws_s3_bucket.algadelivery-teste-devops  # atributos de um recurso
tofu show                                               # state inteiro, legível
tofu show -json | python3 -m json.tool                  # state em JSON formatado
tofu state pull                                         # JSON bruto (útil com backend remoto)
```

Comandos que **alteram** o state (sem tocar na AWS):

| Comando | Quando usar |
|---------|-------------|
| `tofu state mv <antigo> <novo>` | Renomeou o nome lógico e não quer recriar o recurso (alternativa ao bloco `moved`) |
| `tofu state rm <endereço>` | Parar de gerenciar um recurso **sem apagá-lo** na AWS |
| `tofu import <endereço> <id>` | Trazer para o state um recurso criado fora do OpenTofu |

> Eles fazem backup automático, mas teste sempre com `tofu plan` logo depois.

## Drift: alguém mexeu fora do OpenTofu

Aconteceu neste estudo: o bucket foi apagado direto na AWS, mas o state ainda o listava. O `plan` faz refresh, percebe e propõe criar de novo:

```bash
tofu plan -refresh-only
```
```
Note: Objects have changed outside of OpenTofu
  # aws_s3_bucket.algadelivery-teste-devops has been deleted
```

- `tofu apply -refresh-only` → só atualiza o state para refletir a realidade, sem criar nada.
- `tofu apply` → volta a AWS para o que está no código (recria o bucket).

Regra de ouro: **o que é gerenciado pelo OpenTofu, se altera pelo OpenTofu.**

## Criptografia do state (exclusivo do OpenTofu)

O state guarda tudo em texto puro, inclusive valores `sensitive`. Desde a versão 1.7, o OpenTofu pode **criptografar o state** (o Terraform não tem isso):

```hcl
terraform {
  encryption {
    key_provider "pbkdf2" "chave" {
      passphrase = var.state_passphrase   # mínimo 16 caracteres; nunca fixo no código
    }
    method "aes_gcm" "metodo" {
      keys = key_provider.pbkdf2.chave
    }
    state {
      method = method.aes_gcm.metodo
    }
  }
}
```

Em produção, troque `pbkdf2` por `aws_kms`. Perdeu a chave, perdeu o state: guarde-a bem.

## Pegadinhas

- **Nunca edite o JSON à mão.** Use os comandos `tofu state ...`.
- **Não apague o state** com recursos ativos: o OpenTofu "esquece" tudo e tenta criar de novo (`BucketAlreadyExists`), e você passa a ter recursos órfãos pagando na AWS.
- **Não faça commit** (`*.tfstate` e `*.tfstate.*` estão no `.gitignore`).
- Dois `apply` ao mesmo tempo no mesmo state corrompem o arquivo. Local, o OpenTofu cria um `.terraform.tfstate.lock.info` enquanto roda; no remoto, use lock (`use_lockfile`).
- `serial` menor que o atual = state antigo. O OpenTofu recusa sobrescrever um state mais novo com um mais velho.
