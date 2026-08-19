#!/usr/bin/env bash

certificates_validate_pem() {
  local pem_file="${1:-}"

  [[ -n "$pem_file" ]] || { shellops_error "Informe o arquivo PEM."; return 2; }
  [[ "$pem_file" == /* ]] || pem_file="./$pem_file"
  shellops_require_commands openssl awk grep sed cut date mktemp || return
  shellops_run_legacy "maintenance/valida_pem.sh" "$pem_file"
}
