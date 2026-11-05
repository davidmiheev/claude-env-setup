#!/usr/bin/env bash
# setup-dev-common.sh: "dev-common" environment for Claude Code sessions (Ubuntu 24.04).
#
#   rust       rustup toolchain + clippy/rustfmt/rust-src/rust-analyzer/llvm-tools, and the
#              `cargo-tools` helper
#   cargo-tools  testing (cargo-nextest, cargo-llvm-cov), profiling (flamegraph, samply,
#              cargo-show-asm), hygiene (cargo-audit, cargo-deny, cargo-machete); time-boxed
#   profilers  gdb, lldb, valgrind, perf, strace, ltrace, heaptrack, hyperfine, ...
#              + py-spy, scalene, memray (uv tools)
#   ds-agent   github.com/davidmiheev/ds-agent: uv sync + the ds-env data-science venv
#   mcp        registers ds-agent's MCP servers with Claude Code (user scope) and checks each one
#              answers tools/list: research, ds, ds-memory, kaggle, colab
#   pytools    uv tools: ruff, mypy, pre-commit, ipython, pip-audit, maturin (+ py-spy/scalene/memray
#              from the profilers stage)
#   tex        pandoc + XeLaTeX + latexmk + the fonts atcoder_lectures needs
#              (DejaVu Serif/Sans/Mono, TeX Gyre Termes Math)
#
# Idempotent: safe to re-run. Run as root (environment setup) or as a user with sudo.
# Exits non-zero if any stage failed, after trying all the others.
#
# Speed: a cloud environment's setup script is snapshotted only if it finishes within ~5 minutes
# (otherwise it reruns for every session), so independent stages run in parallel lanes:
#   apt (one apt-get for base + profilers + tex)  |  rust toolchain  |  uv tools
#   |  ds-agent        ... then profilers / tex checks, mcp, and last the cargo tools.
# Cargo tools come prebuilt from conda-forge via micromamba (conda.anaconda.org is reachable in
# sandboxed networks where GitHub release downloads, hence cargo-binstall, are blocked): seconds
# for the whole set. A crate that is not on conda-forge is compiled (~1.5-2.5 min on 2 cores) under
# SETUP_BUDGET and skipped if it does not fit. `cargo-tools` (in /usr/local/bin) installs on demand.
#
# Knobs (environment variables):
#   SKIP="rust profilers"        stages to skip (space or comma separated): apt rust profilers
#                                ds-agent mcp pytools tex cargo-tools. Skipping profilers/tex
#                                also drops their apt packages.
#   SETUP_BUDGET=270             seconds after which no new cargo *compile* is started (0 = no limit)
#   RUST_TOOLCHAIN=stable        toolchain to install and make default
#   CARGO_TOOLS="..."            cargo tools for the cargo-tools stage (default below); anything else
#                                is one `cargo-tools cargo-outdated tokei ...` away
#   PY_TOOLS="ruff mypy ..."     uv tools to install (default list above)
#   DS_AGENT_DIR=$HOME/ds-agent  DS_AGENT_REPO=https://github.com/davidmiheev/ds-agent.git
#   DS_PRESET=quant              passed to ds-agent's install_ds_env.sh (adds quant packages)
#   MCP_SERVERS="research ds"    register only these ds-agent servers (default: all five)
#   KAGGLE_API_TOKEN / COLAB_TOKEN_JSON   credentials for the kaggle / colab servers. Set them as
#                                environment variables of the cloud environment: they reach the
#                                session (the servers read them at launch), not this script, and
#                                are never written to a config file.
#   TEX_FULL_FONTS=1             also install texlive-fonts-extra (large; math env does this)
set -euo pipefail

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
CARGO_TOOLS="${CARGO_TOOLS:-cargo-nextest cargo-llvm-cov flamegraph samply cargo-show-asm cargo-audit cargo-deny cargo-machete bacon cargo-edit cargo-expand just hyperfine}"
SETUP_BUDGET="${SETUP_BUDGET:-270}"
T0=$SECONDS
PY_TOOLS="${PY_TOOLS:-ruff mypy pre-commit ipython pip-audit maturin}"
DS_AGENT_REPO="${DS_AGENT_REPO:-https://github.com/davidmiheev/ds-agent.git}"
DS_AGENT_DIR="${DS_AGENT_DIR:-$HOME/ds-agent}"
SKIP="${SKIP:-}"
TEX_FULL_FONTS="${TEX_FULL_FONTS:-0}"

# Cloud sessions reach the network through a proxy; keep it, and prefer the system Python
# so uv does not need to download an interpreter.
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-system}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

# ------------------------------------------------------------------ helpers ----
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

# >>> mcp-helpers (shared by the setup-*.sh scripts) --------------------------------
# Registers stdio MCP servers with Claude Code (user scope, so every project sees them)
# and proves each one works by speaking JSON-RPC to it: initialize + tools/list.
#   MCP_HOME   where generated support files live (probe script, wrappers, per-server specs)
#   MCP_SCOPE  claude mcp scope (default: user)
#   MCP_NO_CLI=1       write ~/.claude.json directly even if the `claude` CLI exists
#   MCP_PROBE_TIMEOUT  seconds to wait for a server to answer (default 120; the first npx run downloads)
# Registration uses `claude mcp add-json`; without the CLI it merges into
# ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json. Claude Code reads that file when a session starts,
# so a server is available from the *first message* only if this script ran before the session:
# a cloud environment's setup script does (it runs before Claude Code starts, and its disk is
# snapshotted); a SessionStart hook runs after the session has started, so servers it adds load
# in the next session.
MCP_HOME="${MCP_HOME:-$HOME/.claude-mcp}"
MCP_SCOPE="${MCP_SCOPE:-user}"
MCP_REGISTERED=()
MCP_PROBE_FAILED=()
MCP_PROBE_EXTRA=()     # NAME=VALUE pairs given to the probe only (never written to the config)

mcp_support() {
  mkdir -p "$MCP_HOME/servers"
  cat > "$MCP_HOME/probe.py" <<'PYEOF'
"""Start an MCP stdio server from a spec file and list its tools (stdlib only).
usage: probe.py SPEC.json [NAME=VALUE ...]   exit 0 and print "N tools: a, b, ..." on success."""
import json, os, queue, subprocess, sys, threading, time

spec = json.load(open(sys.argv[1]))
extra = dict(a.split("=", 1) for a in sys.argv[2:])
env = dict(os.environ)
env.update(spec.get("env") or {})
env.update(extra)
deadline = time.time() + float(os.environ.get("MCP_PROBE_TIMEOUT", "120"))
p = subprocess.Popen([spec["command"], *(spec.get("args") or [])], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
out, err = queue.Queue(), []
threading.Thread(target=lambda: [out.put(l) for l in p.stdout], daemon=True).start()
threading.Thread(target=lambda: [err.append(l) for l in p.stderr], daemon=True).start()

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()

def call(i, method, params=None):
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}})
    while True:
        left = deadline - time.time()
        if left <= 0:
            raise TimeoutError(f"no answer to {method}")
        try:
            line = out.get(timeout=min(left, 1.0))
        except queue.Empty:
            if p.poll() is not None:
                raise RuntimeError(f"server exited with {p.returncode}")
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == i:
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg.get("result") or {}

try:
    call(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                           "clientInfo": {"name": "setup-probe", "version": "1"}})
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    names, cursor, n = [], None, 2
    while True:
        r = call(n, "tools/list", {"cursor": cursor} if cursor else {})
        names += [t["name"] for t in r.get("tools", [])]
        cursor = r.get("nextCursor")
        n += 1
        if not cursor:
            break
    print(f"{len(names)} tools: {', '.join(names)}")
    rc = 0
except Exception as e:                      # noqa: BLE001
    print(f"FAILED: {e}", file=sys.stderr)
    sys.stderr.write("".join(err[-15:]))
    rc = 1
finally:
    try:
        p.stdin.close()
    except Exception:                       # noqa: BLE001
        pass
    p.terminate()
sys.exit(rc)
PYEOF
}

mcp_use_cli() { [ "${MCP_NO_CLI:-0}" != 1 ] && command -v claude >/dev/null 2>&1; }

mcp_config_file() { printf '%s/.claude.json' "${CLAUDE_CONFIG_DIR:-$HOME}"; }

# mcp_add NAME [-e KEY=VALUE]... -- COMMAND [ARG...]
mcp_add() {
  local name="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" = -e ]; do envs+=("$2"); shift 2; done
  [ "${1:-}" = "--" ] && shift
  local spec="$MCP_HOME/servers/$name.json"
  python3 -c 'import json, sys
n = int(sys.argv[1]); env = dict(a.split("=", 1) for a in sys.argv[2:2 + n]); cmd = sys.argv[2 + n:]
d = {"type": "stdio", "command": cmd[0], "args": cmd[1:]}
if env: d["env"] = env
print(json.dumps(d, indent=2))' "${#envs[@]}" "${envs[@]}" "$@" > "$spec"

  if mcp_use_cli; then
    claude mcp remove -s "$MCP_SCOPE" "$name" >/dev/null 2>&1 || true
    claude mcp add-json -s "$MCP_SCOPE" "$name" "$(cat "$spec")" >/dev/null
  else
    python3 - "$(mcp_config_file)" "$name" "$spec" <<'PYEOF'
import json, os, sys
path, name, spec = sys.argv[1:4]
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.setdefault("mcpServers", {})[name] = json.load(open(spec))
json.dump(cfg, open(path, "w"), indent=2)
PYEOF
  fi
  MCP_REGISTERED+=("$name")

  local res
  if res="$(python3 "$MCP_HOME/probe.py" "$spec" "${MCP_PROBE_EXTRA[@]}" 2>"$MCP_HOME/servers/$name.err")"; then
    printf '  %-12s %s\n' "$name" "$res"
  else
    printf '  %-12s PROBE FAILED: %s\n' "$name" "$(head -c 600 "$MCP_HOME/servers/$name.err")" >&2
    MCP_PROBE_FAILED+=("$name")
    return 1
  fi
}

# mcp_remove NAME: unregister a server this script registered earlier
mcp_remove() {
  if mcp_use_cli; then
    claude mcp remove -s "$MCP_SCOPE" "$1" >/dev/null 2>&1 || true
  elif [ -f "$(mcp_config_file)" ]; then
    python3 - "$(mcp_config_file)" "$1" <<'PYEOF'
import json, sys
path, name = sys.argv[1:3]
cfg = json.load(open(path))
if cfg.get("mcpServers", {}).pop(name, None) is not None:
    json.dump(cfg, open(path, "w"), indent=2)
PYEOF
  fi
  rm -f "$MCP_HOME/servers/$1.json" "$MCP_HOME/servers/$1.err"
}

# mcp_summary: confirm Claude Code sees what was registered, fail if any probe failed.
mcp_summary() {
  if mcp_use_cli; then
    log "claude mcp list (scope: $MCP_SCOPE, config: $(mcp_config_file))"
    local listing; listing="$(claude mcp list 2>&1 || true)"
    printf '%s\n' "$listing" | grep -E "^($(IFS='|'; echo "${MCP_REGISTERED[*]:-none}")):" || true
  fi
  if [ "${#MCP_PROBE_FAILED[@]}" -gt 0 ]; then
    warn "servers registered but not answering: ${MCP_PROBE_FAILED[*]}"
    return 1
  fi
  echo "note: Claude Code reads MCP servers when a session starts; run this from the environment's setup script (before the session) to have them in the first message."
}
# <<< mcp-helpers

# >>> mcp-ds-agent (shared by setup-dev-common.sh and setup-research.sh) -------------
# Registers ds-agent's MCP servers (its mcp.json) with Claude Code:
#   research    arXiv / Semantic Scholar / OpenAlex / PubMed / Crossref / bioRxiv / HF / UniProt /
#               PDB / Ensembl / FRED search tools                         (FRED_API_KEY for fred_series)
#   ds          run code in the ds-env data-science venv, inspect data
#   ds-memory   cross-session memory (ds-agent calls it "memory"; renamed so it cannot be
#               confused with Claude's own memory tools)
#   kaggle      Kaggle's official MCP through ds-agent's proxy      (needs KAGGLE_API_TOKEN, KGAT...)
#   colab       Google Colab runtimes (GPU/TPU)                     (needs COLAB_TOKEN_JSON or a token file)
# Needs the `ds-agent` stage first (DS_AGENT_DIR with its .venv and ~/.coding-agent/ds-env).
#   MCP_SERVERS="research ds"   register only these (default: all five)
# ds-agent's `filesystem` server (npx @modelcontextprotocol/server-filesystem /tmp) is left out on
# purpose: it duplicates Claude Code's own file tools. A copy registered by an earlier version of
# this script is removed.
#   COLAB_CLI_SRC               where google-colab-cli is cloned (default ~/.cache/google-colab-cli)
mcp_want() { # is server $1 selected?
  local w="${MCP_SERVERS:-}"
  [ -z "$w" ] && return 0
  case ",${w//[ ]/,}," in *",$1,"*) return 0 ;; esac
  return 1
}

mcp_ds_agent() {
  local root="$DS_AGENT_DIR" py="$DS_AGENT_DIR/.venv/bin/python" rc=0
  local data="${CODING_AGENT_HOME:-$HOME/.coding-agent}"
  [ -x "$py" ] || { warn "ds-agent venv not found at $root/.venv (run the ds-agent stage first)"; return 1; }
  [ -x "$data/ds-env/bin/python" ] || warn "ds-env missing at $data/ds-env: the 'ds' server will start but cannot run code"
  mcp_support
  command -v npx >/dev/null 2>&1 || apt_install nodejs npm
  if [ -f "$MCP_HOME/servers/filesystem.json" ]; then mcp_remove filesystem; fi

  # Kaggle wrapper. ds-agent's kaggle_mcp spawns `npx mcp-remote` through the mcp SDK, which
  # hands the child only a "safe" environment: HTTPS_PROXY / NODE_EXTRA_CA_CERTS vanish and npm
  # fails with SELF_SIGNED_CERT_IN_CHAIN behind a TLS-intercepting proxy (Claude Code cloud
  # sessions). The shim re-adds them. The wrapper maps KAGGLE_API_TOKEN to the variable the
  # server wants, at launch, so the token is never written into any config file.
  cat > "$MCP_HOME/kaggle_shim.py" <<'PYEOF'
"""Run ds-agent's Kaggle MCP proxy with proxy/CA variables passed through to npx."""
import os
from mcp.client import stdio

PASSTHROUGH = ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
               "NODE_EXTRA_CA_CERTS", "NODE_USE_ENV_PROXY", "SSL_CERT_FILE", "npm_config_cafile")
_default_env = stdio.get_default_environment


def _env_with_proxy():
    env = _default_env()
    env.update({k: os.environ[k] for k in PASSTHROUGH if k in os.environ})
    return env


stdio.get_default_environment = _env_with_proxy

from ds_agent.kaggle_mcp import main  # noqa: E402

if __name__ == "__main__":
    main()
PYEOF
  cat > "$MCP_HOME/kaggle-mcp.sh" <<EOF
#!/usr/bin/env bash
export KAGGLE_MCP_TOKEN="\${KAGGLE_MCP_TOKEN:-\${KAGGLE_API_TOKEN:-}}"
export PYTHONPATH="$root/src:$MCP_HOME\${PYTHONPATH:+:\$PYTHONPATH}"
exec "$py" "$MCP_HOME/kaggle_shim.py" "\$@"
EOF
  chmod +x "$MCP_HOME/kaggle-mcp.sh"

  log "registering ds-agent MCP servers"
  MCP_PROBE_EXTRA=()
  if mcp_want research; then
    mcp_add research -e "PYTHONPATH=$root/src" -- "$py" -m research_mcp.server || rc=1
  fi
  if mcp_want ds; then
    mcp_add ds -e "PYTHONPATH=$root/src" -e "DS_PYTHON=$data/ds-env/bin/python" -- "$py" -m ds_mcp.server || rc=1
  fi
  if mcp_want ds-memory; then
    mcp_add ds-memory -e "PYTHONPATH=$root/src" -- "$py" -m ds_agent.agent_mcp || rc=1
  fi
  if mcp_want kaggle; then
    # Env vars set on the cloud environment reach the Claude Code session, not the setup script,
    # so the token is normally unset here. The wrapper reads KAGGLE_API_TOKEN when Claude Code
    # starts the server, which is all that is needed.
    # tools/list is proxied live from kaggle.com, so it can only be probed with a real token
    if [ -n "${KAGGLE_API_TOKEN:-${KAGGLE_MCP_TOKEN:-}}" ]; then
      mcp_add kaggle -- bash "$MCP_HOME/kaggle-mcp.sh" || rc=1
    else
      MCP_PROBE_EXTRA=("KAGGLE_MCP_TOKEN=probe-only")
      if ! mcp_add kaggle -- bash "$MCP_HOME/kaggle-mcp.sh"; then
        local keep=() f
        for f in "${MCP_PROBE_FAILED[@]}"; do [ "$f" = kaggle ] || keep+=("$f"); done
        MCP_PROBE_FAILED=("${keep[@]}")
        warn "kaggle registered; its tools are fetched from kaggle.com at start-up, so export KAGGLE_API_TOKEN before starting Claude Code"
      fi
      MCP_PROBE_EXTRA=()
    fi
  fi
  if mcp_want colab; then
    mcp_colab || rc=1
  fi
  return "$rc"
}

# Colab MCP: own venv (Python 3.13, mcp<2) built by ds-agent's colab_mcp/setup.sh.
# google-colab-cli is pinned: its commit 7141f9d ("store OAuth tokens in keyring", 2026-09)
# removed colab_cli.auth.TOKEN_CONFIG_PATH, which ds-agent's colab_server imports, so the
# server dies at import against upstream HEAD. Override with COLAB_CLI_REF=<sha|branch>.
COLAB_CLI_REF_DEFAULT=4025416a03361d2ff34d06a4523ae76ce4c9bbaf
mcp_colab() {
  local root="$DS_AGENT_DIR" cpy="$DS_AGENT_DIR/src/colab_mcp/.venv/bin/python"
  local ref="${COLAB_CLI_REF:-$COLAB_CLI_REF_DEFAULT}"
  export COLAB_CLI_SRC="${COLAB_CLI_SRC:-$HOME/.cache/google-colab-cli}"   # editable install: must persist
  if [ ! -d "$COLAB_CLI_SRC/.git" ]; then
    git clone --quiet https://github.com/googlecolab/google-colab-cli "$COLAB_CLI_SRC" \
      || { warn "could not clone google-colab-cli; skipping colab"; return 0; }
  fi
  git -C "$COLAB_CLI_SRC" cat-file -e "$ref^{commit}" 2>/dev/null || git -C "$COLAB_CLI_SRC" fetch --quiet origin
  git -C "$COLAB_CLI_SRC" checkout --quiet "$ref" || { warn "google-colab-cli: cannot check out $ref; skipping colab"; return 0; }
  if ! PYTHONPATH="$root/src" "$cpy" -c 'import colab_mcp.colab_server' 2>/dev/null; then
    log "building the Colab MCP venv (Python 3.13)"
    ( cd "$root" && KEEP_PROXY=1 bash src/colab_mcp/setup.sh ) \
      || { warn "colab MCP venv could not be built (needs Python 3.13); skipping colab"; return 0; }
  fi
  if [ -n "${COLAB_TOKEN_JSON:-}" ] && [ ! -s "$HOME/.config/colab-cli/token.json" ]; then
    mkdir -p "$HOME/.config/colab-cli"
    ( umask 077; printf '%s' "$COLAB_TOKEN_JSON" > "$HOME/.config/colab-cli/token.json" )
  fi
  mcp_add colab -e "PYTHONPATH=$root/src" -- "$cpy" -m colab_mcp.colab_server
}
# <<< mcp-ds-agent

# ------------------------------------------------------------------- stages ----
# One apt-get call for everything the stages below need from apt (the index is refreshed once and
# dpkg unpacks once); the stages themselves then only configure and verify.
APT_BASE=(build-essential pkg-config libssl-dev cmake clang lld mold ccache
  git curl ca-certificates unzip xz-utils zstd jq ripgrep iproute2 lsof python3 python3-venv python3-pip)
APT_PROFILERS=(gdb gdbserver lldb valgrind libc6-dbg strace ltrace heaptrack hyperfine
  sysstat htop linux-tools-common linux-tools-generic binutils elfutils)
APT_TEX=(pandoc latexmk texlive-xetex texlive-latex-recommended texlive-latex-extra
  texlive-fonts-recommended texlive-pictures texlive-plain-generic texlive-science lmodern
  fontconfig poppler-utils fonts-dejavu fonts-texgyre fonts-texgyre-math fonts-inter fonts-liberation2)
stage_apt() {
  local pk=("${APT_BASE[@]}")
  if ! skip profilers; then pk+=("${APT_PROFILERS[@]}"); fi
  if ! skip tex; then
    pk+=("${APT_TEX[@]}")
    if [ "$TEX_FULL_FONTS" = 1 ]; then pk+=(texlive-fonts-extra); fi
  fi
  if { ! skip ds-agent || ! skip mcp; } && ! command -v npx >/dev/null 2>&1; then pk+=(nodejs npm); fi
  apt_install_soft "${pk[@]}"
}

stage_rust() {
  export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
  if ! command -v rustup >/dev/null 2>&1; then
    log "installing rustup"
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain none --no-modify-path
  fi
  persist_env 'export PATH="$HOME/.cargo/bin:$PATH"'

  log "rust toolchain: $RUST_TOOLCHAIN"
  rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal \
    -c clippy -c rustfmt -c rust-src -c rust-analyzer -c llvm-tools-preview
  rustup default "$RUST_TOOLCHAIN"

  install_cargo_tools_helper
  rustc --version && cargo --version
}

# `cargo-tools [--bg] [--deadline EPOCH] [crate...]` installs missing cargo tools. Order:
#   1. prebuilt conda-forge packages via micromamba (conda.anaconda.org is reachable where GitHub
#      release downloads are not, so cargo-binstall cannot fetch anything there): seconds per tool
#   2. cargo-binstall, if a network allows it
#   3. a compile with a cheap profile (opt-level 1, no LTO or debug info, 16 codegen units: ~2x
#      faster to build, a bit slower to run) and one shared target dir
# Conda packages live in one prefix ($CARGO_TOOLS_PREFIX, default ~/.local/share/cargo-tools-conda);
# their executables are symlinked into ~/.cargo/bin, so they are on PATH and `cargo <sub>` works.
install_cargo_tools_helper() {
  local bin=/usr/local/bin
  if [ "$(id -u)" -ne 0 ]; then bin="$HOME/.local/bin"; fi
  mkdir -p "$bin"
  cat > "$bin/cargo-tools" <<'HELPER_EOF'
#!/usr/bin/env bash
# cargo-tools [--bg] [--deadline EPOCH] [crate ...]     default crates: @DEFAULT@
export PATH="$HOME/.cargo/bin:$PATH"
DEFAULT="@DEFAULT@"
EST=${CARGO_CRATE_EST:-120}     # seconds a compile is assumed to need when checking the deadline
LOG="$HOME/.cache/cargo-tools.log"
PREFIX="${CARGO_TOOLS_PREFIX:-$HOME/.local/share/cargo-tools-conda}"
MM="${MICROMAMBA:-$HOME/.local/bin/micromamba}"
CARGO_BIN="$HOME/.cargo/bin"
bg=0; deadline=0
while [ "$#" -gt 0 ]; do
  case "$1" in --bg) bg=1 ;; --deadline) deadline="$2"; shift ;; *) break ;; esac
  shift
done
if [ "$bg" = 1 ]; then
  mkdir -p "$(dirname "$LOG")"
  setsid nohup "$0" "$@" >"$LOG" 2>&1 </dev/null &
  echo "installing in the background, log: $LOG"
  exit 0
fi
crates=("$@")
if [ "${#crates[@]}" -eq 0 ]; then read -ra crates <<<"$DEFAULT"; fi

conda_name() { case "$1" in flamegraph) echo cargo-flamegraph ;; *) echo "$1" ;; esac; }

ensure_micromamba() {
  [ -x "$MM" ] && return 0
  mkdir -p "$(dirname "$MM")"
  local tmp; tmp="$(mktemp -d)"
  # micro.mamba.pm redirects to conda-forge's micromamba package (a .tar.bz2 holding bin/micromamba)
  if curl -fsSL --retry 3 -o "$tmp/mm.tar.bz2" https://micro.mamba.pm/api/micromamba/linux-64/latest \
     && tar -xjf "$tmp/mm.tar.bz2" -C "$tmp" bin/micromamba; then
    install -m 755 "$tmp/bin/micromamba" "$MM"
  fi
  rm -rf "$tmp"
  [ -x "$MM" ]
}

# conda_install CRATE...: one solve for all of them; prints the names that failed to stdout
conda_install() {
  local pk=() c todo=()
  for c in "$@"; do pk+=("$(conda_name "$c")"); done
  export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/.cache/micromamba}"
  local args=(-y -q -p "$PREFIX" -c conda-forge --override-channels)
  if [ -d "$PREFIX/conda-meta" ]; then "$MM" install "${args[@]}" "${pk[@]}" >&2 2>&1 && return 0
  else "$MM" create "${args[@]}" "${pk[@]}" >&2 2>&1 && return 0; fi
  # a package missing on conda-forge fails the whole solve: retry one by one
  for c in "$@"; do
    if [ -d "$PREFIX/conda-meta" ]; then "$MM" install "${args[@]}" "$(conda_name "$c")" >/dev/null 2>&1
    else "$MM" create "${args[@]}" "$(conda_name "$c")" >/dev/null 2>&1; fi || echo "$c"
  done
}

link_conda_bins() { # symlink the executables of the conda prefix that cargo tools ship
  mkdir -p "$CARGO_BIN"
  local f n
  for f in "$PREFIX"/bin/cargo-* "$PREFIX"/bin/bacon "$PREFIX"/bin/samply "$PREFIX"/bin/flamegraph \
           "$PREFIX"/bin/just "$PREFIX"/bin/hyperfine "$PREFIX"/bin/rg "$PREFIX"/bin/fd "$PREFIX"/bin/tokei "$PREFIX"/bin/delta; do
    [ -x "$f" ] || continue
    n="$(basename "$f")"
    [ -e "$CARGO_BIN/$n" ] && [ ! -L "$CARGO_BIN/$n" ] && continue     # never replace a real cargo-installed binary
    ln -sf "$f" "$CARGO_BIN/$n"
  done
}

installed="$(cargo install --list 2>/dev/null)"
want=()
for c in "${crates[@]}"; do
  grep -q "^$c v" <<<"$installed" && continue
  [ -d "$PREFIX/conda-meta" ] && ls "$PREFIX/conda-meta" | grep -q "^$(conda_name "$c")-[0-9]" && continue
  want+=("$c")
done
[ "${#want[@]}" -eq 0 ] && { echo "cargo-tools: everything is installed"; exit 0; }

rest=("${want[@]}")
if ensure_micromamba; then
  echo "==> conda-forge (prebuilt): ${want[*]}"
  mapfile -t rest < <(conda_install "${want[@]}")
  link_conda_bins
else
  echo "WARNING: micromamba unavailable; falling back to cargo" >&2
fi

export CARGO_PROFILE_RELEASE_OPT_LEVEL=1 CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_LTO=false        CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 CARGO_PROFILE_RELEASE_STRIP=true CARGO_INCREMENTAL=0
TARGET="${CARGO_TOOLS_TARGET:-$HOME/.cache/cargo-tools-target}"
rc=0; skipped=()
for c in "${rest[@]}"; do
  [ -z "$c" ] && continue
  if [ "$deadline" -gt 0 ] && [ "$(( $(date +%s) + EST ))" -gt "$deadline" ]; then skipped+=("$c"); continue; fi
  echo "==> cargo tool (not on conda-forge): $c"
  if command -v cargo-binstall >/dev/null 2>&1      && cargo binstall -y --locked --disable-strategies compile --log-level error "$c" 2>/dev/null; then continue; fi
  cargo install --locked --target-dir "$TARGET" "$c" || { echo "WARNING: could not install $c" >&2; rc=1; }
done
rm -rf "$TARGET"
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "WARNING: not installed (setup time budget): ${skipped[*]}  ->  run: cargo-tools --bg ${skipped[*]}" >&2
fi
exit "$rc"
HELPER_EOF
  sed -i "s|@DEFAULT@|$CARGO_TOOLS|g" "$bin/cargo-tools"
  chmod +x "$bin/cargo-tools"
}

stage_cargo_tools() {
  local deadline=0 helper
  helper="$(command -v cargo-tools || echo /usr/local/bin/cargo-tools)"
  if [ "$SETUP_BUDGET" -gt 0 ]; then deadline=$(( $(date +%s) - (SECONDS - T0) + SETUP_BUDGET )); fi
  "$helper" --deadline "$deadline"
}

stage_profilers() {
  # linux-tools-common's perf wrapper insists on a kernel-matching build, which a container
  # never has: point `perf` at the newest build that was installed.
  if ! perf --version >/dev/null 2>&1; then
    local p
    p="$(ls -d /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1 || true)"
    if [ -n "$p" ]; then $SUDO ln -sf "$p" /usr/local/bin/perf; else warn "no perf binary found"; fi
  fi
  ensure_uv
  local t
  for t in py-spy scalene memray; do
    uv tool install --quiet "$t" || warn "could not install $t"
  done
  echo "note: perf/samply/py-spy need perf_event access or ptrace; containers often restrict both."
}

# >>> ds-agent-stage (shared by setup-dev-common.sh and setup-research.sh) ---------
# Needs: DS_AGENT_REPO, DS_AGENT_DIR; optional DS_PRESET (e.g. quant), DS_PY_VERSION, DS_EXTRA_PACKAGES.
stage_ds_agent() {
  ensure_uv
  if ! command -v node >/dev/null 2>&1; then apt_install nodejs npm; fi   # npx: kaggle MCP (mcp-remote)
  log "ds-agent -> $DS_AGENT_DIR"
  git_sync "$DS_AGENT_REPO" "$DS_AGENT_DIR"
  ( cd "$DS_AGENT_DIR" && { uv sync --frozen || uv sync; } )
  # install_ds_env.sh unsets the proxy variables unless KEEP_PROXY=1, which would cut it off
  # from the network in a proxied cloud session.
  local pyver
  pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  # The quant preset's vectorbt cannot import with plotly >= 6 (it sets the removed
  # `scattermapbox` template), and install_ds_env.sh's check only catches ImportError, so
  # the whole install would die on it.
  case "${DS_PRESET:-}:${INSTALL_QUANT:-0}" in
    quant:*|all:*|*:1) DS_EXTRA_PACKAGES="${DS_EXTRA_PACKAGES:-} plotly<6" ;;
  esac
  export DS_EXTRA_PACKAGES
  ( cd "$DS_AGENT_DIR" && KEEP_PROXY=1 DS_PY_VERSION="${DS_PY_VERSION:-$pyver}" bash scripts/install_ds_env.sh )
  ( cd "$DS_AGENT_DIR" && PYTHONPATH=src .venv/bin/python -c 'import ds_agent, ds_mcp; print("ds-agent imports OK")' )
  echo "Next: cp $DS_AGENT_DIR/.env.example $DS_AGENT_DIR/.env (keys), then: bash $DS_AGENT_DIR/scripts/run_server.sh"
}
# <<< ds-agent-stage

stage_mcp() {
  mcp_ds_agent
  mcp_summary
}

stage_pytools() {
  ensure_uv
  local t installed
  installed="$(uv tool list 2>/dev/null || true)"
  for t in $PY_TOOLS; do
    if grep -q "^$t " <<<"$installed"; then continue; fi
    log "uv tool: $t"
    uv tool install --quiet "$t" || warn "could not install $t"
  done
  uv tool list 2>/dev/null | grep -E '^[a-z]' || true
}

stage_tex() {
  $SUDO fc-cache -f >/dev/null 2>&1 || true

  local f fonts
  fonts="$(fc-list)"   # not `fc-list | grep -q`: grep exiting early SIGPIPEs fc-list under pipefail
  for f in "DejaVu Serif" "DejaVu Sans Mono" "TeX Gyre Termes Math"; do
    grep -qi "$f" <<<"$fonts" || { echo "font missing after install: $f" >&2; return 1; }
  done

  # Smoke tests: the packages/fonts atcoder_lectures' lecturestyle.sty loads, and the
  # pandoc -> XeLaTeX path.
  local d; d="$(mktemp -d)"
  cat > "$d/t.tex" <<'EOF'
\documentclass{article}
\usepackage{fontspec}
\usepackage{amsmath,amssymb,amsthm,mathtools,unicode-math}
\setmainfont{DejaVu Serif}
\setsansfont{DejaVu Sans}
\setmonofont{DejaVu Sans Mono}
\setmathfont{TeX Gyre Termes Math}
\usepackage{tcolorbox,listings,fancyhdr,titlesec,enumitem,booktabs,xurl,tikz,hyperref,caption,float}
\begin{document}
Smoke test: $\int_0^1 x^2\,dx = \tfrac13$, \texttt{mono}, \textsf{sans}.
\begin{tikzpicture}\draw (0,0)--(1,1);\end{tikzpicture}
\end{document}
EOF
  ( cd "$d" && xelatex -interaction=nonstopmode -halt-on-error t.tex >xe.log 2>&1 ) \
    || { tail -25 "$d/xe.log" >&2; return 1; }
  printf '# Title\n\nInline $x^2$ and a list:\n\n- one\n- two\n' \
    | pandoc -o "$d/p.pdf" --pdf-engine=xelatex -V mainfont="DejaVu Serif" -V mathfont="TeX Gyre Termes Math" \
    || return 1
  rm -rf "$d"
  echo "pandoc $(pandoc --version | head -1 | cut -d' ' -f2), $(xelatex --version | head -1): smoke tests OK"
}

# ------------------------------------------------------------------- driver ----
FAILED=()
LOGDIR="$(mktemp -d)"
declare -A PID STARTED
# spawn NAME: run stage_<name> in the background, output to $LOGDIR/NAME.log
spawn() {
  local name="$1"
  if skip "$name"; then echo "[+$((SECONDS - T0))s] skipping $name"; return 0; fi
  echo "[+$((SECONDS - T0))s] start $name"
  STARTED[$name]=$SECONDS
  ( set +e; ( set -euo pipefail; "stage_${name//-/_}" ) >"$LOGDIR/$name.log" 2>&1; echo $? >"$LOGDIR/$name.rc" ) &
  PID[$name]=$!
}
# join NAME...: wait, then show each stage's output and result
join() {
  local name rc
  for name in "$@"; do
    [ -n "${PID[$name]:-}" ] || continue
    wait "${PID[$name]}" || true
    rc="$(cat "$LOGDIR/$name.rc" 2>/dev/null || echo 1)"
    log "stage: $name ($((SECONDS - STARTED[$name]))s, $([ "$rc" = 0 ] && echo ok || echo "FAILED, exit $rc"))"
    cat "$LOGDIR/$name.log"
    if [ "$rc" -ne 0 ]; then warn "stage '$name' failed (exit $rc)"; FAILED+=("$name"); fi
    unset "PID[$name]"
  done
}

ensure_uv || warn "uv could not be installed; uv-based stages will fail"
# lanes that do not need apt start right away
spawn apt; spawn rust; spawn pytools; spawn ds-agent
join apt
spawn profilers; spawn tex
join ds-agent
spawn mcp
join rust pytools profilers tex mcp
spawn cargo-tools     # last: it is CPU-bound and everything above is done
join cargo-tools

echo
echo "[+$((SECONDS - T0))s] total"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "dev-common setup finished with failures: ${FAILED[*]}" >&2
  exit 1
fi
echo "dev-common setup complete."
