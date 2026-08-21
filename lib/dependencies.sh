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

shellops_dependencies_inventory() {
  local command_name category feature status
  printf 'Dependências ShellOps %s\n' "${SHELLOPS_VERSION:-N/A}"
  printf 'A ausência de FEATURE/OPTIONAL desabilita somente o recurso relacionado.\n\n'
  printf 'Categoria|Comando|Recurso|Status\n'
  while IFS='|' read -r category command_name feature; do
    if shellops_has_command "$command_name"; then status=OK; else status=UNAVAILABLE; fi
    printf '%s|%s|%s|%s\n' "$category" "$command_name" "$feature" "$status"
  done <<'EOF'
CORE|bash|ShellOps
CORE|dialog|TUI
CORE|dirname|Inicialização
CORE|readlink|Inicialização
FEATURE|docker|Docker/TIE/TASY
FEATURE|openssl|Certificados/TLS
FEATURE|keytool|JKS
FEATURE|sqlplus|Oracle SQL
FEATURE|tnsping|Oracle TNS
FEATURE|lsnrctl|Oracle Listener
FEATURE|jcmd|Java avançado
FEATURE|jstack|Java avançado
FEATURE|chronyc|NTP/Chrony
FEATURE|smbpasswd|Provisionamento Samba
OPTIONAL|sar|Performance histórica
OPTIONAL|iostat|Performance de disco
OPTIONAL|pidstat|Performance de processos
OPTIONAL|xmllint|Parsing XML restrito
OPTIONAL|tracepath|Diagnóstico de rede
OPTIONAL|traceroute|Diagnóstico de rede
OPTIONAL|dig|DNS detalhado
OPTIONAL|nc|Teste TCP
OPTIONAL|ethtool|Interface de rede
EOF
}
