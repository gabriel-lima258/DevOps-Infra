# 10. Organização dos arquivos (e módulos)

Com a VPC, o projeto deixou de ter um `main.tofu` único. Agora cada assunto fica num arquivo.

## A estrutura atual

```
devops/
├── providers.tofu    # bloco terraform (versões + backend) e provider "aws"
├── data.tofu         # data sources: data.http.my_public_ip, data.aws_ami.ubuntu
├── ec2.tofu          # chave SSH (tls + key pair + .pem), EC2 bastion e Elastic IP
├── local.tofu        # locals: context_name, ngw_regional_mode, internet_cidr_block, my_public_ip, common_tags
├── vpc.tofu          # CHAMA o módulo de rede: module "vpc" { source = "./modules/vpc" }
├── variables.tofu    # aws_region, environment, vpc_cidr_block, subnets, NAT, EC2, regras do bastion
├── security_group.tofu  # SG bastion_sg (regras via dynamic blocks)
├── outputs.tofu      # repassa outputs do módulo + bastion, SG, EIP, key pair
├── .terraform.lock.hcl
└── modules/
    └── vpc/          # MÓDULO: VPC, 9 subnets, IGW, NAT, route tables (doc 21)
        ├── main.tofu
        ├── variables.tofu   # inputs
        ├── outputs.tofu     # outputs
        └── locals.tofu
```

| Arquivo | O que vai nele |
|---------|----------------|
| `providers.tofu` | `terraform { required_providers, backend }` e `provider "aws"`: a "configuração da ferramenta" |
| `vpc.tofu` | A **chamada** do módulo de rede, com os inputs (ver [21-modules.md](21-modules.md)) |
| `modules/vpc/` | O **módulo** com toda a rede. Antes era o `networking.tofu` |
| `data.tofu` | **Leituras** de coisas que já existem (data sources), ver [18-data-sources-e-functions.md](18-data-sources-e-functions.md) |
| `ec2.tofu` | Servidores (EC2) e a chave SSH, ver [19-ec2-bastion-e-vm-privada.md](19-ec2-bastion-e-vm-privada.md) |
| `security_group.tofu` | Firewalls (security groups) dos recursos, ver [17-security-groups.md](17-security-groups.md) |
| `local.tofu` | Valores calculados (`locals`), ver [06-variaveis.md](06-variaveis.md#locals-valores-derivados) |
| `variables.tofu` | Entradas (ver [06-variaveis.md](06-variaveis.md)) |
| `outputs.tofu` | Saídas (ver [07-outputs.md](07-outputs.md)) |

## Como o OpenTofu enxerga isso

O OpenTofu lê **todos** os `.tofu` e `.tf` da pasta e junta tudo, como se fosse um arquivo só:

- A ordem dos arquivos não importa. A ordem de criação vem das referências (ver doc 05).
- `networking.tofu` usa `var.vpc_cidr_block` declarado em `variables.tofu` sem nenhum import.
- O nome do arquivo não tem significado para a ferramenta. `networking.tofu` poderia se chamar `xyz.tofu`; o nome é para **humanos**.
- Mover um recurso de um arquivo para outro **não muda nada** no plan, porque o endereço (`aws_vpc.algadelivery`) continua o mesmo.

## Arquivo ≠ módulo

> **Atualização:** o projeto agora tem um **módulo de verdade**, `modules/vpc`. Ver [21-modules.md](21-modules.md). A comparação abaixo continua valendo.

No dia a dia é comum dizer "separei em módulos", mas no OpenTofu **módulo** é outra coisa:

| | Arquivos separados (o que temos) | Módulo |
|---|---|---|
| O que é | Vários `.tofu` na **mesma pasta** | Uma **pasta** com seus `.tofu`, chamada por um bloco `module` |
| Escopo | Tudo compartilhado: qualquer arquivo vê qualquer `var`/recurso | Isolado: só entra o que for passado como variável e só sai o que for output |
| Reuso | Não | Sim: o mesmo módulo cria a VPC de dev, homolog e prod |
| Endereço | `aws_vpc.algadelivery` | `module.rede.aws_vpc.this` |

Tecnicamente, a pasta raiz já é um módulo, o **root module**. Ele só não é *chamado* por ninguém.

Prévia de como ficaria com um módulo de verdade (assunto futuro):

```
devops/
├── providers.tofu
├── main.tofu              # module "rede" { source = "./modules/vpc" ... }
└── modules/
    └── vpc/
        ├── main.tofu      # resource "aws_vpc" "this"
        ├── variables.tofu
        └── outputs.tofu
```

```hcl
module "rede" {
  source     = "./modules/vpc"
  cidr_block = var.vpc_cidr_block
  name       = var.vpc_name
}
```

## Um state por camada

A key do backend agora identifica a **camada**, não um recurso específico:

```hcl
key = "${var.environment}/networking/remote.tfstate"
```

```
development/networking/remote.tfstate
└─ ambiente ┘└─ camada ─┘
```

Por que separar camadas (rede, banco, aplicação…) em states diferentes:

- **Raio de impacto menor:** um `apply` errado na aplicação não toca na rede.
- **Plan mais rápido:** cada state tem menos recursos para checar.
- **Permissões:** quem mexe na aplicação não precisa de permissão sobre a VPC.
- A rede muda pouco; a aplicação muda o tempo todo.

Para uma camada ler valores de outra (ex.: a aplicação precisa do `vpc_id`), usa-se `terraform_remote_state` ou `data "aws_vpc"`, assunto para depois.

### O que aconteceu com o state do S3

A key antiga era `development/s3/algadelivery-teste-devops/remote.tfstate`. Ao trocar a key, o OpenTofu passa a apontar para **outro arquivo**: o state antigo não é movido nem apagado. Neste estudo, o bucket do S3 foi destruído e o arquivo de state antigo removido, então hoje o bucket de state só tem:

```
development/networking/remote.tfstate
```

> Trocar a key é trocar de state. Se o state antigo ainda tivesse recursos, eles ficariam "órfãos": existiriam na AWS, mas nenhum código os gerenciaria. Antes de trocar, faça `destroy` ou migre-os (`tofu init -migrate-state`, `tofu state mv`).

## Pegadinhas

- Dois arquivos declarando o mesmo bloco (`variable "aws_region"` em `variables.tofu` e em `providers.tofu`) dão erro `Duplicate variable declaration`.
- Só um bloco `backend` por projeto e só um `provider "aws"` sem `alias`.
- Arquivos em **subpastas não são lidos** automaticamente; só por meio de `module`.
- `.tofu` e `.tf` com o mesmo nome (`networking.tofu` e `networking.tf`): o OpenTofu usa o `.tofu` e ignora o `.tf`. Útil para manter compatibilidade com o Terraform.
- Rode `tofu fmt` na pasta toda: ele formata todos os arquivos de uma vez.
