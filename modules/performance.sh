#!/usr/bin/env bash

_performance_section() {
  printf '\n=== %s ===\n' "$1"
}

_performance_requires_sysstat_command() {
  local command_name="${1:-}"
  if ! shellops_has_command "$command_name"; then
    printf 'Esta funcionalidade requer o comando %s, fornecido pelo pacote sysstat.\n' "$command_name" >&2
    printf 'Instalação sugerida (não executada): dnf install sysstat\n' >&2
    return 127
  fi
}

_performance_validate_sampling() {
  local interval="${1:-}" samples="${2:-}"
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ || ! "$samples" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Intervalo e amostras devem ser números inteiros maiores que zero.\n' >&2
    return 2
  fi
}

performance_overview() {
  _performance_section "Uptime e load average"
  if shellops_has_command uptime; then uptime; else printf 'uptime não encontrado.\n'; fi

  _performance_section "Memória e swap"
  if shellops_has_command free; then
    free -h
  elif [[ -r /proc/meminfo ]]; then
    while IFS= read -r line; do
      case "$line" in
        MemTotal:*|MemAvailable:*|SwapTotal:*|SwapFree:*) printf '%s\n' "$line" ;;
      esac
    done < /proc/meminfo
  else
    printf 'Informações de memória indisponíveis.\n'
  fi

  _performance_section "VMStat"
  if shellops_has_command vmstat; then
    vmstat 1 2
  else
    printf 'vmstat não encontrado.\n'
  fi

  _performance_section "CPU por processador"
  if shellops_has_command mpstat; then
    mpstat -P ALL 1 2
  else
    printf 'mpstat não encontrado; esta seção requer sysstat.\n'
  fi

  _performance_section "I/O de discos"
  if shellops_has_command iostat; then
    iostat -xz 1 2
  else
    printf 'iostat não encontrado; esta seção requer sysstat.\n'
  fi

  cat <<'EOF'

Legenda resumida:
  r/b       processos executáveis/bloqueados
  si/so     páginas lidas da/enviadas para swap no intervalo
  wa        tempo de CPU aguardando I/O
  st        tempo de CPU cedido pelo hypervisor
  await     latência média observada pelo dispositivo
  %util     tempo ocupado reportado; não é diagnóstico isolado

Os valores são evidências pontuais e não recebem classificação automática.
EOF
}

performance_cpu_interval() {
  local interval="${1:-}" samples="${2:-}"
  _performance_validate_sampling "$interval" "$samples" || return
  _performance_requires_sysstat_command mpstat || return
  printf 'CPU por intervalo — sem classificação automática.\n\n'
  mpstat -P ALL "$interval" "$samples"
}

performance_vmstat_interval() {
  local interval="${1:-}" samples="${2:-}"
  _performance_validate_sampling "$interval" "$samples" || return
  if ! shellops_has_command vmstat; then printf 'Comando vmstat não encontrado.\n' >&2; return 127; fi
  cat <<'EOF'
Colunas principais: r executáveis; b bloqueados; swpd swap ocupada; free memória
livre; buff/cache caches; si/so atividade de swap; bi/bo I/O em blocos;
us/sy/id/wa/st CPU em usuário, sistema, idle, I/O wait e steal.

Swap ocupada isoladamente não comprova pressão atual. Correlacione si/so,
MemAvailable, paginação e o contexto do workload.

EOF
  vmstat "$interval" "$samples"
}

performance_disk_io() {
  local interval="${1:-}" samples="${2:-}"
  _performance_validate_sampling "$interval" "$samples" || return
  _performance_requires_sysstat_command iostat || return
  cat <<'EOF'
Os cabeçalhos variam entre versões do sysstat. Observe em conjunto throughput,
await/r_await/w_await, tamanho de fila e %util. A interpretação depende do tipo
de dispositivo, workload, virtualização e backend de storage.

EOF
  iostat -xz "$interval" "$samples"
}

performance_process_cpu() {
  local interval="${1:-}" samples="${2:-}"
  _performance_validate_sampling "$interval" "$samples" || return
  _performance_requires_sysstat_command pidstat || return
  printf 'Atividade de CPU por processo — sem classificação automática.\n\n'
  pidstat -u "$interval" "$samples"
}

performance_process_io() {
  local interval="${1:-}" samples="${2:-}"
  _performance_validate_sampling "$interval" "$samples" || return
  _performance_requires_sysstat_command pidstat || return
  printf 'I/O por processo. As colunas disponíveis dependem da versão do sysstat.\n\n'
  pidstat -d "$interval" "$samples"
}

performance_history_files() {
  local history_dir candidate found=0
  _performance_requires_sysstat_command sar || return
  if ! shellops_has_command find; then printf 'Comando find não encontrado.\n' >&2; return 127; fi

  for history_dir in /var/log/sa /var/log/sysstat; do
    [[ -d "$history_dir" ]] || continue
    while IFS= read -r -d '' candidate; do
      if sar -u -f "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        found=1
      fi
    done < <(find "$history_dir" -maxdepth 1 -type f -size +0c -print0 2>/dev/null)
  done

  if [[ "$found" -eq 0 ]]; then
    printf 'sysstat está instalado, mas não existem dados históricos disponíveis\n' >&2
    return 1
  fi
}

performance_sar_history() {
  local history_file="${1:-}" report="${2:-}"
  _performance_requires_sysstat_command sar || return
  if [[ -z "$history_file" || ! -f "$history_file" || ! -r "$history_file" ]]; then
    printf 'Arquivo histórico inválido ou não legível.\n' >&2
    return 2
  fi

  case "$report" in
    cpu) sar -u -f "$history_file" ;;
    load) sar -q -f "$history_file" ;;
    memory) sar -r -f "$history_file" ;;
    swap)
      _performance_section "Espaço de swap"
      sar -S -f "$history_file"
      _performance_section "Atividade de swap"
      sar -W -f "$history_file"
      ;;
    io) sar -b -f "$history_file" ;;
    disks) sar -d -f "$history_file" ;;
    *) printf 'Tipo de relatório SAR inválido.\n' >&2; return 2 ;;
  esac
}

performance_sysstat_status() {
  local command_name history_output history_count=0 history_dir active_status enabled_status

  _performance_section "Pacote"
  if shellops_has_command rpm; then
    rpm -q sysstat 2>&1 || printf 'Pacote sysstat não identificado pelo RPM.\n'
  else
    printf 'rpm não encontrado; status do pacote indisponível.\n'
  fi

  _performance_section "Comandos"
  for command_name in sar mpstat pidstat iostat; do
    if shellops_has_command "$command_name"; then
      printf '%-8s disponível: %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '%-8s indisponível\n' "$command_name"
    fi
  done

  _performance_section "Histórico"
  for history_dir in /var/log/sa /var/log/sysstat; do
    [[ -d "$history_dir" ]] && printf 'Diretório presente: %s\n' "$history_dir"
  done
  if history_output="$(performance_history_files 2>/dev/null)"; then
    while IFS= read -r history_dir; do
      [[ -n "$history_dir" ]] || continue
      printf '%s\n' "$history_dir"
      history_count=$((history_count + 1))
    done <<< "$history_output"
    printf 'Arquivos históricos válidos: %d\n' "$history_count"
  elif shellops_has_command sar; then
    printf 'sysstat está instalado, mas não existem dados históricos disponíveis\n'
  else
    printf 'sysstat não está instalado\n'
  fi

  _performance_section "Coleta agendada (consulta somente leitura)"
  if shellops_has_command systemctl; then
    for command_name in sysstat sysstat-collect.timer sysstat-summary.timer; do
      active_status="$(systemctl is-active "$command_name" 2>/dev/null || true)"
      enabled_status="$(systemctl is-enabled "$command_name" 2>/dev/null || true)"
      printf '%-24s active=%s enabled=%s\n' "$command_name" \
        "${active_status:-não encontrado}" "${enabled_status:-não encontrado}"
    done
  else
    printf 'systemctl não encontrado; mecanismo tradicional pode estar em uso.\n'
  fi
  printf '\nNenhum serviço foi iniciado, habilitado ou alterado.\n'
}
