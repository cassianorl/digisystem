#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
trap 'exit 130' HUP INT TERM

fail() { printf 'FAILED — %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK — %s\n' "$*"; }

source "$TEST_ROOT/lib/version.sh"
source "$TEST_ROOT/lib/common.sh"
source "$TEST_ROOT/lib/dependencies.sh"
source "$TEST_ROOT/lib/reporting.sh"
for module in system performance services network docker discovery health certificates reports tasy logs tie java oracle collections; do
  source "$TEST_ROOT/modules/$module.sh"
done
source "$TEST_ROOT/tui/main.sh"

[[ "$SHELLOPS_VERSION" == 1.0.0 ]] || fail 'versão central incorreta'
[[ "$($TEST_ROOT/bin/shellops --version)" == 'ShellOps 1.0.0' ]] || fail '--version'
"$TEST_ROOT/bin/shellops" --help | grep -q -- '--version' || fail '--help'
if "$TEST_ROOT/bin/shellops" --invalid >/dev/null 2>&1; then fail 'opção inválida aceita'; fi
ok 'CLI mínima'

for function_name in shellops_tui_diagnostic_menu_v1 shellops_tui_tasy_menu shellops_tui_docker_menu_v1 \
  shellops_tui_java_menu shellops_tui_tie_menu shellops_tui_oracle_menu shellops_tui_logs_menu \
  shellops_tui_certificates_menu shellops_tui_linux_tools_menu; do
  declare -F "$function_name" >/dev/null || fail "handler ausente: $function_name"
done
ok 'handlers dos menus'

mkdir "$TEST_TMP/stubs"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_TMP/stubs/dialog"
chmod 755 "$TEST_TMP/stubs/dialog"
old_path="$PATH"; PATH="$TEST_TMP/stubs:$PATH"
for menu_function in shellops_tui_diagnostic_menu_v1 shellops_tui_tasy_menu shellops_tui_docker_menu_v1 \
  shellops_tui_java_menu shellops_tui_tie_menu shellops_tui_oracle_menu shellops_tui_logs_menu \
  shellops_tui_certificates_menu shellops_tui_linux_tools_menu; do
  "$menu_function" || fail "cancelamento: $menu_function"
done
TERM=dumb shellops_tui_main >/dev/null 2>&1 || fail 'cancelamento do menu principal'
PATH="$old_path"
ok 'inicialização e cancelamento dos menus'

if shellops_require_command __shellops_missing_command__ >/dev/null 2>&1; then fail 'dependência ausente'; fi
inventory="$(shellops_dependencies_inventory)"
[[ "$inventory" == *'CORE|dialog|TUI|'* && "$inventory" == *'FEATURE|openssl|Certificados/TLS|'* ]] || fail 'inventário de dependências'
ok 'dependências opcionais não bloqueantes'

mkdir "$TEST_TMP/path com espaços"
missing="$TEST_TMP/path com espaços/inexistente.log"
if logs_tail "$missing" 10 >/dev/null 2>&1; then fail 'arquivo inexistente aceito'; fi
ok 'paths com espaços e arquivo inexistente'

locale_output="$(system_locale_time_ntp)"
[[ "$locale_output" == *'Current time:'* && "$locale_output" == *'CONSULTA'* ]] || fail 'locale/time/NTP'
ok 'locale/time/NTP consultivo'

discovery_target_set docker_image generic_image example:latest example:latest available none '' 'id=sha256:test'
target_output="$(discovery_diagnose_target)"
[[ "$target_output" == *'Diagnóstico especializado: N/A'* ]] || fail 'fallback de imagem'
tie_status_summary() { printf 'ROUTE:TIE\n'; }
tasy_appmanager_diagnose() { printf 'ROUTE:APPMANAGER\n'; }
tasy_environment_summary() { printf 'ROUTE:TASY\n'; }
java_jvm_summary() { printf 'ROUTE:JAVA\n'; }
docker_diagnose_container() { printf 'ROUTE:DOCKER\n'; }
discovery_target_set process tasy_connector connector '' running none 123 ''
[[ "$(discovery_diagnose_target)" == *'ROUTE:TIE'* ]] || fail 'routing TIE'
discovery_target_set systemd appmanager philips-app-manager.service '' active none '' ''
[[ "$(discovery_diagnose_target)" == *'ROUTE:APPMANAGER'* ]] || fail 'routing AppManager'
discovery_target_set docker tasy_appserver app '' running healthy '' ''
[[ "$(discovery_diagnose_target)" == *'ROUTE:TASY'* ]] || fail 'routing TASY'
discovery_target_set process jvm java '' running none 123 ''
[[ "$(discovery_diagnose_target)" == *'ROUTE:JAVA'* ]] || fail 'routing Java'
discovery_target_set docker generic_container generic '' running none '' ''
[[ "$(discovery_diagnose_target)" == *'ROUTE:DOCKER'* ]] || fail 'routing Docker genérico'
discovery_target_clear
ok 'target genérico e routing especializado'

if shellops_has_command openssl; then
  cert_dir="$TEST_TMP/path com espaços/certificados"; mkdir "$cert_dir"
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=smoke.local -days 2 \
    -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" >/dev/null 2>&1
  [[ "$(certificates_match_certificate_key "$cert_dir/cert.pem" "$cert_dir/key.pem")" == MATCH ]] || fail 'certificado x chave'
  ok 'certificados com path contendo espaços'
else
  printf 'N/A — OpenSSL ausente; teste de certificados ignorado.\n'
fi

bundle_dir="$TEST_TMP/bundle"; mkdir "$bundle_dir"
bundle_path="$(collections_generate_support_bundle "$bundle_dir")" || fail 'Support Bundle parcial'
[[ -s "$bundle_path" ]] || fail 'Support Bundle vazio'
bundle_list="$(tar -tzf "$bundle_path")" || fail 'listagem do Support Bundle'
grep -q '/manifest.txt$' <<< "$bundle_list" || fail 'manifest do Support Bundle'
if grep -Eqi '\.(pem|key|pfx|p12|jks)$' <<< "$bundle_list"; then fail 'artefato proibido no Support Bundle'; fi
ok 'Support Bundle parcial e restrito'

grep -q 'Senha SMB definida para.*senha:' "$TEST_ROOT/install/provisionamento_samba.sh" && fail 'Samba expõe senha'
grep -Eq 'smbclient .*%\$\{?FINAL_PASS' "$TEST_ROOT/install/provisionamento_samba.sh" && fail 'Samba inclui senha em exemplo'
ok 'hardening Samba'

"$TEST_ROOT/install.sh" --help >/dev/null || fail 'ajuda do instalador'
cat > "$TEST_TMP/os-release" <<'EOF'
ID=almalinux
VERSION_ID="9.4"
PRETTY_NAME="AlmaLinux 9.4 (stub)"
EOF
SHELLOPS_OS_RELEASE_FILE="$TEST_TMP/os-release" \
SHELLOPS_INSTALL_ROOT="$TEST_TMP/opt/shellops" \
SHELLOPS_SYMLINK_PATH="$TEST_TMP/usr/local/bin/shellops" \
  "$TEST_ROOT/install.sh" --check >/dev/null || fail '--check do instalador'
[[ ! -e "$TEST_TMP/opt/shellops" && ! -e "$TEST_TMP/usr/local/bin/shellops" ]] || fail '--check modificou destinos'
ok 'instalador em modo não mutável'

printf 'Smoke tests concluídos. Nenhum serviço ou script destrutivo foi executado.\n'
