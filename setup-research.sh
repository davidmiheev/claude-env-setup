#!/usr/bin/env bash
# setup-research.sh: "research" environment for Claude Code sessions (Ubuntu 24.04).
# RL, AI-safety / interpretability, ML + quant research, with ds-agent's MCP tools registered.
#
#   base       system libs: compilers, swig (Box2D), GL/EGL/OSMesa + ffmpeg (MuJoCo, video), node
#   python     uv + Python 3.12 (see below)
#   repos      clones ai-safety-ladder, rl-ladder, ml-ladder, jax-experiments into $RESEARCH_DIR
#   ds-agent   github.com/davidmiheev/ds-agent: uv sync + the ds-env venv with the quant preset
#   mcp        registers ds-agent's MCP servers with Claude Code (user scope) and checks that each
#              answers tools/list: research, ds, ds-memory, kaggle, colab
#   typst      `typst-compile` over the safety venv's `typst` package: ai-safety-ladder's PDF write-ups
#   safety     venv "safety": TransformerLens, SAELens, nnsight, CircuitsVis, inspect-ai, torch,
#              jupyter ...                                              (ai-safety-ladder)
#   ml         venv "ml": torch + JAX/Flax/Optax, torchvision/audio, timm, torch-geometric, escnn,
#              HF datasets/tokenizers/transformers, xgboost/lightgbm/sklearn, plus quant:
#              hftbacktest, numba, polars, statsmodels, arch, cvxpy, optuna   (ml-ladder, jax-experiments)
#   rl         venv "rl": gymnasium (classic-control, Box2D, MuJoCo, Atari), SB3 + contrib,
#              PettingZoo, TRL/PEFT, JAX RL (gymnax, brax, pgx, rlax, flashbax), hftbacktest for
#              the market-making part                                              (rl-ladder)
#   equivariant  (opt-in, WITH_ESCNN=1) venv "equivariant": torch + escnn, which needs numpy<1.27
#   verify     imports + tiny functional runs in every venv
#
# Why Python 3.12: ai-safety-ladder needs <3.13, jax-experiments needs >=3.12 (jax 0.11), and
# rl-ladder / ml-ladder need >=3.11. 3.12 is the only version that satisfies all four.
# Why separate venvs: the stacks pin against each other (TransformerLens vs. current
# transformers, xgboost vs. xgboost-cpu, ...) and each repo's own `uv sync` still works.
# All torch wheels are CPU builds unless a GPU is found (a CPU torch saves ~3 GB of CUDA wheels).
#
# Idempotent: safe to re-run. Run as root (environment setup) or as a user with sudo.
# Exits non-zero if any stage failed, after trying all the others.
#
# Knobs (environment variables):
#   SKIP="colab verify"          stages to skip (space or comma separated). Venvs are the stages
#                                safety / ml / rl, e.g. SKIP="safety" for an RL-only box.
#   PY_VERSION=3.12              Python for the venvs
#   RESEARCH_DIR=$HOME/research  where the repos are cloned
#   VENV_DIR=$HOME/.venvs/research   venvs go to $VENV_DIR/{safety,ml,rl}
#   ACCEL=auto|cpu|cuda          auto = CUDA builds only if nvidia-smi sees a GPU
#   SAFETY_EXTRA= ML_EXTRA= RL_EXTRA=   extra pip requirements (space separated) per venv
#   WITH_ESCNN=1                 also build the "equivariant" venv (torch + escnn)
#   DS_PRESET=quant              passed to ds-agent's install_ds_env.sh (default here: quant)
#   MCP_SERVERS="research ds"    register only these ds-agent servers (default: all five)
#   GITHUB_TOKEN / GH_TOKEN      lets `repos` clone the private rl-ladder when it is not attached
#                                to the session (used as a request header, never stored)
#   KAGGLE_API_TOKEN / COLAB_TOKEN_JSON   credentials for the kaggle / colab servers. Set them as
#                                environment variables of the cloud environment: they reach the
#                                session (the servers read them at launch), not this script, and
#                                are never written to a config file.
#   HF_TOKEN                     for gated models; read from the environment, never stored
set -euo pipefail

ENV_NAME=research
PY_VERSION="${PY_VERSION:-3.12}"
RESEARCH_DIR="${RESEARCH_DIR:-$HOME/research}"
VENV_DIR="${VENV_DIR:-$HOME/.venvs/research}"   # not ~/.venvs/ml: that is dev-common's torch+jax venv
ACCEL="${ACCEL:-auto}"
SKIP="${SKIP:-}"
DS_AGENT_REPO="${DS_AGENT_REPO:-https://github.com/davidmiheev/ds-agent.git}"
DS_AGENT_DIR="${DS_AGENT_DIR:-$HOME/ds-agent}"
export DS_PRESET="${DS_PRESET:-quant}"
GH_OWNER="${GH_OWNER:-davidmiheev}"
REPOS="${REPOS:-ai-safety-ladder rl-ladder ml-ladder jax-experiments}"

export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-system}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

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

# >>> typst-writeups (shared by setup-math.sh and setup-research.sh) ----------------
# ai-safety-ladder renders its PDF write-ups (writeups/*.typ) with Typst, through the `typst`
# Python package (scripts/build_writeups.py: typst.compile). The wheel bundles the compiler and
# the fonts the template names (New Computer Modern, DejaVu Sans Mono), so no typst CLI, TeX
# or network is needed. The PyPI package ships no command-line tool, so `typst-compile` is a
# small wrapper over typst.compile for ad-hoc use.
#   TYPST_VENV=$HOME/.venvs/typst   (math) venv holding the package; research uses its safety venv
#   TYPST_SPEC="typst>=0.13"        what ai-safety-ladder's pyproject asks for
# typst_setup PYTHON: make `import typst` work in PYTHON, install the wrapper, smoke-test it.
typst_setup() {
  local py="$1" bin d
  if ! "$py" -c 'import typst' 2>/dev/null; then
    log "installing ${TYPST_SPEC:-typst>=0.13} into $py"
    if command -v uv >/dev/null 2>&1; then uv pip install --python "$py" "${TYPST_SPEC:-typst>=0.13}"
    else "$py" -m pip install --quiet "${TYPST_SPEC:-typst>=0.13}"; fi
  fi
  apt_install fonts-dejavu fontconfig   # the template's monospace font; also what lets other tools see it
  if [ "$(id -u)" -eq 0 ]; then bin=/usr/local/bin; else bin="$HOME/.local/bin"; fi
  mkdir -p "$bin"
  cat > "$bin/typst-compile" <<PYEOF
#!$py
"""typst-compile INPUT.typ [OUTPUT] [--root DIR] [--font-path DIR] [--ppi N]: compile with the typst Python package.
OUTPUT defaults to INPUT with a .pdf extension; a .png/.svg extension selects that format
(use {p} in the name for per-page PNGs)."""
import argparse, pathlib, sys
import typst

ap = argparse.ArgumentParser(prog="typst-compile", description=__doc__.split("\n")[0])
ap.add_argument("input")
ap.add_argument("output", nargs="?")
ap.add_argument("--root")
ap.add_argument("--font-path", action="append", default=[])
ap.add_argument("--ppi", type=float)
a = ap.parse_args()
out = a.output or str(pathlib.Path(a.input).with_suffix(".pdf"))
kw = {"font_paths": a.font_path}
if a.root: kw["root"] = a.root
if a.ppi: kw["ppi"] = a.ppi
try:
    typst.compile(a.input, output=out, **kw)
except typst.TypstError as e:
    sys.exit(f"typst-compile: {e}")
print(out)
PYEOF
  chmod +x "$bin/typst-compile"
  case ":$PATH:" in *":$bin:"*) ;; *) persist_env 'export PATH="$HOME/.local/bin:$PATH"' ;; esac

  # Smoke test with the template's fonts, math and a figure-free page; fonts the compiler
  # cannot find are reported as warnings, which would show up on stderr.
  d="$(mktemp -d)"
  cat > "$d/t.typ" <<'TYPEOF'
#set text(font: "New Computer Modern", size: 10.5pt)
#show raw: set text(font: "DejaVu Sans Mono")
= Typst smoke test
Inline math $x_(ell+1) = x_ell + sum_h "attn"_h (x_ell)$ and `raw code`.
TYPEOF
  "$bin/typst-compile" "$d/t.typ" "$d/t.pdf" >/dev/null 2>"$d/err" || { cat "$d/err" >&2; return 1; }
  if grep -qi "unknown font" "$d/err"; then cat "$d/err" >&2; return 1; fi
  [ -s "$d/t.pdf" ] || return 1
  rm -rf "$d"
  echo "typst $("$py" -c 'import typst; print(typst.__version__)'): smoke test OK (typst-compile in $bin)"
}
# <<< typst-writeups

# ----------------------------------------------------------------- research ----
GPU=0
if [ "$ACCEL" = cuda ] || { [ "$ACCEL" = auto ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }; then
  GPU=1
fi
BACKEND=cpu; JAX_PKG="jax"
if [ "$GPU" = 1 ]; then BACKEND=auto; JAX_PKG="jax[cuda12]"; fi

# Package sets. Everything here was resolved together (uv pip install --dry-run, Python 3.12).
# xgboost-cpu, not xgboost: both provide the module `xgboost`, the latter drags in NCCL (~300 MB).
SAFETY_PKGS=(torch numpy "transformer-lens>=2.16,<4" "circuitsvis>=1.43" "sae-lens>=6.0" "nnsight>=0.4"
  inspect-ai einops jaxtyping transformers accelerate datasets huggingface_hub safetensors
  scikit-learn pandas scipy matplotlib plotly seaborn tqdm python-dotenv typst
  jupyterlab ipykernel ipywidgets pytest ruff)
ML_PKGS=(torch torchvision torchaudio timm pyarrow wandb tensorboard
  "$JAX_PKG" flax optax
  "transformers>=4.40,<5" datasets tokenizers sentencepiece protobuf accelerate
  torch-geometric
  scikit-learn xgboost-cpu lightgbm optuna
  numpy scipy pandas polars statsmodels arch cvxpy hftbacktest numba
  matplotlib seaborn plotly tqdm pyyaml
  jupyterlab ipykernel pytest ruff)
RL_PKGS=(torch numpy "gymnasium[classic-control,box2d,mujoco,other]>=1.0" "stable-baselines3[extra]>=2.4" sb3-contrib
  pettingzoo ale-py mujoco tensorboard
  transformers trl peft datasets accelerate
  "$JAX_PKG" flax optax gymnax brax pgx rlax flashbax
  hftbacktest numba pandas polars pyarrow scipy scikit-learn
  matplotlib tqdm pyyaml
  jupyterlab ipykernel pytest ruff)

stage_base() {
  apt_install build-essential pkg-config cmake git curl ca-certificates unzip jq ripgrep \
    python3 python3-venv python3-pip gfortran swig libgl1 libegl1 libosmesa6 libglfw3 ffmpeg libgomp1 \
    nodejs npm
}

stage_python() {
  ensure_uv
  if ! uv python find "$PY_VERSION" >/dev/null 2>&1; then
    apt_install_soft "python$PY_VERSION" "python$PY_VERSION-venv" "python$PY_VERSION-dev"
  fi
  if ! uv python find "$PY_VERSION" >/dev/null 2>&1; then
    log "no system Python $PY_VERSION; letting uv download one"
    uv python install "$PY_VERSION"
  fi
  echo "python $PY_VERSION -> $(uv python find "$PY_VERSION")"
}

# clone_repo NAME  (public repos clone anonymously; private ones need the repo attached to the
# session or GITHUB_TOKEN/GH_TOKEN)
clone_repo() {
  local name="$1" dir="$RESEARCH_DIR/$1" url="https://github.com/$GH_OWNER/$1.git" tok
  tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only --quiet || warn "could not fast-forward $dir; using it as is"
    return 0
  fi
  mkdir -p "$RESEARCH_DIR"
  # Anonymous first: public repos need nothing, and a session's git proxy serves the repos
  # attached to it. Only then try the token (a header, so it never lands in .git/config).
  GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$url" "$dir" 2>/dev/null && return 0
  rm -rf "$dir"
  [ -n "$tok" ] || return 1
  GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 \
    git -c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 -w0)" \
    clone --quiet "$url" "$dir"
}

stage_repos() {
  local r
  for r in $REPOS; do
    if clone_repo "$r" 2>/dev/null; then
      echo "$r -> $RESEARCH_DIR/$r ($(git -C "$RESEARCH_DIR/$r" rev-parse --abbrev-ref HEAD))"
    else
      warn "could not clone $GH_OWNER/$r (private? attach it to the session or set a working GITHUB_TOKEN); the venvs do not depend on it"
    fi
  done
  persist_env "export RESEARCH_DIR=\"$RESEARCH_DIR\""
}

# mkvenv NAME / vinstall NAME PKG... / vpy NAME
vpy() { printf '%s/%s/bin/python' "$VENV_DIR" "$1"; }
mkvenv() {
  local py; py="$(vpy "$1")"
  if [ -x "$py" ] && [ "$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])')" = "$PY_VERSION" ]; then return 0; fi
  rm -rf "${VENV_DIR:?}/$1"
  uv venv --python "$PY_VERSION" "$VENV_DIR/$1"
}
vinstall() {
  local name="$1"; shift
  # --torch-backend picks the matching PyTorch wheel index; without it PyPI's Linux torch is
  # the CUDA build and pulls several GB of nvidia-* wheels.
  # No fallback to PyPI defaults on failure: that would silently fetch the CUDA torch build.
  uv pip install --python "$(vpy "$name")" --torch-backend "$BACKEND" "$@"
}
# Make the repo importable (src layout) without touching its pins; a failure is not fatal.
vrepo() { # vrepo VENV REPO
  local d="$RESEARCH_DIR/$2"
  [ -f "$d/pyproject.toml" ] || return 0
  uv pip install --python "$(vpy "$1")" --no-deps -e "$d" >/dev/null 2>&1 \
    && echo "  $2 installed editable into $1" \
    || warn "could not install $2 editable into $1 (its code still runs from $d)"
}
vkernel() { # register a Jupyter kernel for the venv
  "$(vpy "$1")" -m ipykernel install --user --name "research-$1" --display-name "research ($1)" >/dev/null 2>&1 \
    || warn "could not register the Jupyter kernel research-$1"
}

build_venv() { # build_venv NAME "extra pkgs" pkgs...
  local name="$1" extra="$2"; shift 2
  ensure_uv
  log "venv $name -> $VENV_DIR/$name (python $PY_VERSION, $([ "$GPU" = 1 ] && echo CUDA || echo CPU) wheels)"
  mkdir -p "$VENV_DIR"
  mkvenv "$name"
  # shellcheck disable=SC2086   # $extra is a space-separated list on purpose
  vinstall "$name" "$@" $extra
  vkernel "$name"
  persist_env "export RESEARCH_VENVS=\"$VENV_DIR\""
}

stage_safety() {
  build_venv safety "${SAFETY_EXTRA:-}" "${SAFETY_PKGS[@]}"
  vrepo safety ai-safety-ladder
}
stage_typst() {
  [ -x "$(vpy safety)" ] || { warn "the safety venv is missing (stage safety)"; return 1; }
  typst_setup "$(vpy safety)"
}
stage_ml() {
  build_venv ml "${ML_EXTRA:-}" "${ML_PKGS[@]}"
  vrepo ml ml-ladder
}

# escnn (ml-ladder's 'equivariant' extra) pins numpy<1.27 and builds lie-learn/py3nj from source,
# so it cannot share the ml venv (numpy 2 + jax). Opt-in venv: WITH_ESCNN=1.
stage_equivariant() {
  if [ "${WITH_ESCNN:-0}" != 1 ]; then echo "not requested (WITH_ESCNN=1 builds a venv with escnn)"; return 0; fi
  build_venv equivariant "${EQUIVARIANT_EXTRA:-}" torch "numpy<1.27" "scipy<1.18" setuptools wheel cython ipykernel
  vinstall equivariant --no-build-isolation lie-learn   # its sdist needs numpy at build time
  vinstall equivariant escnn
  "$(vpy equivariant)" -c 'import escnn, torch; print("escnn", escnn.__version__, "| torch", torch.__version__)'
}
stage_rl() {
  build_venv rl "${RL_EXTRA:-}" "${RL_PKGS[@]}"
  vrepo rl rl-ladder
  # headless MuJoCo rendering on a box without a GPU
  if [ "$GPU" = 0 ]; then persist_env 'export MUJOCO_GL=osmesa'; fi
}

stage_mcp() {
  mcp_ds_agent
  mcp_summary
}

stage_verify() {
  local rc=0
  if [ -x "$(vpy safety)" ]; then
    log "verify: safety"
    "$(vpy safety)" -I -c '
import torch, transformer_lens, sae_lens, nnsight, circuitsvis, inspect_ai, einops, jaxtyping
print("torch", torch.__version__, "cuda", torch.cuda.is_available(), "| transformer_lens", transformer_lens.__version__ if hasattr(transformer_lens, "__version__") else "ok", "| sae_lens", sae_lens.__version__)
' || rc=1
  fi
  if [ -x "$(vpy ml)" ]; then
    log "verify: ml"
    "$(vpy ml)" -I -c '
import torch, torchvision, jax, flax, optax, sklearn, xgboost, lightgbm, polars, statsmodels, arch, cvxpy, optuna, numba, hftbacktest, torch_geometric
import jax.numpy as jnp
print("torch", torch.__version__, "| jax", jax.__version__, jax.devices(), "| hftbacktest", hftbacktest.__version__ if hasattr(hftbacktest, "__version__") else "ok")
print("jit:", float(jax.jit(lambda x: (x * x).sum())(jnp.arange(4.0))), "| numba:", numba.njit(lambda a: a + 1)(1))
' || rc=1
  fi
  if [ -x "$(vpy rl)" ]; then
    log "verify: rl"
    MUJOCO_GL="${MUJOCO_GL:-osmesa}" "$(vpy rl)" -I -c '
import gymnasium as gym, ale_py, numpy as np
gym.register_envs(ale_py)
for name in ["CartPole-v1", "LunarLander-v3", "HalfCheetah-v5", "ALE/Pong-v5"]:
    env = gym.make(name); env.reset(seed=0); env.step(env.action_space.sample()); env.close(); print("env ok:", name)
from stable_baselines3 import PPO
PPO("MlpPolicy", "CartPole-v1", n_steps=64, batch_size=32, device="cpu", verbose=0).learn(128)
print("SB3 PPO ok")
import gymnax, brax, pgx, rlax, flashbax, trl, peft, hftbacktest, numba
print("jax RL libs, TRL, hftbacktest ok")
' || rc=1
  fi
  return "$rc"
}

# ------------------------------------------------------------------- driver ----
FAILED=()
TIMES=()
T0=$SECONDS
run_stage() { # run_stage NAME  -> runs stage_<name> in a subshell with `set -e` really on
  local name="$1" rc
  if skip "$name"; then log "skipping $name"; return 0; fi
  log "stage: $name"
  local t=$SECONDS
  set +e
  ( set -euo pipefail; "stage_${name//-/_}" )
  rc=$?
  set -e
  TIMES+=("$(printf '%-12s %4ss%s' "$name" "$((SECONDS - t))" "$([ "$rc" -ne 0 ] && echo '  FAILED')")")
  if [ "$rc" -ne 0 ]; then warn "stage '$name' failed (exit $rc)"; FAILED+=("$name"); fi
}

run_stage base
for s in python repos ds-agent mcp safety typst ml rl equivariant verify; do run_stage "$s"; done

echo
echo "stage times (total $((SECONDS - T0))s):"; printf '  %s\n' "${TIMES[@]}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "research setup finished with failures: ${FAILED[*]}" >&2
  exit 1
fi
cat <<EOF
research setup complete.
  venvs:  $VENV_DIR/{safety,ml,rl}$([ -x "$(vpy equivariant)" ] && echo ,equivariant)   (source $VENV_DIR/rl/bin/activate; Jupyter kernels research-*)
  repos:  $RESEARCH_DIR
  MCP:    $(cd "$MCP_HOME/servers" 2>/dev/null && ls -1 *.json 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')(restart Claude Code to load them)
EOF
