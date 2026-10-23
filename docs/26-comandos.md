# 26. Cheat sheet de comandos

> Endereços com `for_each` levam aspas e colchetes: use aspas simples no terminal, ex.: `tofu state show 'aws_subnet.public["public_a"]'`.

Visão geral do ciclo em [04-fluxo-de-trabalho.md](04-fluxo-de-trabalho.md).

Antes de tudo, entre na pasta do ambiente e carregue as credenciais: `cd envs/dev && source ../../.env`

## Básicos

| Comando | O que faz | Acessa a AWS? |
|---------|-----------|---------------|
| `tofu init` | Baixa providers, cria o lock | Não |
| `tofu init -upgrade` | Atualiza providers dentro da restrição de versão | Não |
| `tofu fmt` | Formata os arquivos `.tofu`/`.tf` | Não |
| `tofu fmt -check -diff` | Só mostra o que estaria fora do padrão | Não |
| `tofu validate` | Valida sintaxe e tipos | Não |
| `tofu plan` | Mostra o que vai mudar | Lê |
| `tofu apply` | Aplica as mudanças (pede `yes`) | **Escreve** |
| `tofu show` | Mostra o state de forma legível | Não |
| `tofu destroy` | Apaga tudo que o projeto gerencia | **Escreve** |

## Plan salvo (o que você vê é o que será aplicado)

```bash
tofu plan -out=plano.tfplan
tofu apply plano.tfplan     # não pede confirmação: já foi revisado
```

## State

Detalhes em [08-state.md](08-state.md).

```bash
tofu state list                    # recursos no state
tofu state show <endereço>         # atributos de um recurso
tofu show                          # state inteiro, legível
tofu plan -refresh-only            # detecta drift (mudanças feitas fora do tofu)
tofu apply -refresh-only           # grava o drift no state, sem alterar a AWS
tofu state rm <endereço>           # "esquece" um recurso (não apaga na AWS)
tofu state mv <antigo> <novo>      # renomeia o endereço sem recriar o recurso
tofu state pull                    # JSON bruto do state
tofu import <endereço> <id>        # adota um recurso criado fora do tofu
```

## Backend e ambientes

Detalhes em [09-backend-remoto-s3.md](09-backend-remoto-s3.md).

```bash
tofu init -migrate-state                            # move o state para o backend novo (copia)
tofu init -reconfigure -var-file=homolog.tfvars     # troca de ambiente (não copia)
tofu init -backend-config="key=dev/app.tfstate"     # sobrescreve um argumento do backend
tofu state pull                                     # baixa e mostra o state remoto
tofu workspace list                                 # workspaces (este projeto usa "default")
```

## Conferir a rede na AWS (só leitura)

```bash
# route tables da VPC: rotas e subnets associadas (ver doc 16)
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$(tofu output -raw vpc_id)"

# security groups da VPC: regras de entrada e saída (ver doc 17)
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$(tofu output -raw vpc_id)"
```

## SSH nas EC2 (doc 19)

```bash
tofu state show aws_eip.bastion | grep -E '^\s+public_ip '          # IP fixo do bastion (Elastic IP)
ssh -i algadelivery-iac.pem ubuntu@IP_BASTION                         # entrar no bastion
ssh-add algadelivery-iac.pem                                          # chave no agente SSH
ssh -J ubuntu@IP_BASTION ubuntu@IP_PRIVADO                            # pular para uma VM privada (quando houver)
chmod 400 algadelivery-iac.pem                                        # se o ssh reclamar da permissão
```

## Ver as regras geradas por dynamic blocks (doc 20)

```bash
echo 'local.bastion_ingress_rules' | tofu console    # lista final de regras de entrada
```

## Testar functions e expressões

```bash
tofu console                         # REPL; lê o state (data sources aparecem após um plan/apply)
> merge({ a = 1 }, { b = 2 })
> trimspace("  203.0.113.10\n")
> format("%s-%s", "algadelivery", "igw")
```

Adicionou um provider (ex.: `hashicorp/http`)? Rode `tofu init` antes do `plan` (doc 18).

## Módulos (doc 21)

```bash
tofu init                                              # obrigatório após adicionar/mudar um módulo (source)
tofu fmt -recursive                                    # formata também modules/
tofu state list | grep '^module\.'                      # recursos dentro de módulos
tofu state show 'module.vpc.aws_subnet.public["public_a"]'
tofu state mv 'aws_vpc.algadelivery' 'module.vpc.aws_vpc.main'   # alternativa ao bloco moved
```

## Coleções e expressions (doc 22 e types_expression.md)

```bash
echo 'keys(var.subnet_pvt_config)' | tofu console               # grupos de subnets privadas
echo 'type(["texto", 42, true])' | tofu console                 # ver o tipo de um valor
tofu output -json | python3 -m json.tool                        # outputs agrupados por grupo
```

## Ambientes (doc 24)

```bash
cd envs/dev  && source ../../.env && tofu plan     # o ambiente é a PASTA
cd envs/prod && tofu init -reconfigure             # 1ª vez em prod (.terraform copiado)
pwd                                                 # confira o ambiente antes do apply
diff -r envs/dev envs/prod -x .terraform -x '*.pem' # ver o que diverge entre os ambientes
```

## Módulo EC2 (doc 23)

```bash
tofu state list | grep -E '^module\.(bastion|rancher)'     # recursos de cada servidor
tofu output bastion_public_ip                               # IP do bastion (Elastic IP)
ssh -i algadelivery-bastion.pem ubuntu@IP_BASTION           # cada servidor tem seu .pem
ssh -i algadelivery-rancher.pem ubuntu@IP_RANCHER
```

## Lifecycle (doc 25)

```bash
tofu plan -destroy                                        # simula o destroy (mostra se prevent_destroy bloqueia)
tofu apply -replace='module.bastion.aws_instance.main'    # força a recriação (ex.: pegar a AMI nova)
```

## Outputs

Detalhes em [07-outputs.md](07-outputs.md).

```bash
tofu output                    # todos os outputs do state
tofu output -raw bucket_name   # valor puro, para scripts
tofu output -json              # tudo em JSON
```

## Mirar em um recurso específico

```bash
tofu plan    -target=aws_vpc.algadelivery
tofu destroy -target=aws_vpc.algadelivery
```

> `-target` é para emergências/estudo; no dia a dia, rode o projeto inteiro.

## Flags úteis

| Flag | Uso |
|------|-----|
| `-auto-approve` | Pula o `yes` (apply/destroy). Cuidado |
| `-no-color` | Saída sem cores (logs, CI) |

## Variáveis

Detalhes e precedência em [06-variaveis.md](06-variaveis.md).

```bash
tofu plan -var 'environment=Production'        # uma variável
tofu plan -var-file=dev.tfvars                 # arquivo de valores
export TF_VAR_bucket_name=meu-bucket-teste     # via ambiente
tofu console                                   # REPL: digite var.bucket_name para ver o valor
```

## Ajuda

```bash
tofu -help
tofu plan -help
```
