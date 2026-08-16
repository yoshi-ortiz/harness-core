#!/usr/bin/env bash
# curl -fsSL https://raw.githubusercontent.com/yoshi-ortiz/harness-core/main/install.sh | bash
set -euo pipefail

REPO_URL="${HARNESS_REPO:-https://github.com/yoshi-ortiz/harness-core.git}"
REPO_DIR="${HARNESS_DIR:-$HOME/.harness-core}"
NODE_VERSION="${HARNESS_NODE_VERSION:---lts}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

say() { echo "→ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Darwin)               OS=macos ;;
  *)                    OS=linux ;;
esac

# --- package manager ----------------------------------------------------
# brew everywhere except native Windows shells (Git Bash / MSYS), where winget
# is the system package manager. WSL reports Linux and uses brew like any Linux.
ensure_pkg_manager() {
  if [[ "$OS" == windows ]]; then
    command -v winget >/dev/null 2>&1 || command -v winget.exe >/dev/null 2>&1 \
      || die "winget not found — install 'App Installer' from the Microsoft Store"
    PKG=winget
    return
  fi
  ensure_brew
  PKG=brew
}

# pkg_need <command> <brew formula> <winget id>
pkg_need() {
  local cmd=$1 formula=$2 wid=$3
  command -v "$cmd" >/dev/null 2>&1 && return
  if [[ "$PKG" == winget ]]; then
    say "winget install $wid"
    winget install --id "$wid" -e --source winget \
      --accept-package-agreements --accept-source-agreements
  else
    say "brew install $formula"
    brew install "$formula"
  fi
}

# --- homebrew -----------------------------------------------------------
ensure_brew() {
  if command -v brew >/dev/null 2>&1; then return; fi
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    [[ -x "$p" ]] && { eval "$("$p" shellenv)"; return; }
  done
  say "installing homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    [[ -x "$p" ]] && { eval "$("$p" shellenv)"; break; }
  done
  command -v brew >/dev/null 2>&1 || die "homebrew install failed"
}

# --- node via nvm -------------------------------------------------------
NVM_SH=""

find_nvm_sh() {
  local candidates=("$NVM_DIR/nvm.sh")
  command -v brew >/dev/null 2>&1 && candidates+=("$(brew --prefix 2>/dev/null)/opt/nvm/nvm.sh")
  local f
  for f in "${candidates[@]}"; do
    [[ -s "$f" ]] && { NVM_SH="$f"; return 0; }
  done
  return 1
}

ensure_node() {
  # nvm-windows is a real executable, not a sourced shell function, and takes
  # bare version selectors ("lts") rather than nvm.sh's "--lts" flag
  if [[ "$OS" == windows ]]; then
    pkg_need nvm nvm CoreyButler.NVMforWindows
    command -v nvm >/dev/null 2>&1 \
      || die "nvm-windows installed but not on PATH — reopen your shell and re-run"
    local v="${NODE_VERSION#--}"
    say "nvm install $v"
    nvm install "$v"
    nvm use "$v" >/dev/null
    command -v node >/dev/null 2>&1 || die "node not on PATH after nvm use"
    say "node $(node -v)"
    return
  fi

  if ! find_nvm_sh; then
    brew install nvm
    find_nvm_sh || die "nvm installed but nvm.sh not found (NVM_DIR=$NVM_DIR)"
  fi
  mkdir -p "$NVM_DIR"
  # nvm.sh trips over `set -eu`
  set +eu
  # shellcheck disable=SC1090
  . "$NVM_SH"
  say "nvm install $NODE_VERSION"
  nvm install "$NODE_VERSION"
  nvm use "$NODE_VERSION" >/dev/null
  set -eu
  command -v node >/dev/null 2>&1 || die "node not on PATH after nvm use"
  say "node $(node -v)"
}

ensure_shell_nvm_hook() {
  [[ "$OS" == windows ]] && return 0   # nvm-windows puts node on the system PATH
  local rc="$HOME/.zshrc"
  [[ "${SHELL:-}" == *bash* ]] && rc="$HOME/.bashrc"
  grep -q 'nvm.sh' "$rc" 2>/dev/null && return
  say "adding nvm hook to $rc"
  cat >>"$rc" <<EOF

export NVM_DIR="\$HOME/.nvm"
[ -s "${NVM_SH}" ] && . "${NVM_SH}"
EOF
}

# --- repo ---------------------------------------------------------------
ensure_repo() {
  # running from a checkout already? use it.
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -n "$here" && -f "$here/pony.harness.sh" ]]; then
    REPO_DIR="$here"
    return
  fi
  if [[ -d "$REPO_DIR/.git" ]]; then
    say "updating $REPO_DIR"
    git -C "$REPO_DIR" pull --ff-only
  else
    say "cloning into $REPO_DIR"
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
  fi
}

# --- run ----------------------------------------------------------------
ensure_pkg_manager
pkg_need git git Git.Git
pkg_need yq yq MikeFarah.yq
ensure_node
ensure_shell_nvm_hook

if ! command -v smithery >/dev/null 2>&1; then
  say "npm install -g smithery@latest"
  npm install -g smithery@latest
fi

ensure_repo
chmod +x "$REPO_DIR/pony.harness.sh" "$REPO_DIR"/scripts/*.sh 2>/dev/null || true

# --- `harness` on PATH --------------------------------------------------
# a shim rather than a symlink: pony.harness.sh resolves its collection from
# $0's dirname, and a symlink would point that at the bin dir
install_shim() {
  local bin="${HARNESS_BIN:-$HOME/.local/bin}" shim
  mkdir -p "$bin"
  shim="$bin/harness"
  cat >"$shim" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$REPO_DIR/pony.harness.sh") "\$@"
EOF
  chmod +x "$shim"
  say "installed $shim"
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "  ⚠ $bin is not on your PATH — add: export PATH=\"$bin:\$PATH\"" >&2 ;;
  esac
}

install_shim

say "syncing collection"
"$REPO_DIR/pony.harness.sh" sync "$@"

echo
echo "✓ harness installed at $REPO_DIR"
echo "  harness upgrade   — update collection, tools, and skills"
echo "  harness sync      — reinstall everything in collection.yaml"
echo "  start a new agent session to pick up the skills"
