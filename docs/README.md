# Estudos de OpenTofu (IaC) na AWS

Documentação didática do projeto: como instalar, configurar e rodar o OpenTofu, e o que cada parte do código faz.

## 🗺️ [Arquitetura atual (diagrama)](ARQUITETURA.md)

Como tudo se conecta hoje: VPC, subnets, gateways e o que ainda falta. Atualizado a cada mudança.

## Ordem de leitura

| # | Doc | Assunto |
|---|-----|---------|
| 1 | [01-instalacao.md](01-instalacao.md) | Instalar OpenTofu e AWS CLI (Linux/WSL2 e macOS) |
| 2 | [02-credenciais-aws.md](02-credenciais-aws.md) | Credenciais AWS: `.env` x `aws configure` |
| 3 | [03-providers-e-init.md](03-providers-e-init.md) | Bloco `terraform`, providers e `tofu init` |
| 4 | [04-fluxo-de-trabalho.md](04-fluxo-de-trabalho.md) | Fluxo init → plan → apply → show → destroy |
| 5 | [05-bucket-s3-versionado.md](05-bucket-s3-versionado.md) | Bucket S3 + versionamento e referências entre recursos |
| 6 | [06-variaveis.md](06-variaveis.md) | Variáveis: declarar, usar, `.tfvars`, precedência e validação |
| 7 | [07-outputs.md](07-outputs.md) | Outputs: expor ARN, URL etc. e `tofu output` |
| 8 | [08-state.md](08-state.md) | State: anatomia, serial/lineage, histórico, drift, `tofu state`, criptografia |
| 9 | [09-backend-remoto-s3.md](09-backend-remoto-s3.md) | Backend remoto S3: um state por ambiente, migração, lock |
| 10 | [10-organizacao-dos-arquivos.md](10-organizacao-dos-arquivos.md) | Código separado por arquivos, arquivo x módulo, state por camada |
| 11 | [11-vpc.md](11-vpc.md) | VPC: CIDR, recursos automáticos, custos, próximos passos |
| 12 | [12-subnets.md](12-subnets.md) | Subnets: para que servem, pública x privada, AZs, CIDR |
| 13 | [13-loops-for-each-e-for.md](13-loops-for-each-e-for.md) | Loops: `for_each`, `count`, expressões `for`, `moved` |
| 14 | [14-internet-gateway.md](14-internet-gateway.md) | Internet Gateway: para que serve, IGW x NAT, ingredientes de subnet pública |
| 15 | [15-subnets-privadas-e-nat-gateway.md](15-subnets-privadas-e-nat-gateway.md) | Subnets privadas (management/cluster) e NAT Gateway zonal x regional |
| 16 | [16-route-tables.md](16-route-tables.md) | Route tables: como o tráfego é roteado, pública x privada, targets, associations |
| 17 | [17-security-groups.md](17-security-groups.md) | Security Groups: firewall stateful, SG x NACL, padrão bastion, menor privilégio |
| 18 | [18-data-sources-e-functions.md](18-data-sources-e-functions.md) | Data sources (ler o que existe) e functions (`trimspace`, `merge`…), com o porquê das mudanças |
| 19 | [19-ec2-bastion-e-vm-privada.md](19-ec2-bastion-e-vm-privada.md) | EC2: AMI via data source, chave SSH (tls/local), bastion e VM privada, como acessar |
| 20 | [20-dynamic-blocks.md](20-dynamic-blocks.md) | Dynamic blocks: regras de SG geradas por lista, padrões no local, revisão das regras |
| 21 | [21-modules.md](21-modules.md) | Modules: inputs, outputs, escopo isolado, refatorar sem destruir (`moved`) |
| 22 | [22-modulo-vpc-grupos-de-subnets.md](22-modulo-vpc-grupos-de-subnets.md) | Módulo VPC com grupos de subnets: `map(map(object))`, achatamento com `merge(...)`, outputs agrupados, `moved` por chave |
| 23 | [23-modulo-ec2.md](23-modulo-ec2.md) | Módulo EC2: um módulo chamado 2× (bastion/rancher), SG como `object`, `count` no EIP, nomes únicos, migração |
| 24 | [24-multiplos-ambientes.md](24-multiplos-ambientes.md) | Múltiplos ambientes: `envs/dev` e `envs/prod`, state por ambiente, como rodar, riscos |
| 25 | [25-lifecycle.md](25-lifecycle.md) | `lifecycle`: `ignore_changes`, `prevent_destroy`, `create_before_destroy`, `replace_triggered_by` |
| 26 | [26-comandos.md](26-comandos.md) | Cheat sheet de comandos |
| 📘 | [types_expression.md](types_expression.md) | Material de apoio (aula 04.04): tipos de coleção e for expressions, com exercícios |
| — | [CHANGELOG.md](CHANGELOG.md) | Diário de estudo: o que mudou e quando |

> Os docs 05 e 07 usam exemplos do bucket S3, que saiu do código. Ficam como referência dos conceitos.

## Estado atual do projeto

```
devops/
├── .env                   # credenciais AWS (fora do git)
├── .gitignore             # .env, .terraform/, *.tfstate, *.pem...
├── modules/
│   ├── vpc/               # MÓDULO: VPC, 12 subnets em grupos, IGW, NAT regional, route tables
│   └── ec2/               # MÓDULO: chave + key pair + .pem, SG (dynamic), EC2, Elastic IP (count)
├── envs/
│   ├── dev/               # ambiente development (root module): providers, data, vpc, ec2, local, variables, outputs
│   └── prod/              # ambiente production: mesmos arquivos, valores de prod
└── docs/                  # esta documentação (+ fluxo-opentofu.png)
```

- **OpenTofu:** 1.13.1
- **Providers:** `hashicorp/aws` 6.69.1 (`~> 6.0`), `hashicorp/http` (`~> 3.0`), `hashicorp/tls` (`~> 4.0`), `hashicorp/local` (`~> 2.0`). Um `.terraform.lock.hcl` por ambiente
- **Região:** `us-east-1`

| Ambiente | State | VPC | Status |
|----------|-------|-----|--------|
| `envs/dev` | `algadelivery/development/remote.tfstate` | `172.25.0.0/16` | ✅ aplicado: 35 recursos (`module.vpc` + `module.bastion`), plan sem mudanças |
| `envs/prod` | `algadelivery/production/remote.tfstate` | `172.26.0.0/16` | ⏸️ rode `tofu init -reconfigure` antes do primeiro plan |

- **Em cada ambiente:** `module.vpc` (VPC, 3 públicas + 9 privadas em grupos management/cluster/database, IGW, NAT regional 💲, route tables) e `module.bastion` (EC2 Ubuntu `t3.micro`, Elastic IP, SG via `dynamic`, key pair + `.pem`). `module.rancher` está comentado.
- Pendências e riscos: [ARQUITETURA.md](ARQUITETURA.md#pendências).

## Rodando rápido

![Fluxo de trabalho OpenTofu](fluxo-opentofu.png)

```bash
cd envs/dev       # o AMBIENTE é a pasta (envs/dev ou envs/prod)
source ../../.env # carrega as credenciais AWS no terminal
tofu init         # baixa os providers e configura o backend S3 (prod, 1ª vez: tofu init -reconfigure)
tofu plan         # mostra o que vai mudar
tofu apply        # aplica (pede confirmação "yes")
tofu show         # mostra o que está no state
tofu output       # mostra os outputs (ARN, domínio…)
tofu destroy      # remove tudo que o projeto criou
```
