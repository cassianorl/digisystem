#!/usr/bin/env bash

SHELLOPS_TUI_TEMP_FILES=()

shellops_tui_cleanup() {
  local temporary_file

  for temporary_file in "${SHELLOPS_TUI_TEMP_FILES[@]}"; do
    [[ -n "$temporary_file" ]] && rm -f -- "$temporary_file"
  done
}

shellops_tui_show_output() {
  local title="$1"
  shift

  local output_file status dialog_status report_path report_result
  output_file="$(mktemp)" || return 1
  SHELLOPS_TUI_TEMP_FILES+=("$output_file")

  if "$@" >"$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi

  if [[ ! -s "$output_file" ]]; then
    printf 'Comando finalizado sem saída.\n' >"$output_file"
  fi

  dialog --title "$title" --exit-label "Voltar" \
    --extra-button --extra-label "Gerar HTML" --textbox "$output_file" 22 100
  dialog_status=$?

  if [[ "$dialog_status" -eq 3 ]]; then
    report_path="$(shellops_report_default_path "$title")"
    if report_result="$(shellops_generate_html_report "$title" "$output_file" "$report_path" "$status" 2>&1)"; then
      dialog --title "Relatório HTML gerado" --msgbox \
        "Relatório salvo em:\n\n$report_result" 10 90
    else
      dialog --title "Falha ao gerar relatório" --msgbox "$report_result" 10 90
    fi
  fi
  rm -f -- "$output_file"
  return "$status"
}

shellops_tui_show_program_output() {
  local title="$1"
  shift

  local status
  "$@" 2>&1 | dialog --title "$title" --exit-label "Voltar" \
    --programbox "A execução está em andamento. Aguarde a conclusão." 24 100
  status=${PIPESTATUS[0]}
  return "$status"
}

shellops_tui_select_file() {
  local title="$1"
  local start_path="${2:-$PWD/}"
  dialog --stdout --title "$title" --fselect "$start_path" 14 90
}

shellops_tui_certificates() {
  local pem_file
  pem_file="$(shellops_tui_select_file "Selecionar arquivo PEM")" || return 0
  [[ -n "$pem_file" ]] || return 0
  shellops_tui_show_output "Validação de PEM" certificates_validate_pem "$pem_file" || true
}

shellops_tui_reports() {
  local log_file threshold
  log_file="$(shellops_tui_select_file "Selecionar log de relatórios")" || return 0
  [[ -n "$log_file" ]] || return 0

  threshold="$(dialog --stdout --title "Limite" \
    --inputbox "Duração mínima, em segundos, para considerar um relatório lento:" 9 75 "30")" || return 0

  shellops_tui_show_output "Performance de relatórios" \
    reports_performance_check "$log_file" "$threshold" || true
}

shellops_tui_tasy_monitor() {
  dialog --title "Monitor de startup TASY" --yesno \
    "Esta opção reutiliza o monitor existente. Ela requer root, aguarda um container tasy-tasyappserver-* ficar healthy e grava a coleta em /root. Deseja continuar?" \
    11 82 || return 0

  if ! shellops_tui_show_program_output "Monitor de startup TASY" tasy_monitor_startup; then
    dialog --title "Monitor de startup TASY" --msgbox \
      "O monitor foi encerrado com erro. Consulte a saída apresentada para identificar a causa." \
      9 78
  fi
}

shellops_tui_system() {
  local option

  while true; do
    option="$(dialog --stdout --title "Diagnóstico do sistema - somente leitura" --menu \
      "Escolha uma coleta:" 21 82 10 \
      1 "Resumo do servidor" \
      2 "CPU e Load" \
      3 "Memória e Swap" \
      4 "Processos" \
      5 "Filesystems" \
      6 "Inodes" \
      7 "Block devices" \
      8 "LVM" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Resumo do servidor" system_server_summary || true ;;
      2) shellops_tui_show_output "CPU e Load" system_cpu_load || true ;;
      3) shellops_tui_show_output "Memória e Swap" system_memory_swap || true ;;
      4) shellops_tui_show_output "Processos" system_processes || true ;;
      5) shellops_tui_show_output "Filesystems" system_filesystems || true ;;
      6) shellops_tui_show_output "Inodes" system_inodes || true ;;
      7) shellops_tui_show_output "Block devices" system_block_devices || true ;;
      8) shellops_tui_show_output "LVM" system_lvm || true ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_sampling_parameters() {
  local interval samples
  interval="$(dialog --stdout --title "Intervalo" \
    --inputbox "Intervalo entre amostras, em segundos:" 8 65 "1")" || return 1
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || {
    dialog --title "Entrada inválida" --msgbox "O intervalo deve ser um inteiro maior que zero." 8 70
    return 2
  }
  samples="$(dialog --stdout --title "Amostras" \
    --inputbox "Quantidade de amostras:" 8 65 "5")" || return 1
  [[ "$samples" =~ ^[1-9][0-9]*$ ]] || {
    dialog --title "Entrada inválida" --msgbox "A quantidade deve ser um inteiro maior que zero." 8 70
    return 2
  }
  printf '%s %s\n' "$interval" "$samples"
}

shellops_tui_performance_history() {
  local history_output selected_index report
  local -a history_files=() menu_items=()

  if ! history_output="$(performance_history_files 2>&1)"; then
    dialog --title "Histórico SAR" --msgbox "$history_output" 9 82
    return 0
  fi
  mapfile -t history_files <<< "$history_output"
  for selected_index in "${!history_files[@]}"; do
    menu_items+=("$selected_index" "${history_files[$selected_index]}")
  done
  selected_index="$(dialog --stdout --title "Arquivo SAR" --menu \
    "Selecione o arquivo histórico:" 20 100 12 "${menu_items[@]}")" || return 0

  report="$(dialog --stdout --title "Consulta SAR" --menu \
    "Selecione a métrica:" 18 72 8 \
    cpu "CPU (sar -u)" load "Load (sar -q)" memory "Memória (sar -r)" \
    swap "Swap (sar -S e sar -W)" io "I/O (sar -b)" disks "Discos (sar -d)")" || return 0
  shellops_tui_show_output "Histórico SAR" performance_sar_history \
    "${history_files[$selected_index]}" "$report" || true
}

shellops_tui_performance_sampled() {
  local title="$1" function_name="$2" parameters interval samples
  parameters="$(shellops_tui_sampling_parameters)" || return 0
  read -r interval samples <<< "$parameters"
  shellops_tui_show_output "$title" "$function_name" "$interval" "$samples" || true
}

shellops_tui_service_unit() {
  local choice units_output selected_index
  local -a units=() menu_items=(manual "Informar nome da unit")

  if units_output="$(services_list_units 2>&1)"; then
    mapfile -t units <<< "$units_output"
    for selected_index in "${!units[@]}"; do
      menu_items+=("$selected_index" "${units[$selected_index]}")
    done
  fi

  choice="$(dialog --stdout --title "Unit systemd" --menu \
    "Selecione uma unit ou informe o nome:" 22 92 14 "${menu_items[@]}")" || return 1
  if [[ "$choice" == "manual" ]]; then
    dialog --stdout --title "Unit systemd" --inputbox "Nome da unit (ex.: sshd.service):" 8 72
  else
    printf '%s\n' "${units[$choice]}"
  fi
}

shellops_tui_journal_lines() {
  local lines
  lines="$(dialog --stdout --title "Quantidade de linhas" \
    --inputbox "Quantidade de mensagens recentes:" 8 68 "200")" || return 1
  [[ "$lines" =~ ^[1-9][0-9]*$ ]] || {
    dialog --title "Entrada inválida" --msgbox "A quantidade deve ser um inteiro maior que zero." 8 70
    return 2
  }
  printf '%s\n' "$lines"
}

shellops_tui_journal_period() {
  local allow_until="${1:-1}" period since until=""
  period="$(dialog --stdout --title "Período do journal" --menu \
    "Selecione a janela temporal:" 18 74 8 \
    15m "Últimos 15 minutos" 1h "Última hora" 6h "Últimas 6 horas" \
    24h "Últimas 24 horas" today "Hoje" custom "Período personalizado")" || return 1
  case "$period" in
    15m) since="15 minutes ago" ;;
    1h) since="1 hour ago" ;;
    6h) since="6 hours ago" ;;
    24h) since="24 hours ago" ;;
    today) since="today" ;;
    custom)
      since="$(dialog --stdout --title "Início" \
        --inputbox "Valor compatível com journalctl --since:" 9 78 "1 hour ago")" || return 1
      [[ -n "$since" ]] || return 1
      if [[ "$allow_until" -eq 1 ]]; then
        until="$(dialog --stdout --title "Fim" \
          --inputbox "Valor para --until (vazio = agora):" 9 78 "")" || return 1
      fi
      ;;
  esac
  printf '%s|%s\n' "$since" "$until"
}

shellops_tui_services_status() {
  local unit
  unit="$(shellops_tui_service_unit)" || return 0
  [[ -n "$unit" ]] || return 0
  shellops_tui_show_output "Status: $unit" services_status "$unit" || true
}

shellops_tui_services_journal() {
  local unit lines
  unit="$(shellops_tui_service_unit)" || return 0
  [[ -n "$unit" ]] || return 0
  lines="$(shellops_tui_journal_lines)" || return 0
  shellops_tui_show_output "Journal: $unit" services_journal "$unit" "$lines" || true
}

shellops_tui_services_period() {
  local values since until
  values="$(shellops_tui_journal_period)" || return 0
  IFS='|' read -r since until <<< "$values"
  shellops_tui_show_output "Journal por período" services_journal_period "$since" "$until" || true
}

shellops_tui_services_recent() {
  local values since until
  values="$(shellops_tui_journal_period 0)" || return 0
  IFS='|' read -r since until <<< "$values"
  shellops_tui_show_output "Eventos recentes" services_recent_events "$since" || true
}

shellops_tui_services_kernel() {
  local values since until lines
  values="$(shellops_tui_journal_period 0)" || return 0
  IFS='|' read -r since until <<< "$values"
  lines="$(shellops_tui_journal_lines)" || return 0
  shellops_tui_show_output "Mensagens do kernel" services_kernel_messages "$since" "$lines" || true
}

shellops_tui_network_target() {
  dialog --stdout --title "Destino" --inputbox "Hostname ou endereço IP:" 8 72
}

shellops_tui_network_interface() {
  local output choice
  local -a interfaces=() menu_items=(all "Todas as interfaces")
  output="$(network_interface_names 2>&1)" || {
    dialog --title "Interfaces" --msgbox "$output" 8 78
    return 1
  }
  mapfile -t interfaces <<< "$output"
  for choice in "${!interfaces[@]}"; do menu_items+=("$choice" "${interfaces[$choice]}"); done
  choice="$(dialog --stdout --title "Interface" --menu \
    "Selecione uma interface:" 20 78 12 "${menu_items[@]}")" || return 1
  if [[ "$choice" == all ]]; then printf '\n'; else printf '%s\n' "${interfaces[$choice]}"; fi
}

shellops_tui_network_interfaces() {
  local choice interface
  choice="$(dialog --stdout --title "Interfaces" --menu "Escolha a visualização:" 12 72 4 \
    brief "Resumo de todas as interfaces" detail "Detalhes de uma interface")" || return 0
  if [[ "$choice" == brief ]]; then
    shellops_tui_show_output "Interfaces" network_interfaces || true
  else
    interface="$(shellops_tui_network_interface)" || return 0
    [[ -n "$interface" ]] || return 0
    shellops_tui_show_output "Interface: $interface" network_interface_details "$interface" || true
  fi
}

shellops_tui_network_routes() {
  local choice destination
  choice="$(dialog --stdout --title "Rotas" --menu "Escolha a consulta:" 12 72 4 \
    all "Todas as rotas" get "Rota para um destino")" || return 0
  if [[ "$choice" == all ]]; then
    shellops_tui_show_output "Rotas" network_routes || true
  else
    destination="$(shellops_tui_network_target)" || return 0
    [[ -n "$destination" ]] || return 0
    shellops_tui_show_output "Rota para $destination" network_route_get "$destination" || true
  fi
}

shellops_tui_network_dns() {
  local choice destination detailed=0
  choice="$(dialog --stdout --title "DNS" --menu "Escolha a consulta:" 13 76 5 \
    status "Configuração DNS" resolve "Resolver hostname" detailed "Resolução detalhada")" || return 0
  if [[ "$choice" == status ]]; then
    shellops_tui_show_output "Configuração DNS" network_dns_status || true
    return 0
  fi
  destination="$(shellops_tui_network_target)" || return 0
  [[ -n "$destination" ]] || return 0
  [[ "$choice" == detailed ]] && detailed=1
  shellops_tui_show_output "Resolução: $destination" network_resolve "$destination" "$detailed" || true
}

shellops_tui_network_sockets() {
  local mode
  mode="$(dialog --stdout --title "Portas e sockets" --menu "Escolha a consulta:" 15 76 6 \
    tcp-listen "TCP em LISTEN" udp "Sockets UDP" established "TCP estabelecidas" summary "Resumo geral")" || return 0
  shellops_tui_show_output "Portas e sockets" network_sockets "$mode" || true
}

shellops_tui_network_ping() {
  local destination count
  destination="$(shellops_tui_network_target)" || return 0
  [[ -n "$destination" ]] || return 0
  count="$(dialog --stdout --title "Ping" --inputbox "Quantidade de pacotes (1 a 100):" 8 68 "4")" || return 0
  [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 && "$count" -le 100 ]] || {
    dialog --title "Entrada inválida" --msgbox "A quantidade deve estar entre 1 e 100." 8 68
    return 0
  }
  shellops_tui_show_output "Ping: $destination" network_ping "$destination" "$count" || true
}

shellops_tui_network_tcp() {
  local destination port
  destination="$(shellops_tui_network_target)" || return 0
  [[ -n "$destination" ]] || return 0
  port="$(dialog --stdout --title "Conectividade TCP" --inputbox "Porta TCP (1 a 65535):" 8 68)" || return 0
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
    dialog --title "Entrada inválida" --msgbox "A porta deve estar entre 1 e 65535." 8 68
    return 0
  }
  shellops_tui_show_output "TCP: $destination:$port" network_tcp_test "$destination" "$port" || true
}

shellops_tui_network_trace() {
  local destination
  destination="$(shellops_tui_network_target)" || return 0
  [[ -n "$destination" ]] || return 0
  shellops_tui_show_output "Rota até $destination" network_trace "$destination" || true
}

shellops_tui_network_stats() {
  local interface include_ethtool=0
  interface="$(shellops_tui_network_interface)" || return 0
  if [[ -n "$interface" ]] && dialog --title "ethtool" --yesno \
    "Incluir estatísticas read-only do driver com ethtool -S, se disponível?" 9 76; then
    include_ethtool=1
  fi
  shellops_tui_show_output "Estatísticas de interfaces" \
    network_interface_stats "$interface" "$include_ethtool" || true
}

shellops_tui_diagnostics_performance() {
  local option

  while true; do
    option="$(dialog --stdout --title "Diagnósticos - Performance" --menu \
      "Coletas e amostragens para investigação" 20 88 9 \
      1 "Visão geral de performance" \
      2 "CPU por intervalo" \
      3 "Memória / VMStat" \
      4 "I/O de discos" \
      5 "Processos por CPU" \
      6 "Processos por I/O" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Visão geral de performance" performance_overview || true ;;
      2) shellops_tui_performance_sampled "CPU por intervalo" performance_cpu_interval ;;
      3) shellops_tui_performance_sampled "Memória / VMStat" performance_vmstat_interval ;;
      4) shellops_tui_performance_sampled "I/O de discos" performance_disk_io ;;
      5) shellops_tui_performance_sampled "Processos por CPU" performance_process_cpu ;;
      6) shellops_tui_performance_sampled "Processos por I/O" performance_process_io ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_diagnostics_services() {
  local option

  while true; do
    option="$(dialog --stdout --title "Diagnósticos - Serviços e logs" --menu \
      "Evidências para investigação de falhas" 19 88 8 \
      1 "Serviços com falha" \
      2 "Eventos warning até alert" \
      3 "Journal por período" \
      4 "Mensagens do kernel" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Serviços com falha" services_failed || true ;;
      2) shellops_tui_services_recent ;;
      3) shellops_tui_services_period ;;
      4) shellops_tui_services_kernel ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_diagnostics_network() {
  local option destination detailed

  while true; do
    option="$(dialog --stdout --title "Diagnósticos - Rede" --menu \
      "Testes ativos e evidências de conectividade" 20 88 9 \
      1 "Conectividade ICMP" \
      2 "Conectividade TCP" \
      3 "Rota até o destino" \
      4 "Resolução detalhada de hostname" \
      5 "Estatísticas de interfaces" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_network_ping ;;
      2) shellops_tui_network_tcp ;;
      3) shellops_tui_network_trace ;;
      4)
        destination="$(shellops_tui_network_target)" || continue
        [[ -n "$destination" ]] || continue
        detailed=1
        shellops_tui_show_output "Resolução: $destination" \
          network_resolve "$destination" "$detailed" || true
        ;;
      5) shellops_tui_network_stats ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_read_performance() {
  local option

  while true; do
    option="$(dialog --stdout --title "Consultas - Performance" --menu \
      "Histórico e disponibilidade das ferramentas" 15 88 6 \
      1 "Histórico SAR" \
      2 "Disponibilidade do sysstat" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_performance_history ;;
      2) shellops_tui_show_output "Disponibilidade do sysstat" performance_sysstat_status || true ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_read_services() {
  local option

  while true; do
    option="$(dialog --stdout --title "Consultas - Serviços e logs" --menu \
      "Estado atual e leitura do journal" 18 88 8 \
      1 "Status de um serviço" \
      2 "Serviços em execução" \
      3 "Serviços habilitados" \
      4 "Journal de um serviço" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_services_status ;;
      2) shellops_tui_show_output "Serviços em execução" services_running || true ;;
      3) shellops_tui_show_output "Serviços habilitados" services_enabled || true ;;
      4) shellops_tui_services_journal ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_read_network() {
  local option

  while true; do
    option="$(dialog --stdout --title "Consultas - Rede" --menu \
      "Configuração, inventário e estado atual" 20 88 9 \
      1 "Resumo de rede" \
      2 "Interfaces" \
      3 "Rotas" \
      4 "Configuração DNS" \
      5 "Portas e sockets" \
      6 "ARP / Neighbor table" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Resumo de rede" network_overview || true ;;
      2) shellops_tui_network_interfaces ;;
      3) shellops_tui_network_routes ;;
      4) shellops_tui_network_dns ;;
      5) shellops_tui_network_sockets ;;
      6) shellops_tui_show_output "ARP / Neighbor table" network_neighbors || true ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_select_target() {
  local source_filter="${1:-}" records_output choice index
  local source type name image state health pid metadata description
  local -a records=() menu_items=()

  records_output="$(discovery_records)"
  [[ -n "$records_output" ]] || {
    dialog --title "Selecionar alvo" --msgbox "Nenhum alvo foi detectado." 8 72
    return 1
  }
  while IFS= read -r choice; do
    IFS='|' read -r source type name image state health pid metadata <<< "$choice"
    [[ -z "$source_filter" || "$source" == "$source_filter" ]] || continue
    records+=("$choice")
    index=$((${#records[@]} - 1))
    description="[$source/$type] $name"
    [[ -n "$state" ]] && description+=" — $state"
    menu_items+=("$index" "$description")
  done <<< "$records_output"
  (( ${#records[@]} > 0 )) || {
    dialog --title "Selecionar alvo" --msgbox "Nenhum alvo compatível foi detectado." 8 72
    return 1
  }
  choice="$(dialog --stdout --title "Selecionar alvo" --menu \
    "Selecione o componente que será analisado:" 23 104 15 "${menu_items[@]}")" || return 1
  IFS='|' read -r source type name image state health pid metadata <<< "${records[$choice]}"
  discovery_target_set "$source" "$type" "$name" "$image" "$state" "$health" "$pid" "$metadata"
  dialog --title "Alvo selecionado" --msgbox \
    "Source: $SHELLOPS_TARGET_SOURCE\nTipo: $SHELLOPS_TARGET_TYPE\nNome: $SHELLOPS_TARGET_NAME" 10 84
}

shellops_tui_diagnose_selected_target() {
  [[ -n "$SHELLOPS_TARGET_SOURCE" ]] || shellops_tui_select_target || return 0
  shellops_tui_show_output "Diagnóstico: $SHELLOPS_TARGET_NAME" discovery_diagnose_target || true
}

shellops_tui_diagnostic_menu_v1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Diagnóstico" --menu \
      "Descoberta e diagnóstico genérico — CONSULTA" 18 90 8 \
      1 "Detectar ambiente" 2 "Selecionar alvo" 3 "Diagnosticar alvo" \
      4 "Quick Health Check" 5 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Descoberta de ambiente" discovery_environment_summary || true ;;
      2) shellops_tui_select_target || true ;;
      3) shellops_tui_diagnose_selected_target ;;
      4) shellops_tui_show_output "Quick Health Check" health_quick_check || true ;;
      5) return 0 ;;
    esac
  done
}

shellops_tui_docker_select_container() {
  shellops_tui_select_target docker
}

shellops_tui_docker_diagnose_v3() {
  shellops_tui_docker_select_container || return 0
  shellops_tui_show_output "Diagnóstico: $SHELLOPS_TARGET_NAME" docker_diagnose_container \
    "$SHELLOPS_TARGET_NAME" "$SHELLOPS_TARGET_TYPE" || true
}

shellops_tui_docker_logs_v3() {
  local lines since
  shellops_tui_docker_select_container || return 0
  lines="$(shellops_tui_log_lines)" || return 0
  since="$(dialog --stdout --title "Período opcional" \
    --inputbox "Since (vazio = últimas linhas; exemplo: 1h):" 8 76)" || return 0
  if [[ -n "$since" ]]; then
    shellops_tui_show_output "Logs: $SHELLOPS_TARGET_NAME" docker_show_logs_since \
      "$SHELLOPS_TARGET_NAME" "$lines" "$since" || true
  else
    shellops_tui_show_output "Logs: $SHELLOPS_TARGET_NAME" docker_show_logs \
      "$SHELLOPS_TARGET_NAME" "$lines" || true
  fi
}

shellops_tui_docker_performance_v3() {
  local option parameters interval samples
  option="$(dialog --stdout --title "Performance / Stats" --menu \
    "Coleta finita e somente de leitura" 14 82 5 \
    1 "Snapshot atual de todos os containers" \
    2 "Amostragem curta de um container" \
    3 "Voltar")" || return 0
  case "$option" in
    1) shellops_tui_show_output "Docker stats" docker_show_stats || true ;;
    2)
      shellops_tui_docker_select_container || return 0
      parameters="$(shellops_tui_sampling_parameters)" || return 0
      read -r interval samples <<< "$parameters"
      [[ "$interval" -le 60 && "$samples" -le 60 ]] || {
        dialog --title "Limite" --msgbox "Intervalo e amostras devem ser no máximo 60." 8 72
        return 0
      }
      shellops_tui_show_program_output "Stats: $SHELLOPS_TARGET_NAME" docker_stats_summary \
        "$SHELLOPS_TARGET_NAME" "$interval" "$samples" || true
      ;;
  esac
}

shellops_tui_docker_disk_v3() {
  shellops_tui_docker_select_container || return 0
  shellops_tui_show_output "Uso de disco: $SHELLOPS_TARGET_NAME" docker_container_disk_usage \
    "$SHELLOPS_TARGET_NAME" || true
}

shellops_tui_docker_mounts_v3() {
  local output choice index type source destination mode
  local -a volumes=() menu_items=()
  shellops_tui_docker_select_container || return 0
  output="$(docker_container_mounts "$SHELLOPS_TARGET_NAME" 2>&1)" || {
    dialog --title "Volumes / Mounts" --msgbox "$output" 10 88
    return 0
  }
  shellops_tui_show_output "Volumes / Mounts: $SHELLOPS_TARGET_NAME" docker_container_mounts \
    "$SHELLOPS_TARGET_NAME" || true
  while IFS='|' read -r type source destination mode; do
    [[ "$type" == volume ]] || continue
    volumes+=("$source")
    index=$((${#volumes[@]} - 1))
    menu_items+=("$index" "$source → $destination ($mode)")
  done <<< "$output"
  (( ${#volumes[@]} > 0 )) || return 0
  dialog --title "Volumes Docker" --yesno "Deseja consultar metadados seguros de um volume nomeado?" 8 78 || return 0
  choice="$(dialog --stdout --title "Selecionar volume" --menu "Volumes associados:" \
    18 90 10 "${menu_items[@]}")" || return 0
  shellops_tui_show_output "Volume: ${volumes[$choice]}" docker_volume_metadata "${volumes[$choice]}" || true
}

shellops_tui_docker_network_v3() {
  local records choice index host_ip host_port container_port test_host
  local -a bindings=() menu_items=()
  shellops_tui_docker_select_container || return 0
  shellops_tui_show_output "Portas / Rede: $SHELLOPS_TARGET_NAME" docker_container_network \
    "$SHELLOPS_TARGET_NAME" || true
  records="$(docker_published_port_records "$SHELLOPS_TARGET_NAME" 2>/dev/null)" || return 0
  [[ -n "$records" ]] || return 0
  while IFS= read -r choice; do
    bindings+=("$choice"); index=$((${#bindings[@]} - 1))
    IFS='|' read -r host_ip host_port container_port <<< "$choice"
    menu_items+=("$index" "${host_ip:-0.0.0.0}:$host_port → $container_port")
  done <<< "$records"
  dialog --title "Teste opcional" --yesno "Deseja testar uma única porta publicada?" 8 72 || return 0
  choice="$(dialog --stdout --title "Porta publicada" --menu "Selecione o binding:" \
    18 84 10 "${menu_items[@]}")" || return 0
  IFS='|' read -r host_ip host_port container_port <<< "${bindings[$choice]}"
  case "$host_ip" in ""|0.0.0.0|::) test_host=127.0.0.1 ;; *) test_host="$host_ip" ;; esac
  shellops_tui_show_output "TCP: $test_host:$host_port" network_tcp_test "$test_host" "$host_port" || true
}

shellops_tui_docker_health_v3() {
  shellops_tui_docker_select_container || return 0
  shellops_tui_show_output "Healthcheck: $SHELLOPS_TARGET_NAME" docker_healthcheck_details \
    "$SHELLOPS_TARGET_NAME" || true
}

shellops_tui_docker_startup_v3() {
  local interval timeout
  shellops_tui_docker_select_container || return 0
  interval="$(dialog --stdout --title "Intervalo" \
    --inputbox "Intervalo de observação em segundos (1 a 60):" 8 72 "2")" || return 0
  timeout="$(dialog --stdout --title "Timeout obrigatório" \
    --inputbox "Timeout total em segundos (1 a 86400):" 8 72 "600")" || return 0
  [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 60 && "$timeout" =~ ^[1-9][0-9]*$ && "$timeout" -le 86400 ]] || {
    dialog --title "Entrada inválida" --msgbox "Intervalo ou timeout inválido." 8 70
    return 0
  }
  dialog --title "Monitor passivo" --yesno \
    "O ShellOps apenas observará $SHELLOPS_TARGET_NAME por até ${timeout}s. Nenhum start, stop ou restart será executado. Continuar?" \
    10 84 || return 0
  shellops_tui_show_program_output "Startup: $SHELLOPS_TARGET_NAME" docker_monitor_startup \
    "$SHELLOPS_TARGET_NAME" "$interval" "$timeout" || true
}

shellops_tui_docker_cleanup_v3() {
  shellops_tui_docker_select_container || return 0
  dialog --title "Análise de limpeza — CONSULTA" --yesno \
    "Serão medidos paths e arquivos segundo critérios legados do script de manutenção existente. Eles não são recomendações oficiais Philips/Tasy e nada será removido. Continuar?" \
    12 88 || return 0
  shellops_tui_show_program_output "Análise de limpeza: $SHELLOPS_TARGET_NAME" \
    docker_cleanup_analysis "$SHELLOPS_TARGET_NAME" || true
}

shellops_tui_docker_applications_v3() {
  local output choice index type count
  local -a types=() menu_items=()
  output="$(docker_application_groups 2>&1)" || { dialog --title "Aplicações detectadas" --msgbox "$output" 9 82; return 0; }
  [[ -n "$output" ]] || { dialog --title "Aplicações detectadas" --msgbox "Nenhum container detectado." 8 72; return 0; }
  while IFS='|' read -r type count; do
    types+=("$type"); index=$((${#types[@]} - 1)); menu_items+=("$index" "$type — $count")
  done <<< "$output"
  choice="$(dialog --stdout --title "Aplicações detectadas" --menu \
    "Classificação heurística; Generic permanece visível:" 20 88 12 "${menu_items[@]}")" || return 0
  shellops_tui_show_output "Instâncias: ${types[$choice]}" docker_application_instances "${types[$choice]}" || true
}

shellops_tui_docker_menu_v1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Docker / Containers" --menu \
      "Troubleshooting Docker — somente CONSULTA" 27 98 17 \
      1 "Containers em execução" 2 "Todos os containers" 3 "Imagens disponíveis" \
      4 "Aplicações detectadas" 5 "Diagnosticar container" 6 "Logs" \
      7 "Performance / Stats" 8 "Uso de disco" 9 "Volumes / Mounts" \
      10 "Portas / Rede" 11 "Healthcheck" 12 "Monitorar startup" \
      13 "Analisar limpeza" 14 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Containers em execução" docker_list_running_containers || true ;;
      2) shellops_tui_show_output "Todos os containers" docker_list_all_containers || true ;;
      3) shellops_tui_show_output "Imagens disponíveis" docker_image_inventory || true ;;
      4) shellops_tui_docker_applications_v3 ;;
      5) shellops_tui_docker_diagnose_v3 ;;
      6) shellops_tui_docker_logs_v3 ;;
      7) shellops_tui_docker_performance_v3 ;;
      8) shellops_tui_docker_disk_v3 ;;
      9) shellops_tui_docker_mounts_v3 ;;
      10) shellops_tui_docker_network_v3 ;;
      11) shellops_tui_docker_health_v3 ;;
      12) shellops_tui_docker_startup_v3 ;;
      13) shellops_tui_docker_cleanup_v3 ;;
      14) return 0 ;;
    esac
  done
}

shellops_tui_storage_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Storage / LVM" --menu "Consultas de armazenamento" 17 82 8 \
      1 "Filesystems" 2 "Inodes" 3 "Block devices" 4 "LVM" 5 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Filesystems" system_filesystems || true ;;
      2) shellops_tui_show_output "Inodes" system_inodes || true ;;
      3) shellops_tui_show_output "Block devices" system_block_devices || true ;;
      4) shellops_tui_show_output "LVM" system_lvm || true ;;
      5) return 0 ;;
    esac
  done
}

shellops_tui_performance_menu_v1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Performance" --menu "Consultas e amostragens existentes" 15 88 6 \
      1 "Coletas e amostragens" 2 "Histórico SAR e sysstat" 3 "Voltar")" || return 0
    case "$option" in 1) shellops_tui_diagnostics_performance ;; 2) shellops_tui_read_performance ;; 3) return 0 ;; esac
  done
}

shellops_tui_services_menu_v1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Serviços e Logs" --menu "Consultas existentes" 15 88 6 \
      1 "Status e journal" 2 "Diagnóstico de falhas" 3 "Voltar")" || return 0
    case "$option" in 1) shellops_tui_read_services ;; 2) shellops_tui_diagnostics_services ;; 3) return 0 ;; esac
  done
}

shellops_tui_network_menu_v1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Rede" --menu "Consultas e testes existentes" 15 88 6 \
      1 "Inventário e estado" 2 "Testes e diagnóstico" 3 "Voltar")" || return 0
    case "$option" in 1) shellops_tui_read_network ;; 2) shellops_tui_diagnostics_network ;; 3) return 0 ;; esac
  done
}

shellops_tui_samba_provision() {
  local script status
  script="$(shellops_legacy_script install/provisionamento_samba.sh)" || return 0
  [[ -f "$script" ]] || { dialog --title "Samba" --msgbox "FAILED — script não encontrado: $script" 9 88; return 0; }
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { dialog --title "Samba" --msgbox "FAILED — o provisionamento Samba exige root." 8 76; return 0; }
  dialog --title "Provisionar Samba TASY [ALTERAÇÃO]" --yesno \
    "Script: install/provisionamento_samba.sh\n\nFinalidade: provisionar share Samba para TASY.\nServiços: smb e nmb.\nArquivos principais: /etc/samba/smb.conf e /etc/samba/smbusers.\nImpactos: instala pacotes; cria usuário/grupo e diretórios; altera permissões; configura share; ajusta SELinux e firewalld quando aplicável; reinicia serviços.\n\nO script é interativo. Nenhuma senha será exibida pelo ShellOps. Informe uma senha forte; no legado, deixar o campo vazio usa o nome do usuário como senha. Deseja continuar?" \
    21 98 || return 0
  dialog --title "Confirmação forte — ALTERAÇÃO" --yesno \
    "CONFIRME A ALTERAÇÃO NO HOST.\n\nConfiguração Samba existente poderá ser substituída após backup, usuários/grupos poderão ser criados e serviços serão reiniciados.\n\nExecutar agora?" \
    14 92 || return 0
  clear
  printf 'ShellOps — Provisionar Samba TASY [ALTERAÇÃO]\nScript: %s\n\n' "$script"
  bash "$script"; status=$?
  printf '\nProvisionamento finalizado com status %s. Pressione Enter para retornar ao ShellOps.' "$status"
  read -r || true
  return 0
}

shellops_tui_linux_tools_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Ferramentas Linux" --menu \
      "Funções genéricas preservadas como apoio operacional" 23 96 12 \
      1 "Sistema" 2 "Performance" 3 "Serviços e Logs" 4 "Rede" \
      5 "Storage / LVM" 6 "Provisionar Samba TASY [ALTERAÇÃO]" \
      7 "Locale / Time / NTP [CONSULTA]" 8 "Dependências" 9 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_system ;; 2) shellops_tui_performance_menu_v1 ;;
      3) shellops_tui_services_menu_v1 ;; 4) shellops_tui_network_menu_v1 ;;
      5) shellops_tui_storage_menu ;; 6) shellops_tui_samba_provision ;;
      7) shellops_tui_show_output "Locale / Time / NTP" system_locale_time_ntp || true ;;
      8) shellops_tui_show_output "Dependências ShellOps" shellops_dependencies_inventory || true ;;
      9) return 0 ;;
    esac
  done
}

shellops_tui_tasy_components() {
  local groups choice index type count instances selected action name image state health
  local -a types=() menu_items=() records=()
  groups="$(tasy_component_groups 2>&1)" || { dialog --title "Componentes TASY" --msgbox "$groups" 10 84; return 0; }
  [[ -n "$groups" ]] || { dialog --title "Componentes TASY" --msgbox "Nenhum container detectado." 8 72; return 0; }
  while IFS='|' read -r type count; do types+=("$type"); index=$((${#types[@]}-1)); menu_items+=("$index" "$type — $count"); done <<< "$groups"
  choice="$(dialog --stdout --title "Aplicações / componentes" --menu \
    "Classificação heurística; componentes genéricos não são ocultados:" 20 92 12 "${menu_items[@]}")" || return 0
  type="${types[$choice]}"; menu_items=(); instances="$(tasy_component_instances "$type")" || return 0
  while IFS= read -r selected; do
    records+=("$selected"); index=$((${#records[@]}-1)); IFS='|' read -r name image state health <<< "$selected"
    menu_items+=("$index" "$name — $state/$health")
  done <<< "$instances"
  choice="$(dialog --stdout --title "Instâncias: $type" --menu "Selecione uma instância:" 20 94 12 "${menu_items[@]}")" || return 0
  IFS='|' read -r name image state health <<< "${records[$choice]}"
  discovery_target_set docker "$type" "$name" "$image" "$state" "$health" "" ""
  action="$(dialog --stdout --title "Ação" --menu "Reutilizar recurso existente:" 15 88 6 \
    diagnose "Diagnóstico Docker genérico" monitor "Monitor de startup genérico" legacy "Monitor legado TASY [gera coleta]")" || return 0
  case "$action" in
    diagnose) shellops_tui_show_output "Diagnóstico: $name" docker_diagnose_container "$name" "$type" || true ;;
    monitor) shellops_tui_docker_startup_v3 ;;
    legacy) shellops_tui_tasy_monitor ;;
  esac
}

shellops_tui_tasy_ha() {
  local option
  option="$(dialog --stdout --title "HAProxy / Keepalived" --menu "Diagnósticos independentes e opcionais:" 15 84 6 \
    1 "HAProxy" 2 "Keepalived" 3 "Voltar")" || return 0
  case "$option" in
    1) shellops_tui_show_output "HAProxy" tasy_haproxy_status || true ;;
    2) shellops_tui_show_output "Keepalived" tasy_keepalived_status || true ;;
  esac
}

shellops_tui_tasy_datasource() {
  local endpoint host port
  shellops_tui_show_output "Banco / Datasource" tasy_datasource_summary || true
  endpoint="$(tasy_datasource_endpoint 2>/dev/null)" || return 0
  IFS='|' read -r host port <<< "$endpoint"
  dialog --title "Teste TCP opcional" --yesno \
    "Datasource detectado em $host:$port. Deseja executar somente um teste TCP?" 9 80 || return 0
  shellops_tui_show_output "Datasource TCP: $host:$port" network_tcp_test "$host" "$port" || true
}

shellops_tui_tasy_log_source() {
  local output choice index source value description
  local -a records=() menu_items=()
  output="$(tasy_known_log_sources 2>&1)" || { dialog --title "Logs TASY" --msgbox "$output" 9 84; return 1; }
  [[ -n "$output" ]] || { dialog --title "Logs TASY" --msgbox "Nenhuma fonte de log conhecida foi confirmada." 8 78; return 1; }
  while IFS= read -r choice; do records+=("$choice"); index=$((${#records[@]}-1)); IFS='|' read -r source value description <<< "$choice"; menu_items+=("$index" "[$source] $description — $value"); done <<< "$output"
  choice="$(dialog --stdout --title "Fonte de log" --menu "Selecione uma fonte confirmada:" 20 100 12 "${menu_items[@]}")" || return 1
  printf '%s\n' "${records[$choice]}"
}

shellops_tui_tasy_logs() {
  local record source value description action lines text limit since until
  record="$(shellops_tui_tasy_log_source)" || return 0
  IFS='|' read -r source value description <<< "$record"
  action="$(dialog --stdout --title "Operação de log" --menu "Somente leitura:" 17 82 8 \
    tail "Últimas linhas" search "Busca literal" errors "Erros comuns" period "Período")" || return 0
  case "$action" in
    tail)
      lines="$(shellops_tui_log_lines)" || return 0
      if [[ "$source" == systemd ]]; then shellops_tui_show_output "$description" services_journal "$value" "$lines" || true
      else shellops_tui_show_output "$description" logs_tail "$value" "$lines" || true; fi ;;
    search)
      text="$(dialog --stdout --title "Busca literal" --inputbox "Texto:" 8 76)" || return 0; [[ -n "$text" ]] || return 0
      limit="$(dialog --stdout --title "Limite" --inputbox "Máximo de resultados:" 8 68 "200")" || return 0
      if [[ "$source" == systemd ]]; then
        shellops_tui_show_output "$description" tasy_journal_search "$value" "$text" "$limit" || true
      else shellops_tui_show_output "$description" logs_search_text "$value" "$text" "$limit" || true; fi ;;
    errors)
      if [[ "$source" == systemd ]]; then shellops_tui_show_output "$description" tasy_journal_common_errors "$value" || true
      else shellops_tui_show_output "$description" logs_common_errors "$value" 40 1 || true; fi ;;
    period)
      since="$(dialog --stdout --title "Início" --inputbox "Since (journal ou YYYY-MM-DD HH:MM:SS):" 8 80)" || return 0
      until="$(dialog --stdout --title "Fim" --inputbox "Until (vazio = agora/sem limite):" 8 80)" || return 0
      if [[ "$source" == systemd ]]; then shellops_tui_show_output "$description" services_journal_period "$since" "$until" "$value" || true
      else shellops_tui_show_output "$description" logs_search_period "$value" "$since" "$until" || true; fi ;;
  esac
}

shellops_tui_tasy_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "TASY / AppManager" --menu \
      "Diagnóstico e validação — CONSULTA" 26 98 15 \
      1 "Detectar ambiente TASY" 2 "Aplicações / componentes" \
      3 "Status do AppManager" 4 "Diagnosticar AppManager" \
      5 "Configurações" 6 "HAProxy / Keepalived" \
      7 "Banco / Datasource" 8 "Logs" 9 "JMX" \
      10 "Validar ambiente" 11 "Preparar instalação [DRY-RUN]" \
      12 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Ambiente TASY" tasy_environment_summary || true ;;
      2) shellops_tui_tasy_components ;;
      3) shellops_tui_show_output "Status AppManager" tasy_appmanager_status || true ;;
      4) shellops_tui_show_output "Diagnóstico AppManager" tasy_appmanager_diagnose || true ;;
      5) shellops_tui_show_output "Configurações permitidas" tasy_safe_configurations || true ;;
      6) shellops_tui_tasy_ha ;;
      7) shellops_tui_tasy_datasource ;;
      8) shellops_tui_tasy_logs ;;
      9) shellops_tui_show_output "JMX AppManager" tasy_jmx_status || true ;;
      10) shellops_tui_show_output "Checklist TASY / AppManager" tasy_validate_environment || true ;;
      11) shellops_tui_show_output "Preparar instalação — DRY-RUN" tasy_installation_dry_run || true ;;
      12) return 0 ;;
    esac
  done
}

shellops_tui_tie_select_docker() {
  local output record choice index source type name image state health pid metadata
  local -a records=() menu_items=()
  output="$(tie_environment_records)"
  while IFS= read -r record; do
    IFS='|' read -r source type name image state health pid metadata <<< "$record"
    [[ "$source" == docker ]] || continue
    records+=("$record"); index=$((${#records[@]} - 1))
    menu_items+=("$index" "[$type] $name - ${state:-N/A}/${health:-N/A}")
  done <<< "$output"
  (( ${#records[@]} > 0 )) || { dialog --title "Componentes TIE" --msgbox "Nenhum container TIE foi confirmado." 8 76; return 1; }
  choice="$(dialog --stdout --title "Componentes TIE" --menu "Selecione um container confirmado:" 21 100 13 "${menu_items[@]}")" || return 1
  IFS='|' read -r source type name image state health pid metadata <<< "${records[$choice]}"
  discovery_target_set "$source" "$type" "$name" "$image" "$state" "$health" "$pid" "$metadata"
}

shellops_tui_tie_components() {
  shellops_tui_show_output "Componentes TIE" tie_component_inventory || true
  dialog --title "Componentes TIE" --yesno "Deseja diagnosticar um container com o diagnostico Docker seguro existente?" 9 84 || return 0
  shellops_tui_tie_select_docker || return 0
  shellops_tui_show_output "Diagnostico: $SHELLOPS_TARGET_NAME" docker_diagnose_container "$SHELLOPS_TARGET_NAME" "$SHELLOPS_TARGET_TYPE" || true
}

shellops_tui_tie_connectivity() {
  local host port
  shellops_tui_show_output "Conectividade / Portas" tie_connectivity_summary || true
  dialog --title "Teste TCP opcional" --yesno "Deseja testar um destino e uma porta especificos? Nao sera feita varredura." 9 82 || return 0
  host="$(dialog --stdout --title "Destino" --inputbox "Hostname ou IP confirmado:" 8 72)" || return 0
  port="$(dialog --stdout --title "Porta" --inputbox "Porta TCP:" 8 64)" || return 0
  shellops_tui_show_output "Teste TCP: $host:$port" tie_connectivity_summary "$host" "$port" || true
}

shellops_tui_tie_interfaces() {
  local action host port
  action="$(dialog --stdout --title "Tasy Interfaces" --menu "Elementos do legado so sao considerados quando detectados:" 15 92 6 \
    1 "Diagnostico consultivo" 2 "Healthcheck em endpoint confirmado" 3 "Voltar")" || return 0
  case "$action" in
    1) shellops_tui_show_output "Tasy Interfaces" tie_tasy_interfaces_status || true ;;
    2)
      host="$(dialog --stdout --title "Host confirmado" --inputbox "Host/IP do Tasy Interfaces:" 8 76)" || return 0
      port="$(dialog --stdout --title "Porta confirmada" --inputbox "Porta HTTP:" 8 66)" || return 0
      dialog --title "Healthcheck consultivo" --yesno "Executar GET em:\nhttp://$host:$port/tasy-interfaces/resources/healthcheck\n\nHTTP 2xx indica somente sucesso tecnico de transporte." 12 88 || return 0
      shellops_tui_show_output "Healthcheck Tasy Interfaces" tie_tasy_interfaces_health "$host" "$port" || true
      ;;
  esac
}

shellops_tui_tie_mongodb() {
  local action hours
  action="$(dialog --stdout --title "MongoDB" --menu "Todas as opcoes sao estritamente CONSULTA:" 16 88 7 \
    1 "Status / tamanho / contagens" 2 "Analise de retencao (sem remocao)" 3 "Voltar")" || return 0
  case "$action" in
    1) shellops_tui_show_output "MongoDB TIE" tie_mongodb_status || true ;;
    2)
      hours="$(dialog --stdout --title "Criterio legado" --inputbox "Retencao em horas para simulacao:" 9 76 "48")" || return 0
      shellops_tui_show_output "MongoDB - analise sem remocao" tie_mongodb_retention_analysis "$hours" || true
      ;;
  esac
}

shellops_tui_tie_event_search() {
  local event_name integration_id patient_id message_id since limit
  event_name="$(dialog --stdout --title "Busca de evento" --inputbox "eventName (opcional):" 8 76)" || return 0
  integration_id="$(dialog --stdout --title "Busca de evento" --inputbox "integrationId (opcional):" 8 76)" || return 0
  patient_id="$(dialog --stdout --title "Busca de evento" --inputbox "patientId (opcional):" 8 76)" || return 0
  message_id="$(dialog --stdout --title "Busca de evento" --inputbox "messageId (opcional):" 8 76)" || return 0
  [[ -n "$event_name$integration_id$patient_id$message_id" ]] || { dialog --title "Busca de evento" --msgbox "Informe ao menos um criterio literal." 8 72; return 0; }
  since="$(dialog --stdout --title "Periodo opcional" --inputbox "Since para logs Docker (ex.: 1h; vazio = amostra atual):" 9 84)" || return 0
  limit="$(dialog --stdout --title "Limite" --inputbox "Maximo de evidencias:" 8 68 "200")" || return 0
  shellops_tui_show_program_output "Evidencias de integracao / evento" tie_event_search \
    "$event_name" "$integration_id" "$patient_id" "$message_id" "$since" "$limit" || true
}

shellops_tui_tie_log_source() {
  local output record choice index source value component
  local -a records=() menu_items=()
  output="$(tie_known_log_sources)"
  while IFS= read -r record; do
    IFS='|' read -r source value component <<< "$record"
    [[ "$source" == docker || "$source" == file ]] || continue
    records+=("$record"); index=$((${#records[@]} - 1)); menu_items+=("$index" "[$source] $component - $value")
  done <<< "$output"
  (( ${#records[@]} > 0 )) || { dialog --title "Logs TIE" --msgbox "Nenhuma fonte de log segura foi confirmada." 8 78; return 1; }
  choice="$(dialog --stdout --title "Logs TIE" --menu "Selecione uma fonte confirmada:" 20 102 12 "${menu_items[@]}")" || return 1
  printf '%s\n' "${records[$choice]}"
}

shellops_tui_tie_logs() {
  local record source value component action lines since
  record="$(shellops_tui_tie_log_source)" || return 0
  IFS='|' read -r source value component <<< "$record"
  action="$(dialog --stdout --title "Logs TIE" --menu "Somente leitura; nenhuma fonte arbitraria e coletada:" 16 88 7 \
    tail "Ultimas linhas" period "Periodo Docker"  back "Voltar")" || return 0
  case "$action" in
    tail)
      lines="$(shellops_tui_log_lines)" || return 0
      if [[ "$source" == docker ]]; then shellops_tui_show_output "Fonte: docker:$value" docker_show_logs "$value" "$lines" || true
      else shellops_tui_show_output "Fonte: arquivo:$value" logs_tail "$value" "$lines" || true; fi ;;
    period)
      [[ "$source" == docker ]] || { dialog --title "Periodo" --msgbox "Para arquivo confirmado, use Logs e Coletas > Buscar por periodo." 8 82; return 0; }
      since="$(dialog --stdout --title "Since" --inputbox "Periodo Docker (ex.: 1h):" 8 70)" || return 0
      lines="$(shellops_tui_log_lines)" || return 0
      shellops_tui_show_output "Fonte: docker:$value" docker_show_logs_since "$value" "$lines" "$since" || true ;;
  esac
}

shellops_tui_tie_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "TIE / Integracoes" --menu \
      "Descoberta, diagnostico e evidencias - CONSULTA" 28 102 17 \
      1 "Detectar ambiente TIE" 2 "Componentes / Containers" 3 "Status geral" \
      4 "Conectividade / Portas" 5 "Tasy Interfaces" 6 "RabbitMQ" 7 "MongoDB" \
      8 "Elasticsearch / Kibana" 9 "Buscar integracao / evento" 10 "Logs" \
      11 "Validar ambiente" 12 "Preparar instalacao [DRY-RUN]" 13 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Ambiente TIE" tie_environment_summary || true ;;
      2) shellops_tui_tie_components ;;
      3) shellops_tui_show_output "Status geral TIE" tie_status_summary || true ;;
      4) shellops_tui_tie_connectivity ;;
      5) shellops_tui_tie_interfaces ;;
      6) shellops_tui_show_program_output "RabbitMQ" tie_rabbitmq_status || true ;;
      7) shellops_tui_tie_mongodb ;;
      8) shellops_tui_show_output "Elastic Stack / Keycloak" tie_elastic_stack_status || true ;;
      9) shellops_tui_tie_event_search ;;
      10) shellops_tui_tie_logs ;;
      11) shellops_tui_show_output "Checklist TIE" tie_validate_environment || true ;;
      12) shellops_tui_show_output "Instalacao TIE - DRY-RUN" tie_installation_dry_run || true ;;
      13) return 0 ;;
    esac
  done
}

shellops_tui_java_select_target() {
  local output record choice index source type name image state health pid metadata label display_pid
  local -a records=() menu_items=()
  output="$(java_jvm_records 2>&1)" || { dialog --title "JVM" --msgbox "$output" 10 88; return 1; }
  [[ -n "$output" ]] || { dialog --title "JVM" --msgbox "Nenhuma JVM foi detectada." 8 72; return 1; }
  while IFS= read -r record; do
    IFS='|' read -r source type name image state health pid metadata <<< "$record"
    [[ "$source" == process || "$source" == docker ]] || continue
    display_pid="${pid:-N/A}"; [[ "$source" == docker && "$metadata" =~ java_pid=([0-9]+) ]] && display_pid="${BASH_REMATCH[1]} interno"
    records+=("$record"); index=$((${#records[@]} - 1)); menu_items+=("$index" "[$source/$type] PID $display_pid - $name")
  done <<< "$output"
  (( ${#records[@]} > 0 )) || return 1
  choice="$(dialog --stdout --title "Selecionar JVM" --menu "Selecione o target JVM:" 22 104 14 "${menu_items[@]}")" || return 1
  IFS='|' read -r source type name image state health pid metadata <<< "${records[$choice]}"
  discovery_target_set "$source" "$type" "$name" "$image" "$state" "$health" "$pid" "$metadata"
}

shellops_tui_java_run_for_target() {
  local title="$1" function_name="$2"
  shellops_tui_java_select_target || return 0
  shellops_tui_show_output "$title: $SHELLOPS_TARGET_NAME" "$function_name" || true
}

shellops_tui_java_ports() {
  local host port
  shellops_tui_java_select_target || return 0
  shellops_tui_show_output "Portas JVM" java_ports_summary || true
  dialog --title "Teste TCP opcional" --yesno "Deseja testar um host e porta confirmados? Não será feita varredura." 9 84 || return 0
  host="$(dialog --stdout --title "Destino" --inputbox "Hostname ou IP:" 8 72)" || return 0
  port="$(dialog --stdout --title "Porta" --inputbox "Porta TCP:" 8 64)" || return 0
  shellops_tui_show_output "TCP $host:$port" network_tcp_test "$host" "$port" || true
}

shellops_tui_java_log_source() {
  local output record choice index source value description
  local -a records=() menu_items=()
  output="$(java_known_log_sources 2>&1)"
  while IFS= read -r record; do
    IFS='|' read -r source value description <<< "$record"
    case "$source" in file|docker|systemd) ;; *) continue ;; esac
    records+=("$record"); index=$((${#records[@]} - 1)); menu_items+=("$index" "[$source] $description - $value")
  done <<< "$output"
  (( ${#records[@]} > 0 )) || { dialog --title "Logs Java" --msgbox "Nenhuma fonte segura foi confirmada." 8 76; return 1; }
  choice="$(dialog --stdout --title "Logs Java / Tomcat" --menu "Selecione uma fonte confirmada:" 20 104 12 "${menu_items[@]}")" || return 1
  printf '%s\n' "${records[$choice]}"
}

shellops_tui_java_logs() {
  local record source value description action lines text limit since until
  shellops_tui_java_select_target || return 0; record="$(shellops_tui_java_log_source)" || return 0
  IFS='|' read -r source value description <<< "$record"
  action="$(dialog --stdout --title "Logs Java / Tomcat" --menu "Somente fontes confirmadas:" 17 88 8 \
    tail "Últimas linhas" search "Busca literal" errors "Erros comuns" period "Período" back "Voltar")" || return 0
  case "$action" in
    tail) lines="$(shellops_tui_log_lines)" || return 0; shellops_tui_show_output "$description" java_log_tail "$source" "$value" "$lines" || true ;;
    search)
      text="$(dialog --stdout --title "Busca literal" --inputbox "Texto:" 8 76)" || return 0
      limit="$(dialog --stdout --title "Limite" --inputbox "Máximo de resultados:" 8 68 "200")" || return 0
      shellops_tui_show_output "$description" java_log_search "$source" "$value" "$text" "$limit" || true ;;
    errors) shellops_tui_show_output "$description" java_log_errors "$source" "$value" || true ;;
    period)
      since="$(dialog --stdout --title "Início" --inputbox "Since / YYYY-MM-DD HH:MM:SS:" 8 78)" || return 0
      until="$(dialog --stdout --title "Fim opcional" --inputbox "Until (vazio = sem limite/agora):" 8 76)" || return 0
      shellops_tui_show_output "$description" java_log_period "$source" "$value" "$since" "$until" || true ;;
  esac
}

shellops_tui_java_thread_dump() {
  local action destination file
  shellops_tui_java_select_target || return 0
  action="$(dialog --stdout --title "Thread Dump" --menu "Escolha a classe de operação:" 17 94 8 \
    view "Visualizar temporariamente [CONSULTA]" save "Salvar arquivo [ALTERAÇÃO LOCAL]" analyze "Analisar arquivo existente" back "Voltar")" || return 0
  case "$action" in
    view)
      dialog --title "Dados sensíveis" --yesno "O dump pode conter SQL, URLs, usuários, dados de aplicação, dados clínicos, tokens e outros dados presentes nas stacks.\n\nSerá apenas visualizado temporariamente e não irá para o Support Bundle. Continuar?" 15 92 || return 0
      shellops_tui_show_program_output "Thread Dump - consulta" java_thread_dump view || true ;;
    save)
      dialog --title "ALTERAÇÃO LOCAL / ARTEFATO" --yesno "Será criado um arquivo local com permissão restritiva quando possível.\n\nEle pode conter SQL, URLs, nomes de usuários, dados de aplicação, dados clínicos, tokens e outros dados sensíveis. Não será incluído no Support Bundle. Continuar?" 16 94 || return 0
      destination="$(dialog --stdout --title "Destino" --dselect "$PWD/" 14 92)" || return 0
      shellops_tui_show_output "Salvar thread dump" java_thread_dump save "$destination" || true ;;
    analyze)
      file="$(shellops_tui_select_file "Selecionar thread dump")" || return 0
      shellops_tui_show_output "Resumo do thread dump" java_thread_dump_analyze "$file" || true ;;
  esac
}

shellops_tui_java_heap_prepare() {
  local destination
  shellops_tui_java_select_target || return 0
  if [[ "$SHELLOPS_TARGET_SOURCE" == docker ]]; then
    destination="$(dialog --stdout --title "Path no container" --inputbox "Diretório absoluto existente dentro do container:" 9 84 "/tmp")" || return 0
  else destination="$(dialog --stdout --title "Filesystem destino" --dselect "$PWD/" 14 92)" || return 0; fi
  dialog --title "Heap Dump [PREPARAR]" --msgbox "Nenhum heap dump será gerado. A avaliação é conservadora; incerteza resulta em WARNING." 9 86
  shellops_tui_show_output "Preparação de heap dump" java_heap_dump_prepare "$destination" || true
}

shellops_tui_java_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Java / Tomcat" --menu \
      "Diagnóstico consultivo de JVMs e Tomcat" 28 102 17 \
      1 "JVMs detectadas" 2 "Diagnosticar JVM" 3 "Memória / Heap" 4 "Threads" \
      5 "JMX" 6 "Tomcat" 7 "Portas / Conectividade" 8 "GC / OOM" 9 "Logs" \
      10 "Thread Dump" 11 "Heap Dump [PREPARAR]" 12 "Validar ambiente" 13 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "JVMs detectadas" java_jvm_inventory || true ;;
      2) shellops_tui_java_run_for_target "Diagnóstico JVM" java_jvm_summary ;;
      3) shellops_tui_java_run_for_target "Memória / Heap" java_memory_summary ;;
      4) shellops_tui_java_run_for_target "Threads" java_threads_summary ;;
      5) shellops_tui_java_run_for_target "JMX" java_jmx_summary ;;
      6) shellops_tui_java_run_for_target "Tomcat" java_tomcat_summary ;;
      7) shellops_tui_java_ports ;;
      8) shellops_tui_java_run_for_target "GC / OOM" java_gc_oom_summary ;;
      9) shellops_tui_java_logs ;;
      10) shellops_tui_java_thread_dump ;;
      11) shellops_tui_java_heap_prepare ;;
      12) shellops_tui_java_run_for_target "Checklist Java / Tomcat" java_validate_environment ;;
      13) return 0 ;;
    esac
  done
}

shellops_tui_oracle_select_alias() {
  local output record choice index file alias status host port kind service
  local -a records=() menu_items=()
  output="$(oracle_tns_alias_records 2>&1)"
  while IFS= read -r record; do
    IFS='|' read -r file alias status host port kind service <<< "$record"
    [[ -n "$alias" ]] || continue; records+=("$record"); index=$((${#records[@]} - 1))
    menu_items+=("$index" "$alias - $status - $host:$port/$service")
  done <<< "$output"
  (( ${#records[@]} > 0 )) || { dialog --title "Oracle TNS" --msgbox "Nenhum alias TNS foi inventariado." 8 76; return 1; }
  choice="$(dialog --stdout --title "Alias Oracle" --menu "Descriptors complexos podem ser usados sem serem interpretados:" 22 104 14 "${menu_items[@]}")" || return 1
  IFS='|' read -r file alias status host port kind service <<< "${records[$choice]}"; printf '%s\n' "$alias"
}

shellops_tui_oracle_credentials() {
  set +x
  SHELLOPS_ORACLE_ALIAS="${1:-}"
  [[ -n "$SHELLOPS_ORACLE_ALIAS" ]] || SHELLOPS_ORACLE_ALIAS="$(shellops_tui_oracle_select_alias)" || return 1
  SHELLOPS_ORACLE_USER="$(dialog --stdout --title "Usuário Oracle" --inputbox "Usuário para sessão read-only:" 8 76)" || return 1
  SHELLOPS_ORACLE_PASSWORD="$(dialog --stdout --title "Senha Oracle" --passwordbox "Senha (não será persistida ou exibida):" 9 78)" || { unset SHELLOPS_ORACLE_USER; return 1; }
  [[ -n "$SHELLOPS_ORACLE_USER" && -n "$SHELLOPS_ORACLE_PASSWORD" ]] || { unset SHELLOPS_ORACLE_USER SHELLOPS_ORACLE_PASSWORD SHELLOPS_ORACLE_ALIAS; return 1; }
}

shellops_tui_oracle_forget_credentials() {
  unset SHELLOPS_ORACLE_USER SHELLOPS_ORACLE_PASSWORD SHELLOPS_ORACLE_ALIAS
}

shellops_tui_oracle_sql_action() {
  set +x
  local title="$1" function_name="$2" prefix="${3:-}" suffix="${4:-}"
  shellops_tui_oracle_credentials || return 0
  if [[ -n "$prefix" ]]; then
    shellops_tui_show_program_output "$title" "$function_name" "$prefix" "$SHELLOPS_ORACLE_USER" "$SHELLOPS_ORACLE_PASSWORD" "$SHELLOPS_ORACLE_ALIAS" "$suffix" || true
  else
    shellops_tui_show_program_output "$title" "$function_name" "$SHELLOPS_ORACLE_USER" "$SHELLOPS_ORACLE_PASSWORD" "$SHELLOPS_ORACLE_ALIAS" || true
  fi
  shellops_tui_oracle_forget_credentials
}

shellops_tui_oracle_connectivity() {
  set +x
  local action host port alias include_sql
  action="$(dialog --stdout --title "Conectividade Oracle" --menu "Testes independentes e consultivos:" 19 96 10 \
    tcp "TCP host:port" tnsping "TNSping de alias" sql "Login SQL read-only" listener "Listener LOCAL" ora12516 "Evidências ORA-12516" back "Voltar")" || return 0
  case "$action" in
    tcp)
      host="$(dialog --stdout --title "Host" --inputbox "Host/IP Oracle:" 8 72)" || return 0
      port="$(dialog --stdout --title "Porta" --inputbox "Porta TCP:" 8 64 "1521")" || return 0
      shellops_tui_show_output "TCP Oracle $host:$port" oracle_tcp_test "$host" "$port" || true ;;
    tnsping)
      alias="$(shellops_tui_oracle_select_alias)" || return 0
      shellops_tui_show_program_output "TNSping $alias" oracle_tnsping "$alias" || true ;;
    sql) shellops_tui_oracle_sql_action "Login SQL read-only" oracle_sql_login_test ;;
    listener)
      action="$(dialog --stdout --title "Listener LOCAL" --menu "Nunca executa start/stop/reload:" 14 82 5 status "lsnrctl status" services "lsnrctl services" back "Voltar")" || return 0
      [[ "$action" == back ]] || shellops_tui_show_program_output "Listener Oracle LOCAL" oracle_listener_status "$action" || true ;;
    ora12516)
      alias="$(shellops_tui_oracle_select_alias)" || return 0
      host="$(dialog --stdout --title "Host" --inputbox "Host/IP do serviço:" 8 72)" || return 0
      port="$(dialog --stdout --title "Porta" --inputbox "Porta TCP:" 8 64 "1521")" || return 0
      if dialog --title "SQL opcional" --yesno "Deseja incluir processes/sessions usando login SQL read-only?" 8 82; then
        shellops_tui_oracle_credentials "$alias" || return 0
        shellops_tui_show_program_output "Evidências ORA-12516" oracle_ora12516_evidence "$host" "$port" "$alias" "$SHELLOPS_ORACLE_USER" "$SHELLOPS_ORACLE_PASSWORD" || true
        shellops_tui_oracle_forget_credentials
      else shellops_tui_show_program_output "Evidências ORA-12516" oracle_ora12516_evidence "$host" "$port" "$alias" || true; fi ;;
  esac
}

shellops_tui_oracle_invalid_objects() {
  local mode limit="100"
  mode="$(dialog --stdout --title "Objetos inválidos" --menu "Nenhum objeto será compilado:" 14 84 5 summary "Contagem por tipo" detail "Listagem limitada" back "Voltar")" || return 0
  [[ "$mode" == back ]] && return 0
  if [[ "$mode" == detail ]]; then limit="$(dialog --stdout --title "Limite" --inputbox "Máximo de objetos:" 8 68 "100")" || return 0; fi
  shellops_tui_oracle_sql_action "Objetos inválidos" oracle_invalid_objects "$mode" "$limit"
}

shellops_tui_oracle_bifrost() {
  set +x
  local mode event_name message_id since until limit
  mode="$(dialog --stdout --title "BIFROST_LAYER_LOG" --menu "Query fixa read-only:" 15 92 6 minimal "Campos mínimos" detail "Conteúdo detalhado [SENSÍVEL]" back "Voltar")" || return 0
  [[ "$mode" == back ]] && return 0
  if [[ "$mode" == detail ]]; then
    dialog --title "Conteúdo sensível" --yesno "DS_CONTENT, DS_RESULT, DS_MESSAGE_ERROR e DS_CALL_STACK podem conter dados clínicos, identificadores de paciente, payloads completos, dados do sistema destino e outras informações sensíveis.\n\nContinuar?" 15 94 || return 0
  fi
  event_name="$(dialog --stdout --title "Filtro" --inputbox "NM_EVENT (opcional, máximo 256 bytes):" 8 82)" || return 0
  message_id="$(dialog --stdout --title "Filtro" --inputbox "DS_MESSAGE_ID (opcional, máximo 256 bytes):" 8 82)" || return 0
  since="$(dialog --stdout --title "Início" --inputbox "YYYY-MM-DD HH:MM:SS (opcional):" 8 78)" || return 0
  until="$(dialog --stdout --title "Fim" --inputbox "YYYY-MM-DD HH:MM:SS (opcional):" 8 78)" || return 0
  limit="$(dialog --stdout --title "Limite" --inputbox "Máximo de linhas (1-500):" 8 70 "100")" || return 0
  shellops_tui_oracle_credentials || return 0
  shellops_tui_show_program_output "BIFROST_LAYER_LOG - $mode" oracle_bifrost_layer_log_search "$mode" "$SHELLOPS_ORACLE_USER" "$SHELLOPS_ORACLE_PASSWORD" "$SHELLOPS_ORACLE_ALIAS" "$event_name" "$message_id" "$since" "$until" "$limit" || true
  shellops_tui_oracle_forget_credentials; unset event_name message_id
}

shellops_tui_oracle_checklist() {
  shellops_tui_show_output "Checklist Oracle local" oracle_validate_environment || true
  dialog --title "Checklist SQL opcional" --yesno "Deseja adicionar um teste de login SQL read-only?" 8 80 || return 0
  shellops_tui_oracle_credentials || return 0
  shellops_tui_show_program_output "Checklist Oracle com SQL" oracle_validate_environment "$SHELLOPS_ORACLE_USER" "$SHELLOPS_ORACLE_PASSWORD" "$SHELLOPS_ORACLE_ALIAS" || true
  shellops_tui_oracle_forget_credentials
}

shellops_tui_oracle_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Oracle / Conectividade" --menu \
      "Diagnóstico Oracle e conectividade TASY - CONSULTA" 28 104 17 \
      1 "Detectar Oracle Client" 2 "TNS / Aliases" 3 "Testar conectividade" \
      4 "Informações do banco" 5 "Parâmetros TASY" 6 "Processes / Sessions" \
      7 "Cursores / Jobs" 8 "Tablespaces" 9 "Objetos inválidos" 10 "NLS / Charset" \
      11 "TIE / BIFROST_LAYER_LOG" 12 "Validar ambiente" 13 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Oracle Client" oracle_client_summary || true ;;
      2) shellops_tui_show_output "TNS / Aliases" oracle_tns_summary || true ;;
      3) shellops_tui_oracle_connectivity ;;
      4) shellops_tui_oracle_sql_action "Informações do banco" oracle_database_info ;;
      5) shellops_tui_oracle_sql_action "Parâmetros TASY" oracle_tasy_parameters ;;
      6) shellops_tui_oracle_sql_action "Processes / Sessions" oracle_resource_limits ;;
      7) shellops_tui_oracle_sql_action "Cursores / Jobs" oracle_cursors_jobs ;;
      8) shellops_tui_oracle_sql_action "Tablespaces" oracle_tablespaces ;;
      9) shellops_tui_oracle_invalid_objects ;;
      10) shellops_tui_oracle_sql_action "NLS / Charset" oracle_nls_summary ;;
      11) shellops_tui_oracle_bifrost ;;
      12) shellops_tui_oracle_checklist ;;
      13) return 0 ;;
    esac
  done
}

shellops_tui_log_lines() {
  local lines
  lines="$(dialog --stdout --title "Quantidade de linhas" \
    --inputbox "Quantidade máxima de linhas:" 8 68 "200")" || return 1
  [[ "$lines" =~ ^[1-9][0-9]*$ ]] || {
    dialog --title "Entrada inválida" --msgbox "Informe um inteiro maior que zero." 8 68
    return 2
  }
  printf '%s\n' "$lines"
}

shellops_tui_logs_tail() {
  local log_file lines
  log_file="$(shellops_tui_select_file "Selecionar arquivo de log")" || return 0
  [[ -n "$log_file" ]] || return 0
  lines="$(shellops_tui_log_lines)" || return 0
  shellops_tui_show_output "Últimas linhas" logs_tail "$log_file" "$lines" || true
}

shellops_tui_logs_search_text() {
  local log_file text limit
  log_file="$(shellops_tui_select_file "Selecionar arquivo de log")" || return 0
  [[ -n "$log_file" ]] || return 0
  text="$(dialog --stdout --title "Busca literal" \
    --inputbox "Texto a localizar (não é expressão regular):" 9 78)" || return 0
  [[ -n "$text" ]] || return 0
  limit="$(dialog --stdout --title "Limite" \
    --inputbox "Máximo de resultados:" 8 66 "200")" || return 0
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || {
    dialog --title "Entrada inválida" --msgbox "Informe um limite inteiro maior que zero." 8 70
    return 0
  }
  shellops_tui_show_output "Busca literal em log" logs_search_text "$log_file" "$text" "$limit" || true
}

shellops_tui_logs_common_errors() {
  local log_file limit context
  log_file="$(shellops_tui_select_file "Selecionar arquivo de log")" || return 0
  [[ -n "$log_file" ]] || return 0
  limit="$(dialog --stdout --title "Limite" \
    --inputbox "Máximo de linhas por amostra:" 8 68 "40")" || return 0
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || {
    dialog --title "Entrada inválida" --msgbox "Informe um limite inteiro maior que zero." 8 70
    return 0
  }
  context="$(dialog --stdout --title "Contexto" \
    --inputbox "Linhas de contexto por ocorrência (0 a 5):" 8 70 "1")" || return 0
  [[ "$context" =~ ^[0-5]$ ]] || {
    dialog --title "Entrada inválida" --msgbox "O contexto deve estar entre zero e cinco." 8 70
    return 0
  }
  shellops_tui_show_output "Evidências de erros comuns" logs_common_errors \
    "$log_file" "$limit" "$context" || true
}

shellops_tui_logs_period() {
  local log_file since until
  log_file="$(shellops_tui_select_file "Selecionar arquivo de log")" || return 0
  [[ -n "$log_file" ]] || return 0
  since="$(dialog --stdout --title "Início" \
    --inputbox "Timestamp inicial (YYYY-MM-DD HH:MM:SS):" 8 76)" || return 0
  [[ -n "$since" ]] || return 0
  until="$(dialog --stdout --title "Fim" \
    --inputbox "Timestamp final (vazio = sem limite):" 8 76)" || return 0
  shellops_tui_show_output "Log por período" logs_search_period "$log_file" "$since" "$until" || true
}

shellops_tui_logs_find_large() {
  local start_dir minimum_mb limit
  start_dir="$(dialog --stdout --title "Diretório inicial" --dselect "$PWD/" 14 90)" || return 0
  [[ -n "$start_dir" ]] || return 0
  minimum_mb="$(dialog --stdout --title "Tamanho mínimo" \
    --inputbox "Tamanho mínimo em MiB:" 8 66 "100")" || return 0
  limit="$(dialog --stdout --title "Limite" \
    --inputbox "Máximo de arquivos exibidos:" 8 66 "30")" || return 0
  shellops_tui_show_output "Logs e arquivos grandes" logs_find_large \
    "$start_dir" "$minimum_mb" "$limit" || true
}

shellops_tui_logs_target() {
  local lines since="" until=""
  [[ -n "$SHELLOPS_TARGET_SOURCE" ]] || shellops_tui_select_target || return 0
  lines="$(shellops_tui_log_lines)" || return 0
  if [[ "$SHELLOPS_TARGET_SOURCE" == docker || "$SHELLOPS_TARGET_SOURCE" == systemd ]]; then
    since="$(dialog --stdout --title "Período opcional" \
      --inputbox "Since (vazio = últimas linhas; exemplos: 1h ou 2026-08-20 10:00:00):" 9 88)" || return 0
  fi
  if [[ "$SHELLOPS_TARGET_SOURCE" == systemd && -n "$since" ]]; then
    until="$(dialog --stdout --title "Fim opcional" \
      --inputbox "Until (vazio = agora):" 8 76)" || return 0
  fi
  shellops_tui_show_output "Logs: $SHELLOPS_TARGET_NAME" logs_target "$lines" "$since" "$until" || true
}

shellops_tui_support_bundle() {
  local default_destination destination
  default_destination="$(collections_default_destination)" || default_destination="$PWD"
  destination="$(dialog --stdout --title "Destino da coleta" \
    --dselect "$default_destination/" 14 90)" || return 0
  [[ -n "$destination" ]] || return 0
  dialog --title "Gerar coleta de suporte" --yesno \
    "Será criado um arquivo .tar.gz em:\n\n$destination\n\nA coleta contém diagnósticos estruturados e metadados. Logs de aplicação, credenciais, Config.Env e arquivos de certificados não serão incluídos. Continuar?" \
    15 88 || return 0
  shellops_tui_show_program_output "Gerar coleta de suporte" \
    collections_generate_support_bundle "$destination" || true
}

shellops_tui_logs_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Logs e Coletas" --menu \
      "Leitura e coleta de evidências — CONSULTA" 23 94 13 \
      1 "Últimas linhas de um log" \
      2 "Buscar texto em log" \
      3 "Buscar erros comuns" \
      4 "Buscar por período" \
      5 "Localizar logs grandes" \
      6 "Logs de alvo selecionado" \
      7 "Performance TasyReports" \
      8 "Gerar coleta de suporte" \
      9 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_logs_tail ;;
      2) shellops_tui_logs_search_text ;;
      3) shellops_tui_logs_common_errors ;;
      4) shellops_tui_logs_period ;;
      5) shellops_tui_logs_find_large ;;
      6) shellops_tui_logs_target ;;
      7) shellops_tui_reports ;;
      8) shellops_tui_support_bundle ;;
      9) return 0 ;;
    esac
  done
}

shellops_tui_certificate_file_action() {
  local title="$1" function_name="$2" file
  file="$(shellops_tui_select_file "$title")" || return 0
  [[ -n "$file" ]] || return 0
  shellops_tui_show_output "$title" "$function_name" "$file" || true
}

shellops_tui_certificate_password() {
  set +x
  dialog --stdout --title "${1:-Senha}" --passwordbox "Senha (não será exibida, persistida ou enviada em argv):" 9 82
}

shellops_tui_certificate_destination() {
  dialog --stdout --title "${1:-Destino}" --inputbox "Path completo do novo arquivo (não pode existir):" 9 92 "$PWD/"
}

shellops_tui_certificate_chain() {
  local leaf intermediates anchor hostname
  leaf="$(shellops_tui_select_file "Certificado leaf")" || return 0
  dialog --title "Intermediários" --yesno "Deseja informar um arquivo com certificados intermediários?" 8 82 &&
    intermediates="$(shellops_tui_select_file "Intermediários")"
  dialog --title "Trust anchor" --yesno "Deseja informar explicitamente um trust anchor? Isso não comprova confiança pública." 9 88 &&
    anchor="$(shellops_tui_select_file "Trust anchor")"
  hostname="$(dialog --stdout --title "Hostname opcional" --inputbox "Hostname a validar (vazio = não validar):" 8 80)" || return 0
  shellops_tui_show_output "Validação de cadeia" certificates_validate_chain "$leaf" "${intermediates:-}" "${anchor:-}" "$hostname" || true
}

shellops_tui_certificate_key_match() {
  local certificate key
  certificate="$(shellops_tui_select_file "Certificado")" || return 0
  key="$(shellops_tui_select_file "Chave privada")" || return 0
  shellops_tui_show_output "Certificado x chave" certificates_match_certificate_key "$certificate" "$key" || true
}

shellops_tui_inspect_keystore() {
  set +x
  local type="$1" source password function_name
  source="$(shellops_tui_select_file "Selecionar $type")" || return 0
  password="$(shellops_tui_certificate_password "Senha do $type")" || return 0
  [[ "$type" == JKS ]] && function_name=certificates_inspect_jks || function_name=certificates_inspect_pkcs12
  shellops_tui_show_output "Inspeção $type" "$function_name" "$source" "$password" || true
  unset password
}

shellops_tui_pkcs12_to_pem() {
  set +x
  local source password mode destination confirmation=
  source="$(shellops_tui_select_file "Selecionar PFX/P12")" || return 0
  password="$(shellops_tui_certificate_password "Senha do PFX/P12")" || return 0
  mode="$(dialog --stdout --title "PFX/P12 -> PEM" --menu "Selecione o conteúdo:" 18 92 9 \
    complete "PEM completo [inclui chave sem criptografia]" \
    certificate "Somente certificado leaf" key "Somente private key sem criptografia" \
    chain "Somente cadeia CA" separated "Arquivos separados" back "Voltar")" || { unset password; return 0; }
  [[ "$mode" == back ]] && { unset password; return 0; }
  if [[ "$mode" == separated ]]; then
    destination="$(dialog --stdout --title "Diretório destino" --dselect "$PWD/" 14 92)" || { unset password; return 0; }
  else destination="$(shellops_tui_certificate_destination "Novo arquivo PEM")" || { unset password; return 0; }; fi
  if [[ "$mode" == complete || "$mode" == key || "$mode" == separated ]]; then
    dialog --title "ATENÇÃO — ARTEFATO SENSÍVEL" --yesno \
      "O arquivo resultante conterá uma chave privada sem criptografia.\n\nClassificação:\nALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\n\nSerá aplicada permissão 600 quando suportado. Confirmar especificamente esta geração?" 17 94 ||
      { unset password; return 0; }
    confirmation=CONFIRM_SENSITIVE
  else
    dialog --title "ALTERAÇÃO LOCAL / ARTEFATO" --yesno "Origem: $source\nDestino: $destination\n\nO destino não será sobrescrito. Continuar?" 12 92 ||
      { unset password; return 0; }
  fi
  if [[ "$mode" == separated ]]; then
    shellops_tui_show_program_output "PFX/P12 -> arquivos PEM" certificates_pkcs12_to_pem_separated "$source" "$password" "$destination" "$confirmation" || true
  else shellops_tui_show_program_output "PFX/P12 -> PEM" certificates_pkcs12_to_pem "$source" "$password" "$mode" "$destination" "$confirmation" || true; fi
  unset password
}

shellops_tui_pem_to_pkcs12() {
  set +x
  local certificate key chain= destination password confirm
  certificate="$(shellops_tui_select_file "Certificado leaf PEM")" || return 0
  key="$(shellops_tui_select_file "Chave privada PEM")" || return 0
  dialog --title "Cadeia opcional" --yesno "Deseja incluir intermediários?" 8 72 &&
    chain="$(shellops_tui_select_file "Cadeia intermediária")"
  destination="$(shellops_tui_certificate_destination "Novo PFX/P12")" || return 0
  password="$(shellops_tui_certificate_password "Senha do novo PFX/P12")" || return 0
  confirm="$(shellops_tui_certificate_password "Confirmar senha")" || { unset password; return 0; }
  [[ "$password" == "$confirm" ]] || { dialog --title "Senha" --msgbox "As senhas não coincidem." 8 68; unset password confirm; return 0; }
  unset confirm
  dialog --title "ALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL" --yesno \
    "Leaf: $certificate\nChave: $key\nCadeia: ${chain:-não informada}\nDestino: $destination\n\nA chave será validada antes da conversão e o destino não será sobrescrito. Continuar?" 16 96 ||
    { unset password; return 0; }
  shellops_tui_show_program_output "PEM -> PFX/P12" certificates_pem_to_pkcs12 "$certificate" "$key" "$chain" "$destination" "$password" || true
  unset password
}

shellops_tui_pkcs12_to_jks() {
  set +x
  local source source_password destination destination_password confirm
  source="$(shellops_tui_select_file "Selecionar PFX/P12")" || return 0
  source_password="$(shellops_tui_certificate_password "Senha de origem")" || return 0
  destination="$(shellops_tui_certificate_destination "Novo JKS")" || { unset source_password; return 0; }
  destination_password="$(shellops_tui_certificate_password "Senha do novo JKS")" || { unset source_password; return 0; }
  confirm="$(shellops_tui_certificate_password "Confirmar senha do JKS")" || { unset source_password destination_password; return 0; }
  [[ "$destination_password" == "$confirm" ]] || { dialog --title "Senha" --msgbox "As senhas não coincidem." 8 68; unset source_password destination_password confirm; return 0; }
  unset confirm
  dialog --title "ALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL" --yesno "Origem: $source\nDestino: $destination\n\nO destino não será sobrescrito. Continuar?" 12 92 ||
    { unset source_password destination_password; return 0; }
  shellops_tui_show_program_output "PFX/P12 -> JKS" certificates_pkcs12_to_jks "$source" "$source_password" "$destination" "$destination_password" || true
  unset source_password destination_password
}

shellops_tui_jks_to_pkcs12() {
  set +x
  local source source_password source_key_password records record alias entry choice index destination destination_password confirm
  local -a aliases=() menu_items=()
  source="$(shellops_tui_select_file "Selecionar JKS")" || return 0
  source_password="$(shellops_tui_certificate_password "Senha do JKS")" || return 0
  records="$(_certificates_keystore_aliases "$source" "$source_password" JKS 2>&1)" || {
    dialog --title "JKS" --msgbox "$records" 10 88; unset source_password; return 0
  }
  while IFS= read -r record; do
    IFS='|' read -r alias entry <<< "$record"; [[ "$entry" == *PrivateKeyEntry* ]] || continue
    aliases+=("$alias"); index=$(("${#aliases[@]}" - 1)); menu_items+=("$index" "$alias — $entry")
  done <<< "$records"
  (( ${#aliases[@]} > 0 )) || { dialog --title "JKS" --msgbox "N/A — nenhum alias PrivateKeyEntry disponível." 9 82; unset source_password; return 0; }
  choice="$(dialog --stdout --title "Alias JKS" --menu "Somente PrivateKeyEntry pode ser convertido com chave:" 20 94 12 "${menu_items[@]}")" ||
    { unset source_password; return 0; }
  alias="${aliases[$choice]}"
  source_key_password="$(shellops_tui_certificate_password "Senha do PrivateKeyEntry (vazio = senha do JKS)")" ||
    { unset source_password; return 0; }
  [[ -n "$source_key_password" ]] || source_key_password="$source_password"
  destination="$(shellops_tui_certificate_destination "Novo PFX/P12")" || { unset source_password source_key_password; return 0; }
  destination_password="$(shellops_tui_certificate_password "Senha do novo PFX/P12")" || { unset source_password source_key_password; return 0; }
  confirm="$(shellops_tui_certificate_password "Confirmar senha")" || { unset source_password source_key_password destination_password; return 0; }
  [[ "$destination_password" == "$confirm" ]] || { dialog --title "Senha" --msgbox "As senhas não coincidem." 8 68; unset source_password source_key_password destination_password confirm; return 0; }
  unset confirm
  dialog --title "ALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL" --yesno "Alias: $alias (PrivateKeyEntry)\nDestino: $destination\n\nContinuar?" 11 88 ||
    { unset source_password source_key_password destination_password; return 0; }
  shellops_tui_show_program_output "JKS -> PFX/P12" certificates_jks_to_pkcs12 "$source" "$source_password" "$alias" "$destination" "$destination_password" "$source_key_password" || true
  unset source_password source_key_password destination_password
}

shellops_tui_remote_tls() {
  local host port sni
  host="$(dialog --stdout --title "TLS remoto" --inputbox "Hostname:" 8 72)" || return 0
  port="$(dialog --stdout --title "Porta" --inputbox "Porta TLS:" 8 64 "443")" || return 0
  sni="$(dialog --stdout --title "SNI explícito" --inputbox "Server Name Indication:" 8 76 "$host")" || return 0
  shellops_tui_show_program_output "TLS remoto: $host:$port" certificates_test_remote_tls "$host" "$port" "$sni" || true
}

shellops_tui_certificates_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Certificados" --menu \
      "Inspeção [CONSULTA] e conversões [ALTERAÇÃO LOCAL]" 28 104 17 \
      1 "Analisar arquivo de certificado" \
      2 "Validar PEM padrão Philips" \
      3 "Inspecionar certificado" \
      4 "Validar cadeia" \
      5 "Certificado x chave privada" \
      6 "Converter PFX/P12 -> PEM" \
      7 "PEM -> PFX/P12" \
      8 "PFX/P12 -> JKS" \
      9 "JKS -> PFX/P12" \
      10 "Inspecionar PFX/P12" \
      11 "Inspecionar JKS" \
      12 "Testar certificado TLS remoto" \
      13 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_certificate_file_action "Analisar arquivo" certificates_analyze_file ;;
      2) shellops_tui_certificates ;;
      3) shellops_tui_certificate_file_action "Inspecionar certificado" certificates_inspect_certificate ;;
      4) shellops_tui_certificate_chain ;;
      5) shellops_tui_certificate_key_match ;;
      6) shellops_tui_pkcs12_to_pem ;;
      7) shellops_tui_pem_to_pkcs12 ;;
      8) shellops_tui_pkcs12_to_jks ;;
      9) shellops_tui_jks_to_pkcs12 ;;
      10) shellops_tui_inspect_keystore PKCS12 ;;
      11) shellops_tui_inspect_keystore JKS ;;
      12) shellops_tui_remote_tls ;;
      13) return 0 ;;
    esac
  done
}

shellops_tui_main() {
  local option

  trap shellops_tui_cleanup EXIT
  while true; do
    option="$(dialog --stdout --clear --title "ShellOps v1.0" --menu \
      "Operações de suporte e troubleshooting — Release status: RC1" 23 92 13 \
      1 "Diagnóstico" \
      2 "TASY / AppManager" \
      3 "Docker / Containers" \
      4 "Java / Tomcat" \
      5 "TIE / Integrações" \
      6 "Oracle / Conectividade" \
      7 "Logs e Coletas" \
      8 "Certificados" \
      9 "Ferramentas Linux" \
      0 "Sair")" || break

    case "$option" in
      1) shellops_tui_diagnostic_menu_v1 ;;
      2) shellops_tui_tasy_menu ;;
      3) shellops_tui_docker_menu_v1 ;;
      4) shellops_tui_java_menu ;;
      5) shellops_tui_tie_menu ;;
      6) shellops_tui_oracle_menu ;;
      7) shellops_tui_logs_menu ;;
      8) shellops_tui_certificates_menu ;;
      9) shellops_tui_linux_tools_menu ;;
      0) break ;;
    esac
  done

  shellops_tui_cleanup
  trap - EXIT
  clear 2>/dev/null || true
  return 0
}
