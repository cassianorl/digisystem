#!/usr/bin/env bash

shellops_error() {
  printf 'ERRO: %s\n' "$*" >&2
}

shellops_require_root_path() {
  if [[ -z "${SHELLOPS_ROOT:-}" || ! -d "$SHELLOPS_ROOT" ]]; then
    shellops_error "Raiz do ShellOps não foi inicializada."
    return 1
  fi
}

shellops_legacy_script() {
  local relative_path="$1"

  shellops_require_root_path || return 1
  printf '%s/%s\n' "$SHELLOPS_ROOT" "$relative_path"
}

shellops_run_legacy() {
  local relative_path="$1"
  shift

  local script
  script="$(shellops_legacy_script "$relative_path")" || return 1

  if [[ ! -f "$script" ]]; then
    shellops_error "Script não encontrado: $script"
    return 1
  fi

  bash "$script" "$@"
}

shellops_is_non_negative_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}
