#!/usr/bin/env bash
# MiMoCode CLI installer (intranet edition)
#
# Pulls the mimo binary from the anonymous FTP share on `forge-pc`,
# verifies prerequisites, and installs into ~/.mimocode/bin/.
#
# Heavily inspired by mimicode's own `install` script at
# https://github.com/XiaomiMiMo/MiMo-Code/blob/main/install — same OS /
# arch / libc / AVX2 detection, same PATH-writing idiom, but:
#   * serves a single prebuilt binary from FTP instead of FDS
#   * checks for runtime tools (`git`, `bash`, `tar`, `curl`/`wget`)
#     and offers to install missing ones via the detected package manager
#
# Usage:
#   curl -sSL ftp://forge-pc.local/mimo/install.sh | bash
#   curl -sSL ftp://forge-pc.local/mimo/install.sh | bash -s -- --prefix /opt/mimo
#
# Environment overrides:
#   MIMO_FTP_HOST         (default: forge-pc.local; fallback: 172.16.55.73)
#   MIMO_FTP_PATH         (default: mimo)
#   MIMO_INSTALL_PREFIX   (default: $HOME/.mimocode)
#   MIMO_SKIP_AUTOINSTALL (default: 0; set to 1 to skip package-manager install)
#
# Exit codes:
#   0  ok
#   1  unsupported OS/arch/libc
#   2  download failed
#   3  checksum mismatch
#   4  smoke test failed
#   5  prerequisites missing and user declined / install failed

set -euo pipefail

# -------- output helpers --------
MUTED='\033[0;2m'
RED='\033[0;31m'
ORANGE='\033[38;5;214m'
GREEN='\033[0;32m'
NC='\033[0m'

log()    { printf "${MUTED}[mimo]${NC} %s\n" "$*"; }
ok()     { printf "${GREEN}[mimo]${NC} %s\n" "$*"; }
warn()   { printf "${ORANGE}[mimo]${NC} %s\n" "$*" >&2; }
fail()   { printf "${RED}[mimo]${NC} %s\n" "$*" >&2; exit "${2:-1}"; }
heading(){ printf "\n${ORANGE}── %s ──${NC}\n" "$*"; }

# Download helper — defined up here so both the FTP-host probe and the
# binary fetch can share it. curl preferred; wget fallback.
download() {
  local url="$1" dest="$2"
  if   command -v curl >/dev/null 2>&1; then curl -fsSLo "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$dest" "$url"
  else fail "Need curl or wget to fetch ${url}" 2; fi
}

usage() {
  cat <<EOF
MiMoCode CLI installer (intranet edition)

Usage: install.sh [options]

Options:
  -h, --help              Show this help
  --prefix <dir>          Install to <dir>/bin/mimo (default: \$HOME/.mimocode)
  --no-modify-path        Don't write to shell config files
  --no-auto-install       Don't try to install missing prerequisites
  --force                 Reinstall even if same version is already present

Environment overrides: MIMO_FTP_HOST, MIMO_FTP_PATH, MIMO_INSTALL_PREFIX,
                       MIMO_SKIP_AUTOINSTALL=1

Examples:
  curl -sSL ftp://forge-pc.local/mimo/install.sh | bash
  curl -sSL ftp://forge-pc.local/mimo/install.sh | bash -s -- --prefix /opt/mimo --no-auto-install
  MIMO_FTP_HOST=172.16.55.73 curl -sSL ftp://172.16.55.73/mimo/install.sh | bash
EOF
}

# -------- argument parsing --------
no_modify_path=false
no_auto_install=false
force=false
prefix_arg=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --prefix) prefix_arg="${2:-}"; shift 2 ;;
    --no-modify-path) no_modify_path=true; shift ;;
    --no-auto-install) no_auto_install=true; shift ;;
    --force) force=true; shift ;;
    *) warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done

FTP_PATH="${MIMO_FTP_PATH:-mimo}"
PREFIX="${prefix_arg:-${MIMO_INSTALL_PREFIX:-$HOME/.mimocode}}"
[[ "${MIMO_SKIP_AUTOINSTALL:-0}" == "1" ]] && no_auto_install=true

BIN_DIR="${PREFIX}/bin"
INSTALL_DIR="$BIN_DIR"
mkdir -p "$BIN_DIR"

# Host fallback chain. If the user explicitly set MIMO_FTP_HOST, only that
# host is used; otherwise we try forge-pc.local (mDNS / Bonjour) first and
# fall back to the LAN IP. Resolve to the first host that responds.
if [[ -n "${MIMO_FTP_HOST:-}" ]]; then
  FTP_HOSTS=("$MIMO_FTP_HOST")
else
  FTP_HOSTS=("forge-pc.local" "172.16.55.73")
fi

probe_host() {
  # Probe an FTP host by listing the install dir. Returns 0 if reachable.
  local host="$1"
  if   command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 3 -fsS "ftp://${host}/${FTP_PATH}/" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget --timeout=3 -q -O /dev/null "ftp://${host}/${FTP_PATH}/"
  else
    return 1
  fi
}

FTP_HOST=""
for candidate in "${FTP_HOSTS[@]}"; do
  if probe_host "$candidate"; then
    FTP_HOST="$candidate"
    break
  fi
  warn "Host ${candidate} not reachable, trying next…"
done
[[ -z "$FTP_HOST" ]] && fail "None of the configured hosts responded: ${FTP_HOSTS[*]}. Use MIMO_FTP_HOST=<host> to override." 2

# -------- detect OS / arch / libc / avx2 (matches mimicode's install) --------
heading "Detecting environment"

raw_os=$(uname -s)
case "$raw_os" in
  Darwin) os="darwin" ;;
  Linux)  os="linux"  ;;
  *)      fail "Unsupported OS: ${raw_os}. This intranet build ships linux-x64 only." 1 ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64|amd64)   arch="x64"   ;;
  aarch64|arm64)  arch="arm64" ;;
  *)              fail "Unsupported arch: ${arch}." 1 ;;
esac

is_musl=false
if [[ "$os" == "linux" ]]; then
  if [[ -f /etc/alpine-release ]]; then is_musl=true; fi
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    is_musl=true
  fi
fi
if [[ "$is_musl" == "true" ]]; then
  fail "musl-based distros (Alpine etc.) are not supported by this glibc build." 1
fi

needs_baseline=false
if [[ "$arch" == "x64" && "$os" == "linux" ]]; then
  if ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then needs_baseline=true; fi
fi

log "OS=${os}  arch=${arch}  libc=glibc  avx2=$([[ "$needs_baseline" == "true" ]] && echo missing || echo ok)"

# This FTP share currently only ships linux-x64 (glibc, with AVX2). Refuse
# anything else cleanly so colleagues get a useful message rather than a 404.
target="${os}-${arch}"
if [[ "$target" != "linux-x64" ]]; then
  fail "This FTP share only ships linux-x64. (Asked for ${target}.)" 1
fi
if [[ "$needs_baseline" == "true" ]]; then
  fail "CPU lacks AVX2; this build requires AVX2. Ask your admin to publish a baseline variant." 1
fi

ASSET="mimo-linux-x64"
CHECKSUM_ASSET="${ASSET}.sha256"
URL_BASE="ftp://${FTP_HOST}/${FTP_PATH}"
BIN_URL="${URL_BASE}/${ASSET}"
SHA_URL="${URL_BASE}/${CHECKSUM_ASSET}"

# -------- prerequisite runtime tools --------
heading "Checking prerequisites"

need_tool() { command -v "$1" >/dev/null 2>&1; }
missing=()
declare -A by_pkg=( \
  [git]="git" \
  [bash]="bash" \
  [tar]="tar" \
  [curl]="curl" \
  [wget]="wget" \
)

for tool in git bash tar; do
  if need_tool "$tool"; then
    log "${tool}: ok ($(command -v "$tool"))"
  else
    log "${tool}: ${ORANGE}MISSING${NC}"
    missing+=("$tool")
  fi
done
if need_tool curl; then log "curl: ok ($(command -v curl))"
elif need_tool wget; then log "wget: ok ($(command -v wget))"
else log "curl/wget: ${ORANGE}MISSING${NC}"; missing+=("curl")
fi

# glibc libs that the binary dynamically links. All ship with the libc6/glibc
# package on every mainstream distro; we just probe for them so a missing
# base system is reported instead of failing later with a cryptic loader error.
# (We use a case-glob match instead of `printf | grep -q` because `set -o
# pipefail` + grep's early exit causes SIGPIPE on the producer, making
# the pipeline look failed even on success.)
ldconfig_out="$(ldconfig -p 2>/dev/null || true)"
for lib in libc.so.6 libpthread.so.0 libm.so.6 libdl.so.2; do
  pattern="${lib%%.so.*}.so"
  case "$ldconfig_out" in
    *"$pattern"*) : ;;
    *) fail "Required system library not found: ${lib}. Install glibc / libc6." 5 ;;
  esac
done
log "system libs (libc/pthread/m/dl): ok"

# If anything is missing, try to install via package manager (best-effort)
install_missing() {
  local pm=""
  if   need_tool apt-get    && pm="apt-get";    then :
  elif need_tool dnf        && pm="dnf";        then :
  elif need_tool yum        && pm="yum";        then :
  elif need_tool pacman     && pm="pacman";      then :
  elif need_tool apk        && pm="apk";        then :
  elif need_tool zypper     && pm="zypper";     then :
  elif need_tool brew       && pm="brew";       then :
  else pm=""; fi

  if [[ -z "$pm" ]]; then
    warn "No recognized package manager (apt/dnf/yum/pacman/apk/zypper/brew)."
    warn "Install manually: ${missing[*]}"
    return 1
  fi

  log "Detected package manager: ${pm}"
  local pkgs=()
  for tool in "${missing[@]}"; do pkgs+=("${by_pkg[$tool]:-$tool}"); done
  log "Will install: ${pkgs[*]}"

  case "$pm" in
    apt-get) sudo -n apt-get update -y >/dev/null 2>&1 || true
             sudo -n apt-get install -y "${pkgs[@]}" ;;
    dnf|zypper) sudo -n "$pm" install -y "${pkgs[@]}" ;;
    yum)        sudo -n yum install -y "${pkgs[@]}" ;;
    pacman)     sudo -n pacman -S --noconfirm "${pkgs[@]}" ;;
    apk)        sudo -n apk add "${pkgs[@]}" ;;
    brew)       brew install "${pkgs[@]}" ;;
  esac
}

if (( ${#missing[@]} > 0 )); then
  if [[ "$no_auto_install" == "true" ]]; then
    fail "Missing prerequisites: ${missing[*]}. Re-run without --no-auto-install to install them." 5
  fi
  if ! install_missing; then
    fail "Could not auto-install missing prerequisites: ${missing[*]}" 5
  fi
  # Re-check
  for tool in git bash tar; do
    if ! need_tool "$tool"; then fail "Still missing: $tool after install." 5; fi
  done
  if ! need_tool curl && ! need_tool wget; then fail "Still missing curl/wget after install." 5; fi
  ok "All prerequisites satisfied."
else
  ok "All prerequisites present."
fi

# -------- version short-circuit --------
heading "Checking existing install"
# Discover what version we're about to install. We don't hardcode this —
# instead we probe the FTP server by downloading the binary to a scratch
# dir and asking it --version. That way, two different local builds (which
# embed different version strings) are correctly distinguished, and a
# stale install on the target machine is correctly replaced.
discover_version() {
  local scratch="$1"
  download "$BIN_URL" "$scratch/$ASSET" || return 1
  chmod +x "$scratch/$ASSET"
  "$scratch/$ASSET" --version 2>/dev/null | tr -d '\r' | head -1
}
TMP_PROBE="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP_PROBE"' EXIT
specific_version="$(discover_version "$TMP_PROBE" || echo unknown)"
if [[ -x "$BIN_DIR/mimo" && "$force" != "true" ]]; then
  installed_version="$("$BIN_DIR/mimo" --version 2>/dev/null || echo unknown)"
  if [[ "$installed_version" == "$specific_version" ]]; then
    log "Version ${specific_version} already installed at $BIN_DIR/mimo. Re-run with --force to reinstall."
    exit 0
  fi
  log "Installed version: ${installed_version:-unknown} (will back up; new version is ${specific_version:-unknown})."
fi

# -------- download --------
TMP="$TMP_PROBE"
heading "Downloading ${ASSET}"

if ! download "$BIN_URL" "$TMP/$ASSET"; then fail "Download of ${BIN_URL} failed." 2; fi
EXPECTED_SHA=""
if download "$SHA_URL" "$TMP/$CHECKSUM_ASSET" 2>/dev/null; then
  EXPECTED_SHA="$(awk '{print $1}' "$TMP/$CHECKSUM_ASSET")"
  ACTUAL_SHA="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
  if [[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    fail "Checksum mismatch: expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}" 3
  fi
  log "Checksum verified (sha256: ${ACTUAL_SHA:0:12}…)."
else
  warn "Checksum file unavailable; skipping verification."
fi

chmod +x "$TMP/$ASSET"

# -------- install (with atomic rename + backup) --------
heading "Installing"
if [[ -e "$BIN_DIR/mimo" ]]; then
  PREV_VERSION="$("$BIN_DIR/mimo" --version 2>/dev/null || echo unknown)"
  cp -p "$BIN_DIR/mimo" "$BIN_DIR/mimo.bak-${PREV_VERSION}"
  log "Backed up previous mimo (${PREV_VERSION}) → $BIN_DIR/mimo.bak-${PREV_VERSION}"
fi

install -m 0755 "$TMP/$ASSET" "$BIN_DIR/mimo.new"
mv -f "$BIN_DIR/mimo.new" "$BIN_DIR/mimo"

# -------- smoke test --------
if ! "$BIN_DIR/mimo" --version >/dev/null 2>&1; then
  fail "Installed binary failed smoke test." 4
fi
INSTALLED_VERSION="$("$BIN_DIR/mimo" --version 2>/dev/null || echo unknown)"
ok "Installed: $BIN_DIR/mimo (version ${INSTALLED_VERSION})"

# -------- PATH writing (mirrors mimicode's install) --------
heading "Configuring PATH"

add_to_path() {
  local config_file="$1" command="$2"
  if grep -Fxq "$command" "$config_file" 2>/dev/null; then
    log "Command already present in ${config_file}, skipping."
    return 0
  fi
  if [[ -w "$config_file" ]]; then
    printf '\n# mimocode\n%s\n' "$command" >> "$config_file"
    log "Added to ${config_file}."
    return 0
  fi
  warn "Cannot write to ${config_file}. Add manually: ${command}"
  return 1
}

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
current_shell=$(basename "${SHELL:-/bin/sh}")
case "$current_shell" in
  fish) config_files="$HOME/.config/fish/config.fish" ;;
  zsh)  config_files="${ZDOTDIR:-$HOME}/.zshrc ${ZDOTDIR:-$HOME}/.zshenv $XDG_CONFIG_HOME/zsh/.zshrc $XDG_CONFIG_HOME/zsh/.zshenv" ;;
  bash) config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile $XDG_CONFIG_HOME/bash/.bashrc $XDG_CONFIG_HOME/bash/.bash_profile" ;;
  ash|sh) config_files="$HOME/.ashrc $HOME/.profile /etc/profile" ;;
  *)    config_files="$HOME/.bashrc $HOME/.bash_profile $XDG_CONFIG_HOME/bash/.bashrc $XDG_CONFIG_HOME/bash/.bash_profile" ;;
esac

path_written=false
if [[ "$no_modify_path" != "true" ]]; then
  config_file=""
  for file in $config_files; do
    if [[ -f "$file" ]]; then config_file="$file"; break; fi
  done
  if [[ -z "$config_file" ]]; then
    warn "No shell config file found for ${current_shell}. Add manually: export PATH=${BIN_DIR}:\$PATH"
  elif [[ ":${PATH:-}:" != *":${BIN_DIR}:"* ]]; then
    case "$current_shell" in
      fish) add_to_path "$config_file" "fish_add_path $BIN_DIR" && path_written=true ;;
      *)    add_to_path "$config_file" "export PATH=$BIN_DIR:\$PATH" && path_written=true ;;
    esac
  else
    log "${BIN_DIR} already on PATH."
  fi
fi

# GitHub Actions convenience
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
  log "Added ${BIN_DIR} to \$GITHUB_PATH"
fi

# -------- done --------
heading "Done"
echo ""
echo -e "${MUTED}  ███╗   ███╗ ██╗ ███╗   ███╗  ██████╗ ${NC}   ██████╗  ██████╗  ██████╗  ███████╗"
echo -e "${MUTED}  ████╗ ████║ ██║ ████╗ ████║ ██╔═══██╗${NC}  ██╔════╝ ██╔═══██╗ ██╔══██╗ ██╔════╝"
echo -e "${MUTED}  ██╔████╔██║ ██║ ██╔████╔██║ ██║   ██║${NC}  ██║      ██║   ██║ ██║  ██║ █████╗  "
echo -e "${MUTED}  ██║╚██╔╝██║ ██║ ██║╚██╔╝██║ ██║   ██║${NC}  ██║      ██║   ██║ ██║  ██║ ██╔══╝  "
echo -e "${MUTED}  ██║ ╚═╝ ██║ ██║ ██║ ╚═╝ ██║ ╚██████╔╝${NC}  ╚██████╗ ╚██████╔╝ ██████╔╝ ███████╗"
echo -e "${MUTED}  ╚═╝     ╚═╝ ╚═╝ ╚═╝     ╚═╝  ╚═════╝ ${NC}   ╚═════╝  ╚═════╝  ╚═════╝  ╚══════╝"
echo ""
echo -e "${MUTED}Next steps:${NC}"
if [[ "$path_written" == "true" && -n "${config_file:-}" ]]; then
  echo -e "  source ${config_file}   ${MUTED}# or open a new terminal${NC}"
else
  echo -e "  export PATH=${BIN_DIR}:\$PATH"
fi
echo -e "  cd <project>"
echo -e "  mimo"
echo ""