#!/usr/bin/env bash

###############################################################################
# Monitor passivo de startup do Tasy AppServer
#
# Funcionamento:
#   1. Inicia coleta do HOST imediatamente.
#   2. Aguarda um container tasy-tasyappserver-* iniciar.
#   3. Obtém o StartedAt real informado pelo Docker.
#   4. Passa a coletar também docker stats desse container.
#   5. Monitora o healthcheck.
#   6. Quando ficar "healthy":
#        - registra horário;
#        - calcula duração do startup;
#        - encerra todas as coletas;
#        - gera ZIP em /root/.
#
# Ctrl+C:
#   encerra as coletas e também gera um ZIP parcial.
###############################################################################

PATTERN='^tasy-tasyappserver-'
INTERVAL=1

HOSTNAME=$(hostname -s)
SCRIPT_START=$(date '+%Y%m%d_%H%M%S')

WORKDIR="/root/tasy_startup_${HOSTNAME}_${SCRIPT_START}"
ZIPFILE="${WORKDIR}.zip"

mkdir -p "$WORKDIR"

###############################################################################
# Validação
###############################################################################

REQUIRED_COMMANDS=(
    docker
    sar
    iostat
    vmstat
    pidstat
    zip
    awk
    date
)

for CMD in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERRO: comando '$CMD' não encontrado."
        exit 1
    fi
done

###############################################################################
# Variáveis
###############################################################################

declare -A INITIAL_STARTED_AT

COLLECTOR_PIDS=()

TARGET_NAME=""
TARGET_ID=""

STARTED_AT_UTC=""
STARTED_AT_LOCAL=""
STARTED_EPOCH=""

HEALTHY_AT_UTC=""
HEALTHY_AT_LOCAL=""
HEALTHY_EPOCH=""

FINALIZED=0
FINAL_REASON=""

###############################################################################
# Funções
###############################################################################

local_time() {
    date '+%Y-%m-%d %H:%M:%S.%3N %z'
}

to_local_time() {
    date -d "$1" '+%Y-%m-%d %H:%M:%S.%3N %z' 2>/dev/null
}

to_epoch() {
    date -d "$1" '+%s.%N' 2>/dev/null
}

elapsed() {
    awk -v START="$1" -v END="$2" \
        'BEGIN { printf "%.3f", END - START }'
}

format_elapsed() {
    awk -v T="$1" 'BEGIN {
        MIN=int(T/60);
        SEC=T-(MIN*60);
        printf "%02dm %06.3fs", MIN, SEC
    }'
}

###############################################################################
# Finalização
###############################################################################

finalize() {

    if [ "$FINALIZED" -eq 1 ]; then
        return
    fi

    FINALIZED=1

    echo
    echo "Encerrando coletores..."

    for PID in "${COLLECTOR_PIDS[@]}"; do
        kill "$PID" 2>/dev/null
    done

    sleep 1

    for PID in "${COLLECTOR_PIDS[@]}"; do
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID" 2>/dev/null
        fi
    done

    wait 2>/dev/null

    ###########################################################################
    # Estado final
    ###########################################################################

    if [ -n "$TARGET_NAME" ]; then
        docker inspect "$TARGET_NAME" \
            > "$WORKDIR/docker_inspect_final.json" 2>&1

        docker inspect \
            --format '{{json .State.Health}}' \
            "$TARGET_NAME" \
            > "$WORKDIR/health_final.json" 2>&1

        docker logs --timestamps --tail 500 "$TARGET_NAME" \
            > "$WORKDIR/container_last_500.log" 2>&1
    fi

    ###########################################################################
    # Resultado
    ###########################################################################

    {
        echo "============================================================"
        echo "RESULTADO DO MONITORAMENTO"
        echo "============================================================"
        echo
        echo "Servidor           : $HOSTNAME"
        echo "Motivo encerramento: $FINAL_REASON"
        echo "Container          : ${TARGET_NAME:-não detectado}"
        echo "Container ID       : ${TARGET_ID:-não detectado}"
        echo
        echo "Script iniciado    : $SCRIPT_START"

        if [ -n "$STARTED_AT_LOCAL" ]; then
            echo "Docker StartedAt   : $STARTED_AT_LOCAL"
        fi

        if [ -n "$HEALTHY_AT_LOCAL" ]; then
            echo "Healthy            : $HEALTHY_AT_LOCAL"
        fi

        if [ -n "$STARTED_EPOCH" ] && [ -n "$HEALTHY_EPOCH" ]; then

            TOTAL_SECONDS=$(elapsed \
                "$STARTED_EPOCH" \
                "$HEALTHY_EPOCH")

            echo "Tempo até healthy  : $(format_elapsed "$TOTAL_SECONDS")"
            echo "Segundos totais    : $TOTAL_SECONDS"
        fi

        if [ -n "$TARGET_NAME" ]; then
            echo
            echo "Estado final:"
            docker inspect \
                --format 'Status={{.State.Status}} Running={{.State.Running}} RestartCount={{.RestartCount}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$TARGET_NAME" 2>/dev/null
        fi

    } > "$WORKDIR/result.txt"

    ###########################################################################
    # ZIP
    ###########################################################################

    echo
    echo "Compactando resultado..."

    cd /root || exit 1

    zip -rq "$ZIPFILE" "$(basename "$WORKDIR")"

    echo
    echo "============================================================"
    echo "COLETA FINALIZADA"
    echo "============================================================"
    echo
    cat "$WORKDIR/result.txt"
    echo
    echo "Diretório:"
    echo "  $WORKDIR"
    echo
    echo "ZIP:"
    echo "  $ZIPFILE"
    echo
}

trap '
    FINAL_REASON="interrompido manualmente com Ctrl+C"
    finalize
    exit 130
' INT TERM

###############################################################################
# Informações do ambiente
###############################################################################

{
    echo "============================================================"
    echo "AMBIENTE"
    echo "============================================================"
    echo
    echo "Data:"
    local_time
    echo
    echo "Hostname:"
    hostname
    echo
    echo "Kernel:"
    uname -a
    echo
    echo "CPU:"
    lscpu
    echo
    echo "Memória:"
    free -h
    echo
    echo "Discos:"
    lsblk
    echo
    echo "Docker:"
    docker version
} > "$WORKDIR/environment.log" 2>&1

###############################################################################
# Registrar containers existentes antes do teste
###############################################################################

while read -r ID NAME; do

    [ -z "$ID" ] && continue

    if [[ "$NAME" =~ $PATTERN ]]; then

        STARTED=$(docker inspect \
            --format '{{.State.StartedAt}}' \
            "$ID" 2>/dev/null)

        INITIAL_STARTED_AT["$ID"]="$STARTED"
    fi

done < <(
    docker ps -a \
        --format '{{.ID}} {{.Names}}'
)

###############################################################################
# Iniciar coletores do HOST
###############################################################################

echo "============================================================"
echo "MONITOR TASY APPSERVER"
echo "============================================================"
echo
echo "Servidor : $HOSTNAME"
echo "Logs     : $WORKDIR"
echo
echo "Iniciando coleta do host..."
echo

sar -u "$INTERVAL" \
    > "$WORKDIR/cpu.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

sar -r "$INTERVAL" \
    > "$WORKDIR/memory.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

sar -q "$INTERVAL" \
    > "$WORKDIR/load.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

iostat -xz "$INTERVAL" \
    > "$WORKDIR/iostat.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

vmstat "$INTERVAL" \
    > "$WORKDIR/vmstat.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

pidstat -u -r -d -w -p ALL "$INTERVAL" \
    > "$WORKDIR/pidstat.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

pidstat -t -u -w "$INTERVAL" \
    > "$WORKDIR/pidstat_threads.log" 2>&1 &
COLLECTOR_PIDS+=("$!")

###############################################################################
# Log de eventos
###############################################################################

echo "timestamp|evento|container|id|status|health|restart_count" \
    > "$WORKDIR/events.log"

###############################################################################
# Aguardar o AppManager iniciar um container
###############################################################################

echo "Aguardando o AppManager iniciar:"
echo
echo "    tasy-tasyappserver-*"
echo
echo "Nenhuma ação será executada sobre o Docker."
echo

while true; do

    while read -r ID NAME; do

        [ -z "$ID" ] && continue

        if [[ ! "$NAME" =~ $PATTERN ]]; then
            continue
        fi

        RUNNING=$(docker inspect \
            --format '{{.State.Running}}' \
            "$ID" 2>/dev/null)

        [ "$RUNNING" != "true" ] && continue

        CURRENT_STARTED=$(docker inspect \
            --format '{{.State.StartedAt}}' \
            "$ID" 2>/dev/null)

        #######################################################################
        # Novo container
        #######################################################################

        if [ -z "${INITIAL_STARTED_AT[$ID]+x}" ]; then

            TARGET_ID="$ID"
            TARGET_NAME="$NAME"

        #######################################################################
        # Container existente que acabou de ser iniciado/reiniciado
        #######################################################################

        elif [ "${INITIAL_STARTED_AT[$ID]}" != "$CURRENT_STARTED" ]; then

            TARGET_ID="$ID"
            TARGET_NAME="$NAME"

        else
            continue
        fi

        STARTED_AT_UTC="$CURRENT_STARTED"
        STARTED_AT_LOCAL=$(to_local_time "$STARTED_AT_UTC")
        STARTED_EPOCH=$(to_epoch "$STARTED_AT_UTC")

        break 2

    done < <(
        docker ps -a \
            --format '{{.ID}} {{.Names}}'
    )

    sleep 1

done

###############################################################################
# Container detectado
###############################################################################

DETECTED_AT=$(local_time)

echo
echo "============================================================"
echo "CONTAINER INICIADO"
echo "============================================================"
echo
echo "Nome       : $TARGET_NAME"
echo "ID         : $TARGET_ID"
echo "StartedAt  : $STARTED_AT_LOCAL"
echo "Detectado  : $DETECTED_AT"
echo

echo "$DETECTED_AT|START_DETECTED|$TARGET_NAME|$TARGET_ID|running|starting|" \
    >> "$WORKDIR/events.log"

###############################################################################
# Docker stats
###############################################################################

docker stats "$TARGET_NAME" \
    --format '{{.Container}}|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' \
    > "$WORKDIR/docker_stats.log" 2>&1 &

COLLECTOR_PIDS+=("$!")

###############################################################################
# Health monitoring
###############################################################################

echo \
"timestamp|status|health|restart_count|started_at" \
    > "$WORKDIR/health.log"

LAST_HEALTH=""
LAST_STARTED_AT="$STARTED_AT_UTC"

echo "Monitorando healthcheck..."
echo

while true; do

    NOW=$(local_time)

    ###########################################################################
    # Container pode estar momentaneamente indisponível durante manipulação
    ###########################################################################

    if ! docker inspect "$TARGET_NAME" >/dev/null 2>&1; then

        echo "$NOW|container_missing|||$LAST_STARTED_AT" \
            >> "$WORKDIR/health.log"

        sleep 1
        continue
    fi

    STATUS=$(docker inspect \
        --format '{{.State.Status}}' \
        "$TARGET_NAME" 2>/dev/null)

    HEALTH=$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$TARGET_NAME" 2>/dev/null)

    RESTART_COUNT=$(docker inspect \
        --format '{{.RestartCount}}' \
        "$TARGET_NAME" 2>/dev/null)

    CURRENT_STARTED_AT=$(docker inspect \
        --format '{{.State.StartedAt}}' \
        "$TARGET_NAME" 2>/dev/null)

    echo \
"$NOW|$STATUS|$HEALTH|$RESTART_COUNT|$CURRENT_STARTED_AT" \
        >> "$WORKDIR/health.log"

    ###########################################################################
    # Detectar eventual restart enquanto ainda estava inicializando
    ###########################################################################

    if [ "$CURRENT_STARTED_AT" != "$LAST_STARTED_AT" ]; then

        echo "$NOW|RESTART_DETECTED|$TARGET_NAME|$TARGET_ID|$STATUS|$HEALTH|$RESTART_COUNT" \
            >> "$WORKDIR/events.log"

        echo
        echo "ATENÇÃO: restart detectado em $NOW"
        echo "Novo StartedAt: $CURRENT_STARTED_AT"
        echo

        LAST_STARTED_AT="$CURRENT_STARTED_AT"
    fi

    ###########################################################################
    # Mostrar somente mudanças de health no terminal
    ###########################################################################

    if [ "$HEALTH" != "$LAST_HEALTH" ]; then

        echo "[$NOW] health = $HEALTH"

        echo "$NOW|HEALTH_CHANGE|$TARGET_NAME|$TARGET_ID|$STATUS|$HEALTH|$RESTART_COUNT" \
            >> "$WORKDIR/events.log"

        LAST_HEALTH="$HEALTH"
    fi

    ###########################################################################
    # Healthy
    ###########################################################################

    if [ "$HEALTH" = "healthy" ]; then

        #
        # O último healthcheck concluído é o responsável por mudar para healthy.
        #

        HEALTHY_AT_UTC=$(docker inspect \
            --format '{{range .State.Health.Log}}{{.End}}|{{.ExitCode}}{{"\n"}}{{end}}' \
            "$TARGET_NAME" 2>/dev/null |
            tail -1 |
            cut -d'|' -f1)

        #
        # Caso não seja possível extrair o End do healthcheck,
        # usamos o horário em que detectamos healthy.
        #

        if [ -z "$HEALTHY_AT_UTC" ]; then
            HEALTHY_AT_UTC=$(date --iso-8601=ns)
        fi

        HEALTHY_AT_LOCAL=$(to_local_time "$HEALTHY_AT_UTC")
        HEALTHY_EPOCH=$(to_epoch "$HEALTHY_AT_UTC")

        echo
        echo "============================================================"
        echo "CONTAINER HEALTHY"
        echo "============================================================"
        echo
        echo "StartedAt : $STARTED_AT_LOCAL"
        echo "Healthy   : $HEALTHY_AT_LOCAL"
        echo

        if [ -n "$STARTED_EPOCH" ] && [ -n "$HEALTHY_EPOCH" ]; then

            TOTAL=$(elapsed \
                "$STARTED_EPOCH" \
                "$HEALTHY_EPOCH")

            echo "Tempo total: $(format_elapsed "$TOTAL")"
            echo
        fi

        FINAL_REASON="container atingiu estado healthy"

        break
    fi

    sleep "$INTERVAL"

done

###############################################################################
# Finalizar
###############################################################################

finalize

exit 0