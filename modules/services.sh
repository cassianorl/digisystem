#!/usr/bin/env bash

_services_require_systemd() {
  if ! shellops_has_command systemctl || [[ ! -d /run/systemd/system ]]; then
    printf 'systemd não está disponível neste ambiente.\n' >&2
    return 127
  fi
}

_services_require_journalctl() {
  if ! shellops_has_command journalctl; then
    printf 'journalctl não está disponível neste ambiente.\n' >&2
    return 127
  fi
}

_services_validate_unit() {
  local unit="${1:-}"
  if [[ -z "$unit" || "$unit" == -* || "$unit" == *$'\n'* || "$unit" == *$'\r'* ]]; then
    printf 'Nome de unit inválido.\n' >&2
    return 2
  fi
}

_services_validate_lines() {
  local lines="${1:-}"
  if [[ ! "$lines" =~ ^[1-9][0-9]*$ ]]; then
    printf 'A quantidade de linhas deve ser um inteiro maior que zero.\n' >&2
    return 2
  fi
}

_services_journal_context() {
  if [[ -d /var/log/journal ]]; then
    printf 'Journal persistente detectado em /var/log/journal.\n\n'
  else
    printf 'Diretório /var/log/journal ausente; o journal ainda pode existir apenas em memória.\n\n'
  fi
}

_services_journal_failure() {
  local status="$1"
  printf '\nNão foi possível concluir a consulta ao journal (código %s).\n' "$status" >&2
  printf 'Permissão insuficiente para consultar esta fonte ou journal indisponível.\n' >&2
  return "$status"
}

_services_failed_units() {
  local output status
  _services_require_systemd || return
  if ! shellops_has_command awk; then
    printf 'Comando awk não encontrado.\n' >&2
    return 127
  fi
  if output="$(systemctl --failed --type=service --no-legend --no-pager 2>&1)"; then
    awk 'NF > 0 {print $1}' <<< "$output"
  else
    status=$?
    printf '%s\n' "$output" >&2
    return "$status"
  fi
}

services_list_units() {
  _services_require_systemd || return
  if ! shellops_has_command awk; then
    printf 'Comando awk não encontrado.\n' >&2
    return 127
  fi
  systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
    awk 'NF > 0 {print $1}'
}

services_failed() {
  local output status
  _services_require_systemd || return
  if output="$(systemctl --failed --type=service --no-legend --no-pager 2>&1)"; then
    if [[ -n "$output" ]]; then
      printf '%-42s %-8s %-8s %-10s %s\n' UNIT LOAD ACTIVE SUB DESCRIPTION
      printf '%s\n' "$output"
      printf '\nUma unit failed é uma evidência; sua causa deve ser investigada no contexto.\n'
    else
      printf 'Nenhum serviço em estado failed foi encontrado.\n'
    fi
  else
    status=$?
    printf '%s\n' "$output" >&2
    printf 'Não foi possível consultar serviços com falha.\n' >&2
    return "$status"
  fi
}

services_status() {
  local unit="${1:-}"
  _services_validate_unit "$unit" || return
  _services_require_systemd || return

  printf '=== Status nativo ===\n'
  systemctl status --no-pager -- "$unit" 2>&1 || true
  printf '\n=== Propriedades ===\n'
  systemctl show --no-pager \
    --property=Id,LoadState,ActiveState,SubState,UnitFileState,MainPID,ExecMainPID,ExecMainStatus,Result,ActiveEnterTimestamp,InactiveEnterTimestamp,FragmentPath \
    -- "$unit"
}

services_running() {
  _services_require_systemd || return
  systemctl list-units --type=service --state=running --no-pager
}

services_enabled() {
  _services_require_systemd || return
  systemctl list-unit-files --type=service --no-pager
  printf '\nNota: enabled não significa necessariamente running; disabled não significa falha.\n'
}

services_journal() {
  local unit="${1:-}" lines="${2:-200}" status
  _services_validate_unit "$unit" || return
  _services_validate_lines "$lines" || return
  _services_require_journalctl || return
  _services_journal_context
  journalctl --no-pager -u "$unit" -n "$lines"
  status=$?
  [[ "$status" -eq 0 ]] || _services_journal_failure "$status"
}

services_journal_period() {
  local since="${1:-}" until="${2:-}" unit="${3:-}" status
  local -a journal_args=(--no-pager --since "$since")
  [[ -n "$since" ]] || { printf 'O início do período é obrigatório.\n' >&2; return 2; }
  [[ -n "$until" ]] && journal_args+=(--until "$until")
  if [[ -n "$unit" ]]; then
    _services_validate_unit "$unit" || return
    journal_args+=(-u "$unit")
  fi
  _services_require_journalctl || return
  _services_journal_context
  journalctl "${journal_args[@]}"
  status=$?
  [[ "$status" -eq 0 ]] || _services_journal_failure "$status"
}

services_recent_events() {
  local since="${1:-1 hour ago}" status
  [[ -n "$since" ]] || { printf 'O início do período é obrigatório.\n' >&2; return 2; }
  _services_require_journalctl || return
  printf 'Eventos com prioridade warning até alert. A presença de um evento não determina isoladamente a causa de um incidente.\n\n'
  _services_journal_context
  journalctl --no-pager --priority=warning..alert --since "$since"
  status=$?
  [[ "$status" -eq 0 ]] || _services_journal_failure "$status"
}

services_kernel_messages() {
  local since="${1:-1 hour ago}" lines="${2:-300}" status
  _services_validate_lines "$lines" || return

  if shellops_has_command journalctl; then
    printf 'Fonte: journal do kernel\n\n'
    journalctl --no-pager --kernel --since "$since" -n "$lines"
    status=$?
    [[ "$status" -eq 0 ]] && return 0
    _services_journal_failure "$status" || true
    printf '\nTentando fallback dmesg...\n\n'
  fi

  if shellops_has_command dmesg && shellops_has_command tail; then
    dmesg 2>&1 | tail -n "$lines"
    status=${PIPESTATUS[0]}
    if [[ "$status" -ne 0 ]]; then
      printf '\nPermissão insuficiente para consultar esta fonte.\n' >&2
      return "$status"
    fi
    return 0
  fi

  printf 'journalctl e fallback dmesg não estão disponíveis.\n' >&2
  return 127
}
