#!/usr/bin/env bash

HEALTH_FS_ATTENTION_PERCENT=80
HEALTH_FS_WARNING_PERCENT=90
HEALTH_FS_CRITICAL_PERCENT=95
HEALTH_FS_ATTENTION_AVAILABLE_KB=$((10 * 1024 * 1024))
HEALTH_FS_WARNING_AVAILABLE_KB=$((5 * 1024 * 1024))
HEALTH_FS_CRITICAL_AVAILABLE_KB=$((1 * 1024 * 1024))
HEALTH_INODE_ATTENTION_PERCENT=80
HEALTH_INODE_WARNING_PERCENT=90
HEALTH_INODE_CRITICAL_PERCENT=95
HEALTH_MEMORY_LOW_PERCENT=10
HEALTH_MEMORY_VERY_LOW_PERCENT=5
HEALTH_CPU_IDLE_LOW_PERCENT=5
HEALTH_CPU_IOWAIT_HIGH_PERCENT=20
HEALTH_CPU_STEAL_HIGH_PERCENT=10

_HEALTH_EVIDENCE=()
_HEALTH_COLLECTIONS=()
_HEALTH_ATTENTION=0
_HEALTH_WARNING=0
_HEALTH_CRITICAL=0

_health_evidence() {
  local severity="$1" message="$2"
  _HEALTH_EVIDENCE+=("[$severity] $message")
  case "$severity" in
    ATTENTION) _HEALTH_ATTENTION=$((_HEALTH_ATTENTION + 1)) ;;
    WARNING) _HEALTH_WARNING=$((_HEALTH_WARNING + 1)) ;;
    CRITICAL) _HEALTH_CRITICAL=$((_HEALTH_CRITICAL + 1)) ;;
  esac
}

_health_collection_status() {
  _HEALTH_COLLECTIONS+=("$1|$2")
}

_health_vmstat_metrics() {
  shellops_has_command vmstat || return 127
  vmstat 1 4 2>/dev/null | awk '
    /^[[:space:]]*[0-9]/ {
      rows++
      if (rows == 1) next
      samples++
      si += $7; so += $8
      us += $(NF-4); sy += $(NF-3); idle += $(NF-2); wa += $(NF-1); st += $NF
    }
    END {
      if (samples < 1) exit 1
      printf "%.2f %.2f %.2f %.2f %.2f %.0f %.0f %d\n", us/samples, sy/samples, wa/samples, st/samples, idle/samples, si, so, samples
    }'
}

_health_mpstat_metrics() {
  shellops_has_command mpstat || return 127
  LC_ALL=C mpstat 1 3 2>/dev/null | awk \
    -v idle_limit="$HEALTH_CPU_IDLE_LOW_PERCENT" \
    -v wait_limit="$HEALTH_CPU_IOWAIT_HIGH_PERCENT" \
    -v steal_limit="$HEALTH_CPU_STEAL_HIGH_PERCENT" '
    /%usr/ && /%idle/ {
      for (i=1; i<=NF; i++) {
        if ($i=="CPU") cpu=i
        else if ($i=="%usr") usr=i
        else if ($i=="%sys") sys=i
        else if ($i=="%iowait") iowait=i
        else if ($i=="%steal") steal=i
        else if ($i=="%idle") idle=i
      }
      next
    }
    cpu && $cpu=="all" && $1!="Average:" {
      n++; u+=$usr; s+=$sys; w+=$iowait; t+=$steal; d+=$idle
      if ($idle+0 < idle_limit) low_idle++
      if ($iowait+0 >= wait_limit) high_wait++
      if ($steal+0 >= steal_limit) high_steal++
    }
    END {
      if (n < 1) exit 1
      printf "%.2f %.2f %.2f %.2f %.2f %d %d %d %d\n", u/n, s/n, w/n, t/n, d/n, low_idle, high_wait, high_steal, n
    }'
}

_health_system_section() {
  local hostname_value="N/A" os_value="N/A" kernel_value="N/A" uptime_value="N/A"
  local cpu_count memory_total
  shellops_has_command hostname && hostname_value="$(hostname)"
  os_value="$(_system_os_pretty_name 2>/dev/null || true)"
  shellops_has_command uname && kernel_value="$(uname -r)"
  shellops_has_command uptime && uptime_value="$(uptime -p 2>/dev/null || uptime)"
  cpu_count="$(_system_cpu_count)"
  memory_total="$(_system_memory_value_kb MemTotal 2>/dev/null || true)"

  printf '\nSYSTEM\n------------------------------------------------\n'
  printf 'Host: %s\nOS: %s\nKernel: %s\nUptime: %s\nCPUs: %s\n' \
    "$hostname_value" "${os_value:-N/A}" "$kernel_value" "$uptime_value" "$cpu_count"
  if [[ "$memory_total" =~ ^[0-9]+$ ]]; then
    awk -v kb="$memory_total" 'BEGIN {printf "Memória total: %.2f GiB\n", kb/1024/1024}'
    _health_collection_status "Sistema" "AVAILABLE"
  else
    printf 'Memória total: N/A\n'
    _health_collection_status "Sistema" "ERROR"
  fi
}

_health_cpu_section() {
  local load_values cpu_count metrics source
  local usr sys wait steal idle low_idle high_wait high_steal samples si so
  load_values="$(_system_load_average)"
  cpu_count="$(_system_cpu_count)"

  if metrics="$(_health_mpstat_metrics)"; then
    source="mpstat"
    read -r usr sys wait steal idle low_idle high_wait high_steal samples <<< "$metrics"
  elif metrics="$(_health_vmstat_metrics)"; then
    source="vmstat fallback"
    read -r usr sys wait steal idle si so samples <<< "$metrics"
    low_idle=0; high_wait=0; high_steal=0
    awk -v value="$idle" -v limit="$HEALTH_CPU_IDLE_LOW_PERCENT" 'BEGIN {exit !(value < limit)}' && low_idle="$samples"
    awk -v value="$wait" -v limit="$HEALTH_CPU_IOWAIT_HIGH_PERCENT" 'BEGIN {exit !(value >= limit)}' && high_wait="$samples"
    awk -v value="$steal" -v limit="$HEALTH_CPU_STEAL_HIGH_PERCENT" 'BEGIN {exit !(value >= limit)}' && high_steal="$samples"
  else
    printf '\nCPU\n------------------------------------------------\nCPUs: %s\nLoad 1/5/15: %s\nAmostra: N/A\n' "$cpu_count" "$load_values"
    _health_collection_status "CPU" "UNAVAILABLE"
    return
  fi

  printf '\nCPU\n------------------------------------------------\n'
  printf 'Fonte: %s\nCPUs: %s\nLoad 1/5/15: %s\nUser: %s%%\nSystem: %s%%\nI/O wait: %s%%\nSteal: %s%%\nIdle: %s%%\n' \
    "$source" "$cpu_count" "$load_values" "$usr" "$sys" "$wait" "$steal" "$idle"
  printf 'Critério: evidência somente quando todas as %s amostras atuais cruzam o limite.\n' "$samples"
  [[ "$samples" -ge 2 && "$low_idle" -eq "$samples" ]] && \
    _health_evidence WARNING "Durante todas as $samples amostras coletadas, CPU idle permaneceu abaixo de ${HEALTH_CPU_IDLE_LOW_PERCENT}%."
  [[ "$samples" -ge 2 && "$high_wait" -eq "$samples" ]] && \
    _health_evidence ATTENTION "Durante todas as $samples amostras coletadas, CPU iowait permaneceu em ou acima de ${HEALTH_CPU_IOWAIT_HIGH_PERCENT}%; correlacione com latência, fila e workload de storage."
  [[ "$samples" -ge 2 && "$high_steal" -eq "$samples" ]] && \
    _health_evidence WARNING "Durante todas as $samples amostras coletadas, CPU steal permaneceu em ou acima de ${HEALTH_CPU_STEAL_HIGH_PERCENT}%."
  _health_collection_status "CPU" "AVAILABLE"
}

_health_memory_section() {
  local total available swap_total swap_free swap_used available_percent="N/A"
  local vm_metrics usr sys wait steal idle si=0 so=0 samples paging_available=0
  total="$(_system_memory_value_kb MemTotal 2>/dev/null || true)"
  available="$(_system_memory_value_kb MemAvailable 2>/dev/null || true)"
  swap_total="$(_system_memory_value_kb SwapTotal 2>/dev/null || true)"
  swap_free="$(_system_memory_value_kb SwapFree 2>/dev/null || true)"
  if vm_metrics="$(_health_vmstat_metrics)"; then
    read -r usr sys wait steal idle si so samples <<< "$vm_metrics"
    paging_available=1
  fi

  printf '\nMEMORY / SWAP\n------------------------------------------------\n'
  if [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
    available_percent="$(awk -v a="$available" -v t="$total" 'BEGIN {printf "%.2f", a*100/t}')"
    printf 'MemTotal: %s kB\nMemAvailable: %s kB (%s%%)\n' "$total" "$available" "$available_percent"
  else
    printf 'MemTotal: N/A\nMemAvailable: N/A\n'
  fi
  if [[ "$swap_total" =~ ^[0-9]+$ && "$swap_free" =~ ^[0-9]+$ ]]; then
    swap_used=$((swap_total - swap_free))
    printf 'SwapTotal: %s kB\nSwapUsed: %s kB\n' "$swap_total" "$swap_used"
  else
    swap_used=0
    printf 'SwapTotal: N/A\nSwapUsed: N/A\n'
  fi
  if [[ "$paging_available" -eq 1 ]]; then
    printf 'Swap-in (si, soma da amostra): %s\nSwap-out (so, soma da amostra): %s\n' "$si" "$so"
  else
    printf 'Swap-in (si): N/A\nSwap-out (so): N/A\n'
  fi

  if [[ "$available_percent" != "N/A" ]]; then
    if awk -v p="$available_percent" -v l="$HEALTH_MEMORY_VERY_LOW_PERCENT" 'BEGIN {exit !(p < l)}' && [[ "$so" -gt 0 ]]; then
      _health_evidence WARNING "MemAvailable abaixo de ${HEALTH_MEMORY_VERY_LOW_PERCENT}% com swap-out observado durante a janela amostrada."
    elif awk -v p="$available_percent" -v l="$HEALTH_MEMORY_LOW_PERCENT" 'BEGIN {exit !(p < l)}' && [[ "$si" -gt 0 || "$so" -gt 0 ]]; then
      _health_evidence ATTENTION "MemAvailable abaixo de ${HEALTH_MEMORY_LOW_PERCENT}% com atividade de swap observada durante a janela amostrada (si=$si, so=$so)."
    elif awk -v p="$available_percent" -v l="$HEALTH_MEMORY_VERY_LOW_PERCENT" 'BEGIN {exit !(p < l)}'; then
      _health_evidence ATTENTION "MemAvailable abaixo de ${HEALTH_MEMORY_VERY_LOW_PERCENT}% no snapshot, sem atividade de swap observada na janela curta."
    elif [[ "$paging_available" -eq 1 && "$swap_used" -gt 0 && "$si" -eq 0 && "$so" -eq 0 ]] && \
      awk -v p="$available_percent" -v l="$HEALTH_MEMORY_LOW_PERCENT" 'BEGIN {exit !(p >= l)}'; then
      _health_evidence INFO "Swap utilizada, sem evidência de paginação ativa nesta amostra."
    fi
    _health_collection_status "Memoria" "AVAILABLE"
  else
    _health_collection_status "Memoria" "ERROR"
  fi
}

_health_capacity_section() {
  local mode="$1" command_label attention warning critical output line percent mount severity available available_gib
  if [[ "$mode" == "filesystem" ]]; then
    command_label="FILESYSTEMS"; attention=$HEALTH_FS_ATTENTION_PERCENT; warning=$HEALTH_FS_WARNING_PERCENT; critical=$HEALTH_FS_CRITICAL_PERCENT
    output="$(df -PkT -x tmpfs -x devtmpfs -x squashfs -x iso9660 2>/dev/null)" || output=""
  else
    command_label="INODES"; attention=$HEALTH_INODE_ATTENTION_PERCENT; warning=$HEALTH_INODE_WARNING_PERCENT; critical=$HEALTH_INODE_CRITICAL_PERCENT
    output="$(df -PTi -x tmpfs -x devtmpfs 2>/dev/null)" || output=""
  fi
  printf '\n%s\n------------------------------------------------\n' "$command_label"
  if [[ -z "$output" ]]; then
    printf 'N/A\n'; _health_collection_status "$command_label" "UNAVAILABLE"; return
  fi
  printf '%s\n' "$output"
  while IFS= read -r line; do
    [[ "$line" == Filesystem* ]] && continue
    percent="$(awk '{gsub(/%/, "", $6); print $6}' <<< "$line")"
    mount="$(awk '{print $7}' <<< "$line")"
    [[ "$percent" =~ ^[0-9]+$ ]] || continue
    severity=""
    if [[ "$mode" == "filesystem" ]]; then
      available="$(awk '{print $5}' <<< "$line")"
      [[ "$available" =~ ^[0-9]+$ ]] || continue
      if [[ "$percent" -ge "$critical" && "$available" -lt "$HEALTH_FS_CRITICAL_AVAILABLE_KB" ]]; then severity=CRITICAL
      elif [[ "$percent" -ge "$warning" && "$available" -lt "$HEALTH_FS_WARNING_AVAILABLE_KB" ]]; then severity=WARNING
      elif [[ "$percent" -ge "$attention" && "$available" -lt "$HEALTH_FS_ATTENTION_AVAILABLE_KB" ]]; then severity=ATTENTION; fi
      if [[ -n "$severity" ]]; then
        available_gib="$(awk -v kb="$available" 'BEGIN {printf "%.2f", kb/1024/1024}')"
        _health_evidence "$severity" "$command_label em $mount está com ${percent}% de utilização e ${available_gib} GiB disponíveis."
      fi
    else
      if [[ "$percent" -ge "$critical" ]]; then severity=CRITICAL
      elif [[ "$percent" -ge "$warning" ]]; then severity=WARNING
      elif [[ "$percent" -ge "$attention" ]]; then severity=ATTENTION; fi
      [[ -n "$severity" ]] && _health_evidence "$severity" "$command_label em $mount está com ${percent}% de utilização."
    fi
  done <<< "$output"
  _health_collection_status "$command_label" "AVAILABLE"
}

_health_services_section() {
  local output status count
  printf '\nSERVICES\n------------------------------------------------\n'
  if output="$(_services_failed_units 2>&1)"; then
    if [[ -n "$output" ]]; then
      count="$(awk 'NF {n++} END {print n+0}' <<< "$output")"
      printf 'Services failed: %s\n%s\n' "$count" "$output"
      _health_evidence ATTENTION "Existem $count services em estado failed que merecem investigação; isso não estabelece a causa do incidente."
    else
      printf 'Services failed: 0\n'
    fi
    _health_collection_status "Systemd" "AVAILABLE"
  else
    status=$?
    printf '%s\n' "$output"
    [[ "$status" -eq 127 ]] && _health_collection_status "Systemd" "UNAVAILABLE" || _health_collection_status "Systemd" "ERROR"
  fi
}

_health_network_section() {
  local interfaces routes resolver hostname_result network_status="AVAILABLE"
  printf '\nNETWORK\n------------------------------------------------\n'
  if interfaces="$(_network_non_loopback_up_interfaces 2>/dev/null)"; then
    printf 'Interfaces não-loopback UP: %s\n' "${interfaces//$'\n'/, }"
    [[ -n "$interfaces" ]] || _health_evidence ATTENTION "Nenhuma interface não-loopback está UP."
  else
    printf 'Interfaces UP: N/A\n'; network_status="UNAVAILABLE"
  fi
  if routes="$(_network_default_routes 2>/dev/null)"; then
    printf 'Default routes:\n%s\n' "${routes:-nenhuma}"
    [[ -n "$routes" ]] || _health_evidence ATTENTION "Nenhuma default route IPv4 ou IPv6 foi encontrada; isso pode ser intencional em rede isolada."
  else
    printf 'Default routes: N/A\n'; network_status="UNAVAILABLE"
  fi
  if resolver="$(_network_resolver_available 2>/dev/null)"; then printf 'Resolver configurado: %s\n' "$resolver"
  else printf 'Resolver configurado: não detectado\n'; _health_evidence ATTENTION "Nenhum nameserver foi detectado em /etc/resolv.conf; a resolução pode depender de /etc/hosts, configuração estática ou rede isolada."; fi
  if shellops_has_command hostname && shellops_has_command getent; then
    hostname_result="$(getent hosts "$(hostname)" 2>/dev/null || true)"
    printf 'Hostname via NSS: %s\n' "${hostname_result:-não resolvido}"
  else
    printf 'Hostname via NSS: N/A\n'
  fi
  _health_collection_status "Rede" "$network_status"
}

_health_docker_section() {
  local output status state health name running=0 stopped=0 other=0 healthchecks=0 healthy=0 unhealthy=0 starting=0
  printf '\nDOCKER\n------------------------------------------------\n'
  if ! shellops_has_command docker; then
    printf 'Não instalado / não aplicável\n'; _health_collection_status "Docker" "UNAVAILABLE"; return
  fi
  if output="$(_docker_health_inventory 2>&1)"; then
    while IFS='|' read -r state health name; do
      [[ -n "$state" ]] || continue
      case "$state" in
        running) running=$((running + 1)) ;;
        exited|created|dead) stopped=$((stopped + 1)) ;;
        *) other=$((other + 1)) ;;
      esac
      if [[ "$health" != "none" ]]; then
        healthchecks=$((healthchecks + 1))
        case "$health" in healthy) healthy=$((healthy + 1)) ;; unhealthy) unhealthy=$((unhealthy + 1)); _health_evidence WARNING "Container ${name#/} está unhealthy." ;; starting) starting=$((starting + 1)) ;; esac
      fi
    done <<< "$output"
    printf 'Running: %d\nStopped/exited: %d\nOutros estados: %d\nCom healthcheck: %d\nHealthy: %d\nUnhealthy: %d\nStarting: %d\n' \
      "$running" "$stopped" "$other" "$healthchecks" "$healthy" "$unhealthy" "$starting"
    _health_collection_status "Docker" "AVAILABLE"
  else
    status=$?
    printf '%s\n' "$output"
    [[ "$status" -eq 13 ]] && printf 'Permissão insuficiente ou daemon Docker inacessível.\n'
    [[ "$status" -eq 13 ]] && _health_collection_status "Docker" "PERMISSION_DENIED" || _health_collection_status "Docker" "ERROR"
  fi
}

health_quick_check() {
  local collection collection_name collection_status
  _HEALTH_EVIDENCE=(); _HEALTH_COLLECTIONS=()
  _HEALTH_ATTENTION=0; _HEALTH_WARNING=0; _HEALTH_CRITICAL=0
  printf 'ShellOps Quick Health Check\n================================================\n'
  _health_system_section || true
  _health_cpu_section || true
  _health_memory_section || true
  if shellops_has_command df && shellops_has_command awk; then
    _health_capacity_section filesystem || true
    _health_capacity_section inodes || true
  else
    printf '\nFILESYSTEMS / INODES\n------------------------------------------------\nN/A: df ou awk indisponível.\n'
    _health_collection_status "Capacidade" "UNAVAILABLE"
  fi
  _health_services_section || true
  _health_network_section || true
  _health_docker_section || true

  printf '\nCOLLECTION STATUS\n------------------------------------------------\n'
  for collection in "${_HEALTH_COLLECTIONS[@]}"; do
    IFS='|' read -r collection_name collection_status <<< "$collection"
    printf '%-22s %s\n' "$collection_name" "$collection_status"
  done

  printf '\nEVIDENCE\n------------------------------------------------\n'
  if (( ${#_HEALTH_EVIDENCE[@]} == 0 )); then printf 'Nenhuma evidência pelos critérios desta versão.\n'
  else printf '%s\n' "${_HEALTH_EVIDENCE[@]}"; fi
  printf '\nSUMMARY\n------------------------------------------------\n'
  printf 'Critical: %d\nWarnings: %d\nAttention: %d\n' "$_HEALTH_CRITICAL" "$_HEALTH_WARNING" "$_HEALTH_ATTENTION"
  printf '\nEste relatório consolida evidências pontuais; não substitui análise contextual.\n'
}
