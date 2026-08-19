#!/bin/bash

PEM="$1"

RED="\e[1;31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RESET="\e[0m"

ALERT_DAYS=30
ALERT_SECONDS=$((ALERT_DAYS * 86400))
NOW_EPOCH=$(date +%s)

if [[ -z "$PEM" || ! -f "$PEM" ]]; then
  echo "Uso: $0 arquivo.pem"
  exit 1
fi

TMPDIR=$(mktemp -d)

PEM_OK=1
FORMAT_OK=1
COUNT=0

echo "=================================================="
echo "Desenvolvido por: Herbert Pessoa (DigiSystem)"
echo "Sintaxe: ./validaPEM.sh {caminhoPEM.pem}"
echo "Validando PEM: $PEM"
echo "=================================================="
echo

# --------------------------------------------------
# Extrair certificados
# --------------------------------------------------
awk '
/BEGIN CERTIFICATE/ {i++; out=sprintf("'"$TMPDIR"'/cert_%d.pem", i)}
out {print > out}
' "$PEM"

CERTS=("$TMPDIR"/cert_*.pem)
CERT_TOTAL=${#CERTS[@]}

# --------------------------------------------------
# Validacao SEMANTICA (Padrao Philips)
# --------------------------------------------------
if [[ "$CERT_TOTAL" -lt 2 ]]; then
  FORMAT_OK=0
fi

# LEAF
openssl x509 -in "$TMPDIR/cert_1.pem" -noout -text | grep -A1 "Basic Constraints" | grep -q "CA:FALSE" || FORMAT_OK=0
openssl x509 -in "$TMPDIR/cert_1.pem" -noout -ext subjectAltName >/dev/null 2>&1 || FORMAT_OK=0

# INTERMEDIARIOS
if [[ "$CERT_TOTAL" -gt 2 ]]; then
  for ((i=2; i<=$((CERT_TOTAL-1)); i++)); do
    openssl x509 -in "$TMPDIR/cert_$i.pem" -noout -text | grep -A1 "Basic Constraints" | grep -q "CA:TRUE" || FORMAT_OK=0
  done
fi

# ROOT
openssl x509 -in "$TMPDIR/cert_$CERT_TOTAL.pem" -noout -text | grep -A1 "Basic Constraints" | grep -q "CA:TRUE" || FORMAT_OK=0

# Deve existir chave privada
grep -Eq "BEGIN (RSA )?PRIVATE KEY" "$PEM" || FORMAT_OK=0

[[ "$FORMAT_OK" -eq 0 ]] && PEM_OK=0

# --------------------------------------------------
# Analise amigavel dos certificados
# --------------------------------------------------
for cert in "${CERTS[@]}"; do
  COUNT=$((COUNT+1))

  SUBJECT=$(openssl x509 -in "$cert" -noout -subject | sed 's/^subject= //')
  ISSUER=$(openssl x509 -in "$cert" -noout -issuer  | sed 's/^issuer= //')
  NOTBEFORE=$(openssl x509 -in "$cert" -noout -startdate | cut -d= -f2)
  NOTAFTER=$(openssl x509 -in "$cert" -noout -enddate   | cut -d= -f2)
  SAN=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | sed '1d')

  END_EPOCH=$(date -d "$NOTAFTER" +%s 2>/dev/null)
  DELTA=$((END_EPOCH - NOW_EPOCH))

  if openssl x509 -in "$cert" -noout -text | grep -A1 "Basic Constraints" | grep -q "CA:FALSE"; then
    TYPE="LEAF"
  elif [[ "$COUNT" -eq "$CERT_TOTAL" ]]; then
    TYPE="ROOT"
  else
    TYPE="INTERMEDIATE"
  fi

  echo "Certificado #$COUNT ($TYPE)"
  echo "  Subject : $SUBJECT"
  echo "  Issuer  : $ISSUER"
  echo "  Valido de $NOTBEFORE ate $NOTAFTER"

  if [[ "$DELTA" -le "$ALERT_SECONDS" ]]; then
    echo -e "  Status  : ${RED}ATENCAO - vence em menos de $ALERT_DAYS dias${RESET}"
    PEM_OK=0
  fi

  [[ -n "$SAN" ]] && echo "  SAN     : $SAN"
  echo
done

# --------------------------------------------------
# Verificar chave privada (FORMA CORRETA)
# --------------------------------------------------
KEY="$TMPDIR/privkey.pem"

openssl pkey -in "$PEM" -out "$KEY" 2>/dev/null

echo "Chave privada:"

if openssl pkey -in "$KEY" -noout >/dev/null 2>&1; then

  CERT_PUB=$(openssl x509 -in "$TMPDIR/cert_1.pem" -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | openssl md5)

  KEY_PUB=$(openssl pkey -in "$KEY" -pubout \
    | openssl pkey -pubin -outform DER \
    | openssl md5)

  if [[ "$CERT_PUB" == "$KEY_PUB" ]]; then
    echo "  OK - corresponde ao certificado do site"
  else
    echo -e "  ${RED}ERRO - chave nao corresponde ao certificado${RESET}"
    PEM_OK=0
  fi

else
  echo -e "  ${RED}ERRO - chave privada invalida${RESET}"
  PEM_OK=0
fi


# --------------------------------------------------
# Resumo final
# --------------------------------------------------
echo
echo "Resumo:"
echo "  Certificados encontrados : $CERT_TOTAL"

if [[ "$FORMAT_OK" -eq 1 ]]; then
  echo "  Formato PEM (Padrao Philips) : ATENDE"
else
  echo -e "  Formato PEM (Padrao Philips) : ${RED}NAO ATENDE${RESET}"
fi

if [[ "$PEM_OK" -eq 1 ]]; then
  echo -e "  Status geral                 : ${GREEN}PEM VALIDO E FUNCIONAL${RESET}"
else
  echo -e "  Status geral                 : ${RED}PEM COM ALERTAS / ERROS${RESET}"
fi

echo "=================================================="

rm -rf "$TMPDIR"
