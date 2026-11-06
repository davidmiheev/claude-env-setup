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
