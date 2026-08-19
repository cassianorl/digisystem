#!/usr/bin/env bash
# provisiona_samba_tasy.sh
# Prepara um servidor Samba para uso com TASY (auth DOMINIO;usuario:senha)
# Idempotente e interativo. Agora permite definir senha SMB explícita.

# ---------- util ----------
ask() { # ask "Pergunta" "valor_padrao"
  local prompt="$1"; local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " answer || true
    echo "${answer:-$default}"
  else
    read -rp "$prompt: " answer || true
    echo "$answer"
  fi
}
step() { echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

# ---------- parâmetros ----------
step "Coletando parâmetros"

WORKGROUP=$(ask "Workgroup (nome lógico para o TASY)" "DEFAULT")
NETBIOS=$(ask "NetBIOS name do servidor" "$(hostname -s | tr '[:lower:]' '[:upper:]')")
BIND_ONLY=$(ask "Restringir escuta à interface/IP? (yes/no)" "yes")
IPADDR=""; CIDR="24"
if [[ "$BIND_ONLY" =~ ^[Yy] ]]; then
  IPADDR=$(ask "IP que o Samba deve escutar (ex.: 20.255.46.191)" "")
  [[ -z "$IPADDR" ]] && die "IP não informado."
  CIDR=$(ask "CIDR da interface (ex.: 24)" "24")
fi

SHARE_NAME=$(ask "Nome do compartilhamento (share)" "tasy_anexos")
SHARE_PATH=$(ask "Caminho do diretório a exportar" "/anexos")

SMB_GROUP=$(ask "Grupo POSIX para controlar acesso" "sambagrp")
SMB_USER=$(ask "Usuário SMB local" "samba")
SMB_PASSWD=$(ask "Senha do usuário SMB (deixe vazio para usar o nome do usuário)" "")

DOMAIN_ALIAS=$(ask "Domínio lógico aceito pelo TASY (p/ login tipo DOMINIO;usuario:senha)" "$WORKGROUP")
OPEN_FIREWALL=$(ask "Liberar portas no firewalld (se ativo)? (yes/no)" "yes")

# ---------- detecção de distro ----------
PKG=""
if command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
elif command -v apt >/dev/null 2>&1; then PKG=apt
else die "Gerenciador de pacotes não suportado (dnf/yum/apt)."
fi

# ---------- pacotes ----------
step "Instalando pacotes necessários"
if [[ "$PKG" == "apt" ]]; then
  apt update -y
  apt install -y samba smbclient policycoreutils-python-utils || apt install -y policycoreutils
else
  $PKG -y install samba samba-client policycoreutils-python-utils || true
fi
ok "Pacotes instalados (ou já presentes)."

# ---------- grupo/usuário ----------
step "Criando grupo e usuário locais"
getent group "$SMB_GROUP" >/dev/null || groupadd "$SMB_GROUP"
if ! id "$SMB_USER" >/dev/null 2>&1; then
  useradd -M -s /sbin/nologin -g "$SMB_GROUP" "$SMB_USER"
else
  usermod -aG "$SMB_GROUP" "$SMB_USER" || true
fi
ok "Grupo/usuário prontos."

# ---------- diretório do share ----------
step "Preparando diretório do compartilhamento"
mkdir -p "$SHARE_PATH"
chown -R root:"$SMB_GROUP" "$SHARE_PATH"
chmod 2770 "$SHARE_PATH"
for d in temp default; do
  mkdir -p "$SHARE_PATH/$d"
  chown root:"$SMB_GROUP" "$SHARE_PATH/$d"
  chmod 2770 "$SHARE_PATH/$d"
done
ok "Permissões POSIX aplicadas (root:$SMB_GROUP, 2770)."

# ---------- SELinux ----------
if command -v getenforce >/dev/null 2>&1; then
  SELX=$(getenforce || true)
  step "Ajustando SELinux (status: ${SELX:-desconhecido})"
  if [[ "$SELX" == "Enforcing" || "$SELX" == "Permissive" ]]; then
    if command -v semanage >/dev/null 2>&1; then
      semanage fcontext -a -t samba_share_t "${SHARE_PATH}(/.*)?" 2>/dev/null || \
      semanage fcontext -m -t samba_share_t "${SHARE_PATH}(/.*)?"
      restorecon -Rv "$SHARE_PATH" || true
      setsebool -P samba_export_all_rw on || true
      ok "Contexto samba_share_t aplicado e escrita habilitada."
    else
      warn "semanage não encontrado; pulei rotulagem SELinux (instale policycoreutils-python-utils)."
    fi
  else
    warn "SELinux não está Enforcing/Permissive."
  fi
else
  warn "getenforce não encontrado; pulando ajustes SELinux."
fi

# ---------- backups ----------
STAMP="$(date +%F_%H%M%S)"
mkdir -p /root/samba-backup-$STAMP
[[ -f /etc/samba/smb.conf ]] && cp -a /etc/samba/smb.conf /root/samba-backup-$STAMP/
[[ -f /etc/samba/smbusers ]] && cp -a /etc/samba/smbusers /root/samba-backup-$STAMP/

# ---------- username map ----------
step "Configurando username map (/etc/samba/smbusers)"
{
  echo "${SMB_USER} = ${SMB_USER} ${WORKGROUP}\\${SMB_USER} ${DOMAIN_ALIAS}\\${SMB_USER}"
} >/etc/samba/smbusers
ok "Mapeamento: ${SMB_USER} = ${SMB_USER} ${WORKGROUP}\\${SMB_USER} ${DOMAIN_ALIAS}\\${SMB_USER}"

# ---------- smb.conf ----------
step "Escrevendo /etc/samba/smb.conf endurecido"
IFACE_LINES=""
if [[ "$BIND_ONLY" =~ ^[Yy] ]]; then
  IFACE_LINES=$'    bind interfaces only = yes\n'
  IFACE_LINES+="    interfaces = ${IPADDR}/${CIDR} lo"
fi

cat >/etc/samba/smb.conf <<EOF
[global]
    workgroup = ${WORKGROUP}
    netbios name = ${NETBIOS}

    security = user
    passdb backend = tdbsam
    username map = /etc/samba/smbusers
    map to guest = Bad User

    # Protocolos e autenticação
    server min protocol = SMB2_10
    client min protocol = SMB2
    ntlm auth = ntlmv2-only

    # Logs
    log level = 2
    log file = /var/log/samba/samba.log
    max log size = 5000
    timestamp logs = yes

${IFACE_LINES:+${IFACE_LINES}}

[${SHARE_NAME}]
    path = ${SHARE_PATH}
    comment = ${SHARE_PATH}
    browseable = yes
    read only = no
    valid users = @${SMB_GROUP} ${SMB_USER}
    force group = ${SMB_GROUP}
    create mask = 0660
    directory mask = 2770
    inherit permissions = yes
    inherit acls = yes
EOF

ok "/etc/samba/smb.conf escrito."

# ---------- senha SMB ----------
step "Definindo senha SMB para ${SMB_USER}"
FINAL_PASS="${SMB_PASSWD:-$SMB_USER}"

if pdbedit -L -u "${SMB_USER}" >/dev/null 2>&1; then
  warn "Usuário SMB '${SMB_USER}' já existe. A senha será redefinida."
fi

if printf '%s\n%s\n' "$FINAL_PASS" "$FINAL_PASS" | smbpasswd -a -s "${SMB_USER}" >/dev/null 2>&1; then
  ok "Senha SMB definida para '${SMB_USER}' (senha: '${FINAL_PASS}')."
else
  warn "Falha ao definir senha automaticamente. Será necessário digitar manualmente."
  smbpasswd -a "${SMB_USER}"
fi

# ---------- validar config ----------
step "Validando configuração (testparm)"
testparm -s || die "testparm encontrou erros na configuração."

# ---------- firewall ----------
if systemctl is-active --quiet firewalld; then
  if [[ "$OPEN_FIREWALL" =~ ^[Yy] ]]; then
    step "Abrindo portas Samba no firewalld"
    firewall-cmd --add-service=samba --permanent || true
    firewall-cmd --reload || true
    ok "Firewalld liberado para Samba."
  else
    warn "Firewalld está ativo e você optou por não abrir portas (445/139)."
  fi
else
  ok "Firewalld inativo: nenhuma regra aplicada."
fi

# ---------- iniciar serviços ----------
step "Habilitando e iniciando serviços"
systemctl enable smb nmb >/dev/null 2>&1 || true
systemctl restart smb
systemctl restart nmb || true
systemctl --no-pager -l status smb | sed -n '1,12p' || true

# ---------- teste ----------
step "Teste rápido com smbclient (substitua <senha> se você alterou no prompt)"
if [[ -n "${IPADDR:-}" ]]; then
  echo "  smbclient //${IPADDR}/${SHARE_NAME} -U \"${DOMAIN_ALIAS}\\\\${SMB_USER}\"%${FINAL_PASS} -c 'ls'"
else
  echo "  smbclient //<IP>/${SHARE_NAME} -U \"${DOMAIN_ALIAS}\\\\${SMB_USER}\"%${FINAL_PASS} -c 'ls'"
fi

ok "Provisionamento finalizado.
Backups: /root/samba-backup-${STAMP}
Share:   //${IPADDR:-IP_DO_SERVIDOR}/${SHARE_NAME}
Caminho: ${SHARE_PATH}
Usuário: ${DOMAIN_ALIAS}\\${SMB_USER}  (mapeado para local '${SMB_USER}')
Senha:   '${FINAL_PASS}' (a menos que você a tenha alterado no prompt)

Parametro 185:${DOMAIN_ALIAS};${SMB_USER}:${FINAL_PASS}"