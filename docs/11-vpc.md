# 11. VPC

> **Atualização (módulos):** este código agora mora em `modules/vpc/main.tofu`, com endereços `module.vpc.aws_*.main` (antes: `aws_*.algadelivery`). Os trechos abaixo mostram a versão anterior; os conceitos são os mesmos. Ver [21-modules.md](21-modules.md).

Uma **VPC** (*Virtual Private Cloud*) é a sua rede privada isolada dentro da AWS. Servidores, bancos e containers moram dentro de uma VPC. É a fundação da infraestrutura: quase tudo depois depende dela.

## O código (`networking.tofu`)

```hcl
resource "aws_vpc" "algadelivery" {
  cidr_block = var.vpc_cidr_block
  tags = {
    Name = var.vpc_name
  }
}
```

Variáveis (`variables.tofu`):

```hcl
variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "172.25.0.0/16"
}

variable "vpc_name" {
  description = "The name of the VPC"
  type        = string
  default     = "algadelivery-vpc-devops"
}
```

| Argumento | Valor | Significado |
|-----------|-------|-------------|
| `cidr_block` | `172.25.0.0/16` | Faixa de IPs da rede (ver abaixo) |
| `tags.Name` | `algadelivery-vpc-devops` | O nome que aparece no console. A AWS usa a tag `Name` como nome de exibição |

## CIDR em 1 minuto

`172.25.0.0/16` = endereço base + **quantos bits são fixos**.

| CIDR | Bits livres | IPs | Uso típico |
|------|-------------|-----|------------|
| `/16` | 16 | 65.536 | VPC (o máximo que a AWS permite) |
| `/20` | 12 | 4.096 | Subnet grande |
| `/24` | 8 | 256 | Subnet comum |
| `/28` | 4 | 16 | Menor subnet permitida |

Com `/16`, todos os IPs da VPC começam com `172.25.` e vão de `172.25.0.0` a `172.25.255.255`.

Use faixas **privadas** (RFC 1918): `10.0.0.0/8`, `172.16.0.0/12` (de `172.16` a `172.31`; o `172.25` está aqui dentro) ou `192.168.0.0/16`.

> Teste no `tofu console`: `cidrhost("172.25.0.0/16", 10)` → `"172.25.0.10"`; `cidrsubnet("172.25.0.0/16", 8, 1)` → `"172.25.1.0/24"`. A função `cidrsubnet` será útil para criar subnets.

## O que a AWS cria sozinha junto com a VPC

Do `tofu state show aws_vpc.algadelivery` (resumido):

```
resource "aws_vpc" "algadelivery" {
    arn                       = "arn:aws:ec2:us-east-1:123456789012:vpc/vpc-05954ee76054928db"
    cidr_block                = "172.25.0.0/16"
    default_network_acl_id    = "acl-04c8da72125084d4e"
    default_route_table_id    = "rtb-07b612ae4300bcb45"
    default_security_group_id = "sg-0730f1bfb1fa89feb"
    enable_dns_hostnames      = false
    enable_dns_support        = true
    id                        = "vpc-05954ee76054928db"
    instance_tenancy          = "default"
    main_route_table_id       = "rtb-07b612ae4300bcb45"
    ...
}
```

Você declarou 1 recurso, mas a AWS criou junto:

| Recurso automático | Para que serve |
|--------------------|----------------|
| **Main route table** (`rtb-...`) | Tabela de rotas padrão: hoje só roteia dentro da VPC (`172.25.0.0/16 → local`) |
| **Network ACL padrão** (`acl-...`) | Firewall de subnet; o padrão libera tudo |
| **Security group padrão** (`sg-...`) | Firewall de instância; o padrão só aceita tráfego dele mesmo |

Eles **não** aparecem no `tofu state list` como recursos próprios; são atributos da VPC. Para gerenciá-los existem `aws_default_route_table`, `aws_default_security_group` etc.

> O account ID real foi trocado por `123456789012` neste doc. Evite publicar o seu.

## Atributos úteis que ficaram no padrão

| Atributo | Padrão | Quando mudar |
|----------|--------|--------------|
| `enable_dns_support` | `true` | Quase nunca desligue |
| `enable_dns_hostnames` | `false` | Ligue (`true`) se as instâncias precisarem de nome DNS público, ou para usar VPC endpoints/EKS. **Hoje ligado** no `modules/vpc` (junto com `enable_dns_support = true`) por causa do MSK Serverless ([doc 28](28-modulo-msk.md#mudança-na-vpc-dns-ligado)) |
| `instance_tenancy` | `default` | `dedicated` = hardware exclusivo e **caro** |

## Outputs

```hcl
output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.algadelivery.id
}

output "vpc_arn" {
  description = "The ARN of the VPC"
  value       = aws_vpc.algadelivery.arn
}
```

```bash
$ tofu output
vpc_arn = "arn:aws:ec2:us-east-1:123456789012:vpc/vpc-05954ee76054928db"
vpc_id = "vpc-05954ee76054928db"
```

O `vpc_id` é o valor que os próximos recursos (subnets, security groups) vão referenciar.

## Rodando

```bash
source .env
tofu init        # se mudou a key do backend: tofu init -reconfigure
tofu plan
tofu apply
```

Situação atual: aplicado; `tofu plan` → `No changes. Your infrastructure matches the configuration.`

## Custos

- **VPC, subnets, route tables, security groups e IGW: grátis.**
- Cobrados: **NAT Gateway** (por hora + por GB), **IPv4 público** (por hora, por IP), VPC endpoints de interface e tráfego entre AZs. Cuidado ao adicioná-los no estudo, e rode `destroy` no fim.

## Uma VPC sozinha ainda não serve para muito

Sem subnets, nada pode ser criado dentro dela. Próximos passos naturais:

1. ✅ `aws_subnet`: 3 subnets em 3 AZs, feito (ver [12-subnets.md](12-subnets.md)). Privadas (management + cluster) também ✅, ver [15-subnets-privadas-e-nat-gateway.md](15-subnets-privadas-e-nat-gateway.md).
2. ✅ `aws_internet_gateway`: a porta para a internet, feito (ver [14-internet-gateway.md](14-internet-gateway.md)).
3. ✅ `aws_route_table` + `aws_route_table_association`: pública → IGW e privada → NAT (ver [16-route-tables.md](16-route-tables.md)).
4. ✅ (pago) `aws_nat_gateway` regional: saída das subnets privadas, ver doc 15. A route table privada aponta para ele.

Como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

## Pegadinhas

- **Mudar o `cidr_block` recria a VPC** (`-/+`) e tudo que estiver dentro dela. Para ampliar, existe `aws_vpc_ipv4_cidr_block_association` (CIDR secundário).
- Planeje o CIDR pensando em conectar redes (peering, VPN, outras VPCs): faixas **não podem se sobrepor**. Ex.: dev `172.25.0.0/16`, homolog `172.26.0.0/16`.
- Limite padrão: **5 VPCs por região** por conta. Toda conta já vem com uma *default VPC* (`172.31.0.0/16`), que conta no limite.
- `destroy` da VPC falha (`DependencyViolation`) se houver algo criado fora do OpenTofu dentro dela, como uma EC2 criada pelo console. As subnets do projeto não atrapalham: o OpenTofu as destrói antes da VPC, por causa da dependência.
- A tag `Name` é só exibição: duas VPCs podem ter o mesmo `Name`. Quem identifica é o `id` (`vpc-...`).
