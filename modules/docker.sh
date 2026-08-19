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

docker_inspect_container() {
  local container="${1:-}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }
  docker inspect "$container"
}

docker_show_health() {
  local container="${1:-}"

  shellops_docker_available || return
  [[ -n "$container" ]] || { shellops_error "Informe o container."; return 2; }

  docker inspect --format \
    'Status={{.State.Status}} Running={{.State.Running}} RestartCount={{.RestartCount}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$container"
}
