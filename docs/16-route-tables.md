# 16. Route tables (tabelas de rotas)

> **Atualização (módulos):** este código agora mora em `modules/vpc/main.tofu`, com endereços `module.vpc.aws_*.main` (antes: `aws_*.algadelivery`). Os trechos abaixo mostram a versão anterior; os conceitos são os mesmos. Ver [21-modules.md](21-modules.md).

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

## A ideia em uma frase

Uma **route table** é o **GPS da subnet**: para cada pacote que sai de um recurso, ela responde "**para onde eu mando isso?**".

Até aqui o projeto tinha as peças: a VPC, as subnets, a porta para a internet (IGW) e a saída das privadas (NAT). Faltavam as **placas de trânsito** dizendo qual caminho cada subnet deve pegar. É a route table que transforma uma subnet em **pública** ou **privada**.

## Anatomia de uma rota

Cada linha da tabela tem dois campos:

| Destino (para onde o pacote quer ir) | Alvo / *target* (por onde mandar) |
|--------------------------------------|-----------------------------------|
| `172.25.0.0/16` | `local`: entrega dentro da própria VPC |
| `0.0.0.0/0` | `igw-…` ou `nat-…`: sai da VPC |

- `0.0.0.0/0` significa **"qualquer endereço"**: é a rota padrão (*default route*), usada quando nenhuma outra serve.
- A rota `local` é **criada automaticamente** em toda route table e não pode ser removida. Por isso as subnets sempre conversam entre si.

### Como a AWS escolhe: a rota mais específica vence

Quando mais de uma rota serve, vence a de **maior prefixo** (o `/` maior), o chamado *longest prefix match*:

| Pacote para… | Rotas que servem | Vence | Resultado |
|--------------|------------------|-------|-----------|
| `172.25.8.10` (um pod do cluster) | `172.25.0.0/16` e `0.0.0.0/0` | `/16` (mais específica) | Fica na VPC |
| `8.8.8.8` (DNS do Google) | só `0.0.0.0/0` | `/0` | Sai pelo IGW ou NAT |

## As tabelas do projeto

| Tabela | Usada por | Rotas | Efeito |
|--------|-----------|-------|--------|
| `algadelivery-rt-public` | 3 subnets públicas | `172.25.0.0/16 → local`<br>`0.0.0.0/0 → igw` | Entrada e saída direto pela internet → **subnet pública** |
| `algadelivery-rt-private` | 6 subnets privadas (mgmt + cluster) | `172.25.0.0/16 → local`<br>`0.0.0.0/0 → nat` | Só saída, via NAT → **subnet privada** |
| Route table do NAT regional | o NAT Gateway | `0.0.0.0/0 → igw` | Criada pela AWS (doc 15); não é gerenciada pelo OpenTofu |
| *Main route table* da VPC | subnets **sem** association | só `local` | Criada com a VPC; hoje nenhuma subnet a usa |

```
 pod 172.25.7.15 quer falar com api.externa.com
        │
        ▼
 rt-private: 0.0.0.0/0 → nat ──► NAT Gateway ──► rt do NAT: 0.0.0.0/0 → igw ──► IGW ──► Internet

 ALB na pub-a responde a um usuário
        │
        ▼
 rt-public:  0.0.0.0/0 → igw ──► IGW ──► Internet
```

## O código (`networking.tofu`)

### Tabela pública + associations

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.algadelivery.id

  route {
    cidr_block = local.internet_cidr_block                 # "0.0.0.0/0"
    gateway_id = aws_internet_gateway.algadelivery.id      # → IGW
  }

  tags = {
    Name        = "${local.context_name}-rt-public"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
```

| Trecho | O que faz |
|--------|-----------|
| `route { ... }` | Bloco de rota **inline**: as rotas ficam dentro da própria tabela |
| `local.internet_cidr_block` | `"0.0.0.0/0"` com um nome legível, definido em `local.tofu` |
| `gateway_id = aws_internet_gateway...id` | Alvo da rota. A referência faz o IGW ser criado antes da tabela |
| `aws_route_table_association` | **Liga** a tabela a uma subnet. Sem isso, a tabela existe mas ninguém a usa |
| `for_each = aws_subnet.public` | Percorre o **mapa de subnets** (criado com `for_each`, doc 13): uma association por subnet, com a mesma chave. Endereços: `aws_route_table_association.public["public_a"]`… |

### Tabela privada + associations

```hcl
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.algadelivery.id

  route {
    cidr_block = local.internet_cidr_block
    gateway_id = aws_nat_gateway.algadelivery.id    # ⚠️ ver "gateway_id x nat_gateway_id"
  }

  tags = {
    Name        = "${local.context_name}-rt-private"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_route_table_association" "private_management" {
  for_each       = aws_subnet.private_management
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_cluster" {
  for_each       = aws_subnet.private_cluster
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
```

- **Uma tabela privada para as 3 AZs.** Isso só funciona porque o NAT é **regional**. Com NAT zonal seria uma tabela por AZ, cada uma apontando para o NAT da sua AZ.
- **Duas associations** (uma por grupo) em vez de juntar tudo com `merge()`, como na prévia do doc 15:

| Abordagem | Prós | Contras |
|-----------|------|---------|
| Um recurso por grupo (o código atual) | Simples de ler; as chaves `private_a` não colidem (estão em recursos diferentes) | Um bloco a mais por grupo novo |
| Um recurso com `merge()` | Um bloco só | Precisa prefixar as chaves (`mgmt_private_a`) e a expressão é mais difícil de ler |

### Detalhes que o código mostra

- **A ordem dos blocos não importa:** no arquivo, o `aws_internet_gateway` aparece **depois** da route table que o usa, e o NAT aparece no fim. O OpenTofu monta a ordem pelas referências, não pela posição no arquivo (doc 10).
- **Comentários:** `// SUBNET PÚBLICA` funciona. O HCL aceita `#` (o mais comum), `//` e `/* ... */`.

## Atenção: `gateway_id` x `nat_gateway_id`

O bloco `route` tem **um argumento por tipo de alvo**:

| Argumento | Alvo |
|-----------|------|
| `gateway_id` | **Internet Gateway** (`igw-…`) ou Virtual Private Gateway (`vgw-…`, VPN) |
| `nat_gateway_id` | **NAT Gateway** (`nat-…`) |
| `transit_gateway_id` | Transit Gateway (`tgw-…`) |
| `vpc_peering_connection_id` | Peering com outra VPC (`pcx-…`) |
| `vpc_endpoint_id` | Gateway Load Balancer endpoint (`vpce-…`) |
| `network_interface_id` | Uma ENI (ex.: um firewall em EC2) |

A rota privada usa **`gateway_id` com o ID do NAT**. O `validate` e o `plan` aceitam, porque para eles é só um texto. O plan atual mostra:

```
+ route = [
    + {
        + cidr_block     = "0.0.0.0/0"
        + gateway_id     = (known after apply)
        + nat_gateway_id = ""
        ...
```

O argumento próprio para NAT é **`nat_gateway_id`**:

```hcl
route {
  cidr_block     = local.internet_cidr_block
  nat_gateway_id = aws_nat_gateway.algadelivery.id
}
```

> ✅ **Resolvido no módulo:** `modules/vpc/main.tofu` usa `nat_gateway_id = aws_nat_gateway.main.id`. Num plan de teste (com blocos `moved`, doc 21), a rota privada não aparece mais como alterada.
>
> 🔴 **Histórico do problema:** com o código antigo aplicado, **todo** `tofu plan` mostra a rota privada sendo "corrigida". Trecho real (ID do NAT encurtado):
> ```
>   ~ resource "aws_route_table" "private" {
>       ~ route = [
>           - {
>               - cidr_block     = "0.0.0.0/0"
>               - gateway_id     = ""
>               - nat_gateway_id = "nat-12a4…"
>               ...
>           + {
>               + cidr_block     = "0.0.0.0/0"
>               + gateway_id     = "nat-12a4…"
>               + nat_gateway_id = ""
> ```
> A AWS guarda a rota como de NAT (`nat_gateway_id`); o código manda em `gateway_id`. O apply "corrige", a AWS guarda de novo como NAT, e o ciclo se repete. A solução é usar `nat_gateway_id` no código.

Com `gateway_id`, a AWS pode registrar a rota como sendo de NAT e o provider ler de volta em `nat_gateway_id`. O código diria uma coisa e o state outra: **diff permanente** (todo `plan` querendo "corrigir" a rota), ou erro no apply. **Como conferir:** depois do `apply`, rode `tofu plan` de novo. Precisa dar `No changes`. Se aparecer `~ route` na tabela privada, é isso.

## Rotas inline x recurso `aws_route`

As rotas também podem ser recursos separados:

```hcl
resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.algadelivery.id
}
```

- Útil quando outra parte do código (ou outro state) precisa **adicionar** rotas a uma tabela existente.
- **Não misture** as duas formas na mesma tabela: o bloco inline acha que é dono de todas as rotas e remove as do `aws_route` a cada apply.

## No `plan`

O state estava vazio (houve `destroy`), então tudo entra: **23 to add**.

```
  # aws_route_table.private will be created
  # aws_route_table.public will be created
  # aws_route_table_association.private_cluster["private_a"] will be created
  # ... private_cluster b, c · private_management a, b, c
  # aws_route_table_association.public["public_a"] will be created
  # ... public b, c
  ...
Plan: 23 to add, 0 to change, 0 to destroy.
```

| Grupo | Qtd |
|-------|-----|
| VPC | 1 |
| Subnets (3 públicas + 3 mgmt + 3 cluster) | 9 |
| IGW + NAT | 2 |
| Route tables | 2 |
| Associations | 9 |
| **Total** | **23** |

## Como conferir depois do `apply`

```bash
# Rotas e associations das tabelas da VPC (só leitura)
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$(tofu output -raw vpc_id)" \
  --query 'RouteTables[].{Nome:Tags[?Key==`Name`]|[0].Value,Rotas:Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId],Subnets:Associations[].SubnetId}'
```

- No console: **VPC → sua VPC → aba "Resource map"** desenha subnets → route tables → gateways. É ótimo para conferir visualmente.
- Para provar que a internet funciona de verdade, é preciso uma instância numa subnet (ex.: EC2 privada acessada via SSM rodando `curl`). Fica para um próximo assunto.

## Pegadinhas

- **Uma subnet tem exatamente uma route table.** Associar uma segunda dá erro; a association **substitui** a main route table para aquela subnet.
- A **main route table** continua existindo (criada com a VPC, só com `local`). Subnets novas sem association caem nela, ou seja, ficam isoladas. Para gerenciá-la existe o `aws_default_route_table`.
- **Mudar o alvo de uma rota** (ex.: trocar `gateway_id` por `nat_gateway_id`) é um update **no lugar** (`~`): a tabela não é recriada.
- `0.0.0.0/0` cobre só **IPv4**. Para IPv6 seria `::/0` (com um *egress-only internet gateway* nas privadas).
- Subnet pública com rota para o IGW **ainda não basta** para um recurso ser acessível: ele também precisa de IP público (`map_public_ip_on_launch = true` na subnet, ou um IP elástico) e de um security group liberando a porta (ver [17-security-groups.md](17-security-groups.md)).
- **Destroy:** o OpenTofu remove as associations, depois as tabelas, depois NAT e IGW. As referências resolvem a ordem.
