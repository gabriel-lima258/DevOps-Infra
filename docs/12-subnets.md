# 12. Subnets

> **Atualização (módulos):** este código agora mora em `modules/vpc/main.tofu`, com endereços `module.vpc.aws_*.main` (antes: `aws_*.algadelivery`). Os trechos abaixo mostram a versão anterior; os conceitos são os mesmos. Ver [21-modules.md](21-modules.md).

## Para que serve uma subnet

A VPC (doc 11) é o "terreno" da sua rede. Uma **subnet** é um **lote** desse terreno: um pedaço da faixa de IPs da VPC, com regras próprias de roteamento e acesso. **Nada roda direto na VPC**: toda EC2, banco RDS, container ou load balancer é criado **dentro de uma subnet**.

Dividir a rede em subnets serve para:

1. **Separar o que é exposto do que é protegido.** O load balancer fica onde a internet alcança; o banco de dados, onde ela não alcança.
2. **Espalhar entre datacenters (AZs).** Cada subnet mora em **uma** *Availability Zone*. Várias subnets em AZs diferentes = a aplicação sobrevive se um datacenter cair.
3. **Aplicar regras por camada.** Rotas (route tables) e firewalls de rede (NACLs) são associados a subnets.

### Pública x privada

O que torna uma subnet pública **não é o nome**, é a **rota**:

| | Subnet pública | Subnet privada |
|---|---|---|
| Rota `0.0.0.0/0` (internet) | → **Internet Gateway** | → NAT Gateway (só saída) ou nenhuma |
| Alcançável da internet? | Sim, se o recurso tiver IP público | Não |
| O que costuma ficar nela | Load balancer (ALB), bastion host, NAT Gateway | Aplicação (EC2/ECS/EKS), banco (RDS), cache (ElastiCache) |

Arquitetura típica, de fora para dentro: **internet → ALB (pública) → aplicação (privada) → banco (privada)**.

As subnets privadas do projeto (management e cluster) e o NAT Gateway estão em [15-subnets-privadas-e-nat-gateway.md](15-subnets-privadas-e-nat-gateway.md). O desenho completo está em [ARQUITETURA.md](ARQUITETURA.md).

### Por que 3 AZs

- **Alta disponibilidade:** se a `us-east-1a` tiver problema, `b` e `c` continuam atendendo.
- **Requisitos da AWS:** ALB exige subnets em **pelo menos 2 AZs**; RDS também pede um *subnet group* com 2+ AZs.
- 3 é o padrão de mercado: tolera a queda de uma AZ e ainda mantém redundância.

## O desenho da rede

```
VPC algadelivery  172.25.0.0/16  (65.536 IPs)
│
├── us-east-1a ── Subnet Public A  172.25.1.0/24  (256 IPs)
├── us-east-1b ── Subnet Public B  172.25.2.0/24  (256 IPs)
└── us-east-1c ── Subnet Public C  172.25.3.0/24  (256 IPs)

Hoje: privadas management 172.25.4-6.0/24 e cluster 172.25.7-9.0/24 (doc 15).
Livre: 172.25.10.0 … 172.25.255.255
```

### IPs que a AWS reserva

Em toda subnet, a AWS reserva **5 IPs**. Numa `/24` sobram **251** utilizáveis. Para `172.25.1.0/24`:

| IP | Reservado para |
|----|----------------|
| `172.25.1.0` | Endereço da rede |
| `172.25.1.1` | Roteador da VPC |
| `172.25.1.2` | DNS da AWS |
| `172.25.1.3` | Uso futuro da AWS |
| `172.25.1.255` | Broadcast (não usado, mas reservado) |

## O código

`networking.tofu`: **um bloco** cria as três subnets com `for_each` (detalhes em [13-loops-for-each-e-for.md](13-loops-for-each-e-for.md)).

```hcl
resource "aws_subnet" "public" {
  for_each          = var.subnet_pub_config
  vpc_id            = aws_vpc.algadelivery.id
  cidr_block        = each.value.cidr_block
  availability_zone = "${var.aws_region}${each.value.az}"

  tags = {
    Name = "${local.context_name}-pub-${each.value.az}"   # algadelivery-pub-a
  }
}
```

`variables.tofu`:

```hcl
variable "subnet_pub_config" {
  type = map(object({
    cidr_block = string
    az         = string
  }))
  default = {
    "public_a" = { cidr_block = "172.25.1.0/24", az = "a" }
    "public_b" = { cidr_block = "172.25.2.0/24", az = "b" }
    "public_c" = { cidr_block = "172.25.3.0/24", az = "c" }
  }
}
```

| Trecho | O que faz |
|--------|-----------|
| `vpc_id = aws_vpc.algadelivery.id` | Coloca a subnet dentro da VPC. A referência cria a **dependência implícita**: a VPC é criada antes e destruída depois |
| `for_each = var.subnet_pub_config` | Uma subnet por item do mapa |
| `each.value.cidr_block` | O campo `cidr_block` do item da vez |
| `"${var.aws_region}${each.value.az}"` | Interpolação: `"us-east-1"` + `"a"` = `"us-east-1a"` |
| `"${local.context_name}-pub-${each.value.az}"` | Nome padronizado a partir do `local` (`algadelivery`) + AZ: `algadelivery-pub-a` |

Endereços no state: `aws_subnet.public["public_a"]`, `["public_b"]`, `["public_c"]`. O tipo `map(object(...))` está explicado em [06-variaveis.md](06-variaveis.md#tipos-complexos).

> Na primeira versão eram 3 blocos (`public_a`, `public_b`, `public_c`) lendo uma **lista** por índice (`var.subnet_pub_config[0]`). O antes x depois está no doc 13.

### No `plan`

Saída real da primeira versão (subnet A, resumida; hoje o endereço seria `aws_subnet.public["public_a"]`). O state estava vazio, então a VPC também entra no plano: **4 to add**.

```
  # aws_subnet.public_a will be created
  + resource "aws_subnet" "public_a" {
      + arn                     = (known after apply)
      + availability_zone       = "us-east-1a"
      + cidr_block              = "172.25.1.0/24"
      + id                      = (known after apply)
      + map_public_ip_on_launch = false
      + tags                    = {
          + "Name" = "Subnet Public A"
        }
      + vpc_id                  = (known after apply)
      ...
    }

Plan: 4 to add, 0 to change, 0 to destroy.
```

`vpc_id = (known after apply)`: o ID da VPC só existe depois que ela for criada. É a dependência implícita aparecendo.

## Pública de verdade: o que já existe

O que torna uma subnet pública é a **rota para o IGW**. Situação no código:

| Ingrediente | Situação |
|-------------|----------|
| `aws_internet_gateway`: a porta | ✅ ver [14-internet-gateway.md](14-internet-gateway.md) |
| `aws_route_table` com `0.0.0.0/0 → IGW`: o caminho | ✅ ver [16-route-tables.md](16-route-tables.md) |
| `aws_route_table_association` por subnet | ✅ ver [16-route-tables.md](16-route-tables.md) |
| IP público no recurso | ❌ `map_public_ip_on_launch = false` (configure por recurso: EIP, ALB) |
| Security group liberando a porta | ✅ `bastion_sg` libera a 22, ver [17-security-groups.md](17-security-groups.md) |

E, se as instâncias devem ganhar IP público automaticamente, `map_public_ip_on_launch = true` na subnet.

> Custo: IGW, route tables e subnets são **grátis**. Cada **IPv4 público** é cobrado por hora (desde 2024). No estudo, prefira não ligar o `map_public_ip_on_launch` sem necessidade.

## Repetição eliminada com loops ✅

A primeira versão tinha 3 blocos quase iguais e 6 outputs. Isso foi refatorado com `for_each` (recursos) e expressões `for` (outputs): ver [13-loops-for-each-e-for.md](13-loops-for-each-e-for.md).

## Melhoria possível

### `cidrsubnet()`: deixar o OpenTofu calcular os CIDRs

```hcl
cidrsubnet(var.vpc_cidr_block, 8, 1)   # "172.25.1.0/24"
cidrsubnet(var.vpc_cidr_block, 8, 2)   # "172.25.2.0/24"
```

`8` = quantos bits somar à máscara (`/16` + 8 = `/24`); o último número é qual pedaço usar. Se o CIDR da VPC mudar, as subnets acompanham. Teste no `tofu console`.

## Pegadinhas

- **Mudar `cidr_block` ou `availability_zone` recria a subnet** (`-/+`) e tudo o que estiver nela.
- O CIDR da subnet precisa estar **dentro** do CIDR da VPC e **não pode sobrepor** outra subnet (`InvalidSubnet.Conflict`).
- **Mudar a chave do mapa** (`public_a` → `pub_a`) recria a subnet: a chave é a identidade. (Com a lista da primeira versão, o problema era reordenar os itens.)
- Nem toda região tem as AZs `a`, `b` e `c` disponíveis para todos os tipos de recurso. Para descobrir as AZs de forma dinâmica: `data "aws_availability_zones" "available" {}`.
- O **nome** da AZ (`us-east-1a`) é embaralhado por conta: a sua `1a` pode ser outro datacenter na conta de outra pessoa. O identificador fixo é o **AZ ID** (`use1-az1`), que aparece no atributo `availability_zone_id`.
- `destroy` da VPC destrói as subnets antes (dependência). Se houver algo criado fora do OpenTofu numa subnet (uma EC2 pelo console), falha com `DependencyViolation`.
