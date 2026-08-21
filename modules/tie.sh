#!/usr/bin/env bash

_tie_is_type() {
  case "${1:-}" in bifrost_*|tasy_interfaces|tasy_connector|rabbitmq|mongodb|elasticsearch|kibana|logstash|keycloak|tie_*) return 0 ;; *) return 1 ;; esac
}

_tie_valid_line() {
  [[ -n "${1:-}" && "$1" != -* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || { shellops_error "${2:-Valor} inválido."; return 2; }
}

tie_environment_records() {
  local source type name image state health pid metadata joined
  while IFS='|' read -r source type name image state health pid metadata; do
    joined="${name,,} ${image,,} ${metadata,,}"
    if _tie_is_type "$type" || [[ "$joined" == *bifrost* || "$joined" == *"compose_project=tie"* ]]; then
      printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$source" "$type" "$name" "$image" "$state" "$health" "$pid" "$metadata"
    fi
  done < <(discovery_records)
}

_tie_topology() {
  local records="${1:-}" line lower roles="" count=0 role
  while IFS= read -r line; do
    lower="${line,,}"
    case "$lower" in *tie_manager*|*compose_service=manager*) roles+=" manager" ;; esac
    case "$lower" in *tie_primary*|*compose_service=primary*) roles+=" primary" ;; esac
    case "$lower" in *tie_secondary*|*compose_service=secondary*) roles+=" secondary" ;; esac
  done <<< "$records"
  for role in manager primary secondary; do [[ " $roles " == *" $role "* ]] && count=$((count + 1)); done
  if (( count >= 2 )); then printf 'Topologia: papéis explícitos detectados:%s\n' "$roles"; else printf 'Topologia: indeterminada\n'; fi
  printf 'Múltiplos containers, IPs ou portas não são evidência suficiente de HA.\n'
}

tie_environment_summary() {
  local records source type name image state health pid metadata count=0
  records="$(tie_environment_records)"
  printf 'ShellOps - Ambiente TIE / Integrações (CONSULTA)\nHostname: %s\nTimestamp: %s\n\n' "$(hostname 2>/dev/null || printf desconhecido)" "$(date '+%Y-%m-%d %H:%M:%S %z')"
  if [[ -z "$records" ]]; then printf 'Nenhum componente TIE foi confirmado neste host.\n'; _tie_topology ""; return 0; fi
  while IFS='|' read -r source type name image state health pid metadata; do
    count=$((count + 1)); printf '[%d] Fonte=%s Componente=%s Nome=%s Estado=%s Health=%s\n' "$count" "$source" "$type" "$name" "${state:-N/A}" "${health:-N/A}"
  done <<< "$records"
  printf '\nTotal: %d\n' "$count"; _tie_topology "$records"
}

tie_component_inventory() {
  local records
  records="$(tie_environment_records)"
  [[ -n "$records" ]] || { printf 'Nenhum componente TIE confirmado.\n'; return 0; }
  printf 'Fonte|Tipo|Nome|Imagem|Estado|Health\n'
  awk -F '|' '{print $1"|"$2"|"$3"|"$4"|"$5"|"$6}' <<< "$records"
  printf '\nClassificação heurística; componentes desconhecidos associados por evidência não são ocultados.\n'
}

tie_status_summary() {
  local records path source type name image state health rest problems=0 found=0
  records="$(tie_environment_records)"
  printf '=== Path ===\n'
  for path in /opt/philips/tie /opt/tie; do
    [[ -e "$path" ]] || continue; found=1; printf '%s: presente (path conhecido do legado)\n' "$path"
    shellops_has_command df && df -P -- "$path" 2>/dev/null | awk 'NR<=2'
  done
  (( found > 0 )) || printf 'Nenhum path conhecido do legado foi confirmado.\n'
  printf '\n=== Topologia ===\n'; _tie_topology "$records"
  printf '\n=== Docker / Compose ===\n'; docker_access_status 2>&1 || true
  printf '\n=== Componentes ===\n'; tie_component_inventory
  while IFS='|' read -r source type name image state health rest; do [[ "$source" == docker && ( "$state" != running || "$health" == unhealthy ) ]] && problems=$((problems + 1)); done <<< "$records"
  printf '\nContainers parados/unhealthy: %d\n\n=== Disco Docker ===\n' "$problems"; docker_system_df 2>&1 || true
  printf '\n=== Logs confirmados ===\n'; tie_known_log_sources
}

tie_connectivity_summary() {
  local host="${1:-}" port="${2:-}"
  printf '=== Portas detectadas ===\n'
  if shellops_has_command ss; then ss -lnt 2>/dev/null | awk 'NR==1 || $4 ~ /:(5044|5601|5672|8080|8282|8383|90[0-5][0-9]|9090|9091|9200|9300|9600|15672|27017)$/'; else printf 'N/A: ss indisponível.\n'; fi
  printf '\n=== Portas contextuais conhecidas ===\n5044 5601 5672 8080 8282 8383 9000-9050 9090 9091 9200 9300 9600 15672 27017\n'
  printf 'Uma porta só é esperada quando o componente correspondente foi confirmado.\n\n=== Teste solicitado ===\n'
  if [[ -n "$host$port" ]]; then _tie_valid_line "$host" Destino || return; network_tcp_test "$host" "$port"; else printf 'Nenhum teste ativo. Ranges não são varridos automaticamente.\n'; fi
}

_tie_safe_jvm_tokens() {
  local pid="${1:-}" token
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 0
  while IFS= read -r -d '' token; do case "$token" in -Dphilips.bifrost.events.url=*|-Dphilips.bifrost.tasy.url=*|-Xms*|-Xmx*|-XX:MaxMetaspaceSize=*) printf '%s\n' "$token" ;; esac; done < "/proc/$pid/cmdline"
}

tie_tasy_interfaces_status() {
  local source type name image state health pid metadata found=0
  printf 'Tasy Interfaces - diagnóstico consultivo\n'
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$type" == tasy_interfaces ]] || continue; found=1
    printf '\nFonte=%s Nome=%s Estado=%s Health=%s\n' "$source" "$name" "${state:-N/A}" "${health:-N/A}"
    [[ "$source" == docker ]] && docker_diagnose_container "$name" "$type" 2>&1 || true
    if [[ "$source" == process ]]; then printf 'Tokens JVM permitidos:\n'; _tie_safe_jvm_tokens "$pid"; fi
  done < <(discovery_records)
  if [[ -d /u01/TasyInterfacesServer ]]; then
    found=1; printf '\n/u01/TasyInterfacesServer: presente (path conhecido do legado; não é requisito universal)\n'
    [[ -f /u01/TasyInterfacesServer/webapps/tasy-interfaces.war ]] && printf 'WAR conhecido do legado: presente\n' || printf 'WAR conhecido do legado: N/A/ausente\n'
  fi
  if shellops_has_command systemctl && systemctl list-unit-files tomcat.service --no-legend 2>/dev/null | grep -q '^tomcat\.service'; then found=1; printf '\ntomcat.service: elemento conhecido do legado detectado\n'; services_status tomcat.service 2>&1 || true; fi
  (( found > 0 )) || printf 'Nenhuma evidência de Tasy Interfaces foi confirmada.\n'
}

tie_tasy_interfaces_health() {
  local host="${1:-}" port="${2:-}" url code
  _tie_valid_line "$host" Host || return
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || { shellops_error 'Porta inválida.'; return 2; }
  shellops_require_command curl || return; url="http://${host}:${port}/tasy-interfaces/resources/healthcheck"
  code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 5 --max-time 10 --get "$url")" || return
  printf 'Endpoint confirmado pelo operador: %s\nHTTP status: %s\n' "$url" "$code"
  [[ "$code" =~ ^2 ]] && printf 'HTTP 2xx = sucesso técnico de transporte. Isso não comprova sucesso funcional da integração.\n' || printf 'A resposta não comprova disponibilidade funcional.\n'
}

_tie_container_for_type() {
  local wanted="$1" source type name image state rest
  while IFS='|' read -r source type name image state rest; do [[ "$source" == docker && "$type" == "$wanted" && "$state" == running ]] || continue; printf '%s\n' "$name"; return 0; done < <(tie_environment_records)
  return 1
}

tie_rabbitmq_status() {
  local container output
  container="$(_tie_container_for_type rabbitmq 2>/dev/null)" || { printf 'RabbitMQ: N/A (container em execução não confirmado).\n'; return 0; }
  printf 'RabbitMQ container: %s\n' "$container"; docker_diagnose_container "$container" rabbitmq 2>&1 || true
  output="$(docker exec "$container" rabbitmq-diagnostics -q status 2>&1)" || {
    printf 'N/A: consulta indisponível ou exige autenticação não disponível de forma segura.\nCredenciais não são procuradas em Config.Env, arquivos arbitrários, volumes, command line ou secrets.\n'; return 0; }
  printf '%s\n' "$output" | awk 'NR<=120'
  docker exec "$container" rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers memory 2>/dev/null | awk 'NR<=200' || printf 'Filas: N/A (acesso seguro indisponível).\n'
  docker exec "$container" rabbitmqctl list_channels number messages_unacknowledged 2>/dev/null | awk 'NR<=200' || printf 'Canais: N/A (acesso seguro indisponível).\n'
  docker exec "$container" rabbitmqctl list_connections name channels 2>/dev/null | awk 'NR<=200' || printf 'Conexões: N/A (acesso seguro indisponível).\n'
}

_tie_mongo_eval() {
  local container="$1" javascript="$2"
  if docker exec "$container" sh -c 'command -v mongosh >/dev/null 2>&1'; then docker exec "$container" mongosh --quiet --eval "$javascript"
  elif docker exec "$container" sh -c 'command -v mongo >/dev/null 2>&1'; then docker exec "$container" mongo --quiet --eval "$javascript"
  else return 127; fi
}

tie_mongodb_status() {
  local container script output
  container="$(_tie_container_for_type mongodb 2>/dev/null)" || { printf 'MongoDB: N/A (container em execução não confirmado).\n'; return 0; }
  printf 'MongoDB container: %s\n' "$container"; docker_diagnose_container "$container" mongodb 2>&1 || true
  script='var n=db.adminCommand({listDatabases:1,nameOnly:true}).databases.map(function(x){return x.name});if(n.indexOf("BifrostDB")<0){print("BifrostDB: N/A");quit(0)};var d=db.getSiblingDB("BifrostDB");print("BifrostDB: confirmado");printjson(d.stats(1048576));["messages","deadletters","deadlettersHistory"].forEach(function(n){if(d.getCollectionNames().indexOf(n)<0){print(n+"|N/A");return};var c=d.getCollection(n),s=c.stats(1048576);print(n+"|count="+c.countDocuments({})+"|sizeMiB="+s.size+"|storageMiB="+s.storageSize)});'
  output="$(_tie_mongo_eval "$container" "$script" 2>&1)" || { printf 'N/A: cliente, permissão ou autenticação segura indisponível. Nenhuma credencial foi procurada.\n'; return 0; }
  printf '%s\n' "$output" | awk 'NR<=200'
}

tie_mongodb_retention_analysis() {
  local hours="${1:-48}" container cutoff script output
  [[ "$hours" =~ ^[1-9][0-9]*$ && "$hours" -le 8760 ]] || { shellops_error 'Retenção inválida.'; return 2; }
  container="$(_tie_container_for_type mongodb 2>/dev/null)" || { printf 'MongoDB: N/A (container em execução não confirmado).\n'; return 0; }
  cutoff="$(date -u -d "-$hours hours" '+%Y-%m-%dT%H:%M:%SZ')" || return
  printf 'ANÁLISE DE RETENÇÃO - ESTRITAMENTE CONSULTA\nCritério legado do script de manutenção existente; não é recomendação oficial Philips/Tasy.\nCorte UTC: %s\n' "$cutoff"
  script="var n=db.adminCommand({listDatabases:1,nameOnly:true}).databases.map(function(x){return x.name});if(n.indexOf(\"BifrostDB\")<0){print(\"BifrostDB: N/A\");quit(0)};var d=db.getSiblingDB(\"BifrostDB\"),cut=ISODate(\"$cutoff\");[\"messages\",\"deadletters\",\"deadlettersHistory\"].forEach(function(n){if(d.getCollectionNames().indexOf(n)<0){print(n+\"|N/A\");return};var c=d.getCollection(n);print(n+\"|total=\"+c.countDocuments({})+\"|anteriores=\"+c.countDocuments({executionDateTime:{\$lt:cut}})+\"|sem_data=\"+c.countDocuments({\$or:[{executionDateTime:{\$exists:false}},{executionDateTime:null}]}))});"
  output="$(_tie_mongo_eval "$container" "$script" 2>&1)" || { printf 'N/A: consulta ou autenticação segura indisponível.\n'; return 0; }
  printf '%s\nNenhum createIndex, delete, compact, drop ou repair foi executado.\n' "$output" | awk 'NR<=110'
}

tie_elastic_stack_status() {
  local type container host_ip host_port container_port url code
  for type in elasticsearch kibana logstash keycloak; do
    container="$(_tie_container_for_type "$type" 2>/dev/null || true)"
    if [[ -z "$container" ]]; then printf '\n%s: N/A (container em execução não confirmado).\n' "$type"; continue; fi
    printf '\n=== %s ===\n' "$type"; docker_diagnose_container "$container" "$type" 2>&1 || true
    docker_container_network "$container" 2>&1 || true
    [[ "$type" == elasticsearch || "$type" == kibana ]] || continue
    while IFS='|' read -r host_ip host_port container_port; do
      case "$type:$container_port" in elasticsearch:9200/tcp|kibana:5601/tcp) ;; *) continue ;; esac
      case "$host_ip" in ''|0.0.0.0|'::') host_ip=127.0.0.1 ;; esac
      url="http://${host_ip}:${host_port}"; [[ "$type" == kibana ]] && url+="/api/status"
      if shellops_has_command curl; then
        code="$(curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 3 --max-time 6 --get "$url" 2>/dev/null || printf N/A)"
        printf '%s -> HTTP %s (transporte técnico; não valida função da integração)\n' "$url" "$code"
      fi
    done < <(docker_published_port_records "$container" 2>/dev/null)
  done
  printf 'Nenhum índice, documento, configuração ou credencial foi consultado/modificado.\n'
}

tie_known_log_sources() {
  local source type name image state health rest found=0
  while IFS='|' read -r source type name image state health rest; do
    [[ "$source" == docker ]] || continue; found=1; printf 'docker|%s|%s\n' "$name" "$type"
  done < <(tie_environment_records)
  if [[ -f /u01/TasyInterfacesServer/logs/catalina.out && -r /u01/TasyInterfacesServer/logs/catalina.out ]]; then found=1; printf 'file|/u01/TasyInterfacesServer/logs/catalina.out|tasy-interfaces (path conhecido do legado)\n'; fi
  (( found > 0 )) || printf 'Nenhuma fonte de log segura foi confirmada.\n'
}

_tie_matches_all() {
  local line="$1" value; shift
  for value in "$@"; do [[ -z "$value" || "$line" == *"$value"* ]] || return 1; done
}

tie_event_search() (
  local event_name="${1:-}" integration_id="${2:-}" patient_id="${3:-}" message_id="${4:-}" since="${5:-}" limit="${6:-200}"
  local source value component raw line timestamp labels count=0 temp_file all_timestamps=1 sortable=1 criterion
  local -a criteria=("$event_name" "$integration_id" "$patient_id" "$message_id")
  [[ -n "$event_name$integration_id$patient_id$message_id" ]] || { shellops_error 'Informe ao menos um critério literal.'; return 2; }
  [[ "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le 2000 ]] || { shellops_error 'Limite inválido (1 a 2000).'; return 2; }
  for criterion in "${criteria[@]}"; do [[ "$criterion" != *$'\n'* && "$criterion" != *$'\r'* ]] || { shellops_error 'Critérios devem ocupar uma linha.'; return 2; }; done
  shellops_require_commands mktemp rm awk tail sort || return; temp_file="$(mktemp)" || return 1
  trap 'rm -f -- "$temp_file"' EXIT
  trap 'exit 130' HUP INT TERM
  while IFS='|' read -r source value component; do
    [[ "$source" == docker || "$source" == file ]] || continue
    if [[ "$source" == docker ]]; then
      if [[ -n "$since" ]]; then raw="$(docker_show_logs_since "$value" 5000 "$since" 2>&1 || true)"; else raw="$(docker_show_logs "$value" 5000 2>&1 || true)"; fi
      source="docker:$value"
    else raw="$(tail -n 5000 -- "$value" 2>/dev/null || true)"; source="arquivo:$value"; fi
    while IFS= read -r line; do
      _tie_matches_all "$line" "${criteria[@]}" || continue
      timestamp=N/A
      if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?) ]]; then
        timestamp="${BASH_REMATCH[1]}"
        [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || sortable=0
      else all_timestamps=0; sortable=0; fi
      labels=""; [[ -n "$event_name" ]] && labels+="eventName "; [[ -n "$integration_id" ]] && labels+="integrationId "; [[ -n "$patient_id" ]] && labels+="patientId "; [[ -n "$message_id" ]] && labels+="messageId "
      line="${line//$'\t'/ }"; line="${line//$'\r'/ }"; line="${line:0:1000}"
      printf '%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$source" "$component" "${labels% }" "$line" >> "$temp_file"
      count=$((count + 1)); (( count >= limit )) && break 2
    done <<< "$raw"
  done < <(tie_known_log_sources)
  if (( count == 0 )); then printf 'Nenhuma evidência literal encontrada nas fontes confirmadas.\n'; return 0; fi
  if (( sortable == 1 )); then
    LC_ALL=C sort -t $'\t' -k1,1 "$temp_file" -o "$temp_file"
  elif (( all_timestamps == 0 )); then
    printf 'Timestamp não interpretável em parte das fontes; ordem original preservada e timestamp N/A informado.\n\n'
  else
    printf 'Formatos/fusos não são seguramente comparáveis; ordem original preservada.\n\n'
  fi
  while IFS=$'\t' read -r timestamp source component labels line; do
    printf 'Timestamp: %s\nFonte: %s\nComponente: %s\nCritério encontrado: %s\nMensagem resumida: %s\n\n' "$timestamp" "$source" "$component" "$labels" "$line"
  done < "$temp_file"
  printf 'Resultados são evidências literais; nenhum diagnóstico automático foi produzido.\nBIFROST_LAYER_LOG/SQL não são consultados nesta etapa.\n'
)

tie_validate_environment() {
  local records source type name image state health rest problems=0
  records="$(tie_environment_records)"
  printf 'REFERÊNCIA TÉCNICA DO PRODUTO\n'
  [[ -n "$records" ]] && printf '[OK] Conjunto TIE detectado por evidência do host\n' || printf '[N/A] Conjunto TIE não confirmado neste host\n'
  printf '[N/A] Requisito de versão\n      Referência documental não disponível neste ambiente.\n'
  printf '[N/A] Componentes opcionais\n      Aplicabilidade depende da arquitetura e versão documentadas.\n'
  printf '\nCHECKS OPERACIONAIS SHELLOPS\n'
  shellops_has_command docker && printf '[OK] Comando Docker disponível\n' || printf '[N/A] Comando Docker indisponível\n'
  docker_access_status >/dev/null 2>&1 && printf '[OK] Daemon Docker acessível\n' || printf '[N/A] Daemon Docker não acessível\n'
  while IFS='|' read -r source type name image state health rest; do [[ "$source" == docker && ( "$state" != running || "$health" == unhealthy ) ]] && problems=$((problems + 1)); done <<< "$records"
  (( problems == 0 )) && printf '[OK] Nenhum container TIE confirmado está parado/unhealthy\n' || printf '[ATENÇÃO] Containers parados/unhealthy: %d\n' "$problems"
  [[ -d /opt/philips/tie || -d /opt/tie ]] && printf '[OK] Path TIE conhecido detectado\n' || printf '[N/A] Path TIE conhecido não detectado\n'
  _tie_topology "$records"
}

tie_installation_dry_run() {
  printf 'PREPARAR INSTALAÇÃO [DRY-RUN]\nAnálise da versão atual do legado: install/install_tie.sh\nO script não foi executado, sourced ou alterado. Revisar este inventário quando o legado mudar.\n\n'
  printf 'PRÁTICA OPERACIONAL LEGADA\n'; printf '%s\n' '- Prepara /opt/philips/tie e /u01/TasyInterfacesServer; baixa/extrai bundle, JDK, servidor e WAR.' '- Configura Bifrost Frontend e Tasy Interfaces; cria tie.service e tomcat.service.' '- Aciona install.sh, start.sh e stop.sh.'
  printf '\nREFERÊNCIA TÉCNICA CONHECIDA (não equivale a recomendação oficial)\n'; printf '%s\n' '- Relaciona Bifrost, Tasy Interfaces, RabbitMQ, MongoDB, Elasticsearch, Kibana e Keycloak.' '- Observa philips.bifrost.events.url e philips.bifrost.tasy.url.'
  printf '\nPRECISA REVISÃO\n'; printf '%s\n' '- Versões fixas de bundle, Docker e JDK; FTP; paths/portas; localhost; root no Tomcat.' '- Wrapper docker-compose, idempotência, rollback, ILM/index patterns e retenção fixos.' '- /u01/TasyInterfacesServer, WAR e tomcat.service são elementos conhecidos do legado, não requisitos universais.'
  printf '\nPRECISA REVISÃO / ALTO IMPACTO DE SEGURANÇA\n'; printf '%s\n' '- Desabilita SELinux.' '- Para/desabilita firewalld.' '- Executa flush de iptables e ip6tables.'
  printf '\nALTERAÇÃO\n'; printf '%s\n' '- Instala/remove pacotes; altera limits.conf, sysctl.conf, context.xml, setenv.sh e config.js.' '- Cria diretórios, links, units, permissões, ownership, templates, ILM e configurações Kibana.'
  printf '\nMANUTENÇÃO\n'; printf '%s\n' '- Remove JDKs/temporários, inicia/reinicia serviços e altera estado de ILM/índices.'
  printf '\nRISCOS DE SEGURANÇA\n'; printf '%s\n' '- Credencial FTP embutida; senha na linha de comando; senha interpolada via sed.' '- curl | bash e downloads remotos sem validação adequada.' '- rm -rf em paths críticos; SIGKILL como fallback.' '- Operações Elasticsearch que alteram documentos, índices, settings, templates e ILM.'
  printf '\nREFERÊNCIA DO clean_mongodb.sh\n'; printf '%s\n' '- BifrostDB; messages, deadletters e deadlettersHistory; retenção legada de 48h; batch 5000.' '- createIndex é somente documentado e não foi transportado.' '- delete, compact e remoção de logs são MANUTENÇÃO e não são executados.'
}
