#!/usr/bin/env bash
set -euo pipefail

############################################################
# CONFIGURAÇÕES
############################################################
TIE_BASE_DIR="/opt/philips"
TIE_DIR="${TIE_BASE_DIR}/tie"
BUNDLE_ZIP="bifrost_1.68.0_onprem_ha_bundle.zip"

FTP_URL="ftp://ftp.digisystem.cloud//SOFTWARES/TIE_NOVO/${BUNDLE_ZIP}"
FTP_USER="ftp-digi"
FTP_PASS=""

PHILIPS_REPO_SCRIPT_URL="https://repo.tasy.com.br/pub/philips_repo_public.sh"

############################################################
# HELPERS
############################################################
log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die()  { echo -e "[ERRO] $*" >&2; exit 1; }

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Execute como root."
}

backup_file() {
  [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"
}

upsert_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  touch "$file"

  if grep -qF "$begin" "$file"; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi

  {
    echo "$begin"
    echo "$content"
    echo "$end"
  } >> "$file"
}

detect_os_major() {
  grep -oE '[0-9]+' /etc/redhat-release | head -1
}

FAILED_PKGS=""

install_pkg() {
  local pkg="$1"

  if rpm -q "$pkg" &>/dev/null; then
    log "Pacote $pkg: já instalado"
    return 0
  fi

  log "Instalando pacote: $pkg"

  # roda yum em silêncio total
  if yum install -y -q "$pkg" >/dev/null 2>&1; then
    log "Pacote $pkg: instalado com sucesso"
  else
    local rc=$?
    # WARN em vermelho
    echo -e "\e[31m[+] WARN: falha ao instalar pacote ${pkg} (rc=${rc}). Continuando...\e[0m"
    FAILED_PKGS="${FAILED_PKGS} ${pkg}"
  fi

  return 0
}


install_pkg_optional() {
  local pkg="$1"
  if yum list available "$pkg" &>/dev/null; then
    install_pkg "$pkg"
  else
    warn "Pacote opcional $pkg não disponível (ignorado)"
  fi
}

############################################################
# ETAPA 1 — SISTEMA OPERACIONAL
############################################################
disable_selinux() {
  if [[ -f "/.tie_selinux_done" ]]; then
    log "SELinux já foi desabilitado anteriormente (/.tie_selinux_done)"
    return
  fi

  log "Desabilitando SELinux (persistente)"
  for f in /etc/selinux/config /etc/sysconfig/selinux; do
    [[ -f "$f" ]] || continue
    backup_file "$f"
    sed -ri 's/^SELINUX=(enforcing|permissive)/SELINUX=disabled/' "$f"
  done

  # Desabilita temporariamente até reboot
  if command -v setenforce &>/dev/null; then
    setenforce 0 || true
  fi

  #########################
  # FIREWALL & IPTABLES
  #########################
  log "Desabilitando e limpando firewalld/iptables"

  # Stop e Disable do firewalld
  systemctl stop firewalld &>/dev/null || true
  systemctl disable firewalld &>/dev/null || true

  # Flush iptables
  iptables -F &>/dev/null || true
  ip6tables -F &>/dev/null || true

  touch "/.tie_selinux_done"
}


tune_limits_sysctl() {

  if [[ -f "/.tie_sysctl_done" ]]; then
    log "Limits e sysctl já foram configurados anteriormente (/.tie_sysctl_done)"
    return
  fi
  
  log "Aplicando limits.conf"
  backup_file /etc/security/limits.conf

  upsert_block /etc/security/limits.conf \
"#### ALTERACAO INSTALACAO TASY INICIO ####" \
"#### ALTERACAO INSTALACAO TASY  FIM ####" \
"*   soft   nofile    8192
*   hard   nofile    65536
*   soft   nproc     16384
*   hard   nproc     16384
*   soft   stack     10240
*   hard   stack     32768
*   soft   memlock   134217728
*   hard   memlock   134217728"

  log "Aplicando sysctl.conf"
  backup_file /etc/sysctl.conf

  upsert_block /etc/sysctl.conf \
"#### ALTERACAO INSTALACAO TASY  ####" \
"#### ALTERACAO INSTALACAO TASY  FIM ####" \
"# Docker/bridge e roteamento local
net.ipv4.ip_forward = 1

# Conexões e rede
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.optmem_max = 25165824

# Portas efêmeras
net.ipv4.ip_local_port_range = 10000 65535

# Keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_fin_timeout = 15

# Buffers
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 1048576

# FDs globais
fs.file-max = 2097152

# Inotify
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Swappiness
vm.swappiness = 5
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20

# rp_filter
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 1"

  sysctl --system > /dev/null || true
  sysctl -p > /dev/null || true

  touch "/.tie_sysctl_done"
}

############################################################
# ETAPA 2 — PACOTES
############################################################
install_packages() {
  if [[ -f "/.tie_packages_done" ]]; then
    log "Pacotes essenciais já foram instalados anteriormente (/.tie_packages_done)"
    return
  fi
  
  log "Instalando pacotes essenciais"
  for pkg in zip unzip wget ftp curl net-tools psmisc yum-utils jq tar; do
    install_pkg "$pkg"
  done
  if [[ -n "${FAILED_PKGS// /}" ]]; then
    log "WARN: Pacotes que falharam na instalação:${FAILED_PKGS}"
  fi

  log "Instalando pacotes opcionais"
  for pkg in figlet cowsay foomatic-filters; do
    install_pkg_optional "$pkg"
  done

  touch "/.tie_packages_done"
}

############################################################
# ETAPA 3 — DOCKER
############################################################
install_docker() {
  log "Removendo Docker antigo (se existir)"
  yum remove -y docker\* containerd\* &>/dev/null || true

  log "Habilitando repositório Docker (via Philips)"
  curl -fsSL "$PHILIPS_REPO_SCRIPT_URL" | bash &>/dev/null

  log "Detectando versão Docker 26.x disponível"
  local docker_ver
  docker_ver="$(
    yum list --showduplicates docker-ce 2>/dev/null \
      | awk '$1 ~ /^docker-ce/ {print $2}' \
      | sort -V \
      | awk '/^3:26\./ {v=$0} END {print v}'
  )"

  if [[ -z "$docker_ver" ]]; then
    warn "Versões disponíveis no repositório:"
    yum list --showduplicates docker-ce 2>/dev/null || true
    die "Docker 26.x não encontrado no repositório habilitado"
  fi

  log "Instalando Docker $docker_ver"
  yum install -y -q "docker-ce-$docker_ver" containerd.io docker-compose-plugin
  systemctl enable --now docker &>/dev/null

  log "Criando wrapper docker-compose (compatibilidade com TIE)"
  cat <<'EOF' > /usr/local/bin/docker-compose
#!/usr/bin/env bash
exec docker compose "$@"
EOF

  chmod +x /usr/local/bin/docker-compose
}

############################################################
# ETAPA 4 — TIE
############################################################
deploy_tie() {
  log "Preparando diretórios do TIE"
  mkdir -p "$TIE_BASE_DIR"
  cd "$TIE_BASE_DIR"

  if [[ ! -f "$BUNDLE_ZIP" ]]; then

    [[ -n "$FTP_USER" ]] || die "FTP_USER não definido"

    if [[ -z "$FTP_PASS" ]]; then
      read -rsp "Informe a senha do FTP (${FTP_USER}): " FTP_PASS
      echo
    fi

    log "Baixando bundle do TIE"

    MAX_TENTATIVAS=3
    tentativa=1

    while [[ $tentativa -le $MAX_TENTATIVAS ]]; do
      if wget --user="$FTP_USER" --password="$FTP_PASS" "$FTP_URL" &>/dev/null; then
        log "Download realizado com sucesso"
        break
      fi

      warn "Falha de autenticação no FTP (tentativa $tentativa/$MAX_TENTATIVAS)"

      if [[ $tentativa -ge $MAX_TENTATIVAS ]]; then
        die "Número máximo de tentativas excedido. Verifique usuário/senha do FTP."
      fi

      FTP_PASS=""
      read -rsp "Informe novamente a senha do FTP (${FTP_USER}): " FTP_PASS
      echo

      tentativa=$((tentativa + 1))
    done

  else
    log "Bundle já presente"
  fi

  if [[ ! -d "$TIE_DIR" ]]; then
    log "Descompactando bundle"
    unzip -q "$BUNDLE_ZIP"
  else
    log "Diretório TIE já existe"
  fi

  if [[ -d "${TIE_BASE_DIR}/tie_bundle" ]]; then
    log "Removendo diretório tie_bundle (não necessário para TIE puro)"
    rm -rf "${TIE_BASE_DIR}/tie_bundle"
  fi

  log "Ajustando permissão dos scripts"
  find "$TIE_DIR" -type f -name "*.sh" -exec chmod 755 {} +
}

############################################################
# ETAPA 5 - CONFIGURAÇÃO BIFROST FRONTEND
############################################################
get_primary_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

configure_bifrost_frontend() {
  local cfg_file="${TIE_DIR}/configs/bifrost-frontend/config.js"

  [[ -f "$cfg_file" ]] || die "Arquivo não encontrado: $cfg_file"

  local tie_ip
  tie_ip="$(get_primary_ip)"

  if [[ -n "$tie_ip" ]]; then
    log "IP do servidor TIE detectado: $tie_ip"
    read -rp "Confirmar este IP? [Enter para sim / n para não]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
      read -rp "Informe o IP correto do servidor TIE: " tie_ip
    fi
  else
    read -rp "Informe o IP do servidor TIE: " tie_ip
  fi

  echo
  read -rp "O Tasy-Interfaces está no MESMO servidor do TIE? (s/n): " same_host

  local tasy_ip
  if [[ "$same_host" =~ ^[Ss]$ ]]; then
    tasy_ip="$tie_ip"
  else
    read -rp "Informe o IP do servidor Tasy-Interfaces: " tasy_ip
  fi

  backup_file "$cfg_file"

  log "Atualizando bifrost-frontend/config.js"

  sed -i \
    -e "s|<bifrost-admin-backend>|${tie_ip}|g" \
    -e "s|<kibana-host>|${tie_ip}|g" \
    -e "s|<tasy-interfaces-host>|${tasy_ip}|g" \
    -e "s|<tasy-interfaces-port>|7070|g" \
    "$cfg_file"

  warn "Campo <kibana-index-pattern-id> permanece para configuração posterior."
}

############################################################
# ETAPA 6 — CHECK + INSTALL + START TIE
############################################################
check_install_start_TIE() {
  echo
  log "=== CHECK FINAL DO AMBIENTE TIE ==="

  local cfg_file="${TIE_DIR}/configs/bifrost-frontend/config.js"

  # 1. Verificar config.js
  log "Validando bifrost-frontend/config.js"

  if grep -q "<bifrost-admin-backend>" "$cfg_file"; then
    die "config.js NÃO foi configurado corretamente (placeholders ainda presentes)"
  fi

  log "config.js configurado corretamente"

  # 2. Versões Docker
  echo
  log "Versões do ambiente Docker"

  echo "--------------------------------------------------"
  printf "Docker:          "
  docker --version
  printf "Docker Compose:  "
  docker-compose version
  echo "--------------------------------------------------"

  # 3. Perguntar se executa install.sh
  echo
  read -rp "Deseja executar agora o install.sh do TIE? (s/n): " run_install

  if [[ "$run_install" =~ ^[Ss]$ ]]; then
    log "Executando install.sh"
    cd "$TIE_DIR" || die "Falha ao acessar $TIE_DIR"
    ./install.sh
  else
    warn "install.sh NÃO executado"
  fi

  # 4. Perguntar se executa start.sh
  echo
  read -rp "Deseja executar agora o start.sh do TIE? (s/n): " run_start

  if [[ "$run_start" =~ ^[Ss]$ ]]; then
    log "Executando start.sh"
    cd "$TIE_DIR" || die "Falha ao acessar $TIE_DIR"
    ./start.sh
  else
    warn "start.sh NÃO executado"
  fi

  # 5. docker ps final
  echo
  log "Estado final dos containers Docker"
  echo "--------------------------------------------------"
  docker ps
  echo "--------------------------------------------------"

  log "CHECK FINAL DO TIE CONCLUÍDO"
}

############################################################
# BLOCO DE CONFIGURAÇÃO DO CONEXT.XML
############################################################
configure_context_xml() {
  local context_file="/u01/TasyInterfacesServer/conf/context.xml"

  [[ -f "$context_file" ]] || die "Arquivo context.xml não encontrado em $context_file"

  echo
  log "=== Configuração do context.xml (conexão com o banco Oracle) ==="

  # Coletar informações do banco
  read -rp "Informe o IP do banco Oracle: " db_ip
  read -rp "Informe a porta do banco Oracle [1521]: " db_port
  db_port="${db_port:-1521}"

  read -rp "Informe o Service Name do banco Oracle: " db_service

  local jdbc_url="jdbc:oracle:thin:@${db_ip}:${db_port}/${db_service}"
  echo
  log "URL JDBC final montada:"
  echo "    $jdbc_url"
  echo

  # Atualizar campo url
  sed -i -E "s|url=\"jdbc:oracle:thin:@[^\"]*\"|url=\"$jdbc_url\"|" "$context_file"
  log "Campo 'url' atualizado com sucesso."

  # Coletar e atualizar a senha do usuário tasy
  echo
  read -rsp "Informe a senha do banco para o usuário 'tasy': " db_password
  echo

  sed -i -E "s|password=\"[^\"]*\"|password=\"$db_password\"|" "$context_file"
  log "Campo 'password' atualizado com sucesso."

  echo
  log "Arquivo context.xml atualizado com as configurações do banco."
}

############################################################
# CONFIGURAÇÃO DO SETENV.SH do TOMCAT
############################################################
configure_setenv_sh() {
  local setenv_file="/u01/TasyInterfacesServer/bin/setenv.sh"

  [[ -f "$setenv_file" ]] || die "Arquivo setenv.sh não encontrado: $setenv_file"

  echo
  log "=== Configuração do setenv.sh ==="

  # Detectar IP local
  local local_ip
  local_ip="$(get_primary_ip)"
  echo
  log "IP local detectado: $local_ip"
  read -rp "O TIE está no mesmo servidor? [Enter para sim / n para não]: " tie_same
  local tie_ip
  if [[ "$tie_same" =~ ^[Nn]$ ]]; then
    read -rp "Informe o IP do servidor TIE: " tie_ip
  else
    tie_ip="$local_ip"
  fi

  local events_url="http://${tie_ip}:9090/bifrost/events"
  local tasy_url="http://${tie_ip}:9090/tasy"

  echo
  log "URL de eventos configurada: $events_url"
  log "URL Tasy configurada       : $tasy_url"

  # Atualizar ou inserir URLs
  sed -i -E "s|(-Dphilips\.bifrost\.events\.url=)[^\"']+|\1${events_url}|" "$setenv_file"
  sed -i -E "s|(-Dphilips\.bifrost\.tasy\.url=)[^\"']+|\1${tasy_url}|" "$setenv_file"

  # Caso não existam, adicionar ao final
  grep -q "bifrost.events.url=" "$setenv_file" || echo "JAVA_OPTS=\"\$JAVA_OPTS -Dphilips.bifrost.events.url=${events_url}\"" >> "$setenv_file"
  grep -q "bifrost.tasy.url=" "$setenv_file" || echo "JAVA_OPTS=\"\$JAVA_OPTS -Dphilips.bifrost.tasy.url=${tasy_url}\"" >> "$setenv_file"

  ###################
  # POLLING
  ###################
  echo
  read -rp "Deseja habilitar o polling de conexão? (s/n): " use_polling

  if [[ "$use_polling" =~ ^[Ss]$ ]]; then
    read -rp "Informe o Consumer ID do polling [default]: " polling_id
    polling_id="${polling_id:-default}"

    # Atualizar ou inserir as opções de polling
    sed -i '/-Dphilips\.bifrost\.polling\.enabled/d' "$setenv_file"
    sed -i '/-Dphilips\.bifrost\.polling\.consumer\.id/d' "$setenv_file"

    echo "JAVA_OPTS=\"\$JAVA_OPTS -Dphilips.bifrost.polling.enabled=true\"" >> "$setenv_file"
    echo "JAVA_OPTS=\"\$JAVA_OPTS -Dphilips.bifrost.polling.consumer.id=${polling_id}\"" >> "$setenv_file"
	echo "export JAVA_OPTS" >> "$setenv_file"

    log "Polling habilitado com Consumer ID: $polling_id"
  else
    # Remover entradas se existirem
    sed -i '/-Dphilips\.bifrost\.polling\.enabled/d' "$setenv_file"
    sed -i '/-Dphilips\.bifrost\.polling\.consumer\.id/d' "$setenv_file"
    log "Polling desabilitado"
  fi

  echo
  log "Configuração do setenv.sh concluída."
}


############################################################
# ETAPA EXTRA — INSTALAÇÃO DO TASY-INTERFACES
############################################################
install_tasy_interfaces() {
  echo
  log ">>> Iniciando instalação do Tasy-Interfaces <<<"

  local BASE_DIR="/u01"
  local FTP_BASE="ftp://ftp.digisystem.cloud//SOFTWARES/TIE_NOVO"
  local JDK_TAR="jdk-8u461-linux-x64.tar.gz"
  local TASY_TAR="TasyInterfacesServer.tar.gz"

  require_root

  # Garantir pré-requisitos de SO
  disable_selinux
  tune_limits_sysctl
  install_packages

  # Criar /u01
  log "Garantindo diretório ${BASE_DIR}"
  mkdir -p "${BASE_DIR}"
  cd "${BASE_DIR}"

  ######################
  # DOWNLOAD DOS ARQUIVOS
  #######################
  for file in "$JDK_TAR" "$TASY_TAR"; do
    if [[ -f "$file" ]]; then
      log "Arquivo $file já existe, pulando download"
    else
      [[ -n "$FTP_USER" ]] || die "FTP_USER não definido"

      if [[ -z "$FTP_PASS" ]]; then
        read -rsp "Informe a senha do FTP (${FTP_USER}): " FTP_PASS
        echo
      fi

      log "Baixando $file"
      wget --user="$FTP_USER" --password="$FTP_PASS" "${FTP_BASE}/${file}" \
        || die "Falha ao baixar $file"
    fi
  done

 ########################
  # DESCOMPACTAÇÃO DO JDK
  ########################
  log "Removendo diretórios JDK antigos (se existirem)"
  find "${BASE_DIR}" -maxdepth 1 -type d -name "jdk*" ! -name "jdk" -exec rm -rf {} +

  log "Descompactando novo JDK"
  tar -xzvf "${JDK_TAR}" -C "${BASE_DIR}" >/dev/null || die "Falha ao descompactar o JDK"

# Detectar o diretório real do JDK extraído (ignorando o link simbólico)
local JDK_DIR
JDK_DIR=$(find "${BASE_DIR}" -maxdepth 1 -type d -name "jdk*" ! -name "jdk" | head -n1)

[[ -d "$JDK_DIR" ]] || die "Diretório do JDK não encontrado após extração"

  ########################
  # LINK SIMBÓLICO DO JDK
  ########################
  if [[ -L "${BASE_DIR}/jdk" || -d "${BASE_DIR}/jdk" ]]; then
    log "Removendo link ou diretório /u01/jdk antigo"
    rm -rf "${BASE_DIR}/jdk"
  fi

  log "Criando link simbólico /u01/jdk -> ${JDK_DIR}"
  ln -s "$JDK_DIR" "${BASE_DIR}/jdk"

  #####################
  # DESCOMPACTAÇÃO DO TASY INTERFACES
  #####################
  if [[ -d "${BASE_DIR}/TasyInterfacesServer" ]]; then
    log "TasyInterfacesServer já existe, pulando extração"
  else
    log "Descompactando TasyInterfacesServer"
    tar -xzf "$TASY_TAR"
  fi

  ######################
  # ESTRUTURA BÁSICA AUXILIAR
  ######################
  mkdir -p "${BASE_DIR}/logs" "${BASE_DIR}/scripts"

  ######################
  # CONFIGURAÇÃO DO CONTEXT.XML
  ######################
  configure_context_xml
  configure_setenv_sh

  log "Estrutura atual em /u01:"
  ls -lh "${BASE_DIR}"
  
  echo "=================================================="
  echo "Tasy-Interfaces configurado com sucesso"
  echo "Por favor, disponibilizar o arquivo tasy-interfaces.war"
  echo "no caminho: /u01/TasyInterfacesServer/webapps"
  echo "e executar o comando para iniciar o ambiente"
  echo "/u01/TasyInterfacesServer/bin/startup.sh"
  echo "=================================================="

  local ip
  ip="$(get_primary_ip)"
  echo "--------------------------------------------------"
  echo "URL Tasy-Interfaces   : http://${ip}:7070/tasy-interfaces"
  echo "--------------------------------------------------"  

  log ">>> Instalação base do Tasy-Interfaces concluída <<<"
}

############################################################
# CONFIGURAÇÃO DO KIBANA (INDEX PATTERNS + ILM)
############################################################
configure_kibana() {
  local kibana_url="http://localhost:5601"
  local es_url="http://localhost:9200"

  log "Aguardando Kibana iniciar..."

  local kibana_ready=false
  for attempt in {1..4}; do
    if curl -s --fail "${kibana_url}/api/status" &>/dev/null; then
      kibana_ready=true
      break
    fi
    log "Kibana não respondeu (tentativa $attempt/4). Aguardando 30s..."
    sleep 30
  done

  if [[ "$kibana_ready" == false ]]; then
    warn "Kibana não respondeu após 4 tentativas. Configuração do Kibana abortada."
    return
  fi

  log "Kibana está pronto. Criando Index Patterns..."

  ########################
  # INDEX PATTERNS
  ########################
  curl -s -X POST "${kibana_url}/api/saved_objects/index-pattern/bifrost-server-*" \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -d '{"attributes":{"title":"bifrost-server-*","timeFieldName":"@timestamp"}}' \
    >/dev/null 2>&1

  curl -s -X POST "${kibana_url}/api/saved_objects/index-pattern/bifrost-admin-backend-*" \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -d '{"attributes":{"title":"bifrost-admin-backend-*","timeFieldName":"@timestamp"}}' \
    >/dev/null 2>&1

  ########################
  # DEFAULT INDEX
  ########################
  curl -s -X POST "${kibana_url}/api/kibana/settings/defaultIndex" \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -d '{"value": "bifrost-server-*"}' \
    >/dev/null 2>&1

  log "Index Patterns configurados com sucesso."

  ########################
  # INDEX LIFECYCLE POLICY (ILM)
  ########################
  log "Criando Index Lifecycle Policy (ILM)..."

  curl -s -X PUT "${es_url}/_ilm/policy/bifrost-policy" \
    -H 'Content-Type: application/json' \
    -d '{
      "policy": {
        "phases": {
          "hot": {
            "min_age": "0ms",
            "actions": {
              "rollover": {
                "max_age": "7d",
                "max_size": "5gb"
              }
            }
          },
          "cold": {
            "min_age": "7d",
            "actions": {
              "allocate": {
                "require": {
                  "data": "cold"
                }
              }
            }
          },
          "delete": {
            "min_age": "14d",
            "actions": {
              "delete": {}
            }
          }
        }
      }
    }' \
    >/dev/null 2>&1

  log "ILM configurado com sucesso."
  log "Configuração do Kibana concluída."
}


configuraILP() {
  local ES_URL="http://localhost:9200"
  local POLICY_NAME="biFrostILP"
  local TEMPLATE_NAME="bifrost_template"
  local INDEX_PATTERN="bifrost-*"
  local EXISTING_INDICES=""

  echo "1) Criando/atualizando ILM policy: ${POLICY_NAME}"
  curl -fsS -X PUT "${ES_URL}/_ilm/policy/${POLICY_NAME}" \
    -H 'Content-Type: application/json' \
    -d @- <<'JSON' || return 1
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {}
      },
      "delete": {
        "min_age": "14d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
JSON

  echo
  echo "2) Criando/atualizando index template: ${TEMPLATE_NAME}"
  curl -fsS -X PUT "${ES_URL}/_index_template/${TEMPLATE_NAME}" \
    -H 'Content-Type: application/json' \
    -d @- <<JSON || return 1
{
  "index_patterns": ["${INDEX_PATTERN}"],
  "template": {
    "settings": {
      "index.lifecycle.name": "${POLICY_NAME}"
    }
  },
  "priority": 100
}
JSON

  echo
  echo "3) Verificando se existem indices atuais em ${INDEX_PATTERN}"
  EXISTING_INDICES="$(curl -fsS "${ES_URL}/_cat/indices/${INDEX_PATTERN}?h=index&expand_wildcards=open" 2>/dev/null || true)"

  if [ -n "${EXISTING_INDICES}" ]; then
    echo "Indices encontrados:"
    echo "${EXISTING_INDICES}"

    echo
    echo "4) Removendo bloqueio read_only_allow_delete, se existir..."
    curl -fsS -X PUT "${ES_URL}/${INDEX_PATTERN}/_settings?expand_wildcards=open" \
      -H 'Content-Type: application/json' \
      -d @- <<'JSON' || return 1
{
  "index.blocks.read_only_allow_delete": null
}
JSON

    echo
    echo "5) Removendo metadados ILM anteriores dos indices existentes..."
    curl -fsS -X POST "${ES_URL}/${INDEX_PATTERN}/_ilm/remove?expand_wildcards=open" || return 1

    echo
    echo "6) Associando a policy aos indices existentes..."
    curl -fsS -X PUT "${ES_URL}/${INDEX_PATTERN}/_settings?expand_wildcards=open" \
      -H 'Content-Type: application/json' \
      -d @- <<JSON || return 1
{
  "index.lifecycle.name": "${POLICY_NAME}"
}
JSON

    echo
    echo "7) Retry ILM"
    echo "Retry nao sera executado automaticamente."
    echo "O endpoint _ilm/retry deve ser usado apenas em indices que estejam em step ERROR."
  else
    echo "Nenhum indice atual encontrado para ${INDEX_PATTERN}. Seguindo apenas com o template."
  fi

  echo
  echo "8) Validacoes"

  echo
  echo "--- Uso de disco dos nodes ---"
  curl -fsS "${ES_URL}/_cat/nodes?v&h=name,disk.used_percent,disk.avail,disk.total" || return 1

  echo
  echo "--- Status do ILM ---"
  curl -fsS "${ES_URL}/_ilm/status?pretty" || return 1

  echo
  echo "--- Policy ---"
  curl -fsS "${ES_URL}/_ilm/policy/${POLICY_NAME}?pretty" || return 1

  echo
  echo "--- Template ---"
  curl -fsS "${ES_URL}/_index_template/${TEMPLATE_NAME}?pretty" || return 1

  echo
  echo "--- Indices ${INDEX_PATTERN} ---"
  curl -fsS "${ES_URL}/_cat/indices/${INDEX_PATTERN}?v&s=index&expand_wildcards=open" || true

  echo
  echo "--- ILM Explain ${INDEX_PATTERN} ---"
  curl -fsS "${ES_URL}/${INDEX_PATTERN}/_ilm/explain?expand_wildcards=open&pretty" || true

  echo
  echo "--- Verificando bloqueios read_only_allow_delete ---"
  curl -fsS "${ES_URL}/${INDEX_PATTERN}/_settings/index.blocks.read_only_allow_delete?expand_wildcards=open&pretty" || true

  echo
  echo "Concluido."
}

############################################################
# MAIN TIE
############################################################
install_tie() {
  require_root
  disable_selinux
  tune_limits_sysctl
  install_packages
  install_docker
  deploy_tie
  configure_bifrost_frontend
  check_install_start_TIE
  sleep 30
  curl -X POST "http://localhost:9200/bifrost-server-indexpartnew/_doc/" -H 'Content-Type: application/json' -d '
  {
    "@timestamp": "'$(date --iso-8601=seconds)'",
    "message": "Teste manual via curl para forcar criacao do IndexPart",
    "status": "OK",
    "source": "curl"
  }' &>/dev/null


  log "Instalação base do TIE concluída com sucesso"
  echo "Próximo passo:"
  echo "   Configuração do Kibana"
  echo "   IndexPatterns: bifrost-admin-backend-* e bifrost-server-*"

  local ip
  ip="$(get_primary_ip)"

  echo
  log "URLs de acesso do ambiente TIE"
  echo "--------------------------------------------------"
  echo "KIBANA URL   : http://${ip}:5601"
  echo "KEYCLOAK URL : http://${ip}:8282/auth/admin"
  echo "TIE URL      : http://${ip}:8080"
  echo "TASY INTERF  : http://${ip}:7070"  
  echo "--------------------------------------------------"

  echo
read -rp "Deseja instalar o Tasy-Interfaces neste mesmo servidor? (s/n): " instalar_tasy
if [[ "$instalar_tasy" =~ ^[Ss]$ ]]; then
  install_tasy_interfaces
else
  warn "Instalação do Tasy-Interfaces ignorada. Retornando ao menu principal..."
  sleep 1
  return
fi
}

main_tasy_interfaces() {
  require_root
  install_tasy_interfaces
}


############################################################
# VALIDAÇÃO REAL DO KIBANA (INDEX PATTERNS + ILM)
############################################################
valida_kibana() {
:
}

############################################################
# ETAPA 4 — INSTALAR / ATUALIZAR TASY-INTERFACES (.war)
############################################################
install_tasy_interfaces_version() {
  local ftp_dir="ftp://ftp.digisystem.cloud//SOFTWARES/TIE_NOVO"
  local dest_dir="/u01/TasyInterfacesServer/webapps"
  local war_final_name="tasy-interfaces.war"
  local base_dir="/u01/TasyInterfacesServer"

  [[ -d "$base_dir" ]] || {
    warn "O diretório ${base_dir} não existe."
    echo "Execute primeiro a instalação do Tasy-Interfaces (opção 2)."
    return
  }

  [[ -n "$FTP_USER" ]] || {
    warn "Variável FTP_USER não definida!"
    return
  }

  log "Buscando versões disponíveis no FTP..."

  local max_tries=3
  local try=1
  local files=""

  while [[ -z "$files" && "$try" -le "$max_tries" ]]; do
    [[ -n "$FTP_PASS" ]] || read -rsp "Informe a senha do FTP (${FTP_USER}): " FTP_PASS && echo

    log "Tentando acessar o FTP (tentativa $try de $max_tries)..."

    files=$(curl -s --user "$FTP_USER:$FTP_PASS" "$ftp_dir/" \
      | grep -o 'tasy-interfaces-[^"]*\.war' | sort -u)

    [[ -n "$files" ]] && break

    warn "Falha ao listar arquivos no FTP."
    FTP_PASS=""
    ((try++))
  done

  [[ -n "$files" ]] || {
    warn "Não foi possível acessar o FTP."
    return
  }

  echo "Versões disponíveis:"
  select war_file in $files; do
    [[ -n "$war_file" ]] && break
    echo "Opção inválida."
  done

  log "Baixando ${war_file}..."
  wget --user="$FTP_USER" --password="$FTP_PASS" \
    "${ftp_dir}/${war_file}" \
    -O "${dest_dir}/${war_final_name}" || {
      warn "Falha no download."
      return
    }

  log "WAR atualizado com sucesso."

  log "Iniciando Tomcat via systemd..."
  /u01/TasyInterfacesServer/bin/startup.sh 2>&1

  local ip
  ip="$(get_primary_ip)"

  echo
  echo "=================================================="
  echo "[✔] Tasy-Interfaces iniciado com sucesso"
  echo "URL:"
  echo " http://${ip}:7070/tasy-interfaces"
  echo "=================================================="
}

############################################################
# ETAPA 7 — SYSTEMD TOMCAT (AUTO START)
############################################################
install_tomcat_systemd() {
  require_root

  local SERVICE_FILE="/etc/systemd/system/tomcat.service"
  local TOMCAT_DIR="/u01/TasyInterfacesServer"
  local JAVA_DIR="/u01/jdk"
  local BASE_DIR="/u01"
  local LOG_DIR="/u01/logs"

  [[ -d "$TOMCAT_DIR" ]] || die "Tomcat não encontrado"
  [[ -d "$JAVA_DIR" ]]   || die "Java não encontrado"

  read -rp "Usuário do Tomcat [ENTER = root]: " TASY_USER
  TASY_USER="${TASY_USER:-root}"

  id "$TASY_USER" &>/dev/null || die "Usuário inválido"

  chown -R "$TASY_USER:$TASY_USER" "$BASE_DIR"

  find "$TOMCAT_DIR/bin" -name "*.sh" -exec chmod 755 {} \;

cat <<EOF > "$SERVICE_FILE"
# /etc/systemd/system/tomcat.service
[Unit]
Description=Apache Tomcat 9 - Tasy Interfaces
After=network.target

[Service]
Type=forking
User=root
Group=root

Environment="JAVA_HOME=/u01/jdk"
Environment="CATALINA_HOME=/u01/TasyInterfacesServer"
Environment="CATALINA_BASE=/u01/TasyInterfacesServer"
Environment="CATALINA_PID=/u01/logs/tasyinterfaces.pid"

PIDFile=/u01/logs/tasyinterfaces.pid

ExecStartPre=/bin/bash -c 'echo "Iniciando Tasy-Interfaces..."'
ExecStartPre=/bin/bash -c 'rm -f /u01/logs/tasyinterfaces.pid || true'
ExecStart=/bin/bash /u01/TasyInterfacesServer/bin/startup.sh
ExecStartPost=/bin/bash -c 'echo "Start enviado. Verifique logs: journalctl -u tomcat -f"'

# Parada "de qualquer forma": tenta PIDFile, depois fallback seguro via pgrep
ExecStop=/bin/bash -lc '
PIDFILE=/u01/logs/tasyinterfaces.pid

echo "Parando Tasy-Interfaces..."

if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)

  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "Enviando SIGTERM para PID $PID..."
    kill -TERM "$PID"

    for i in {1..20}; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done

    if kill -0 "$PID" 2>/dev/null; then
      echo "Nao parou a tempo. Forcando SIGKILL no PID $PID..."
      kill -KILL "$PID"
    fi
  else
    echo "PIDFile existe, mas PID nao esta ativo. Limpando pidfile..."
  fi

  rm -f "$PIDFILE" || true
else
  echo "PIDFile nao encontrado. Tentando localizar processo..."
  PID=$(pgrep -f "/u01/TasyInterfacesServer/.*org\.apache\.catalina\.startup\.Bootstrap" | head -n1)

  if [[ -n "$PID" ]]; then
    echo "Encontrado PID $PID. Enviando SIGTERM..."
    kill -TERM "$PID"
    sleep 5
    if kill -0 "$PID" 2>/dev/null; then
      echo "Forcando SIGKILL no PID $PID..."
      kill -KILL "$PID"
    fi
  else
    echo "Nenhum processo do Tasy-Interfaces encontrado."
  fi
fi

echo "Stop finalizado."
'

Restart=no
TimeoutStartSec=60
TimeoutStopSec=30
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

EOF

  systemctl daemon-reload
  systemctl enable tomcat
  systemctl restart tomcat
  systemctl status tomcat --no-pager
}

############################################################
# ETAPA 8 — SYSTEMD TIE (AUTO START)
############################################################
install_tie_systemd() {
  require_root

  local SERVICE_FILE="/etc/systemd/system/tie.service"
  local TIE_HOME="/opt/philips/tie"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=TIE - Tasy Integration Engine
After=docker.service network.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${TIE_HOME}
ExecStart=/bin/bash ${TIE_HOME}/start.sh
ExecStop=/bin/bash ${TIE_HOME}/stop.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tie
  systemctl restart tie
  systemctl status tie --no-pager
}


############################################################
# LIMPEZA DE ARQUIVOS TEMPORÁRIOS DE INSTALAÇÃO
############################################################
cleanup_installation_files() {
  log "Iniciando limpeza dos arquivos de instalação..."

  local files_to_remove=(
    "/u01/jdk-*.tar.gz"
    "/u01/jdk-*.rar"
    "/u01/TasyInterfacesServer.tar.gz"
    "/opt/philips/${BUNDLE_ZIP}"
  )

  for pattern in "${files_to_remove[@]}"; do
    for f in $pattern; do
      [[ -f "$f" ]] && {
        rm -f "$f"
        log "Removido: $f"
      }
    done
  done

  log "Limpeza concluída. Apenas as aplicações permanecem."
}

############################################################
# MANU PRINCIPAL
############################################################
main() {
while true; do
  echo "=================================================="
  echo "Escolha a etapa que deseja executar:"
  echo "  1 - Instalar TIE"
  echo "  2 - Instalar Tasy-Interfaces"
  echo "  3 - Configurar ILP"
  echo "  4 - Instalar Tasy-Interfaces (.war)"
  echo "  5 - Configurar Tasy-Interfaces no systemd (auto start)"
  echo "  6 - Configurar TIE no systemd (auto start)"
  echo "  0 - Sair"
  echo "=================================================="
  read -rp "Digite a opção desejada (0 a 6): " opcao

  case "$opcao" in
    1)
      install_tie
      cleanup_installation_files
      ;;
    2)
      install_tasy_interfaces
      cleanup_installation_files
      ;;
    3)
	  configuraILP
      #configure_kibana
      #valida_kibana
      ;;
    4)
      install_tasy_interfaces_version
      ;;
	5)
      install_tomcat_systemd
      ;;
	6)
      install_tie_systemd
      ;;
    0)
      echo "Saindo..."
      break
      ;;
    *)
      echo "Opção inválida! Tente novamente."
      ;;
  esac

  echo
  read -rp "Pressione ENTER para continuar..."
  clear
done
}

main "$@"