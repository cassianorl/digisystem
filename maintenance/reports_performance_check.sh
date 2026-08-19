#!/bin/bash

echo "DESENVOLVIDO POR: HERBERT PESSOA"
echo "CONTATO: Herbert.Pessoa@digisystem.com.br"

if [ "$#" -ne 2 ]; then
  echo "Uso: $0 <arquivo_de_log> <limite_em_segundos>"
  exit 1
fi

LOG="$1"
LIMITE="$2"

if [ ! -r "$LOG" ]; then
  echo "Erro: arquivo de log não existe ou não é legível: $LOG"
  exit 1
fi

if ! [[ "$LIMITE" =~ ^[0-9]+$ ]]; then
  echo "Erro: o limite deve ser um número inteiro em segundos."
  exit 1
fi

TMP_OUTPUT=$(mktemp)
TMP_PENDING=$(mktemp)
TMP_TOP=$(mktemp)

trap 'rm -f "$TMP_OUTPUT" "$TMP_PENDING" "$TMP_TOP"' EXIT

awk -v limite="$LIMITE" -v pending_file="$TMP_PENDING" '
function mon_to_num(mon) {
  mon = toupper(mon)
  if (mon == "JAN") return "01"
  if (mon == "FEB") return "02"
  if (mon == "MAR") return "03"
  if (mon == "APR") return "04"
  if (mon == "MAY") return "05"
  if (mon == "JUN") return "06"
  if (mon == "JUL") return "07"
  if (mon == "AUG") return "08"
  if (mon == "SEP") return "09"
  if (mon == "OCT") return "10"
  if (mon == "NOV") return "11"
  if (mon == "DEC") return "12"
  return ""
}

function parse_ts(line,   raw,a,b,c,mon) {
  # Formato 1: 2026-03-27T09:52:25.398Z
  if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
    raw = substr(line, RSTART, RLENGTH)
    split(raw, a, "T")
    split(a[1], b, "-")
    split(a[2], c, ":")
    return mktime(b[1] " " b[2] " " b[3] " " c[1] " " c[2] " " c[3])
  }

  # Formato 2: 27-Mar-2026 09:52:25.398
  if (match(line, /^[0-9]{2}-[A-Za-z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
    raw = substr(line, RSTART, RLENGTH)
    split(raw, a, " ")
    split(a[1], b, "-")
    split(a[2], c, ":")
    mon = mon_to_num(b[2])
    if (mon == "") return 0
    return mktime(b[3] " " mon " " b[1] " " c[1] " " c[2] " " c[3])
  }

  return 0
}

function display_ts(line,   raw) {
  # Exibição amigável do timestamp
  if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?/)) {
    raw = substr(line, RSTART, RLENGTH)
    gsub(/T/, " ", raw)
    gsub(/Z$/, "", raw)
    return raw
  }

  if (match(line, /^[0-9]{2}-[A-Za-z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/)) {
    return substr(line, RSTART, RLENGTH)
  }

  return "DATA_DESCONHECIDA"
}

function extract_fields(line,   m) {
  rel = user = hash = ""

  # Ex.: 0___CATE2296_2306438 - regiane.pereira - 1a65f288-22a1-40d6-930d-0acfb4ea932d.
  if (match(line, /(0___[^ ]+)[[:space:]]+-[[:space:]]+([^ ]+)[[:space:]]+-[[:space:]]+([[:alnum:]-]+)\.?/, m)) {
    rel = m[1]
    user = m[2]
    hash = m[3]
    return 1
  }

  return 0
}

BEGIN {
  OFS="|"
}

{
  ts = parse_ts($0)
  dh = display_ts($0)

  if (!extract_fields($0))
    next

  base_id = rel "|" user "|" hash

  if ($0 ~ /Relatorio iniciou geracao/) {
    start_count[base_id]++
    exec_id = base_id SUBSEP start_count[base_id]

    ini[exec_id] = ts
    dh_ini[exec_id] = dh
    rel_exec[exec_id] = rel
    user_exec[exec_id] = user
    hash_exec[exec_id] = hash

    queue_tail[base_id]++
    queue[base_id, queue_tail[base_id]] = exec_id
  }
  else if ($0 ~ /Relatorio finalizou geracao/) {
    queue_head[base_id]++
    exec_id = queue[base_id, queue_head[base_id]]

    if (exec_id != "") {
      fim[exec_id] = ts
    }
  }
}

END {
  for (exec_id in ini) {
    if (ini[exec_id] <= 0)
      continue

    if (exec_id in fim && fim[exec_id] > 0) {
      dur = fim[exec_id] - ini[exec_id]
      if (dur > limite) {
        printf "%d|%s | Relatório: %s | Usuário: %s | Hash: %s | Duração: %ds\n",
          ini[exec_id], dh_ini[exec_id], rel_exec[exec_id], user_exec[exec_id], hash_exec[exec_id], dur
      }
    } else {
      printf "%d|%s | Relatório: %s | Usuário: %s | Hash: %s (SEM FINALIZAÇÃO)\n",
        ini[exec_id], dh_ini[exec_id], rel_exec[exec_id], user_exec[exec_id], hash_exec[exec_id] > pending_file
    }
  }
}
' "$LOG" > "$TMP_OUTPUT"

echo "Relatórios com duração superior a $LIMITE segundos (ordenados por início):"
sort -n "$TMP_OUTPUT" | cut -d"|" -f2-

echo
echo "Relatórios que iniciaram mas não finalizaram (ordenados por início):"
sort -n "$TMP_PENDING" | cut -d"|" -f2-

awk -F' \\| ' '
/Relatório:/ && /Duração:/ {
  rel = dur = ""

  for (i = 1; i <= NF; i++) {
    if ($i ~ /^Relatório: /) {
      rel = $i
      sub(/^Relatório: /, "", rel)
    }
    if ($i ~ /^Duração: [0-9]+s$/) {
      dur = $i
      sub(/^Duração: /, "", dur)
      sub(/s$/, "", dur)
    }
  }

  if (rel != "" && dur != "") {
    soma[rel] += dur
    qtd[rel]++
  }
}
END {
  for (r in soma) {
    if (qtd[r] > 3) {
      media = soma[r] / qtd[r]
      printf "%.2f|%s|%d\n", media, r, qtd[r]
    }
  }
}
' "$TMP_OUTPUT" | sort -t'|' -k1,1nr | head -3 > "$TMP_TOP"

echo
echo "TOP 3 relatórios mais lentos (com mais de 3 execuções):"
awk -F'|' '{printf "Relatório: %s | Execuções: %d | Média: %.2fs\n", $2, $3, $1}' "$TMP_TOP"