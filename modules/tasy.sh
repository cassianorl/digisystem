#!/usr/bin/env bash

tasy_monitor_startup() {
  shellops_tasy_monitor_dependencies || return

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    shellops_error "O monitor atual grava a coleta em /root e deve ser executado como root."
    return 1
  fi

  shellops_run_legacy "analysis/monitor_tasy_startup.sh"
}
