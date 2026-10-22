# 14. Internet Gateway (IGW)

> **Atualização (módulos):** este código agora mora em `modules/vpc/main.tofu`, com endereços `module.vpc.aws_*.main` (antes: `aws_*.algadelivery`). Os trechos abaixo mostram a versão anterior; os conceitos são os mesmos. Ver [21-modules.md](21-modules.md).

## O que é

O **Internet Gateway** é a **porta** entre a sua VPC e a internet. Sem ele, a VPC é uma rede fechada: nada entra nem sai para a internet, mesmo com IP público.

Características:

- **Gerenciado pela AWS:** redundante e altamente disponível. Não há servidor para cuidar nem tamanho para escolher.
- **Escala sozinho:** não vira gargalo de banda.
- **Grátis:** você não paga pelo IGW. Paga pelo tráfego de saída e pelos IPs públicos (ver Custos).
- **1 por VPC:** uma VPC tem no máximo um IGW, e um IGW atende uma VPC só.
- **Traduz endereços:** a instância só conhece o próprio IP privado (`172.25.1.10`). O IGW faz a tradução 1:1 para o IP público associado a ela, na ida e na volta.

## Para que serve

| Uso | Exemplo |
|-----|---------|
| **Entrada:** a internet acessa recursos na VPC | Usuário acessa o site pelo load balancer (ALB) numa subnet pública |
| **Saída:** recursos na subnet pública acessam a internet | EC2 numa subnet pública baixa pacotes (`apt update`) |
| Base para o **NAT Gateway** | O NAT usa o IGW para dar saída às subnets privadas (ver [15-subnets-privadas-e-nat-gateway.md](15-subnets-privadas-e-nat-gateway.md)) |

### O que o IGW **não** faz

Ele não dá internet para subnet **privada**: quem está numa subnet privada não tem rota para o IGW, de propósito. Para uma subnet privada só **sair** (baixar atualizações), sem poder ser acessada de fora, usa-se o **NAT Gateway**.

| | Internet Gateway | NAT Gateway |
|---|---|---|
| Direção | Entrada **e** saída | Só saída |
| Quem usa | Subnets públicas | Subnets privadas |
| Precisa de IP público no recurso? | Sim | Não (o NAT tem o dele) |
| Custo | Grátis | **Pago** (por hora + por GB) |
| Onde fica | Ligado à VPC | Zonal: dentro de uma subnet pública · **Regional (o deste projeto): ligado à VPC** |

## Os ingredientes de uma subnet pública

Uma subnet só é pública quando **todos** estes itens existem:

| # | Ingrediente | Recurso | Situação |
|---|-------------|---------|----------|
| 1 | A porta | `aws_internet_gateway` | ✅ criado |
| 2 | O caminho até a porta | `aws_route_table` com rota `0.0.0.0/0 → IGW` | ✅ no código (doc 16) |
| 3 | Ligar o caminho à subnet | `aws_route_table_association` | ✅ no código (doc 16) |
| 4 | Endereço público no recurso | `map_public_ip_on_launch = true` ou IP elástico | ❌ falta (opcional por subnet) |

```
                 Internet
                    │
          ┌─────────┴─────────┐
          │  Internet Gateway │  ✅ algadelivery-igw
          └─────────┬─────────┘
                    │  rota 0.0.0.0/0 → igw       ✅ algadelivery-rt-public
   ┌────────────────┼────────────────┐
   │                │                │            ✅ 3 associations
┌──┴───────┐   ┌────┴─────┐   ┌──────┴───┐
│ pub-a    │   │ pub-b    │   │ pub-c    │
│ 1a       │   │ 1b       │   │ 1c       │
└──────────┘   └──────────┘   └──────────┘
          VPC 172.25.0.0/16
```

Com a route table pública e as associations (doc 16), as subnets públicas têm o caminho até a porta. Falta só o item 4 para cada recurso que precisar ser acessado de fora.

## O código (`networking.tofu`)

```hcl
resource "aws_internet_gateway" "algadelivery" {
  vpc_id = aws_vpc.algadelivery.id

  tags = {
    Name = "${local.context_name}-igw"
  }
}
```

| Trecho | O que faz |
|--------|-----------|
| `vpc_id = aws_vpc.algadelivery.id` | Cria o IGW **já ligado** à VPC. A referência cria a dependência implícita: VPC primeiro, IGW depois; no destroy, o contrário |
| `"${local.context_name}-igw"` | `local.context_name` vem de `local.tofu` (`"algadelivery"`) e resulta em `algadelivery-igw` (ver [06-variaveis.md](06-variaveis.md#locals-valores-derivados)) |

### No `plan`

Saída real. O state estava vazio, então tudo entra no plano: **5 to add** (VPC, 3 subnets e IGW).

```
  # aws_internet_gateway.algadelivery will be created
  + resource "aws_internet_gateway" "algadelivery" {
      + arn      = (known after apply)
      + id       = (known after apply)
      + owner_id = (known after apply)
      + region   = "us-east-1"
      + tags     = {
          + "Name" = "algadelivery-igw"
        }
      + vpc_id   = (known after apply)
    }

Plan: 5 to add, 0 to change, 0 to destroy.
```

### Outputs (`outputs.tofu`)

```hcl
output "igw_id" {
  description = "The ID of the Internet Gateway"
  value       = aws_internet_gateway.algadelivery.id
}

output "igw_arn" {
  description = "The ARN of the Internet Gateway"
  value       = aws_internet_gateway.algadelivery.arn
}
```

O `igw_id` (`igw-...`) é o que a route table vai referenciar.

## A route table pública ✅

Implementada: `aws_route_table.public` com `0.0.0.0/0 → IGW` e `aws_route_table_association.public` com `for_each = aws_subnet.public`. Explicação completa em [16-route-tables.md](16-route-tables.md).

## Custos

| Item | Custo |
|------|-------|
| Internet Gateway | **Grátis** |
| Tráfego **entrando** da internet | Grátis |
| Tráfego **saindo** para a internet | Pago por GB (há uma faixa gratuita mensal) |
| IPv4 público (EC2, ALB, NAT, IP elástico) | Pago por hora, por IP |

Criar e destruir o IGW no estudo não custa nada. O que pode custar é o que vier depois (instâncias com IP público, NAT Gateway).

## Pegadinhas

- **IGW sem rota não faz nada.** Criar o gateway é só metade do trabalho; sem a route table e a association, a subnet continua isolada.
- **Só 1 IGW por VPC.** Um segundo `aws_internet_gateway` com o mesmo `vpc_id` falha (`Resource.AlreadyAssociated`).
- **Destroy:** o IGW não sai enquanto houver IPs públicos em uso na VPC (EC2 com IP público, IP elástico, NAT Gateway): `DependencyViolation`. Com tudo gerenciado pelo OpenTofu, a ordem é resolvida pelas dependências.
- Existe o recurso `aws_internet_gateway_attachment`, para criar o IGW solto e ligá-lo depois. **Não use os dois juntos:** ou `vpc_id` no IGW (como aqui), ou o attachment.
- "Subnet pública" é uma **convenção**: a AWS não tem um campo `public = true`. Quem decide é a rota para o IGW.
