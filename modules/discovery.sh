#!/usr/bin/env bash

SHELLOPS_TARGET_SOURCE=""
SHELLOPS_TARGET_TYPE=""
SHELLOPS_TARGET_NAME=""
SHELLOPS_TARGET_IMAGE=""
SHELLOPS_TARGET_STATE=""
SHELLOPS_TARGET_HEALTH=""
SHELLOPS_TARGET_PID=""
SHELLOPS_TARGET_METADATA=""

_discovery_clean_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//|/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

discovery_classify_component() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    *tasy*report*) printf 'tasy_reports\n' ;;
    *tasy*emr*) printf 'tasy_emr\n' ;;
    *tasy*schedul*) printf 'tasy_scheduler\n' ;;
    *tasy*connector*) printf 'tasy_connector\n' ;;
    *tasy*interface*) printf 'tasy_interfaces\n' ;;
    *tasy*app*server*|*tasyappserver*) printf 'tasy_appserver\n' ;;
    *appmanager*|*app-manager*) printf 'appmanager\n' ;;
    *bifrost*backend*) printf 'bifrost_backend\n' ;;
    *bifrost*frontend*) printf 'bifrost_frontend\n' ;;
    *bifrost*) printf 'bifrost_server\n' ;;
    *rabbitmq*) printf 'rabbitmq\n' ;;
    *mongodb*|*mongo:*) printf 'mongodb\n' ;;
    *elasticsearch*) printf 'elasticsearch\n' ;;
    *kibana*) printf 'kibana\n' ;;
    *logstash*) printf 'logstash\n' ;;
    *keycloak*) printf 'keycloak\n' ;;
    *tie*manager*|*manager*tie*) printf 'tie_manager\n' ;;
    *tie*primary*|*primary*tie*) printf 'tie_primary\n' ;;
    *tie*secondary*|*secondary*tie*) printf 'tie_secondary\n' ;;
    *tie.service*|*/opt/philips/tie*|*/opt/tie*) printf 'tie_service\n' ;;
    *haproxy*) printf 'haproxy\n' ;;
    *keepalived*) printf 'keepalived\n' ;;
    *tomcat*|*catalina*) printf 'tomcat\n' ;;
    *java*) printf 'jvm\n' ;;
    *) printf 'generic\n' ;;
  esac
}

_discovery_record() {
  local source="$1" type="$2" name="$3" image="$4"
  local state="$5" health="$6" pid="$7" metadata="$8"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$(_discovery_clean_field "$source")" \
    "$(_discovery_clean_field "$type")" \
    "$(_discovery_clean_field "$name")" \
    "$(_discovery_clean_field "$image")" \
    "$(_discovery_clean_field "$state")" \
    "$(_discovery_clean_field "$health")" \
    "$(_discovery_clean_field "$pid")" \
    "$(_discovery_clean_field "$metadata")"
}

discovery_docker_container_records() {
  local scope="${1:-all}" ids_output id details
  local name image state health ports mounts compose_service compose_project type metadata
  local -a ids=()

  _docker_require_access >/dev/null 2>&1 || return 0
  if [[ "$scope" == running ]]; then
    ids_output="$(docker ps -q 2>/dev/null)" || return 0
  else
    ids_output="$(docker ps -aq 2>/dev/null)" || return 0
  fi
  [[ -n "$ids_output" ]] || return 0
  mapfile -t ids <<< "$ids_output"

  for id in "${ids[@]}"; do
    details="$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{json .NetworkSettings.Ports}}|{{range .Mounts}}{{.Destination}};{{end}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null)" || continue
    IFS='|' read -r name image state health ports mounts compose_service compose_project <<< "$details"
    name="${name#/}"
    type="$(discovery_classify_component "$name $image $compose_service")"
    [[ "$type" != generic ]] || type="generic_container"
    metadata="ports=${ports:-none}; mounts=${mounts:-none}"
    [[ -n "$compose_service" ]] && metadata+="; compose_service=$compose_service"
    [[ -n "$compose_project" ]] && metadata+="; compose_project=$compose_project"
    _discovery_record docker "$type" "$name" "$image" "$state" "$health" "" "$metadata"
  done
}

discovery_docker_image_records() {
  local repository tag image_id type
  _docker_require_access >/dev/null 2>&1 || return 0

  while IFS=$'\t' read -r repository tag image_id; do
    [[ -n "$image_id" ]] || continue
    type="$(discovery_classify_component "$repository:$tag")"
    [[ "$type" != generic ]] || type="generic_image"
    _discovery_record docker_image "$type" "$repository:$tag" "$repository:$tag" available none "" "id=$image_id"
  done < <(docker images --no-trunc --format '{{.Repository}}	{{.Tag}}	{{.ID}}' 2>/dev/null)
}

discovery_process_records() {
  local pid command arguments type name proc_file comm
  local -A seen=()

  if shellops_has_command ps; then
    while read -r pid command arguments; do
      [[ -n "$pid" && -n "$command" ]] || continue
      type=""; name="$command"
      case "$(printf '%s %s' "$command" "$arguments" | tr '[:upper:]' '[:lower:]')" in
        *tasy*connector*) type=tasy_connector; name="Tasy Connector ($command)" ;;
        *tasy*interface*) type=tasy_interfaces; name="Tasy Interfaces ($command)" ;;
        *bifrost*backend*) type=bifrost_backend; name="Bifrost Backend ($command)" ;;
        *bifrost*frontend*) type=bifrost_frontend; name="Bifrost Frontend ($command)" ;;
        *bifrost*) type=bifrost_server; name="Bifrost Server ($command)" ;;
        *tomcat*|*catalina*) type=tomcat; name="Tomcat ($command)" ;;
        *appmanager*|*app-manager*) type=appmanager; name="AppManager ($command)" ;;
        *java*) type=jvm; name="JVM ($command)" ;;
      esac
      [[ -n "$type" ]] || continue; seen["$pid"]=1
      _discovery_record process "$type" "$name" "" running none "$pid" "command=$command"
    done < <(ps -eo pid=,comm=,args= 2>/dev/null)
  fi

  for proc_file in /proc/[0-9]*/comm; do
    [[ -r "$proc_file" ]] || continue; pid="${proc_file#/proc/}"; pid="${pid%/comm}"
    [[ -z "${seen[$pid]:-}" ]] || continue; IFS= read -r comm < "$proc_file"
    case "$comm" in java|java.bin) _discovery_record process jvm "JVM ($comm)" "" running none "$pid" "command=$comm" ;; esac
  done
}

discovery_systemd_records() {
  local unit state type
  shellops_has_command systemctl || return 0

  while read -r unit _; do
    [[ "$unit" =~ ^[A-Za-z0-9_.@:-]+\.service$ ]] || continue
    case "${unit,,}" in
      *philips*|*tasy*|*tie*|*app-manager*|*appmanager*|docker.service|haproxy.service|keepalived.service|chronyd.service|tomcat*.service|rabbitmq*.service|mongod*.service|elasticsearch.service|kibana.service|logstash.service|keycloak.service) ;;
      *) continue ;;
    esac
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    type="$(discovery_classify_component "$unit")"
    [[ "$type" != generic ]] || type="generic_service"
    _discovery_record systemd "$type" "$unit" "" "${state:-unknown}" none "" "unit=$unit"
  done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null)
}

discovery_path_records() {
  local path type
  local -a paths=(
    /opt/philips
    /opt/philips/volumes
    /opt/philips/tie
    /opt/philips/tie/apps
    /opt/philips/tie/configs
    /opt/philips/tie/volumes
    /opt/tie
    /opt/tie/apps
    /opt/tie/configs
    /opt/tie/volumes
  )

  for path in "${paths[@]}"; do
    [[ -e "$path" ]] || continue
    type="$(discovery_classify_component "$path")"
    [[ "$type" != generic ]] || type="philips_path"
    _discovery_record path "$type" "$path" "" present none "" "path=$path"
  done
}

discovery_records() {
  discovery_docker_container_records all
  discovery_docker_image_records
  discovery_process_records
  discovery_systemd_records
  discovery_path_records
}

discovery_environment_summary() {
  local records count source type name image state health pid metadata
  records="$(discovery_records)"

  printf 'ShellOps - Descoberta de ambiente (CONSULTA)\n'
  printf 'Hostname: %s\n' "$(hostname 2>/dev/null || printf desconhecido)"
  printf 'Timestamp: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf indisponivel)"
  if [[ -z "$records" ]]; then
    printf 'Nenhum alvo conhecido foi detectado. Itens ausentes não são tratados como erro.\n'
    return 0
  fi

  count=0
  while IFS='|' read -r source type name image state health pid metadata; do
    count=$((count + 1))
    printf '[%d] source=%s type=%s name=%s' "$count" "$source" "$type" "$name"
    [[ -n "$image" ]] && printf ' image=%s' "$image"
    [[ -n "$state" ]] && printf ' state=%s' "$state"
    [[ -n "$health" && "$health" != none ]] && printf ' health=%s' "$health"
    [[ -n "$pid" ]] && printf ' pid=%s' "$pid"
    [[ -n "$metadata" ]] && printf ' metadata={%s}' "$metadata"
    printf '\n'
  done <<< "$records"
  printf '\nTotal de alvos: %d\n' "$count"
}

discovery_target_clear() {
  SHELLOPS_TARGET_SOURCE=""
  SHELLOPS_TARGET_TYPE=""
  SHELLOPS_TARGET_NAME=""
  SHELLOPS_TARGET_IMAGE=""
  SHELLOPS_TARGET_STATE=""
  SHELLOPS_TARGET_HEALTH=""
  SHELLOPS_TARGET_PID=""
  SHELLOPS_TARGET_METADATA=""
}

discovery_target_set() {
  discovery_target_clear
  SHELLOPS_TARGET_SOURCE="${1:-}"
  SHELLOPS_TARGET_TYPE="${2:-}"
  SHELLOPS_TARGET_NAME="${3:-}"
  SHELLOPS_TARGET_IMAGE="${4:-}"
  SHELLOPS_TARGET_STATE="${5:-}"
  SHELLOPS_TARGET_HEALTH="${6:-}"
  SHELLOPS_TARGET_PID="${7:-}"
  SHELLOPS_TARGET_METADATA="${8:-}"
}

discovery_target_describe() {
  [[ -n "$SHELLOPS_TARGET_SOURCE" ]] || {
    printf 'Nenhum alvo selecionado.\n'
    return 1
  }
  printf 'Alvo selecionado\n'
  printf 'source: %s\ntype: %s\nname: %s\n' \
    "$SHELLOPS_TARGET_SOURCE" "$SHELLOPS_TARGET_TYPE" "$SHELLOPS_TARGET_NAME"
  [[ -n "$SHELLOPS_TARGET_IMAGE" ]] && printf 'image: %s\n' "$SHELLOPS_TARGET_IMAGE"
  [[ -n "$SHELLOPS_TARGET_STATE" ]] && printf 'state: %s\n' "$SHELLOPS_TARGET_STATE"
  [[ -n "$SHELLOPS_TARGET_HEALTH" ]] && printf 'health: %s\n' "$SHELLOPS_TARGET_HEALTH"
  [[ -n "$SHELLOPS_TARGET_PID" ]] && printf 'pid: %s\n' "$SHELLOPS_TARGET_PID"
  [[ -n "$SHELLOPS_TARGET_METADATA" ]] && printf 'metadata: %s\n' "$SHELLOPS_TARGET_METADATA"
  return 0
}

discovery_diagnose_target() {
  discovery_target_describe || return 1
  printf '\nDiagnóstico roteado — CONSULTA:\n'
  case "$SHELLOPS_TARGET_TYPE" in
    appmanager)
      tasy_appmanager_diagnose
      return
      ;;
    tie_*|bifrost_*|rabbitmq|mongodb|elasticsearch|kibana|logstash|keycloak|tasy_interfaces|tasy_connector)
      tie_status_summary
      return
      ;;
    tasy_appserver|tasy_reports|tasy_emr|tasy_scheduler|haproxy|keepalived)
      tasy_environment_summary
      return
      ;;
    jvm|tomcat)
      java_jvm_summary
      return
      ;;
    oracle*)
      oracle_client_summary
      return
      ;;
  esac
  case "$SHELLOPS_TARGET_SOURCE" in
    docker)
      docker_diagnose_container "$SHELLOPS_TARGET_NAME" "$SHELLOPS_TARGET_TYPE"
      ;;
    process)
      if shellops_has_command ps; then
        ps -p "$SHELLOPS_TARGET_PID" -o pid=,ppid=,user=,stat=,etime=,comm=
      fi
      ;;
    systemd)
      services_status "$SHELLOPS_TARGET_NAME"
      ;;
    docker_image)
      printf 'Tipo: %s\nOrigem: docker_image\nEstado: %s\nMetadados disponíveis: %s\nDiagnóstico especializado: N/A\n' \
        "$SHELLOPS_TARGET_TYPE" "${SHELLOPS_TARGET_STATE:-N/A}" "${SHELLOPS_TARGET_METADATA:-N/A}"
      ;;
    path)
      printf 'Tipo: %s\nOrigem: path\nEstado: %s\nMetadados disponíveis: %s\nDiagnóstico especializado: N/A\n' \
        "$SHELLOPS_TARGET_TYPE" "${SHELLOPS_TARGET_STATE:-N/A}" "${SHELLOPS_TARGET_METADATA:-N/A}"
      ;;
    *)
      printf 'Não há diagnóstico genérico aplicável ao tipo selecionado.\n'
      ;;
  esac
}
