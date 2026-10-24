# Conectando ao RDS via Túnel SSH

O RDS está em uma subnet privada e não possui acesso público. O bastion host age como ponte:
a conexão SSH cria um canal seguro da sua máquina até o endpoint do RDS, que só é alcançável
de dentro da VPC.

```
Máquina local :5433  →  Bastion (SSH)  →  RDS :5432
              [túnel criptografado]    [rede privada VPC]
```

---

## Pré-requisitos

- OpenTofu aplicado (`tofu apply` executado com sucesso)
- AWS CLI configurado (`aws configure`)
- `psql` instalado (opcional — pode usar DBeaver ou outro cliente)

---

## Passo 1 — Obter os valores via tofu output

```bash
cd envs/dev

tofu output bastion_public_ip
tofu output db_endpoint
tofu output db_password_secret_arn
```

Exemplo de retorno:

```
bastion_public_ip = "3.95.202.187"
db_endpoint       = "development-algadelivery-db.ca50g4ycge5p.us-east-1.rds.amazonaws.com:5432"
db_password_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:..."
```

> O arquivo `.pem` foi gerado pelo OpenTofu e salvo em `envs/dev/algadelivery-bastion.pem`.

---

## Passo 2 — Ajustar permissão do arquivo .pem

```bash
chmod 400 algadelivery-bastion.pem
```

---

## Passo 3 — Buscar a senha do banco no Secrets Manager

```bash
aws secretsmanager get-secret-value \
  --secret-id $(tofu output -raw db_password_secret_arn) \
  --query SecretString \
  --output text
```

O retorno é um JSON como `{"password":"SenhaGerada123!"}`. Anote o valor de `password`.

---

## Passo 4 — Abrir o túnel SSH

> O `db_endpoint` retorna `host:porta`. Remova o `:5432` do final para usar no `-L`.

```bash
ssh -i algadelivery-bastion.pem \
  -L 5433:<RDS_HOST>:5432 \
  ubuntu@<BASTION_PUBLIC_IP> \
  -N
```

Exemplo concreto:

```bash
ssh -i algadelivery-bastion.pem \
  -L 5433:development-algadelivery-db.ca50g4ycge5p.us-east-1.rds.amazonaws.com:5432 \
  ubuntu@3.95.202.187 \
  -N
```

O terminal ficará bloqueado com o túnel ativo — isso é esperado. A flag `-N` mantém o túnel
aberto sem executar nenhum comando remoto.

---

## Passo 5 — Conectar ao banco

Abra um **novo terminal** e conecte via `localhost:5433`.

**Via psql:**

```bash
psql -h localhost -p 5433 -U postgres -d delivery
```

**Via DBeaver ou outro cliente:**

| Campo    | Valor                              |
|----------|------------------------------------|
| Host     | `localhost`                        |
| Port     | `5433`                             |
| Database | `delivery`                         |
| User     | `postgres`                         |
| Password | valor obtido no Passo 3            |

---

## Encerrando o túnel

Volte ao terminal onde o túnel está aberto e pressione `Ctrl+C`.
