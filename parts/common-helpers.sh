# >>> common-helpers (shared by the setup-*.sh scripts) ----------------------------
log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
skip() { case ",${SKIP//[ ]/,}," in *",$1,"*) return 0 ;; esac; return 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

APT_UPDATED=0
apt_update() {
  if [ "$APT_UPDATED" = 1 ]; then return 0; fi
  local _
  for _ in 1 2 3 4 5; do   # another lane may hold the lists lock
    $SUDO apt-get update -qq && { APT_UPDATED=1; return 0; }
    sleep 5
  done
  return 1
}
# Installs the listed packages that are missing and exist in the index; names that do not
# exist are reported and skipped instead of aborting the whole install.
apt_install() {
  local want=() ok=() miss=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || want+=("$p"); done
  if [ "${#want[@]}" -eq 0 ]; then return 0; fi
  apt_update
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then ok+=("$p"); else miss+=("$p"); fi
  done
  if [ "${#miss[@]}" -gt 0 ]; then warn "not available in apt, skipped: ${miss[*]}"; fi
  if [ "${#ok[@]}" -eq 0 ]; then return 0; fi
  # a stale index gives 404s on moved .debs: refresh once and retry
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends "${ok[@]}" >/dev/null \
    || { APT_UPDATED=0; apt_update
         DEBIAN_FRONTEND=noninteractive $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y -qq --fix-missing --no-install-recommends "${ok[@]}" >/dev/null; }
}
# Like apt_install, but a failing package does not fail the stage.
apt_install_soft() {
  local p
  if apt_install "$@"; then return 0; fi
  warn "bulk install failed, retrying one package at a time"
  for p in "$@"; do apt_install "$p" || warn "could not install $p"; done
}

append_once() { # append_once FILE LINE
  mkdir -p "$(dirname "$1")"; touch "$1"
  grep -qxF -- "$2" "$1" || printf '%s\n' "$2" >> "$1"
}
persist_env() { # persist_env 'export FOO=bar'  (single-quote it so $HOME expands later)
  append_once "$HOME/.bashrc" "$1"
  if [ "$(id -u)" -eq 0 ]; then append_once "/etc/profile.d/${ENV_NAME:-dev-common}.sh" "$1"; fi
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then append_once "$CLAUDE_ENV_FILE" "$1"; fi
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then return 0; fi
  log "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh \
    || python3 -m pip install --quiet --break-system-packages uv
  persist_env 'export PATH="$HOME/.local/bin:$PATH"'
  command -v uv >/dev/null 2>&1
}

git_sync() { # git_sync URL DIR  (clone, or fast-forward an existing checkout)
  if [ -d "$2/.git" ]; then
    git -C "$2" pull --ff-only --quiet || warn "could not fast-forward $2 (local changes?); using it as is"
  else
    mkdir -p "$(dirname "$2")"
    GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$1" "$2"
  fi
}
# <<< common-helpers
