# Guia de Instalação — OpenTofu e AWS CLI

Instruções para WSL2/Linux (Ubuntu/Debian) e macOS.

---

## 1. OpenTofu

### WSL2 / Linux (Ubuntu, Debian e derivados)

**Opção A — Script de instalação oficial (mais rápido)**

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
./install-opentofu.sh --install-method deb
rm -f install-opentofu.sh
```

**Opção B — Passo a passo manual via APT**

```bash
# 1. Dependências
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

# 2. Chave GPG do OpenTofu
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://get.opentofu.org/opentofu.gpg | sudo tee /etc/apt/keyrings/opentofu.gpg > /dev/null
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | sudo gpg --no-tty --batch --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg > /dev/null
sudo chmod a+r /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg

# 3. Repositório
echo \
  "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main
deb-src [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" | \
  sudo tee /etc/apt/sources.list.d/opentofu.list > /dev/null
sudo chmod a+r /etc/apt/sources.list.d/opentofu.list

# 4. Instalação
sudo apt-get update
sudo apt-get install -y tofu
```

### macOS

Requer [Homebrew](https://brew.sh). Caso não tenha instalado:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Instalar OpenTofu:

```bash
brew update
brew install opentofu
```

### Verificar instalação

```bash
tofu version
```

---

## 2. AWS CLI v2

### WSL2 / Linux (x86_64)

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
```

> Para arquitetura ARM64 (ex: Graviton, Raspberry Pi), substitua `x86_64` por `aarch64` na URL acima.

### macOS

**Opção A — Homebrew**

```bash
brew install awscli
```

**Opção B — Instalador oficial (.pkg)**

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
rm -f AWSCLIV2.pkg
```

### Verificar instalação

```bash
aws --version
```

---

## 3. Configurar credenciais AWS

Após instalar o AWS CLI, configure suas credenciais:

```bash
aws configure
```

Informe quando solicitado:

| Campo                    | Exemplo                  |
|--------------------------|--------------------------|
| AWS Access Key ID        | `AKIAIOSFODNN7EXAMPLE`   |
| AWS Secret Access Key    | `wJalrXUtnFEMI/K7MDENG…` |
| Default region name      | `us-east-1`              |
| Default output format    | `json`                   |

As credenciais são salvas em `~/.aws/credentials` e a configuração em `~/.aws/config`.

### Verificar acesso

```bash
aws sts get-caller-identity
```

---

## Referências

- [OpenTofu — Instalação oficial](https://opentofu.org/docs/intro/install/)
- [AWS CLI v2 — Instalação oficial](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
