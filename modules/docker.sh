#!/usr/bin/env bash

_docker_health_inventory() {
  local ids_output
  local -a container_ids=()
  shellops_docker_available || return
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
  shellops_docker_available || return
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_list_running_containers() {
  shellops_docker_available || return
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_list_all_containers() {
  docker_list_containers
}

docker_list_images() {
  shellops_docker_available || return
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'
}

docker_list_detected_applications() {
  local source type name image state health pid metadata
  local found=0
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
  shellops_docker_available || return
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}'
}

docker_show_logs() {
  local container="${1:-}"
  local lines="${2:-200}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  shellops_is_non_negative_integer "$lines" || { shellops_error "A quantidade de linhas deve ser um inteiro."; return 2; }

  docker logs --timestamps --tail "$lines" "$container"
}

docker_show_logs_since() {
  local container="${1:-}" lines="${2:-200}" since="${3:-}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  shellops_is_non_negative_integer "$lines" || { shellops_error "A quantidade de linhas deve ser um inteiro."; return 2; }
  [[ -n "$since" && "$since" != -* && "$since" != *$'\n'* && "$since" != *$'\r'* ]] || {
    shellops_error "Informe um período válido para --since."
    return 2
  }

  docker logs --timestamps --tail "$lines" --since "$since" "$container"
}

docker_system_df() {
  shellops_docker_available || return
  docker system df
}

docker_health_inventory() {
  _docker_health_inventory
}

docker_inspect_container() {
  local container="${1:-}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  docker inspect "$container"
}

docker_inspect_safe() {
  local container="${1:-}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  docker inspect --format $'Nome={{.Name}}\nImagem={{.Config.Image}}\nID={{.Id}}\nCriado={{.Created}}\nStatus={{.State.Status}}\nRunning={{.State.Running}}\nRestartCount={{.RestartCount}}\nHealth={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\nPorts={{json .NetworkSettings.Ports}}\nMounts={{range .Mounts}}{{.Type}}:{{.Source}} -> {{.Destination}} (RW={{.RW}}){{"\\n"}}{{end}}\nComposeProject={{index .Config.Labels "com.docker.compose.project"}}\nComposeService={{index .Config.Labels "com.docker.compose.service"}}' "$container"
}

docker_show_health() {
  local container="${1:-}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }

  docker inspect --format \
    'Status={{.State.Status}} Running={{.State.Running}} RestartCount={{.RestartCount}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$container"
}
