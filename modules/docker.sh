#!/usr/bin/env bash

docker_access_status() {
  local output status
  if ! shellops_has_command docker; then
    printf 'Docker: UNAVAILABLE (comando docker não encontrado).\n' >&2
    return 127
  fi
  output="$(docker info --format '{{.ServerVersion}}' 2>&1)"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'Docker daemon: ACCESSIBLE (versão %s).\n' "${output:-desconhecida}"
    return 0
  fi
  printf 'Docker daemon: NOT ACCESSIBLE. Verifique se o daemon está ativo e se o usuário possui permissão.\n' >&2
  return "$status"
}

_docker_require_access() {
  docker_access_status >/dev/null
}

_docker_health_inventory() {
  local ids_output
  local -a container_ids=()
  _docker_require_access || return
  if ! ids_output="$(docker ps -aq 2>&1)"; then
    printf '%s\n' "$ids_output" >&2
    return 13
  fi
  [[ -n "$ids_output" ]] || return 0
  mapfile -t container_ids <<< "$ids_output"
  docker inspect --format \
    '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Name}}' \
    "${container_ids[@]}"
}

docker_list_containers() {
  _docker_require_access || return
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_list_running_containers() {
  _docker_require_access || return
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_list_all_containers() {
  docker_list_containers
}

docker_list_images() {
  _docker_require_access || return
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'
}

docker_list_detected_applications() {
  local source type name image state health pid metadata
  local found=0
  _docker_require_access || return
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == docker || "$source" == docker_image ]] || continue
    [[ "$type" != generic_container && "$type" != generic_image ]] || continue
    found=1
    printf 'type=%s name=%s' "$type" "$name"
    [[ -n "$image" ]] && printf ' image=%s' "$image"
    [[ -n "$state" ]] && printf ' state=%s' "$state"
    printf '\n'
  done < <(discovery_records)
  [[ "$found" -eq 1 ]] || printf 'Nenhuma aplicação conhecida detectada. Containers e imagens genéricos continuam disponíveis.\n'
}

docker_show_stats() {
  _docker_require_access || return
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}'
}

docker_show_logs() {
  local container="${1:-}"
  local lines="${2:-200}"

  _docker_require_access || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  shellops_is_non_negative_integer "$lines" || { shellops_error "A quantidade de linhas deve ser um inteiro."; return 2; }

  docker logs --timestamps --tail "$lines" "$container"
}

docker_show_logs_since() {
  local container="${1:-}" lines="${2:-200}" since="${3:-}"

  _docker_require_access || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  shellops_is_non_negative_integer "$lines" || { shellops_error "A quantidade de linhas deve ser um inteiro."; return 2; }
  [[ -n "$since" && "$since" != -* && "$since" != *$'\n'* && "$since" != *$'\r'* ]] || {
    shellops_error "Informe um período válido para --since."
    return 2
  }

  docker logs --timestamps --tail "$lines" --since "$since" "$container"
}

docker_system_df() {
  _docker_require_access || return
  docker system df
}

docker_health_inventory() {
  _docker_health_inventory
}

docker_inspect_container() {
  local container="${1:-}"

  _docker_require_access || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  docker inspect "$container"
}

docker_inspect_safe() {
  local container="${1:-}"

  _docker_require_access || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  docker inspect --format $'Name={{.Name}}\nImage={{.Config.Image}}\nID={{.Id}}\nCreated={{.Created}}\nState={{.State.Status}}\nRunning={{.State.Running}}\nStartedAt={{.State.StartedAt}}\nFinishedAt={{.State.FinishedAt}}\nRestartCount={{.RestartCount}}\nExitCode={{.State.ExitCode}}\nOOMKilled={{.State.OOMKilled}}\nError={{.State.Error}}\nPID={{.State.Pid}}\nHealth={{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}\nPorts={{json .NetworkSettings.Ports}}\nNetworks={{range $name, $network := .NetworkSettings.Networks}}{{$name}};{{end}}\nMounts={{range .Mounts}}{{.Type}}:{{.Source}} -> {{.Destination}} (RW={{.RW}}){{"\\n"}}{{end}}\nComposeProject={{index .Config.Labels "com.docker.compose.project"}}\nComposeService={{index .Config.Labels "com.docker.compose.service"}}' "$container"
}

docker_show_health() {
  local container="${1:-}"

  _docker_require_access || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }

  docker inspect --format \
    'Status={{.State.Status}} Running={{.State.Running}} RestartCount={{.RestartCount}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$container"
}

_docker_validate_container() {
  local container="${1:-}"
  [[ -n "$container" && "$container" != -* && "$container" != *$'\n'* && "$container" != *$'\r'* ]] || {
    shellops_error "Container inválido."
    return 2
  }
}

docker_diagnose_container() {
  local container="${1:-}" component_type="${2:-generic_container}" details stats
  _docker_require_access || return
  _docker_validate_container "$container" || return
  details="$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}|{{.Created}}|{{.State.StartedAt}}|{{.State.FinishedAt}}|{{.RestartCount}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{if .State.Error}}{{.State.Error}}{{else}}N/A{{end}}|{{.State.Pid}}|{{json .NetworkSettings.Ports}}|{{range $name, $network := .NetworkSettings.Networks}}{{$name}};{{end}}|{{range .Mounts}}{{.Type}}:{{.Destination}};{{end}}' "$container" 2>/dev/null)" || {
    shellops_error "Container não encontrado ou não acessível: $container"
    return 1
  }
  stats="$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' "$container" 2>/dev/null || true)"
  awk -F '|' -v type="$component_type" -v stats="$stats" '
    function value(v) { return (v == "" || v == "<no value>" || v ~ /^0001-01-01/) ? "N/A" : v }
    {
      split(stats, s, "|")
      sub(/^\//, "", $1)
      print "Container: " value($1); print "Image: " value($2); print "Type: " value(type)
      print "State: " value($3); print "Health: " value($4); print "Created: " value($5)
      print "Started: " value($6); print "Finished: " value($7); print "Restart count: " value($8)
      print "Exit code: " value($9); print "OOMKilled: " value($10); print "Error: " value($11)
      print "PID: " value($12); print "CPU: " value(s[1]); print "Memory: " value(s[2]) " (" value(s[3]) ")"
      print "Ports: " value($13); print "Networks: " value($14); print "Mounts: " value($15)
    }' <<< "$details"
}

_docker_stats_record() {
  local container="$1"
  LC_ALL=C docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' "$container"
}

docker_stats_sample() {
  local container="${1:-}" interval="${2:-1}" samples="${3:-5}" index record
  _docker_require_access || return
  shellops_require_commands date sleep || return
  _docker_validate_container "$container" || return
  [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 60 ]] || { shellops_error "Intervalo inválido (1 a 60)."; return 2; }
  [[ "$samples" =~ ^[1-9][0-9]*$ && "$samples" -le 60 ]] || { shellops_error "Amostras inválidas (1 a 60)."; return 2; }
  printf 'Timestamp|CPU %%|Memory usage|Memory %%|Network I/O|Block I/O|PIDs\n'
  for ((index=1; index<=samples; index++)); do
    record="$(_docker_stats_record "$container")" || return
    printf '%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$record"
    (( index < samples )) && sleep "$interval"
  done
  return 0
}

docker_stats_summary() (
  local container="${1:-}" interval="${2:-1}" samples="${3:-5}" temp_file status
  shellops_require_commands mktemp awk cat rm || return
  temp_file="$(mktemp)" || return 1
  trap 'rm -f -- "$temp_file"' EXIT
  trap 'exit 130' HUP INT TERM
  if docker_stats_sample "$container" "$interval" "$samples" > "$temp_file"; then status=0; else status=$?; fi
  cat "$temp_file"
  if [[ "$status" -eq 0 ]]; then
    printf '\nResumo (somente percentuais instantâneos):\n'
    awk -F '|' 'NR > 1 {
      cpu=$2; mem=$4; gsub(/%/, "", cpu); gsub(/%/, "", mem)
      if (cpu ~ /^[0-9]+([.][0-9]+)?$/ && mem ~ /^[0-9]+([.][0-9]+)?$/) {
        count++; cpu_sum+=cpu; mem_sum+=mem; if (count==1 || cpu>cpu_max) cpu_max=cpu; if (count==1 || mem>mem_max) mem_max=mem
      }
    } END {if (count) printf "CPU média: %.2f%%\nCPU máxima: %.2f%%\nMemory média: %.2f%%\nMemory máxima: %.2f%%\n", cpu_sum/count,cpu_max,mem_sum/count,mem_max; else print "Métricas percentuais indisponíveis."}' "$temp_file"
    printf 'Network I/O e Block I/O são exibidos por amostra; não são agregados por serem contadores cumulativos.\n'
  fi
  return "$status"
)

docker_container_mounts() {
  local container="${1:-}"
  _docker_require_access || return
  _docker_validate_container "$container" || return
  printf 'Type|Source|Destination|Mode\n'
  docker inspect --format '{{range .Mounts}}{{.Type}}|{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}|{{.Destination}}|{{if .RW}}RW{{else}}RO{{end}}{{"\n"}}{{end}}' "$container"
}

docker_volume_metadata() {
  local volume="${1:-}"
  _docker_require_access || return
  [[ -n "$volume" && "$volume" != -* && "$volume" != *$'\n'* ]] || { shellops_error "Volume inválido."; return 2; }
  docker volume inspect --format $'Name={{.Name}}\nDriver={{.Driver}}\nScope={{.Scope}}\nMountpoint={{.Mountpoint}}\nCreatedAt={{.CreatedAt}}' "$volume"
}

docker_container_network() {
  local container="${1:-}"
  _docker_require_access || return
  _docker_validate_container "$container" || return
  printf 'Portas publicadas:\n'
  docker port "$container" 2>/dev/null || printf 'Nenhuma porta publicada.\n'
  printf '\nNetworks:\nName|IP interno|Gateway|Aliases\n'
  docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}|{{$network.IPAddress}}|{{$network.Gateway}}|{{json $network.Aliases}}{{"\n"}}{{end}}' "$container"
}

docker_published_port_records() {
  local container="${1:-}"
  _docker_require_access || return
  _docker_validate_container "$container" || return
  docker inspect --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostIp}}|{{.HostPort}}|{{$port}}{{"\n"}}{{end}}{{end}}' "$container"
}

docker_healthcheck_details() {
  local container="${1:-}" has_health
  _docker_require_access || return
  shellops_require_command tail || return
  _docker_validate_container "$container" || return
  has_health="$(docker inspect --format '{{if .State.Health}}yes{{else}}no{{end}}' "$container")" || return
  if [[ "$has_health" != yes ]]; then
    printf 'Healthcheck não configurado.\n'
    return 0
  fi
  docker inspect --format $'Status={{.State.Health.Status}}\nFailingStreak={{.State.Health.FailingStreak}}' "$container" || return
  printf '\nÚltimas execuções (máximo 5; output limitado a 1024 caracteres):\n'
  docker inspect --format '{{range .State.Health.Log}}Start={{.Start}} End={{.End}} ExitCode={{.ExitCode}} Output={{printf "%.1024s" (json .Output)}}{{"\n"}}{{end}}' "$container" |
    tail -n 5
}

docker_container_disk_usage() {
  local container="${1:-}" details id size_rw size_root log_path fallback log_size="N/A"
  local mount_type mount_source mount_destination mount_size
  _docker_require_access || return
  _docker_validate_container "$container" || return
  details="$(docker inspect --size --format '{{.Id}}|{{.SizeRw}}|{{.SizeRootFs}}|{{.LogPath}}' "$container")" || return
  IFS='|' read -r id size_rw size_root log_path <<< "$details"
  if [[ -z "$log_path" && "$id" =~ ^[a-f0-9]{64}$ ]]; then
    fallback="/var/lib/docker/containers/$id/$id-json.log"
    [[ -f "$fallback" ]] && log_path="$fallback"
  fi
  if [[ -n "$log_path" && "$log_path" == /* && -f "$log_path" && -r "$log_path" ]]; then
    log_size="$(stat -c %s -- "$log_path" 2>/dev/null || printf N/A)"
  fi
  printf 'Container: %s\nWritable layer (bytes): %s\nRoot filesystem (bytes): %s\n' "$container" "${size_rw:-N/A}" "${size_root:-N/A}"
  printf 'JSON LogPath: %s\nJSON log size (bytes): %s\n\n' "${log_path:-N/A}" "$log_size"
  docker_system_df
  printf '\nMounts associados:\n'
  docker_container_mounts "$container"
  printf '\nUso dos sources acessíveis (metadados agregados, sem listar conteúdo):\n'
  while IFS='|' read -r mount_type mount_source mount_destination; do
    [[ -n "$mount_source" ]] || continue
    mount_size="N/A"
    if [[ "$mount_source" == /* && -r "$mount_source" ]] && shellops_has_command du; then
      if shellops_has_command timeout; then
        mount_size="$(timeout 10 du -sx -B1 -- "$mount_source" 2>/dev/null | awk 'NR==1 {print $1}' || printf N/A)"
      else
        mount_size="$(du -sx -B1 -- "$mount_source" 2>/dev/null | awk 'NR==1 {print $1}' || printf N/A)"
      fi
    fi
    printf '%s|%s|%s|%s bytes\n' "$mount_type" "$mount_source" "$mount_destination" "$mount_size"
  done < <(docker inspect --format '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$container")
}

docker_cleanup_analysis() {
  local container="${1:-}" state details id log_path fallback log_bytes=0 internal status
  _docker_require_access || return
  _docker_validate_container "$container" || return
  details="$(docker inspect --format '{{.State.Status}}|{{.Id}}|{{.LogPath}}' "$container")" || return
  IFS='|' read -r state id log_path <<< "$details"
  if [[ -z "$log_path" && "$id" =~ ^[a-f0-9]{64}$ ]]; then
    fallback="/var/lib/docker/containers/$id/$id-json.log"
    [[ -f "$fallback" ]] && log_path="$fallback"
  fi
  [[ -n "$log_path" && "$log_path" == /* && -r "$log_path" ]] && log_bytes="$(stat -c %s -- "$log_path" 2>/dev/null || printf 0)"
  printf 'Análise de limpeza — CONSULTA\nContainer: %s\n\n' "$container"
  printf 'Os filtros abaixo são critérios legados do script de manutenção existente; não são recomendações oficiais Philips/Tasy.\n'
  printf 'Nenhum arquivo será removido. Todo candidato exige validação operacional.\n\n'
  printf 'Docker JSON log encontrado: %s bytes\n' "$log_bytes"
  if [[ "$log_bytes" =~ ^[0-9]+$ && "$log_bytes" -gt 1073741824 ]]; then
    printf 'Docker JSON log que atende ao critério legado (> 1 GiB): %s bytes\n' "$log_bytes"
  else
    printf 'Docker JSON log que atende ao critério legado (> 1 GiB): 0 bytes\n'
  fi
  if [[ "$state" != running ]]; then
    printf '\nContainer não está running; análise interna de paths: N/A\n'
    return 0
  fi
  printf '\nPaths internos:\n'
  internal="$(docker exec "$container" sh -c '
    sum_all() { find "$1" -type f -exec stat -c %s {} \; 2>/dev/null | awk "{s+=\$1} END{print s+0}"; }
    for tomcat in /opt/apache-tomcat-*; do
      [ -d "$tomcat" ] || continue
      total=$(sum_all "$tomcat/temp"); old=$(find "$tomcat/temp" -maxdepth 1 -type f -mtime +3 -exec stat -c %s {} \; 2>/dev/null | awk "{s+=\$1} END{print s+0}")
      printf "Tomcat temp (>3 dias)|%s|%s|%s\n" "$tomcat/temp" "$total" "$old"
      total=$(sum_all "$tomcat/temp/TasyTemp"); old=$(find "$tomcat/temp/TasyTemp" -type f -mtime +3 -exec stat -c %s {} \; 2>/dev/null | awk "{s+=\$1} END{print s+0}")
      printf "TasyTemp (>3 dias)|%s|%s|%s\n" "$tomcat/temp/TasyTemp" "$total" "$old"
      total=$(sum_all "$tomcat/logs"); old=$(find "$tomcat/logs" -type f -mtime +1 -exec stat -c %s {} \; 2>/dev/null | awk "{s+=\$1} END{print s+0}")
      printf "Tomcat logs (>1 dia)|%s|%s|%s\n" "$tomcat/logs" "$total" "$old"
    done
    total=$(sum_all /tmp); old=$(find /tmp -maxdepth 1 -type f -mtime +2 -exec stat -c %s {} \; 2>/dev/null | awk "{s+=\$1} END{print s+0}")
    printf "/tmp (>2 dias)|/tmp|%s|%s\n" "$total" "$old"
  ' 2>/dev/null)"
  status=$?
  if [[ "$status" -ne 0 ]]; then
    printf 'Análise interna indisponível: container sem ferramentas compatíveis ou sem permissão.\n'
    printf '\nEspaço encontrado: %s bytes (somente JSON log)\n' "$log_bytes"
    printf 'Atende aos critérios legados: %s bytes\n' "$([[ "$log_bytes" -gt 1073741824 ]] && printf '%s' "$log_bytes" || printf 0)"
    printf 'Remoção precisa de validação: todo espaço que atende aos critérios.\n'
    return 0
  fi
  awk -F '|' -v json="$log_bytes" '
    BEGIN {found=json+0; eligible=(json>1073741824 ? json : 0)}
    NF >= 4 {printf "%-28s path=%s encontrado=%s bytes critério=%s bytes\n",$1,$2,$3,$4; found+=$3; eligible+=$4}
    END {
      printf "\nEspaço encontrado: %.0f bytes\n",found
      printf "Atende aos critérios legados: %.0f bytes\n",eligible
      printf "Remoção precisa de validação: %.0f bytes (nenhum valor é classificado como removível automaticamente)\n",eligible
    }' <<< "$internal"
  printf '\nEspaço que atende aos critérios legados não é automaticamente removível com segurança.\n'
}

docker_image_inventory() {
  local repository tag image_id created size short_id associated name used
  _docker_require_access || return
  printf 'Repository|Tag|ID curto|Created|Size|Estado|Containers associados\n'
  while IFS='|' read -r repository tag image_id created size; do
    [[ -n "$image_id" ]] || continue
    associated=""
    while IFS='|' read -r used name; do
      [[ "$used" == "$image_id" ]] || continue
      associated+="${associated:+, }$name"
    done < <(docker ps -a --no-trunc --format '{{.Image}}|{{.Names}}' 2>/dev/null | while IFS='|' read -r used name; do
      if [[ "$used" == sha256:* ]]; then printf '%s|%s\n' "$used" "$name"; else
        used="$(docker image inspect --format '{{.Id}}' "$used" 2>/dev/null || true)"; printf '%s|%s\n' "$used" "$name"
      fi
    done)
    short_id="${image_id#sha256:}"; short_id="${short_id:0:12}"
    if [[ -n "$associated" ]]; then used="em uso"; else used="sem container associado"; associated="-"; fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$repository" "$tag" "$short_id" "$created" "$size" "$used" "$associated"
  done < <(docker images --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedSince}}|{{.Size}}')
}

docker_application_groups() {
  local source type name image state health pid metadata
  _docker_require_access || return
  shellops_require_commands sort uniq awk || return
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == docker ]] || continue
    printf '%s\n' "$type"
  done < <(discovery_docker_container_records all) | sort | uniq -c | awk '{count=$1; $1=""; sub(/^ /,""); printf "%s|%d\n",$0,count}'
}

docker_application_instances() {
  local wanted="${1:-}" source type name image state health pid metadata
  _docker_require_access || return
  [[ -n "$wanted" ]] || return 2
  while IFS='|' read -r source type name image state health pid metadata; do
    [[ "$source" == docker && "$type" == "$wanted" ]] || continue
    printf '%s|%s|%s|%s\n' "$name" "$image" "$state" "$health"
  done < <(discovery_docker_container_records all)
}

docker_monitor_startup() (
  local container="${1:-}" interval="${2:-2}" timeout="${3:-600}"
  local start_epoch now elapsed details state health created started previous="" running_elapsed="N/A"
  _docker_require_access || return
  shellops_require_commands date sleep || return
  _docker_validate_container "$container" || return
  [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 60 ]] || { shellops_error "Intervalo inválido (1 a 60)."; return 2; }
  [[ "$timeout" =~ ^[1-9][0-9]*$ && "$timeout" -le 86400 ]] || { shellops_error "Timeout inválido (1 a 86400 segundos)."; return 2; }
  trap 'printf "Monitor cancelado; nenhuma alteração foi feita no container.\n"; exit 130' INT TERM
  start_epoch="$(date +%s)"
  printf 'Monitor passivo iniciado. Container=%s intervalo=%ss timeout=%ss\n' "$container" "$interval" "$timeout"
  while true; do
    details="$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}|{{.Created}}|{{.State.StartedAt}}' "$container" 2>/dev/null)" || {
      shellops_error "Container não está mais acessível."
      return 1
    }
    IFS='|' read -r state health created started <<< "$details"
    now="$(date +%s)"; elapsed=$((now-start_epoch))
    if [[ "$state|$health" != "$previous" ]]; then
      if [[ -z "$previous" ]]; then
        printf 'detected created=%s started=%s\n' "${created:-N/A}" "${started:-N/A}"
      fi
      printf '%s elapsed=%ss state=%s health=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$elapsed" "$state" "$health"
      [[ "$state" == running && "$running_elapsed" == N/A ]] && running_elapsed="$elapsed"
      previous="$state|$health"
    fi
    if [[ "$health" == healthy ]]; then
      printf 'Monitor concluído por healthy. Tempo até running: %ss; tempo até healthy: %ss.\n' "$running_elapsed" "$elapsed"
      return 0
    fi
    if [[ "$health" == not-configured && "$state" == running ]]; then
      printf 'Monitor concluído por running em %ss; healthcheck não configurado.\n' "$elapsed"
      return 0
    fi
    if [[ "$state" == exited || "$state" == dead ]]; then
      printf 'Monitor encerrado: container chegou ao estado %s em %ss.\n' "$state" "$elapsed"
      return 1
    fi
    if (( elapsed >= timeout )); then
      printf 'Monitor concluído por timeout após %ss. Estado final=%s health=%s. Nenhuma alteração foi feita.\n' "$elapsed" "$state" "$health"
      return 124
    fi
    sleep "$interval"
  done
)
