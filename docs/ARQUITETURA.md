# Arquitetura atual

> Diagrama vivo: atualizado a cada mudança no código. **Última atualização: 2026-10-22**, com as subnets em **grupos** (`map(map(object))`) e o novo grupo **database**.
> State: `s3://algadelivery-tfstate-devops/development/networking/remote.tfstate` · Região: `us-east-1` · Ambiente: `development`
> **Situação:** o código tem **35 recursos** (29 dentro de `module.vpc` + 6 na raiz). 🔴 O state ainda é o de antes dos módulos: **sem `moved` por chave, o próximo `apply` destrói 27 e cria 32**. Com os 23 `moved` do [doc 22](22-modulo-vpc-grupos-de-subnets.md#migração-do-state-moved-por-chave), o plan testado fica em 8 add / 8 change / 3 destroy (⚠️ inclui a substituição do bastion por AMI nova).

## Diagrama

```mermaid
flowchart TB
    internet(("Internet"))
    igw["Internet Gateway<br/>algadelivery-igw"]
    rtNat["Route table do NAT<br/>(criada pela AWS)<br/>0.0.0.0/0 → IGW"]
    rtPub["Route table pública<br/>algadelivery-rt-public<br/>local + 0.0.0.0/0 → IGW"]
    rtPvt["Route table privada<br/>algadelivery-rt-private<br/>local + 0.0.0.0/0 → NAT"]

    subgraph mod["module.vpc (modules/vpc)"]
    subgraph vpc["VPC algadelivery-vpc · 172.25.0.0/16"]
        ngw["NAT Gateway REGIONAL<br/>algadelivery-ngw<br/>cobre todas as AZs"]
        sgB["SG bastion_sg (dynamic blocks)<br/>in: 22 do SEU IP /32 · 80, 443 da VPC<br/>out: tudo (+80)"]

        subgraph aza["AZ us-east-1a"]
            pubA["pub-public-a<br/>172.25.1.0/24"]
            ec2B["EC2 algadelivery-bastion<br/>Ubuntu 22.04 · t3.micro"]
            eip["Elastic IP<br/>IP público fixo"]
            mgmtA["pvt-management-a<br/>172.25.4.0/24"]
            clA["pvt-cluster-a<br/>172.25.7.0/24"]
            dbA["pvt-database-a<br/>172.25.10.0/24"]
        end
        subgraph azb["AZ us-east-1b"]
            pubB["pub-public-b<br/>172.25.2.0/24"]
            mgmtB["pvt-management-b<br/>172.25.5.0/24"]
            clB["pvt-cluster-b<br/>172.25.8.0/24"]
            dbB["pvt-database-b<br/>172.25.11.0/24"]
        end
        subgraph azc["AZ us-east-1c"]
            pubC["pub-public-c<br/>172.25.3.0/24"]
            mgmtC["pvt-management-c<br/>172.25.6.0/24"]
            clC["pvt-cluster-c<br/>172.25.9.0/24"]
            dbC["pvt-database-c<br/>172.25.12.0/24"]
        end
    end
    end

    internet <--> igw
    ngw --> rtNat --> igw

    pubA --> rtPub
    pubB --> rtPub
    pubC --> rtPub
    rtPub <--> igw

    mgmtA --> rtPvt
    mgmtB --> rtPvt
    mgmtC --> rtPvt
    clA --> rtPvt
    clB --> rtPvt
    clC --> rtPvt
    dbA --> rtPvt
    dbB --> rtPvt
    dbC --> rtPvt
    rtPvt --> ngw

    ec2B --- pubA
    eip --- ec2B
    sgB -.- ec2B

    classDef pub fill:#dbeafe,stroke:#2563eb,color:#111
    classDef mgmt fill:#fef3c7,stroke:#d97706,color:#111
    classDef cluster fill:#ede9fe,stroke:#7c3aed,color:#111
    classDef gw fill:#dcfce7,stroke:#16a34a,color:#111
    classDef rt fill:#f1f5f9,stroke:#475569,color:#111
    classDef sg fill:#ffe4e6,stroke:#e11d48,color:#111
    classDef db fill:#fce7f3,stroke:#db2777,color:#111
    classDef ec2 fill:#fff7ed,stroke:#ea580c,color:#111,stroke-width:2px

    class pubA,pubB,pubC pub
    class mgmtA,mgmtB,mgmtC mgmt
    class clA,clB,clC cluster
    class dbA,dbB,dbC db
    class igw,ngw gw
    class rtPub,rtPvt,rtNat rt
    class sgB sg
    class ec2B,eip ec2
    style mod fill:transparent,stroke:#64748b,stroke-dasharray:6 4
```

**Legenda:** 🟦 pública · 🟨 privada de gerenciamento · 🟪 privada do cluster · 🌸 privada database · 🟩 gateways · ⬜ route tables · 🟥 security groups · 🟧 EC2/Elastic IP · moldura tracejada = módulo `vpc` (o bastion, o SG e o EIP ficam na raiz, mas aparecem dentro da VPC porque moram nela). Seta de mão dupla = entrada e saída; seta simples = só saída. Linha pontilhada = SG aplicado à EC2; linha cheia EC2—subnet = "mora nesta subnet".

> Para ver o diagrama renderizado: GitHub, ou no VS Code com uma extensão de Mermaid (ex.: *Markdown Preview Mermaid Support*).

## Versão texto (para o terminal)

```
                                   Internet
                                      │ ▲
                            ┌─────────▼─┴───────┐
                            │ Internet Gateway  │ algadelivery-igw
                            └──▲─────────────▲──┘
                               │             │ rt do NAT (AWS): 0.0.0.0/0 → igw
 rt-public: 0.0.0.0/0 → igw    │             │
┌──────────────────────────────┼─────────────┼────────────────────────────────┐
│ VPC 172.25.0.0/16            │   ┌─────────┴────────────┐                   │
│                              │   │ NAT Gateway REGIONAL │ algadelivery-ngw  │
│                              │   └─────────▲────────────┘                   │
│                              │             │ rt-private: 0.0.0.0/0 → nat    │
│                              │             │                                │
│    us-east-1a           us-east-1b                 us-east-1c               │
│  ┌──────────────────┐  ┌──────────────────┐   ┌──────────────────┐          │
│  │ pub-a     .1/24  │  │ pub-b     .2/24  │   │ pub-c     .3/24  │ → rt-public
│  │ mgmt-a    .4/24  │  │ mgmt-b    .5/24  │   │ mgmt-c    .6/24  │ → rt-private
│  │ cluster-a .7/24  │  │ cluster-b .8/24  │   │ cluster-c .9/24  │ → rt-private
│  │ database-a .10/24│  │ database-b .11/24│   │ database-c .12/24│ → rt-private
│  └──────────────────┘  └──────────────────┘   └──────────────────┘          │
│                                                                             │
│  SG bastion_sg (dynamic): in 22 do SEU IP · 80/443 da VPC · out tudo        │
│  EC2 algadelivery-bastion (pub-a) + Elastic IP (IP público fixo)            │
│        você ──SSH──► Elastic IP ──► bastion                                 │
│  (VM privada e vm_private_sg saíram do código)                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Recursos (no código)

| Recurso | Endereço no OpenTofu | Detalhe | Qtd |
|---------|----------------------|---------|-----|
| VPC | `module.vpc.aws_vpc.main` | `172.25.0.0/16` | 1 |
| Subnets públicas (grupo `public`) | `module.vpc.aws_subnet.public["pub_a\|b\|c"]` | `172.25.1-3.0/24` · `algadelivery-pub-public-{a,b,c}` | 3 |
| Subnets privadas (grupos `management`, `cluster`, `database`) | `module.vpc.aws_subnet.private["pvt_mgmt_*"\|"pvt_cluster_*"\|"pvt_db_*"]` | `172.25.4-12.0/24` · `algadelivery-pvt-<grupo>-{a,b,c}` | 9 |
| Internet Gateway | `module.vpc.aws_internet_gateway.main` | `algadelivery-igw` | 1 |
| NAT Gateway (regional) | `module.vpc.aws_nat_gateway.main` | `algadelivery-ngw` · 💲 por hora | 1 |
| Route table pública | `module.vpc.aws_route_table.public` | `0.0.0.0/0 → IGW` | 1 |
| Route table privada | `module.vpc.aws_route_table.private` | `0.0.0.0/0 → NAT` (`nat_gateway_id` ✅) | 1 |
| Associations públicas | `module.vpc.aws_route_table_association.public[...]` | 3 subnets → rt-public | 3 |
| Associations privadas | `module.vpc.aws_route_table_association.private[...]` | 9 subnets → rt-private | 9 |
| Security Group do bastion | `aws_security_group.bastion` | `bastion_sg` · regras via `dynamic` (in 22 do seu IP, 80/443 da VPC; out tudo + 80) | 1 |
| Chave SSH (gerada) | `tls_private_key.algadelivery` | RSA 4096 (⚠️ fica no state) | 1 |
| Key pair na AWS | `aws_key_pair.algadelivery` | `algadelivery-iac` (chave pública) | 1 |
| Arquivo da chave privada | `local_sensitive_file.private_key` | `./algadelivery-iac.pem` (0400) · `*.pem` no `.gitignore` ✅ | 1 |
| EC2 bastion | `aws_instance.bastion` | Ubuntu 22.04 · `t3.micro` · pub-a · 💲 | 1 |
| Elastic IP do bastion | `aws_eip.bastion` | IP público fixo · 💲 | 1 |
| **Total** | | | **35** |

Saíram do código (o próximo apply destrói): `aws_instance.vm_private` e `aws_security_group.vm_private`.

Data sources (leituras, não contam como recursos): `data.http.my_public_ip` e `data.aws_ami.ubuntu`.

Os IDs (`vpc-…`, `igw-…`, `rtb-…`) mudam a cada `destroy`/`apply`; consulte com `tofu output` (inclui `route_table_public_id` e `route_table_private_id`).

## Mapa de CIDRs

```
172.25.0.0/16
├── 172.25.0.0/24        livre
├── 172.25.1-3.0/24      públicas            (a, b, c)  → rt-public
├── 172.25.4-6.0/24      privadas management (a, b, c)  → rt-private
├── 172.25.7-9.0/24      privadas cluster    (a, b, c)  → rt-private
├── 172.25.10-12.0/24    privadas database   (a, b, c)  → rt-private
└── 172.25.13.0 … .255   livre (~243 blocos /24)
```

## Fluxos de tráfego (após o `apply`)

| Fluxo | Caminho | Funciona? |
|-------|---------|-----------|
| Subnet privada → internet (só saída) | subnet privada → rt-private → NAT → rt do NAT → IGW → Internet | ✅ (`nat_gateway_id` corrigido no módulo) |
| Subnet pública → internet | subnet pública → rt-public → IGW → Internet | ✅ se o recurso tiver IP público |
| Internet → recurso público (ex.: ALB) | Internet → IGW → rt-public → subnet pública | ✅ se o recurso tiver IP público + security group liberando |
| Internet → subnet privada | não existe, **por design** | 🔒 bloqueado, como deve ser |
| Entre subnets da VPC | rota `local` automática em todas as tabelas | ✅ (rota) · a porta depende do SG de destino |
| SSH: você → bastion | Seu IP → IGW → rt-public → Elastic IP → EC2 bastion (`bastion_sg`: 22 só do seu IP `/32`) | ✅ `ssh -i algadelivery-iac.pem ubuntu@ELASTIC_IP` |
| SSH: bastion → VM privada | — | ⏸️ a VM privada saiu do código |

## Pendências

> Data sources (`data.http.my_public_ip`, `data.aws_ami.ubuntu`) não aparecem no diagrama: não são recursos, só leituras.

1. 🔴 **`moved.tofu` com 23 blocos por chave antes do `apply`.** Sem ele: 32 add / 27 destroy. Com ele: 8 add / 8 change / 3 destroy ([doc 22](22-modulo-vpc-grupos-de-subnets.md#migração-do-state-moved-por-chave)). O `moved.tofu` do doc 21 ficou desatualizado (as chaves mudaram).
2. ⚠️ **O bastion vai ser substituído** porque a AMI mudou (`most_recent = true`): adicione `lifecycle { ignore_changes = [ami] }` antes do apply.
3. ⚠️ Chaves de subnets precisam ser únicas entre grupos (o `merge` sobrescreve em silêncio): `validation` sugerida no doc 22.
4. O grupo `database` não aparece nos outputs da raiz. As descriptions de `subnet_pvt_ids/arns` dizem "management". Nomes de outputs inconsistentes; `subnet_pub_ids["public"][0]` depende da ordem; `var.vpc_name` e `var.ami_id` sem uso.
5. As subnets `database` usam a route table privada (com saída via NAT). Se o banco não deve sair para a internet, ele precisa de uma route table própria.
6. ⚠️ Regras do bastion: entrada 80/443 da VPC sem uso; saída 80 redundante (doc 20).
7. A regra SSH do bastion usa o IP de **quem roda o tofu** (doc 18).
8. 💲 Custos: NAT (~US$ 0,045/h) + `t3.micro` + Elastic IP. `tofu destroy` ao terminar cada sessão.

## Histórico da arquitetura

| Data | Mudança |
|------|---------|
| 2026-10-19 | VPC `172.25.0.0/16` |
| 2026-10-19 | 3 subnets públicas |
| 2026-10-20 | Subnets via `for_each` · Internet Gateway |
| 2026-10-20 | 6 subnets privadas (management + cluster) · NAT Gateway regional · tags `Environment`/`ManagedBy` |
| 2026-10-20 | Route tables pública (→ IGW) e privada (→ NAT) + 9 associations: rede básica completa |
| 2026-10-20 | Security Groups `bastion_sg` e `vm_private_sg` (SSH) · outputs dos IDs das route tables |
| 2026-10-20 | Data source `http` (seu IP) → SSH do bastion só do seu IP `/32` · tags via `merge(local.common_tags, …)` · provider `http` |
| 2026-10-20 | EC2 bastion (pub-a) e VM privada (mgmt-a) · AMI Ubuntu via `data.aws_ami` · chave SSH gerada (`tls` + `aws_key_pair` + `.pem` local) · providers `tls` e `local` |
| 2026-10-22 | Subnets em grupos (`map(map(object))`, achatadas com `merge([for ...]...)`) · `aws_subnet.private` único · grupo **database** (`172.25.10-12.0/24`) · outputs agrupados · tags `pub-public-*` / `pvt-<grupo>-*` |
| 2026-10-20 | Rede movida para o **módulo `modules/vpc`** (`vpc.tofu` chama; outputs repassados) · `nat_gateway_id` corrigido · tag da VPC → `algadelivery-vpc` · outputs de bastion/SG/EIP/key pair |
| 2026-10-20 | Regras do SG do bastion via `dynamic` blocks (listas em variável + padrões no local) · Elastic IP no bastion · VM privada e `vm_private_sg` removidas · `*.pem` no `.gitignore` |

Detalhes de cada mudança: [CHANGELOG.md](CHANGELOG.md).
