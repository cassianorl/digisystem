#!/usr/bin/env bash

reports_performance_check() {
  local log_file="${1:-}"
  local threshold="${2:-}"

  [[ -n "$log_file" ]] || { shellops_error "Informe o arquivo de log."; return 2; }
  [[ "$log_file" == /* ]] || log_file="./$log_file"
  shellops_is_non_negative_integer "$threshold" || { shellops_error "O limite deve ser um inteiro em segundos."; return 2; }
  shellops_require_commands awk sort cut head mktemp || return
  shellops_run_legacy "maintenance/reports_performance_check.sh" "$log_file" "$threshold"
}
