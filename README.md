# claude-env-setup

Idempotent setup scripts for Claude Code cloud environments (Ubuntu 24.04). Paste one into an
environment's **setup script** field (or run it with `bash`): it runs as root before Claude Code
starts, so the MCP servers it registers are present from the first message.

| script | environment | what it sets up |
|---|---|---|
| `setup-dev-common.sh` | dev-common | apt base + profilers + TeX, Rust toolchain, prebuilt cargo tools (conda-forge), Python tools (uv), ds-agent + its MCP servers |
| `setup-math.sh` | math | CAS tools, Lean, Regina, mtengine (+ its MCP server), TeX, Typst writeup tooling |
| `setup-research.sh` | research | uv + venvs for AI safety / ML / RL / quant, ds-agent MCP servers, the ladder repos, Typst writeup tooling |

Every script has a header listing its knobs (`SKIP="stage ..."`, `MCP_SERVERS`, ...), prints a
per-stage timing table at the end, and exits non-zero if a stage failed.

## Notes

- A setup script is snapshotted only if it finishes in about five minutes, otherwise it reruns
  every session. `setup-dev-common.sh` runs its stages in parallel lanes for that reason.
- Cargo tools come prebuilt from conda-forge through micromamba (`cargo-tools` helper):
  GitHub release downloads (so `cargo-binstall`) are blocked in the sandbox network, conda.anaconda.org is not.
- Credentials are environment variables of the cloud environment (`KAGGLE_API_TOKEN`,
  `COLAB_TOKEN_JSON`, `HF_TOKEN`); they reach the session, never a config file.

## Layout

`parts/*.sh` hold blocks shared by several scripts (delimited by `# >>> name` / `# <<< name`).
Edit a block there, then run `python3 build.py` to sync it into every `setup-*.sh`.
