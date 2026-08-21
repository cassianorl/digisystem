#!/usr/bin/env bash

_oracle_path_value() {
  local value="${1:-}"
  [[ -n "$value" && "$value" == /* && "$value" != *$'\n'* && "$value" != *$'\r'* && -d "$value" ]] && printf '%s\n' "$value" || return 1
}

_oracle_command_path() {
  command -v -- "$1" 2>/dev/null || return 1
}

oracle_client_summary() {
  local sqlplus tnsping lsnrctl home admin version
  sqlplus="$(_oracle_command_path sqlplus || true)"; tnsping="$(_oracle_command_path tnsping || true)"; lsnrctl="$(_oracle_command_path lsnrctl || true)"
  home="$(_oracle_path_value "${ORACLE_HOME:-}" || true)"; admin="$(_oracle_path_value "${TNS_ADMIN:-}" || true)"
  printf 'Oracle Client (CONSULTA)\nSQLPlus: %s\nTNSping: %s\nLSNRCTL: %s\n' "${sqlplus:-NÃO DETECTADO}" "${tnsping:-NÃO DETECTADO}" "${lsnrctl:-NÃO DETECTADO}"
  if [[ -n "${ORACLE_HOME:-}" ]]; then printf 'ORACLE_HOME: %s\n' "${home:-definido, porém inválido/inexistente}"; else printf 'ORACLE_HOME: variável não definida\n'; fi
  if [[ -n "${TNS_ADMIN:-}" ]]; then printf 'TNS_ADMIN: %s\n' "${admin:-definido, porém inválido/inexistente}"; else printf 'TNS_ADMIN: variável não definida\n'; fi
  if [[ -n "$sqlplus" ]] && shellops_has_command timeout; then
    version="$(timeout 10 "$sqlplus" -V 2>&1 | awk 'NR<=3 && /SQL\*Plus|Release|Version/')"
    printf 'Client version: %s\n' "${version:-N/A}"
  else printf 'Client version: N/A\n'; fi
  printf '\nORACLE_HOME não é obrigatório para todos os Instant Clients. Ausência de lsnrctl não indica problema em banco remoto.\n'
}

oracle_tns_files() {
  local home admin sqlplus bin_dir candidate
  local -A seen=()
  home="$(_oracle_path_value "${ORACLE_HOME:-}" || true)"; admin="$(_oracle_path_value "${TNS_ADMIN:-}" || true)"; sqlplus="$(_oracle_command_path sqlplus || true)"
  local -a candidates=()
  [[ -n "$admin" ]] && candidates+=("$admin/tnsnames.ora")
  [[ -n "$home" ]] && candidates+=("$home/network/admin/tnsnames.ora")
  if [[ -n "$sqlplus" ]]; then bin_dir="$(dirname "$sqlplus")"; candidates+=("$bin_dir/../network/admin/tnsnames.ora"); fi
  candidates+=(/etc/tnsnames.ora /opt/oracle/network/admin/tnsnames.ora)
  for candidate in "${candidates[@]}"; do
    candidate="$(readlink -f -- "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    [[ -f "$candidate" && -r "$candidate" && -z "${seen[$candidate]:-}" ]] || continue
    seen["$candidate"]=1; printf '%s\n' "$candidate"
  done
}

_oracle_parse_tns_file() {
  local file="$1"
  awk -v file="$file" '
    function trim(v){sub(/^[[:space:]]+/,"",v);sub(/[[:space:]]+$/, "",v);return v}
    function occurrences(s,re, n,t){n=0;t=s;while(match(t,re)){n++;t=substr(t,RSTART+RLENGTH)}return n}
    function field(s,key, clean,upper,marker,start,rest,finish){
      clean=s;gsub(/[[:space:]]/,"",clean);upper=toupper(clean);marker="(" key "=";start=index(upper,marker);if(!start)return ""
      rest=substr(clean,start+length(marker));finish=index(rest,")");if(!finish)return "";return substr(rest,1,finish-1)
    }
    function emit( host,port,svc,sid,complex,status,kind,value){
      if(alias=="")return
      upper=toupper(text);complex=(upper ~ /\((ADDRESS_LIST|DESCRIPTION_LIST|FAILOVER|LOAD_BALANCE|IFILE)[[:space:]]*=/ || occurrences(upper,"\\(ADDRESS[[:space:]]*=")>1 || depth!=0)
      host=field(text,"HOST");port=field(text,"PORT");svc=field(text,"SERVICE_NAME");sid=field(text,"SID")
      if(svc!=""){kind="SERVICE_NAME";value=svc}else if(sid!=""){kind="SID";value=sid}else{kind="N/A";value="N/A"}
      status=(complex || host=="" || port !~ /^[0-9]+$/ || value=="N/A") ? "descriptor não interpretado" : "interpretado"
      gsub(/[|\r\n]/," ",alias);gsub(/[|\r\n]/," ",host);gsub(/[|\r\n]/," ",value)
      printf "%s|%s|%s|%s|%s|%s|%s\n",file,alias,status,(host==""?"N/A":host),(port==""?"N/A":port),kind,value
      alias="";text="";depth=0
    }
    /^[[:space:]]*($|#|;)/{next}
    alias=="" && $0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
      line=$0;sub(/^[[:space:]]*/,"",line);alias=line;sub(/[[:space:]]*=.*/,"",alias);text=line;sub(/^[^=]*=/,"",text)
      depth=occurrences(text,"\\(")-occurrences(text,"\\)");if(index(text,"(")>0 && depth<=0)emit();next
    }
    alias!="" {text=text " " $0;depth+=occurrences($0,"\\(")-occurrences($0,"\\)");if(index(text,"(")>0 && depth<=0)emit()}
    END{if(alias!="")emit()}
  ' "$file"
}

oracle_tns_alias_records() {
  local file found=0
  while IFS= read -r file; do found=1; _oracle_parse_tns_file "$file"; done < <(oracle_tns_files)
  (( found > 0 )) || return 0
}

oracle_tns_summary() {
  local records
  records="$(oracle_tns_alias_records)"
  if [[ -z "$records" ]]; then printf 'TNS config: NÃO DETECTADO\nNenhum tnsnames.ora foi localizado nos paths confirmados.\n'; return 0; fi
  printf 'Arquivo|Alias|Status|Host|Port|Tipo|Service/SID\n%s\n' "$records"
  printf '\nDescriptors complexos permanecem selecionáveis para tnsping/SQLPlus, mas não são expandidos pelo ShellOps.\n'
}

_oracle_valid_alias() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+$ ]]; }

_oracle_alias_exists() {
  local wanted="$1" file alias rest
  while IFS='|' read -r file alias rest; do [[ "$alias" == "$wanted" ]] && return 0; done < <(oracle_tns_alias_records)
  return 1
}

oracle_tcp_test() { network_tcp_test "$@"; }

oracle_tnsping() {
  local alias="${1:-}" output status
  _oracle_valid_alias "$alias" && _oracle_alias_exists "$alias" || { shellops_error 'Alias TNS inválido ou não inventariado.'; return 2; }
  shellops_require_commands tnsping timeout || return
  output="$(timeout 20 tnsping "$alias" 1 2>&1)"; status=$?
  printf '%s\n' "$output" | awk 'NR<=80 && $0 !~ /(PASSWORD|password|credential|wallet)/'
  return "$status"
}

oracle_listener_status() {
  local action="${1:-status}" output status
  case "$action" in status|services) ;; *) shellops_error 'Ação lsnrctl não permitida.'; return 2 ;; esac
  shellops_require_commands lsnrctl timeout || return
  output="$(timeout 20 lsnrctl "$action" 2>&1)"; status=$?
  printf 'Diagnóstico LOCAL; não determina o estado de um banco/listener remoto.\n\n'
  printf '%s\n' "$output" | awk 'NR<=250 && $0 !~ /(PASSWORD|password|credential)/'
  return "$status"
}

_oracle_hex_filter() {
  local value="${1:-}" bytes hex
  shellops_require_commands wc od tr || return
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 2
  bytes="$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d ' ')"; [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -le 256 ]] || return 2
  hex="$(LC_ALL=C printf '%s' "$value" | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
  [[ -z "$value" || "$hex" =~ ^[0-9A-F]+$ ]] || return 2
  printf '%s\n' "$hex"
}

_oracle_valid_datetime() { [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; }

_oracle_valid_user() { [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,127}$ ]]; }

_oracle_sanitize_output() {
  local user="$1" alias="$2"
  awk -v u="$user" -v a="$alias" '
    function replace_literal(s,old,new,p){if(old=="")return s;while((p=index(s,old))>0)s=substr(s,1,p-1) new substr(s,p+length(old));return s}
    {probe=toupper($0); if(probe ~ /^[[:space:]]*(CONNECT|CONN)[[:space:]]/)next; line=replace_literal($0,u,"<USUARIO>");line=replace_literal(line,a,"<ALIAS>");print line}
  ' | awk 'NR<=2000'
}

_oracle_sql_preamble() {
  printf '%s\n' \
    'set echo off' 'set verify off' 'set define off' 'set feedback off' \
    'set heading on' 'set pagesize 50000' 'set linesize 240' 'set trimspool on' \
    'set tab off' 'set long 2000' 'set longchunksize 2000' 'whenever sqlerror exit 9'
}

_oracle_write_query() {
  local query_id="$1" sql_file="$2" arg1="${3:-}" arg2="${4:-}" arg3="${5:-}" arg4="${6:-}" limit="${7:-100}"
  { _oracle_sql_preamble
    case "$query_id" in
      database_info)
        printf '%s\n' \
          "select d.name database_name, i.instance_name, i.instance_number, i.host_name, i.version, to_char(i.startup_time,'YYYY-MM-DD HH24:MI:SS') startup_time, d.open_mode, d.database_role from v\$database d cross join v\$instance i;" \
          "select parameter, value from nls_database_parameters where parameter in ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET') order by parameter;"
        ;;
      login_test)
        printf '%s\n' "select sys_context('USERENV','DB_NAME') database_name, sys_context('USERENV','INSTANCE_NAME') instance_name from dual;"
        ;;
      tasy_parameters)
        printf '%s\n' "select name parameter, display_value valor_atual, case when name in ('processes','sessions','sga_target','sga_max_size','pga_aggregate_target','shared_pool_size','large_pool_size','java_pool_size') then 'DEPENDENTE DE SIZING' else 'VERIFICAR DOCUMENTACAO DA VERSAO' end referencia_tecnica, 'N/A' status, case when isdefault='TRUE' then 'PADRAO ORACLE/NAO ALTERADO EXPLICITAMENTE' else 'VALOR CONFIGURADO; APLICABILIDADE DEPENDE DA VERSAO' end observacao from v\$parameter where name in ('open_cursors','optimizer_index_caching','job_queue_processes','recyclebin','filesystemio_options','session_cached_cursors','optimizer_index_cost_adj','sec_case_sensitive_logon','cursor_sharing','optimizer_mode','db_block_size','processes','sessions','sga_target','sga_max_size','pga_aggregate_target','shared_pool_size','large_pool_size','java_pool_size') order by name;"
        ;;
      resource_limits)
        printf '%s\n' "select resource_name, current_utilization, max_utilization, limit_value, case when regexp_like(limit_value,'^[0-9]+$') and to_number(limit_value)>0 then round(current_utilization*100/to_number(limit_value),2) else null end used_percent from v\$resource_limit where resource_name in ('processes','sessions') order by resource_name;"
        ;;
      session_summary)
        printf '%s\n' "select status, type, count(*) sessions from v\$session group by status,type order by type,status;" "select count(*) user_sessions from v\$session where type='USER';"
        ;;
      gv_session_summary)
        printf '%s\n' "select inst_id,status,type,count(*) sessions from gv\$session group by inst_id,status,type order by inst_id,type,status;"
        ;;
      cursor_summary)
        printf '%s\n' \
          "select name, display_value from v\$parameter where name in ('open_cursors','session_cached_cursors') order by name;" \
          "select n.name, sum(s.value) total from v\$sesstat s join v\$statname n on n.statistic#=s.statistic# where n.name in ('opened cursors current','opened cursors cumulative') group by n.name order by n.name;" \
          "select * from (select s.sid, ss.value opened_cursors from v\$sesstat ss join v\$statname sn on sn.statistic#=ss.statistic# join v\$session s on s.sid=ss.sid where sn.name='opened cursors current' order by ss.value desc) where rownum<=20;"
        ;;
      jobs)
        printf '%s\n' \
          "select name, display_value from v\$parameter where name='job_queue_processes';" \
          "select 'USER_JOBS' source, count(*) total, sum(case when broken='Y' then 1 else 0 end) attention from user_jobs;" \
          "select 'USER_SCHEDULER_JOBS' source, state, count(*) total from user_scheduler_jobs group by state order by state;"
        ;;
      tablespaces)
        cat <<'SQL'
select t.tablespace_name, t.contents type, t.status,
       round(df.allocated/1024/1024,2) allocated_mb,
       round((df.allocated-nvl(fs.free_bytes,0))/1024/1024,2) used_mb,
       round(nvl(fs.free_bytes,0)/1024/1024,2) free_mb,
       case when df.allocated>0 then round((df.allocated-nvl(fs.free_bytes,0))*100/df.allocated,2) end used_percent
from dba_tablespaces t
join (select tablespace_name,sum(bytes) allocated from dba_data_files group by tablespace_name) df on df.tablespace_name=t.tablespace_name
left join (select tablespace_name,sum(bytes) free_bytes from dba_free_space group by tablespace_name) fs on fs.tablespace_name=t.tablespace_name
where t.contents='PERMANENT'
union all
select t.tablespace_name,t.contents,t.status,round(sum(f.bytes)/1024/1024,2),null,null,null
from dba_tablespaces t join dba_temp_files f on f.tablespace_name=t.tablespace_name where t.contents='TEMPORARY'
group by t.tablespace_name,t.contents,t.status
union all
select t.tablespace_name,t.contents,t.status,round(sum(f.bytes)/1024/1024,2),null,null,null
from dba_tablespaces t join dba_data_files f on f.tablespace_name=t.tablespace_name where t.contents='UNDO'
group by t.tablespace_name,t.contents,t.status
order by 2,1;
SQL
        ;;
      invalid_summary)
        printf '%s\n' "select object_type, count(*) invalid_count from all_objects where status='INVALID' group by object_type order by invalid_count desc,object_type;"
        ;;
      invalid_detail)
        printf '%s\n' "select owner,object_name,object_type,status from (select owner,object_name,object_type,status from all_objects where status='INVALID' order by owner,object_type,object_name) where rownum<=$limit;"
        ;;
      nls)
        printf '%s\n' \
          "select 'DATABASE' source, parameter, value from nls_database_parameters where parameter in ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET') order by parameter;" \
          "select 'INSTANCE' source, parameter, value from nls_instance_parameters where parameter in ('NLS_LANGUAGE','NLS_TERRITORY','NLS_DATE_FORMAT') order by parameter;" \
          "select 'SESSION' source, parameter, value from nls_session_parameters where parameter in ('NLS_LANGUAGE','NLS_TERRITORY','NLS_DATE_FORMAT') order by parameter;"
        ;;
      bifrost_minimal|bifrost_detail)
        local event_expr="NULL" message_expr="NULL" since_expr="NULL" until_expr="NULL" columns
        [[ -n "$arg1" ]] && event_expr="UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('$arg1'))"
        [[ -n "$arg2" ]] && message_expr="UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('$arg2'))"
        [[ -n "$arg3" ]] && since_expr="TO_TIMESTAMP('$arg3','YYYY-MM-DD HH24:MI:SS')"
        [[ -n "$arg4" ]] && until_expr="TO_TIMESTAMP('$arg4','YYYY-MM-DD HH24:MI:SS')"
        columns='DT_INTEGRATION,NR_SEQUENCE,DS_MESSAGE_ID,NM_EVENT,IE_DELIVERED'
        [[ "$query_id" == bifrost_detail ]] && columns+=' ,SUBSTR(DS_CONTENT,1,2000) DS_CONTENT,SUBSTR(DS_RESULT,1,2000) DS_RESULT,SUBSTR(DS_MESSAGE_ERROR,1,2000) DS_MESSAGE_ERROR,SUBSTR(DS_CALL_STACK,1,2000) DS_CALL_STACK'
        printf '%s\n' "select $columns from (select $columns from BIFROST_LAYER_LOG where ($event_expr is null or NM_EVENT=$event_expr) and ($message_expr is null or DS_MESSAGE_ID=$message_expr) and ($since_expr is null or DT_INTEGRATION >= $since_expr) and ($until_expr is null or DT_INTEGRATION <= $until_expr) order by DT_INTEGRATION desc) where rownum<=$limit;"
        ;;
      *) return 64 ;;
    esac
    printf '%s\n' 'exit'
  } > "$sql_file"
}

_oracle_query_id_allowed() {
  case "${1:-}" in login_test|database_info|tasy_parameters|resource_limits|session_summary|gv_session_summary|cursor_summary|jobs|tablespaces|invalid_summary|invalid_detail|nls|bifrost_minimal|bifrost_detail) return 0 ;; *) return 1 ;; esac
}

oracle_readonly_check() (
  set +x; set +H
  local query_id="${1:-}" user="${2:-}" password="${3:-}" alias="${4:-}" sql_file output_file status sql_status
  local arg1="${5:-}" arg2="${6:-}" arg3="${7:-}" arg4="${8:-}" limit="${9:-100}"
  set --
  _oracle_query_id_allowed "$query_id" || { unset password; printf 'FAILED — check Oracle desconhecido\n'; return 2; }
  _oracle_valid_user "$user" || { unset password; printf 'FAILED — usuário Oracle inválido\n'; return 2; }
  _oracle_valid_alias "$alias" && _oracle_alias_exists "$alias" || { unset password; printf 'FAILED — alias Oracle inválido ou não inventariado\n'; return 2; }
  [[ -n "$password" && "$password" != *$'\n'* && "$password" != *$'\r'* && "$password" != *'"'* ]] || { unset password; printf 'N/A — credencial incompatível com o mecanismo seguro disponível\n'; return 2; }
  [[ "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le 500 ]] || { unset password; printf 'FAILED — limite inválido\n'; return 2; }
  case "$query_id" in
    bifrost_minimal|bifrost_detail)
      [[ -z "$arg1" || "$arg1" =~ ^[0-9A-F]+$ ]] || { unset password; printf 'FAILED — filtro hexadecimal inválido\n'; return 2; }
      [[ -z "$arg2" || "$arg2" =~ ^[0-9A-F]+$ ]] || { unset password; printf 'FAILED — filtro hexadecimal inválido\n'; return 2; }
      [[ -z "$arg3" ]] || _oracle_valid_datetime "$arg3" || { unset password; printf 'FAILED — data inicial inválida\n'; return 2; }
      [[ -z "$arg4" ]] || _oracle_valid_datetime "$arg4" || { unset password; printf 'FAILED — data final inválida\n'; return 2; }
      ;;
    *) [[ -z "$arg1$arg2$arg3$arg4" ]] || { unset password; printf 'FAILED — filtros não permitidos para este check\n'; return 2; } ;;
  esac
  shellops_require_commands sqlplus timeout mktemp chmod rm awk || { unset password; return; }
  sql_file="$(mktemp)" || { unset password; return 1; }; output_file="$(mktemp)" || { rm -f -- "$sql_file"; unset password; return 1; }
  chmod 600 -- "$sql_file" "$output_file" 2>/dev/null || true
  trap 'rm -f -- "$sql_file" "$output_file"' EXIT
  trap 'exit 130' HUP INT TERM
  _oracle_write_query "$query_id" "$sql_file" "$arg1" "$arg2" "$arg3" "$arg4" "$limit" || {
    unset password; rm -f -- "$sql_file" "$output_file"; trap - EXIT HUP INT TERM; printf 'FAILED — check Oracle desconhecido\n'; return 2; }
  if grep -Eiq '(^|[;[:space:]])(insert|update|delete|merge|alter|create|drop|truncate|grant|revoke|execute|exec|begin)([;[:space:]]|$)' "$sql_file"; then
    unset password; rm -f -- "$sql_file" "$output_file"; trap - EXIT HUP INT TERM; printf 'FAILED — barreira adicional read-only rejeitou o template\n'; return 3
  fi
  {
    printf '%s\n' 'set echo off' 'set verify off' 'set define off'
    printf 'connect %s/"%s"@%s\n' "$user" "$password" "$alias"
    printf '@%s\n' "$sql_file"
  } | timeout 90 sqlplus -L -S /nolog 2>&1 | _oracle_sanitize_output "$user" "$alias" > "$output_file"
  sql_status=${PIPESTATUS[1]}; unset password
  if grep -Eq 'ORA-(01017|28000|28001)' "$output_file"; then printf 'FAILED — autenticação SQL não aceita\n'; status=4
  elif grep -Eq 'ORA-(01031|00942)' "$output_file"; then printf 'N/A — privilégio insuficiente ou objeto não disponível\n'; status=0
  elif [[ "$sql_status" -eq 124 ]]; then printf 'FAILED — timeout na consulta Oracle\n'; status=124
  else cat "$output_file"; status="$sql_status"; fi
  rm -f -- "$sql_file" "$output_file"; trap - EXIT HUP INT TERM
  unset user alias arg1 arg2 arg3 arg4
  return "$status"
)

oracle_database_info() { set +x; oracle_readonly_check database_info "$@"; }

oracle_tasy_parameters() {
  set +x
  printf 'VALOR ATUAL consultado. REFERÊNCIA TÉCNICA/STATUS dependem da versão do produto e não serão aplicados automaticamente.\n'
  printf 'Parâmetros de SGA/PGA/pools/processes/sessions são dependentes de sizing. Diferença não é classificada automaticamente como erro.\n\n'
  oracle_readonly_check tasy_parameters "$@"
}

oracle_resource_limits() {
  set +x
  printf 'LIMIT_VALUE=UNLIMITED permanece textual; percentual só é calculado para limite numérico.\n'
  printf 'Processes e sessions são evidências independentes. Sessions pode ser derivado automaticamente pelo Oracle.\n'
  printf 'Os dados não determinam automaticamente a causa de ORA-12516.\n\n'
  oracle_readonly_check resource_limits "$@" || return
  oracle_readonly_check session_summary "$@"
  printf '\n=== GV$/RAC agregado quando disponível ===\n'; oracle_readonly_check gv_session_summary "$@" || true
}

oracle_cursors_jobs() {
  set +x
  printf '=== Cursores ===\n'; oracle_readonly_check cursor_summary "$@" || true
  printf '\n=== Jobs agregados ===\n'; oracle_readonly_check jobs "$@"
}

oracle_tablespaces() {
  set +x
  printf 'Percentuais são calculados somente para PERMANENT. TEMP e UNDO apresentam uso/free como N/A quando não há cálculo seguro.\n'
  printf 'Qualquer faixa de atenção é heurística operacional ShellOps, não requisito Philips/TASY.\n\n'
  oracle_readonly_check tablespaces "$@"
}

oracle_invalid_objects() {
  set +x
  local mode="${1:-summary}" user="${2:-}" password="${3:-}" alias="${4:-}" limit="${5:-100}"
  case "$mode" in summary) oracle_readonly_check invalid_summary "$user" "$password" "$alias" ;; detail) oracle_readonly_check invalid_detail "$user" "$password" "$alias" '' '' '' '' "$limit" ;; *) printf 'FAILED — modo inválido\n'; return 2 ;; esac
  unset password
}

oracle_nls_summary() {
  set +x
  printf 'Valores são separados por DATABASE, INSTANCE e SESSION. Nenhum ALTER SESSION é executado.\n'
  printf 'Compatibilidade TASY: N/A — verificar documentação da versão.\n\n'
  oracle_readonly_check nls "$@"
}

oracle_bifrost_layer_log_search() {
  set +x
  local mode="${1:-minimal}" user="${2:-}" password="${3:-}" alias="${4:-}" event_name="${5:-}" message_id="${6:-}" since="${7:-}" until="${8:-}" limit="${9:-100}"
  local event_hex message_hex query_id
  case "$mode" in minimal) query_id=bifrost_minimal ;; detail) query_id=bifrost_detail ;; *) unset password; printf 'FAILED — modo BIFROST_LAYER_LOG inválido\n'; return 2 ;; esac
  event_hex="$(_oracle_hex_filter "$event_name")" || { unset password; printf 'FAILED — NM_EVENT excede o limite ou contém formato inválido\n'; return 2; }
  message_hex="$(_oracle_hex_filter "$message_id")" || { unset password; printf 'FAILED — DS_MESSAGE_ID excede o limite ou contém formato inválido\n'; return 2; }
  [[ -z "$since" ]] || _oracle_valid_datetime "$since" || { unset password; printf 'FAILED — data inicial inválida; use YYYY-MM-DD HH:MM:SS\n'; return 2; }
  [[ -z "$until" ]] || _oracle_valid_datetime "$until" || { unset password; printf 'FAILED — data final inválida; use YYYY-MM-DD HH:MM:SS\n'; return 2; }
  [[ -n "$event_name$message_id$since$until" ]] || { unset password; printf 'FAILED — informe ao menos um filtro\n'; return 2; }
  if [[ "$mode" == detail ]]; then
    printf 'ATENÇÃO: DS_CONTENT, DS_RESULT, DS_MESSAGE_ERROR e DS_CALL_STACK podem conter dados clínicos, identificadores de paciente, payloads completos, dados do sistema destino e informações sensíveis. Saída limitada a 2000 caracteres por campo.\n\n'
  fi
  oracle_readonly_check "$query_id" "$user" "$password" "$alias" "$event_hex" "$message_hex" "$since" "$until" "$limit"
  unset password event_name message_id
}

oracle_sql_login_test() { set +x; oracle_readonly_check login_test "$@"; }

oracle_ora12516_evidence() {
  set +x
  local host="${1:-}" port="${2:-}" alias="${3:-}" user="${4:-}" password="${5:-}"
  printf 'ORA-12516 — EVIDÊNCIAS INDEPENDENTES\nA função não conclui automaticamente que processes está esgotado.\n\n'
  printf '=== TCP ===\n'; oracle_tcp_test "$host" "$port" 2>&1 || true
  printf '\n=== TNS / Alias ===\nAlias: %s\n' "$alias"; oracle_tnsping "$alias" 2>&1 || true
  printf '\n=== Listener local, se aplicável ===\n'
  if shellops_has_command lsnrctl; then oracle_listener_status services 2>&1 || true; else printf 'N/A — lsnrctl/listener local não disponível; isso não determina o estado remoto.\n'; fi
  printf '\n=== Processes / Sessions ===\n'
  if [[ -n "$user$password" ]]; then oracle_resource_limits "$user" "$password" "$alias" 2>&1 || true
  else printf 'N/A — sessão SQL read-only não fornecida.\n'; fi
  unset password user
  printf '\nTCP, TNS, listener local, handlers, processes e sessions são evidências; nenhuma causa foi inferida automaticamente.\n'
}

oracle_validate_environment() {
  set +x
  local user="${1:-}" password="${2:-}" alias="${3:-}" records files aliases
  printf 'Oracle / Conectividade\n\nREFERÊNCIA TÉCNICA DO PRODUTO\n'
  printf '[N/A] Aplicabilidade de parâmetros e charset\n      Verificar documentação da versão do produto. Nenhum valor será aplicado.\n'
  printf '\nCHECKS OPERACIONAIS SHELLOPS\n'
  shellops_has_command sqlplus && printf '[OK] SQLPlus disponível\n' || printf '[N/A] SQLPlus ausente; não é falha universal para host que usa somente TCP/TNS\n'
  shellops_has_command tnsping && printf '[OK] TNSping disponível\n' || printf '[N/A] TNSping não disponível\n'
  shellops_has_command lsnrctl && printf '[OK] LSNRCTL local disponível\n' || printf '[N/A] LSNRCTL local ausente; não determina listener remoto\n'
  files="$(oracle_tns_files)"; [[ -n "$files" ]] && printf '[OK] TNS config confirmado\n' || printf '[N/A] tnsnames.ora não detectado\n'
  aliases="$(oracle_tns_alias_records)"; [[ -n "$aliases" ]] && printf '[OK] Alias TNS inventariado\n' || printf '[N/A] Alias TNS não inventariado\n'
  [[ "$aliases" == *'|interpretado|'* ]] && printf '[OK] Ao menos um descriptor simples interpretado\n' || printf '[N/A] Nenhum descriptor foi interpretado com segurança\n'
  if [[ -n "$user$password$alias" ]]; then
    printf '\n=== Checks SQL opcionais ===\n'; oracle_readonly_check login_test "$user" "$password" "$alias" || true
    printf 'Versão/charset/parâmetros/resource limits/tablespaces/objetos exigem seleção explícita das respectivas funções.\n'
  else printf '[N/A] Login SQL e checks de banco não solicitados\n'; fi
  unset password user alias
}
