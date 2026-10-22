# 15. Subnets privadas e NAT Gateway

> **Atualização (módulos):** este código agora mora em `modules/vpc/main.tofu`, com endereços `module.vpc.aws_*.main` (antes: `aws_*.algadelivery`). Os trechos abaixo mostram a versão anterior; os conceitos são os mesmos. Ver [21-modules.md](21-modules.md).

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

## Subnets privadas

### Para que servem

Uma subnet privada **não tem rota para o Internet Gateway**: ninguém da internet chega até ela, nem que um recurso tenha IP público. É onde fica tudo que **não deve ser exposto**: aplicação, banco de dados, cache, ferramentas internas.

Elas ainda precisam **sair** para a internet: baixar atualizações, imagens de container, chamar APIs externas (gateway de pagamento, e-mail). Para isso existe o **NAT Gateway**: deixa sair, não deixa entrar.

### Por que dois grupos (management e cluster)

O projeto separa as privadas por **função**:

| Grupo | CIDRs | Nome | Para que serve |
|-------|-------|------|----------------|
| **management** | `172.25.4-6.0/24` | `algadelivery-pvt-mgmt-{a,b,c}` | Infraestrutura de apoio: bancos (RDS), cache (ElastiCache), bastion/SSM, runners de CI, ferramentas internas |
| **cluster** | `172.25.7-9.0/24` | `algadelivery-pvt-cluster-{a,b,c}` | Workloads da aplicação: nós de EKS/ECS e, no EKS, **os pods**, que recebem IPs da VPC |

Vantagens de separar:

- **Regras de acesso por grupo:** security groups e NACLs diferentes. Ex.: "só o cluster acessa o banco na porta 5432".
- **O cluster consome muitos IPs:** no EKS, cada pod pega um IP da subnet. Isolar a faixa do cluster evita que ele esgote os IPs do banco e das ferramentas (e vice-versa).
- **Escala independente:** dá para ampliar a faixa do cluster sem mexer no resto.
- **Leitura e auditoria:** pelo nome/CIDR você sabe o que é cada IP.

### O código

```hcl
resource "aws_subnet" "private_management" {
  for_each          = var.subnet_pvt_management_config
  vpc_id            = aws_vpc.algadelivery.id
  cidr_block        = each.value.cidr_block
  availability_zone = "${var.aws_region}${each.value.az}"

  tags = {
    Name        = "${local.context_name}-pvt-mgmt-${each.value.az}"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_subnet" "private_cluster" {
  for_each = var.subnet_pvt_cluster_config
  # ... mesmo padrão, Name = "${local.context_name}-pvt-cluster-${each.value.az}"
}
```

```hcl
variable "subnet_pvt_management_config" {
  type = map(object({
    cidr_block = string
    az         = string
  }))
  default = {
    "private_a" = { cidr_block = "172.25.4.0/24", az = "a" }
    "private_b" = { cidr_block = "172.25.5.0/24", az = "b" }
    "private_c" = { cidr_block = "172.25.6.0/24", az = "c" }
  }
}
# subnet_pvt_cluster_config: mesmo formato, 172.25.7-9.0/24
```

- O padrão é o mesmo das públicas (`for_each` sobre um mapa, doc 13).
- As duas variáveis usam as **mesmas chaves** (`private_a`…). Não há conflito: o endereço completo inclui o nome do recurso, `aws_subnet.private_management["private_a"]` x `aws_subnet.private_cluster["private_a"]`.
- **O que torna a subnet privada não está no bloco `aws_subnet`**: está na route table associada a ela. O código das públicas e das privadas é praticamente igual.

## NAT Gateway

### Para que serve

**NAT** (*Network Address Translation*) troca o IP privado de quem está saindo pelo IP público do NAT:

```
pod 172.25.7.15 ──► NAT Gateway ──► IGW ──► api.pagamentos.com
                    (sai com o IP público do NAT)
api.pagamentos.com ──► responde ao IP do NAT ──► NAT devolve ao pod
```

- **Só saída:** conexões **iniciadas de dentro**. A resposta volta; uma conexão nova vinda de fora não entra.
- **IP de saída fixo:** todos os recursos privados saem com o(s) IP(s) do NAT. Útil quando um parceiro exige **allowlist** de IP.
- Gerenciado, redundante, escala sozinho (até dezenas de Gbps).

| | Internet Gateway | NAT Gateway |
|---|---|---|
| Quem usa | Subnets **públicas** | Subnets **privadas** |
| Direção | Entrada e saída | **Só saída** |
| Custo | Grátis | **Pago** por hora + por GB |

### Zonal x regional

O código usa o modo **regional** (`availability_mode = "regional"`), lançado pela AWS em 2025:

| | NAT **zonal** (clássico) | NAT **regional** (o deste projeto) |
|---|---|---|
| Onde fica | **Dentro de uma subnet pública** (`subnet_id`) | Ligado à **VPC** (`vpc_id`), sem subnet pública |
| Alta disponibilidade | Só na AZ dele. Para HA: **1 NAT por AZ** | Um só NAT que se **expande e se retrai entre AZs** conforme os workloads |
| Rotas | Uma route table privada por AZ, cada uma apontando para o NAT da sua AZ | Uma route table privada pode servir todas as AZs, apontando para o mesmo NAT |
| Saída para o IGW | Pela route table da subnet pública onde ele mora | A AWS **cria uma route table para o NAT**, já com rota para o IGW |
| IPs públicos | Você aloca e associa um EIP | A AWS aloca EIPs por AZ automaticamente (`auto_provision_zones`) |

Fonte: [Regional NAT gateways for automatic multi-AZ expansion](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html) (AWS).

### O código

`networking.tofu`:

```hcl
resource "aws_nat_gateway" "algadelivery" {
  vpc_id            = aws_vpc.algadelivery.id
  availability_mode = local.ngw_regional_mode

  tags = {
    Name        = "${local.context_name}-ngw"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}
```

`variables.tofu` + `local.tofu`:

```hcl
variable "ngw_regional_mode" {
  description = "The availability mode regional"
  type        = bool
  default     = true
}

locals {
  ngw_regional_mode = var.ngw_regional_mode ? "regional" : "zonal"
}
```

- A variável é um **`bool`** (liga/desliga), mais simples para quem usa.
- O `local` traduz para o texto que a AWS espera, com o **operador ternário** `condição ? se_verdadeiro : se_falso` (ver [06-variaveis.md](06-variaveis.md#locals-valores-derivados)).
- **Sem `subnet_id`:** no modo regional não se informa subnet. Se mudar para `false` (zonal), o código precisaria de `subnet_id` (uma subnet pública) e de um EIP. Do jeito que está, o modo zonal não funcionaria.

### O que a AWS criou (do `tofu state show`)

```
resource "aws_nat_gateway" "algadelivery" {
    auto_provision_zones           = "enabled"
    auto_scaling_ips               = "enabled"
    availability_mode              = "regional"
    connectivity_type              = "public"
    id                             = "nat-1f382d3ca0c590361"
    regional_nat_gateway_address   = [
        {
            allocation_id        = "eipalloc-…"
            availability_zone    = "us-east-1a"
            availability_zone_id = "use1-az1"
            public_ip            = "x.x.x.x"
            status               = "succeeded"
        },
    ]
    regional_nat_gateway_auto_mode = "enabled"
    route_table_id                 = "rtb-00af5f92fea57daa6"
    vpc_id                         = "vpc-03f06be0abed6a7f7"
}
```

(IP público mascarado.)

| Atributo | Significado |
|----------|-------------|
| `availability_mode = "regional"` | Multi-AZ automático |
| `connectivity_type = "public"` | Sai para a internet (existe também `private`, para NAT entre redes privadas) |
| `auto_provision_zones = "enabled"` | A AWS gerencia sozinha em quais AZs o NAT atua e os EIPs de cada uma |
| `auto_scaling_ips = "enabled"` | Adiciona EIPs numa AZ quando faltam portas (muitas conexões simultâneas ao mesmo destino) |
| `regional_nat_gateway_address` | Os IPs públicos por AZ. No momento do state, **1 IP em `us-east-1a`**: o NAT cresce para outras AZs conforme aparecem workloads |
| `route_table_id` | A route table **do NAT**, criada pela AWS com rota para o IGW. Não é gerenciada pelo OpenTofu |

### Outputs

```hcl
output "ngw_id" {
  description = "The ID of the NAT Gateway"
  value       = aws_nat_gateway.algadelivery.id
}
```

Além de `subnet_pvt_mgmt_id/arn` e `subnet_pvt_cluster_id/arn` (listas via `for`, como as públicas).

## A route table privada ✅

Implementada em `networking.tofu`: `aws_route_table.private` com `0.0.0.0/0 → NAT` e associations para os dois grupos de subnets privadas. Explicação completa em [16-route-tables.md](16-route-tables.md).

Diferenças em relação à prévia que estava aqui:

| Prévia | Código atual |
|--------|--------------|
| Uma association com `merge()` dos dois grupos | Duas associations (`private_management` e `private_cluster`), uma por grupo: mais simples de ler |
| `nat_gateway_id = aws_nat_gateway...id` | `gateway_id = aws_nat_gateway...id`: ⚠️ o argumento próprio para NAT é `nat_gateway_id` ([doc 16](16-route-tables.md#atenção-gateway_id-x-nat_gateway_id)) |

Com NAT **regional**, **uma** route table privada serve as 3 AZs. Com NAT zonal, seriam 3 (uma por AZ).

## Custos 💲

O NAT Gateway é o **primeiro recurso pago** do projeto:

| Item | Preço de referência (us-east) |
|------|-------------------------------|
| NAT Gateway por hora | ~US$ 0,045/h (~US$ 33/mês) |
| Dados processados pelo NAT | ~US$ 0,045/GB |
| IPv4 público (EIP do NAT) | ~US$ 0,005/h por IP |
| Tráfego entre AZs | cobrado por GB |

- **Cobra por hora mesmo sem tráfego.** No estudo, rode `tofu destroy` ao terminar e `tofu apply` quando voltar.
- No modo regional o NAT atua em várias AZs: confira na [página de preços da VPC](https://aws.amazon.com/vpc/pricing/) como as horas são contadas por AZ.
- Economia comum: **VPC endpoints** de gateway para S3 e DynamoDB são **grátis** e tiram esse tráfego do NAT.

## Tags padronizadas

Todos os recursos têm `Environment` e `ManagedBy`:

- `Environment`: filtrar custos e recursos por ambiente.
- `ManagedBy = "OpenTofu"`: avisa quem abrir o console para **não alterar à mão** (evita drift, doc 08).

Na primeira versão, as duas linhas eram repetidas em cada recurso. Hoje ficam num lugar só, em `local.common_tags`, e cada recurso junta com o seu `Name` usando a função `merge()`:

```hcl
tags = merge(local.common_tags, {
  Name = "${local.context_name}-ngw"
})
```

Explicação completa (e a comparação com `default_tags` no provider) em [18-data-sources-e-functions.md](18-data-sources-e-functions.md#merge--common_tags-x-default_tags).

## Pegadinhas

- O **modo regional** precisa do provider AWS v6.2x ou mais novo (o projeto usa 6.69.1) e da permissão IAM `ec2:DescribeAvailabilityZones`.
- **Não informe `subnet_id`** no NAT regional. No zonal, ele é obrigatório (e deve ser uma subnet **pública**).
- Trocar `availability_mode` (ou `ngw_regional_mode`) **recria o NAT**: o IP público de saída muda e as allowlists de parceiros quebram.
- A route table criada pela AWS para o NAT **não está no state**. Não a apague pelo console.
- Subnet privada **sem** rota para o NAT continua funcionando dentro da VPC, mas qualquer `apt update`/`docker pull` fica pendurado até dar timeout. Sintoma clássico de rota faltando.
- Destroy: o OpenTofu remove o NAT antes do IGW e das subnets por causa das referências. O NAT leva alguns minutos para ser apagado.
