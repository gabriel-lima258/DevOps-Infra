# 26. Módulo RDS: um PostgreSQL gerenciado, passo a passo

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Módulos: [21-modules.md](21-modules.md) · Ambientes: [24-multiplos-ambientes.md](24-multiplos-ambientes.md)

## O que é o RDS

O **Amazon RDS** é um banco de dados **gerenciado**: você escolhe o motor (aqui, PostgreSQL), o tamanho e a rede, e a AWS cuida do resto.

| | PostgreSQL numa EC2 (faça você mesmo) | RDS (gerenciado) |
|---|---|---|
| Instalar e atualizar o PostgreSQL | Você | AWS |
| Backup automático e restauração | Você | AWS (`backup_retention_period`) |
| Patches de segurança do SO | Você | AWS |
| Alta disponibilidade (réplica em outra AZ) | Você monta | `multi_az = true` |
| Acesso ao SO (SSH) | Sim | **Não** (só a porta do banco) |
| Custo | Só a EC2 | Um pouco mais caro |

As subnets do grupo **`database`** (`172.25.10-12.0/24`, doc 22) foram criadas pensando nisso: agora elas recebem o banco.

## O que mudou no código

| Arquivo | O que entrou |
|---------|--------------|
| `modules/rds/main.tofu` (novo) | Subnet group, parameter group e a instância RDS |
| `modules/rds/security_group.tofu` (novo) | SG do banco (mesmo padrão do módulo ec2) |
| `modules/rds/variables.tofu` (novo) | 14 inputs |
| `modules/rds/outputs.tofu` (novo) | ARN do segredo da senha, endpoint, id, arn |
| `envs/{dev,prod}/rds.tofu` (novo) | `module "database"` (a chamada) |
| `envs/{dev,prod}/variables.tofu` | 13 variáveis `db_*` |
| `envs/{dev,prod}/local.tofu` | `db_security_group_config` (padrão) e `db_port = 5432` |
| `envs/{dev,prod}/outputs.tofu` | Repasse dos 4 outputs do banco |
| `envs/dev/providers.tofu` | Provider `hashicorp/random` (⚠️ sem uso, ver a revisão) |

## As 4 peças e a ordem de criação

Um RDS não é um recurso só. O módulo cria 4, e as referências definem a ordem:

```
module.vpc.subnet_pvt_ids["database"] ──► 1. aws_db_subnet_group  ──┐
                                          2. aws_db_parameter_group ─┼──► 4. aws_db_instance
module.vpc.vpc_id ──────────────────────► 3. aws_security_group  ───┘
```

### Passo 1: subnet group (onde o banco pode morar)

```hcl
resource "aws_db_subnet_group" "main" {
  name       = var.db_subnet_group_name             # "algadelivery-db-subnet-group"
  subnet_ids = var.db_subnet_ids                    # as 3 subnets "database"
  tags       = merge(var.common_tags, { Name = var.db_subnet_group_name })
}
```

- O RDS não recebe um `subnet_id` como a EC2. Ele recebe um **grupo de subnets** e escolhe em qual delas fica.
- A AWS exige subnets em **pelo menos 2 AZs**. O grupo `database` tem 3 (a, b, c) ✅. Isso também permite, no futuro, ligar o `multi_az` (a réplica vai para outra AZ).
- A lista vem do módulo VPC: `module.vpc.subnet_pvt_ids["database"]`. É o output agrupado do doc 22 funcionando.

### Passo 2: parameter group (a "configuração" do PostgreSQL)

É o equivalente ao `postgresql.conf` num RDS:

```hcl
resource "aws_db_parameter_group" "main" {
  name   = var.db_parameter_group_name                 # "algadelivery-db-parameter-group"
  family = "${var.db_engine}${var.db_engine_version}"  # "postgres" + "18" = "postgres18"

  dynamic "parameter" {
    for_each = var.db_parameter_group_options          # map(string)
    content {
      name         = parameter.key                     # a CHAVE do mapa
      value        = parameter.value                   # o VALOR do mapa
      apply_method = "pending-reboot"
    }
  }
}
```

Os parâmetros vêm da variável do ambiente:

```hcl
db_parameter_group_options = {
  max_connections          = "300"
  shared_preload_libraries = "pg_stat_statements,pgaudit"
}
```

| Parâmetro | O que faz |
|-----------|-----------|
| `max_connections = 300` | Máximo de conexões simultâneas. Numa `db.t4g.micro` (1 GB de RAM), 300 é alto: cada conexão consome memória |
| `pg_stat_statements` | Extensão que registra estatísticas das queries (quais são lentas, quantas vezes rodam) |
| `pgaudit` | Extensão de auditoria (registra quem fez o quê) |

Técnicas usadas:

- **`family` montado por interpolação:** `"${var.db_engine}${var.db_engine_version}"` → `"postgres18"`. Conferido na AWS: o PostgreSQL 18 existe no RDS (default `18.3`) e a família é `postgres18` ✅. A família precisa bater com a **versão major** da instância.
- **`dynamic` sobre um mapa** (doc 20): agora com `parameter.key` e `parameter.value`. Cada item do mapa vira um bloco `parameter { }`.
- **`apply_method = "pending-reboot"`:** parâmetros **estáticos** (como os dois acima) só valem depois de reiniciar o banco. Na criação já entram; numa mudança futura, é preciso reiniciar a instância. Parâmetros **dinâmicos** aceitariam `"immediate"`.

### Passo 3: o Security Group do banco (porta 5432)

O módulo `rds` repete o padrão do `ec2` (doc 23): o SG chega como um `object` e as regras viram `dynamic`. O padrão vem do `local.tofu` do ambiente:

```hcl
db_security_group_config = var.db_security_group_config != null ? var.db_security_group_config : {
  name        = "${var.environment}-${local.context_name}-db-sg"     # "development-algadelivery-db-sg"
  description = "Security group for DB instance"
  ingress_rules = [
    {
      description = "PostgreSQL para VPC"
      from_port   = local.db_port                                   # 5432
      to_port     = local.db_port
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]                            # toda a VPC
    }
  ]
  egress_rules = [ { ... saída liberada ... } ]
}

db_port = 5432
```

- Só a porta do PostgreSQL entra, e só de dentro da VPC. Ninguém da internet chega no banco (ele está em subnet privada e `publicly_accessible` é `false` por padrão).

### Passo 4: a instância

```hcl
resource "aws_db_instance" "main" {
  identifier        = var.db_identifier        # "development-algadelivery-db"
  db_name           = var.db_name              # "delivery"
  engine            = var.db_engine            # "postgres"
  engine_version    = var.db_engine_version    # "18"
  instance_class    = var.db_instance_class    # "db.t4g.micro"
  allocated_storage = var.db_storage           # 20 (GB)

  username                    = var.db_username   # "postgres"
  manage_master_user_password = true
  port                        = var.db_port       # 5432

  parameter_group_name   = aws_db_parameter_group.main.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.main.id]

  multi_az            = false
  skip_final_snapshot = var.db_skip_final_snapshot   # true
  apply_immediately   = true
}
```

| Argumento | Valor | Por quê |
|-----------|-------|---------|
| `identifier` | `development-algadelivery-db` | Nome da instância na AWS (único por conta/região). Tem o ambiente no nome ✅ |
| `db_name` | `delivery` | O banco criado dentro do PostgreSQL |
| `engine` / `engine_version` | `postgres` / `18` | Com só o major (`18`), a AWS escolhe o minor padrão (`18.3`) |
| `instance_class` | `db.t4g.micro` | A menor e mais barata (Graviton/ARM, 2 vCPU, 1 GB) |
| `allocated_storage` | `20` | GB de disco |
| `username` | `postgres` | Usuário administrador |
| `manage_master_user_password = true` | — | **A AWS gera a senha e guarda no Secrets Manager.** A senha não aparece no código nem no state ✅ |
| `port` | `5432` | Porta padrão do PostgreSQL |
| `parameter_group_name` / `db_subnet_group_name` / `vpc_security_group_ids` | referências | Ligam as peças dos passos 1–3 (e definem a ordem de criação) |
| `multi_az = false` | — | Uma instância só, numa AZ. Mais barato; sem failover automático |
| `skip_final_snapshot = true` | — | No `destroy`, **não** faz um backup final. Ok para estudo; perigoso em produção |
| `apply_immediately = true` | — | Mudanças são aplicadas na hora, e não na próxima janela de manutenção (pode reiniciar o banco) |

Padrões que ficaram implícitos (não aparecem no código):

| Argumento | Padrão | Comentário |
|-----------|--------|------------|
| `publicly_accessible` | `false` | ✅ O banco não ganha IP público |
| `storage_encrypted` | `false` | ⚠️ Disco **sem** criptografia |
| `deletion_protection` | `false` | ⚠️ Pode ser apagado sem trava |

### Passo 4b: backup automático e janela de manutenção

Configurado depois, em `modules/rds/main.tofu`:

```hcl
resource "aws_db_instance" "main" {
  # ...
  backup_retention_period = var.db_backup_retention_period   # "10"
  backup_window           = var.db_backup_window             # "02:00-03:00"
  maintenance_window      = var.db_maintenance_window        # "Mon:03:00-Mon:04:00"
  # ...
}
```

Os valores vêm do ambiente (`envs/<env>/variables.tofu`) e passam pela chamada (`envs/<env>/rds.tofu`), no mesmo caminho dos outros inputs:

```
envs/dev/variables.tofu  ──►  envs/dev/rds.tofu (module "database")  ──►  modules/rds/variables.tofu  ──►  aws_db_instance
   default = "10"                db_backup_retention_period = var...        variable "db_backup_..."         backup_retention_period
```

#### O que é o backup automático

Com `backup_retention_period` maior que 0, a AWS faz **sozinha**:

1. **Um snapshot por dia**, dentro da `backup_window`.
2. **Cópia contínua dos logs de transação** (a cada ~5 minutos).

Juntos, eles permitem o **point-in-time restore**: restaurar o banco como ele estava em **qualquer segundo** dos últimos N dias (até ~5 minutos atrás).

| `backup_retention_period` | Efeito |
|---------------------------|--------|
| `0` | Backup automático **desligado** (e sem point-in-time restore, nem réplicas de leitura) |
| `1` a `35` | Guarda os backups por N dias |
| **`10`** (projeto) | Dá para voltar a qualquer momento dos últimos 10 dias |

💲 O armazenamento de backup é **grátis até o tamanho do banco** (20 GB aqui). Acima disso, é cobrado por GB.

#### `backup_window`: quando o snapshot diário roda

- Formato `hh24:mi-hh24:mi`, **em UTC**, com no mínimo 30 minutos.
- `02:00-03:00` UTC = **23:00–00:00 no horário de Brasília** (UTC−3).
- Durante o snapshot, numa instância **Single-AZ** (`multi_az = false`, o caso do projeto), o I/O pode ficar lento por alguns instantes. Por isso se escolhe a madrugada do público do sistema.

#### `maintenance_window`: quando a AWS pode mexer no banco

- Formato `ddd:hh24:mi-ddd:hh24:mi`, **em UTC**, com no mínimo 30 minutos.
- `Mon:03:00-Mon:04:00` UTC = **domingo 00:00–01:00 em Brasília**.
- No `plan`, o provider mostra o dia em minúsculas (`"mon:03:00-mon:04:00"`). É só normalização, não é um diff.

O que acontece nessa janela:

- patches do sistema operacional e do PostgreSQL;
- atualização de **versão minor** automática (`auto_minor_version_upgrade`, ligado por padrão): por exemplo, `18.3` → `18.4`;
- mudanças que você deixou **pendentes** (feitas sem `apply_immediately`).

> **Interação com `apply_immediately = true` (passo 4):** as mudanças feitas pelo `tofu apply` **não** esperam a janela; são aplicadas na hora, às vezes com reinício. A janela continua valendo para os patches e upgrades **da AWS**.

#### Regra: as duas janelas não podem se sobrepor

A AWS rejeita uma configuração em que o backup cai dentro da manutenção:

```
                          00:00   01:00   02:00   03:00   04:00   (UTC, segunda)
Ambientes (dev e prod):
  backup_window                           [==02-03==]
  maintenance_window (Mon)                          [==03-04==]   ✅ encostam, mas não se sobrepõem

Defaults do MÓDULO (modules/rds/variables.tofu):
  backup_window                                   [==03-04==]
  maintenance_window (Mon)                [=====02-04=====]       ❌ sobreposição
```

Os **defaults do módulo** (`"03:00-04:00"` e `"Mon:02:00-Mon:04:00"`) se sobrepõem. Hoje isso não quebra, porque os dois ambientes passam valores próprios. Mas quem usar o módulo **sem** passar esses inputs vai receber erro da AWS no apply.

#### No `plan`

```
  # module.database.aws_db_instance.main will be created
      + backup_retention_period = 10
      + backup_window           = "02:00-03:00"
      + maintenance_window      = "mon:03:00-mon:04:00"
```

Repare: a variável é `"10"` (texto), e o plan mostra `10` (número). O OpenTofu converte sozinho (ver as melhorias abaixo).

#### Restaurar e consultar backups

```bash
# backups automáticos existentes
aws rds describe-db-snapshots --db-instance-identifier development-algadelivery-db --snapshot-type automated

# point-in-time restore: cria uma INSTÂNCIA NOVA (a original continua lá)
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier development-algadelivery-db \
  --target-db-instance-identifier development-algadelivery-db-restore \
  --restore-time 2026-10-23T12:00:00Z
```

O restore **sempre cria outra instância**, que fica fora do state do OpenTofu. Depois de conferir os dados, você decide: apontar a aplicação para ela (e importar no state, doc 08) ou só copiar os dados de volta.

#### Melhorias para o backup e a manutenção

1. **`type = number` na retenção.** Hoje é `type = string` com `"10"`. Funciona porque o OpenTofu converte, mas o tipo certo documenta melhor e permite validar o intervalo.
2. **Corrigir os defaults do módulo** para não se sobreporem (ex.: backup `02:00-03:00`, manutenção `Mon:03:00-Mon:04:00`).
3. **Validar o formato** (testado: aceita os valores do projeto e recusa `40`, `2:00-3:00` e `Segunda:03:00` com `Invalid value for variable`):
   ```hcl
   variable "db_backup_retention_period" {
     type    = number
     default = 7
     validation {
       condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
       error_message = "A retencao de backup deve ficar entre 0 e 35 dias."
     }
   }

   variable "db_backup_window" {
     type    = string
     default = "02:00-03:00"
     validation {
       condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$", var.db_backup_window))
       error_message = "Use o formato hh24:mi-hh24:mi (UTC), ex.: 02:00-03:00."
     }
   }

   variable "db_maintenance_window" {
     type    = string
     default = "Mon:03:00-Mon:04:00"
     validation {
       condition     = can(regex("^(?i)(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]$", var.db_maintenance_window))
       error_message = "Use o formato ddd:hh24:mi-ddd:hh24:mi (UTC), ex.: Mon:03:00-Mon:04:00."
     }
   }
   ```
   A sobreposição entre as duas janelas não é checada por essas regex. Ela continua sendo verificada pela AWS no apply.
4. **Valores diferentes por ambiente.** Hoje dev e prod usam os mesmos `10` dias e as mesmas janelas. É comum dev com 1–3 dias (mais barato) e prod com 7–35, com as janelas de prod no horário de menor uso real.
5. **`copy_tags_to_snapshot = true`**: os snapshots herdam as tags (`Environment`, `ManagedBy`), o que ajuda a achar e a ratear custos.
6. **Atenção ao `destroy`:** com `skip_final_snapshot = true`, o `destroy` apaga o banco **sem** snapshot final, e os backups automáticos também vão embora junto (padrão `delete_automated_backups = true`). Os "10 dias de backup" **não sobrevivem** a um `tofu destroy`. Em prod: `skip_final_snapshot = false` (com `final_snapshot_identifier`) e/ou `delete_automated_backups = false`.

### Passo 5: a chamada no ambiente (`envs/dev/rds.tofu`)

```hcl
module "database" {
  source = "../../modules/rds"

  db_name                = var.db_name
  db_identifier          = "${var.environment}-${var.db_identifier}"
  db_engine              = var.db_engine
  db_engine_version      = var.db_engine_version
  db_instance_class      = var.db_instance_class
  db_username            = var.db_username
  db_storage             = var.db_storage
  db_skip_final_snapshot = var.db_skip_final_snapshot
  db_port                = local.db_port

  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.subnet_pvt_ids["database"]
  db_subnet_group_name  = var.db_subnet_group_name
  security_group_config = local.db_security_group_config

  db_parameter_group_name    = var.db_parameter_group_name
  db_parameter_group_options = var.db_parameter_group_options

  common_tags = merge(local.common_tags, {
    "Name" = "${var.environment}-${var.db_identifier}"
  })
}
```

De onde vem cada input:

| Origem | Inputs |
|--------|--------|
| **Variável do ambiente** (`variables.tofu`) | `db_name`, `db_engine`, `db_engine_version`, `db_instance_class`, `db_username`, `db_storage`, `db_skip_final_snapshot`, `db_subnet_group_name`, `db_parameter_group_name`, `db_parameter_group_options` |
| **Local** (`local.tofu`) | `db_port`, `security_group_config`, `common_tags` |
| **Output de outro módulo** | `vpc_id` e `db_subnet_ids` (de `module.vpc`) |
| **Interpolação** | `db_identifier` = ambiente + nome |

Repare como os **módulos se conectam**: o `vpc` entrega as subnets do grupo `database`, e o `rds` as consome. Nenhum dos dois conhece o código do outro, só os outputs e inputs.

### Passo 6: os outputs e como usar o banco

```hcl
# modules/rds/outputs.tofu (repassados em envs/<env>/outputs.tofu)
output "db_password_secret_arn" { value = aws_db_instance.main.master_user_secret[0].secret_arn }
output "db_endpoint"            { value = aws_db_instance.main.endpoint }        # "host:5432"
output "db_instance_id"         { value = aws_db_instance.main.id }
output "db_instance_arn"        { value = aws_db_instance.main.arn }
```

**Pegar a senha** (ela está no Secrets Manager, não no state):

```bash
cd envs/dev && source ../../.env
aws secretsmanager get-secret-value \
  --secret-id "$(tofu output -raw db_password_secret_arn)" \
  --query SecretString --output text
# {"username":"postgres","password":"..."}
```

**Conectar pela sua máquina, passando pelo bastion** (o banco é privado):

```bash
DB_HOST=$(tofu output -raw db_endpoint | cut -d: -f1)    # tira o ":5432"
ssh -i development-algadelivery-bastion.pem \
    -L 5432:$DB_HOST:5432 \
    ubuntu@$(tofu output -raw bastion_public_ip) -N      # túnel: localhost:5432 → banco

# em outro terminal
psql -h localhost -p 5432 -U postgres -d delivery
```

O túnel funciona porque o bastion está **dentro da VPC**, e o SG do banco aceita a 5432 de qualquer IP da VPC.

## No `plan` (envs/dev)

Saída real (resumida):

```
  # module.database.aws_db_subnet_group.main will be created
      + name = "algadelivery-db-subnet-group"
  # module.database.aws_db_parameter_group.main will be created
      + family = "postgres18"
      + name   = "algadelivery-db-parameter-group"
      + parameter { + apply_method = "pending-reboot", + name = "max_connections", ... }
      + parameter { + apply_method = "pending-reboot", + name = "shared_preload_libraries", ... }
  # module.database.aws_security_group.main will be created
      + name = "development-algadelivery-db-sg"
  # module.database.aws_db_instance.main will be created
      + identifier                  = "development-algadelivery-db"
      + engine_version              = "18"
      + manage_master_user_password = true
      + multi_az                    = false
      + publicly_accessible         = false
      + skip_final_snapshot         = true
      + tags = { "Name" = "algadelivery-db-parameter-group", ... }   ⚠️

Plan: 4 to add, 0 to change, 0 to destroy.
```

> O mesmo plan mostra `module.bastion.aws_instance.main has changed` (o `public_ip`). É só informativo: o IP automático foi trocado pelo Elastic IP (doc 19).

## Validação

| Ambiente | Resultado |
|----------|-----------|
| **dev** | `tofu validate` ✅. Na primeira análise o `plan` deu 4 to add. **Depois o dev foi destruído** (state vazio; na AWS não sobrou VPC, NAT nem RDS): hoje o `plan` mostra **39 to add** (rede + bastion + banco) |
| **prod** | ❌ `Error: Module not installed` (`module "database"`). Rode `tofu init -reconfigure` (doc 24) |
| `tofu fmt -check -recursive` | ❌ `modules/ec2/main.tofu`, `modules/rds/variables.tofu`, `envs/prod/local.tofu`, `envs/prod/variables.tofu` |

## 🔍 Revisão: o que ajustar

### 1. 🔴 Nomes sem o ambiente: o prod vai colidir com o dev

| Recurso | Nome | Único em | dev × prod |
|---------|------|----------|------------|
| Instância | `${env}-algadelivery-db` | conta/região | ✅ diferentes |
| SG | `${env}-algadelivery-db-sg` | VPC | ✅ diferentes |
| Subnet group | `algadelivery-db-subnet-group` | **conta/região** | 🔴 **iguais** |
| Parameter group | `algadelivery-db-parameter-group` | **conta/região** | 🔴 **iguais** |

Dev e prod estão na mesma conta e região. O apply do **segundo** ambiente vai falhar (`DBSubnetGroupAlreadyExists` / `DBParameterGroupAlreadyExists`). Correção na chamada, nos dois envs:

```hcl
db_subnet_group_name    = "${var.environment}-${var.db_subnet_group_name}"
db_parameter_group_name = "${var.environment}-${var.db_parameter_group_name}"
```

### 2. ⚠️ Tag `Name` da instância errada

No módulo, a instância usa `Name = var.db_parameter_group_name`, então o banco aparece no console como `algadelivery-db-parameter-group`. O `Name` que a chamada passa em `common_tags` é **sobrescrito** pelo `merge` (o último mapa vence, doc 18). Correção no `aws_db_instance`:

```hcl
tags = merge(var.common_tags, {
  Name = var.db_identifier
})
```

### 3. ⚠️ Variáveis e provider sem uso

- `var.db_multi_az` existe nos envs, mas o módulo fixa `multi_az = false`. Para usá-la: um input `db_multi_az` no módulo + `multi_az = var.db_multi_az`.
- `var.db_port` existe, mas a chamada usa `local.db_port`.
- **Provider `random`** (só em `envs/dev/providers.tofu`): nada usa `random_password`, porque o `manage_master_user_password` já gera a senha. Pode sair (e os envs voltam a ter os mesmos providers).

### 4. 🔐 Segurança e dados

```hcl
resource "aws_db_instance" "main" {
  # ...
  storage_encrypted         = true                       # disco criptografado (KMS padrão da AWS)
  deletion_protection       = var.db_deletion_protection # true em prod
  skip_final_snapshot       = var.db_skip_final_snapshot # false em prod
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.db_identifier}-final"
}
```

- `storage_encrypted` **só pode ser definido na criação**. Ligar depois **recria** o banco. Vale decidir antes do primeiro apply.
- Com `skip_final_snapshot = false`, o `final_snapshot_identifier` é obrigatório.
- **SG por referência, não por CIDR:** hoje qualquer recurso da VPC (inclusive pods do cluster) alcança a 5432. O ideal é aceitar só o SG da aplicação ou do bastion (`security_groups = [...]`), o mesmo ponto do doc 17. Isso exigiria um campo `security_groups` no `object` de regras.

Os trechos dos itens 1–4 foram testados com `tofu validate` numa cópia de `envs/dev`.

### 5. `create_before_destroy` com `name` fixo

O SG do banco repete o caso do doc 25: numa substituição haveria dois SGs com o mesmo nome na mesma VPC. Use `name_prefix`.

### 6. As subnets `database` saem para a internet

Elas usam a route table privada (rota `0.0.0.0/0 → NAT`). O RDS não precisa de saída para a internet. Uma route table só com a rota `local` isolaria o banco (doc 16).

### 7. `pending-reboot` em mudanças futuras

Mudar `max_connections` depois: o `apply` atualiza o parameter group, mas o valor só vale após um reboot (`aws rds reboot-db-instance --db-instance-identifier development-algadelivery-db`).

## Custos 💲

| Item | Preço aproximado (us-east-1) |
|------|------------------------------|
| `db.t4g.micro` | ~US$ 0,016/h (~US$ 12/mês) |
| 20 GB de armazenamento | ~US$ 2–2,50/mês |
| Segredo no Secrets Manager | ~US$ 0,40/mês |
| Backups (10 dias) até o tamanho do banco (20 GB) | sem custo extra; acima disso, por GB |

Somado ao NAT, ao bastion e ao Elastic IP, o dev já passa de US$ 50/mês ligado 24h. O `prevent_destroy` do módulo ec2 hoje está `false`, então o `tofu destroy` funciona (doc 25).

## Pegadinhas

- **Criar um RDS demora** (5–10 minutos, às vezes mais). O `apply` fica esperando: não é travamento.
- **`identifier` não muda sem recriar:** renomear = banco novo (e o velho apagado, com os dados).
- **Upgrade de versão major** (18 → 19) exige `allow_major_version_upgrade = true`, e o `family` do parameter group muda junto (`postgres19`), o que recria o parameter group.
- **Parameter group em uso não pode ser apagado.** Trocar o `name` dele (como na correção 1) cria um novo, troca na instância e só depois apaga o velho; isso pode pedir reboot.
- **`master_user_secret[0]`** só existe com `manage_master_user_password = true`. Se desligar, o output quebra.
- **`db_endpoint` inclui a porta** (`host:5432`). Para o `psql -h`, use só o host (`address`).
- **O banco fica numa AZ só** (`multi_az = false`): se aquela AZ cair, o banco fica fora até ela voltar.
