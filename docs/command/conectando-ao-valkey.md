# Conectando ao ElastiCache Valkey via Túnel SSH

O ElastiCache está em uma subnet privada e não possui acesso público. O bastion host age como ponte:
a conexão SSH cria um canal seguro da sua máquina até o endpoint do Valkey, que só é alcançável
de dentro da VPC.

```
Máquina local :6380  →  Bastion (SSH)  →  ElastiCache :6379
              [túnel criptografado]    [rede privada VPC]
```

> A porta local é `6380` para evitar conflito caso haja um Redis/Valkey rodando localmente na `6379`.

---

## Pré-requisitos

- OpenTofu aplicado (`tofu apply` executado com sucesso)
- AWS CLI configurado (`aws configure`)
- `redis-cli` instalado (opcional — pode usar qualquer cliente Redis/Valkey compatível)

---

## Passo 1 — Obter os valores via tofu output

```bash
cd envs/dev

tofu output bastion_public_ip
tofu output elasticache_endpoint_address
tofu output elasticache_endpoint_port
```

Exemplo de retorno:

```
bastion_public_ip             = "3.95.202.187"
elasticache_endpoint_address  = "development-algadelivery-valkey.serverless.use1.cache.amazonaws.com"
elasticache_endpoint_port     = 6379
```

> O arquivo `.pem` foi gerado pelo OpenTofu e salvo em `envs/dev/algadelivery-bastion.pem`.

---

## Passo 2 — Ajustar permissão do arquivo .pem

```bash
chmod 400 algadelivery-bastion.pem
```

---

## Passo 3 — Abrir o túnel SSH

```bash
ssh -i algadelivery-bastion.pem \
  -L 6380:<ELASTICACHE_ENDPOINT>:6379 \
  ubuntu@<BASTION_PUBLIC_IP> \
  -N
```

Exemplo concreto:

```bash
ssh -i algadelivery-bastion.pem \
  -L 6380:development-algadelivery-valkey.serverless.use1.cache.amazonaws.com:6379 \
  ubuntu@3.95.202.187 \
  -N
```

O terminal ficará bloqueado com o túnel ativo — isso é esperado. A flag `-N` mantém o túnel
aberto sem executar nenhum comando remoto.

---

## Passo 4 — Conectar ao Valkey

Abra um **novo terminal** e conecte via `localhost:6380`.

**Via redis-cli:**

```bash
redis-cli -h localhost -p 6380
```

Testando a conexão:

```
127.0.0.1:6380> PING
PONG

127.0.0.1:6380> SET chave "algadelivery"
OK

127.0.0.1:6380> GET chave
"algadelivery"
```

**Via Another Redis Desktop Manager (ARDM) ou outro cliente:**

| Campo    | Valor       |
|----------|-------------|
| Host     | `localhost` |
| Port     | `6380`      |
| Auth     | (sem senha) |

> O ElastiCache Serverless não usa senha — o controle de acesso é feito via IAM/VPC.

---

## Encerrando o túnel

Volte ao terminal onde o túnel está aberto e pressione `Ctrl+C`.
