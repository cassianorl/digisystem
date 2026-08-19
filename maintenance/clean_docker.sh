{
SCRIPT_DIR="/u01/script"
SCRIPT_PATH="${SCRIPT_DIR}/dockerCleanupFiles.sh"
LOG_PATH="${SCRIPT_DIR}/dockerCleanupFiles.log"
CRON_JOB="0 3 * * * ${SCRIPT_PATH} >> ${LOG_PATH} 2>&1"

mkdir -p "${SCRIPT_DIR}"
chmod 755 "${SCRIPT_DIR}"

cat > "${SCRIPT_PATH}" << 'EOF'
#!/bin/bash

echo "===== INÍCIO DA LIMPEZA DE CONTAINERS DOCKER ====="
echo "Data: $(date)"
echo

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

containers=$(docker ps -q)

for container_id in $containers; do
    name=$(docker inspect --format '{{.Name}}' "$container_id" | sed 's|/||')
    full_container_id=$(docker inspect --format '{{.Id}}' "$container_id" 2>/dev/null)
    json_log="/var/lib/docker/containers/${full_container_id}/${full_container_id}-json.log"

    echo "Container: $name"
    echo "ID: $container_id"
    echo "ID completo: $full_container_id"

    size_before=$(docker exec "$container_id" sh -c '
        du -sb /opt/apache-tomcat-* /tmp 2>/dev/null | awk "{s+=\$1} END {printf \"%.2f GB\", s/1024/1024/1024}"
    ' 2>/dev/null || echo "0 GB")

    echo "Uso de disco ANTES: $size_before"

    if [[ -f "$json_log" ]]; then
        size_bytes=$(stat -c %s "$json_log" 2>/dev/null || echo 0)
        echo "Log Docker atual: $(du -h "$json_log" 2>/dev/null | awk '{print $1}')"

        if [[ "$size_bytes" -gt 1073741824 ]]; then
            echo "Log maior que 1 GiB. Mantendo apenas as últimas 1000 linhas..."

            tmp_file=$(mktemp)

            if tail -n 1000 "$json_log" > "$tmp_file"; then
                cat "$tmp_file" > "$json_log"
                echo "Log reduzido com sucesso."
                echo "Novo tamanho do log: $(du -h "$json_log" 2>/dev/null | awk '{print $1}')"
            else
                echo "ERRO: falha ao tratar $json_log"
            fi

            rm -f "$tmp_file"
        else
            echo "Log menor que 1 GiB. Nenhuma ação necessária."
        fi
    fi

    docker exec "$container_id" sh -c '
        for TOMCAT in /opt/apache-tomcat-*; do
            [ -d "$TOMCAT" ] || continue

            if [ -d "$TOMCAT/temp" ]; then
                find "$TOMCAT/temp" -maxdepth 1 -type f -mtime +3 -exec rm -f {} \;
            fi

            if [ -d "$TOMCAT/temp/TasyTemp" ]; then
                find "$TOMCAT/temp/TasyTemp" -depth -mindepth 1 -mtime +3 -exec rm -rf {} \; 2>/dev/null
            fi

            if [ -d "$TOMCAT/logs" ]; then
                find "$TOMCAT/logs" -type f -mtime +1 -exec rm -f {} \;
            fi
        done

        if [ -d /tmp ]; then
            find /tmp -maxdepth 1 -type f -mtime +2 -exec rm -f {} \;
        fi
    ' 2>/dev/null

    size_after=$(docker exec "$container_id" sh -c '
        du -sb /opt/apache-tomcat-* /tmp 2>/dev/null | awk "{s+=\$1} END {printf \"%.2f GB\", s/1024/1024/1024}"
    ' 2>/dev/null || echo "0 GB")

    echo "Uso de disco DEPOIS: $size_after"
    echo "Finalizado container: $name"
    echo "------------------------------------------"
done

echo "Limpando logs Docker *-json.log em /var/lib/docker/containers"

find /var/lib/docker/containers -type f -name "*-json.log" -print0 2>/dev/null | while IFS= read -r -d '' json_log; do
    echo "Arquivo encontrado: $json_log"

    size_bytes=$(stat -c %s "$json_log" 2>/dev/null || echo 0)
    echo "Tamanho atual: $(du -h "$json_log" 2>/dev/null | awk '{print $1}')"

    if [[ "$size_bytes" -gt 1073741824 ]]; then
        echo "Log maior que 1 GiB. Mantendo apenas as últimas 1000 linhas..."

        tmp_file=$(mktemp)

        if tail -n 1000 "$json_log" > "$tmp_file"; then
            cat "$tmp_file" > "$json_log"
            echo "Log $json_log reduzido com sucesso."
            echo "Novo tamanho: $(du -h "$json_log" 2>/dev/null | awk '{print $1}')"
        else
            echo "ERRO: falha ao tratar $json_log"
        fi

        rm -f "$tmp_file"
    else
        echo "Log menor que 1 GiB. Nenhuma ação necessária."
    fi

    echo "------------------------------------------"
done

echo "Removendo /var/log/secure e message antigos"

rm -Rf /var/log/secure-*
rm -Rf /var/log/messages-*

echo "===== LIMPEZA CONCLUÍDA ====="

EOF

chmod 755 "${SCRIPT_PATH}"

( crontab -l 2>/dev/null | grep -Fv "${SCRIPT_PATH}" ; echo "${CRON_JOB}" ) | sort -u | crontab -

bash "${SCRIPT_PATH}"
}