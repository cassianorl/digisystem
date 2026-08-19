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

  local output_file status
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

  dialog --title "$title" --exit-label "Voltar" --textbox "$output_file" 22 100
  rm -f -- "$output_file"
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

shellops_tui_docker() {
  local option container lines

  while true; do
    option="$(dialog --stdout --title "Docker - somente leitura" --menu \
      "Escolha uma operação:" 18 82 8 \
      1 "Listar containers" \
      2 "Stats atuais" \
      3 "Logs de um container" \
      4 "Inspect de um container" \
      5 "Status e healthcheck" \
      0 "Voltar")" || return 0

    case "$option" in
      1) shellops_tui_show_output "Containers Docker" docker_list_containers || true ;;
      2) shellops_tui_show_output "Docker stats" docker_show_stats || true ;;
      3)
        container="$(shellops_tui_container_name)" || continue
        [[ -n "$container" ]] || continue
        lines="$(dialog --stdout --title "Docker logs" --inputbox "Quantidade de linhas:" 8 60 "200")" || continue
        [[ -n "$lines" ]] || continue
        shellops_tui_show_output "Logs: $container" docker_show_logs "$container" "$lines" || true
        ;;
      4)
        container="$(shellops_tui_container_name)" || continue
        [[ -n "$container" ]] || continue
        shellops_tui_show_output "Inspect: $container" docker_inspect_container "$container" || true
        ;;
      5)
        container="$(shellops_tui_container_name)" || continue
        [[ -n "$container" ]] || continue
        shellops_tui_show_output "Health: $container" docker_show_health "$container" || true
        ;;
      0) return 0 ;;
    esac
  done
}

shellops_tui_tasy_monitor() {
  dialog --title "Monitor de startup TASY" --yesno \
    "Esta opção reutiliza o monitor existente. Ela requer root, aguarda um container tasy-tasyappserver-* ficar healthy e grava a coleta em /root. Deseja continuar?" \
    11 82 || return 0

  local status
  clear
  tasy_monitor_startup
  status=$?
  printf '\nMonitor finalizado com código %d. Pressione ENTER para retornar à TUI.\n' "$status"
  read -r
}

shellops_tui_unavailable() {
  dialog --title "Indisponível" --msgbox \
    "Operações de instalação e manutenção de risco estão em refatoração e não podem ser executadas nesta versão." \
    9 76
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

shellops_tui_performance() {
  local option
  while true; do
    option="$(dialog --stdout --title "Performance - somente leitura" --menu \
      "Escolha uma coleta:" 22 88 11 \
      1 "Visão geral de performance" \
      2 "CPU por intervalo" \
      3 "Memória / VMStat" \
      4 "I/O de discos" \
      5 "Processos por CPU" \
      6 "Processos por I/O" \
      7 "Histórico SAR" \
      8 "Disponibilidade do sysstat" \
      9 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Visão geral de performance" performance_overview || true ;;
      2) shellops_tui_performance_sampled "CPU por intervalo" performance_cpu_interval ;;
      3) shellops_tui_performance_sampled "Memória / VMStat" performance_vmstat_interval ;;
      4) shellops_tui_performance_sampled "I/O de discos" performance_disk_io ;;
      5) shellops_tui_performance_sampled "Processos por CPU" performance_process_cpu ;;
      6) shellops_tui_performance_sampled "Processos por I/O" performance_process_io ;;
      7) shellops_tui_performance_history ;;
      8) shellops_tui_show_output "Disponibilidade do sysstat" performance_sysstat_status || true ;;
      9) return 0 ;;
    esac
  done
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

shellops_tui_services() {
  local option
  while true; do
    option="$(dialog --stdout --title "Serviços e Logs - somente leitura" --menu \
      "Escolha uma consulta:" 22 88 11 \
      1 "Serviços com falha" \
      2 "Status de um serviço" \
      3 "Serviços em execução" \
      4 "Serviços habilitados" \
      5 "Journal de um serviço" \
      6 "Journal por período" \
      7 "Erros recentes do sistema" \
      8 "Mensagens do kernel" \
      9 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Serviços com falha" services_failed || true ;;
      2) shellops_tui_services_status ;;
      3) shellops_tui_show_output "Serviços em execução" services_running || true ;;
      4) shellops_tui_show_output "Serviços habilitados" services_enabled || true ;;
      5) shellops_tui_services_journal ;;
      6) shellops_tui_services_period ;;
      7) shellops_tui_services_recent ;;
      8) shellops_tui_services_kernel ;;
      9) return 0 ;;
    esac
  done
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

shellops_tui_network() {
  local option
  while true; do
    option="$(dialog --stdout --title "Rede - somente leitura" --menu \
      "Escolha uma consulta:" 24 88 13 \
      1 "Resumo de rede" 2 "Interfaces" 3 "Rotas" 4 "DNS" \
      5 "Portas e sockets" 6 "Conectividade ICMP" 7 "Conectividade TCP" \
      8 "Rota até destino" 9 "ARP / Neighbor table" \
      10 "Estatísticas de interfaces" 11 "Voltar")" || return 0
    case "$option" in
      1) shellops_tui_show_output "Resumo de rede" network_overview || true ;;
      2) shellops_tui_network_interfaces ;;
      3) shellops_tui_network_routes ;;
      4) shellops_tui_network_dns ;;
      5) shellops_tui_network_sockets ;;
      6) shellops_tui_network_ping ;;
      7) shellops_tui_network_tcp ;;
      8) shellops_tui_network_trace ;;
      9) shellops_tui_show_output "ARP / Neighbor table" network_neighbors || true ;;
      10) shellops_tui_network_stats ;;
      11) return 0 ;;
    esac
  done
}

shellops_tui_main() {
  local option

  trap shellops_tui_cleanup EXIT

  while true; do
    option="$(dialog --stdout --clear --title "ShellOps" --menu \
      "Administração e troubleshooting para servidores RHEL-based" 23 88 12 \
      1 "Quick Health Check - somente leitura" \
      2 "Validar certificado PEM" \
      3 "Analisar performance de relatórios" \
      4 "Docker - operações somente leitura" \
      5 "Monitorar startup do TASY AppServer" \
      6 "Diagnóstico do sistema - somente leitura" \
      7 "Performance - somente leitura" \
      8 "Serviços e Logs - somente leitura" \
      9 "Rede - somente leitura" \
      10 "Instalação [Operação de risco - indisponível]" \
      11 "Manutenção [Operação de risco - indisponível]" \
      0 "Sair")" || break

    case "$option" in
      1) shellops_tui_show_output "Quick Health Check" health_quick_check || true ;;
      2) shellops_tui_certificates ;;
      3) shellops_tui_reports ;;
      4) shellops_tui_docker ;;
      5) shellops_tui_tasy_monitor ;;
      6) shellops_tui_system ;;
      7) shellops_tui_performance ;;
      8) shellops_tui_services ;;
      9) shellops_tui_network ;;
      10|11) shellops_tui_unavailable ;;
      0) break ;;
    esac
  done

  shellops_tui_cleanup
  trap - EXIT
  clear
}
