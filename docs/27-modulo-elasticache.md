# 27. Módulo ElastiCache: Valkey Serverless passo a passo

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Módulos: [21-modules.md](21-modules.md) · Módulo irmão: [26-modulo-rds.md](26-modulo-rds.md)

## O que é um cache e por que usar

O banco (RDS, doc 26) guarda os dados **no disco**, e cada consulta custa alguns milissegundos. Um **cache** guarda dados **na memória**: a leitura leva menos de 1 ms.

Analogia: o banco é o **arquivo do escritório** (tudo guardado, mas é preciso ir buscar); o cache é a **mesa** (só o que se usa toda hora, ao alcance da mão).

Usos típicos numa aplicação como a algadelivery:

| Uso | Exemplo |
|-----|---------|
| Cache de consultas | cardápio de um restaurante, lido mil vezes e alterado pouco |
| Sessão de usuário | quem está logado, carrinho de compras |
| Contadores e rate limit | "no máximo 10 pedidos por minuto" |
| Filas e pub/sub simples | avisar que o status do pedido mudou |

> O cache **não substitui** o banco: se ele for apagado, a aplicação busca de novo no banco. Por isso, no projeto, os snapshots do cache estão desligados (ver [ponto 7](#7-snapshots-desligados-e-valores-iguais-em-dev-e-prod)).

## ElastiCache, Valkey e Serverless

- **ElastiCache:** o serviço gerenciado de cache da AWS (a AWS cuida de servidor, patches, réplicas e failover).
- **Engine** (o software do cache):

| Engine | O que é |
|--------|---------|
| **Valkey** (o do projeto) | Fork open source do Redis, mantido pela Linux Foundation. Compatível com os comandos do Redis e **mais barato** na AWS (~33% menos no serverless) |
| Redis OSS | O original; mudou de licença em 2024, e daí nasceu o Valkey |
| Memcached | Mais simples: só chave/valor, sem persistência nem estruturas de dados |

- **Serverless x node-based:**

| | **Serverless** (o do projeto) | Node-based (cluster) |
|---|---|---|
| Você escolhe | só limites (máximo/mínimo) | tipo de nó (`cache.t4g.micro`…), quantidade, réplicas |
| Escala | sozinho, em segundos | manual (trocar o nó / adicionar shards) |
| Alta disponibilidade | já vem (dados replicados em várias AZs) | você configura réplicas e Multi-AZ |
| Cobrança | por **GB armazenado/hora** + **ECPU** | por hora de cada nó |
| Recurso no OpenTofu | `aws_elasticache_serverless_cache` | `aws_elasticache_replication_group` / `aws_elasticache_cluster` |

- **ECPU (ElastiCache Processing Unit):** a "moeda" de processamento do serverless. Grosso modo, **1 ECPU = 1 KB lido ou gravado** por um comando simples (um `GET` de 3,2 KB consome 3,2 ECPUs).

## O que foi criado

```
modules/elasticache/
├── main.tofu            ← aws_elasticache_serverless_cache.main
├── security_group.tofu  ← aws_security_group.main (object + dynamic, igual ao ec2/rds)
├── variables.tofu       ← inputs (nome, engine, versão, limites, snapshots, subnets, SG, tags)
└── outputs.tofu         ← endpoint, reader endpoint, arn, status, id do SG

envs/dev/  e  envs/prod/
├── elasticache.tofu     ← module "elasticache" { source = "../../modules/elasticache" }
├── variables.tofu       ← + 8 variáveis elasticache_*
├── local.tofu           ← + local.cache_security_group_config (default do SG)
└── outputs.tofu         ← + 5 outputs elasticache_*
```

São **2 recursos** por ambiente: o cache e o security group dele. O `plan` do dev passou de 39 para **41 to add**.

Ordem em que o OpenTofu cria (ele deduz pelas referências):

```
module.vpc (VPC + subnets management)
        │
        ▼
aws_security_group.main  ──(id)──►  aws_elasticache_serverless_cache.main
```

## Passo 1: o security group

`modules/elasticache/security_group.tofu` repete o padrão dos módulos `ec2` e `rds` (docs 20, 23, 26): o SG inteiro chega como **um `object`** e as regras viram blocos com `dynamic`.

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
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  dynamic "egress" { ... }   # mesmo formato

  lifecycle {
    create_before_destroy = true
  }
}
```

As regras vêm do env (`local.cache_security_group_config`):

| Regra | Valor | Por quê |
|-------|-------|---------|
| Entrada | TCP **6379** de `var.vpc_cidr_block` (`172.25.0.0/16` no dev) | 6379 é a porta padrão do Redis/Valkey; só quem está dentro da VPC alcança |
| Saída | tudo para `0.0.0.0/0` | herdado do padrão dos outros SGs (ver [ponto 5](#5-security-group-vpc-inteira-egress-sem-uso-e-nome-fixo)) |

## Passo 2: o cache serverless

`modules/elasticache/main.tofu`:

```hcl
resource "aws_elasticache_serverless_cache" "main" {
  name        = var.cache_name          # development-algadelivery-valkey
  engine      = var.engine              # "valkey"
  description = var.description

  major_engine_version = var.major_engine_version   # "8" (vindo do env)

  cache_usage_limits {
    data_storage {
      maximum = var.data_storage_maximum   # 5
      minimum = var.data_storage_minimum   # 1
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = var.ecpu_per_second_maximum   # 5000
      minimum = var.ecpu_per_second_minimum   # 1000
    }
  }

  subnet_ids         = var.subnet_ids                     # as 3 subnets management
  security_group_ids = [aws_security_group.main.id]

  snapshot_retention_limit = var.snapshot_retention_limit  # 0 = sem snapshot automático
  daily_snapshot_time      = var.daily_snapshot_time       # null

  tags = merge(var.common_tags, { Name = var.cache_name })

  lifecycle {
    prevent_destroy = true
  }
}
```

O porquê de cada argumento:

| Argumento | O que faz | Detalhe |
|-----------|-----------|---------|
| `name` | Identificador do cache na conta/região | Único por região: o prefixo `${var.environment}` evita colisão entre dev e prod ✅ |
| `engine` | `valkey`, `redis` ou `memcached` | |
| `major_engine_version` | Só a versão **major** (`"8"`) | A AWS aplica as minors sozinha (8.0 → 8.1 → 8.2) **sem janela de manutenção** e sem downtime: no serverless não existe `maintenance_window`. Versões Valkey na AWS hoje: 7.2, 8.0–8.2, 9.0, 9.1 |
| `cache_usage_limits.data_storage` | Faixa de memória (GB) | **`maximum`:** teto de custo; ao atingir, o cache começa a remover chaves (*evict*) ou recusa gravações (`Out of Memory`). **`minimum`:** reserva (pre-scaling) e **é cobrado sempre** (ver [ponto 2](#2--custo-os-mínimos-são-cobrados-mesmo-parado)) |
| `cache_usage_limits.ecpu_per_second` | Faixa de processamento | Ao atingir o `maximum`, os comandos sofrem *throttling*. O `minimum` (≥ 1000) também é cobrado sempre |
| `subnet_ids` | Onde o cache tem endpoints | Precisa de subnets em **2 ou mais AZs**; o projeto passa as 3 `management` (a, b, c) |
| `security_group_ids` | Firewall | O SG do passo 1 |
| `snapshot_retention_limit` | Dias de snapshot automático | `0` desliga. Máximo 35 |
| `daily_snapshot_time` | Hora do snapshot, **em UTC** (`"05:00"`) | Igual ao `backup_window` do RDS (doc 26, passo 4b). `null` = a AWS escolhe |
| `prevent_destroy` | Impede o `destroy` | ⚠️ fixo em `true` (ver [ponto 1](#1--prevent_destroy--true-fixo-o-destroy-do-dev-volta-a-falhar)) |

O que o serverless já faz **sem argumento nenhum**:

- **Criptografia em trânsito (TLS) obrigatória** e criptografia em repouso (chave da AWS; `kms_key_id` troca por uma sua).
- Dados replicados em várias AZs, com failover automático.
- Um **endpoint de leitura** (`reader_endpoint`) que lê das réplicas (*read from replica*).

### Por que as subnets `management`?

O RDS ficou nas subnets `database` (doc 26). O cache foi para as `management`. As duas escolhas funcionam, porque a rota `local` liga todas as subnets da VPC. É uma decisão de organização:

- `database` = camada de dados persistentes (RDS);
- `management` = serviços de apoio.

Muitos projetos põem o cache junto do banco (camada de dados). O importante é que seja uma subnet **privada** ✅ e que o SG controle quem acessa.

## Passo 3: a chamada no ambiente

`envs/dev/elasticache.tofu`:

```hcl
module "elasticache" {
  source = "../../modules/elasticache"

  cache_name           = "${var.environment}-${local.context_name}-valkey"
  engine               = "valkey"
  major_engine_version = var.elasticache_major_engine_version
  description          = "ElastiCache Serverless Valkey for ${local.context_name}"

  data_storage_maximum    = var.elasticache_data_storage_maximum
  data_storage_minimum    = var.elasticache_data_storage_minimum
  ecpu_per_second_maximum = var.elasticache_ecpu_per_second_maximum
  ecpu_per_second_minimum = var.elasticache_ecpu_per_second_minimum

  snapshot_retention_limit = var.elasticache_snapshot_retention_limit
  daily_snapshot_time      = var.elasticache_daily_snapshot_time

  subnet_ids            = module.vpc.subnet_pvt_ids["management"]   # output de outro módulo
  vpc_id                = module.vpc.vpc_id
  security_group_config = local.cache_security_group_config
  common_tags           = local.common_tags
}
```

- **Output de um módulo vira input de outro:** `module.vpc.subnet_pvt_ids["management"]` é o mapa agrupado do doc 22 (`{ management = [id_a, id_b, id_c], ... }`); o `["management"]` pega a lista, que bate com o `type = list(string)` do input `subnet_ids`.
- **Variáveis do env** (`envs/dev/variables.tofu`):

| Variável | Default | Vai para |
|----------|---------|----------|
| `elasticache_major_engine_version` | `"8"` | `major_engine_version` |
| `elasticache_data_storage_maximum` / `_minimum` | `5` / `1` (GB) | `data_storage` |
| `elasticache_ecpu_per_second_maximum` / `_minimum` | `5000` / `1000` | `ecpu_per_second` |
| `elasticache_snapshot_retention_limit` | `0` | snapshots desligados |
| `elasticache_daily_snapshot_time` | `null` | |
| `elasticache_security_group_config` | `null` | ver abaixo |

### Padrão novo: default "inteligente" com `!= null`

Em `envs/dev/local.tofu`:

```hcl
cache_security_group_config = var.elasticache_security_group_config != null ? var.elasticache_security_group_config : {
  name        = "${var.environment}-${local.context_name}-valkey-sg"
  description = "Security group for ElastiCache Serverless Valkey in ${var.environment}"
  ingress_rules = [{ description = "Valkey da VPC", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = [var.vpc_cidr_block] }]
  egress_rules  = [{ description = "Todo o trafego de saida", from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = [local.internet_cidr_block] }]
}
```

Lendo em português: "se alguém passou um SG na variável, use; senão, monte um padrão".

**Por que não colocar o padrão direto no `default` da variável?** Porque o `default` de uma variável precisa ser um **valor fixo**: ele não pode usar `var.environment`, `var.vpc_cidr_block` nem `local.*`. O truque é deixar o `default = null` e montar o valor no `local`, onde expressões são permitidas.

| Onde | Pode usar outras variáveis/locals? |
|------|------------------------------------|
| `variable { default = ... }` | ❌ só valor literal |
| `locals { ... }` | ✅ qualquer expressão |

Funciona como o operador ternário do doc 18: `condição ? valor_se_verdadeiro : valor_se_falso`.

## Passo 4: os outputs

`modules/elasticache/outputs.tofu` expõe 7 valores; o env repassa 5 (`elasticache_endpoint_address`, `_endpoint_port`, `_reader_endpoint_address`, `elasticache_arn`, `security_group_elasticache_id`).

```hcl
output "endpoint_address" {
  value = aws_elasticache_serverless_cache.main.endpoint[0].address
}
```

**Por que o `[0]`?** No provider, `endpoint` é uma **lista de objetos** (com um item só). O `[0]` pega o primeiro item e o `.address`, o campo dele. O mesmo vale para `reader_endpoint[0]`.

`reader_endpoint_port` e `status` existem no módulo, mas o env não os repassa (dá para acrescentar se precisar).

## O plan real (dev)

```
  # module.elasticache.aws_elasticache_serverless_cache.main will be created
  + resource "aws_elasticache_serverless_cache" "main" {
      + endpoint                 = (known after apply)
      + engine                   = "valkey"
      + major_engine_version     = "8"
      + name                     = "development-algadelivery-valkey"
      + reader_endpoint          = (known after apply)
      + snapshot_retention_limit = 0
      + subnet_ids               = [ (known after apply), (known after apply), (known after apply) ]
      + cache_usage_limits {
          + data_storage    { maximum = 5, minimum = 1, unit = "GB" }
          + ecpu_per_second { maximum = 5000, minimum = 1000 }
        }
    }
  # module.elasticache.aws_security_group.main will be created

Plan: 41 to add, 0 to change, 0 to destroy.
```

(Trecho resumido.) O `endpoint` só aparece depois do apply, porque a AWS gera o endereço.

## Como conectar (depois do apply)

O cache está numa subnet **privada**: da sua máquina não dá para acessar direto. O caminho é o mesmo do RDS, pelo bastion (que está dentro da VPC e, portanto, liberado pelo SG da 6379):

```bash
cd envs/dev
tofu output -raw elasticache_endpoint_address
# development-algadelivery-valkey-xxxxxx.serverless.use1.cache.amazonaws.com

# Opção A: rodar o cliente no bastion
ssh -i development-algadelivery-bastion.pem ubuntu@ELASTIC_IP
sudo apt install -y redis-tools            # o redis-cli fala com o Valkey
redis-cli --tls -h <endpoint> -p 6379 PING # → PONG

# Opção B: túnel SSH e cliente na sua máquina
ssh -i development-algadelivery-bastion.pem -N -L 6379:<endpoint>:6379 ubuntu@ELASTIC_IP
redis-cli --tls -h localhost -p 6379 --insecure PING   # --insecure: o certificado é do endpoint, não do localhost
```

> ⚠️ **Sem `--tls` a conexão trava ou cai:** no serverless o TLS é obrigatório. Na aplicação, use `rediss://` (com dois "s") na URL de conexão.

Teste rápido:

```
SET pedido:42:status "saiu para entrega"
GET pedido:42:status
EXPIRE pedido:42:status 60      # some sozinho em 60 s (cache!)
```

## Custos

Preços on-demand em `us-east-1` (consultados na AWS Price List API):

| Item | Preço Valkey Serverless |
|------|-------------------------|
| Dados armazenados | US$ 0,084 por GB-hora (mínimo cobrado: **100 MB**) |
| Processamento | US$ 0,0023 por **milhão** de ECPUs |
| Snapshots | US$ 0,085 por GB-mês |

Com os valores do projeto (**`minimum` = 1 GB e 1000 ECPU/s**), o cache cobra o mínimo **mesmo sem uso**:

```
storage: 1 GB × 0,084 × 730 h                  ≈ US$ 61/mês
ECPU:    1000/s × 3600 × 730 h = 2.628 milhões × 0,0023 ≈ US$  6/mês
                                                 ───────────────
                                                 ≈ US$ 67/mês por ambiente
```

**Sem os mínimos** (deixando a AWS escalar do zero), um cache de estudo parado cobra só os 100 MB: 0,1 × 0,084 × 730 ≈ **US$ 6/mês**, mais o uso real de ECPU (centavos).

> 💲 Hoje o cache vira o **2º item mais caro** do ambiente, atrás só do NAT. Ver [ponto 2](#2--custo-os-mínimos-são-cobrados-mesmo-parado).

## Validação (feita só com leitura)

| Checagem | Resultado |
|----------|-----------|
| `tofu validate` (dev) | ✅ |
| `tofu plan` (dev) | ✅ **41 to add** (39 de antes + cache + SG); dev continua destruído, nada foi aplicado |
| Versões Valkey na AWS (`describe-cache-engine-versions`) | 7.2, 8.0, 8.1, 8.2, 9.0, 9.1 → a `"8"` do env existe ✅ |
| Caches serverless existentes na conta | nenhum (não há conflito de nome) |
| `tofu fmt -check` | ✅ arquivos novos ok · continuam pendentes `modules/ec2/main.tofu`, `modules/rds/variables.tofu`, `envs/prod/local.tofu`, `envs/prod/variables.tofu` |
| prod | ⏸️ precisa de `tofu init -reconfigure` (agora também para instalar o `module "elasticache"`) |

## ⚠️ Pontos de atenção

Os snippets abaixo foram testados numa cópia do módulo (`tofu validate` + `tofu plan`, sem aplicar nada).

### 1. 🔴 `prevent_destroy = true` fixo: o `destroy` do dev volta a falhar

É a mesma lição do doc 25: o módulo `ec2` teve `prevent_destroy = true` e o `tofu destroy` do dev parou de funcionar até ele virar `false`. Agora o cache traz o problema de volta, e **num recurso que custa ~US$ 67/mês**:

```
Error: Resource instance cannot be destroyed

Resource instance module.elasticache.aws_elasticache_serverless_cache.main has
prevent_destroy set, but the plan calls for it to be destroyed.
```

Solução (OpenTofu aceita variável no `prevent_destroy`, [doc 25](25-lifecycle.md#prevent_destroy-por-ambiente-com-variável)):

```hcl
# modules/elasticache/variables.tofu
variable "prevent_destroy" {
  description = "Protege o cache contra destroy (true no prod, false no dev)"
  type        = bool
  default     = true
}

# modules/elasticache/main.tofu
lifecycle {
  prevent_destroy = var.prevent_destroy
}

# envs/dev/elasticache.tofu
prevent_destroy = false
```

> Para um **cache**, o `prevent_destroy` protege pouco: os dados são reconstruíveis a partir do banco. No dev, `false` é o natural.

### 2. 💲 Custo: os mínimos são cobrados mesmo parado

`minimum` serve para **pré-aquecer** o cache antes de um pico (ex.: lançamento com 5× mais acessos). Fora disso, só gera custo. Deixe os mínimos como opcionais (`null` = sem mínimo):

```hcl
# modules/elasticache/variables.tofu
variable "data_storage_minimum" {
  description = "Minimum data storage limit in GB (null = sem minimo)"
  type        = number
  default     = null
}

variable "ecpu_per_second_minimum" {
  description = "Minimum number of ECPUs per second (null = sem minimo)"
  type        = number
  default     = null
}
```

O `main.tofu` não muda: um argumento `null` é tratado como "não informado" (testado: o plan mostra `minimum = (known after apply)`, e a AWS não reserva nada). No env, tire as linhas `*_minimum` ou passe `null` no dev.

### 3. Versão: módulo `"9"` x env `"8"`

O default do módulo é `"9"` e o dos envs é `"8"`. Funciona (os envs sempre passam o valor), mas confunde: quem chamar o módulo sem a variável ganha outra versão. Alinhe os dois e, se quiser, valide:

```hcl
variable "major_engine_version" {
  type    = string
  default = "8"

  validation {
    condition     = contains(["7", "8", "9"], var.major_engine_version)
    error_message = "Use uma versao major do Valkey suportada: 7, 8 ou 9."
  }
}
```

(Testado: `"10"` é recusado com `Invalid value for variable`.) Trocar a major depois (8 → 9) é uma atualização feita pela AWS sem recriar o cache, mas **voltar** de 9 para 8 não é possível.

### 4. Sem autenticação: só a rede protege

Sem `user_group_id`, o cache aceita o usuário `default` **sem senha**: quem alcançar a porta 6379 lê e grava tudo. Hoje isso significa "qualquer coisa dentro da VPC". Para melhorar:

- restringir o SG (ponto 5);
- criar usuários com senha/IAM (`aws_elasticache_user` + `aws_elasticache_user_group`) e passar `user_group_id` no cache.

Para o estudo, a proteção pela rede (subnet privada + SG) é aceitável.

### 5. Security group: VPC inteira, egress sem uso e nome fixo

- **Entrada da VPC inteira** (`172.25.0.0/16`): basta liberar quem usa o cache. Referenciar o **SG de origem** é mais preciso que um CIDR:

```hcl
# no type do object (variables.tofu): campos opcionais
cidr_blocks               = optional(list(string), [])
source_security_group_ids = optional(list(string), [])

# no dynamic "ingress" (security_group.tofu)
cidr_blocks     = ingress.value.cidr_blocks
security_groups = ingress.value.source_security_group_ids

# no env: só o bastion (e, no futuro, a aplicação)
{
  description               = "Valkey do bastion"
  from_port                 = 6379
  to_port                   = 6379
  protocol                  = "tcp"
  source_security_group_ids = [module.bastion.security_group_id]
}
```

  (O módulo `ec2` já tem o output `security_group_id`.)
- **Egress "tudo":** o cache não inicia conexões, e o SG é stateful (as respostas saem sozinhas, doc 17). A regra pode ser `egress_rules = []`.
- **`name` fixo + `create_before_destroy`:** o mesmo conflito do doc 25 (`InvalidGroup.Duplicate` numa substituição). Use `name_prefix = "${var.security_group_config.name}-"` (testado: o plan gera `development-algadelivery-valkey-sg-<sufixo>`).

### 6. Subnets management x database

O cache foi para `management`, e o RDS para `database`. Não é erro, mas defina uma regra para o projeto ("dados ficam em `database`") e siga nos próximos serviços.

### 7. Snapshots desligados e valores iguais em dev e prod

- `snapshot_retention_limit = 0` é ótimo para cache **puro** (dados reconstruíveis). Se o Valkey guardar algo que não está no banco (sessões, filas), ligue no prod: `snapshot_retention_limit = 7` e `daily_snapshot_time = "05:00"` (UTC = 02:00 em Brasília; escolha um horário fora do backup do RDS, 02–03 UTC).
- **dev e prod têm os mesmos valores** (limites, mínimos, snapshots). O comum: dev sem mínimos e com teto baixo; prod com teto maior e snapshots.

### 8. Repetição entre os envs

`elasticache.tofu`, as 8 variáveis e o `local` foram copiados idênticos para `envs/dev` e `envs/prod`. É a duplicação descrita no doc 24 (ponto 2): toda mudança precisa ser feita nas duas pastas.

## Pegadinhas

- **TLS:** sem `--tls` (ou `rediss://`), a conexão não funciona.
- **Endpoint muda** a cada recriação: leia sempre do `tofu output`, nunca fixe no código da aplicação.
- **Criação demora** alguns minutos (o plan/apply fica em `Still creating...`).
- **`maximum` atingido = evict/erro**, não "cobra mais": é um teto de custo e de desempenho ao mesmo tempo.
- **`minimum` = cobrança fixa**, mesmo sem nenhum acesso.
- **`[0]` nos outputs:** se o cache ainda não existir (plan), o valor fica `(known after apply)`.
- **Mudar `modules/elasticache`** afeta dev e prod no próximo `plan` (doc 24).
