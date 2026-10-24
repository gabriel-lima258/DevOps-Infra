# 28. Módulo MSK: Kafka Serverless passo a passo

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Módulos: [21-modules.md](21-modules.md) · Módulos irmãos: [26-modulo-rds.md](26-modulo-rds.md), [27-modulo-elasticache.md](27-modulo-elasticache.md)

> 💲💲 **Leia a seção de [custos](#custos) antes do `apply`:** o MSK Serverless custa ~US$ 547/mês por ambiente **só por existir**. É, de longe, o recurso mais caro do projeto.

## Para que serve: mensageria e eventos

Até aqui o projeto tem onde **guardar** dados (RDS) e onde **lembrar rápido** (Valkey). Falta um jeito de os serviços **conversarem sem depender um do outro**.

Sem mensageria, quando um pedido é criado, o serviço de pedidos precisa chamar, um por um, a cozinha, a entrega e as notificações. Se a entrega estiver fora do ar, o pedido falha.

Com mensageria, o serviço de pedidos só **publica um evento** ("pedido 42 criado") e segue a vida. Cada interessado lê o evento no seu ritmo:

```
                         tópico "pedidos"
 serviço de pedidos ──►  [ ev1 | ev2 | ev3 | ev4 ... ]  ──► cozinha       (lê tudo)
     (producer)                                         ──► entrega       (lê tudo)
                                                        ──► notificações  (lê tudo)
                                                             (consumers)
```

Analogia: o **mural de avisos** do restaurante. Quem anota o pedido prende o papel no mural; a cozinha, o entregador e o caixa leem quando puderem. Ninguém precisa esperar ninguém.

| | Fila (ex.: SQS) | Streaming (Kafka) |
|---|---|---|
| A mensagem depois de lida | some | **fica guardada** (por um tempo: a retenção) |
| Vários leitores do mesmo evento | precisa duplicar a fila | nativo: cada grupo lê tudo |
| Reprocessar o passado | ❌ | ✅ volta o "marcador" (offset) |
| Ordem | não garantida (ou FIFO limitada) | garantida **dentro de cada partição** |

## Kafka em 6 conceitos

| Conceito | O que é | Na algadelivery |
|----------|---------|-----------------|
| **Broker** | Um servidor do Kafka | No serverless, você não vê os brokers: a AWS cuida |
| **Tópico** | Um "canal" com nome, onde os eventos são gravados em ordem | `pedidos`, `entregas` |
| **Partição** | Um tópico é dividido em partições para escalar; a ordem é garantida dentro de cada uma | 3 partições = 3 consumers lendo em paralelo |
| **Producer** | Quem publica eventos | serviço de pedidos |
| **Consumer / consumer group** | Quem lê; um *grupo* divide as partições entre seus membros | grupo `cozinha`, grupo `entrega` |
| **Offset** | A posição de leitura de cada grupo ("li até o evento 1520") | permite retomar de onde parou ou reprocessar |

## MSK provisioned x serverless

**MSK** (Amazon Managed Streaming for Apache Kafka) é o Kafka gerenciado da AWS.

| | Provisioned | **Serverless** (o do projeto) |
|---|---|---|
| Você escolhe | tipo e número de brokers, disco, versão do Kafka | nada disso: só rede e autenticação |
| Escala | manual | automática |
| Autenticação | IAM, SCRAM, TLS mútuo ou nenhuma | **só IAM** |
| Cobrança | por hora de broker + disco | por **hora de cluster** + partição + GB |
| Recurso no OpenTofu | `aws_msk_cluster` | `aws_msk_serverless_cluster` |

O serverless tem **cotas** definidas pela AWS (por exemplo, número máximo de partições e throughput de entrada/saída por cluster e por partição). Para estudo e aplicações pequenas elas sobram; consulte a página *MSK Serverless quotas* da AWS antes de usar em produção.

## O que foi criado

```
modules/msk/
├── main.tofu            ← aws_msk_serverless_cluster.main + data "aws_msk_bootstrap_brokers"
├── security_group.tofu  ← aws_security_group.main (object + dynamic, igual aos outros módulos)
├── variables.tofu       ← cluster_name, subnet_ids, vpc_id, security_group_config, common_tags
└── outputs.tofu         ← arn, bootstrap_brokers_sasl_iam, security_group_id

envs/dev/  e  envs/prod/
├── msk.tofu             ← module "msk" { source = "../../modules/msk" }
├── variables.tofu       ← + msk_security_group_config (default null)
├── local.tofu           ← + local.msk_security_group_config (default: 9098 da VPC)
└── outputs.tofu         ← + msk_arn, msk_bootstrap_brokers_sasl_iam, security_group_msk_id

modules/vpc/main.tofu    ← + enable_dns_hostnames = true, enable_dns_support = true
```

São **2 recursos** por ambiente (cluster + SG) e **1 data source**. O `plan` do dev passou de 41 para **43 to add**.

```
module.vpc (VPC com DNS + subnets management)
        │
        ▼
aws_security_group.main ──(id)──► aws_msk_serverless_cluster.main ──(arn)──► data.aws_msk_bootstrap_brokers.main
```

## Passo 1: o security group

`modules/msk/security_group.tofu` é idêntico ao dos módulos `rds` e `elasticache` (object + `dynamic`, docs 20, 26, 27). O que muda é o default montado em `envs/dev/local.tofu`, com o mesmo truque do `!= null` do doc 27:

| Regra | Valor | Por quê |
|-------|-------|---------|
| Entrada | TCP **9098** de `var.vpc_cidr_block` | 9098 é a porta do Kafka com **autenticação IAM sobre TLS** (a única do serverless) |
| Saída | tudo para `0.0.0.0/0` | herdado do padrão; desnecessária (ver [ponto 5](#5-security-group-vpc-inteira-egress-sem-uso-e-nome-fixo)) |

Portas do Kafka na AWS, para referência:

| Porta | Uso |
|-------|-----|
| 9092 | texto puro (sem TLS), só no provisioned |
| 9094 | TLS |
| 9096 | SASL/SCRAM (usuário e senha) |
| **9098** | **IAM** (provisioned e serverless) |

## Passo 2: o cluster serverless

```hcl
resource "aws_msk_serverless_cluster" "main" {
  cluster_name = var.cluster_name            # development-algadelivery-msk

  vpc_config {
    subnet_ids         = var.subnet_ids      # as 3 subnets management
    security_group_ids = [aws_security_group.main.id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true                       # obrigatório no serverless
      }
    }
  }

  tags = merge(var.common_tags, { Name = var.cluster_name })

  lifecycle {
    prevent_destroy = true
  }
}
```

| Bloco/argumento | O que faz | Detalhe |
|-----------------|-----------|---------|
| `cluster_name` | Nome do cluster | Prefixo `${var.environment}` evita colisão entre dev e prod ✅ |
| `vpc_config.subnet_ids` | Onde a AWS cria os pontos de acesso (VPC endpoints) do cluster | Subnets em **2 ou mais AZs**; as 3 `management` |
| `vpc_config.security_group_ids` | Firewall desses pontos de acesso | O SG do passo 1 |
| `client_authentication.sasl.iam` | Quem pode se conectar | Só clientes com **credenciais IAM** e permissões `kafka-cluster:*`. Não existe usuário/senha |
| `prevent_destroy` | Trava o destroy | ⚠️ ver [ponto 2](#2--prevent_destroy--true-fixo-no-recurso-mais-caro) |

O que **não** se configura no serverless (e por isso o módulo tem tão poucas variáveis): versão do Kafka, tipo/quantidade de brokers, disco, criptografia (sempre ligada, em trânsito e em repouso). A retenção e o número de partições são definidos **por tópico**, na criação do tópico, pelo cliente Kafka, não pelo OpenTofu.

## Passo 3: data source que depende de um recurso

```hcl
data "aws_msk_bootstrap_brokers" "main" {
  cluster_arn = aws_msk_serverless_cluster.main.arn
}
```

**Bootstrap brokers** são o "endereço de entrada" que o cliente Kafka usa para se conectar (ex.: `boot-xxxxxxxx.c1.kafka-serverless.us-east-1.amazonaws.com:9098`).

Até agora, os data sources do projeto liam coisas que **já existiam** antes do plan (seu IP, a AMI do Ubuntu, doc 18). Este lê algo de um recurso **que ainda vai ser criado**. Por isso o plan mostra:

```
  # module.msk.data.aws_msk_bootstrap_brokers.main will be read during apply
  # (config refers to values not yet known)
```

O ARN do cluster só existe depois do apply, então a leitura fica para **durante o apply**. O OpenTofu cria o cluster primeiro e só depois lê os brokers (a dependência vem da referência ao `.arn`).

> 💡 Neste caso o data source é **desnecessário**: o próprio `aws_msk_serverless_cluster` já exporta `bootstrap_brokers_sasl_iam` (conferido no schema do provider 6.69.1). Ver [ponto 4](#4-data-source-redundante).

## Passo 4: a chamada no ambiente e os outputs

```hcl
# envs/dev/msk.tofu
module "msk" {
  source = "../../modules/msk"

  cluster_name          = "${var.environment}-${local.context_name}-msk"
  subnet_ids            = module.vpc.subnet_pvt_ids["management"]
  vpc_id                = module.vpc.vpc_id
  security_group_config = local.msk_security_group_config
  common_tags           = local.common_tags
}
```

Outputs do env: `msk_arn`, `msk_bootstrap_brokers_sasl_iam` (o endereço que a aplicação vai usar) e `security_group_msk_id`.

## Mudança na VPC: DNS ligado

```hcl
# modules/vpc/main.tofu
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr_block

  enable_dns_hostnames = true
  enable_dns_support   = true
  ...
}
```

| Atributo | Antes | Agora | O que faz |
|----------|-------|-------|-----------|
| `enable_dns_support` | `true` (padrão) | `true` | Liga o servidor DNS da AWS dentro da VPC (o endereço `.2` da VPC, ex.: `172.25.0.2`) |
| `enable_dns_hostnames` | `false` (padrão) | **`true`** | Dá nomes DNS aos recursos e permite o **DNS privado** dos VPC endpoints |

**Por quê:** o MSK Serverless entrega o acesso por **VPC endpoints** com nome DNS privado (`boot-….kafka-serverless…amazonaws.com`). Sem os dois atributos ligados, esse nome não resolve dentro da VPC e o cliente não encontra o cluster. O doc 11 já previa: "ligue se for usar VPC endpoints/EKS".

Efeito no state: num ambiente já aplicado, seria uma **alteração in-place** da VPC (sem recriar nada). Como o dev está destruído, só aparece no `plan` como `enable_dns_hostnames = true`.

## O plan real (dev)

```
  # module.msk.aws_msk_serverless_cluster.main will be created
  + resource "aws_msk_serverless_cluster" "main" {
      + arn                        = (known after apply)
      + bootstrap_brokers_sasl_iam = (known after apply)
      + cluster_name               = "development-algadelivery-msk"
      + client_authentication { + sasl { + iam { + enabled = true } } }
      + vpc_config {
          + security_group_ids = (known after apply)
          + subnet_ids         = (known after apply)
        }
    }
  # module.msk.aws_security_group.main will be created
      + ingress: 9098/tcp de 172.25.0.0/16
  # module.msk.data.aws_msk_bootstrap_brokers.main will be read during apply

Plan: 43 to add, 0 to change, 0 to destroy.
```

(Trecho resumido.)

## Como conectar (depois do apply)

Com IAM, **estar na VPC não basta**: o cliente precisa de credenciais AWS com permissão no cluster. Hoje o bastion **não tem** instance profile (o módulo `ec2` não cria IAM), então ninguém consegue usar o cluster ainda.

### 1. Uma role IAM para o cliente (snippet testado)

```hcl
# envs/dev/msk_iam.tofu (sugestão; não existe no código)
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "msk_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]   # quem pode "vestir" a role: instâncias EC2
    }
  }
}

data "aws_iam_policy_document" "msk_client" {
  statement {                                # conectar no cluster
    actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
    resources = [module.msk.arn]
  }
  statement {                                # tópicos do cluster
    actions   = ["kafka-cluster:CreateTopic", "kafka-cluster:DescribeTopic",
                 "kafka-cluster:WriteData", "kafka-cluster:ReadData"]
    resources = ["arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${module.msk.cluster_name}/*"]
  }
  statement {                                # consumer groups
    actions   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
    resources = ["arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:group/${module.msk.cluster_name}/*"]
  }
}

resource "aws_iam_role" "msk_client" {
  name               = "${var.environment}-${local.context_name}-msk-client"
  assume_role_policy = data.aws_iam_policy_document.msk_assume.json
}

resource "aws_iam_role_policy" "msk_client" {
  name   = "msk-client"
  role   = aws_iam_role.msk_client.id
  policy = data.aws_iam_policy_document.msk_client.json
}

resource "aws_iam_instance_profile" "msk_client" {
  name = "${var.environment}-${local.context_name}-msk-client"
  role = aws_iam_role.msk_client.name
}
```

- Requer um output `cluster_name` no módulo `msk` (ou montar o nome no env).
- Depois, ligar o profile na EC2: `iam_instance_profile = aws_iam_instance_profile.msk_client.name` no `aws_instance` (o módulo `ec2` precisaria de um input novo).
- Testado numa cópia: `validate` ok e `plan` com +3 recursos IAM.

### 2. O cliente Kafka (no bastion)

```bash
sudo apt install -y openjdk-17-jre-headless
wget https://archive.apache.org/dist/kafka/3.7.0/kafka_2.13-3.7.0.tgz && tar xzf kafka_2.13-3.7.0.tgz
wget -P kafka_2.13-3.7.0/libs https://github.com/aws/aws-msk-iam-auth/releases/download/v2.2.0/aws-msk-iam-auth-2.2.0-all.jar

cat > client.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

BOOT=boot-xxxxxxxx.c1.kafka-serverless.us-east-1.amazonaws.com:9098   # tofu output -raw msk_bootstrap_brokers_sasl_iam
cd kafka_2.13-3.7.0/bin
./kafka-topics.sh --bootstrap-server $BOOT --command-config ~/client.properties \
  --create --topic pedidos --partitions 3
./kafka-console-producer.sh --bootstrap-server $BOOT --producer.config ~/client.properties --topic pedidos
./kafka-console-consumer.sh --bootstrap-server $BOOT --consumer.config ~/client.properties --topic pedidos --from-beginning
```

O `aws-msk-iam-auth` é a biblioteca que troca as credenciais IAM da instância por uma "senha" temporária aceita pelo cluster.

## Custos

Preços on-demand em `us-east-1` (AWS Price List API):

| Item | Preço MSK Serverless |
|------|----------------------|
| **Hora de cluster** | **US$ 0,75/h** |
| Partição | US$ 0,0015 por partição-hora |
| Armazenamento | US$ 0,10 por GB-mês |
| Dados de entrada / saída | US$ 0,10 / US$ 0,05 por GB |

```
cluster:   0,75 × 730 h                 ≈ US$ 547/mês   (mesmo sem nenhuma mensagem)
partições: 3 tópicos × 3 partições = 9 × 0,0015 × 730 ≈ US$ 10/mês
```

Comparando com o resto do ambiente (por mês, ligado o tempo todo):

| Recurso | ~US$/mês |
|---------|----------|
| **MSK Serverless** | **547** |
| ElastiCache Valkey (com mínimos) | 67 |
| NAT Gateway | 33 |
| RDS `db.t4g.micro` | 12 |
| EC2 `t3.micro` | 8 |

> Para estudar: `apply`, testar por uma ou duas horas (~US$ 1,50) e `destroy` logo em seguida. Para isso funcionar, o `prevent_destroy` precisa sair do caminho (ponto 2). Alternativa para estudar Kafka sem custo: rodar o Kafka num container local (`docker run apache/kafka`).

## Validação (feita só com leitura)

| Checagem | Resultado |
|----------|-----------|
| `tofu validate` (dev, cópia) | ✅ |
| `tofu plan` (dev) | ✅ **43 to add** (41 + cluster + SG; data source lido no apply) · VPC com `enable_dns_hostnames = true` |
| Schema do provider | `aws_msk_serverless_cluster` exporta `arn`, `bootstrap_brokers_sasl_iam`, `cluster_uuid` |
| Preços | Price List API (tabela acima) |
| `aws kafka list-clusters-v2` | ⚠️ `SubscriptionRequiredException` com as credenciais usadas na consulta (ver [ponto 6](#6-a-conta-pode-não-ter-o-msk-habilitado)) |
| `tofu fmt -check` | ❌ `envs/prod/local.tofu` (o novo `msk_security_group_config` está com 4 espaços a mais), `envs/prod/variables.tofu`, `modules/ec2/main.tofu`, `modules/rds/variables.tofu` |
| prod | ⏸️ `tofu init -reconfigure` (agora também para instalar o `module "msk"`) |

## ⚠️ Pontos de atenção

Snippets testados numa cópia do projeto (`tofu validate` + `tofu plan`, sem aplicar).

### 1. 💲💲 Custo: o recurso mais caro do projeto

~US$ 547/mês por ambiente, cobrados por hora **a partir da criação**, com ou sem uso. Subir dev **e** prod passa de US$ 1.000/mês. Só crie quando for testar, e destrua no mesmo dia.

### 2. 🔴 `prevent_destroy = true` fixo no recurso mais caro

A mesma situação dos docs 25 e 27, agora com o maior custo: o `tofu destroy` do dev é **recusado** e o cluster continua cobrando. Solução por variável:

```hcl
# modules/msk/variables.tofu
variable "prevent_destroy" {
  description = "Protege o cluster contra destroy (true no prod, false no dev)"
  type        = bool
  default     = true
}

# modules/msk/main.tofu
lifecycle {
  prevent_destroy = var.prevent_destroy
}

# envs/dev/msk.tofu
prevent_destroy = false
```

### 3. Autenticação IAM sem nenhuma IAM no projeto

O cluster só aceita IAM, e o projeto não cria role, policy nem instance profile. Resultado: depois do apply, **nenhum cliente consegue usar o cluster**. Ver a seção [Como conectar](#como-conectar-depois-do-apply).

### 4. Data source redundante

O recurso já tem o atributo; o data source faz uma chamada a mais na AWS a cada `plan`/`apply`:

```hcl
# modules/msk/outputs.tofu
output "bootstrap_brokers_sasl_iam" {
  description = "IAM bootstrap broker endpoints for the MSK Serverless cluster"
  value       = aws_msk_serverless_cluster.main.bootstrap_brokers_sasl_iam
}
```

E remova o bloco `data "aws_msk_bootstrap_brokers"` do `main.tofu` (testado: o plan fica igual, sem o "read during apply"). Ainda assim, ele é um bom exemplo didático de data source dependente de recurso.

### 5. Security group: VPC inteira, egress sem uso e nome fixo

Os mesmos três pontos do [doc 27](27-modulo-elasticache.md#5-security-group-vpc-inteira-egress-sem-uso-e-nome-fixo):

- entrada 9098 da VPC inteira (melhor: só o SG do bastion/aplicação);
- egress "tudo" desnecessário (SG é stateful);
- `name` fixo + `create_before_destroy` → use `name_prefix`.

Aqui o risco da porta aberta é menor que no Valkey: mesmo alcançando a 9098, o cliente ainda precisa de permissão IAM.

### 6. A conta pode não ter o MSK habilitado

A consulta `kafka:ListClustersV2` retornou `SubscriptionRequiredException` ("The AWS Access Key Id needs a subscription for the service"). Isso acontece em contas novas ou com restrições (ex.: plano gratuito). Se o `apply` der o mesmo erro, o problema é da conta, não do código: verifique no console do MSK ou com o suporte da AWS.

### 7. Subnets management e valores iguais em dev e prod

O cluster foi para `management`, como o Valkey (o RDS está em `database`). O módulo não tem nenhuma variável de ambiente além do SG, então dev e prod são idênticos; a diferença real, se houver, ficará nos tópicos (partições/retenção) criados pela aplicação.

### 8. Duplicação e formatação

`msk.tofu`, a variável e o `local` foram copiados para as duas pastas (doc 24, ponto 2). No prod, o `local` foi colado com indentação a mais: rode `tofu fmt -recursive` na raiz.

## Pegadinhas

- **Porta 9098 + IAM:** sem `client.properties` com `AWS_MSK_IAM`, a conexão falha mesmo com o SG aberto.
- **DNS:** sem `enable_dns_hostnames`/`enable_dns_support`, o endereço `boot-…` não resolve na VPC.
- **"read during apply":** data source que depende de recurso novo só é lido no apply; no plan aparece `(known after apply)`.
- **Tópicos não são do OpenTofu** aqui: são criados pelo cliente Kafka. (Existe o provider `Mongey/kafka` para gerenciá-los como código.)
- **A cobrança começa na criação**, não no primeiro uso.
- **Mudar `modules/msk` ou `modules/vpc`** afeta dev e prod no próximo `plan` (doc 24).
