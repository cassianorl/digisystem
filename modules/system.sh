#!/usr/bin/env bash

_system_section() { printf '\n=== %s ===\n' "$1"; }
_system_unavailable() { printf 'Indisponível: comando %s não encontrado.\n' "$1"; }

_system_os_pretty_name() {
  local key value
  [[ -r /etc/os-release ]] || { printf 'desconhecida\n'; return 1; }
  while IFS='=' read -r key value; do
    if [[ "$key" == "PRETTY_NAME" ]]; then
      value="${value#\"}"
      value="${value%\"}"
      printf '%s\n' "$value"
      return 0
    fi
  done < /etc/os-release
  printf 'desconhecida\n'
  return 1
}

_system_memory_value_kb() {
  local field="${1:-}" key value remainder
  [[ -n "$field" && -r /proc/meminfo ]] || return 1
  while read -r key value remainder; do
    if [[ "$key" == "${field}:" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < /proc/meminfo
  return 1
}

_system_cpu_count() {
  if shellops_has_command nproc; then nproc
  elif shellops_has_command getconf; then getconf _NPROCESSORS_ONLN
  else printf 'desconhecido\n'; fi
}

_system_load_average() {
  if [[ -r /proc/loadavg ]]; then
    local load_1 load_5 load_15 remainder
    read -r load_1 load_5 load_15 remainder < /proc/loadavg
    printf '%s %s %s\n' "$load_1" "$load_5" "$load_15"
  elif shellops_has_command uptime; then uptime
  else printf 'indisponível\n'; fi
}

system_server_summary() {
  local os_name="desconhecida" os_key os_value

  _system_section "Identificação"
  if shellops_has_command hostname; then
    printf 'Hostname: %s\n' "$(hostname)"
  elif [[ -r /proc/sys/kernel/hostname ]]; then
    printf 'Hostname: '
    while IFS= read -r os_value; do printf '%s' "$os_value"; done < /proc/sys/kernel/hostname
    printf '\n'
  else
    _system_unavailable hostname
  fi

  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r os_key os_value; do
      if [[ "$os_key" == "PRETTY_NAME" ]]; then
        os_value="${os_value#\"}"
        os_value="${os_value%\"}"
        os_name="$os_value"
        break
      fi
    done < /etc/os-release
  fi
  printf 'Distribuição: %s\n' "$os_name"

  if shellops_has_command uname; then
    printf 'Kernel: %s\n' "$(uname -r)"
    printf 'Arquitetura: %s\n' "$(uname -m)"
  else
    _system_unavailable uname
  fi

  if shellops_has_command uptime; then
    printf 'Uptime: %s\n' "$(uptime -p 2>/dev/null || uptime)"
  else
    _system_unavailable uptime
  fi

  _system_section "Data e plataforma"
  if shellops_has_command date; then
    printf 'Data/hora: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Timezone: %s\n' "$(date '+%Z (%z)')"
  else
    _system_unavailable date
  fi

  if shellops_has_command systemd-detect-virt; then
    os_value="$(systemd-detect-virt 2>/dev/null || true)"
    printf 'Virtualização: %s\n' "${os_value:-não detectada}"
  else
    printf 'Virtualização: não detectável (systemd-detect-virt ausente)\n'
  fi

  printf 'CPUs lógicas: %s\n' "$(_system_cpu_count)"
  if shellops_has_command free && shellops_has_command awk; then
    free -h | awk 'NR == 2 {print "Memória total: " $2}'
  elif [[ -r /proc/meminfo ]] && shellops_has_command awk; then
    awk '/^MemTotal:/ {printf "Memória total: %.2f GiB\n", $2 / 1024 / 1024}' /proc/meminfo
  else
    printf 'Memória total: indisponível\n'
  fi
}

system_cpu_load() {
  local cpu_count load_values load_1 load_5 load_15

  _system_section "CPU"
  if shellops_has_command lscpu; then
    if shellops_has_command awk; then
      LC_ALL=C lscpu | awk -F: '
        /^(Architecture|CPU\(s\)|On-line CPU\(s\) list|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|Model name|CPU MHz|Virtualization):/ {
          key=$1; value=$2; sub(/^[[:space:]]+/, "", value); printf "%-24s %s\n", key ":", value
        }'
    else
      lscpu
    fi
  else
    _system_unavailable lscpu
  fi

  cpu_count="$(_system_cpu_count)"
  load_values="$(_system_load_average)"
  printf '\nCPUs lógicas: %s\n' "$cpu_count"
  printf 'Load average (1/5/15 min): %s\n' "$load_values"
  if shellops_is_non_negative_integer "$cpu_count" && [[ "$cpu_count" -gt 0 ]] && shellops_has_command awk; then
    read -r load_1 load_5 load_15 <<< "$load_values"
    if [[ "$load_1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      awk -v l1="$load_1" -v l5="$load_5" -v l15="$load_15" -v cpus="$cpu_count" \
        'BEGIN {printf "Load por CPU (1/5/15): %.2f %.2f %.2f\n", l1/cpus, l5/cpus, l15/cpus}'
    fi
  fi
  printf 'Observação: os valores são apresentados sem classificação automática.\n'

  _system_section "Snapshot de uso"
  if shellops_has_command mpstat; then
    mpstat 1 1
  elif shellops_has_command vmstat; then
    printf 'mpstat ausente; usando vmstat 1 2. A primeira linha representa média desde o boot.\n'
    vmstat 1 2
  elif shellops_has_command top && shellops_has_command head; then
    printf 'mpstat/vmstat ausentes; usando snapshot do top.\n'
    LC_ALL=C top -bn1 | head -n 5
  else
    printf 'Snapshot indisponível: mpstat, vmstat e top não encontrados.\n'
  fi
}

system_memory_swap() {
  _system_section "Memória e swap"
  if shellops_has_command free; then
    free -h
  elif [[ -r /proc/meminfo ]]; then
    while IFS= read -r line; do
      case "$line" in
        MemTotal:*|MemFree:*|MemAvailable:*|Buffers:*|Cached:*|SwapTotal:*|SwapFree:*) printf '%s\n' "$line" ;;
      esac
    done < /proc/meminfo
  else
    _system_unavailable free
  fi

  _system_section "vmstat curto"
  if shellops_has_command vmstat; then
    vmstat 1 2
    printf '\nNota: si/so representam entrada/saída de swap no intervalo; swap ocupada, isoladamente, não comprova pressão de memória.\n'
  else
    _system_unavailable vmstat
  fi
}

system_processes() {
  if ! shellops_has_command ps; then _system_unavailable ps; return 127; fi

  _system_section "Contagem"
  if shellops_has_command awk; then
    ps -e --no-headers | awk 'END {print "Processos: " NR}'
    ps -eLf --no-headers | awk 'END {print "Threads aproximadas (LWPs): " NR}'
  else
    printf 'Contagens indisponíveis: awk não encontrado.\n'
  fi

  _system_section "Top processos por CPU"
  if shellops_has_command head; then
    LC_ALL=C ps -eo pid,user,pcpu,pmem,args --sort=-pcpu | head -n 16
  else _system_unavailable head; fi

  _system_section "Top processos por memória"
  if shellops_has_command head; then
    LC_ALL=C ps -eo pid,user,pcpu,pmem,args --sort=-pmem | head -n 16
  else _system_unavailable head; fi
}

system_filesystems() {
  _system_section "Filesystems"
  if shellops_has_command df; then df -hT
  else _system_unavailable df; return 127; fi
}

system_inodes() {
  _system_section "Utilização de inodes"
  if shellops_has_command df; then df -i
  else _system_unavailable df; return 127; fi
}

system_block_devices() {
  _system_section "Block devices"
  if shellops_has_command lsblk; then lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MODEL
  else _system_unavailable lsblk; return 127; fi
}

_system_lvm_report() {
  local command_name="$1" label="$2" output status
  _system_section "$label"
  if ! shellops_has_command "$command_name"; then _system_unavailable "$command_name"; return 127; fi

  if output="$("$command_name" 2>&1)"; then
    if [[ -n "$output" ]]; then printf '%s\n' "$output"; else printf 'Nenhum item encontrado.\n'; fi
    return 0
  else
    status=$?
    printf 'Não foi possível consultar %s (código %d).\n' "$command_name" "$status"
    [[ -n "$output" ]] && printf '%s\n' "$output"
    return "$status"
  fi
}

system_lvm() {
  local status=0
  _system_lvm_report pvs "Physical Volumes (PVs)" || status=$?
  _system_lvm_report vgs "Volume Groups (VGs)" || status=$?
  _system_lvm_report lvs "Logical Volumes (LVs)" || status=$?
  if [[ "$status" -eq 127 ]]; then
    printf '\nAs ferramentas LVM não estão completamente disponíveis. Nenhuma instalação foi executada.\n'
  fi
  return "$status"
}

system_locale_time_ntp() {
  local locale_value lang_value lc_all_value timezone current_time ntp synchronization source stratum
  locale_value="$(locale 2>/dev/null | awk -F= '$1=="LANG" {gsub(/"/,"",$2); print $2; exit}')"
  lang_value="${LANG:-${locale_value:-N/A}}"
  lc_all_value="${LC_ALL:-N/A}"
  timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -n "$timezone" ]] || timezone="$(date +%Z 2>/dev/null || printf N/A)"
  current_time="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf N/A)"
  ntp=N/A; synchronization=N/A; source=N/A; stratum=N/A
  if shellops_has_command timedatectl; then
    ntp="$(timedatectl show -p NTP --value 2>/dev/null || printf N/A)"
    synchronization="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf N/A)"
  fi
  if shellops_has_command chronyc; then
    source="$(chronyc tracking 2>/dev/null | awk -F: '/Reference ID/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}')"
    stratum="$(chronyc tracking 2>/dev/null | awk -F: '/Stratum/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')"
    [[ -n "$source" ]] || source=N/A; [[ -n "$stratum" ]] || stratum=N/A
    ntp=Chrony
  elif shellops_has_command systemctl && systemctl is-active --quiet chronyd 2>/dev/null; then
    ntp='Chrony ativo; chronyc indisponível'
  fi
  printf 'Locale: %s\nLANG: %s\nLC_ALL: %s\nTimezone: %s\nCurrent time: %s\nNTP/Chrony: %s\nSynchronization: %s\nSource: %s\nStratum: %s\n' \
    "${locale_value:-N/A}" "$lang_value" "$lc_all_value" "$timezone" "$current_time" "$ntp" "$synchronization" "$source" "$stratum"
  printf '\nCONSULTA — nenhuma configuração de locale, timezone ou NTP foi alterada.\n'
}
