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
