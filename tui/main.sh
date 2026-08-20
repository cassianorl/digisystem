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

shellops_tui_container_name() {
  dialog --stdout --title "Container Docker" \
    --inputbox "Informe o nome ou ID do container:" 9 70
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

shellops_tui_utilities_menu() {
  local option

  while true; do
    option="$(dialog --stdout --title "Utilitários" --menu \
      "Ferramentas para tarefas específicas" 17 88 7 \
      1 "Validar certificado PEM" \
      2 "Analisar performance de relatórios" \
      3 "Monitorar startup do TASY AppServer [gera coleta]" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_certificates ;;
      2) shellops_tui_reports ;;
      3) shellops_tui_tasy_monitor ;;
      0) return 0 ;;
    esac
  done
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

shellops_tui_diagnostics_docker() {
  local container

  container="$(shellops_tui_container_name)" || return 0
  [[ -n "$container" ]] || return 0
  shellops_tui_show_output "Health: $container" docker_show_health "$container" || true
}

shellops_tui_diagnostics_menu() {
  local option

  while true; do
    option="$(dialog --stdout --title "Diagnósticos" --menu \
      "Coletas, testes e correlação de evidências" 19 88 8 \
      1 "Quick Health Check" \
      2 "Performance" \
      3 "Rede" \
      4 "Serviços e logs" \
      5 "Docker - status e healthcheck" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Quick Health Check" health_quick_check || true ;;
      2) shellops_tui_diagnostics_performance ;;
      3) shellops_tui_diagnostics_network ;;
      4) shellops_tui_diagnostics_services ;;
      5) shellops_tui_diagnostics_docker ;;
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
      4) shellops_tui_show_output "Configuração DNS" network_dns_status || true ;;
      5) shellops_tui_network_sockets ;;
      6) shellops_tui_show_output "ARP / Neighbor table" network_neighbors || true ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_read_docker() {
  local option container lines

  while true; do
    option="$(dialog --stdout --title "Consultas - Docker" --menu \
      "Operações somente de leitura" 18 82 8 \
      1 "Listar containers" \
      2 "Stats atuais" \
      3 "Logs de um container" \
      4 "Inspect de um container" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Containers Docker" docker_list_containers || true ;;
      2) shellops_tui_show_output "Docker stats" docker_show_stats || true ;;
      3)
        container="$(shellops_tui_container_name)" || continue
        [[ -n "$container" ]] || continue
        lines="$(dialog --stdout --title "Docker logs" \
          --inputbox "Quantidade de linhas:" 8 60 "200")" || continue
        [[ -n "$lines" ]] || continue
        shellops_tui_show_output "Logs: $container" docker_show_logs "$container" "$lines" || true
        ;;
      4)
        container="$(shellops_tui_container_name)" || continue
        [[ -n "$container" ]] || continue
        shellops_tui_show_output "Inspect: $container" docker_inspect_container "$container" || true
        ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_read_menu() {
  local option

  while true; do
    option="$(dialog --stdout --title "Consultas e leitura" --menu \
      "Inventário e estado atual, sem alterações no servidor" 20 88 9 \
      1 "Sistema" \
      2 "Rede" \
      3 "Serviços e logs" \
      4 "Docker" \
      5 "Histórico e dependências de performance" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_system ;;
      2) shellops_tui_read_network ;;
      3) shellops_tui_read_services ;;
      4) shellops_tui_read_docker ;;
      5) shellops_tui_read_performance ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_not_available() {
  local area="${1:-Funcionalidade}"
  dialog --title "$area" --msgbox \
    "[Em refatoração]\n\nNesta etapa, somente operações de CONSULTA já validadas estão ativas." 10 76
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

shellops_tui_docker_container_action() {
  local action="$1" lines
  shellops_tui_select_target docker || return 0
  case "$action" in
    diagnose) shellops_tui_show_output "Diagnóstico: $SHELLOPS_TARGET_NAME" discovery_diagnose_target || true ;;
    logs)
      lines="$(dialog --stdout --title "Docker logs" --inputbox "Quantidade de linhas:" 8 60 "200")" || return 0
      shellops_is_non_negative_integer "$lines" || {
        dialog --title "Entrada inválida" --msgbox "A quantidade deve ser um inteiro." 8 70
        return 0
      }
      shellops_tui_show_output "Logs: $SHELLOPS_TARGET_NAME" docker_show_logs "$SHELLOPS_TARGET_NAME" "$lines" || true
      ;;
    inspect) shellops_tui_show_output "Inspect seguro: $SHELLOPS_TARGET_NAME" docker_inspect_safe "$SHELLOPS_TARGET_NAME" || true ;;
  esac
}

shellops_tui_docker_menu_v1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Docker / Containers" --menu \
      "Inventário e análise somente de leitura" 22 94 12 \
      1 "Containers em execução" 2 "Todos os containers" 3 "Imagens disponíveis" \
      4 "Aplicações detectadas" 5 "Diagnosticar container" 6 "Logs" 7 "Stats" \
      8 "Inspect seguro" 9 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Containers em execução" docker_list_running_containers || true ;;
      2) shellops_tui_show_output "Todos os containers" docker_list_all_containers || true ;;
      3) shellops_tui_show_output "Imagens disponíveis" docker_list_images || true ;;
      4) shellops_tui_show_output "Aplicações detectadas" docker_list_detected_applications || true ;;
      5) shellops_tui_docker_container_action diagnose ;;
      6) shellops_tui_docker_container_action logs ;;
      7) shellops_tui_show_output "Docker stats" docker_show_stats || true ;;
      8) shellops_tui_docker_container_action inspect ;;
      9) return 0 ;;
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

shellops_tui_linux_tools_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Ferramentas Linux" --menu \
      "Funções genéricas preservadas como apoio operacional" 19 90 9 \
      1 "Sistema" 2 "Performance" 3 "Serviços e Logs" 4 "Rede" \
      5 "Storage / LVM" 6 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_system ;; 2) shellops_tui_performance_menu_v1 ;;
      3) shellops_tui_services_menu_v1 ;; 4) shellops_tui_network_menu_v1 ;;
      5) shellops_tui_storage_menu ;; 6) return 0 ;;
    esac
  done
}

shellops_tui_tasy_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "TASY / AppManager" --menu "Recursos disponíveis nesta etapa" 16 90 7 \
      1 "Monitorar startup do TASY AppServer [gera coleta]" \
      2 "Instalação do AppManager [Em refatoração]" 3 "Voltar")" || return 0
    case "$option" in 1) shellops_tui_tasy_monitor ;; 2) shellops_tui_not_available "Instalação do AppManager" ;; 3) return 0 ;; esac
  done
}

_shellops_tui_logs_menu_stage1() {
  local option
  while true; do
    option="$(dialog --stdout --title "Logs e Coletas" --menu "Consultas e coletas existentes" 16 90 7 \
      1 "Analisar performance de relatórios" 2 "Serviços e journal" 3 "Voltar")" || return 0
    case "$option" in 1) shellops_tui_reports ;; 2) shellops_tui_services_menu_v1 ;; 3) return 0 ;; esac
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

shellops_tui_certificates_menu() {
  local option
  while true; do
    option="$(dialog --stdout --title "Certificados" --menu "Recursos disponíveis nesta etapa" 15 88 6 \
      1 "Validar PEM padrão Philips" 2 "Conversões e inspeções [Em refatoração]" 3 "Voltar")" || return 0
    case "$option" in 1) shellops_tui_certificates ;; 2) shellops_tui_not_available "Certificados" ;; 3) return 0 ;; esac
  done
}

_shellops_tui_main_legacy() {
  local option

  trap shellops_tui_cleanup EXIT

  while true; do
    option="$(dialog --stdout --clear --title "ShellOps" --menu \
      "Administração e troubleshooting para servidores RHEL-based" 16 88 6 \
      1 "Utilitários" \
      2 "Diagnósticos" \
      3 "Consultas e leitura" \
      0 "Sair")" || break

    case "$option" in
      1) shellops_tui_utilities_menu ;;
      2) shellops_tui_diagnostics_menu ;;
      3) shellops_tui_read_menu ;;
      0) break ;;
    esac
  done

  shellops_tui_cleanup
  trap - EXIT
  clear
}

shellops_tui_main() {
  local option

  trap shellops_tui_cleanup EXIT
  while true; do
    option="$(dialog --stdout --clear --title "ShellOps v1.0" --menu \
      "Operações de suporte e troubleshooting — etapa estrutural" 23 92 13 \
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
      4) shellops_tui_not_available "Java / Tomcat" ;;
      5) shellops_tui_not_available "TIE / Integrações" ;;
      6) shellops_tui_not_available "Oracle / Conectividade" ;;
      7) shellops_tui_logs_menu ;;
      8) shellops_tui_certificates_menu ;;
      9) shellops_tui_linux_tools_menu ;;
      0) break ;;
    esac
  done

  shellops_tui_cleanup
  trap - EXIT
  clear
}
