# 19. EC2: bastion e VM privada

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

> **Atualização:** a **VM privada** (`aws_instance.vm_private`) e o SG dela (`vm_private_sg`) **saíram do código**. O próximo `apply` destrói os dois. As seções sobre ela ficam como referência. O bastion ganhou um **Elastic IP** (seção 9), e as regras do SG passaram a usar `dynamic` blocks ([doc 20](20-dynamic-blocks.md)).

Até aqui o projeto construiu a **rede**: ruas (VPC, subnets), placas (route tables), portões (IGW, NAT) e porteiros (security groups). Agora chegam os primeiros **moradores**: dois servidores.

## O que é uma EC2, em uma frase

Uma **EC2** é um **computador alugado** na AWS. Você escolhe o sistema, o tamanho e onde ele fica, e paga por hora enquanto está ligado.

Para criar um, o OpenTofu precisa de 5 respostas:

| Pergunta | Peça | Analogia | No projeto |
|----------|------|----------|------------|
| Que sistema vem instalado? | **AMI** | O "pendrive de instalação" | Ubuntu 22.04 (via data source) |
| De que tamanho? | **Tipo de instância** | Quanta CPU e memória | `t3.micro` (2 vCPU, 1 GB) |
| Onde ele mora? | **Subnet** | O endereço na rede | Bastion: pública · VM: privada |
| Quem pode bater na porta? | **Security Group** | O porteiro | `bastion_sg` · `vm_private_sg` (doc 17) |
| Como eu entro? | **Key pair** | A chave da porta (SSH) | Gerada pelo próprio OpenTofu |

## Arquivos que mudaram

| Arquivo | O que entrou |
|---------|--------------|
| `providers.tofu` | Providers `tls` e `local` |
| `data.tofu` | `data "aws_ami" "ubuntu"` |
| `ec2.tofu` (novo) | Chave SSH + as duas instâncias |
| `variables.tofu` | `instance_type`, `keypair_name`, `ami_id` |

## 1. Os providers novos

```hcl
tls = {
  source  = "hashicorp/tls"      # gera chaves e certificados
  version = "~> 4.0"
}
local = {
  source  = "hashicorp/local"    # cria arquivos na SUA máquina
  version = "~> 2.0"
}
```

| Provider | Por que entrou |
|----------|----------------|
| `tls` | Para **gerar a chave SSH** dentro do OpenTofu, sem rodar `ssh-keygen` à mão |
| `local` | Para **salvar a chave privada** num arquivo `.pem` no seu computador |

Agora o projeto tem **4 providers** (aws, http, tls, local). Nenhum dos novos precisa de bloco `provider { }`.

> ⚠️ **Provider novo = `tofu init` de novo.** Sem ele: `Error: Missing required provider ... hashicorp/local`. O `init` instala (testado numa cópia: tls v4.4.1, local v2.9.1) e atualiza o `.terraform.lock.hcl`, que deve ser commitado.

## 2. A AMI: escolhendo o sistema operacional

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

É um **data source** (doc 18): não cria nada, só **procura** uma imagem que já existe.

| Configuração | Por quê |
|--------------|---------|
| `owners = ["099720109477"]` | É o ID de conta da **Canonical**, a empresa do Ubuntu. Garante que a imagem é **oficial**: qualquer pessoa pode publicar uma AMI chamada "ubuntu…", inclusive com malware |
| `filter name = "ubuntu/images/...jammy-22.04-amd64-server-*"` | Ubuntu **22.04 (Jammy)**, versão servidor. O `*` aceita qualquer data de build |
| `filter architecture = "x86_64"` | Processador Intel/AMD, que combina com o `t3.micro`. (Instâncias Graviton, como `t4g`, precisariam de `arm64`) |
| `filter virtualization-type = "hvm"` | Virtualização moderna, exigida pelos tipos atuais de instância |
| `most_recent = true` | Se várias imagens servirem (uma por build), pega **a mais nova**, com as últimas correções de segurança |

**Por que data source e não um ID fixo?** O ID de uma AMI (`ami-…`) é diferente **em cada região** e muda **a cada atualização**. Com o data source, o código funciona em qualquer região e sempre pega a versão atual. No plan de teste, ele achou `ami-09db1e291cef3f1ef`:

```
data.aws_ami.ubuntu: Reading...
data.aws_ami.ubuntu: Read complete after 1s [id=ami-09db1e291cef3f1ef]
```

> O `variables.tofu` também tem `ami_id = "ami-04680790a315cd58d"`, mas **ninguém usa** essa variável: as instâncias usam `data.aws_ami.ubuntu.id`. Pode ser removida, ou usada como alternativa ("se passar `ami_id`, use; senão, o data source").

## 3. A chave SSH em 3 passos

```hcl
# Passo 1: gera um par de chaves (pública + privada)
resource "tls_private_key" "algadelivery" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Passo 2: entrega a chave PÚBLICA para a AWS
resource "aws_key_pair" "algadelivery" {
  key_name   = var.keypair_name                                  # "algadelivery-iac"
  public_key = tls_private_key.algadelivery.public_key_openssh
}

# Passo 3: salva a chave PRIVADA no seu computador
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.algadelivery.private_key_pem
  filename        = "${path.module}/${var.keypair_name}.pem"     # ./algadelivery-iac.pem
  file_permission = "0400"
}
```

```
          tls_private_key (gera o par)
              │                    │
   chave PÚBLICA               chave PRIVADA
   (o "cadeado")               (a "chave")
              │                    │
              ▼                    ▼
       aws_key_pair         local_sensitive_file
   (AWS instala o cadeado    (./algadelivery-iac.pem
    nas EC2 com key_name)     no seu computador)
```

| Configuração | Por quê |
|--------------|---------|
| `algorithm = "RSA"`, `rsa_bits = 4096` | Tipo e tamanho da chave. 4096 bits é bem seguro (o `ED25519` também é aceito pela AWS e é mais moderno) |
| `public_key_openssh` | O formato que a AWS espera para a chave pública |
| `local_sensitive_file` (e não `local_file`) | Marca o conteúdo como **sensível**: não aparece no plan nem nos logs |
| `${path.module}` | A pasta do projeto. O `.pem` é criado ao lado dos `.tofu` |
| `file_permission = "0400"` | Só o dono pode **ler**. O `ssh` **recusa** chave com permissão aberta (`UNPROTECTED PRIVATE KEY FILE!`) |

## 4. As duas instâncias

### Bastion (a "portaria")

```hcl
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type                 # "t3.micro"
  subnet_id                   = aws_subnet.public["public_a"].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.keypair_name
  associate_public_ip_address = true

  tags = merge(local.common_tags, {
    Name = "${local.context_name}-bastion"
  })

  depends_on = [aws_key_pair.algadelivery]
}
```

### VM privada (o "servidor protegido")

```hcl
resource "aws_instance" "vm_private" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_management["private_a"].id
  vpc_security_group_ids = [aws_security_group.vm_private.id]
  key_name               = var.keypair_name

  tags = merge(local.common_tags, {
    Name = "${local.context_name}-vm-private"
  })

  depends_on = [aws_key_pair.algadelivery]
}
```

### O porquê de cada configuração

| Configuração | Bastion | VM privada | Por quê |
|--------------|---------|------------|---------|
| `ami` | Ubuntu 22.04 | Ubuntu 22.04 | Mesmo sistema nas duas, vindo do data source |
| `instance_type` | `t3.micro` | `t3.micro` | Pequena e barata, suficiente para estudo. Vem de variável para trocar fácil (`-var instance_type=t3.small`) |
| `subnet_id` | `public["public_a"]` | `private_management["private_a"]` | O bastion precisa ser alcançável da internet → subnet **pública**. A VM deve ficar escondida → subnet **privada** (de gerenciamento, doc 15). Ambas na AZ `a` |
| `vpc_security_group_ids` | `bastion_sg` | `vm_private_sg` | O porteiro de cada uma: bastion aceita SSH só do seu IP; a VM aceita SSH de dentro da VPC (doc 17) |
| `key_name` | `algadelivery-iac` | `algadelivery-iac` | A AWS instala a chave pública nas duas. A mesma chave abre as duas |
| `associate_public_ip_address` | `true` | (não tem) | As subnets públicas têm `map_public_ip_on_launch = false` (doc 12). Sem isso, o bastion não teria IP público e ninguém chegaria nele. A VM privada **não deve** ter IP público |
| `tags` | `algadelivery-bastion` | `algadelivery-vm-private` | `merge` com as tags comuns (doc 18) |
| `depends_on` | `aws_key_pair` | `aws_key_pair` | Ver abaixo |

### Por que o `depends_on`?

Normalmente o OpenTofu descobre a ordem sozinho pelas **referências** (doc 05). Mas aqui `key_name = var.keypair_name` usa a **variável**, e não o recurso `aws_key_pair`. Para o OpenTofu, a instância não "conhece" o key pair, e ele poderia tentar criar a EC2 **antes** da chave existir na AWS (`InvalidKeyPair.NotFound`).

O `depends_on` resolve dizendo explicitamente: "crie o key pair antes".

**Alternativa mais simples:** referenciar o recurso. A dependência vira implícita e o `depends_on` pode sair:

```hcl
key_name = aws_key_pair.algadelivery.key_name
```

Regra prática: **prefira referências**; use `depends_on` só quando não existe atributo para referenciar.

### Como o tráfego de cada uma flui

```
Você ──SSH 22──► IGW ──► rt-public ──► BASTION (pub-a, IP público, bastion_sg: só seu IP)
                                          │
                                          │ SSH 22 (rota local)
                                          ▼
                                       VM PRIVADA (mgmt-a, sem IP público, vm_private_sg: 22 da VPC)
                                          │
                                          │ apt update, downloads
                                          ▼
                                   rt-private ──► NAT ──► IGW ──► Internet
```

## 5. Como acessar (depois do `apply`)

Descobrir os IPs (ainda não há outputs para isso):

```bash
tofu state show aws_instance.bastion    | grep -E '^\s+public_ip '
tofu state show aws_instance.vm_private | grep -E '^\s+private_ip '
```

Entrar no bastion (usuário **`ubuntu`**, padrão das AMIs Ubuntu):

```bash
ssh -i algadelivery-iac.pem ubuntu@IP_PUBLICO_DO_BASTION
```

Pular do bastion para a VM privada, **sem copiar a chave para o bastion**:

```bash
ssh-add algadelivery-iac.pem                                   # carrega a chave no agente SSH
ssh -J ubuntu@IP_PUBLICO_DO_BASTION ubuntu@IP_PRIVADO_DA_VM    # -J = "pula" pelo bastion
```

> Nunca copie o `.pem` para dentro do bastion. Se o bastion for invadido, a chave de todas as VMs vai junto.

## 6. ⚠️ Pontos de atenção e melhorias

### 1. O `.pem` pode ir parar no git

> ✅ **Resolvido:** `*.pem` foi adicionado ao `.gitignore`.

🔴 **Urgente.** O arquivo `algadelivery-iac.pem` é criado **na pasta do projeto**, e o `.gitignore` **não** ignora `*.pem`. Um `git add .` publicaria a chave privada. Adicione ao `.gitignore` **antes** do próximo commit:

```
*.pem
```

### 2. A chave privada também fica no state

O `tls_private_key` grava a chave privada **no state**, em texto puro, no S3 (doc 08). Para estudo, ok. Em produção:

- gerar a chave fora do OpenTofu e só enviar a pública (`public_key = file("~/.ssh/id_ed25519.pub")`);
- ou dispensar chaves e usar **SSM Session Manager** (doc 17);
- e criptografar o state (doc 08).

### 3. A AMI nova vai querer recriar as EC2

Com `most_recent = true`, quando a Canonical publicar um build novo do Ubuntu (acontece com frequência), o próximo `plan` mostra:

```
-/+ resource "aws_instance" "bastion" {
      ~ ami = "ami-09db…" -> "ami-0abc…" # forces replacement
```

Ou seja: **destruir e recriar** as instâncias, perdendo tudo que estiver nelas. Para "travar" a AMI depois de criada:

```hcl
lifecycle {
  ignore_changes = [ami]
}
```

### 4. Faltam outputs

```hcl
output "bastion_public_ip" {
  description = "IP publico do bastion"
  value       = aws_instance.bastion.public_ip
}

output "vm_private_ip" {
  description = "IP privado da VM"
  value       = aws_instance.vm_private.private_ip
}

output "ssh_bastion" {
  description = "Comando para entrar no bastion"
  value       = "ssh -i ${var.keypair_name}.pem ubuntu@${aws_instance.bastion.public_ip}"
}
```

Aí basta `tofu output -raw ssh_bastion`.

### 5. Boas práticas de segurança (opcionais)

```hcl
metadata_options {
  http_tokens = "required"    # IMDSv2: protege as credenciais da instância contra ataques SSRF
}

root_block_device {
  encrypted = true            # disco criptografado
}
```

### 6. Pequenos ajustes

- `key_name = aws_key_pair.algadelivery.key_name` dispensa o `depends_on` (ver acima).
- `var.ami_id` sem uso.
- `tofu fmt`: o `ec2.tofu` está fora do padrão (`depends_on = [ aws_key_pair... ]` com espaços e o `filename` desalinhado).
- Pendências antigas: SG privado aceita a VPC inteira; description "Allow TLS"; `gateway_id` x `nat_gateway_id` na rota privada.

> Os trechos desta seção foram testados com `tofu validate` numa cópia do projeto. O código real **não** foi alterado.

## 7. No `plan`

Na cópia de teste (state vazio), o plano completo ficou com **30 recursos**: os 25 da rede e dos SGs, mais `tls_private_key`, `aws_key_pair`, `local_sensitive_file` e as 2 `aws_instance`.

```
data.aws_ami.ubuntu: Read complete after 1s [id=ami-09db1e291cef3f1ef]
  # aws_instance.bastion will be created
      + ami = "ami-09db1e291cef3f1ef"
  # aws_instance.vm_private will be created
  # aws_key_pair.algadelivery will be created
  # local_sensitive_file.private_key will be created
  # tls_private_key.algadelivery will be created
  ...
Plan: 30 to add, 0 to change, 0 to destroy.
```

## 8. Custos 💲

| Item | Preço aproximado (us-east-1) |
|------|------------------------------|
| `t3.micro` (cada, 2 no total) | ~US$ 0,0104/h (~US$ 7,50/mês) |
| IPv4 público do bastion | ~US$ 0,005/h |
| Disco (EBS gp2/gp3, 8 GB cada) | centavos/mês |
| NAT Gateway (já existente) | ~US$ 0,045/h + por GB |

O free tier pode cobrir parte das horas de `t3.micro`, dependendo da conta. Instância **parada** não cobra CPU, mas o disco e o IP elástico continuam cobrando. No estudo: `tofu destroy` ao terminar.

## 9. Elastic IP: um IP público fixo para o bastion

```hcl
// evita do bastion pub trocar o ip ao reinicializar
resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
}
```

| Configuração | Por quê |
|--------------|---------|
| `aws_eip` | Reserva um IP público **seu**, que não muda |
| `instance = aws_instance.bastion.id` | Prende o IP ao bastion. A referência faz o EIP ser criado depois da instância |
| `domain = "vpc"` | EIP para instâncias em VPC (o padrão atual; o antigo "EC2-Classic" não existe mais) |

**Por quê:** o IP público "automático" (`associate_public_ip_address = true`) **muda toda vez que a instância é parada e ligada**. Aí o comando SSH, o `known_hosts` e qualquer anotação ficam errados. O Elastic IP continua o mesmo.

Detalhes:

- Quando o EIP é associado, a AWS **libera** o IP automático: a instância fica só com o Elastic IP. O `associate_public_ip_address = true` passa a ser quase redundante, mas não atrapalha.
- O atributo `aws_instance.bastion.public_ip` pode ficar desatualizado no state até o próximo refresh. Para outputs e SSH, use **`aws_eip.bastion.public_ip`**:
  ```hcl
  output "bastion_public_ip" {
    value = aws_eip.bastion.public_ip
  }
  ```
- 💲 O EIP é cobrado como IPv4 público (~US$ 0,005/h), **inclusive com a instância parada**. O `destroy` libera o IP.
- Limite padrão: 5 Elastic IPs por região.

## Pegadinhas

- **Usuário de login depende da AMI:** Ubuntu = `ubuntu`; Amazon Linux = `ec2-user`; Debian = `admin`.
- **`Permission denied (publickey)`:** usuário errado, `.pem` errado ou permissão do arquivo (`chmod 400`).
- **Trocar `instance_type`** faz um update com a instância **parada e religada** (não recria); trocar `ami`, `subnet_id` ou `key_name` **recria**.
- **IP público muda** se a instância for parada e ligada de novo. Por isso o bastion ganhou um `aws_eip` (seção 9).
- **O SSH do bastion depende do seu IP atual** (data source `http`, doc 18): se o IP mudou, rode `tofu apply` antes de conectar.
- **`destroy`:** apaga as EC2 e o `.pem` local (é um recurso gerenciado). Num `apply` novo, uma chave **nova** é gerada.
