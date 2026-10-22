# 7. Outputs

Se as variáveis são as **entradas** do projeto, os outputs são as **saídas**: valores que você quer ver ou reaproveitar depois do `apply`, como ARN, URL ou ID. Muitos deles só existem depois que a AWS cria o recurso.

## Para que servem

- Mostrar informações úteis no fim do `apply`, sem abrir o console.
- Alimentar scripts e pipelines (`tofu output -raw ...`).
- Expor valores de um **módulo** para quem o usa (assunto futuro).
- Ler valores de outro projeto via `terraform_remote_state` (assunto futuro).

## Os outputs atuais (VPC)

```hcl
output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.algadelivery.id
}

output "vpc_arn" {
  description = "The ARN of the VPC"
  value       = aws_vpc.algadelivery.arn
}
```

```bash
$ tofu output -raw vpc_id
vpc-0a768d2dbdfb3b9cb
```

(account ID trocado por `123456789012`.) Detalhes da VPC em [11-vpc.md](11-vpc.md).

> **Atualização (módulos):** os outputs de rede agora nascem **dentro** do módulo (`modules/vpc/outputs.tofu`) e a raiz os **repassa** com `value = module.vpc.<nome>`. Sem esse repasse, eles não aparecem no `tofu output`. A raiz também ganhou outputs próprios: `security_group_bastion_id`, `bastion_id`, `bastion_arn`, `bastion_public_ip` (do Elastic IP) e `keypair_arn`. Ver [21-modules.md](21-modules.md#outputs-como-os-valores-saem).

Para as subnets, que são criadas com `for_each`, os outputs usam uma **expressão `for`**: um output devolve a lista de todas.

```hcl
output "subnet_public_id" {
  description = "The IDs of the public subnet "
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "subnet_public_arn" {
  description = "The ARNs of the public subnets"
  value       = [for subnet in aws_subnet.public : subnet.arn]
}
```

```bash
$ tofu output subnet_public_id
[
  "subnet-0e01e77ec2f8b7351",
  "subnet-091d4378f833c0cb5",
  "subnet-03015cb81720e7f7c",
]
```

As subnets privadas seguem o mesmo padrão (`subnet_pvt_mgmt_id/arn`, `subnet_pvt_cluster_id/arn`) e o NAT Gateway tem `ngw_id` (ver [doc 15](15-subnets-privadas-e-nat-gateway.md)). O Internet Gateway tem `igw_id` e `igw_arn` (ver [14-internet-gateway.md](14-internet-gateway.md#outputs-outputstofu)). As route tables têm `route_table_public_id` e `route_table_private_id` (doc 16).

> Ainda não há outputs dos Security Groups. As EC2 vão precisar deles: ver a sugestão `sg_bastion_id`/`sg_vm_private_id` em [17-security-groups.md](17-security-groups.md#5-faltam-outputs).

> A primeira versão tinha 6 outputs (`subnet_public_a_id`, `subnet_public_a_arn`…). Como funciona o `for`, variações (mapa, filtro, splat) e a saída completa: [13-loops-for-each-e-for.md](13-loops-for-each-e-for.md).

> O resto deste doc usa os outputs da fase do **bucket S3** (removido do código em 2026-10-19). Os conceitos são os mesmos.

## Declarar (exemplo do S3)

```hcl
output "bucket_name" {
  description = "The name of the S3 bucket"
  value       = aws_s3_bucket.algadelivery-teste-devops.bucket
}

output "bucket_arn" {
  description = "The ARN of the S3 bucket"
  value       = aws_s3_bucket.algadelivery-teste-devops.arn
}

output "bucket_url" {
  description = "The URL of the S3 bucket"
  value       = aws_s3_bucket.algadelivery-teste-devops.bucket_regional_domain_name
}
```

| Argumento | Para que serve |
|-----------|----------------|
| `value` | O valor exposto. Obrigatório. Qualquer expressão: atributo de recurso, `var.*`, texto interpolado, mapa… |
| `description` | Documenta o output |
| `sensitive` | `true` esconde o valor no terminal (aparece `<sensitive>`). **Ele continua em texto puro no state** |

O `value` usa a mesma sintaxe de referência do doc 05: `<tipo>.<nome_lógico>.<atributo>`. Os atributos disponíveis (`arn`, `bucket_regional_domain_name`, `id`…) estão na seção *Attribute Reference* do recurso na doc do provider.

## No `plan`

Os outputs aparecem num bloco próprio. Saída real deste projeto:

```
Changes to Outputs:
  + bucket_arn  = (known after apply)
  + bucket_name = "algadelivery-teste-devops"
  + bucket_url  = (known after apply)
```

O `bucket_name` já é conhecido porque vem da variável; `arn` e o domínio só existem depois que a AWS cria o bucket.

## Depois do `apply`

O fim do `apply` lista os outputs:

```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

bucket_arn = "arn:aws:s3:::algadelivery-teste-devops"
bucket_name = "algadelivery-teste-devops"
bucket_url = "algadelivery-teste-devops.s3.us-east-1.amazonaws.com"
```

Os valores ficam gravados no **state**, então dá para consultá-los a qualquer momento, sem acessar a AWS:

```bash
tofu output                    # todos
tofu output bucket_arn         # um só, entre aspas: "arn:aws:s3:::..."
tofu output -raw bucket_arn    # sem aspas, bom para scripts
tofu output -json              # tudo em JSON
```

Exemplo em script:

```bash
aws s3 ls "s3://$(tofu output -raw bucket_name)"
```

## Pegadinhas

- **Referência a nome lógico antigo.** Aconteceu neste estudo: o `outputs.tofu` foi escrito com `aws_s3_bucket.algadelivery-teste-devops` quando o recurso se chamava `algadelivery-teste-tofu` (resolvido: o recurso voltou a se chamar `algadelivery-teste-devops`):
  ```
  Error: Reference to undeclared resource
    on outputs.tofu line 3, in output "bucket_name":
     3:   value = aws_s3_bucket.algadelivery-teste-devops.bucket
  There is no managed resource "aws_s3_bucket" "algadelivery-teste-devops"
  ```
  Ao renomear um recurso, procure todas as referências a ele (`grep -rn "nome_antigo" *.tofu`). Rode `tofu validate` para pegar o erro antes do `plan`.
- `tofu output` diz `No outputs found` → ainda não houve `apply` com os outputs, ou houve `destroy`: o state está vazio.
- Com backend remoto, `tofu output` lê o state do S3 do ambiente configurado no `init` (ver [09-backend-remoto-s3.md](09-backend-remoto-s3.md)).
- `bucket_regional_domain_name` é só o **domínio** (`...s3.us-east-1.amazonaws.com`), não uma URL completa. Para uma URL de verdade, monte no `value`: `"https://${aws_s3_bucket.algadelivery-teste-devops.bucket_regional_domain_name}"`.
- Adicionou ou mudou um output sem mudar recursos? `tofu apply` atualiza só os outputs no state (`0 added, 0 changed`).
- O nome do output (`bucket_name`) pode ser igual ao de uma variável: são espaços separados (`var.bucket_name` x `tofu output bucket_name`).
