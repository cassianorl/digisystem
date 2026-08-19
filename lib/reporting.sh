#!/usr/bin/env bash

shellops_html_escape() {
  local value="${1:-}" character index

  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      '&') printf '&amp;' ;;
      '<') printf '&lt;' ;;
      '>') printf '&gt;' ;;
      '"') printf '&quot;' ;;
      "'") printf '&#39;' ;;
      *) printf '%s' "$character" ;;
    esac
  done
}

shellops_report_slug() {
  local value="${1:-relatorio}"

  if shellops_has_command tr && shellops_has_command sed; then
    value="$(printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  else
    value="relatorio"
  fi
  printf '%s\n' "${value:-relatorio}"
}

shellops_report_default_path() {
  local title="${1:-Relatório}" output_dir="${SHELLOPS_REPORT_DIR:-$PWD/shellops-reports}"
  local host timestamp slug

  shellops_require_command date "O comando date é necessário para nomear o relatório." || return
  if shellops_has_command hostname; then host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"; fi
  host="${host:-host}"
  timestamp="$(date '+%Y%m%d-%H%M%S')" || return 1
  slug="$(shellops_report_slug "$title")" || return 1
  host="$(shellops_report_slug "$host")" || return 1
  printf '%s/%s-%s-%s.html\n' "$output_dir" "$slug" "$host" "$timestamp"
}

shellops_generate_html_report() {
  local title="${1:-Relatório ShellOps}" input_file="${2:-}" output_file="${3:-}" command_status="${4:-0}"
  local generated_at host user_name escaped_title escaped_host escaped_user escaped_date escaped_status

  [[ -n "$input_file" && -r "$input_file" ]] || { shellops_error "Arquivo de entrada inválido ou não legível."; return 2; }
  [[ -n "$output_file" ]] || { shellops_error "Caminho do relatório não informado."; return 2; }
  shellops_require_commands mkdir dirname date || return

  mkdir -p -- "$(dirname -- "$output_file")" || {
    shellops_error "Não foi possível criar o diretório do relatório."
    return 1
  }

  generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
  if shellops_has_command hostname; then host="$(hostname 2>/dev/null || true)"; fi
  host="${host:-desconhecido}"
  user_name="${USER:-${LOGNAME:-desconhecido}}"
  escaped_title="$(shellops_html_escape "$title")"
  escaped_host="$(shellops_html_escape "$host")"
  escaped_user="$(shellops_html_escape "$user_name")"
  escaped_date="$(shellops_html_escape "$generated_at")"
  escaped_status="$(shellops_html_escape "$command_status")"

  {
    printf '%s\n' '<!doctype html>' '<html lang="pt-BR">' '<head>' '<meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '<title>%s - ShellOps</title>\n' "$escaped_title"
    printf '%s\n' '<style>' \
      ':root { color-scheme: light dark; --bg: #0f172a; --panel: #111827; --text: #e5e7eb; --muted: #94a3b8; --accent: #38bdf8; }' \
      '* { box-sizing: border-box; } body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, sans-serif; }' \
      'main { width: min(1200px, 94vw); margin: 2rem auto; } h1 { color: var(--accent); margin-bottom: .5rem; }' \
      '.meta { color: var(--muted); display: flex; flex-wrap: wrap; gap: .5rem 1.5rem; margin-bottom: 1.5rem; }' \
      'pre { margin: 0; padding: 1.25rem; overflow: auto; border: 1px solid #334155; border-radius: .5rem; background: var(--panel); color: var(--text); font: 13px/1.45 ui-monospace, SFMono-Regular, Consolas, monospace; white-space: pre-wrap; }' \
      '@media print { :root { --bg: #fff; --panel: #fff; --text: #111; --muted: #444; } main { width: 100%; margin: 0; } pre { border: 0; padding: 0; white-space: pre-wrap; } }' \
      '</style>' '</head>' '<body>' '<main>'
    printf '<h1>%s</h1>\n' "$escaped_title"
    printf '<div class="meta"><span><strong>Host:</strong> %s</span><span><strong>Usuário:</strong> %s</span><span><strong>Gerado em:</strong> %s</span><span><strong>Status:</strong> %s</span></div>\n' \
      "$escaped_host" "$escaped_user" "$escaped_date" "$escaped_status"
    printf '<pre>'
    while IFS= read -r line || [[ -n "$line" ]]; do
      shellops_html_escape "$line"
      printf '\n'
    done < "$input_file"
    printf '%s\n' '</pre>' '</main>' '</body>' '</html>'
  } > "$output_file" || {
    shellops_error "Não foi possível gravar o relatório: $output_file"
    return 1
  }

  printf '%s\n' "$output_file"
}
