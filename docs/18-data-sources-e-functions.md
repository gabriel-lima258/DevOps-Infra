# 18. Data Sources e Functions

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

Esta etapa não criou nenhum recurso novo na AWS. Ela deixou o código **mais inteligente e menos repetitivo**, com duas ferramentas:

| Ferramenta | Pergunta que responde | Uso no projeto |
|------------|-----------------------|----------------|
| **Data source** | "Qual é o valor de algo que **já existe** lá fora?" | Descobrir o seu IP público |
| **Function** | "Como **transformar** este valor?" | Limpar o IP (`trimspace`) e juntar tags (`merge`) |

## O que mudou e por quê

| Mudança | Antes | Depois | Por quê |
|---------|-------|--------|---------|
| SSH do bastion | `cidr_blocks = ["0.0.0.0/0"]` | `cidr_blocks = [local.my_public_ip]` | Só o **seu IP** pode tentar SSH, não o mundo inteiro (alerta nº 1 do doc 17) |
| Seu IP | (não existia) | `data "http"` + `trimspace()` + `/32` | O IP de casa muda; o código **descobre sozinho** em vez de você editar à mão |
| Tags | `Environment` + `ManagedBy` repetidos em **cada** recurso | `merge(local.common_tags, { Name = ... })` | As tags comuns ficam **num lugar só** (DRY: *Don't Repeat Yourself*) |
| Providers | só `aws` | `aws` + `http` | O data source `http` vem de outro provider |

## Data sources

### Resource x data source

| | `resource` | `data` |
|---|---|---|
| O que faz | **Cria e gerencia** algo | **Só lê** algo que já existe |
| Entra no `destroy`? | Sim | Não: não há nada para destruir |
| Quando roda | No `apply` | A cada `plan`/`apply`/`refresh`: é **lido de novo toda vez** |
| Referência | `aws_vpc.algadelivery.id` | `data.http.my_public_ip.response_body` (com o prefixo `data.`) |

Analogia: um `resource` é **construir** uma casa; um `data` é **consultar o endereço** de uma casa que já está lá.

### O data source do projeto (`data.tofu`)

```hcl
data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com/"
}
```

- `"http"` é o **tipo**: faz um `GET` numa URL. `"my_public_ip"` é o **nome lógico**.
- O serviço `checkip.amazonaws.com` (da própria AWS) responde com o IP de quem fez a requisição. Teste no terminal: `curl https://checkip.amazonaws.com/`.
- A resposta fica em `data.http.my_public_ip.response_body`, por exemplo `"203.0.113.10\n"` (com quebra de linha no fim).

No `plan`, o data source aparece **antes** do diff, sendo lido:

```
data.http.my_public_ip: Reading...
data.http.my_public_ip: Read complete after 1s [id=https://checkip.amazonaws.com/]
```

E o SG do bastion já recebe o IP calculado (mascarado aqui):

```
      + ingress = [
          + {
              + cidr_blocks = [
                  + "x.x.x.x/32",
```

### Um segundo provider: `http`

O data source `http` não vem do provider AWS. Por isso o `providers.tofu` ganhou:

```hcl
required_providers {
  aws = {
    source  = "hashicorp/aws"
    version = "~> 6.0"
  }
  http = {
    source  = "hashicorp/http"
    version = "~> 3.0"
  }
}
```

- O provider `http` **não tem bloco `provider "http" { }`**: ele não precisa de configuração (região, credenciais…).
- ⚠️ **Provider novo = `tofu init` de novo.** Sem isso, o `validate`/`plan` falha com:
  ```
  Error: Missing required provider
  This configuration requires provider registry.opentofu.org/hashicorp/http,
  but that provider isn't available. You may be able to install it
  automatically by running:
    tofu init
  ```
- O `init` baixa o `hashicorp/http` (testado: v3.6.2) e **atualiza o `.terraform.lock.hcl`**, que deve ir para o git (doc 03).

### Outros data sources úteis da AWS

Testados com `tofu validate` numa cópia do projeto:

```hcl
# As AZs disponíveis na região, em vez de fixar "a", "b", "c"
data "aws_availability_zones" "available" {
  state = "available"
}
# uso: slice(data.aws_availability_zones.available.names, 0, 3)  →  ["us-east-1a", "us-east-1b", "us-east-1c"]

# Quem está rodando o tofu: account ID, ARN do usuário
data "aws_caller_identity" "current" {}
# uso: data.aws_caller_identity.current.account_id

# A região do provider
data "aws_region" "current" {}

# A imagem (AMI) mais recente do Amazon Linux 2023
# (o projeto acabou usando a do Ubuntu 22.04, com owner da Canonical: ver doc 19)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
# uso: ami = data.aws_ami.amazon_linux.id
```

Também é possível ler recursos de **outros states** ou criados à mão: `data "aws_vpc"`, `data "aws_subnet"` (com filtros por tag), ou `terraform_remote_state`.

## Functions

### O que são

Funções **embutidas** do OpenTofu para transformar valores: texto, listas, mapas, redes, datas… Não dá para escrever funções próprias em HCL. O OpenTofu 1.7+ também aceita funções vindas de providers (`provider::nome::funcao`), assunto avançado.

Sintaxe: `nome_da_funcao(argumento1, argumento2)`.

**Teste tudo no `tofu console`**, sem mexer em nada:

```bash
$ tofu console
> merge({ a = 1, b = 2 }, { b = 3 })
{
  "a" = 1
  "b" = 3
}
> format("%s-%s", "algadelivery", "igw")
"algadelivery-igw"
> join(",", ["a", "b"])
"a,b"
> lookup({ a = 1 }, "b", 0)
0
```

### As functions do projeto

#### `trimspace()`: limpar o IP

```hcl
my_public_ip = "${trimspace(data.http.my_public_ip.response_body)}/32"
```

Passo a passo:

| Etapa | Valor |
|-------|-------|
| `data.http.my_public_ip.response_body` | `"203.0.113.10\n"` (com `\n` no fim) |
| `trimspace(...)` | `"203.0.113.10"`: remove espaços e quebras de linha das pontas |
| `"${...}/32"` | `"203.0.113.10/32"`: vira um CIDR de **um único IP** |

**Por que o `trimspace` é obrigatório:** sem ele, o CIDR seria `"203.0.113.10\n/32"`, que é inválido, e a AWS recusaria a regra.

**Por que `/32`:** o SG espera CIDR, não um IP solto. `/32` = todos os 32 bits fixos = exatamente 1 endereço (doc 11).

#### `merge()`: juntar mapas (tags)

```hcl
# local.tofu
common_tags = {
  Environment = var.environment
  ManagedBy   = "OpenTofu"
}

# em cada recurso
tags = merge(local.common_tags, {
  Name = "${local.context_name}-igw"
})
```

Resultado (testado no `tofu console`):

```
{
  "Environment" = "development"
  "ManagedBy"   = "OpenTofu"
  "Name"        = "algadelivery-igw"
}
```

- `merge` recebe vários mapas e devolve **um só** com todas as chaves.
- **Se a mesma chave aparecer em mais de um mapa, vence o último.** Ex.: `merge(local.common_tags, { Environment = "teste" })` sobrescreve só nesse recurso.
- **Antes:** 3 linhas de tags × 13 recursos. **Depois:** as tags comuns num lugar só. Para adicionar `Project = "algadelivery"` a tudo, basta mudar o `common_tags`.

### Functions usadas em outros pontos do projeto/docs

| Function | Onde | O que faz |
|----------|------|-----------|
| `cidrhost`, `cidrsubnet` | docs 11, 12 | Calcular IPs e sub-faixas a partir de um CIDR |
| `can` | doc 06 (validation) | `true` se a expressão não der erro |
| `contains` | doc 06 (validation) | Se uma lista contém um valor |
| `values`, `toset` | doc 13 | Valores de um mapa; transformar lista em conjunto |
| `merge` | doc 15 (route table, prévia) e agora nas tags | Juntar mapas |

### Categorias (cola rápida)

| Categoria | Exemplos |
|-----------|----------|
| Texto | `lower`, `upper`, `trimspace`, `replace`, `format`, `split`, `join`, `substr` |
| Coleções | `merge`, `concat`, `length`, `lookup`, `keys`, `values`, `flatten`, `slice`, `distinct`, `contains` |
| Rede | `cidrhost`, `cidrsubnet`, `cidrsubnets`, `cidrnetmask` |
| Conversão de tipo | `tostring`, `tonumber`, `tolist`, `toset`, `tomap` |
| Codificação | `jsonencode`, `jsondecode`, `base64encode`, `yamlencode` |
| Arquivos | `file`, `templatefile` (ex.: o *user data* de uma EC2) |
| Erros | `can`, `try` |

Lista completa: https://opentofu.org/docs/language/functions/

## `merge` + `common_tags` x `default_tags`

O doc 15 sugeria `default_tags` no provider. O projeto escolheu `merge` + `local.common_tags`. Os dois funcionam:

| | `merge(local.common_tags, …)` (o adotado) | `default_tags` no provider |
|---|---|---|
| Onde se declara | `local.tofu` + uma linha em cada recurso | Uma vez, no `provider "aws"` |
| Recurso esquecido | Fica **sem** as tags comuns | Recebe as tags **automaticamente** |
| Visível no código do recurso | Sim, explícito | Não; aparece no plan em `tags_all` |
| Funciona com outros providers | Sim, é só um mapa | Só no provider AWS |
| Recursos que não aceitam `default_tags` | Sem problema | Alguns recursos (ex.: tags de instâncias criadas por ASG) precisam de tratamento à parte |

Regra prática: `default_tags` para garantir o mínimo (custos, dono); `merge` quando cada recurso precisa compor tags específicas. Dá para usar os dois.

## Locals podem usar data sources; variables não

```hcl
locals {
  my_public_ip = "${trimspace(data.http.my_public_ip.response_body)}/32"   # ✅ local lendo um data source
}

variable "my_ip" {
  default = data.http.my_public_ip.response_body                         # ❌ erro: default só aceita valor fixo
}
```

Por isso o IP calculado mora em `local.tofu` (doc 06).

## Pegadinhas

- **O IP é de quem roda o `tofu`.** No seu notebook, é o seu IP. Num pipeline de CI ou no computador de um colega, é o IP **daquela** máquina, e o SG do bastion muda para ele. Em equipe, use uma variável com a lista de IPs autorizados ou SSM Session Manager (doc 17).
- **IP dinâmico:** o provedor de internet troca o seu IP de tempos em tempos. Quando trocar, o próximo `plan` mostra `~ aws_security_group.bastion` (update da regra). É esperado: rode `apply` para liberar o IP novo.
- **VPN ou proxy:** o checkip vê o IP de saída da VPN, não o da sua casa.
- **Dependência externa:** sem internet ou com o checkip fora do ar, o `plan` **falha** (o data source não consegue ler).
- **IPv4 apenas:** o `checkip.amazonaws.com` devolve IPv4; a regra usa `cidr_blocks` (IPv4).
- **Data source é lido a cada `plan`:** valores que mudam (como IP) fazem o plan mostrar mudança. Valores que dependem de um recurso ainda não criado aparecem como `(known after apply)`.
- **Provider novo exige `tofu init`** e um commit do `.terraform.lock.hcl` atualizado.
