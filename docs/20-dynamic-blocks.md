# 20. Dynamic blocks: regras de Security Group geradas por lista

> **Atualização (módulo EC2):** a instância, o key pair, o `.pem`, o Elastic IP e o Security Group agora moram no módulo `modules/ec2`, chamado duas vezes (`module.bastion` e `module.rancher`). O código abaixo é a versão anterior; os conceitos são os mesmos. Ver [23-modulo-ec2.md](23-modulo-ec2.md).

Visão geral de como tudo se conecta: [ARQUITETURA.md](ARQUITETURA.md).

## O problema

Um Security Group com várias regras repete o **mesmo bloco** várias vezes, mudando só os valores:

```hcl
resource "aws_security_group" "bastion" {
  ingress { description = "SSH",   from_port = 22,  to_port = 22,  protocol = "tcp", cidr_blocks = [...] }
  ingress { description = "HTTP",  from_port = 80,  to_port = 80,  protocol = "tcp", cidr_blocks = [...] }
  ingress { description = "HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = [...] }
  egress  { ... }
}
```

O `for_each` do doc 13 **não resolve**: ele cria vários **recursos**, e aqui queremos **um** recurso com vários **blocos dentro** dele. É para isso que existe o `dynamic`.

| | `for_each` no recurso (doc 13) | `dynamic` (este doc) |
|---|---|---|
| Gera | Vários **recursos** (`aws_subnet.public["public_a"]`…) | Vários **blocos dentro** de um recurso (`ingress { }`, `egress { }`…) |
| Aceita | Mapa ou set | Lista, mapa ou set |
| Variável de cada volta | `each.key` / `each.value` | `<nome_do_bloco>.key` / `<nome_do_bloco>.value` |

## A sintaxe

```hcl
dynamic "ingress" {                         # 1. nome do bloco que será gerado
  for_each = local.bastion_ingress_rules    # 2. a lista: um bloco por item
  content {                                 # 3. o "molde" de cada bloco
    description = ingress.value.description # 4. ingress.value = o item da vez
    from_port   = ingress.value.from_port
    to_port     = ingress.value.to_port
    protocol    = ingress.value.protocol
    cidr_blocks = ingress.value.cidr_blocks
  }
}
```

Leia como: **"para cada regra da lista, gere um bloco `ingress` com estes campos"**.

- O rótulo (`"ingress"`) precisa ser o nome **exato** de um bloco que o recurso aceita.
- Dentro do `content`, o item da vez se chama pelo **nome do bloco**: `ingress.value` (o objeto) e `ingress.key` (o índice na lista, ou a chave no mapa).
- Para dar outro nome, use `iterator`:
  ```hcl
  dynamic "ingress" {
    for_each = local.bastion_ingress_rules
    iterator = regra
    content {
      from_port = regra.value.from_port
      # ...
    }
  }
  ```

## O código do projeto, passo a passo

### 1. As variáveis: listas de regras, vazias por padrão (`variables.tofu`)

```hcl
variable "bastion_ingress_rules" {
  description = "Ingress rules for bastion security group"
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}
# bastion_egress_rules: mesmo formato
```

O `type` garante que **toda regra** tenha os 5 campos com o tipo certo. Esquecer `protocol` numa regra dá erro já no `plan` (doc 06).

### 2. Os locals: "se ninguém passou regras, use estas" (`local.tofu`)

```hcl
bastion_ingress_rules = length(var.bastion_ingress_rules) > 0 ? var.bastion_ingress_rules : [
  {
    description = "SSH para minha maquina"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_public_ip]                     # data source (doc 18)
  },
  {
    description = "HTTP para VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.algadelivery.cidr_block]        # atributo de recurso
  },
  # HTTPS 443 da VPC ...
]
```

| Peça | O que faz |
|------|-----------|
| `length(var.bastion_ingress_rules) > 0` | A variável tem alguma regra? |
| `? var.bastion_ingress_rules` | Sim → usa as regras de quem rodou o tofu |
| `: [ ... ]` | Não → usa as regras padrão da lista |

**Por que os padrões estão no `local` e não no `default` da variável?** Porque eles usam `local.my_public_ip` (data source) e `aws_vpc.algadelivery.cidr_block` (recurso). O `default` de uma variável **só aceita valor fixo**; um local pode usar qualquer expressão (doc 18).

### 3. O SG usa os locals (`security_group.tofu`)

```hcl
resource "aws_security_group" "bastion" {
  name        = "bastion_sg"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.algadelivery.id

  dynamic "ingress" {
    for_each = local.bastion_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  dynamic "egress" {
    for_each = local.bastion_egress_rules
    content {
      description = egress.value.description
      # ... mesmos campos, com egress.value
    }
  }

  tags = merge(local.common_tags, {
    Name = "bastion_sg"
  })
}
```

### 4. As regras que saem disso (padrão)

| Direção | Porta | Origem/destino | Description |
|---------|-------|----------------|-------------|
| Entrada | 22/tcp | seu IP `/32` | SSH para minha maquina |
| Entrada | 80/tcp | VPC `172.25.0.0/16` | HTTP para VPC |
| Entrada | 443/tcp | VPC `172.25.0.0/16` | HTTPS para VPC |
| Saída | todas | `0.0.0.0/0` | Todo o trafego de saida |
| Saída | 80/tcp | `0.0.0.0/0` | HTTP para VPC |

### 5. No `plan`

Como o SG já existia com as regras antigas, o plan mostra um **update in-place** (o SG não é recriado; só as regras mudam). Trecho real, com o IP mascarado:

```
  # aws_security_group.bastion will be updated in-place
  ~ resource "aws_security_group" "bastion" {
      ~ egress  = [
          + {
              + cidr_blocks = ["0.0.0.0/0"]
              + description = "HTTP para VPC"
              + from_port   = 80
              ...
      ~ ingress = [
          - {
              - cidr_blocks = ["x.x.x.x/32"]
              - description = "SSH da internet"
              ...
          + {
              + cidr_blocks = ["172.25.0.0/16"]
              + description = "HTTP para VPC"
              + from_port   = 80
              ...
```

A regra SSH aparece saindo e entrando de novo porque a **description mudou** ("SSH da internet" → "SSH para minha maquina"): para a AWS é outra regra.

## Customizar sem mexer no código

Com as listas em variáveis, dá para trocar as regras por ambiente com um `.tfvars` (doc 06):

```hcl
# bastion.auto.tfvars
bastion_ingress_rules = [
  {
    description = "SSH do escritorio"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["203.0.113.10/32"]
  }
]
```

⚠️ **Passar a variável SUBSTITUI todas as regras padrão: não soma.** Testado no `tofu console` numa cópia: com o arquivo acima, `local.bastion_ingress_rules` vira só a regra "SSH do escritorio". O SSH do seu IP e as portas 80/443 somem. Se quiser somar, use `concat(padroes, var.bastion_ingress_rules)` no local.

## Revisão das regras atuais

O dynamic block está correto. Já as **regras** merecem uma olhada:

1. **Entrada 80/443 da VPC no bastion: para quê?** O bastion é uma "portaria" de SSH. Ele não serve site, então ninguém da VPC precisa acessar as portas 80/443 dele. Pelo princípio do menor privilégio (doc 17), porta aberta sem uso deve sair.
2. **Saída 80 é redundante.** A regra "Todo o trafego de saida" (`-1`, `0.0.0.0/0`) já libera a porta 80. A segunda não muda nada.
3. **As descriptions confundem a direção.** "HTTP **para** VPC" numa regra de **entrada** quer dizer "**da** VPC"; e na saída, o destino é `0.0.0.0/0` (a internet), não a VPC. Description é documentação: vale estar certa. Mas lembre que mudar a description de uma **regra** atualiza o SG (in-place), e mudar a `description` do **SG** recria o SG.

Exemplo enxuto para um bastion:

```hcl
bastion_ingress_rules = length(var.bastion_ingress_rules) > 0 ? var.bastion_ingress_rules : [
  {
    description = "SSH do meu IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_public_ip]
  }
]

bastion_egress_rules = length(var.bastion_egress_rules) > 0 ? var.bastion_egress_rules : [
  {
    description = "Saida liberada"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.internet_cidr_block]
  }
]
```

## Alternativa: um recurso por regra com `for_each`

O doc 17 citou que o provider AWS recomenda `aws_vpc_security_group_ingress_rule`. A mesma lista serve com `for_each` (testado com `tofu validate`):

```hcl
resource "aws_vpc_security_group_ingress_rule" "bastion" {
  for_each = { for r in local.bastion_ingress_rules : "${r.protocol}-${r.from_port}" => r }

  security_group_id = aws_security_group.bastion.id
  description       = each.value.description
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol
  cidr_ipv4         = each.value.cidr_blocks[0]
}
```

| | `dynamic` dentro do SG (o atual) | Recurso por regra |
|---|---|---|
| Mudar uma regra | Atualiza o SG inteiro | Atualiza só aquela regra |
| Endereço no state | Um recurso | Um por regra (`["tcp-22"]`) |
| Uma regra com vários CIDRs | Natural (`cidr_blocks` é lista) | Uma regra por CIDR |
| Misturar com regras inline | — | **Não misture** no mesmo SG |

Para estudo, o `dynamic` é ótimo. Em projetos grandes, o recurso por regra costuma dar diffs mais limpos.

## Quando NÃO usar `dynamic`

- Com **um ou dois blocos fixos**, escrever os blocos direto é mais fácil de ler.
- Abusar de `dynamic` dentro de `dynamic` deixa o código difícil de entender. A própria documentação do OpenTofu recomenda usá-lo com moderação.
- Use quando os blocos vêm de **dados** (variáveis, listas, mapas) ou quando o número de blocos **varia**.

## Outros usos comuns

`dynamic` funciona para **qualquer bloco aninhado repetível**:

- `route { }` em `aws_route_table` (várias rotas);
- `filter { }` em data sources como `aws_ami`;
- `setting { }` em Elastic Beanstalk, `tag { }` em Auto Scaling Group etc.

## Pegadinhas

- **Os dois lados do ternário precisam ter tipos compatíveis.** `var.bastion_ingress_rules` é `list(object(...))`; a lista padrão precisa ter **os mesmos campos**. Faltar um campo dá erro de tipo no `validate`.
- **A ordem da lista não gera diff** nas regras de SG: a AWS guarda as regras como conjunto. Já em blocos onde a ordem importa, reordenar a lista muda o plan.
- **Lista vazia = nenhum bloco.** Se as duas listas ficarem vazias, o SG fica sem entrada **e sem saída** (o OpenTofu remove o egress padrão da AWS, doc 17).
- O `for_each` de um `dynamic` aceita valores `(known after apply)`, como `aws_vpc.algadelivery.cidr_block` numa VPC ainda não criada. O `for_each` de **recurso** não aceita isso nas chaves.
- Rode `tofu fmt`: o `local.tofu` está com a indentação irregular nos blocos de regras (`fmt -check` falha).
