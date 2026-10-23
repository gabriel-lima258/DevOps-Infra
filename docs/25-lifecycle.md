# 25. `lifecycle`: controlando como o OpenTofu cria, troca e apaga recursos

Visão geral: [ARQUITETURA.md](ARQUITETURA.md) · Módulo EC2: [23-modulo-ec2.md](23-modulo-ec2.md)

> **Atualização:** hoje o módulo está com `prevent_destroy = false`, e o `tofu destroy` voltou a funcionar (o dev foi destruído em 2026-10-23). O `ignore_changes = [ami]` continua.
>
> ⚠️ **De novo:** o módulo `elasticache` (doc 27) chegou com `prevent_destroy = true` fixo no cache. O `tofu destroy` do dev volta a falhar até usar a variável abaixo ([doc 27](27-modulo-elasticache.md#1--prevent_destroy--true-fixo-o-destroy-do-dev-volta-a-falhar)).

## O que é

Por padrão, o OpenTofu decide sozinho **quando** e **como** mexer num recurso: se um argumento imutável muda, ele **destrói e depois cria** (`-/+`); se você roda `destroy`, ele apaga; se algo mudou fora do código, ele "corrige".

O bloco `lifecycle` muda essas regras **para um recurso específico**. Ele é um *meta-argumento*: vale para qualquer tipo de recurso, não só AWS.

```hcl
resource "qualquer_tipo" "nome" {
  # ...argumentos do recurso...

  lifecycle {
    create_before_destroy = true        # na troca: cria o novo ANTES de apagar o velho
    prevent_destroy       = true        # recusa qualquer plano que apague este recurso
    ignore_changes        = [ami, tags] # ignora diferenças nesses atributos
    replace_triggered_by  = [ ... ]     # recria este recurso quando outro mudar
  }
}
```

| Opção | Em uma frase | Analogia |
|-------|--------------|----------|
| `create_before_destroy` | "Monte o novo antes de desmontar o velho" | Trocar o pneu com o estepe já pronto |
| `prevent_destroy` | "Não deixe apagar isto" | Trava de segurança |
| `ignore_changes` | "Não se preocupe com estes campos" | Fingir que não viu |
| `replace_triggered_by` | "Se aquilo mudar, refaça isto" | Gatilho |

## O que o projeto usa (`modules/ec2`)

```hcl
# modules/ec2/main.tofu
resource "aws_instance" "main" {
  # ...
  depends_on = [aws_key_pair.main]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami]
  }
}

# modules/ec2/security_group.tofu
resource "aws_security_group" "main" {
  name = var.security_group_config.name
  # ...

  lifecycle {
    create_before_destroy = true
  }
}
```

Como estão **dentro do módulo**, valem para **toda** instância e SG criados por ele, em **todos** os ambientes (dev e prod).

### 1. `ignore_changes = [ami]` na instância ✅

**O problema que resolve:** a AMI vem de `data "aws_ami"` com `most_recent = true` (doc 19). Toda vez que a Canonical publica um build novo do Ubuntu, o ID muda, e trocar a AMI de uma instância **força a recriação**. Isso já aconteceu neste estudo:

```
~ ami = "ami-09db1e291cef3f1ef" -> "ami-033ea4ff4a9c726dc" # forces replacement
```

**Com `ignore_changes = [ami]`:** depois que a instância existe, o OpenTofu **ignora** diferenças no campo `ami`. Ela continua com a imagem com que nasceu, e o `plan` não acusa mais nada. Hoje, em `envs/dev`: `No changes`.

**O efeito colateral:** a instância fica com a AMI antiga para sempre (sem as atualizações de segurança da imagem nova). Para atualizar de propósito, peça a recriação explicitamente:

```bash
tofu apply -replace='module.bastion.aws_instance.main'
```

> Atenção: com o `prevent_destroy` atual, esse `-replace` também é bloqueado (ver o item 2).

Outros usos comuns de `ignore_changes`: `tags` alteradas por outras ferramentas, `desired_count` de um ECS mexido por autoscaling, `user_data`. Use `ignore_changes = all` com muito cuidado: aí o OpenTofu só cria e apaga, e nunca atualiza.

### 2. `prevent_destroy = true` na instância ⚠️

**O que faz:** qualquer plano que **apague** a instância vira erro, e nada é aplicado. Saída real, em `envs/dev`:

```
$ tofu plan -destroy

Error: Resource instance cannot be destroyed

  on ../../modules/ec2/main.tofu line 23:
  23: resource "aws_instance" "main" {

Resource instance module.bastion.aws_instance.main has prevent_destroy set,
but the plan calls for it to be destroyed.
```

**Quando é útil:** recursos que **não podem** sumir por engano, como banco de produção, bucket com dados ou o bucket de state.

**Consequências no projeto:**

| Situação | Resultado |
|----------|-----------|
| `tofu destroy` no fim do estudo (dev) | ❌ **Falha.** O NAT, a VPC e o resto também não são apagados: o plano inteiro é recusado |
| A AMI muda | ✅ Sem problema (o `ignore_changes` já impede a troca) |
| `instance_type`, `subnet_id`, `key_name` ou outro campo imutável mudar | ❌ A substituição também é bloqueada: você precisa desligar a trava para conseguir mudar |
| Remover o `module "bastion"` do código | ❌ Bloqueado |

**Ponto de atenção para o estudo:** a recomendação de rodar `tofu destroy` ao terminar cada sessão (para não pagar NAT, EC2 e EIP) **deixou de funcionar** no dev. Para desligar a trava num ambiente, sem mexer no outro, use uma variável.

#### `prevent_destroy` por ambiente (com variável)

O OpenTofu aceita **variável** no `prevent_destroy`. Testado (OpenTofu 1.13): com `true`, o `plan -destroy` dá o erro acima; com `false`, o plano de destroy sai normal.

```hcl
# modules/ec2/variables.tofu
variable "prevent_destroy" {
  description = "Impede que a instancia seja destruida"
  type        = bool
  default     = false
}

# modules/ec2/main.tofu
lifecycle {
  prevent_destroy = var.prevent_destroy
  ignore_changes  = [ami]
}

# envs/dev/ec2.tofu   → prevent_destroy = false  (dá para destruir no fim do estudo)
# envs/prod/ec2.tofu  → prevent_destroy = true   (protegido)
```

> No Terraform, `lifecycle` só aceita valores fixos (literais). Variável em `prevent_destroy` é uma diferença do OpenTofu: se o código precisar rodar nos dois, use valor fixo.

`prevent_destroy` **não** protege contra: apagar pelo console da AWS, `tofu state rm`, ou alguém tirar o bloco `lifecycle` do código. Ele só bloqueia **planos** do próprio OpenTofu.

### 3. `create_before_destroy = true` no Security Group ⚠️

**O que faz:** quando o SG precisa ser **substituído** (por exemplo, ao mudar o `name` ou a `description`, que são imutáveis, doc 17), o OpenTofu cria o novo **antes** de apagar o velho. Sem isso, ele tentaria apagar o SG primeiro, e a AWS recusaria (`DependencyViolation`), porque a instância ainda o usa.

**O problema com o código atual:** o SG usa `name` **fixo** (`bastion-sg`). Criar o novo antes de apagar o velho significa ter **dois SGs com o mesmo nome na mesma VPC** por um momento, e a AWS não permite:

```
InvalidGroup.Duplicate: The security group 'bastion-sg' already exists for VPC 'vpc-…'
```

Ou seja, o `create_before_destroy` só funciona de verdade junto com um nome que **muda a cada criação**. A forma padrão é `name_prefix`:

```hcl
resource "aws_security_group" "main" {
  name_prefix = "${var.security_group_config.name}-"   # vira "bastion-sg-20261023..." (sufixo único)
  description = var.security_group_config.description
  vpc_id      = var.vpc_id
  # ...

  lifecycle {
    create_before_destroy = true
  }
}
```

> Trocar `name` por `name_prefix` também **recria** o SG uma vez (o nome muda). Com `create_before_destroy`, essa troca acontece sem tirar a instância do ar.

| Recurso com `name` fixo | `create_before_destroy` funciona? |
|-------------------------|-----------------------------------|
| Security Group (`name`) | ❌ Conflito de nome na substituição |
| Security Group (`name_prefix`) | ✅ |
| Key pair (`key_name` fixo) | ❌ Mesmo problema |
| Instância EC2 (só tag `Name`) | ✅ Tag não precisa ser única |

## `replace_triggered_by` (não usado ainda)

Recria um recurso quando **outro** muda, mesmo sem mudança nele próprio:

```hcl
resource "aws_instance" "main" {
  # ...
  lifecycle {
    replace_triggered_by = [aws_key_pair.main]   # chave nova → instância nova
  }
}
```

## Validação: `precondition` e `postcondition`

Também ficam dentro do `lifecycle`, mas servem para **checar** e não para controlar a troca:

```hcl
lifecycle {
  precondition {
    condition     = var.instance_type != ""
    error_message = "Informe o tipo da instancia."
  }
}
```

## Resumo do estado atual

| Recurso | Lifecycle | Efeito | Situação |
|---------|-----------|--------|----------|
| `aws_instance.main` | `ignore_changes = [ami]` | AMI nova não recria a instância | ✅ resolve o problema do doc 19 |
| `aws_instance.main` | `prevent_destroy = true` | Bloqueia `destroy` e substituições | ⚠️ trava o `tofu destroy` do dev (custo) |
| `aws_security_group.main` | `create_before_destroy = true` | Novo SG antes de apagar o velho | ⚠️ com `name` fixo, a substituição falharia (use `name_prefix`) |
| `module.elasticache`: `aws_elasticache_serverless_cache.main` | `prevent_destroy = true` (fixo) | Bloqueia `destroy` do cache | ⚠️ trava de novo o `tofu destroy` do dev (doc 27) |
| `module.elasticache`/`module.database`: `aws_security_group.main` | `create_before_destroy = true` | Igual ao do `ec2` | ⚠️ mesmo problema do `name` fixo |

## Pegadinhas

- **`prevent_destroy` recusa o plano inteiro:** um `tofu destroy` não apaga "o resto" pulando o protegido. E um `-target` na rede também falha, porque destruir a VPC/subnet exige destruir a instância que mora nela. Para destruir, desligue a trava (variável `false` ou remova a linha) e rode de novo.
- **Mudança de `lifecycle` não aparece no `plan`:** ela não altera a AWS, só o comportamento dos próximos planos.
- **`ignore_changes` usa nomes de atributos**, não expressões: `[ami]` e `[tags["Name"]]` funcionam; `[var.x]` não.
- **No módulo, vale para todas as chamadas:** bastion, rancher, dev e prod. Para variar, use variável (só `prevent_destroy` aceita, e é recurso do OpenTofu) ou crie o recurso fora do módulo.
- Rode `tofu fmt -recursive`: hoje o `modules/ec2/main.tofu` está fora do padrão (alinhamento do `=` no bloco `lifecycle`).
