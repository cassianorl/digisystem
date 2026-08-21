#!/usr/bin/env bash

_java_valid_pid() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

_java_target_internal_pid() {
  local metadata="${SHELLOPS_TARGET_METADATA:-}"
  if [[ "$metadata" =~ (^|[;[:space:]])java_pid=([1-9][0-9]*) ]]; then printf '%s\n' "${BASH_REMATCH[2]}"
  elif [[ "${SHELLOPS_TARGET_SOURCE:-}" == process ]]; then printf '%s\n' "${SHELLOPS_TARGET_PID:-}"
  else return 1; fi
}

_java_target_ready() {
  [[ "${SHELLOPS_TARGET_SOURCE:-}" == process || "${SHELLOPS_TARGET_SOURCE:-}" == docker ]] || {
    shellops_error 'Selecione uma JVM do host ou de container.'; return 2;
  }
  _java_valid_pid "$(_java_target_internal_pid 2>/dev/null)" || { shellops_error 'PID Java não confirmado.'; return 2; }
}

_java_container_pids() {
  local container="${1:-}"
  _docker_validate_container "$container" || return
  docker exec "$container" sh -c '
    if command -v jps >/dev/null 2>&1; then
      jps -l 2>/dev/null | awk '\''$1 ~ /^[0-9]+$/ && $2 !~ /sun.tools.jps|Jps$/ {print $1 "|" $2}'\''
    else
      for f in /proc/[0-9]*/comm; do
        [ -r "$f" ] || continue
        n=$(cat "$f" 2>/dev/null) || continue
        case "$n" in java|java.bin) p=${f#/proc/}; p=${p%/comm}; printf "%s|java\n" "$p" ;; esac
      done
    fi' 2>/dev/null
}

_java_classify_hint() {
  local hint="${1,,}"
  case "$hint" in
    *appmanager*|*app-manager*) printf 'appmanager\n' ;;
    *tasy*report*) printf 'tasy_reports\n' ;;
    *tasy*interface*) printf 'tasy_interfaces\n' ;;
    *tasy*app*server*|*tasyappserver*) printf 'tasy_appserver\n' ;;
    *tomcat*|*catalina*) printf 'tomcat\n' ;;
    *) printf 'generic_jvm\n' ;;
  esac
}

java_jvm_records() {
  local source type name image state health pid metadata internal_pid hint java_type
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == process ]] || continue
    case "$type" in jvm|tomcat|appmanager|tasy_appserver|tasy_reports|tasy_interfaces) ;; *) continue ;; esac
    [[ "$type" == jvm ]] && type="$(_java_classify_hint "$(_java_host_classification_hint "$pid")")"
    _discovery_record process "$type" "$name" "$image" "$state" "$health" "$pid" "$metadata"
  done < <(discovery_records)

  _docker_require_access >/dev/null 2>&1 || return 0
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == docker && "$state" == running ]] || continue
    while IFS='|' read -r internal_pid hint; do
      _java_valid_pid "$internal_pid" || continue
      java_type="$(_java_classify_hint "$type $name $image $hint")"
      _discovery_record docker "$java_type" "$name" "$image" "$state" "$health" "" "java_pid=$internal_pid; java_hint=${hint//;/ }; $metadata"
    done < <(_java_container_pids "$name")
  done < <(discovery_docker_container_records running)
}

_java_host_classification_hint() {
  local pid="$1" token lower
  [[ -r "/proc/$pid/cmdline" ]] || { printf 'java\n'; return 0; }
  while IFS= read -r -d '' token; do
    lower="${token,,}"; case "$lower" in *password*|*passwd*|*token*|*secret*|*credential*|*key*) continue ;; esac
    case "$lower" in *appmanager*|*app-manager*|*tasy*report*|*tasy*interface*|*tasyappserver*|*tasy*app*server*|*tomcat*|*catalina*) printf '%s\n' "$lower"; return 0 ;; esac
  done < "/proc/$pid/cmdline"
  printf 'java\n'
}

java_jvm_inventory() {
  local records source type name image state health pid metadata count=0 origin display_pid
  records="$(java_jvm_records)"
  [[ -n "$records" ]] || { printf 'Nenhuma JVM foi detectada.\n'; return 0; }
  printf 'Origem|PID|Aplicação|Alvo|Estado|Health\n'
  while IFS='|' read -r source type name image state health pid metadata; do
    count=$((count + 1)); origin=host; display_pid="$pid"
    if [[ "$source" == docker ]]; then origin=docker; display_pid=N/A; [[ "$metadata" =~ java_pid=([0-9]+) ]] && display_pid="${BASH_REMATCH[1]} (interno)"; fi
    printf '%s|%s|%s|%s|%s|%s\n' "$origin" "$display_pid" "$type" "$name" "${state:-N/A}" "${health:-N/A}"
  done <<< "$records"
  printf '\nTotal: %d\n' "$count"
}

_java_emit_allowed_token() {
  local token="${1:-}" lower="${1,,}"
  case "$lower" in *password*|*passwd*|*token*|*secret*|*credential*|*private*key*) return 0 ;; esac
  if [[ "$token" =~ ^-Xm[sx][0-9]+[kKmMgG]?$ || "$token" =~ ^-Xss[0-9]+[kKmMgG]?$ || "$token" =~ ^-XX:(MaxMetaspaceSize|MetaspaceSize)=[0-9]+[kKmMgG]?$ ]]; then
    printf '%s\n' "$token"; return 0
  fi
  case "$token" in
    -XX:+UseG1GC|-XX:+UseParallelGC|-XX:+UseConcMarkSweepGC|-XX:+HeapDumpOnOutOfMemoryError|-XX:+PrintGCDetails|-XX:+PrintGCDateStamps) printf '%s\n' "$token" ;;
    -XX:HeapDumpPath=*) [[ "${token#*=}" == /* && "${token#*=}" != *$'\n'* && "${token#*=}" != *$'\r'* ]] && printf '%s\n' "$token" ;;
    -Xlog:gc*|-Xloggc:*) printf '%s\n' "$token" ;;
    -Dcom.sun.management.jmxremote) printf '%s\n' "$token" ;;
    -Dcom.sun.management.jmxremote.port=[0-9]*|-Dcom.sun.management.jmxremote.rmi.port=[0-9]*) [[ "${token#*=}" =~ ^[0-9]+$ ]] && printf '%s\n' "$token" ;;
    -Djava.rmi.server.hostname=*) [[ "${token#*=}" =~ ^[A-Za-z0-9_.:-]+$ ]] && printf '%s\n' "$token" ;;
    -Dcom.sun.management.jmxremote.ssl=true|-Dcom.sun.management.jmxremote.ssl=false|-Dcom.sun.management.jmxremote.authenticate=true|-Dcom.sun.management.jmxremote.authenticate=false) printf '%s\n' "$token" ;;
    -Dcatalina.base=*|-Dcatalina.home=*) [[ "${token#*=}" == /* && "${token#*=}" != *$'\n'* ]] && printf '%s\n' "$token" ;;
  esac
}

_java_proc_safe_arguments() {
  local pid source token container
  pid="$(_java_target_internal_pid)" || return 1; source="${SHELLOPS_TARGET_SOURCE:-}"
  if [[ "$source" == process ]]; then
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    while IFS= read -r -d '' token; do _java_emit_allowed_token "$token"; done < "/proc/$pid/cmdline"
  else
    container="${SHELLOPS_TARGET_NAME:-}"
    while IFS= read -r token; do _java_emit_allowed_token "$token"; done < <(
      docker exec "$container" sh -c 'tr "\000" "\n" < "/proc/$1/cmdline"' shellops "$pid" 2>/dev/null
    )
  fi
}

_java_safe_arguments() {
  local primary flags token
  primary="$(_java_proc_safe_arguments 2>/dev/null || true)"
  if [[ -n "$primary" ]]; then printf '%s\n' "$primary"; return 0; fi
  flags="$(_java_run_tool jcmd VM.flags 2>/dev/null || true)"
  [[ -n "$flags" ]] || return 1
  while IFS= read -r token; do _java_emit_allowed_token "$token"; done < <(printf '%s\n' "$flags" | tr ' ' '\n')
}

_java_tool_available() {
  local tool="$1"
  if [[ "${SHELLOPS_TARGET_SOURCE:-}" == docker ]]; then docker exec "${SHELLOPS_TARGET_NAME}" sh -c 'command -v "$1" >/dev/null 2>&1' shellops "$tool" 2>/dev/null
  else shellops_has_command "$tool"; fi
}

_java_run_tool() {
  local tool="$1" pid; shift; pid="$(_java_target_internal_pid)" || return 1
  shellops_has_command timeout || return 127; _java_tool_available "$tool" || return 127
  if [[ "${SHELLOPS_TARGET_SOURCE:-}" == docker ]]; then timeout 20 docker exec "${SHELLOPS_TARGET_NAME}" "$tool" "$pid" "$@"
  else timeout 20 "$tool" "$pid" "$@"; fi
}

_java_proc_status() {
  local pid key container
  pid="$(_java_target_internal_pid)" || return 1
  if [[ "${SHELLOPS_TARGET_SOURCE:-}" == docker ]]; then
    container="${SHELLOPS_TARGET_NAME}"; docker exec "$container" sh -c 'grep -E "^(Name|VmPeak|VmSize|VmRSS|VmSwap|Threads):" "/proc/$1/status"' shellops "$pid" 2>/dev/null
  else grep -E '^(Name|VmPeak|VmSize|VmRSS|VmSwap|Threads):' "/proc/$pid/status" 2>/dev/null; fi
}

_java_version() {
  local pid exe output
  pid="$(_java_target_internal_pid)" || return 1; shellops_has_command timeout || return 127
  if [[ "${SHELLOPS_TARGET_SOURCE:-}" == docker ]]; then
    output="$(timeout 10 docker exec "${SHELLOPS_TARGET_NAME}" sh -c '"/proc/$1/exe" -version' shellops "$pid" 2>&1)" || return 1
  else
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"; [[ -x "$exe" ]] || return 1
    output="$(timeout 10 "$exe" -version 2>&1)" || return 1
  fi
  printf '%s\n' "$output" | awk 'NR<=3 && /version|Runtime Environment|VM/'
}

_java_service_for_pid() {
  local pid unit main_pid
  [[ "${SHELLOPS_TARGET_SOURCE:-}" == process ]] || return 1
  pid="$(_java_target_internal_pid)" || return 1
  shellops_has_command systemctl || return 1
  while read -r unit _; do
    [[ "$unit" =~ \.service$ ]] || continue
    main_pid="$(systemctl show --property=MainPID --value -- "$unit" 2>/dev/null)"
    [[ "$main_pid" == "$pid" ]] && { printf '%s\n' "$unit"; return 0; }
  done < <(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null)
  return 1
}

java_memory_summary() {
  local args heap_info
  _java_target_ready || return
  args="$(_java_safe_arguments 2>/dev/null || true)"
  printf '=== Configuração ===\n'
  printf '%s\n' "$args" | awk '/^-Xms|^-Xmx|^-Xss|Metaspace|Use.*GC|HeapDump/'
  [[ -n "$args" ]] || printf 'Argumentos permitidos: N/A\n'
  printf '\n=== Uso observado ===\n'; _java_proc_status || printf 'RSS/VSZ/Swap: N/A\n'
  heap_info="$(_java_run_tool jcmd GC.heap_info 2>/dev/null || true)"
  if [[ -n "$heap_info" ]]; then printf '%s\n' "$heap_info" | awk 'NR<=20 && /heap|used|committed|capacity|Metaspace|class space/'; else printf 'Heap atual/usado/livre: N/A\n'; fi
  printf '\nXmx é configuração de limite; não representa memória realmente consumida.\n'
}

java_jvm_summary() {
  local pid service args threads jmx ports logs origin
  _java_target_ready || return; pid="$(_java_target_internal_pid)"; origin=host; [[ "$SHELLOPS_TARGET_SOURCE" == docker ]] && origin=docker
  service="$(_java_service_for_pid 2>/dev/null || printf N/A)"; args="$(_java_safe_arguments 2>/dev/null || true)"
  threads="$(_java_proc_status | awk '$1=="Threads:" {print $2}')"; [[ -n "$threads" ]] || threads=N/A
  printf 'JVM\n----------------------------------------\nOrigem: %s\nPID: %s%s\nAplicação: %s\nJava: %s\n' "$origin" "$pid" "$([[ "$origin" == docker ]] && printf ' (interno)')" "${SHELLOPS_TARGET_TYPE:-generic_jvm}" "${SHELLOPS_TARGET_NAME:-N/A}"
  printf 'Versão:\n'; _java_version || printf 'N/A\n'
  printf 'Uptime: '; if [[ "$origin" == host ]]; then ps -p "$pid" -o etime= 2>/dev/null || printf 'N/A\n'; else printf 'N/A\n'; fi
  printf 'Heap inicial: %s\nHeap máximo: %s\nMetaspace: %s\nGC: %s\nThreads: %s\n' \
    "$(_java_arg_value '^-Xms')" "$(_java_arg_value '^-Xmx')" "$(_java_arg_value 'Metaspace')" "$(_java_arg_value 'Use.*GC')" "$threads"
  printf 'JMX:\n'; java_jmx_summary compact
  printf 'Portas:\n'; java_ports_summary compact
  printf 'Container: %s\nService: %s\nLogs:\n' "$([[ "$origin" == docker ]] && printf '%s' "$SHELLOPS_TARGET_NAME" || printf N/A)" "$service"
  java_known_log_sources
}

_java_arg_value() {
  local pattern="$1" value
  value="$(_java_safe_arguments 2>/dev/null | awk -v p="$pattern" '$0 ~ p {print; exit}')"
  [[ -n "$value" ]] && printf '%s\n' "$value" || printf 'N/A\n'
}

java_threads_summary() {
  local pid status source container
  _java_target_ready || return; pid="$(_java_target_internal_pid)"; source="$SHELLOPS_TARGET_SOURCE"
  printf '=== Contagem ===\n'; status="$(_java_proc_status)"; printf '%s\n' "$status" | awk '/^Threads:/{print "Threads atuais: "$2; found=1} END{if(!found) print "Threads atuais: N/A"}'
  printf 'Peak threads: N/A\nLimite de threads: N/A quando não explicitamente detectável.\n'
  printf '\n=== Estados / top CPU ===\nSnapshot consultivo; CPU elevada neste instante não identifica thread problemática nem causa de lentidão.\n'
  if [[ "$source" == process ]] && shellops_has_command ps; then
    ps -L -p "$pid" -o pid=,tid=,pcpu=,stat=,comm= --sort=-pcpu 2>/dev/null | awk 'NR<=15'
  elif [[ "$source" == docker ]]; then
    container="$SHELLOPS_TARGET_NAME"
    if docker exec "$container" sh -c 'command -v ps >/dev/null 2>&1' 2>/dev/null; then
      docker exec "$container" ps -L -p "$pid" -o pid=,tid=,pcpu=,stat=,comm= 2>/dev/null | awk 'NR<=15'
    else printf 'N/A — ferramenta de threads não disponível no container.\n'; fi
  fi
}

_java_listener_lines() {
  local pid container
  pid="$(_java_target_internal_pid)" || return 1
  if [[ "$SHELLOPS_TARGET_SOURCE" == process ]]; then
    shellops_has_command ss || return 127
    ss -lntp 2>/dev/null | awk -v p="pid=$pid," 'NR==1 || index($0,p)'
  else
    container="$SHELLOPS_TARGET_NAME"
    if docker exec "$container" sh -c 'command -v ss >/dev/null 2>&1' 2>/dev/null; then
      docker exec "$container" ss -lntp 2>/dev/null | awk -v p="pid=$pid," 'NR==1 || index($0,p)'
    else docker_container_network "$container" 2>/dev/null; fi
  fi
}

_java_port_is_listening() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  _java_listener_lines 2>/dev/null | grep -Eq "(^|[^0-9])${port}([^0-9]|$)"
}

java_ports_summary() {
  local mode="${1:-full}" lines
  _java_target_ready || return
  lines="$(_java_listener_lines 2>/dev/null || true)"
  if [[ "$mode" == compact ]]; then [[ -n "$lines" ]] && printf '%s\n' "$lines" | awk 'NR<=10' || printf 'N/A\n'; return 0; fi
  printf 'Listeners associados ao PID/container (evidência consultiva):\n'
  [[ -n "$lines" ]] && printf '%s\n' "$lines" || printf 'N/A — listener não detectado ou permissão/ferramenta indisponível.\n'
  printf '\nHTTP/HTTPS/AJP/JMX/RMI só são classificados quando configuração e porta podem ser correlacionadas. Não há scanner.\n'
}

java_jmx_summary() {
  local mode="${1:-full}" token active=N/A port=N/A rmi=N/A host=N/A ssl=N/A auth=N/A configured=0 listener=0
  _java_target_ready || return
  while IFS= read -r token; do
    case "$token" in
      -Dcom.sun.management.jmxremote) active=sim; configured=1 ;;
      -Dcom.sun.management.jmxremote.port=*) active=sim; configured=1; port="${token#*=}" ;;
      -Dcom.sun.management.jmxremote.rmi.port=*) rmi="${token#*=}" ;;
      -Djava.rmi.server.hostname=*) host="${token#*=}" ;;
      -Dcom.sun.management.jmxremote.ssl=*) ssl="${token#*=}" ;;
      -Dcom.sun.management.jmxremote.authenticate=*) auth="${token#*=}" ;;
    esac
  done < <(_java_safe_arguments)
  [[ "$port" != N/A ]] && _java_port_is_listening "$port" && listener=1
  printf 'JMX ativo: %s\nPorta: %s\nRMI port: %s\nHostname: %s\nSSL: %s\nAuthentication: %s\n' "$active" "$port" "$rmi" "$host" "$ssl" "$auth"
  if (( configured == 1 && listener == 0 )) && [[ "$port" != N/A ]]; then printf 'WARNING: configuração JMX detectada, mas listener não foi confirmado.\n'
  elif (( configured == 0 && listener == 1 )); then printf 'WARNING: listener compatível detectado, mas configuração JMX não foi confirmada.\n'
  elif (( configured == 0 )); then printf 'JMX não configurado/detectado: N/A; JMX não é obrigatório universalmente.\n'; fi
}

_java_catalina_value() {
  local key="$1" value
  value="$(_java_safe_arguments 2>/dev/null | awk -F= -v k="-D${key}" '$1==k {print substr($0,index($0,"=")+1);exit}')"
  [[ -n "$value" ]] && printf '%s\n' "$value" || return 1
}

_java_tomcat_connector_records() {
  local base="$1" file="$1/conf/server.xml" count index port protocol max_threads accept timeout max_connections ssl keystore
  [[ -f "$file" && -r "$file" ]] || return 1
  if grep -Eq '<!DOCTYPE|<!ENTITY|<Include|\$\{|<xi:include' "$file" 2>/dev/null || ! shellops_has_command xmllint; then
    printf 'N/A — configuração não interpretada com segurança\n'; return 3
  fi
  count="$(xmllint --xpath 'count(//*[local-name()="Connector"])' "$file" 2>/dev/null)" || { printf 'N/A — configuração não interpretada com segurança\n'; return 3; }
  [[ "$count" =~ ^[0-9]+$ && "$count" -le 50 ]] || { printf 'N/A — configuração não interpretada com segurança\n'; return 3; }
  for ((index=1; index<=count; index++)); do
    port="$(_java_xml_attr "$file" "$index" port)"; protocol="$(_java_xml_attr "$file" "$index" protocol)"; max_threads="$(_java_xml_attr "$file" "$index" maxThreads)"
    accept="$(_java_xml_attr "$file" "$index" acceptCount)"; timeout="$(_java_xml_attr "$file" "$index" connectionTimeout)"; max_connections="$(_java_xml_attr "$file" "$index" maxConnections)"
    ssl="$(_java_xml_attr "$file" "$index" SSLEnabled)"; keystore="$(_java_xml_attr "$file" "$index" keystoreFile)"
    case "${keystore,,}" in *password*|*passwd*|*token*|*secret*|*credential*|*keypass*) keystore='<SUPRIMIDO>' ;; esac
    [[ "$ssl" == true ]] && ssl=sim || ssl=não
    printf 'port=%s|protocol=%s|maxThreads=%s|acceptCount=%s|connectionTimeout=%s|maxConnections=%s|SSL=%s|keystore=%s\n' "$port" "$protocol" "$max_threads" "$accept" "$timeout" "$max_connections" "$ssl" "$keystore"
  done
}

_java_xml_attr() {
  local file="$1" index="$2" attribute="$3" value
  value="$(xmllint --xpath "string((//*[local-name()='Connector'])[${index}]/@${attribute})" "$file" 2>/dev/null)" || return 1
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] && printf '%s\n' "$value" || printf 'N/A\n'
}

_java_tomcat_shutdown_port() {
  local base="$1" file="$1/conf/server.xml" value
  [[ -f "$file" && -r "$file" ]] || return 1
  grep -Eq '<!DOCTYPE|<!ENTITY|<Include|\$\{|<xi:include' "$file" 2>/dev/null && return 3
  shellops_has_command xmllint || return 3
  value="$(xmllint --xpath "string(/*[local-name()='Server']/@port)" "$file" 2>/dev/null)" || return 3
  [[ "$value" =~ ^-?[0-9]+$ ]] && printf '%s\n' "$value" || return 3
}

_java_tomcat_version() {
  local home="$1" script="$1/bin/catalina.sh" output
  [[ -f "$script" && -x "$script" ]] || return 1; shellops_has_command timeout || return 127
  output="$(timeout 15 "$script" version 2>&1)" || return 1
  printf '%s\n' "$output" | awk '/^(Server version|Server number|Server built|JVM Version|JVM Vendor|OS Name|OS Version):/ {print}'
}

_java_tomcat_deployments() {
  local base="$1" webapps="$1/webapps" item found=0
  [[ -d "$webapps" && -r "$webapps" ]] || { printf 'N/A\n'; return 0; }
  while IFS= read -r -d '' item; do found=1; basename -- "$item"; done < <(find "$webapps" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -print0 2>/dev/null)
  (( found > 0 )) || printf 'N/A\n'
  printf 'Nomes são inventário; presença de WAR/diretório não comprova saúde ou estado do deployment.\n'
}

java_tomcat_summary() {
  local base home pid connectors max_threads http https ajp shutdown
  _java_target_ready || return; pid="$(_java_target_internal_pid)"
  base="$(_java_catalina_value catalina.base 2>/dev/null || true)"; home="$(_java_catalina_value catalina.home 2>/dev/null || true)"
  [[ -n "$base$home" || "${SHELLOPS_TARGET_TYPE:-}" == tomcat || "${SHELLOPS_TARGET_TYPE:-}" == tasy_interfaces ]] || { printf 'Tomcat: N/A — não confirmado para o target.\n'; return 0; }
  printf 'Tomcat\n----------------------------------------\nVersion:\n'
  if [[ "$SHELLOPS_TARGET_SOURCE" == process && -n "$home" ]]; then _java_tomcat_version "$home" || printf 'N/A\n'; else printf 'N/A\n'; fi
  printf 'CATALINA_BASE: %s\nCATALINA_HOME: %s\nPID: %s%s\n' "${base:-N/A}" "${home:-N/A}" "$pid" "$([[ "$SHELLOPS_TARGET_SOURCE" == docker ]] && printf ' (interno)')"
  printf 'Connectors:\n'
  if [[ "$SHELLOPS_TARGET_SOURCE" == process && -n "$base" ]]; then connectors="$(_java_tomcat_connector_records "$base" 2>/dev/null || true)"; [[ -n "$connectors" ]] && printf '%s\n' "$connectors" || printf 'N/A\n'; else printf 'N/A — configuração não confirmada no host.\n'; fi
  http="$(printf '%s\n' "${connectors:-}" | awk -F'[=|]' '$0 ~ /protocol=.*HTTP/ && $0 ~ /SSL=não/ {for(i=1;i<=NF;i++)if($i=="port")out=out (out?",":"") $(i+1)} END{print out}')"
  https="$(printf '%s\n' "${connectors:-}" | awk -F'[=|]' '$0 ~ /SSL=sim/ {for(i=1;i<=NF;i++)if($i=="port")out=out (out?",":"") $(i+1)} END{print out}')"
  ajp="$(printf '%s\n' "${connectors:-}" | awk -F'[=|]' 'toupper($0) ~ /PROTOCOL=.*AJP/ {for(i=1;i<=NF;i++)if($i=="port")out=out (out?",":"") $(i+1)} END{print out}')"
  shutdown=N/A; [[ "$SHELLOPS_TARGET_SOURCE" == process && -n "$base" ]] && shutdown="$(_java_tomcat_shutdown_port "$base" 2>/dev/null || printf N/A)"
  printf 'HTTP: %s\nHTTPS: %s\nAJP: %s\nShutdown: %s\n' "${http:-N/A}" "${https:-N/A}" "${ajp:-N/A}" "$shutdown"
  printf 'JMX:\n'; java_jmx_summary compact
  printf 'Heap:\n'; _java_arg_value '^-Xm[sx]'
  printf 'Threads JVM: %s\n' "$(_java_proc_status | awk '/^Threads:/{print $2;found=1} END{if(!found)print "N/A"}')"
  max_threads="$(printf '%s\n' "${connectors:-}" | awk -F'[=|]' '{for(i=1;i<=NF;i++)if($i=="maxThreads"){print $(i+1);exit}}')"
  printf 'Configured maxThreads: %s\n' "${max_threads:-N/A}"
  printf 'Logs:\n'; java_known_log_sources
  printf 'Deployments (nomes, sem leitura recursiva):\n'; if [[ "$SHELLOPS_TARGET_SOURCE" == process && -n "$base" ]]; then _java_tomcat_deployments "$base"; else printf 'N/A\n'; fi
}

_java_gc_log_path() {
  local token value
  while IFS= read -r token; do
    case "$token" in
      -Xloggc:*) value="${token#-Xloggc:}" ;;
      -Xlog:gc*:file=*) value="${token#*file=}"; value="${value%%:*}" ;;
      *) continue ;;
    esac
    [[ "$value" == /* && "$value" != *'%'* ]] && { printf '%s\n' "$value"; return 0; }
  done < <(_java_safe_arguments)
  return 1
}

java_known_log_sources() {
  local service base gc_path item found=0
  _java_target_ready || return
  if [[ "$SHELLOPS_TARGET_SOURCE" == docker ]]; then printf 'docker|%s|%s\n' "$SHELLOPS_TARGET_NAME" "${SHELLOPS_TARGET_TYPE:-JVM}"; return 0; fi
  service="$(_java_service_for_pid 2>/dev/null || true)"
  if [[ -n "$service" ]]; then found=1; printf 'systemd|%s|Journal da JVM\n' "$service"; fi
  gc_path="$(_java_gc_log_path 2>/dev/null || true)"
  if [[ -n "$gc_path" && -f "$gc_path" && -r "$gc_path" ]]; then found=1; printf 'file|%s|GC log confirmado por argumento permitido\n' "$gc_path"; fi
  base="$(_java_catalina_value catalina.base 2>/dev/null || true)"
  if [[ -n "$base" && -d "$base/logs" ]]; then
    while IFS= read -r -d '' item; do found=1; printf 'file|%s|Log Tomcat confirmado\n' "$item"; done < <(find "$base/logs" -mindepth 1 -maxdepth 1 -type f \( -name 'catalina.out' -o -name '*.log' \) -print0 2>/dev/null)
  fi
  (( found > 0 )) || printf 'Nenhuma fonte de log segura foi confirmada.\n'
}

java_log_tail() {
  local source="$1" value="$2" lines="${3:-200}"
  case "$source" in file) logs_tail "$value" "$lines" ;; docker) docker_show_logs "$value" "$lines" ;; systemd) services_journal "$value" "$lines" ;; *) shellops_error 'Fonte de log inválida.'; return 2 ;; esac
}

java_log_search() (
  local source="$1" value="$2" text="$3" limit="${4:-200}" temp status
  [[ "$source" == file ]] && { logs_search_text "$value" "$text" "$limit"; return; }
  shellops_require_commands mktemp rm || return; temp="$(mktemp)" || return 1
  trap 'rm -f -- "$temp"' EXIT
  trap 'exit 130' HUP INT TERM
  if [[ "$source" == docker ]]; then docker_show_logs "$value" 5000 > "$temp" 2>&1
  elif [[ "$source" == systemd ]]; then services_journal "$value" 5000 > "$temp" 2>&1
  else rm -f -- "$temp"; shellops_error 'Fonte inválida.'; return 2; fi
  logs_search_text "$temp" "$text" "$limit"; status=$?; return "$status"
)

java_log_errors() (
  local source="$1" value="$2" temp status
  [[ "$source" == file ]] && { logs_common_errors "$value" 40 1; return; }
  temp="$(mktemp)" || return 1
  trap 'rm -f -- "$temp"' EXIT
  trap 'exit 130' HUP INT TERM
  if [[ "$source" == docker ]]; then docker_show_logs "$value" 5000 > "$temp" 2>&1
  elif [[ "$source" == systemd ]]; then services_journal "$value" 5000 > "$temp" 2>&1
  else rm -f -- "$temp"; shellops_error 'Fonte inválida.'; return 2; fi
  logs_common_errors "$temp" 40 1; status=$?; return "$status"
)

java_log_period() {
  local source="$1" value="$2" since="$3" until="${4:-}"
  case "$source" in file) logs_search_period "$value" "$since" "$until" ;; docker) docker_show_logs_since "$value" 5000 "$since" ;; systemd) services_journal_period "$since" "$until" "$value" ;; *) shellops_error 'Fonte inválida.'; return 2 ;; esac
}

_java_evidence_scan() {
  local regex="$1" source value description content
  while IFS='|' read -r source value description; do
    case "$source" in
      file) grep -Ein -- "$regex" "$value" 2>/dev/null | tail -n 30 | sed "s|^|Fonte: arquivo:$value |" ;;
      docker) docker_show_logs "$value" 3000 2>/dev/null | grep -Ein -- "$regex" | tail -n 30 | sed "s|^|Fonte: docker:$value |" ;;
      systemd) services_journal "$value" 3000 2>/dev/null | grep -Ein -- "$regex" | tail -n 30 | sed "s|^|Fonte: journal:$value |" ;;
    esac
  done < <(java_known_log_sources)
}

java_gc_oom_summary() {
  local args gc_path jvm native system
  _java_target_ready || return; args="$(_java_safe_arguments 2>/dev/null || true)"
  printf '=== Configuração GC / Heap dump em OOM ===\n'; printf '%s\n' "$args" | awk '/Use.*GC|^-Xlog:gc|^-Xloggc:|HeapDump/'
  gc_path="$(_java_gc_log_path 2>/dev/null || true)"
  if [[ -n "$gc_path" && "$SHELLOPS_TARGET_SOURCE" == process && -f "$gc_path" ]]; then
    printf 'GC log: %s\n' "$gc_path"; stat -c 'Tamanho: %s bytes' -- "$gc_path" 2>/dev/null || true; stat -c 'Última modificação: %y' -- "$gc_path" 2>/dev/null || true
    printf 'Full GC (evidências, máximo 20):\n'; grep -Fin -- 'Full GC' "$gc_path" 2>/dev/null | tail -n 20 || printf 'Nenhuma ocorrência textual.\n'
  else printf 'GC log confirmado/acessível: N/A\n'; fi
  printf '\n=== JVM OutOfMemoryError ===\n'
  jvm="$(_java_evidence_scan 'OutOfMemoryError|Java heap space|GC overhead limit exceeded|Metaspace' 2>/dev/null || true)"; [[ -n "$jvm" ]] && printf '%s\n' "$jvm" || printf 'Nenhuma evidência encontrada nas fontes confirmadas.\n'
  printf '\n=== Native/thread/resource exhaustion ===\n'
  native="$(_java_evidence_scan 'unable to create new native thread' 2>/dev/null || true)"; [[ -n "$native" ]] && printf '%s\n' "$native" || printf 'Nenhuma evidência encontrada nas fontes confirmadas.\n'
  printf 'Essa categoria não é classificada automaticamente como Java heap OOM.\n'
  printf '\n=== Linux/container OOMKilled ===\n'
  if [[ "$SHELLOPS_TARGET_SOURCE" == docker ]]; then
    docker inspect --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}' "$SHELLOPS_TARGET_NAME" 2>/dev/null || printf 'N/A\n'
  else
    system="$(services_kernel_messages '24 hours ago' 500 2>/dev/null | grep -Ei 'Killed process|oom-kill|Out of memory' | tail -n 30 || true)"; [[ -n "$system" ]] && printf '%s\n' "$system" || printf 'Nenhuma evidência encontrada no kernel consultável.\n'
  fi
  printf '\nAs três categorias são evidências distintas e não são tratadas como equivalentes.\n'
}

_java_capture_thread_dump() {
  if _java_tool_available jcmd; then _java_run_tool jcmd Thread.print
  elif _java_tool_available jstack; then _java_run_tool jstack
  else
    if [[ "$SHELLOPS_TARGET_SOURCE" == docker ]]; then printf 'N/A — jcmd/jstack não disponíveis no container. Não será usado JDK do host, nsenter, cópia ou instalação.\n' >&2
    else printf 'N/A — jcmd/jstack não disponíveis. kill -3 envia sinal à JVM e não é executado automaticamente nesta etapa.\n' >&2; fi
    return 127
  fi
}

java_thread_dump() {
  local mode="${1:-view}" destination="${2:-}" pid timestamp output_file status
  _java_target_ready || return; pid="$(_java_target_internal_pid)"
  case "$mode" in
    view)
      printf 'THREAD DUMP — CONSULTA / VISUALIZAÇÃO TEMPORÁRIA\nPode conter SQL, URLs, usuários, dados de aplicação, dados clínicos, tokens e outros dados sensíveis presentes nas stacks.\nNão será incluído automaticamente no Support Bundle.\n\n'
      _java_capture_thread_dump
      ;;
    save)
      [[ -d "$destination" && -w "$destination" ]] || { shellops_error 'Destino inexistente ou não gravável.'; return 2; }
      timestamp="$(date '+%Y%m%d_%H%M%S')"; output_file="${destination%/}/shellops-thread-dump-${pid}-${timestamp}.txt"
      printf 'THREAD DUMP — ALTERAÇÃO LOCAL / ARTEFATO GERADO\nO arquivo pode conter SQL, URLs, nomes de usuários, dados de aplicação, dados clínicos, tokens e outros dados sensíveis presentes nas stacks.\nNão será incluído automaticamente no Support Bundle.\n'
      (umask 077; : > "$output_file") || return 1
      if _java_capture_thread_dump > "$output_file" 2>&1; then status=0; else status=$?; rm -f -- "$output_file"; return "$status"; fi
      chmod 600 -- "$output_file" 2>/dev/null || true
      printf 'Arquivo salvo com permissão restritiva quando suportada: %s\n' "$output_file"
      ;;
    *) shellops_error 'Modo de thread dump inválido.'; return 2 ;;
  esac
}

java_thread_dump_analyze() {
  local file="${1:-}" total runnable waiting timed blocked deadlocks jdbc socket t4c pools
  [[ -f "$file" && -r "$file" ]] || { shellops_error 'Arquivo de thread dump inválido.'; return 2; }
  total="$(grep -Ec '^".*"' "$file" 2>/dev/null || true)"
  runnable="$(grep -Ec 'java.lang.Thread.State: RUNNABLE' "$file" 2>/dev/null || true)"
  waiting="$(grep -Ec 'java.lang.Thread.State: WAITING' "$file" 2>/dev/null || true)"
  timed="$(grep -Ec 'java.lang.Thread.State: TIMED_WAITING' "$file" 2>/dev/null || true)"
  blocked="$(grep -Ec 'java.lang.Thread.State: BLOCKED' "$file" 2>/dev/null || true)"
  deadlocks="$(grep -Eic 'deadlock|Found one Java-level deadlock' "$file" 2>/dev/null || true)"
  jdbc="$(grep -Eic 'oracle\.jdbc|T4CConnection' "$file" 2>/dev/null || true)"; socket="$(grep -Eic 'SocketInputStream' "$file" 2>/dev/null || true)"; t4c="$(grep -Eic 'T4CMAREngine' "$file" 2>/dev/null || true)"; pools="$(grep -Eic 'ThreadPool|Executor|ForkJoinPool|pool-' "$file" 2>/dev/null || true)"
  printf 'Total de threads: %s\nRUNNABLE: %s\nWAITING: %s\nTIMED_WAITING: %s\nBLOCKED: %s\nDeadlock explicitamente reportado: %s\nOracle JDBC: %s\nSocketInputStream: %s\nT4CMAREngine: %s\nPools/filas visíveis: %s\n' "$total" "$runnable" "$waiting" "$timed" "$blocked" "$deadlocks" "$jdbc" "$socket" "$t4c" "$pools"
  printf '\nOcorrências são evidências. Oracle JDBC ou CPU elevada não determinam causa de banco ou lentidão.\n'
}

_java_size_bytes() {
  local value="${1:-}" number unit
  [[ "$value" =~ ^-Xm[xs]([0-9]+)([kKmMgG]?)$ ]] || return 1
  number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2],,}"
  case "$unit" in k) printf '%s\n' "$((number*1024))" ;; m) printf '%s\n' "$((number*1024*1024))" ;; g) printf '%s\n' "$((number*1024*1024*1024))" ;; '') printf '%s\n' "$number" ;; esac
}

_java_observed_heap_bytes() {
  local output value number unit
  output="$(_java_run_tool jcmd GC.heap_info 2>/dev/null)" || return 1
  value="$(printf '%s\n' "$output" | grep -Eio 'used[[:space:]]+[0-9]+[KMG]' | head -n1 | awk '{print $2}')"
  [[ "$value" =~ ^([0-9]+)([KMG])$ ]] || return 1; number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  case "$unit" in K) printf '%s\n' "$((number*1024))" ;; M) printf '%s\n' "$((number*1024*1024))" ;; G) printf '%s\n' "$((number*1024*1024*1024))" ;; esac
}

java_heap_dump_prepare() {
  local destination="${1:-}" pid xmx xmx_bytes rss_kb rss_bytes observed_bytes free_bytes fs_type tool=N/A compatible=0 result=WARNING required=0 candidate
  _java_target_ready || return; pid="$(_java_target_internal_pid)"
  [[ -n "$destination" && "$destination" == /* && "$destination" != *$'\n'* ]] || { shellops_error 'Informe um path absoluto de destino.'; return 2; }
  if [[ "$SHELLOPS_TARGET_SOURCE" == docker ]]; then
    docker exec "$SHELLOPS_TARGET_NAME" sh -c '[ -d "$1" ] && [ -w "$1" ]' shellops "$destination" 2>/dev/null || { printf 'Resultado: NOT AVAILABLE\nDestino não existe ou não é gravável no container.\n'; return 0; }
    free_bytes="$(docker exec "$SHELLOPS_TARGET_NAME" df -PB1 "$destination" 2>/dev/null | awk 'NR==2{print $4}')"; fs_type="$(docker exec "$SHELLOPS_TARGET_NAME" df -PT "$destination" 2>/dev/null | awk 'NR==2{print $2}')"
  else
    [[ -d "$destination" && -w "$destination" ]] || { printf 'Resultado: NOT AVAILABLE\nDestino não existe ou não é gravável.\n'; return 0; }
    free_bytes="$(df -PB1 -- "$destination" 2>/dev/null | awk 'NR==2{print $4}')"; fs_type="$(df -PT -- "$destination" 2>/dev/null | awk 'NR==2{print $2}')"
  fi
  if _java_tool_available jcmd; then tool=jcmd; _java_run_tool jcmd VM.version >/dev/null 2>&1 && compatible=1
  elif _java_tool_available jmap; then tool='jmap (compatibilidade não confirmada)'; fi
  xmx="$(_java_safe_arguments 2>/dev/null | awk '/^-Xmx/{print;exit}')"; xmx_bytes="$(_java_size_bytes "$xmx" 2>/dev/null || true)"
  rss_kb="$(_java_proc_status | awk '/^VmRSS:/{print $2}')"; [[ "$rss_kb" =~ ^[0-9]+$ ]] && rss_bytes=$((rss_kb*1024)) || rss_bytes=""
  observed_bytes="$(_java_observed_heap_bytes 2>/dev/null || true)"
  for candidate in "$xmx_bytes" "$rss_bytes" "$observed_bytes"; do [[ "$candidate" =~ ^[0-9]+$ && "$candidate" -gt "$required" ]] && required="$candidate"; done
  (( required > 0 )) && required=$((required*2))
  if [[ "$tool" == N/A ]]; then result='NOT AVAILABLE'
  elif [[ "$compatible" -eq 1 && "$xmx_bytes" =~ ^[0-9]+$ && "$observed_bytes" =~ ^[0-9]+$ && "$free_bytes" =~ ^[0-9]+$ && "$required" -gt 0 && "$free_bytes" -ge "$required" && "$fs_type" != tmpfs && "$fs_type" != overlay ]]; then result=READY
  else result=WARNING; fi
  printf 'HEAP DUMP [PREPARAR] — nenhum dump será executado\nPID: %s%s\nXmx: %s\nHeap observado: %s bytes\nRSS: %s kB\nFilesystem: %s\nEspaço livre: %s bytes\nFerramenta na origem: %s\nCompatibilidade consultiva: %s\nMargem conservadora requerida: %s bytes\nResultado: %s\n' "$pid" "$([[ "$SHELLOPS_TARGET_SOURCE" == docker ]] && printf ' (interno)')" "${xmx:-N/A}" "${observed_bytes:-N/A}" "${rss_kb:-N/A}" "${fs_type:-N/A}" "${free_bytes:-N/A}" "$tool" "$([[ "$compatible" -eq 1 ]] && printf confirmada || printf incerta)" "${required:-N/A}" "$result"
  printf 'Mesmo READY não elimina risco: heap dump pode ser grande, causar pausa/impacto, exigir espaço adicional e conter dados sensíveis ou clínicos. Incerteza resulta em WARNING.\n'
}

java_validate_environment() {
  local records pid args base tool
  records="$(java_jvm_records)"
  printf 'JAVA / TOMCAT\n----------------------------------------\nCHECKS OPERACIONAIS SHELLOPS\n'
  [[ -n "$records" ]] && printf '[OK] Java detectado\n' || { printf '[N/A] Java não detectado\n'; return 0; }
  if _java_target_ready 2>/dev/null; then printf '[OK] Target JVM selecionado e PID acessível\n'; else printf '[WARNING] Selecione uma JVM para checks detalhados\n'; return 0; fi
  _java_version >/dev/null 2>&1 && printf '[OK] Versão Java consultável\n' || printf '[N/A] Versão Java não consultável\n'
  args="$(_java_safe_arguments 2>/dev/null || true)"; [[ "$args" == *-Xmx* ]] && printf '[OK] Heap configurado detectado\n' || printf '[N/A] Xmx não detectado\n'
  [[ "$args" == *Use*GC* ]] && printf '[OK] GC identificado\n' || printf '[N/A] GC não identificado explicitamente\n'
  _java_proc_status | grep -q '^Threads:' && printf '[OK] Threads consultáveis\n' || printf '[WARNING] Threads não consultáveis\n'
  [[ "$args" == *jmxremote* ]] && printf '[OK] Configuração JMX detectada\n' || printf '[N/A] JMX não detectado; não é requisito universal\n'
  base="$(_java_catalina_value catalina.base 2>/dev/null || true)"; [[ -n "$base" ]] && printf '[OK] Tomcat detectado\n' || printf '[N/A] Tomcat não detectado\n'
  [[ -n "$base" && -r "$base/conf/server.xml" ]] && printf '[OK] server.xml confirmado para análise allowlist\n' || printf '[N/A] Connectors não confirmados\n'
  java_known_log_sources | grep -qE '^(file|docker|systemd)\|' && printf '[OK] Fonte de log confirmada\n' || printf '[N/A] Fonte de log não confirmada\n'
  if _java_tool_available jcmd; then tool=jcmd; elif _java_tool_available jstack; then tool=jstack; else tool=N/A; fi
  [[ "$tool" != N/A ]] && printf '[OK] Ferramenta de diagnóstico disponível: %s\n' "$tool" || printf '[N/A] jcmd/jstack indisponíveis na origem da JVM\n'
  printf '[N/A] Filesystem para dump deve ser escolhido e avaliado em Heap Dump [PREPARAR]\n'
}
