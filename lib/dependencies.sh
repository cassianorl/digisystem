#!/usr/bin/env bash

shellops_has_command() {
  command -v "$1" >/dev/null 2>&1
}

shellops_require_command() {
  local command_name="$1"
  local message="${2:-Comando obrigatório não encontrado: $command_name}"

  if ! shellops_has_command "$command_name"; then
    shellops_error "$message"
    return 127
  fi
}

shellops_require_commands() {
  local command_name
  local missing=()

  for command_name in "$@"; do
    shellops_has_command "$command_name" || missing+=("$command_name")
  done

  if (( ${#missing[@]} > 0 )); then
    shellops_error "Dependências ausentes: ${missing[*]}"
    return 127
  fi
}

shellops_docker_available() {
  shellops_require_command docker "Docker não está instalado ou não está no PATH."
}

shellops_tasy_monitor_dependencies() {
  shellops_require_commands \
    docker sar iostat vmstat pidstat zip awk date hostname uname lscpu free \
    lsblk tail cut basename sleep mkdir cat
}
