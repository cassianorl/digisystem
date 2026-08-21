#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_ROOT="${SHELLOPS_INSTALL_ROOT:-/opt/shellops}"
SYMLINK_PATH="${SHELLOPS_SYMLINK_PATH:-/usr/local/bin/shellops}"
REPOSITORY_URL="https://github.com/cassianorl/digisystem.git"
OS_RELEASE_FILE="${SHELLOPS_OS_RELEASE_FILE:-/etc/os-release}"
MODE="${1:-install}"

fail() { printf 'FAILED — %s\n' "$*" >&2; exit 1; }
info() { printf 'OK — %s\n' "$*"; }

usage() {
  printf '%s\n' \
    'Instalador do ShellOps (não instala AppManager, TIE ou Samba).' \
    'Uso: ./install.sh [install|--check|--help]' \
    '' \
    '  install   instala/atualiza o ShellOps e dependências CORE' \
    '  --check   valida plataforma e estado sem modificar o host' \
    '  --help    mostra esta ajuda'
}

detect_platform() {
  local id version_id pretty_name
  [[ -r "$OS_RELEASE_FILE" && -f "$OS_RELEASE_FILE" ]] || fail 'arquivo os-release não encontrado.'
  id="$(sed -n 's/^ID=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n 1)"
  version_id="$(sed -n 's/^VERSION_ID=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n 1)"
  pretty_name="$(sed -n 's/^PRETTY_NAME=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n 1)"
  [[ "$id" =~ ^[a-z0-9._-]+$ && "$version_id" =~ ^[0-9]+([.][0-9]+)*$ ]] ||
    fail 'campos de distribuição inválidos no arquivo os-release.'
  case "$id" in rhel|ol|almalinux|rocky) ;; *) fail "distribuição não suportada: $id" ;; esac
  case "${version_id%%.*}" in 8|9) ;; *) fail "versão não suportada: $version_id" ;; esac
  printf 'Plataforma: %s %s\n' "${pretty_name:-$id}" "$version_id"
}

package_manager() {
  if command -v dnf >/dev/null 2>&1; then printf 'dnf\n'
  elif command -v yum >/dev/null 2>&1; then printf 'yum\n'
  else fail 'dnf/yum não encontrado.'; fi
}

check_target_state() {
  if [[ -e "$INSTALL_ROOT" && ! -d "$INSTALL_ROOT/.git" ]]; then
    fail "$INSTALL_ROOT existe, mas não é um repositório Git; nada será sobrescrito."
  fi
  if [[ -d "$INSTALL_ROOT/.git" ]]; then
    command -v git >/dev/null 2>&1 || fail 'git é necessário para validar o repositório instalado.'
    if [[ -n "$(git -C "$INSTALL_ROOT" status --porcelain --untracked-files=normal)" ]]; then
      fail 'o repositório instalado possui alterações locais; atualização automática recusada.'
    fi
    printf 'Repositório instalado: pronto para git pull --ff-only.\n'
  else
    printf 'Repositório instalado: ausente; será clonado de %s.\n' "$REPOSITORY_URL"
  fi
  [[ ! -e "$SYMLINK_PATH" || -L "$SYMLINK_PATH" ]] ||
    fail "$SYMLINK_PATH existe e não é symlink; nada será sobrescrito."
}

install_core_dependencies() {
  local manager="$1"
  local -a packages=(bash dialog git coreutils findutils grep sed gawk tar gzip procps-ng util-linux iproute)
  "$manager" -y install "${packages[@]}"
}

install_repository() {
  if [[ -d "$INSTALL_ROOT/.git" ]]; then
    git -C "$INSTALL_ROOT" pull --ff-only ||
      fail 'git pull --ff-only não pôde ser concluído; arquivos locais foram preservados.'
  else
    mkdir -p -- "$(dirname -- "$INSTALL_ROOT")"
    git clone -- "$REPOSITORY_URL" "$INSTALL_ROOT"
  fi
  chmod 755 -- "$INSTALL_ROOT/bin/shellops" "$INSTALL_ROOT/install.sh"
  mkdir -p -- "$(dirname -- "$SYMLINK_PATH")"
  ln -sfn -- "$INSTALL_ROOT/bin/shellops" "$SYMLINK_PATH"
}

case "$MODE" in
  --help) usage; exit 0 ;;
  install|--check) ;;
  *) usage >&2; exit 2 ;;
esac

detect_platform
check_target_state

if [[ "$MODE" == --check ]]; then
  printf 'Modo --check: nenhuma alteração foi executada.\n'
  exit 0
fi

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fail 'a instalação em /opt e /usr/local/bin exige root.'
manager="$(package_manager)"
install_core_dependencies "$manager"
install_repository
installed_version="$($INSTALL_ROOT/bin/shellops --version)" || fail 'não foi possível consultar a versão instalada.'
info "$installed_version instalado em $INSTALL_ROOT"
printf '%s\n' \
  'Dependências FEATURE/OPTIONAL não são instaladas automaticamente.' \
  'Execute ShellOps > Ferramentas Linux > Dependências para consultar o inventário.'
