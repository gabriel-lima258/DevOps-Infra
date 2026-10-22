# 17. Security Groups (bastion + privado)

> **Atualização (módulo EC2):** a instância, o key pair, o `.pem`, o Elastic IP e o Security Group agora moram no módulo `modules/ec2`, chamado duas vezes (`module.bastion` e `module.rancher`). O código abaixo é a versão anterior; os conceitos são os mesmos. Ver [23-modulo-ec2.md](23-modulo-ec2.md).

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

## O que é

Um **Security Group (SG)** é um **firewall** colado em cada recurso: na verdade, na **interface de rede** (ENI) de uma EC2, de um banco RDS, de um load balancer…

Até aqui, as route tables (doc 16) definiram **por onde** o tráfego pode ir. O Security Group define **quem pode bater em qual porta** de cada recurso. São camadas diferentes:

```
Route table   → "existe caminho até aqui?"
Security Group → "este recurso aceita esta conexão?"
```

Três regras de ouro:

1. **Tudo que entra é negado por padrão.** Você só escreve regras de **permitir** (*allow*). Não existe regra de "bloquear".
2. **É *stateful*:** se uma conexão foi permitida, a **resposta** volta sozinha, sem regra no sentido contrário.
3. Um recurso pode ter **vários SGs**: as permissões se somam.

### Security Group x Network ACL

A VPC também tem as **NACLs** (doc 11, criadas automaticamente). A diferença:

| | Security Group | Network ACL |
|---|---|---|
| Onde atua | Na **interface do recurso** (EC2, RDS…) | Na **subnet** inteira |
| Estado | **Stateful** (a resposta volta sozinha) | **Stateless** (precisa de regra de ida e de volta) |
| Regras | Só **allow** | **Allow e deny**, avaliadas por número |
| Padrão | Nega entrada, libera saída | A NACL padrão libera tudo |
| Uso comum | O firewall do dia a dia | Bloqueios amplos (ex.: negar uma faixa de IP) |

Na prática, quase tudo se resolve com Security Groups.

## Anatomia de uma regra

```hcl
ingress {                                  # ingress = ENTRADA · egress = SAÍDA
  description = "SSH da internet"          # texto livre (aparece no console)
  from_port   = 22                         # porta inicial
  to_port     = 22                         # porta final (faixa 22-22 = só a 22)
  protocol    = "tcp"                      # tcp, udp, icmp ou "-1" (todos)
  cidr_blocks = ["0.0.0.0/0"]              # DE ONDE (entrada) / PARA ONDE (saída)
}
```

| Campo | Valores comuns |
|-------|----------------|
| `protocol` | `"tcp"`, `"udp"`, `"icmp"`, `"-1"` = **todos** os protocolos (aí as portas devem ser `0`) |
| `from_port`/`to_port` | `22` SSH · `80` HTTP · `443` HTTPS · `5432` PostgreSQL · `0`/`0` com `-1` = todas |
| Origem/destino | `cidr_blocks` (faixas de IP) **ou** `security_groups` (outro SG: "quem tiver aquele SG") |

## O padrão bastion (jump host)

As VMs nas subnets **privadas** não são alcançáveis da internet (doc 15). Como um administrador chega nelas? Por um **bastion**: uma VM pequena numa subnet **pública** que serve de "portaria".

```
 Você (internet)
     │  SSH porta 22
     ▼
┌──────────────────────── subnet pública ────────────────────────┐
│  EC2 bastion        SG bastion_sg: aceita 22 só do SEU IP /32   │
└─────────────┬──────────────────────────────────────────────────┘
              │  SSH porta 22 (de dentro da VPC)
              ▼
┌──────────────────────── subnet privada ────────────────────────┐
│  EC2 privada        SG vm_private_sg: aceita 22 de 172.25.0.0/16│
└────────────────────────────────────────────────────────────────┘
```

- **Um único ponto de entrada** para auditar e proteger, em vez de dar IP público a cada VM.
- Da sua máquina: `ssh -J ec2-user@<ip-do-bastion> ec2-user@<ip-privado-da-vm>` (`-J` = *jump*).

## O código (`security_group.tofu`)

> **Atualização:** as regras do `bastion_sg` agora são geradas por **`dynamic` blocks** a partir de listas (variáveis + padrões no `local.tofu`), com novas regras 80/443. Ver [20-dynamic-blocks.md](20-dynamic-blocks.md). O **`vm_private_sg` saiu do código** junto com a VM privada. O código abaixo é o da primeira versão, mantido para explicar os conceitos.

### SG do bastion

```hcl
resource "aws_security_group" "bastion" {
  name        = "bastion_sg"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.algadelivery.id

  ingress {
    description = "SSH da internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_public_ip]             # SÓ o seu IP /32 (descoberto por data source, doc 18)
  }

  egress {
    description = "Todo o trafego de saida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"                             # todos os protocolos
    cidr_blocks = [local.internet_cidr_block]
  }

  tags = merge(local.common_tags, {             # tags comuns + Name (doc 18)
    Name = "bastion_sg"
  })
}
```

### SG das VMs privadas

```hcl
resource "aws_security_group" "vm_private" {
  name        = "vm_private_sg"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.algadelivery.id

  ingress {
    description = "SSH para VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.algadelivery.cidr_block]   # 172.25.0.0/16 = qualquer IP da VPC
  }

  egress { ... mesmo do bastion: tudo liberado ... }
}
```

| Trecho | O que faz |
|--------|-----------|
| `vpc_id = aws_vpc.algadelivery.id` | SG pertence a **uma VPC**; só recursos dela podem usá-lo |
| `name` | Nome do SG na AWS (único por VPC). Diferente da tag `Name`, que é só exibição |
| `cidr_blocks = [local.my_public_ip]` | Só o seu IP público, no formato `x.x.x.x/32`, calculado em `local.tofu` a partir do data source `http` ([doc 18](18-data-sources-e-functions.md)). Note os `[ ]`: é uma **lista** |
| `cidr_blocks = [local.internet_cidr_block]` (egress) | Reaproveita o `"0.0.0.0/0"` do `local.tofu` (doc 06) |
| `cidr_blocks = [aws_vpc.algadelivery.cidr_block]` | Lê o CIDR **da própria VPC** por referência. Se o CIDR mudar, a regra acompanha |
| egress `-1` para `0.0.0.0/0` | Saída livre: a VM pode baixar pacotes (via NAT nas privadas, via IGW no bastion) |

### Quem pode falar com quem (hoje)

| De → Para | Porta | Permitido? | Por quê |
|-----------|-------|-----------|---------|
| **Seu IP** → bastion | 22 | ✅ | ingress `local.my_public_ip` (`/32`) no `bastion_sg` |
| Qualquer outro IP → bastion | 22 | ❌ | Não está na regra |
| Internet → bastion | 80/443/outras | ❌ | Nenhuma regra (nega por padrão) |
| Bastion → VM privada | 22 | ✅ | O IP do bastion está em `172.25.0.0/16` |
| **Qualquer recurso da VPC** → VM privada | 22 | ✅ ⚠️ | A regra aceita a VPC inteira, não só o bastion |
| Internet → VM privada | qualquer | ❌ | Sem rota (subnet privada) **e** sem regra |
| VMs → internet | qualquer | ✅ | egress liberado (+ rotas IGW/NAT) |

## ⚠️ Pontos de atenção (e como melhorar)

O código funciona e é um ótimo começo. Para fins didáticos, estes são os ajustes que um ambiente real faria:

### 1. SSH aberto para o mundo

> ✅ **Resolvido** na etapa seguinte: o bastion passou a aceitar só `local.my_public_ip`, descoberto automaticamente pelo data source `http` + functions `trimspace` e `/32`. Ver [18-data-sources-e-functions.md](18-data-sources-e-functions.md). O texto abaixo explica o problema original.

Na primeira versão, `0.0.0.0/0` na porta 22 = **qualquer IP do planeta** pode tentar logar. Robôs varrem a internet atrás de porta 22 aberta o tempo todo.

- **Melhor:** só o seu IP, com `/32` = um único endereço:
  ```hcl
  variable "my_ip_cidr" {
    description = "Seu IP público em CIDR /32, ex.: 203.0.113.10/32"
    type        = string
  }
  # ingress do bastion:
  cidr_blocks = [var.my_ip_cidr]
  ```
  Descubra seu IP com `curl -s https://checkip.amazonaws.com`.
- **Ainda melhor:** **AWS Systems Manager Session Manager (SSM).** Acesso ao terminal da VM pelo console/CLI, **sem porta 22 aberta, sem chave SSH e muitas vezes sem bastion**. A VM só precisa de uma IAM role com `AmazonSSMManagedInstanceCore` e saída para a internet (o NAT já resolve).

### 2. SG privado aceita a VPC inteira

`cidr_blocks = [172.25.0.0/16]` deixa **qualquer coisa** da VPC (inclusive pods do cluster) tentar SSH nas VMs privadas. O ideal é o **menor privilégio**: só quem tem o SG do bastion.

```hcl
ingress {
  description     = "SSH vindo do bastion"
  from_port       = 22
  to_port         = 22
  protocol        = "tcp"
  security_groups = [aws_security_group.bastion.id]   # referência a outro SG
}
```

Referenciar um SG em vez de um CIDR significa "aceite quem estiver usando aquele SG", **independente do IP**. Se o bastion for recriado com outro IP, a regra continua valendo.

### 3. `description` copiada

Os dois SGs dizem `"Allow TLS inbound traffic and all outbound traffic"`, mas a regra é **SSH** (TLS seria a 443). Vale corrigir, **sabendo que mudar a `description` de um `aws_security_group` recria o SG** (`-/+`), assim como mudar o `name`. Com o state vazio ou em estudo, sem problema; em produção, planeje.

### 4. Regras inline x recursos de regra

Hoje as regras ficam dentro do SG (`ingress { }`/`egress { }`). A documentação atual do provider AWS recomenda **um recurso por regra**:

```hcl
resource "aws_vpc_security_group_ingress_rule" "vm_private_ssh" {
  security_group_id            = aws_security_group.vm_private.id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}
```

- Vantagem: adicionar ou remover uma regra não reescreve o SG inteiro, e cada regra tem tags e ID próprios.
- **Não misture** as duas formas no mesmo SG: o bloco inline "é dono" de todas as regras e apaga as outras a cada apply. É o mesmo problema das rotas inline x `aws_route` do doc 16.

### 5. Faltam outputs

As EC2 (próximo passo) vão precisar dos IDs dos SGs:

```hcl
output "sg_bastion_id" {
  value = aws_security_group.bastion.id
}

output "sg_vm_private_id" {
  value = aws_security_group.vm_private.id
}
```

> Os trechos desta seção foram testados com `tofu validate` numa cópia do projeto. O código real **não** foi alterado.

## Os SGs presos às EC2 ✅

Security Groups sozinhos não fazem nada: eles precisam estar **presos a um recurso**. Isso foi feito em [19-ec2-bastion-e-vm-privada.md](19-ec2-bastion-e-vm-privada.md):

| Item | Como ficou |
|------|------------|
| EC2 bastion | Subnet `public["public_a"]`, `vpc_security_group_ids = [aws_security_group.bastion.id]` |
| IP público no bastion | `associate_public_ip_address = true` |
| Key pair | `aws_key_pair.algadelivery`, com a chave gerada por `tls_private_key` |
| EC2 privada | Subnet `private_management["private_a"]`, `vpc_security_group_ids = [aws_security_group.vm_private.id]` |

## No `plan`

Cada SG aparece com suas regras:

```
  # aws_security_group.bastion will be created
  + resource "aws_security_group" "bastion" {
      + description = "Allow TLS inbound traffic and all outbound traffic"
      + egress      = [
          + { cidr_blocks = ["0.0.0.0/0"], from_port = 0, protocol = "-1", to_port = 0, ... },
        ]
      + ingress     = [
          + { cidr_blocks = ["0.0.0.0/0"], description = "SSH da internet", from_port = 22, protocol = "tcp", to_port = 22, ... },
        ]
      + name        = "bastion_sg"
      + vpc_id      = (known after apply)
      ...
    }
```

## Como conferir depois do `apply`

```bash
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$(tofu output -raw vpc_id)" \
  --query 'SecurityGroups[].{Nome:GroupName,Entrada:IpPermissions,Saida:IpPermissionsEgress}'
```

No console: **EC2 → Security Groups**, filtrando pela VPC. A VPC também tem um SG `default`, criado automaticamente (doc 11) e não gerenciado aqui.

## Pegadinhas

- **Egress padrão:** a AWS cria todo SG com uma regra "saída liberada". O OpenTofu **remove** essa regra e deixa só as que você declarou. Por isso o código declara o egress explicitamente; sem ele, o SG ficaria **sem saída nenhuma**.
- **`name` e `description` são imutáveis:** mudar qualquer um recria o SG. Se ele estiver em uso por uma EC2, o destroy trava (`DependencyViolation`). Use `lifecycle { create_before_destroy = true }` com `name_prefix` em vez de `name` quando isso importar.
- **SG é por VPC:** não dá para usar `bastion_sg` numa instância de outra VPC.
- **Limites:** por padrão, 60 regras de entrada + 60 de saída por SG, e até 5 SGs por interface de rede.
- **Stateful não é "duas mãos":** liberar a saída para a porta 443 não libera **entrada** na 443. O stateful vale só para a **resposta** da conexão iniciada.
- Porta 22 liberada **não significa** acesso: ainda é preciso a chave SSH certa. Mas expor a porta aumenta a superfície de ataque (força bruta, falhas no OpenSSH).
