#!/usr/bin/env bash

_certificates_file_ok() {
  [[ -n "${1:-}" && -f "$1" && -r "$1" ]] || {
    shellops_error "Arquivo inexistente ou sem leitura: ${1:-N/A}"
    return 2
  }
}

_certificates_destination_ok() {
  local destination="${1:-}" parent
  [[ -n "$destination" ]] || { shellops_error "Informe o destino."; return 2; }
  [[ ! -e "$destination" ]] || { shellops_error "O destino já existe e não será sobrescrito: $destination"; return 3; }
  parent="$(dirname -- "$destination")"
  [[ -d "$parent" && -w "$parent" ]] || { shellops_error "Diretório de destino inválido ou sem escrita: $parent"; return 2; }
}

_certificates_secure_file() { chmod 600 -- "$1" 2>/dev/null || true; }
_certificates_public_file() { chmod 644 -- "$1" 2>/dev/null || chmod go-w -- "$1" 2>/dev/null || true; }
_certificates_openssl() { shellops_require_command openssl "OpenSSL não está disponível."; }

_certificates_keytool_password_mode() {
  local probe
  shellops_has_command keytool || return 1
  probe="$(SHELLOPS_KT_PROBE= keytool -list -keystore /__shellops_capability_probe__ \
    -storepass:env SHELLOPS_KT_PROBE 2>&1 || true)"
  printf '%s\n' "$probe" | grep -Eqi 'illegal option|unknown password type|unrecognized option|opção.*inválida' && return 1
  printf 'env\n'
}

_certificates_format() {
  local file="$1" first_hex
  _certificates_file_ok "$file" || return
  if grep -aEq '^-----BEGIN (CERTIFICATE|((RSA|EC|DSA|ENCRYPTED) )?PRIVATE KEY|PKCS7)-----$' "$file" 2>/dev/null; then
    printf 'PEM\n'; return
  fi
  first_hex="$(od -An -tx1 -N4 -- "$file" 2>/dev/null | tr -d ' \n')"
  [[ "$first_hex" == feedfeed ]] && { printf 'JKS\n'; return; }
  openssl x509 -inform DER -in "$file" -noout >/dev/null 2>&1 && { printf 'DER\n'; return; }
  SHELLOPS_OPENSSL_PASS= openssl pkcs12 -in "$file" -noout -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1 &&
    { printf 'PKCS12\n'; return; }
  case "${file,,}" in
    *.p12|*.pfx|*.pkcs12) printf 'PKCS12 (não confirmado; pode exigir senha)\n' ;;
    *.jks) printf 'JKS (não confirmado)\n' ;;
    *) printf 'UNKNOWN\n' ;;
  esac
}

_certificates_pem_counts() {
  printf '%s|%s\n' \
    "$(grep -ac '^-----BEGIN CERTIFICATE-----$' "$1" 2>/dev/null || true)" \
    "$(grep -aEc '^-----BEGIN ((RSA|EC|DSA|ENCRYPTED) )?PRIVATE KEY-----$' "$1" 2>/dev/null || true)"
}

_certificates_days_left() {
  local file="$1" form="${2:-PEM}" end epoch now
  end="$(openssl x509 -inform "$form" -in "$file" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" || return
  epoch="$(date -d "$end" +%s 2>/dev/null)" || return
  now="$(date +%s)"
  printf '%s\n' "$(( (epoch - now) / 86400 ))"
}

_certificates_validity() {
  local file="$1" form="${2:-PEM}" days
  if ! openssl x509 -inform "$form" -in "$file" -noout -checkend 0 >/dev/null 2>&1; then
    printf 'CERTIFICATE VALIDITY: EXPIRED ou NOT YET VALID\n'; return
  fi
  days="$(_certificates_days_left "$file" "$form" 2>/dev/null || printf N/A)"
  printf 'CERTIFICATE VALIDITY: VALID; dias restantes=%s\n' "$days"
  [[ "$days" =~ ^-?[0-9]+$ && "$days" -le 30 ]] &&
    printf 'WARNING — heurística operacional ShellOps: expiração em até 30 dias.\n'
}

_certificates_certificate_metadata() {
  local file="$1" form="${2:-PEM}"
  openssl x509 -inform "$form" -in "$file" -noout -subject -issuer -serial -dates -fingerprint -sha256 2>/dev/null || return
  openssl x509 -inform "$form" -in "$file" -noout -ext subjectAltName 2>/dev/null || printf 'subjectAltName: N/A\n'
  openssl x509 -inform "$form" -in "$file" -noout -text 2>/dev/null | awk '
    /Signature Algorithm:/ && !sig++ {sub(/^[[:space:]]*/, ""); print}
    /Public Key Algorithm:|Public-Key:/ {sub(/^[[:space:]]*/, ""); print}
    /X509v3 Key Usage:|X509v3 Extended Key Usage:|X509v3 Basic Constraints:/ {
      sub(/^[[:space:]]*/, ""); print; getline; sub(/^[[:space:]]*/, ""); print
    }'
}

_certificates_extract_pem_certificates() {
  awk -v dir="$2" '
    /^-----BEGIN CERTIFICATE-----$/ {n++; out=sprintf("%s/cert_%04d.pem",dir,n); writing=1}
    writing {print > out}
    /^-----END CERTIFICATE-----$/ {writing=0; close(out)}
  ' "$1"
}

_certificates_ca_classification() {
  local cert="$1" subject issuer ca=no
  openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -A1 'Basic Constraints' | grep -q 'CA:TRUE' && ca=yes
  subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  issuer="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  if [[ "$ca" == yes && -n "$subject" && "$subject" == "$issuer" ]] &&
     openssl verify -CAfile "$cert" "$cert" >/dev/null 2>&1; then
    printf 'self-signed candidate'
  elif [[ "$ca" == yes ]]; then printf 'CA certificate'
  else printf 'end-entity certificate'; fi
}

certificates_analyze_file() {
  local file="${1:-}" format counts certs keys size permissions
  _certificates_openssl || return; _certificates_file_ok "$file" || return
  format="$(_certificates_format "$file")"
  size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
  permissions="$(stat -c '%A (%a)' -- "$file" 2>/dev/null || printf N/A)"
  printf 'Arquivo: %s\nFormato detectado: %s\nTamanho: %s bytes\nPermissões: %s\n' "$file" "$format" "${size:-N/A}" "$permissions"
  case "$format" in
    PEM) counts="$(_certificates_pem_counts "$file")"; IFS='|' read -r certs keys <<< "$counts"
      printf 'Conteúdo reconhecido: certificados=%s; chaves privadas=%s\nMaterial bruto não exibido.\n' "$certs" "$keys" ;;
    DER) printf 'Conteúdo reconhecido: certificado X.509 em DER\n' ;;
    JKS*) printf 'Conteúdo reconhecido: keystore JKS%s\n' "${format#JKS}" ;;
    PKCS12*) printf 'Conteúdo reconhecido: container PKCS#12/PFX/P12%s\n' "${format#PKCS12}" ;;
    *) printf 'Conteúdo reconhecido: N/A. O arquivo não foi exibido nem submetido a parsing extensivo.\n' ;;
  esac
}

certificates_inspect_certificate() (
  local file="${1:-}" format temp_dir cert index=0 class
  _certificates_openssl || return; _certificates_file_ok "$file" || return
  format="$(_certificates_format "$file")"
  case "$format" in
    DER) _certificates_certificate_metadata "$file" DER; _certificates_validity "$file" DER ;;
    PEM)
      temp_dir="$(mktemp -d)" || return
      trap 'rm -rf -- "$temp_dir"' EXIT
      trap 'exit 130' HUP INT TERM
      _certificates_extract_pem_certificates "$file" "$temp_dir"
      for cert in "$temp_dir"/cert_*.pem; do
        [[ -f "$cert" ]] || continue; index=$((index + 1)); class="$(_certificates_ca_classification "$cert")"
        printf '\nCertificado #%s — %s\n' "$index" "$class"
        _certificates_certificate_metadata "$cert" PEM || printf 'N/A — certificado não interpretado com segurança.\n'
        _certificates_validity "$cert" PEM
      done
      (( index > 0 )) || { printf 'N/A — nenhum certificado X.509 PEM reconhecido.\n'; return 1; } ;;
    *) printf 'N/A — o arquivo não é um certificado PEM/DER reconhecido.\n'; return 2 ;;
  esac
)

certificates_validate_pem() {
  local pem_file="${1:-}" status
  [[ -n "$pem_file" ]] || { shellops_error "Informe o arquivo PEM."; return 2; }
  [[ "$pem_file" == /* ]] || pem_file="./$pem_file"
  shellops_require_commands openssl awk grep sed cut date mktemp || return
  shellops_run_legacy "maintenance/valida_pem.sh" "$pem_file"; status=$?
  printf '\nObservação: resultado do script legado. Validações genéricas modernas são independentes.\n'
  return "$status"
}

certificates_match_certificate_key() (
  local certificate="${1:-}" key="${2:-}" cert_der key_der temp_dir status=2
  _certificates_openssl || return
  _certificates_file_ok "$certificate" || { printf 'N/A\n'; return 2; }
  _certificates_file_ok "$key" || { printf 'N/A\n'; return 2; }
  temp_dir="$(mktemp -d)" || { printf 'N/A\n'; return 1; }
  cert_der="$temp_dir/cert.der"; key_der="$temp_dir/key.der"
  trap 'rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  if openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null |
       openssl pkey -pubin -outform DER -out "$cert_der" 2>/dev/null &&
     openssl pkey -in "$key" -pubout -outform DER -out "$key_der" 2>/dev/null; then
    if cmp -s -- "$cert_der" "$key_der"; then printf 'MATCH\n'; status=0
    else printf 'MISMATCH\n'; status=1; fi
  else printf 'N/A\n'; fi
  return "$status"
)

certificates_validate_chain() {
  local leaf="${1:-}" intermediates="${2:-}" anchor="${3:-}" hostname="${4:-}" status output
  _certificates_openssl || return; _certificates_file_ok "$leaf" || return
  [[ -z "$intermediates" ]] || _certificates_file_ok "$intermediates" || return
  [[ -z "$anchor" ]] || _certificates_file_ok "$anchor" || return
  _certificates_validity "$leaf" PEM
  if [[ -n "$anchor" ]]; then
    if [[ -n "$intermediates" ]]; then output="$(openssl verify -CAfile "$anchor" -untrusted "$intermediates" "$leaf" 2>&1)"; status=$?
    else output="$(openssl verify -CAfile "$anchor" "$leaf" 2>&1)"; status=$?; fi
    if (( status == 0 )); then printf 'CHAIN VALIDATION: CHAIN OK — cadeia criptograficamente verificável com trust anchor informado.\n'
    else printf 'CHAIN VALIDATION: FAILED — %s\n' "$(printf '%s' "$output" | head -n 2)"; fi
    printf 'TRUST: isso não comprova confiança pública; não foi usado trust store público do sistema.\n'
  else printf 'CHAIN VALIDATION: N/A — trust anchor não fornecido.\n'; fi
  if [[ -n "$hostname" ]]; then
    if openssl x509 -in "$leaf" -noout -checkhost "$hostname" >/dev/null 2>&1; then printf 'HOSTNAME MATCH\n'
    elif openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then printf 'HOSTNAME MISMATCH\n'
    else printf 'HOSTNAME N/A\n'; fi
  else printf 'HOSTNAME N/A — não solicitado.\n'; fi
}

certificates_inspect_pkcs12() (
  set +x
  local source="${1:-}" password="${2:-}" temp_dir cert_count key_count friendly
  _certificates_openssl || return; _certificates_file_ok "$source" || return
  temp_dir="$(mktemp -d)" || return
  trap 'unset password; rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  if ! SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -nodes -out "$temp_dir/content.pem" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1; then
    printf 'N/A — senha inválida ou PKCS#12 não interpretado.\n'; return 1
  fi
  _certificates_secure_file "$temp_dir/content.pem"
  IFS='|' read -r cert_count key_count <<< "$(_certificates_pem_counts "$temp_dir/content.pem")"
  printf 'Formato: PKCS#12/PFX/P12\nCertificados: %s\nChaves privadas: %s\n' "$cert_count" "$key_count"
  friendly="$(SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -info -noout -passin env:SHELLOPS_OPENSSL_PASS 2>&1 |
    sed -n 's/^[[:space:]]*friendlyName:[[:space:]]*/friendlyName: /p' | head -n 20)"
  [[ -n "$friendly" ]] && printf '%s\n' "$friendly"
  printf 'Material de chave privada não exibido.\n'
  certificates_inspect_certificate "$temp_dir/content.pem" || true
)

_certificates_publish() {
  local temporary="$1" destination="$2" sensitive="${3:-no}"
  [[ -s "$temporary" ]] || { shellops_error "Artefato temporário vazio; nada foi publicado."; return 1; }
  _certificates_destination_ok "$destination" || return
  if [[ "$sensitive" == yes ]]; then _certificates_secure_file "$temporary"; else _certificates_public_file "$temporary"; fi
  mv -- "$temporary" "$destination" || return
  printf 'Artefato publicado: %s\n' "$destination"
  stat -c 'Permissões: %A (%a)' -- "$destination" 2>/dev/null || true
}

certificates_pkcs12_to_pem() (
  set +x
  local source="${1:-}" password="${2:-}" mode="${3:-complete}" destination="${4:-}" confirmation="${5:-}"
  local temp_dir temporary sensitive=no status
  _certificates_openssl || return; _certificates_file_ok "$source" || return; _certificates_destination_ok "$destination" || return
  case "$mode" in complete|key) sensitive=yes ;; certificate|chain) ;; *) shellops_error "Modo inválido."; return 2 ;; esac
  if [[ "$sensitive" == yes ]]; then
    printf 'ATENÇÃO\nO arquivo resultante conterá uma chave privada sem criptografia.\n\nClassificação:\nALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\n'
    [[ "$confirmation" == CONFIRM_SENSITIVE ]] || { printf 'Operação cancelada: confirmação específica ausente.\n'; return 3; }
  else printf 'Classificação: ALTERAÇÃO LOCAL / ARTEFATO GERADO\n'; fi
  temp_dir="$(mktemp -d "$(dirname -- "$destination")/.shellops-cert.XXXXXX")" || return
  temporary="$temp_dir/artifact"
  trap 'unset password; rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  case "$mode" in
    complete) SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -nodes -out "$temporary" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1; status=$? ;;
    key) SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -nocerts -nodes -out "$temporary" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1; status=$? ;;
    certificate) SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -clcerts -nokeys -out "$temporary" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1; status=$? ;;
    chain) SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -cacerts -nokeys -out "$temporary" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1; status=$? ;;
  esac
  (( status == 0 )) || { shellops_error "Falha na conversão PKCS#12."; return 1; }
  _certificates_publish "$temporary" "$destination" "$sensitive"
)

certificates_pkcs12_to_pem_separated() (
  set +x
  local source="${1:-}" password="${2:-}" destination_dir="${3:-}" confirmation="${4:-}"
  local temp_dir cert index=0 class published_file
  local -a published=()
  [[ "$confirmation" == CONFIRM_SENSITIVE ]] || {
    printf 'ATENÇÃO\nO arquivo private.key resultante conterá uma chave privada sem criptografia.\n\nClassificação:\nALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\nOperação cancelada: confirmação específica ausente.\n'
    return 3
  }
  _certificates_openssl || return; _certificates_file_ok "$source" || return
  [[ -d "$destination_dir" && -w "$destination_dir" ]] || { shellops_error "Diretório destino inválido."; return 2; }
  local name
  for name in certificate.pem private.key chain.pem fullchain.pem; do
    [[ ! -e "$destination_dir/$name" ]] || { shellops_error "O arquivo já existe e não será sobrescrito: $destination_dir/$name"; return 3; }
  done
  printf 'ATENÇÃO\nO arquivo resultante conterá uma chave privada sem criptografia.\n\nClassificação:\nALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\n'
  temp_dir="$(mktemp -d "$destination_dir/.shellops-cert.XXXXXX")" || return
  trap 'unset password; rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -clcerts -nokeys -out "$temp_dir/certificate.pem" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1 &&
  SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -nocerts -nodes -out "$temp_dir/private.key" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1 &&
  SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$source" -cacerts -nokeys -out "$temp_dir/ca-all.pem" -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1 ||
    { shellops_error "Falha ao extrair os componentes PKCS#12."; return 1; }
  : > "$temp_dir/chain.pem"; mkdir "$temp_dir/extracted" || return
  _certificates_extract_pem_certificates "$temp_dir/ca-all.pem" "$temp_dir/extracted"
  for cert in "$temp_dir"/extracted/cert_*.pem; do
    [[ -f "$cert" ]] || continue; class="$(_certificates_ca_classification "$cert")"
    if [[ "$class" == 'self-signed candidate' ]]; then
      index=$((index + 1)); cp -- "$cert" "$temp_dir/root-${index}.pem"
    else cat -- "$cert" >> "$temp_dir/chain.pem"; fi
  done
  cat -- "$temp_dir/certificate.pem" "$temp_dir/chain.pem" > "$temp_dir/fullchain.pem"
  _certificates_secure_file "$temp_dir/private.key"
  _certificates_public_file "$temp_dir/certificate.pem"; _certificates_public_file "$temp_dir/chain.pem"; _certificates_public_file "$temp_dir/fullchain.pem"
  [[ -s "$temp_dir/certificate.pem" && -s "$temp_dir/private.key" && -s "$temp_dir/fullchain.pem" ]] ||
    { shellops_error "Artefatos gerados não passaram na validação."; return 1; }
  for name in certificate.pem private.key chain.pem fullchain.pem; do
    if mv -- "$temp_dir/$name" "$destination_dir/$name"; then published+=("$destination_dir/$name")
    else
      for published_file in "${published[@]}"; do rm -f -- "$published_file"; done
      shellops_error "Falha ao publicar os artefatos; somente arquivos criados por esta operação foram removidos."
      return 1
    fi
  done
  for cert in "$temp_dir"/root-*.pem; do
    [[ -f "$cert" ]] || continue
    name="$(basename -- "$cert")"; [[ ! -e "$destination_dir/$name" ]] && { _certificates_public_file "$cert"; mv -- "$cert" "$destination_dir/$name"; }
  done
  printf 'Arquivos publicados em %s\nfullchain.pem = leaf + intermediários; nunca inclui private key.\nRaízes self-signed candidatas foram mantidas separadas quando detectadas.\n' "$destination_dir"
  stat -c '%n: %A (%a)' -- "$destination_dir/certificate.pem" "$destination_dir/private.key" "$destination_dir/chain.pem" "$destination_dir/fullchain.pem" 2>/dev/null || true
)

certificates_pem_to_pkcs12() (
  set +x
  local certificate="${1:-}" key="${2:-}" chain="${3:-}" destination="${4:-}" password="${5:-}"
  local temp_dir temporary match
  _certificates_openssl || return; _certificates_file_ok "$certificate" || return; _certificates_file_ok "$key" || return
  [[ -z "$chain" ]] || _certificates_file_ok "$chain" || return; _certificates_destination_ok "$destination" || return
  match="$(certificates_match_certificate_key "$certificate" "$key")"
  [[ "$match" == MATCH ]] || { printf '%s\nConversão cancelada.\n' "$match"; return 3; }
  printf 'Classificação: ALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\n'
  temp_dir="$(mktemp -d "$(dirname -- "$destination")/.shellops-cert.XXXXXX")" || return
  temporary="$temp_dir/artifact.p12"
  trap 'unset password; rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  if [[ -n "$chain" ]]; then
    SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -export -in "$certificate" -inkey "$key" -certfile "$chain" -out "$temporary" -passout env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1
  else SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -export -in "$certificate" -inkey "$key" -out "$temporary" -passout env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1; fi ||
    { shellops_error "Falha na conversão para PKCS#12."; return 1; }
  SHELLOPS_OPENSSL_PASS="$password" openssl pkcs12 -in "$temporary" -noout -passin env:SHELLOPS_OPENSSL_PASS >/dev/null 2>&1 ||
    { shellops_error "O artefato gerado não passou na validação."; return 1; }
  _certificates_publish "$temporary" "$destination" yes
)

_certificates_keytool_run() {
  set +x
  local source="$1" destination="$2" source_type="$3" destination_type="$4"
  local source_password="$5" destination_password="$6" alias="${7:-}" source_key_password="${8:-$5}"
  _certificates_keytool_password_mode >/dev/null || {
    printf 'N/A — transporte seguro de senha não disponível nesta versão\n'; return 4
  }
  if [[ -n "$alias" ]]; then
    SHELLOPS_KT_SRC="$source_password" SHELLOPS_KT_DST="$destination_password" \
      SHELLOPS_KT_KEY="$source_key_password" keytool -importkeystore -noprompt \
      -srckeystore "$source" -srcstoretype "$source_type" -srcalias "$alias" -srcstorepass:env SHELLOPS_KT_SRC \
      -srckeypass:env SHELLOPS_KT_KEY -destkeystore "$destination" -deststoretype "$destination_type" \
      -deststorepass:env SHELLOPS_KT_DST -destkeypass:env SHELLOPS_KT_DST >/dev/null 2>&1
  else
    SHELLOPS_KT_SRC="$source_password" SHELLOPS_KT_DST="$destination_password" keytool -importkeystore -noprompt \
      -srckeystore "$source" -srcstoretype "$source_type" -srcstorepass:env SHELLOPS_KT_SRC \
      -destkeystore "$destination" -deststoretype "$destination_type" -deststorepass:env SHELLOPS_KT_DST >/dev/null 2>&1
  fi
}

_certificates_keystore_aliases() {
  set +x
  local source="$1" password="$2" type="$3" output status
  _certificates_keytool_password_mode >/dev/null || {
    printf 'N/A — transporte seguro de senha não disponível nesta versão\n'; return 4
  }
  output="$(SHELLOPS_KT_PASS="$password" keytool -list -keystore "$source" -storetype "$type" \
    -storepass:env SHELLOPS_KT_PASS 2>&1)"; status=$?
  (( status == 0 )) || { printf 'N/A — keystore não interpretado com segurança.\n'; return 1; }
  printf '%s\n' "$output" | awk -F, '/^[^[:space:]].*,.*,.*Entry/ {
    alias=$1; date=$2; type=$3;
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", alias);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", date);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", type);
    print alias "|" type "|" date
  }'
}

certificates_inspect_jks() {
  local source="${1:-}" password="${2:-}" records
  _certificates_file_ok "$source" || return; shellops_require_command keytool "keytool não está disponível." || return
  records="$(_certificates_keystore_aliases "$source" "$password" JKS)" || { printf '%s\n' "$records"; return 1; }
  printf 'Formato: JKS\nAlias|Entry type|Data\n%s\n' "${records:-N/A}"
  printf 'Inspeção sanitizada; conteúdo de chaves e saída detalhada não são exibidos.\n'
}

certificates_pkcs12_to_jks() (
  local source="${1:-}" source_password="${2:-}" destination="${3:-}" destination_password="${4:-}" temp_dir temporary
  _certificates_file_ok "$source" || return; _certificates_destination_ok "$destination" || return
  temp_dir="$(mktemp -d "$(dirname -- "$destination")/.shellops-cert.XXXXXX")" || return
  temporary="$temp_dir/artifact.jks"
  trap 'unset source_password destination_password; rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  printf 'Classificação: ALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\n'
  _certificates_keytool_run "$source" "$temporary" PKCS12 JKS "$source_password" "$destination_password" || return
  _certificates_publish "$temporary" "$destination" yes
)

certificates_jks_to_pkcs12() (
  local source="${1:-}" source_password="${2:-}" alias="${3:-}" destination="${4:-}" destination_password="${5:-}"
  local source_key_password="${6:-$source_password}" records entry temp_dir temporary
  _certificates_file_ok "$source" || return; _certificates_destination_ok "$destination" || return
  records="$(_certificates_keystore_aliases "$source" "$source_password" JKS)" || { printf '%s\n' "$records"; return 1; }
  [[ -n "$alias" ]] || { printf 'N/A — alias obrigatório. Aliases disponíveis:\n%s\n' "$records"; return 2; }
  entry="$(printf '%s\n' "$records" | awk -F'|' -v wanted="$alias" '$1==wanted {print $2; exit}')"
  [[ "$entry" == *PrivateKeyEntry* ]] || { printf 'N/A — o alias selecionado não é PrivateKeyEntry.\n'; return 3; }
  temp_dir="$(mktemp -d "$(dirname -- "$destination")/.shellops-cert.XXXXXX")" || return
  temporary="$temp_dir/artifact.p12"
  trap 'unset source_password destination_password; rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  printf 'Classificação: ALTERAÇÃO LOCAL / ARTEFATO SENSÍVEL GERADO\n'
  _certificates_keytool_run "$source" "$temporary" JKS PKCS12 \
    "$source_password" "$destination_password" "$alias" "$source_key_password" || return
  _certificates_publish "$temporary" "$destination" yes
)

certificates_test_remote_tls() (
  local host="${1:-}" port="${2:-443}" sni="${3:-$host}" temp_dir output leaf tls_status
  local verify_code protocol cipher chain_status=FAILED
  _certificates_openssl || return; shellops_require_command timeout "timeout é obrigatório para TLS remoto." || return
  [[ "$host" =~ ^[A-Za-z0-9._:-]+$ && "$sni" =~ ^[A-Za-z0-9._-]+$ &&
     "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] ||
    { shellops_error "Host, SNI ou porta inválidos."; return 2; }
  temp_dir="$(mktemp -d)" || return; output="$temp_dir/handshake"; leaf="$temp_dir/leaf.pem"
  trap 'rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  timeout 20 openssl s_client -connect "$host:$port" -servername "$sni" -showcerts </dev/null >"$output" 2>&1
  tls_status=$?; [[ "$tls_status" -ne 124 ]] || { printf 'TLS: timeout.\n'; return 124; }
  awk '/-----BEGIN CERTIFICATE-----/{take=1} take{print} /-----END CERTIFICATE-----/{exit}' "$output" > "$leaf"
  [[ -s "$leaf" ]] || { printf 'TLS: N/A — certificado remoto não recebido.\n'; return 1; }
  protocol="$(sed -n 's/^[[:space:]]*Protocol[[:space:]]*:[[:space:]]*/Protocol: /p' "$output" | head -n1)"
  cipher="$(sed -n 's/^[[:space:]]*Cipher[[:space:]]*:[[:space:]]*/Cipher: /p' "$output" | head -n1)"
  verify_code="$(sed -n 's/^Verify return code: /Verify return code: /p' "$output" | tail -n1)"
  [[ "$verify_code" == 'Verify return code: 0 '* ]] && chain_status='CHAIN OK'
  printf 'Destino: %s:%s\nSNI: %s\n%s\n%s\nCHAIN VALIDATION: %s (%s)\n' "$host" "$port" "$sni" \
    "${protocol:-Protocol: N/A}" "${cipher:-Cipher: N/A}" "$chain_status" "${verify_code:-N/A}"
  _certificates_validity "$leaf" PEM
  if openssl x509 -in "$leaf" -noout -checkhost "$sni" >/dev/null 2>&1; then printf 'HOSTNAME MATCH\n'
  elif openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then printf 'HOSTNAME MISMATCH\n'
  else printf 'HOSTNAME N/A\n'; fi
  printf '\nMetadados permitidos do certificado leaf:\n'; _certificates_certificate_metadata "$leaf" PEM
  printf '\nCadeia apresentada: %s certificado(s).\n' "$(grep -c '^-----BEGIN CERTIFICATE-----$' "$output" 2>/dev/null || true)"
  printf 'Session tickets, session IDs, certificados brutos e handshake completo foram omitidos.\n'
)
