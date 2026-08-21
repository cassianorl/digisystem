#!/usr/bin/env bash

tasy_monitor_startup() {
  shellops_tasy_monitor_dependencies || return

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    shellops_error "O monitor atual grava a coleta em /root e deve ser executado como root."
    return 1
  fi

  shellops_run_legacy "analysis/monitor_tasy_startup.sh"
}

_tasy_systemd_property() {
  local unit="$1" property="$2"
  shellops_has_command systemctl && [[ -d /run/systemd/system ]] || return 127
  systemctl show --no-pager --property="$property" --value -- "$unit" 2>/dev/null
}

_tasy_service_value() {
  local unit="$1" property="$2" value
  value="$(_tasy_systemd_property "$unit" "$property" 2>/dev/null || true)"
  [[ -n "$value" && "$value" != not-found ]] || value="NÃO DETECTADO"
  printf '%s\n' "$value"
}

_tasy_appmanager_pid() {
  local main_pid proc_file cmdline pid
  main_pid="$(_tasy_systemd_property philips-app-manager.service MainPID 2>/dev/null || true)"
  if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$main_pid"; return 0; fi
  shellops_has_command tr || return 127
  for proc_file in /proc/[0-9]*/cmdline; do
    [[ -r "$proc_file" ]] || continue
    cmdline="$(tr '\0' '\n' < "$proc_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [[ "$cmdline" == *appmanager* || "$cmdline" == *app-manager* ]] || continue
    pid="${proc_file#/proc/}"; pid="${pid%/cmdline}"
    printf '%s\n' "$pid"
    return 0
  done
  return 1
}

_tasy_process_safe_tokens() {
  local pid="${1:-}" proc_file token
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  proc_file="/proc/$pid/cmdline"
  [[ -r "$proc_file" ]] || return 1
  while IFS= read -r token; do
    if [[ "$token" =~ ^-Xm[sx][0-9]+[kKmMgG]?$ || "$token" =~ ^-XX:MaxMetaspaceSize=[0-9]+[kKmMgG]?$ ]]; then
      printf '%s\n' "$token"
    elif [[ "$token" == -Dcom.sun.management.jmxremote ]]; then
      printf '%s\n' "$token"
    elif [[ "$token" =~ ^-Dcom\.sun\.management\.jmxremote\.(port|rmi\.port)=[0-9]+$ ]]; then
      printf '%s\n' "$token"
    elif [[ "$token" =~ ^-Djava\.rmi\.server\.hostname=[A-Za-z0-9_.:-]+$ ]]; then
      printf '%s\n' "$token"
    elif [[ "$token" =~ ^-Dcom\.sun\.management\.jmxremote\.(ssl|authenticate)=(true|false)$ ]]; then
      printf '%s\n' "$token"
    fi
  done < <(tr '\0' '\n' < "$proc_file")
}

_tasy_parse_safe_config() {
  local config_file="${1:-}"
  [[ -f "$config_file" && -r "$config_file" ]] || return 1
  shellops_require_command awk || return
  awk -v file="$config_file" '
    function trim(v) {sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/, "", v); return v}
    /^[[:space:]]*($|#|;)/ {next}
    {
      pos=index($0,"="); if (!pos) next
      key=trim(substr($0,1,pos-1)); value=trim(substr($0,pos+1)); upper=toupper(key)
      if (upper ~ /(PASSWORD|PASSWD|PASS|TOKEN|SECRET|PRIVATE|CREDENTIAL|AUTH|KEY)/) next
      allowed=(upper ~ /^(LOG_SIZE|LOG_PATH|HTTP_PORT|HTTPS_PORT|SERVER_PORT|MANAGEMENT_PORT|CONFIG_PATH|DATA_PATH|TEMP_PATH|JAVA_HOME|RUN_MODE|EXECUTION_MODE|ENVIRONMENT|TIE_ADDRESS|TIE_HOST|TIE_PORT|TASYREPORTS_HOST|TASYREPORTS_PORT|TASYREPORTS_REMOTE|DB_HOST|DATABASE_HOST|ORACLE_HOST|DB_PORT|DATABASE_PORT|ORACLE_PORT|DB_SERVICE|SERVICE_NAME|DB_SID|ORACLE_SID|DB_USER|DATABASE_USER|ORACLE_USER)$/)
      if (!allowed) next
      lower=tolower(value)
      if (lower ~ /(password|passwd|token|secret|private[_. -]*key|credential)/) value="<SUPRIMIDO>"
      gsub(/\|/," ",file); gsub(/\|/," ",value)
      printf "%s|%s|%s\n",file,upper,value
    }' "$config_file"
}

_tasy_safe_config_records() {
  local config_file
  local -a config_files=(
    /etc/philips/philips-app-manager.conf
    /opt/philips/etc/philips-database.conf
  )
  if [[ -d /opt/philips/etc ]] && shellops_has_command find; then
    while IFS= read -r config_file; do config_files+=("$config_file"); done \
      < <(find /opt/philips/etc -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null)
  fi
  for config_file in "${config_files[@]}"; do
    [[ -f "$config_file" && -r "$config_file" ]] || continue
    _tasy_parse_safe_config "$config_file"
  done | awk '!seen[$0]++'
}

tasy_safe_configurations() {
  local records file key value
  records="$(_tasy_safe_config_records)"
  [[ -n "$records" ]] || { printf 'Nenhuma configuração conhecida e permitida foi detectada.\n'; return 0; }
  printf 'Arquivo|Chave|Valor permitido\n'
  while IFS='|' read -r file key value; do
    printf '%s|%s|%s\n' "$file" "$key" "$value"
  done <<< "$records"
  printf '\nLOG_PATH é apenas apresentado; seu conteúdo não é lido automaticamente.\n'
  printf 'Usuários de banco são exibidos somente como identificadores; nenhuma senha é inferida.\n'
}

tasy_environment_summary() {
  local records source type name image state health pid metadata found=0
  printf 'Ambiente TASY / AppManager\n\n'
  records="$(discovery_records)"
  while IFS='|' read -r source type name image state health pid metadata; do
    case "$type" in
      appmanager|tasy_*|bifrost_*|haproxy|keepalived|tomcat|jvm|philips_path) ;;
      *) continue ;;
    esac
    found=1
    printf '%-12s %-22s %-35s state=%s health=%s\n' "$source" "$type" "$name" "${state:-N/A}" "${health:-N/A}"
  done <<< "$records"
  [[ "$found" -eq 1 ]] || printf 'Componentes TASY: NÃO DETECTADO\n'
  printf '\nAppManager unit: %s\n' "$(_tasy_service_value philips-app-manager.service LoadState)"
  if docker_access_status >/dev/null 2>&1; then printf 'Docker daemon: ACESSÍVEL\n'; else printf 'Docker daemon: NÃO ACESSÍVEL OU NÃO DETECTADO\n'; fi
  printf 'HAProxy: %s\n' "$(_tasy_service_value haproxy.service LoadState)"
  printf 'Keepalived: %s\n' "$(_tasy_service_value keepalived.service LoadState)"
  [[ -f /etc/philips/philips-app-manager.conf ]] && printf 'Config AppManager: DETECTADA\n' || printf 'Config AppManager: NÃO DETECTADO\n'
}

tasy_component_groups() {
  local source type name image state health pid metadata
  shellops_require_commands sort uniq awk || return
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == docker ]] || continue
    printf '%s\n' "$type"
  done < <(discovery_docker_container_records all) | sort | uniq -c | awk '{n=$1;$1="";sub(/^ /,"");printf "%s|%d\n",$0,n}'
}

tasy_component_instances() {
  docker_application_instances "${1:-}"
}

tasy_appmanager_status() {
  local load active enabled main_pid detected_pid rpm_version etime command config ports
  load="$(_tasy_service_value philips-app-manager.service LoadState)"
  active="$(_tasy_service_value philips-app-manager.service ActiveState)"
  enabled="$(_tasy_service_value philips-app-manager.service UnitFileState)"
  main_pid="$(_tasy_systemd_property philips-app-manager.service MainPID 2>/dev/null || true)"
  detected_pid="$(_tasy_appmanager_pid 2>/dev/null || true)"
  if shellops_has_command rpm; then rpm_version="$(rpm -q philips-app-manager 2>/dev/null || true)"; fi
  rpm_version="${rpm_version:-NÃO DETECTADO}"
  config="NÃO DETECTADO"; [[ -f /etc/philips/philips-app-manager.conf ]] && config=/etc/philips/philips-app-manager.conf
  etime="N/A"; command="N/A"; ports="NÃO DETECTADO"
  if [[ "$detected_pid" =~ ^[1-9][0-9]*$ ]] && shellops_has_command ps; then
    read -r etime command < <(ps -p "$detected_pid" -o etime=,comm= 2>/dev/null || true)
  fi
  if [[ "$detected_pid" =~ ^[1-9][0-9]*$ ]] && shellops_has_command ss && shellops_has_command awk; then
    ports="$(ss -lntp 2>/dev/null | awk -v pid="$detected_pid" 'index($0,"pid=" pid ",") && !seen[$4]++ {out=out (out?",":"") $4} END{print out}')"
    ports="${ports:-NÃO DETECTADO}"
  fi
  printf 'AppManager — componentes próprios\n'
  printf 'Unit systemd: %s\nService state: %s\nEnabled: %s\nMainPID: %s\n' "$load" "$active" "$enabled" "${main_pid:-N/A}"
  printf 'Processo Java associado: %s\nJava command: %s\nTempo de execução: %s\n' "${detected_pid:-NÃO DETECTADO}" "${command:-N/A}" "${etime:-N/A}"
  printf 'Pacote RPM: %s\nConfig: %s\nPortas detectadas: %s\n' "$rpm_version" "$config" "$ports"
  if [[ "$active" != active && -n "$detected_pid" ]]; then
    printf '\nWARNING — Diagnóstico ShellOps\nProcesso AppManager detectado fora do estado esperado do serviço.\n'
  fi
}

tasy_haproxy_status() {
  local load active enabled pid config=/etc/haproxy/haproxy.cfg
  load="$(_tasy_service_value haproxy.service LoadState)"; active="$(_tasy_service_value haproxy.service ActiveState)"
  enabled="$(_tasy_service_value haproxy.service UnitFileState)"; pid="$(_tasy_service_value haproxy.service MainPID)"
  printf 'HAProxy\nService: %s\nState: %s\nEnabled: %s\nPID: %s\n' "$load" "$active" "$enabled" "$pid"
  if [[ -f "$config" && -r "$config" ]]; then
    printf 'Config: %s\n' "$config"
    if shellops_has_command haproxy; then
      printf '\nValidação consultiva de sintaxe:\n'
      haproxy -c -f "$config" 2>&1
    else printf 'Validação: N/A (binário haproxy ausente)\n'; fi
  else printf 'Config: NÃO DETECTADO\n'; fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && shellops_has_command ss; then
    printf '\nListeners associados:\n'; ss -lntp 2>/dev/null | awk -v pid="$pid" 'index($0,"pid=" pid ",") {print}'
  fi
  if [[ "$load" != "NÃO DETECTADO" ]]; then printf '\nEventos recentes limitados:\n'; services_journal haproxy.service 50 2>&1 || true; fi
}

_tasy_parse_keepalived_config() {
  local config="${1:-}"
  [[ -f "$config" && -r "$config" ]] || return 1
  shellops_require_command awk || return
  awk '
    function braces(line, c, i) {c=0; for(i=1;i<=length(line);i++){if(substr(line,i,1)=="{")c++;else if(substr(line,i,1)=="}")c--} return c}
    {
      line=$0; sub(/#.*/,"",line)
      if (line ~ /^[[:space:]]*authentication([[:space:]]*\{)?[[:space:]]*$/) {auth=1; depth=braces(line); next}
      if (auth) {delta=braces(line); if(depth==0 && delta>0)depth=delta; else depth+=delta; if(depth<=0 && line ~ /}/)auth=0; next}
      if (line ~ /^[[:space:]]*vrrp_instance[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]*\{/) {print line; next}
      if (line ~ /^[[:space:]]*(interface|virtual_router_id|priority|advert_int)[[:space:]]+[A-Za-z0-9_.:/-]+[[:space:]]*$/) {print line; next}
      if (line ~ /^[[:space:]]*virtual_ipaddress[[:space:]]*\{/) {vip=1; next}
      if (vip && line ~ /^[[:space:]]*\}/) {vip=0; next}
      if (vip && line ~ /^[[:space:]]*[0-9a-fA-F:.]+(\/[0-9]+)?([[:space:]]+dev[[:space:]]+[A-Za-z0-9_.:-]+)?[[:space:]]*$/) print line
    }' "$config"
}

tasy_keepalived_status() {
  local load active enabled pid config=/etc/keepalived/keepalived.conf
  load="$(_tasy_service_value keepalived.service LoadState)"; active="$(_tasy_service_value keepalived.service ActiveState)"
  enabled="$(_tasy_service_value keepalived.service UnitFileState)"; pid="$(_tasy_service_value keepalived.service MainPID)"
  printf 'Keepalived\nService: %s\nState: %s\nEnabled: %s\nPID: %s\n' "$load" "$active" "$enabled" "$pid"
  [[ -f "$config" && -r "$config" ]] || {
    printf 'Config: NÃO DETECTADO\n'
    if [[ "$load" != "NÃO DETECTADO" ]]; then printf '\nEventos recentes limitados (estado observado é evidência):\n'; services_journal keepalived.service 50 2>&1 || true; fi
    return 0
  }
  printf 'Config: %s\nCampos permitidos:\n' "$config"
  _tasy_parse_keepalived_config "$config"
  if [[ "$load" != "NÃO DETECTADO" ]]; then printf '\nEventos recentes limitados (estado observado é evidência):\n'; services_journal keepalived.service 50 2>&1 || true; fi
}

tasy_datasource_summary() {
  local file key value found=0 host="" port=""
  printf 'Datasource AppManager (sem senhas)\n'
  while IFS='|' read -r file key value; do
    case "$key" in DB_HOST|DATABASE_HOST|ORACLE_HOST) host="$value" ;; DB_PORT|DATABASE_PORT|ORACLE_PORT) port="$value" ;; esac
    case "$key" in DB_*|DATABASE_*|ORACLE_*|SERVICE_NAME)
      found=1; printf '%s|%s|%s\n' "$file" "$key" "$value" ;;
    esac
  done < <(_tasy_safe_config_records)
  [[ "$found" -eq 1 ]] || printf 'Configuração datasource permitida: NÃO DETECTADO\n'
  printf '\nHost para teste: %s\nPorta para teste: %s\n' "${host:-N/A}" "${port:-N/A}"
  shellops_has_command tnsping && printf 'tnsping: DISPONÍVEL\n' || printf 'tnsping: NÃO DISPONÍVEL\n'
  shellops_has_command sqlplus && printf 'sqlplus: DISPONÍVEL\n' || printf 'sqlplus: NÃO DISPONÍVEL\n'
}

tasy_datasource_endpoint() {
  local file key value host="" port=""
  while IFS='|' read -r file key value; do
    case "$key" in DB_HOST|DATABASE_HOST|ORACLE_HOST) [[ -z "$host" ]] && host="$value" ;; DB_PORT|DATABASE_PORT|ORACLE_PORT) [[ -z "$port" ]] && port="$value" ;; esac
  done < <(_tasy_safe_config_records)
  [[ -n "$host" && "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || return 1
  printf '%s|%s\n' "$host" "$port"
}

tasy_known_log_sources() {
  local load file key value
  load="$(_tasy_systemd_property philips-app-manager.service LoadState 2>/dev/null || true)"
  [[ -n "$load" && "$load" != not-found ]] && printf 'systemd|philips-app-manager.service|Journal AppManager\n'
  load="$(_tasy_systemd_property haproxy.service LoadState 2>/dev/null || true)"
  [[ -n "$load" && "$load" != not-found ]] && printf 'systemd|haproxy.service|Journal HAProxy\n'
  load="$(_tasy_systemd_property keepalived.service LoadState 2>/dev/null || true)"
  [[ -n "$load" && "$load" != not-found ]] && printf 'systemd|keepalived.service|Journal Keepalived\n'
  while IFS='|' read -r file key value; do
    [[ "$key" == LOG_PATH && -f "$value" && -r "$value" ]] || continue
    printf 'file|%s|Log confirmado por %s\n' "$value" "$file"
  done < <(_tasy_safe_config_records)
}

tasy_journal_search() {
  local unit="${1:-}" text="${2:-}" limit="${3:-200}" service_status grep_status
  local -a pipeline_status=()
  [[ -n "$text" && "$text" != *$'\n'* && "$text" != *$'\r'* ]] || { shellops_error "Texto de busca inválido."; return 2; }
  [[ "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le 5000 ]] || { shellops_error "Limite inválido (1 a 5000)."; return 2; }
  shellops_require_commands grep awk || return
  services_journal "$unit" 2000 | grep -F -n -- "$text" | awk -v n="$limit" 'NR<=n'
  pipeline_status=("${PIPESTATUS[@]}")
  service_status=${pipeline_status[0]}; grep_status=${pipeline_status[1]}
  [[ "$service_status" -eq 0 ]] || return "$service_status"
  [[ "$grep_status" -eq 1 ]] && { printf 'Nenhuma ocorrência literal encontrada.\n'; return 0; }
  return "$grep_status"
}

tasy_journal_common_errors() (
  local unit="${1:-}" temp_file status
  shellops_require_commands mktemp cat rm || return
  temp_file="$(mktemp)" || return 1
  trap 'rm -f -- "$temp_file"' EXIT
  trap 'exit 130' HUP INT TERM
  if services_journal "$unit" 2000 > "$temp_file" 2>&1; then
    logs_common_errors "$temp_file" 40 1
    status=$?
  else
    status=$?; cat "$temp_file"
  fi
  rm -f -- "$temp_file"
  trap - EXIT HUP INT TERM
  return "$status"
)

tasy_jmx_status() {
  local pid token active=não port=N/A rmi=N/A host=N/A ssl=N/A auth=N/A
  pid="$(_tasy_appmanager_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] || { printf 'JMX ativo: não\nProcesso AppManager: NÃO DETECTADO\n'; return 0; }
  while IFS= read -r token; do
    case "$token" in
      -Dcom.sun.management.jmxremote) active=sim ;;
      -Dcom.sun.management.jmxremote.port=*) active=sim; port="${token#*=}" ;;
      -Dcom.sun.management.jmxremote.rmi.port=*) rmi="${token#*=}" ;;
      -Djava.rmi.server.hostname=*) host="${token#*=}" ;;
      -Dcom.sun.management.jmxremote.ssl=*) ssl="${token#*=}" ;;
      -Dcom.sun.management.jmxremote.authenticate=*) auth="${token#*=}" ;;
    esac
  done < <(_tasy_process_safe_tokens "$pid")
  printf 'JMX ativo: %s\nPorta: %s\nRMI port: %s\nHostname: %s\nSSL: %s\nAutenticação: %s\n' "$active" "$port" "$rmi" "$host" "$ssl" "$auth"
}

tasy_appmanager_diagnose() {
  local containers=0 unhealthy=0 source type name image state health pid metadata disk_opt=N/A file key value
  local http=N/A https=N/A config=NÃO_DETECTADO
  printf '=== AppManager: unit, processo e pacote ===\n'
  tasy_appmanager_status
  printf '\nHeap/JVM permitidos:\n'
  pid="$(_tasy_appmanager_pid 2>/dev/null || true)"; _tasy_process_safe_tokens "$pid" | awk '/^-Xm|^-XX:MaxMetaspaceSize=/' || true
  while IFS='|' read -r file key value; do
    config="$file"; [[ "$key" == HTTP_PORT || "$key" == SERVER_PORT ]] && http="$value"; [[ "$key" == HTTPS_PORT ]] && https="$value"
  done < <(_tasy_safe_config_records)
  printf 'HTTP: %s\nHTTPS: %s\nConfig permitida detectada: %s\n' "$http" "$https" "$config"
  printf '\n=== Aplicações gerenciadas: containers, imagens e componentes ===\n'
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == docker ]] || continue
    containers=$((containers+1)); [[ "$health" == unhealthy ]] && unhealthy=$((unhealthy+1))
    printf '%s|%s|%s|%s\n' "$type" "$name" "$state" "$health"
  done < <(discovery_docker_container_records all)
  printf 'Containers: %d\nUnhealthy: %d\n' "$containers" "$unhealthy"
  printf '\nHAProxy: %s\nKeepalived: %s\n' "$(_tasy_service_value haproxy.service ActiveState)" "$(_tasy_service_value keepalived.service ActiveState)"
  if [[ -d /opt/philips && -r /opt/philips ]] && shellops_has_command du; then
    if shellops_has_command timeout; then disk_opt="$(timeout 10 du -sx -B1 -- /opt/philips 2>/dev/null | awk 'NR==1{print $1}' || printf N/A)"; else disk_opt="$(du -sx -B1 -- /opt/philips 2>/dev/null | awk 'NR==1{print $1}' || printf N/A)"; fi
  fi
  printf 'Disk /opt/philips: %s bytes\n' "$disk_opt"
  printf '\nDisk Docker:\n'; docker_system_df 2>&1 || true
  printf '\nLogs conhecidos:\n'; tasy_known_log_sources
}

tasy_validate_environment() {
  local service docker_status containers unhealthy=0 source type name image state health pid metadata file key value
  local log_size=0 reports_remote=0 tie_address=0
  printf 'REFERÊNCIA DO FABRICANTE\n'
  if shellops_has_command docker; then printf '[OK] Docker disponível\n     Origem: referência técnica do produto\n'; else printf '[FAILED] Docker não disponível\n     Origem: referência técnica do produto\n'; fi
  [[ -f /etc/philips/philips-app-manager.conf ]] && printf '[OK] Configuração AppManager presente\n     Origem: referência técnica do produto\n' || printf '[WARNING] Configuração AppManager não detectada\n     Origem: referência técnica do produto\n'
  while IFS='|' read -r file key value; do
    [[ "$key" == LOG_SIZE ]] && log_size=1
    case "$key" in TASYREPORTS_HOST|TASYREPORTS_PORT|TASYREPORTS_REMOTE) reports_remote=1 ;; TIE_ADDRESS|TIE_HOST|TIE_PORT) tie_address=1 ;; esac
  done < <(_tasy_safe_config_records)
  [[ "$log_size" -eq 1 ]] && printf '[OK] LOG_SIZE detectado\n     Origem: referência técnica do produto\n' || printf '[WARNING] LOG_SIZE não detectado\n     Origem: referência técnica do produto; aplicabilidade deve ser validada.\n'
  [[ "$reports_remote" -eq 1 ]] && printf '[OK] Configuração de TasyReports remoto detectada\n     Origem: referência técnica do produto\n' || printf '[N/A] TasyReports remoto não configurado ou não aplicável\n     Origem: referência técnica do produto\n'
  [[ "$tie_address" -eq 1 ]] && printf '[OK] Endereço TIE detectado\n     Origem: referência técnica do produto\n' || printf '[N/A] Endereço TIE não detectado ou não aplicável\n     Origem: referência técnica do produto\n'
  printf '[N/A] Uso das ferramentas oficiais de instalação/gerenciamento\n      Não verificável apenas pelo estado atual do host.\n'
  printf '[N/A] Requisito de versão e coexistência Production/Homolog\n      Referência documental não disponível neste ambiente.\n'
  printf '[N/A] Sistema operacional suportado para a versão\n      Referência documental não disponível neste ambiente.\n'
  printf '\nCHECKS OPERACIONAIS SHELLOPS\n'
  service="$(_tasy_systemd_property philips-app-manager.service ActiveState 2>/dev/null || true)"
  [[ "$service" == active ]] && printf '[OK] Service AppManager ativo\n' || printf '[WARNING] Service AppManager não ativo ou não detectado\n'
  if docker_access_status >/dev/null 2>&1; then printf '[OK] Docker daemon acessível\n'; else docker_status=$?; [[ "$docker_status" -eq 127 ]] && printf '[FAILED] Docker ausente\n' || printf '[WARNING] Docker daemon inacessível\n'; fi
  containers=0
  while IFS='|' read -r source type name image state health pid metadata; do containers=$((containers+1)); [[ "$health" == unhealthy ]] && unhealthy=$((unhealthy+1)); done < <(discovery_docker_container_records all)
  [[ "$containers" -gt 0 ]] && printf '[OK] Containers detectados: %d\n' "$containers" || printf '[N/A] Containers não detectados\n'
  [[ "$unhealthy" -eq 0 ]] && printf '[OK] Containers unhealthy: 0\n' || printf '[WARNING] Containers unhealthy: %d\n' "$unhealthy"
  [[ -d /opt/philips ]] && printf '[OK] /opt/philips presente\n' || printf '[N/A] /opt/philips não detectado\n'
  printf '[%s] HAProxy: %s\n' "$([[ "$(_tasy_service_value haproxy.service LoadState)" == NÃO* ]] && printf N/A || printf OK)" "$(_tasy_service_value haproxy.service ActiveState)"
  printf '[%s] Keepalived: %s\n' "$([[ "$(_tasy_service_value keepalived.service LoadState)" == NÃO* ]] && printf N/A || printf OK)" "$(_tasy_service_value keepalived.service ActiveState)"
}

tasy_installation_dry_run() {
  local legacy checksum expected='211bfac20c98003a245396fec43a234152adf339d55c8dadcb9d40b31cea66fd'
  legacy="$(shellops_legacy_script install/install_appmanager.sh)" || return
  printf 'PREPARAR INSTALAÇÃO — DRY-RUN\nNenhuma ação será executada.\n\n'
  printf 'Análise da versão atual do legado: %s\n' "$legacy"
  if shellops_has_command sha256sum && [[ -f "$legacy" ]]; then
    read -r checksum _ < <(sha256sum "$legacy")
    [[ "$checksum" == "$expected" ]] && printf 'Inventário alinhado ao checksum analisado.\n' || printf 'WARNING: o script legado mudou; este inventário precisa ser revisado.\n'
  else printf 'Checksum: N/A; o inventário deve ser revisado quando o legado mudar.\n'; fi
  printf '%s\n' \
    '[PRECISA REVISÃO] Desabilitar SELinux.' \
    '[PRECISA REVISÃO] Parar/desabilitar firewalld e limpar iptables/ip6tables.' \
    '[PRÁTICA OPERACIONAL LEGADA] Acrescentar limits globais e do usuário philips.' \
    '[PRECISA REVISÃO] Substituir /etc/sysctl.conf e aplicar parâmetros.' \
    '[ALTERAÇÃO] Instalar pacotes de sistema, HAProxy e ferramentas.' \
    '[PRECISA REVISÃO] Remover pacotes Docker/containerd existentes e atualizar o sistema.' \
    '[ALTERAÇÃO] Criar usuário/grupo philips e preparar /u01.' \
    '[INSEGURO] Definir senha fixa philips01.' \
    '[PRECISA REVISÃO] Conceder sudo amplo ao usuário philips.' \
    '[ALTERAÇÃO] Forçar timezone America/Sao_Paulo e alterar .bashrc.' \
    '[MANUTENÇÃO] Criar cron de drop_caches e swapoff/swapon a cada três horas.' \
    '[INSEGURO] Executar curl -k de repositório remoto diretamente em bash.' \
    '[ALTERAÇÃO] Instalar philips-app-manager.' \
    '[ALTERAÇÃO] Reiniciar philips-app-manager duas vezes.'
  printf '\nNenhum item é promovido a recomendação Philips apenas por existir no legado.\n'
}
