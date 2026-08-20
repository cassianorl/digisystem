#!/usr/bin/env bash

collections_default_destination() {
  if [[ "${EUID:-$(id -u)}" -eq 0 && -d /root && -w /root ]]; then
    printf '/root\n'
  elif [[ -n "${HOME:-}" && -d "$HOME" && -w "$HOME" ]]; then
    printf '%s\n' "$HOME"
  else
    printf '%s\n' "$PWD"
  fi
}

_collections_recent_journal() {
  local status
  services_recent_events "1 hour ago" | tail -n 500
  status=${PIPESTATUS[0]}
  return "$status"
}

_collections_run() {
  local relative_file="$1" label="$2"
  shift 2
  local output_file="$SHELLOPS_COLLECTION_ROOT/$relative_file" status

  mkdir -p -- "$(dirname -- "$output_file")" || return 1
  if "$@" >"$output_file" 2>&1; then
    status=0
    SHELLOPS_COLLECTION_RESULTS+=("$label: OK")
  else
    status=$?
    if [[ "$status" -eq 127 ]]; then
      SHELLOPS_COLLECTION_RESULTS+=("$label: UNAVAILABLE")
    else
      SHELLOPS_COLLECTION_RESULTS+=("$label: FAILED ($status)")
    fi
    SHELLOPS_COLLECTION_FAILURES+=("$label ($status)")
  fi
  [[ -s "$output_file" ]] || printf 'Coletor finalizado sem saída. Status: %s\n' "$status" > "$output_file"
  return 0
}

_collections_security_barrier() {
  local forbidden_file suspicious_file
  forbidden_file="$(find "$SHELLOPS_COLLECTION_ROOT" -type f \
    \( -iname '*.pem' -o -iname '*.key' -o -iname '*.pfx' -o -iname '*.p12' \
       -o -iname '*.jks' -o -iname '*credential*' -o -iname '*secret*' \) -print -quit 2>/dev/null)"
  [[ -z "$forbidden_file" ]] || {
    shellops_error "Barreira de segurança: arquivo de tipo proibido encontrado na coleta."
    return 1
  }

  suspicious_file="$(grep -Eil -m 1 \
    'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|(^|[^[:alnum:]_])(password|passwd|token|secret)[[:space:]]*=' \
    "$SHELLOPS_COLLECTION_ROOT"/*/*.txt "$SHELLOPS_COLLECTION_ROOT"/manifest.txt 2>/dev/null | head -n 1)"
  [[ -z "$suspicious_file" ]] || {
    shellops_error "Barreira adicional de segurança encontrou conteúdo potencialmente sensível; o bundle não será criado."
    return 1
  }
}

collections_generate_support_bundle() (
  local destination="${1:-}" temp_dir bundle_dir hostname_value timestamp bundle_name final_path
  local started_at finished_at executor version result
  local -a SHELLOPS_COLLECTION_RESULTS=() SHELLOPS_COLLECTION_FAILURES=()

  [[ -n "$destination" && -d "$destination" && -w "$destination" ]] || {
    shellops_error "O diretório de destino deve existir e ser gravável."
    return 2
  }
  shellops_require_commands mktemp mkdir dirname date hostname tar find grep head tail tr || return

  temp_dir="$(mktemp -d)" || { shellops_error "Não foi possível criar diretório temporário."; return 1; }
  trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM
  hostname_value="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf host)"
  hostname_value="$(printf '%s' "$hostname_value" | tr -cd '[:alnum:]_.-')"
  hostname_value="${hostname_value:-host}"
  timestamp="$(date '+%Y%m%d-%H%M%S')" || return 1
  bundle_name="shellops-support-${hostname_value}-${timestamp}"
  bundle_dir="$temp_dir/$bundle_name"
  final_path="$destination/$bundle_name.tar.gz"
  [[ ! -e "$final_path" ]] || { shellops_error "O arquivo final já existe."; return 1; }

  SHELLOPS_COLLECTION_ROOT="$bundle_dir"
  export SHELLOPS_COLLECTION_ROOT
  mkdir -p -- "$bundle_dir"/{health,system,services,network,docker,logs} || return 1
  started_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
  executor="${USER:-${LOGNAME:-desconhecido}}"
  version="${SHELLOPS_VERSION:-1.0-dev}"

  _collections_run health/quick-health.txt health health_quick_check
  _collections_run system/summary.txt system-summary system_server_summary
  _collections_run system/cpu-load.txt system-cpu system_cpu_load
  _collections_run system/memory-swap.txt system-memory system_memory_swap
  _collections_run system/filesystems.txt system-filesystems system_filesystems
  _collections_run system/inodes.txt system-inodes system_inodes
  _collections_run system/block-devices.txt system-block-devices system_block_devices
  _collections_run services/failed.txt services-failed services_failed
  _collections_run services/recent-errors.txt services-journal _collections_recent_journal
  _collections_run network/interfaces.txt network-interfaces network_interfaces
  _collections_run network/routes.txt network-routes network_routes
  _collections_run network/dns.txt network-dns network_dns_status
  _collections_run network/sockets.txt network-sockets network_sockets summary

  if shellops_docker_available >/dev/null 2>&1; then
    _collections_run docker/containers.txt docker-containers docker_list_all_containers
    _collections_run docker/images.txt docker-images docker_list_images
    _collections_run docker/system-df.txt docker-system-df docker_system_df
    _collections_run docker/health.txt docker-health docker_health_inventory
  else
    SHELLOPS_COLLECTION_RESULTS+=("Docker: UNAVAILABLE")
    SHELLOPS_COLLECTION_FAILURES+=("Docker indisponível")
    printf 'Docker não está instalado, não está no PATH ou não pôde ser consultado.\n' > "$bundle_dir/docker/UNAVAILABLE.txt"
  fi

  printf '%s\n' \
    'Logs de aplicação não são incluídos automaticamente no Support Bundle por poderem conter dados sensíveis, credenciais, tokens e grande volume de dados.' \
    > "$bundle_dir/logs/README.txt"

  finished_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
  {
    printf 'ShellOps Support Bundle\n'
    printf 'Hostname: %s\n' "$hostname_value"
    printf 'Data/hora: %s\n' "$finished_at"
    printf 'Versão ShellOps: %s\n' "$version"
    printf 'Usuário executor: %s\n' "$executor"
    printf 'Início: %s\nTérmino: %s\n' "$started_at" "$finished_at"
    printf '\nMódulos executados:\n'
    for result in "${SHELLOPS_COLLECTION_RESULTS[@]}"; do printf -- '- %s\n' "$result"; done
    printf '\nFalhas de coleta:\n'
    if (( ${#SHELLOPS_COLLECTION_FAILURES[@]} == 0 )); then
      printf -- '- nenhuma registrada\n'
    else
      for result in "${SHELLOPS_COLLECTION_FAILURES[@]}"; do printf -- '- %s\n' "$result"; done
    fi
    printf '\nSegurança:\n'
    printf '%s\n' '- Logs de aplicação e arquivos arbitrários não foram incluídos.'
    printf '%s\n' '- Docker Config.Env e docker inspect integral não foram coletados.'
    printf '%s\n' '- A inspeção por padrões é somente uma barreira adicional e não comprova ausência de secrets.'
  } > "$bundle_dir/manifest.txt" || return 1

  find "$bundle_dir" -type f -size +0c -print -quit | grep -q . || {
    shellops_error "A coleta não produziu conteúdo."
    return 1
  }
  _collections_security_barrier || return 1
  tar -C "$temp_dir" -czf "$final_path" "$bundle_name" || {
    rm -f -- "$final_path"
    shellops_error "Não foi possível empacotar a coleta."
    return 1
  }
  printf '%s\n' "$final_path"
)
