# 2. Credenciais AWS

O OpenTofu não tem login próprio: o **provider AWS** usa as mesmas credenciais que o AWS CLI e os SDKs. Há duas formas comuns de fornecê-las.

## Opção A — arquivo `.env` (o que este projeto usa)

O `.env` na raiz contém:

```bash
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
```

Carregue no terminal antes de rodar o tofu:

```bash
source .env
```

> O `source` só vale para **aquele terminal**. Abriu outra aba? Rode de novo.

## Opção B — `aws configure`

```bash
aws configure
```

Salva em `~/.aws/credentials` e `~/.aws/config` (perfil `default`). Com vários perfis, use `export AWS_PROFILE=nome-do-perfil`.

## Quem ganha quando há as duas? (precedência)

O provider procura credenciais nesta ordem e para na primeira que encontrar:

1. Parâmetros no próprio bloco `provider "aws"` (**não faça isso**: a chave iria parar no código)
2. Variáveis de ambiente (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_PROFILE`…) ← o `.env`
3. Arquivos `~/.aws/credentials` / `~/.aws/config` ← o `aws configure`
4. Role da máquina (EC2, ECS, CI etc.)

A **região** segue lógica parecida: o `region = var.aws_region` (padrão `us-east-1`) no `providers.tofu` tem prioridade sobre `AWS_REGION`.

## Conferir quem você é

```bash
aws sts get-caller-identity
```

Mostra a conta e o usuário/role em uso. Se der erro aqui, o tofu também vai falhar.

## Pegadinhas

- `.env` está no `.gitignore`. **Nunca** faça commit de chaves; se vazar, desative a chave no IAM na hora.
- Erro `No valid credential sources found` no `plan` = esqueceu o `source .env` naquele terminal.
- Prefira um usuário IAM com permissões mínimas (para este estudo, S3) em vez da conta root.
