#!/usr/bin/env bash

_network_require_command() {
  local command_name="${1:-}"
  if ! shellops_has_command "$command_name"; then
    printf 'Comando %s não está disponível.\n' "$command_name" >&2
    return 127
  fi
}

_network_validate_name() {
  local value="${1:-}" label="${2:-Destino}"
  if [[ -z "$value" || "$value" == -* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf '%s inválido.\n' "$label" >&2
    return 2
  fi
}

_network_validate_port() {
  local port="${1:-}"
  if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
    printf 'A porta deve ser um inteiro entre 1 e 65535.\n' >&2
    return 2
  fi
}

_network_validate_count() {
  local count="${1:-}"
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" -lt 1 || "$count" -gt 100 ]]; then
    printf 'A quantidade deve ser um inteiro entre 1 e 100.\n' >&2
    return 2
  fi
}

_network_non_loopback_up_interfaces() {
  _network_require_command ip || return
  _network_require_command awk || return
  ip -o link show up | awk -F': ' '$2 != "lo" {name=$2; sub(/@.*/, "", name); print name}'
}

_network_default_routes() {
  _network_require_command ip || return
  ip route show default
  ip -6 route show default
}

_network_resolver_available() {
  local key value remainder
  [[ -r /etc/resolv.conf ]] || return 1
  while read -r key value remainder; do
    [[ "$key" == "nameserver" && -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
  done < /etc/resolv.conf
  return 1
}

network_interface_names() {
  _network_require_command ip || return
  _network_require_command awk || return
  ip -o link show | awk -F': ' '{name=$2; sub(/@.*/, "", name); print name}'
}

network_overview() {
  printf '=== Identificação ===\n'
  if shellops_has_command hostname; then printf 'Hostname: %s\n' "$(hostname)"; else printf 'hostname indisponível\n'; fi

  printf '\n=== Interfaces e endereços ===\n'
  if shellops_has_command ip; then
    ip -br link
    printf '\n'
    ip -br addr
  else
    printf 'Comando ip não está disponível.\n'
  fi

  printf '\n=== Rotas padrão ===\n'
  if shellops_has_command ip; then
    printf 'IPv4:\n'
    ip route show default
    printf 'IPv6:\n'
    ip -6 route show default
  else
    printf 'Comando ip não está disponível.\n'
  fi

  printf '\n=== DNS configurado ===\n'
  if [[ -r /etc/resolv.conf ]]; then
    while IFS= read -r line; do
      case "$line" in nameserver*|search*|domain*|options*) printf '%s\n' "$line" ;; esac
    done < /etc/resolv.conf
  else
    printf '/etc/resolv.conf não está legível.\n'
  fi

  if shellops_has_command hostname && shellops_has_command getent; then
    printf '\nResolução do hostname local:\n'
    getent hosts "$(hostname)" || printf 'Hostname local não resolvido pelo NSS.\n'
  fi

  printf '\n=== Sockets ===\n'
  if shellops_has_command ss; then
    ss -s
    printf '\nListeners TCP/UDP:\n'
    ss -lntu
  else
    printf 'Comando ss não está disponível.\n'
  fi
}

network_interfaces() {
  _network_require_command ip || return
  printf '=== Endereços ===\n'
  ip -br addr
  printf '\n=== Links e MAC ===\n'
  ip -br link
}

network_interface_details() {
  local interface="${1:-}"
  _network_validate_name "$interface" "Interface" || return
  _network_require_command ip || return
  ip addr show dev "$interface"
  printf '\n=== Link ===\n'
  ip link show dev "$interface"
}

network_routes() {
  _network_require_command ip || return
  printf '=== Default IPv4 ===\n'
  ip route show default
  printf '\n=== Rotas IPv4 ===\n'
  ip route show
  printf '\n=== Default IPv6 ===\n'
  ip -6 route show default
  printf '\n=== Rotas IPv6 ===\n'
  ip -6 route show
}

network_route_get() {
  local destination="${1:-}"
  _network_validate_name "$destination" "Destino" || return
  _network_require_command ip || return
  ip route get "$destination"
}

network_dns_status() {
  printf '=== /etc/resolv.conf ===\n'
  if [[ -r /etc/resolv.conf ]]; then
    while IFS= read -r line; do printf '%s\n' "$line"; done < /etc/resolv.conf
  else
    printf '/etc/resolv.conf não está legível.\n'
  fi

  printf '\n=== resolvectl ===\n'
  if shellops_has_command resolvectl; then resolvectl status
  else printf 'resolvectl não está disponível.\n'; fi

  printf '\n=== NetworkManager DNS ===\n'
  if shellops_has_command nmcli; then
    nmcli --fields GENERAL.DEVICE,IP4.DNS,IP6.DNS device show
  else
    printf 'nmcli não está disponível.\n'
  fi
}

network_resolve() {
  local host_name="${1:-}" detailed="${2:-0}" status
  _network_validate_name "$host_name" "Hostname/endereço" || return
  _network_require_command getent || return
  printf '=== Resolução NSS (getent) ===\n'
  getent hosts "$host_name"
  status=$?

  if [[ "$detailed" == "1" ]]; then
    printf '\n=== Consulta DNS detalhada ===\n'
    if shellops_has_command dig; then dig "$host_name"
    elif shellops_has_command host; then host "$host_name"
    elif shellops_has_command nslookup; then nslookup "$host_name"
    else printf 'dig, host e nslookup não estão disponíveis.\n'; fi
  fi
  return "$status"
}

network_sockets() {
  local mode="${1:-summary}"
  _network_require_command ss || return
  case "$mode" in
    tcp-listen) ss -lntp ;;
    udp) ss -lnup ;;
    established) ss -ntp state established ;;
    summary) ss -s ;;
    *) printf 'Modo de sockets inválido.\n' >&2; return 2 ;;
  esac
  printf '\nNota: informações de processo/PID podem ser limitadas sem root.\n'
}

network_ping() {
  local destination="${1:-}" count="${2:-4}" deadline status
  _network_validate_name "$destination" "Destino" || return
  _network_validate_count "$count" || return
  _network_require_command ping || return
  deadline=$((count * 3))
  printf 'Teste ICMP com %d pacote(s) e deadline de %d segundos.\n\n' "$count" "$deadline"
  ping -c "$count" -W 2 -w "$deadline" "$destination"
  status=$?
  printf '\nICMP pode estar bloqueado mesmo quando o serviço de destino está disponível.\n'
  return "$status"
}

network_tcp_test() {
  local destination="${1:-}" port="${2:-}" timeout_seconds="${3:-5}" output status
  _network_validate_name "$destination" "Destino" || return
  _network_validate_port "$port" || return
  _network_validate_count "$timeout_seconds" || return

  if shellops_has_command nc; then
    output="$(LC_ALL=C nc -vz -w "$timeout_seconds" "$destination" "$port" 2>&1)"
    status=$?
  elif shellops_has_command timeout && shellops_has_command bash; then
    output="$(timeout "$timeout_seconds" bash -c 'exec 3<>"/dev/tcp/$1/$2"' shellops "$destination" "$port" 2>&1)"
    status=$?
  else
    printf 'nc não está disponível e o fallback timeout/bash não pode ser usado.\n' >&2
    return 127
  fi

  printf '%s\n' "$output"
  if [[ "$status" -eq 0 ]]; then
    printf 'Resultado: conexão TCP estabelecida. Isso não comprova a saúde da aplicação.\n'
  elif [[ "$output" == *refused* ]]; then printf 'Resultado: conexão recusada.\n'
  elif [[ "$output" == *timed\ out* || "$status" -eq 124 ]]; then printf 'Resultado: timeout.\n'
  elif [[ "$output" == *Name\ or\ service\ not\ known* || "$output" == *Temporary\ failure\ in\ name\ resolution* ]]; then
    printf 'Resultado: erro de resolução de nome.\n'
  else
    printf 'Resultado: conexão não estabelecida; consulte a mensagem da ferramenta.\n'
  fi
  return "$status"
}

network_trace() {
  local destination="${1:-}" status
  _network_validate_name "$destination" "Destino" || return
  if shellops_has_command tracepath; then
    if shellops_has_command timeout; then timeout 45 tracepath -m 20 "$destination"
    else tracepath -m 20 "$destination"; fi
    status=$?
  elif shellops_has_command traceroute; then
    if shellops_has_command timeout; then timeout 45 traceroute -m 20 -w 2 "$destination"
    else traceroute -m 20 -w 2 "$destination"; fi
    status=$?
  else
    printf 'tracepath/traceroute não estão disponíveis.\n' >&2
    printf 'Pacotes podem ser instalados manualmente, mas o ShellOps não executa instalação.\n' >&2
    return 127
  fi
  return "$status"
}

network_neighbors() {
  _network_require_command ip || return
  ip neigh show
  printf '\nOs estados são apresentados sem classificação automática global.\n'
}

network_interface_stats() {
  local interface="${1:-}" include_ethtool="${2:-0}"
  _network_require_command ip || return
  if [[ -n "$interface" ]]; then
    _network_validate_name "$interface" "Interface" || return
    ip -s link show dev "$interface"
  else
    ip -s link show
  fi

  if [[ "$include_ethtool" == "1" && -n "$interface" ]]; then
    printf '\n=== Estatísticas do driver (ethtool -S) ===\n'
    if shellops_has_command ethtool; then ethtool -S "$interface"
    else printf 'ethtool não está disponível.\n'; fi
  fi
}
