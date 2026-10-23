# Diário de estudo

Registro do que mudou no código e quais docs foram atualizados. Mais recente no topo.

## 2026-10-23 (módulo RDS)

**Código**
- Novo `modules/rds/`: `aws_db_subnet_group`, `aws_db_parameter_group` (`family = "${engine}${version}"` → `postgres18`, `dynamic "parameter"` sobre um mapa, `pending-reboot`), `aws_db_instance` (`manage_master_user_password`, `multi_az = false`, `apply_immediately`) e o SG (object + dynamic + `create_before_destroy`). Outputs: ARN do segredo, endpoint, id, arn.
- `envs/{dev,prod}`: `rds.tofu` (`module "database"`, subnets `module.vpc.subnet_pvt_ids["database"]`), 13 variáveis `db_*` (PostgreSQL 18, `db.t4g.micro`, 20 GB, `max_connections`, `pg_stat_statements`, `pgaudit`), `db_security_group_config` + `db_port` no local, outputs repassados. `envs/dev/providers.tofu`: provider `random` (sem uso).
- dev: `validate` ✅, `plan` = 4 to add. A AWS oferece o PostgreSQL 18 (`18.3`, família `postgres18`). prod: `Module not installed` → `init -reconfigure`. `fmt -check` falha em `modules/ec2/main.tofu` e `envs/prod/local.tofu`.
- ⚠️ Subnet group e parameter group sem o prefixo do ambiente (colidem entre dev e prod); tag `Name` do banco errada; sem `storage_encrypted`/`deletion_protection`; `db_multi_az`/`db_port`/`random` sem uso. Ainda sem commit.

**Docs**
- Novo `26-modulo-rds.md`: RDS x EC2, as 4 peças e a ordem, passos 1–6 (subnet group, parameter group, SG, instância com tabela de "por quê", chamada no env, outputs + senha no Secrets Manager + túnel SSH e `psql`), plan real, validação, revisão em 7 pontos (snippets validados), custos e pegadinhas.
- `ARQUITETURA.md`: RDS no Mermaid e no ASCII, tabela (39), fluxo até o banco, pendências e histórico. `15`, `22`, `24` (notas), `10` (árvore), `27-comandos.md` (ex-26, com comandos de RDS), README.

## 2026-10-23 (lifecycle no módulo EC2)

**Código**
- `modules/ec2/main.tofu`: `aws_instance.main` com `lifecycle { prevent_destroy = true, ignore_changes = [ami] }`.
- `modules/ec2/security_group.tofu`: `aws_security_group.main` com `lifecycle { create_before_destroy = true }`.
- `envs/dev`: `validate` ok; `plan` → No changes. `tofu plan -destroy` → `Error: Resource instance cannot be destroyed` (prevent_destroy). `fmt -check` falha em `modules/ec2/main.tofu`.
- Testado à parte (`terraform_data`, OpenTofu 1.13): `prevent_destroy` aceita variável.

**Docs**
- Novo `25-lifecycle.md`: o que é, as 4 opções com analogias, os 3 usos do projeto (`ignore_changes` resolve a AMI; `prevent_destroy` trava o destroy do estudo, com o erro real e a solução por variável testada; `create_before_destroy` + `name` fixo = conflito, com `name_prefix`), `replace_triggered_by`, pre/postconditions, resumo e pegadinhas.
- `19` (AMI ✅), `23`, `24` (aviso do destroy), `26-comandos.md` (ex-25, com `plan -destroy` e `-replace`), README, `ARQUITETURA.md` (pendências e histórico).

## 2026-10-22 (múltiplos ambientes: envs/dev e envs/prod)

**Código**
- Os `.tofu` da raiz foram movidos para `envs/dev/` e `envs/prod/` (um root module por ambiente), compartilhando `modules/vpc` e `modules/ec2` (`source = "../../modules/..."`).
- Backend: `key = "algadelivery/${var.environment}/remote.tfstate"`. Dev em `algadelivery/development/...` e prod em `algadelivery/production/...`. VPCs `172.25.0.0/16` (dev) e `172.26.0.0/16` (prod).
- dev: aplicado do zero; 35 recursos; `plan` → No changes. prod: `validate` ok, mas o `.terraform/` copiado aponta para o backend antigo → `tofu init -reconfigure`.
- AWS conferida (só leitura): 1 VPC (dev), 1 NAT, 1 EC2, 2 EIPs (bastion + NAT regional); sem órfãos. O state antigo `development/networking/...` não existe mais.
- ⚠️ Envs divergentes (nome do bastion, key pair, `[0]` x `["0"]`, rancher comentado diferente; bug de `instance_type` no rancher do dev). A key do backend depende de variável. Ainda sem commit.

**Docs**
- Novo `24-multiplos-ambientes.md`: por que separar, estrutura, o que é compartilhado x por ambiente, state por env, como rodar, `init -reconfigure`, dev x prod, situação real, riscos (key por variável com snippets validados, duplicação e alternativas, nomes, bug do rancher, custo, commit) e pegadinhas.
- `09`, `10` (árvore com `envs/`), `21`/`22`/`23` (o `moved` não foi necessário na prática), `25-comandos.md` (ex-24, com envs), README (estrutura, estado por ambiente, como rodar).
- `ARQUITETURA.md`: seção Ambientes, diagrama do dev (sem o rancher), 35 recursos, pendências refeitas e histórico.

## 2026-10-22 (módulo EC2: bastion e rancher)

**Código**
- Novo `modules/ec2/` (`main.tofu`, `security_group.tofu`, `variables.tofu`, `outputs.tofu`): chave, key pair, `.pem` em `path.root`, Elastic IP com `count = var.enabled_eip ? 1 : 0`, EC2 e SG com dynamic blocks a partir de `security_group_config` (object).
- `ec2.tofu`: chama o módulo como `module "bastion"` e `module "rancher"`. O `security_group.tofu` da raiz foi removido. `local.tofu`: `bastion_security_group_config` (`!= null ? var : padrão`). `variables.tofu`: `bastion_security_group_config` (`default = null`), `keypair_name` → `algadelivery-bastion`. `outputs.tofu`: `module.bastion.*`.
- 🔴 Validação: `validate`/`plan` ok, mas **o apply falharia**: bastion e rancher com o mesmo key pair, o mesmo SG `bastion-sg`, o mesmo `.pem` e a mesma tag.
- **Corrigido (por pedido):** rancher com `name = "rancher"`, `keypair_name = "algadelivery-rancher"` e `local.rancher_security_group_config` (merge com `name = "rancher-sg"`); `["public"]["0"]` → `[0]`; output `public_ip` com ternário (funciona com `enabled_eip = false`); `tofu fmt` (`modules/ec2/outputs.tofu`). `validate` ✅, `fmt -check -recursive` ✅, o plan mostra nomes únicos.
- `plan`: 41 add / 30 destroy. Com 23 `moved` (VPC) + 5 (bastion), testado com o state numa cópia: 17 add / 7 change / 5 destroy; o bastion é recriado (AMI, key pair e SG mudaram).

**Docs**
- Novo `23-modulo-ec2.md`: por que, estrutura, inputs/outputs, SG como `object` + dynamic, `default = null` + ternário, `merge` para o rancher, `count` no EIP, `path.root` x `path.module`, a chamada 2×, os conflitos e a correção, migração (5 `moved` + motivos da recriação), melhorias (validadas), prévia com `for_each` no módulo e pegadinhas.
- Notas de "agora no módulo ec2" em 17, 19 e 20. `21`: reuso na prática. `10`: árvore com `modules/ec2`. `24-comandos.md` (ex-23). README.
- `ARQUITETURA.md`: módulos bastion/rancher no diagrama, no ASCII e na tabela (41), fluxos SSH, pendências e histórico.

## 2026-10-22 (subnets em grupos: coleções e expressions)

**Código**
- `subnet_pub_config` / `subnet_pvt_config` (raiz e módulo): `map(map(object({cidr_block, az})))` por grupo. Públicas: `public` (`pub_a/b/c`). Privadas: `management`, `cluster` e o novo **`database`** (`172.25.10-12.0/24`).
- `modules/vpc/locals.tofu`: achatamento com `merge([for group, subnets in ... : { for k, s in subnets : k => merge(s, { group = group }) }]...)`.
- `modules/vpc/main.tofu`: um único `aws_subnet.private` + `aws_route_table_association.private`; tags `pub-<grupo>-<az>` / `pvt-<grupo>-<az>`.
- `modules/vpc/outputs.tofu`: `subnet_pub_ids/arns` e `subnet_pvt_ids/arns` como mapa grupo → lista. Raiz: o bastion usa `subnet_pub_ids["public"][0]`; outputs repassam public/management/cluster (sem database).
- `validate` e `fmt -check -recursive` ok ✅.
- 🔴 `plan`: 32 add / 27 destroy. Com 23 `moved` por chave (testado com o state baixado numa cópia, depois apagada): 8 add / 8 change / 3 destroy; o bastion seria **substituído por AMI nova** (`most_recent`).

**Docs**
- `types_expression.md` editado: correção da ordem de map/object (alfabética), tuple com `type()`, `set`, tipos aninhados, `merge`/`flatten`/`...`, for aninhado, agrupamento `=> v...`, resultados reais nos 10 exercícios + 6 extras, ligação com o projeto.
- Novo `22-modulo-vpc-grupos-de-subnets.md`: o porquê, variável antes x depois, o achatamento passo a passo (saídas reais), um recurso para as privadas, outputs agrupados, migração com `moved` por chave (tabela + arquivo + resultado), o alerta da AMI, a `validation` de chaves únicas (testada) e as pegadinhas.
- `21`: nota de `moved` desatualizado. `13` e `06`: links. `23-comandos.md` (ex-22). README (índice + material de apoio).
- `ARQUITETURA.md`: grupo database no diagrama/ASCII/CIDRs, nomes novos, 35 recursos, pendências e histórico.

## 2026-10-20 (modules: vpc)

**Código**
- `networking.tofu` removido. Novo módulo `modules/vpc/` (`main.tofu`, `variables.tofu`, `outputs.tofu`, `locals.tofu`), com nomes lógicos `main`. A rota privada usa `nat_gateway_id` ✅.
- Novo `vpc.tofu`: `module "vpc" { source = "./modules/vpc", ... }`, com `vpc_name = "${local.context_name}-vpc"` (a tag muda; `var.vpc_name` fica sem uso).
- Raiz: o SG usa `module.vpc.vpc_id`; o bastion usa `module.vpc.subnet_public_ids[0]`. `outputs.tofu` repassa `module.vpc.*` e ganhou bastion/SG/EIP/key pair.
- `init` registrou o módulo (`modules.json`). `validate` ok. `fmt -check -recursive` falha em `modules/vpc/variables.tofu`.
- 🔴 `plan` real: **26 add / 27 destroy** (endereços mudaram). Com 11 blocos `moved` (testado com o state baixado numa cópia, depois apagada): **2 add / 2 change / 2 destroy**, sem diff na rota privada.

**Docs**
- Novo `21-modules.md`: o que é (root x child), estrutura, inputs (tabela input → origem), outputs e repasse, escopo isolado, endereços novos, `init`, refatorar sem destruir (`moved.tofu` completo + resultado testado, `tofu state mv`), melhorias (nomes, output em mapa validado, inputs sem description, `versions.tofu`, `fmt -recursive`), reuso e pegadinhas.
- Notas de "agora está no módulo" em 11, 12, 14, 15 e 16. `16`: diff ✅ resolvido. `10`: árvore com `modules/vpc`. `13`: `moved` na prática. `07`: outputs de módulo. `22-comandos.md` (ex-21) com comandos de módulo.
- `ARQUITETURA.md`: moldura do módulo no Mermaid, endereços `module.vpc.*`, tag da VPC, pendências (🔴 `moved`) e histórico. README.

## 2026-10-20 (dynamic blocks)

**Código**
- `security_group.tofu`: regras do `bastion_sg` via `dynamic "ingress"` / `dynamic "egress"` com `for_each = local.bastion_*_rules`. O `aws_security_group.vm_private` foi removido.
- `variables.tofu`: `bastion_ingress_rules` e `bastion_egress_rules` (`list(object)`, `default = []`).
- `local.tofu`: `length(var.x) > 0 ? var.x : [padrões]`. Padrões: entrada 22 do meu IP, 80/443 da VPC; saída tudo + 80. ⚠️ Indentação irregular (`fmt -check` falha).
- `ec2.tofu`: `aws_instance.vm_private` removida; novo `aws_eip.bastion`.
- `.gitignore`: `*.pem` ✅. Lock com 4 providers ✅ (init feito).
- `plan`: 1 add, 2 change, 2 destroy. 🔴 Diff permanente da rota privada **confirmado** (`nat_gateway_id` no state x `gateway_id` no código).

**Docs**
- Novo `20-dynamic-blocks.md`: problema, sintaxe (`content`, `.value`, `iterator`), `dynamic` x `for_each` de recurso, o código passo a passo, padrões no local, plan real, customização via `.tfvars` (substitui, testado), revisão das regras, alternativa com `aws_vpc_security_group_ingress_rule` (validada) e pegadinhas.
- `19`: nota da VM privada removida, seção 9 (Elastic IP), `.pem` ✅. `17`: nota sobre `dynamic` e o SG removido. `16`: diff confirmado com o trecho real. `06`: lista de objetos com padrão no local. `10`, `21-comandos.md` (ex-20), README.
- `ARQUITETURA.md`: VM privada e SG fora; EIP dentro; SG bastion com as novas regras; 29 recursos; pendências e histórico.

## 2026-10-20 (EC2: bastion e VM privada)

**Código**
- `providers.tofu`: novos `hashicorp/tls ~> 4.0` e `hashicorp/local ~> 2.0`. ⚠️ Falta `tofu init`: o `validate` falha (`Missing required provider ... hashicorp/local`). Numa cópia: tls v4.4.1, local v2.9.1, `validate` ok, `plan` 30 to add.
- `data.tofu`: `data "aws_ami" "ubuntu"` (Canonical `099720109477`, Ubuntu 22.04 Jammy amd64, `most_recent`). Resolveu para `ami-09db1e291cef3f1ef` no teste.
- Novo `ec2.tofu`: `tls_private_key` (RSA 4096), `aws_key_pair` (`algadelivery-iac`), `local_sensitive_file` (`./algadelivery-iac.pem`, 0400), `aws_instance.bastion` (public_a, IP público) e `aws_instance.vm_private` (private_management a), com `depends_on` no key pair.
- `variables.tofu`: `instance_type` (`t3.micro`), `keypair_name`, `ami_id` (sem uso).
- 🔴 `*.pem` não está no `.gitignore`. ⚠️ `most_recent` pode forçar a recriação das EC2; faltam outputs de IP; `ec2.tofu` fora do `fmt`.

**Docs**
- Novo `19-ec2-bastion-e-vm-privada.md`: explicação fácil das peças (AMI, tipo, subnet, SG, chave), providers tls/local, cada filtro da AMI, a chave em 3 passos, tabela do porquê de cada configuração, `depends_on` x referência, como acessar (ssh / ssh -J), melhorias (`.gitignore`, chave no state, `ignore_changes`, outputs, IMDSv2, disco criptografado; validadas numa cópia), custos e pegadinhas.
- `ARQUITETURA.md`: EC2 no diagrama e no ASCII, tabela com 30 recursos, fluxos SSH prontos após o apply, pendências e histórico.
- `17` ("o que falta" virou implementado), `18`, `03` (4 providers), `06` (variáveis das EC2), `10`, `20-comandos.md` (ex-19, com SSH), README.

## 2026-10-20 (data sources e functions)

**Código**
- Novo `data.tofu`: `data "http" "my_public_ip"` (GET em `https://checkip.amazonaws.com/`).
- `providers.tofu`: provider `hashicorp/http ~> 3.0`. ⚠️ Falta `tofu init`: o `validate` falha com `Missing required provider` (numa cópia, o init instalou o http v3.6.2 e o validate passou).
- `local.tofu`: `my_public_ip = "${trimspace(...response_body)}/32"` e `common_tags = { Environment, ManagedBy }`.
- Todos os recursos: `tags = merge(local.common_tags, { Name = ... })`.
- `security_group.tofu`: o bastion aceita SSH só de `local.my_public_ip` (resolve o "SSH aberto para o mundo").

**Docs**
- Novo `18-data-sources-e-functions.md`: o porquê de cada mudança, resource x data source, o provider `http`, `trimspace`/`/32`/`merge` passo a passo, functions por categoria, `merge` x `default_tags`, outros data sources AWS (validados numa cópia), locals x variables e pegadinhas (IP de quem roda, IP dinâmico, CI, init).
- `17`: ponto 1 ✅ resolvido, snippet e tabela "quem fala com quem" atualizados. `15`: tags via `common_tags` + `merge`. `06`: locals com data source e mapa. `03`: mais de um provider. `10`: `data.tofu`. `19-comandos.md` (ex-18): `tofu console` com functions.
- `ARQUITETURA.md`: SG do bastion com o seu IP, pendência do `init`, nota sobre data sources, histórico. README atualizado.

## 2026-10-20 (security groups)

**Código**
- Novo `security_group.tofu`:
  - `aws_security_group.bastion` (`bastion_sg`): SSH 22/tcp de `0.0.0.0/0`, saída liberada.
  - `aws_security_group.vm_private` (`vm_private_sg`): SSH 22/tcp de `aws_vpc.algadelivery.cidr_block`, saída liberada.
- `outputs.tofu`: `route_table_public_id` e `route_table_private_id`.
- `tofu fmt -check` agora passa ✅.
- O state estava mudando durante a documentação (apply/destroy). Num plan apareceu `aws_route_table.private will be updated in-place`, indício do problema `gateway_id` x `nat_gateway_id`.
- ⚠️ SSH aberto para o mundo; o SG privado aceita a VPC inteira; a `description` dos SGs diz "Allow TLS".

**Docs**
- Novo `17-security-groups.md`: o que é (stateful, só allow), SG x NACL, anatomia da regra, padrão bastion, código explicado, tabela "quem fala com quem", 5 melhorias (IP `/32` ou SSM, referência a SG, description, `aws_vpc_security_group_ingress_rule`, outputs; testadas com `validate` numa cópia), o que falta (EC2s) e pegadinhas.
- `ARQUITETURA.md`: SGs no diagrama, no ASCII, na tabela (25), nos fluxos de SSH e nas pendências; `fmt` saiu das pendências.
- `16` (indício do diff, link para o 17), `07` (outputs de route table), `10`, `12` e `18-comandos.md` (ex-17, com `describe-security-groups`). README: tabela do índice corrigida (a nota tinha quebrado a tabela), SGs e outputs.

## 2026-10-20 (route tables)

**Código**
- `networking.tofu`: `aws_route_table.public` (`0.0.0.0/0 → IGW`) + `aws_route_table_association.public` (`for_each = aws_subnet.public`).
- `aws_route_table.private` (`0.0.0.0/0 → NAT`) + `aws_route_table_association.private_management` e `.private_cluster`.
- Comentários `// SUBNET PÚBLICA` e `// SUBNET PRIVADA`.
- `local.tofu`: `internet_cidr_block = "0.0.0.0/0"`.
- O state está vazio (destroy); o `plan` mostra 23 to add.
- ⚠️ A rota privada usa `gateway_id` com o ID do NAT; o argumento próprio é `nat_gateway_id`. O `fmt -check` continua falhando em 4 arquivos.

**Docs**
- Novo `16-route-tables.md`: analogia, destino x target, longest prefix match, as tabelas do projeto, o código explicado, 2 associations x `merge()`, os tipos de target, o alerta `gateway_id` x `nat_gateway_id`, inline x `aws_route`, o plan (23), como conferir após o apply e pegadinhas.
- `ARQUITETURA.md`: diagrama com as route tables, tabela com 23 recursos, fluxos, pendências e histórico.
- `14` e `15`: as prévias viraram "implementado" (com as diferenças). `12` atualizado com o checklist de subnet pública. `11`, `13`, `06` (`internet_cidr_block`), `10` e README atualizados. `16-comandos.md` virou `17-comandos.md` (com `describe-route-tables`).

## 2026-10-20 (subnets privadas, NAT Gateway regional e diagrama de arquitetura)

**Código**
- `networking.tofu`: `aws_subnet.private_management` (`172.25.4-6.0/24`) e `aws_subnet.private_cluster` (`172.25.7-9.0/24`) com `for_each`, mais `aws_nat_gateway.algadelivery` com `vpc_id` e `availability_mode` (regional, sem `subnet_id`).
- Tags `Environment` e `ManagedBy = "OpenTofu"` em todos os recursos.
- `local.tofu`: `ngw_regional_mode = var.ngw_regional_mode ? "regional" : "zonal"`. `variables.tofu`: dois mapas de subnets privadas e `ngw_regional_mode` (bool).
- `outputs.tofu`: `subnet_pvt_mgmt_id/arn`, `subnet_pvt_cluster_id/arn` e `ngw_id`.
- Aplicado: 12 recursos, `plan` → No changes. A AWS criou uma route table para o NAT (fora do state) e 1 EIP em `us-east-1a`.
- ⚠️ Ainda sem route tables do projeto (nem pública, nem privada), então nenhuma subnet tem internet. 💲 O NAT cobra por hora. O `fmt -check` falha em `local.tofu`, `networking.tofu`, `outputs.tofu` e `variables.tofu`.

**Docs**
- Novo `ARQUITETURA.md`, o diagrama vivo: Mermaid + versão texto, tabela de recursos e status, mapa de CIDRs, fluxos de tráfego, pendências e histórico.
- Novo `15-subnets-privadas-e-nat-gateway.md`: para que servem as privadas e os dois grupos, NAT (para que serve, zonal x regional com fonte da AWS, o state real, `bool` + ternário), prévia da route table privada com `merge()` + `for_each` (validada numa cópia), custos, `default_tags` e pegadinhas.
- `06`: `bool` + ternário. `07`, `10`, `11`, `12` e `14` atualizados com links para o 15 e para a arquitetura. `15-comandos.md` virou `16-comandos.md`. README com link destacado para a arquitetura.

## 2026-10-20 (internet gateway)

**Código**
- `networking.tofu`: novo `aws_internet_gateway.algadelivery` (`vpc_id` da VPC, tag `algadelivery-igw`).
- `local.tofu` voltou com `context_name = "algadelivery"`. A tag das subnets agora é `"${local.context_name}-pub-${each.value.az}"`, e `subnet_pub_config` perdeu o campo `name`.
- `outputs.tofu`: `igw_id` e `igw_arn`.
- O state está vazio (destroy); o `plan` mostra 5 to add.
- ⚠️ Sem route table `0.0.0.0/0 → IGW` e sem associations: as subnets ainda não têm internet. O `fmt -check` falha em `networking.tofu`, `outputs.tofu` e `variables.tofu`.

**Docs**
- Novo `14-internet-gateway.md`: o que é, para que serve, IGW x NAT Gateway, os ingredientes de uma subnet pública (com diagrama), o código, o plan real, os outputs, uma prévia de route table + association com `for_each` (validada numa cópia: 9 to add), custos e pegadinhas.
- `12-subnets.md`: código atual (tag via `local`); a seção "ainda não é pública" agora tem um checklist com o IGW ✅.
- `13-loops-for-each-e-for.md`: snippets atuais; `for_each` sobre um mapa de recursos.
- `06-variaveis.md`: `map(object)` sem `name`; a seção de `locals` voltou a refletir o projeto (`local.tofu`).
- `07`, `10`, `11` e README atualizados; `14-comandos.md` virou `15-comandos.md`.

## 2026-10-20 (loops: `for_each` e `for`)

**Código**
- `networking.tofu`: os 3 blocos `aws_subnet.public_a/b/c` viraram 1 bloco `aws_subnet.public` com `for_each = var.subnet_pub_config`.
- `variables.tofu`: `subnet_pub_config` passou de `list(object)` para `map(object)` com as chaves `public_a/b/c`.
- `outputs.tofu`: os 6 outputs por subnet viraram `subnet_public_id` e `subnet_public_arn`, com a expressão `[for subnet in aws_subnet.public : ...]`.
- Aplicado: nova VPC `vpc-0a768d2dbdfb3b9cb` + 3 subnets; `plan` → No changes. Não foi preciso `moved` (tudo criado do zero).
- ⚠️ O `fmt -check` continua falhando em `outputs.tofu` e `variables.tofu`.

**Docs**
- Novo `13-loops-for-each-e-for.md`: antes x depois, `for_each` e `each`, endereços com chave, mapa x lista, `count`, expressões `for` (lista, mapa, filtro, splat), `moved` e pegadinhas.
- `12-subnets.md`: código atual com `for_each`; a seção "Melhorias" virou link para o 13 (o `cidrsubnet` ficou como melhoria possível).
- `06-variaveis.md`: tipos complexos com o `map(object)` atual.
- `07-outputs.md`: outputs de subnet com `for` e IDs atuais.
- `10-organizacao-dos-arquivos.md` e README atualizados; `13-comandos.md` virou `14-comandos.md`.

## 2026-10-20 (fix: atributo `name` nas subnets)

**Código**
- `locals.tofu` removido; `networking.tofu` passou a usar `Name = each.value.name`.
- `tofu plan` falhava com `Unsupported attribute ... does not have an attribute named "name"`: o tipo `map(object({cidr_block, az}))` não tinha `name`.
- `variables.tofu`: `name = string` adicionado ao objeto, e os defaults ganharam `algadelivery-pub-{a,b,c}`. `validate` ok; `plan`: 4 to add.
- Lição: com `type = object(...)`, só existem os atributos declarados no tipo. Os que não estão lá não podem ser lidos, nem mesmo se aparecerem no default.

**Docs**
- `10-organizacao-dos-arquivos.md`: `locals.tofu` removido da árvore e da tabela.
- `06-variaveis.md`: seção de `locals` mantida como conceito, com nota de que o projeto não a usa mais.

## 2026-10-20 (fix: local não declarado)

**Código**
- `tofu plan` falhava com `Reference to undeclared local value`: `networking.tofu` usava `local.context_name` no `Name` das subnets, mas não existia bloco `locals`.
- Novo `locals.tofu` com `context_name = "algadelivery-${var.environment}"`. `validate` ok; `plan`: 4 to add, subnets nomeadas `algadelivery-development-pub-{a,b,c}`.
- O `fmt -check` continua apontando `outputs.tofu` e `variables.tofu`.

**Docs**
- `06-variaveis.md`: nova seção "`locals`: valores derivados".
- `10-organizacao-dos-arquivos.md`: `locals.tofu` na árvore e na tabela.

## 2026-10-19 (fix: nomes lógicos)

**Código**
- `tofu plan` falhava com 4 × `Reference to undeclared resource`: o bucket tinha sido renomeado para `aws_s3_bucket.algadelivery-tfstate-devops`, o versionamento apontava para `algadelivery-teste-tofu` e os outputs para `algadelivery-teste-devops`.
- Unificado tudo em `aws_s3_bucket.algadelivery-teste-tofu` (`main.tofu` e `outputs.tofu`) + `tofu fmt`. `validate` ok; `plan`: 2 to add.
- Lição: o nome lógico só existe dentro do código, mas toda referência `tipo.nome.atributo` precisa bater com ele exatamente.

**Docs**
- Nenhum doc alterado além deste registro (o 07 já descreve o erro).

## 2026-10-19 (subnets)

**Código**
- `networking.tofu`: `aws_subnet.public_a/b/c` (`172.25.1.0/24`, `.2.0/24`, `.3.0/24` em `us-east-1a/b/c`).
- `variables.tofu`: `subnet_pub_config` do tipo `list(object({cidr_block, az, name}))`.
- `outputs.tofu`: `subnet_public_{a,b,c}_{id,arn}`.
- A VPC foi destruída (state vazio, serial 2); o `plan` mostra 4 to add. Ainda sem apply das subnets.
- ⚠️ Sem IGW/route table e com `map_public_ip_on_launch = false`: as subnets ainda não são públicas de verdade. O `fmt -check` continua falhando em `outputs.tofu` e `variables.tofu`.

**Docs**
- Novo `12-subnets.md`: para que servem, pública x privada, por que 3 AZs, o desenho do CIDR e os IPs reservados, o código explicado, o que falta para ser pública (IGW, rotas) e melhorias (`for_each`, `moved`, `for` nos outputs, `cidrsubnet`).
- `06-variaveis.md`: nova seção "Tipos complexos" (`list`, `map`, `object`).
- `07-outputs.md`: outputs das subnets e o padrão com `for`.
- `11-vpc.md`: subnets marcadas como feitas nos próximos passos.
- `10-organizacao-dos-arquivos.md` e README atualizados; `12-comandos.md` virou `13-comandos.md`.

## 2026-10-19 (VPC e organização em arquivos)

**Código**
- O `main.tofu` foi dividido em `providers.tofu` (terraform + backend + provider) e `networking.tofu` (VPC).
- Recurso S3 (bucket + versionamento) removido do código; o bucket e o state `development/s3/...` foram apagados.
- Novo `aws_vpc.algadelivery` (`172.25.0.0/16`, `Name = algadelivery-vpc-devops`), já aplicado: `plan` → No changes.
- Backend: a key agora é `${var.environment}/networking/remote.tfstate` (state por ambiente **e por camada**).
- Variáveis: saíram `bucket_name`/`bucket_versioning`; entraram `vpc_cidr_block`/`vpc_name`. Outputs: `vpc_id`, `vpc_arn`.
- ⚠️ `tofu fmt -check` falha em `outputs.tofu` e `variables.tofu`; a description de `environment` ainda cita S3; `aws_region` está sem `type`.

**Docs**
- Novo `10-organizacao-dos-arquivos.md`: como os arquivos são lidos juntos, arquivo x **módulo**, state por camada e o que acontece ao trocar a key.
- Novo `11-vpc.md`: CIDR, código, recursos que a AWS cria sozinha, atributos, outputs reais (account ID redigido), custos, próximos passos e pegadinhas.
- `10-comandos.md` virou `12-comandos.md`, com exemplos usando `aws_vpc.algadelivery`.
- `09-backend-remoto-s3.md`: código em `providers.tofu`, key `networking`, `homolog.tfvars` com variáveis de VPC; a key do S3 ficou como nota.
- `06-variaveis.md`: variáveis e exemplos atuais (VPC), validação de CIDR; o exemplo de versioning foi mantido.
- `05` e `07`: aviso de que são referência da fase do S3; o 07 ganhou os outputs atuais da VPC.
- README: índice, árvore e estado atual.

## 2026-10-19 (backend remoto S3)

**Código**
- `main.tofu`: bloco `backend "s3"` com o bucket `algadelivery-tfstate-devops` e `key = "${var.environment}/s3/${var.bucket_name}/remote.tfstate"`, com variáveis no backend (OpenTofu ≥ 1.8). O provider usa `var.aws_region`.
- O nome lógico voltou para `algadelivery-teste-devops` (o versionamento é `algadelivery-teste-devops-versioning`), e o `outputs.tofu` voltou a validar.
- `variables.tofu`: nova `aws_region` (sem `type`/`description`); `environment` agora em minúsculas (`development`).
- State migrado para `s3://algadelivery-tfstate-devops/development/s3/algadelivery-teste-devops/remote.tfstate` (serial 1, 2 recursos, 3 outputs). O state local foi removido.
- ⚠️ O bucket de state está sem versionamento, sem `use_lockfile` e sem `encrypt`.

**Docs**
- Novo `09-backend-remoto-s3.md`: por que usar, a key por ambiente, variáveis no backend, ovo e galinha, `-migrate-state` x `-reconfigure`, `.tfvars` por ambiente, recomendações (versionamento, lock, encrypt), comparação com workspaces e pegadinhas.
- `09-comandos.md` virou `10-comandos.md`, com uma seção de backend e ambientes.
- `08-state.md`: aviso de que o state agora é remoto; a prévia de backend virou link para o 09.
- `06-variaveis.md`: `aws_region`, `environment` em minúsculas, variáveis no provider e no backend.
- 04, 05, 07 e 10: nome lógico atualizado para `algadelivery-teste-devops`; no 07, o erro de referência foi marcado como resolvido.
- README: índice, árvore, state remoto e ambiente atual.

## 2026-10-19 (state)

**Código**
- Nenhuma mudança. Exploração do `terraform.tfstate` (serial 4, vazio) e do `.backup` (serial 3, bucket + versionamento).
- ⚠️ O `outputs.tofu` ainda referencia `aws_s3_bucket.algadelivery-teste-devops` (o `validate` falha).

**Docs**
- Novo `08-state.md`:
  - código x state x AWS, os campos do arquivo (`serial`, `lineage`, `resources`, `dependencies`) com exemplos reais;
  - state não é histórico: `.backup` guarda só a versão anterior; histórico de verdade vem de backend S3 versionado;
  - comandos `state list/show/pull/mv/rm` e `import`, drift, criptografia do state (exclusiva do OpenTofu) e pegadinhas.
- As seções "O state" e "Drift" saíram do `05-bucket-s3-versionado.md` e foram para o 08; no 05 ficou um link.
- `08-comandos.md` virou `09-comandos.md`, com mais comandos de state. Links do 04 e do README atualizados.

## 2026-10-19 (outputs)

**Código**
- `apply` do bucket versionado (2 recursos) e depois `destroy`: state vazio.
- Novo `outputs.tofu` com `bucket_name`, `bucket_arn` e `bucket_url`.
- ⚠️ Os outputs referenciam `aws_s3_bucket.algadelivery-teste-devops` (nome lógico antigo): o `tofu validate` falha com `Reference to undeclared resource`. O certo é `aws_s3_bucket.algadelivery-teste-tofu`.

**Docs**
- Novo `07-outputs.md`: declarar, `sensitive`, outputs no plan e no apply, `tofu output` (`-raw`, `-json`) e pegadinhas, incluindo o erro acima. As saídas foram testadas em uma cópia com a referência corrigida.
- `07-comandos.md` virou `08-comandos.md`, com uma seção de outputs.
- README: índice, árvore de arquivos, outputs e situação atual na AWS.

## 2026-10-19 (variáveis e versionamento)

**Código**
- `main.tofu`: novo recurso `aws_s3_bucket_versioning` ligado ao bucket por referência (`aws_s3_bucket.algadelivery-teste-tofu.id`).
- Nome lógico do bucket mudou de `algadelivery-teste-devops` para `algadelivery-teste-tofu` (o nome real continua `algadelivery-teste-devops`).
- Novo `variables.tofu` com `bucket_name`, `environment` e `bucket_versioning`; o `main.tofu` passou a usar `var.*`.
- `tofu plan`: 2 to add (ainda sem apply registrado no state).

**Docs**
- `05-primeiro-resource-s3.md` virou `05-bucket-s3-versionado.md`: código novo, seção de versionamento (`Enabled`/`Suspended`/`Disabled`), referência e dependência implícita, saídas novas de plan/apply e pegadinha de `destroy` com versões.
- Novo `06-variaveis.md`: declarar, usar, precedência de valores, `.tfvars`, `TF_VAR_` e `validation`.
- `06-comandos.md` virou `07-comandos.md`, com uma seção de variáveis e o `tofu console`.
- README (índice e estado atual) e `04-fluxo-de-trabalho.md` (exemplo do `show` e link) atualizados.

## 2026-10-19 (início)

**Código**
- `main.tofu`: provider `hashicorp/aws ~> 6.0` (região `us-east-1`) e bucket S3 com tags.
- Bucket renomeado de `algadelivery-teste-tofu` para `algadelivery-teste-devops`.
- `tofu init` (provider 6.69.1) e `tofu apply`: bucket criado; depois foi apagado fora do OpenTofu (drift).
- `.gitignore`: adicionados `.terraform/`, `*.tfstate`, `*.tfstate.*`, `crash.log`, `*.tfplan`.

**Docs**
- Criada a pasta `docs/`: README, 02 a 05 e este changelog.
- `setup-env.md` movido para `docs/01-instalacao.md`.
- Novo `04-fluxo-de-trabalho.md` com o diagrama `fluxo-opentofu.png` (init → plan → apply → show → destroy), incluindo o `tofu show`.
- Renumerados: `04-primeiro-resource-s3` → `05`, `05-comandos` → `06`. A seção "O ciclo de trabalho" do doc do S3 virou um link para o 04.
- README: diagrama, novo índice e `tofu show` no resumo; `tofu show` na tabela do cheat sheet.
