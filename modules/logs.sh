#!/usr/bin/env bash

_logs_validate_file() {
  local log_file="${1:-}"
  [[ -n "$log_file" ]] || { shellops_error "Informe o arquivo de log."; return 2; }
  [[ -f "$log_file" && -r "$log_file" ]] || {
    shellops_error "Arquivo inexistente, não regular ou não legível: $log_file"
    return 2
  }
}

_logs_validate_positive_integer() {
  local value="${1:-}" label="${2:-Valor}" maximum="${3:-}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    shellops_error "$label deve ser um inteiro maior que zero."
    return 2
  }
  [[ -z "$maximum" || "$value" -le "$maximum" ]] || {
    shellops_error "$label deve ser menor ou igual a $maximum."
    return 2
  }
}

logs_tail() {
  local log_file="${1:-}" lines="${2:-200}"
  _logs_validate_file "$log_file" || return
  [[ "$log_file" == -* ]] && log_file="./$log_file"
  _logs_validate_positive_integer "$lines" "A quantidade de linhas" 10000 || return
  shellops_require_command tail || return
  tail -n "$lines" -- "$log_file"
}

logs_search_text() {
  local log_file="${1:-}" text="${2:-}" limit="${3:-200}" status
  _logs_validate_file "$log_file" || return
  [[ "$log_file" == -* ]] && log_file="./$log_file"
  [[ -n "$text" && "$text" != *$'\n'* && "$text" != *$'\r'* ]] || {
    shellops_error "Informe um texto de busca em uma única linha."
    return 2
  }
  _logs_validate_positive_integer "$limit" "O limite de resultados" 5000 || return
  shellops_require_commands grep awk || return

  grep -F -n -- "$text" "$log_file" | awk -v limit="$limit" 'NR <= limit {print}'
  status=${PIPESTATUS[0]}
  if [[ "$status" -eq 1 ]]; then
    printf 'Nenhuma ocorrência literal encontrada.\n'
    return 0
  fi
  return "$status"
}

logs_common_errors() {
  local log_file="${1:-}" limit="${2:-40}" context="${3:-1}"
  local pattern total status
  _logs_validate_file "$log_file" || return
  [[ "$log_file" == -* ]] && log_file="./$log_file"
  _logs_validate_positive_integer "$limit" "O limite de ocorrências" 1000 || return
  [[ "$context" =~ ^[0-5]$ ]] || {
    shellops_error "O contexto deve ser um inteiro entre zero e cinco."
    return 2
  }
  shellops_require_commands grep awk tail || return

  pattern='ERROR|FATAL|Exception|OutOfMemory|ORA-|timeout|Connection reset|segfault|I/O error|failed'
  total="$(grep -Eic -- "$pattern" "$log_file")"
  status=$?
  if [[ "$status" -eq 1 ]]; then
    printf 'Ocorrências encontradas: 0\n'
    printf 'A ausência desses termos não comprova ausência de falhas.\n'
    return 0
  elif [[ "$status" -ne 0 ]]; then
    return "$status"
  fi

  printf 'Ocorrências encontradas: %s\n' "$total"
  printf 'Os resultados abaixo são evidências textuais, não um diagnóstico.\n\n'
  printf '%s\n' '=== Primeiras ocorrências ==='
  grep -Ein -C "$context" -- "$pattern" "$log_file" |
    awk -v limit="$limit" 'NR <= limit {print}'
  printf '\n%s\n' '=== Últimas ocorrências ==='
  grep -Ein -- "$pattern" "$log_file" | tail -n "$limit"
}

logs_search_period() {
  local log_file="${1:-}" since="${2:-}" until="${3:-}"
  local detected_format
  _logs_validate_file "$log_file" || return
  [[ "$log_file" == -* ]] && log_file="./$log_file"
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || {
    shellops_error "Início inválido. Use YYYY-MM-DD HH:MM:SS."
    return 2
  }
  [[ -z "$until" || "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || {
    shellops_error "Fim inválido. Use YYYY-MM-DD HH:MM:SS."
    return 2
  }
  shellops_require_command awk || return

  detected_format="$(awk '
    NR <= 100 && substr($0,1,19) ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}$/ {
      print "iso19"; exit
    }' "$log_file")"
  [[ "$detected_format" == iso19 ]] || {
    shellops_error "Formato de timestamp não reconhecido com segurança. Nesta etapa são aceitas linhas iniciadas por YYYY-MM-DD HH:MM:SS ou YYYY-MM-DDTHH:MM:SS."
    return 3
  }

  since="${since/T/ }"
  until="${until/T/ }"
  awk -v since="$since" -v until="$until" '
    {
      timestamp=substr($0,1,19); gsub(/T/, " ", timestamp)
      if (timestamp ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/ &&
          timestamp >= since && (until == "" || timestamp <= until)) print
    }' "$log_file"
}

logs_find_large() {
  local start_dir="${1:-}" minimum_mb="${2:-100}" limit="${3:-30}"
  [[ -n "$start_dir" && -d "$start_dir" && -r "$start_dir" ]] || {
    shellops_error "Diretório inicial inexistente ou não legível: $start_dir"
    return 2
  }
  [[ "$start_dir" == -* ]] && start_dir="./$start_dir"
  _logs_validate_positive_integer "$minimum_mb" "O tamanho mínimo em MiB" || return
  _logs_validate_positive_integer "$limit" "O limite de resultados" 1000 || return
  shellops_require_commands find sort awk || return

  printf 'Consulta somente de metadados; nenhum arquivo será removido ou lido.\n'
  printf 'Busca restrita ao filesystem do diretório inicial (-xdev).\n\n'
  find "$start_dir" -xdev -type f -size "+${minimum_mb}M" -printf '%s\t%p\n' 2>/dev/null |
    sort -nr | awk -F '\t' -v limit="$limit" '
      NR <= limit {
        typical=($2 ~ /(^|\/)(messages|secure|catalina\.out)$/ || $2 ~ /\.log([.-]|$)/ || $2 ~ /-json\.log$/) ? "log-típico" : "arquivo-grande"
        printf "%.2f MiB\t[%s]\t%s\n", $1/1048576, typical, $2
      }'
}

logs_target() {
  local lines="${1:-200}" since="${2:-}" until="${3:-}"
  _logs_validate_positive_integer "$lines" "A quantidade de linhas" 10000 || return
  [[ -n "${SHELLOPS_TARGET_SOURCE:-}" ]] || {
    shellops_error "Nenhum alvo foi selecionado."
    return 2
  }

  case "$SHELLOPS_TARGET_SOURCE" in
    docker)
      if [[ -n "$since" ]]; then
        docker_show_logs_since "$SHELLOPS_TARGET_NAME" "$lines" "$since"
      else
        docker_show_logs "$SHELLOPS_TARGET_NAME" "$lines"
      fi
      ;;
    systemd)
      if [[ -n "$since" ]]; then
        services_journal_period "$since" "$until" "$SHELLOPS_TARGET_NAME"
      else
        services_journal "$SHELLOPS_TARGET_NAME" "$lines"
      fi
      ;;
    process|path|docker_image)
      printf 'Nenhum log foi associado automaticamente ao alvo %s (%s).\n' \
        "$SHELLOPS_TARGET_NAME" "$SHELLOPS_TARGET_SOURCE"
      printf 'Esta etapa não inventa paths nem regras específicas de produto.\n'
      ;;
    *)
      printf 'A fonte de alvo %s ainda não possui integração de logs.\n' "$SHELLOPS_TARGET_SOURCE"
      ;;
  esac
}
