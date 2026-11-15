# claude-env-setup

Idempotent setup scripts for Claude Code cloud environments (Ubuntu 24.04). Paste one into an
environment's **setup script** field (or run it with `bash`): it runs as root before Claude Code
starts, so the MCP servers it registers are present from the first message.

| script | environment | what it sets up |
|---|---|---|
| `setup-dev-common.sh` | dev-common | apt base + profilers + TeX, Rust toolchain, prebuilt cargo tools (conda-forge), Python tools (uv), ds-agent + its MCP servers |
| `setup-math.sh` | math | CAS tools, Lean, Regina, mtengine (+ its MCP server), TeX, Typst writeup tooling (parallel lanes) |
| `setup-research.sh` | research | uv + venvs for AI safety / ML / RL / quant, ds-agent MCP servers, Typst writeup tooling |

Every script has a header listing its knobs (`SKIP="stage ..."`, `MCP_SERVERS`, ...), prints a
per-stage timing table at the end, and exits non-zero if a stage failed.

## Measured times

Each script prints its own per-stage table at the end. Fully cold runs (the script's apt packages
purged and apt's cache emptied, empty uv cache and home directory, 4 cores):

| script | wall time | critical path |
|---|---|---|
| `setup-math.sh` | 105-222 s (was 286 s run stage by stage) | the one apt-get: 87-212 s, 629 MB of it `texlive-fonts-extra` |
| `setup-research.sh` | 201 s (was 278 s) | the venv downloads, ~1.5 GB of wheels shared by three venvs |
| `setup-dev-common.sh` | 111 s (2 cores, earlier measurement) | prebuilt cargo tools ~26 s; Python tools installed 4 at a time |

Times depend on the network, which varied a lot between runs: math's apt stage took 87 s in one
cold run and 212 s in the next, dev-common took 99-205 s in four cold runs, and 14-21 minutes
twice when a connection was throttled.

What was tried and left out:
- TeX Live 2026 from CTAN (`install-tl`, the same collections as the apt TeX set): 342 s for TeX
  alone, over the five-minute budget. apt's TeX Live 2023 stays.
- Replacing `texlive-fonts-extra` with the few CTAN packages the thesis preamble loads: a fuller
  preamble also needs newtx, pxfonts, txfonts and STIX glyphs, so the 629 MB package stays.

## Notes

- A setup script is snapshotted only if it finishes in about five minutes, otherwise it reruns
  every session. All three scripts run independent stages in parallel lanes for that reason, and
  each one installs its apt packages in a single apt-get.
- Regina's apt repo pins one key from `debian-keyring` (31 MB, not in the cloud image); the math
  script fetches just that key, checked against the pinned fingerprint, so Regina comes with the
  one apt-get.
- Behind the session's TLS-intercepting proxy some CTAN mirrors fail certificate checks;
  `ctan.math.illinois.edu` works.
- Cargo tools come prebuilt from conda-forge through micromamba (`cargo-tools` helper):
  GitHub release downloads (so `cargo-binstall`) are blocked in the sandbox network, conda.anaconda.org is not.
- Credentials are environment variables of the cloud environment (`KAGGLE_API_TOKEN`,
  `COLAB_TOKEN_JSON`, `HF_TOKEN`); they reach the session, never a config file.

## Layout

`parts/*.sh` hold blocks shared by several scripts (delimited by `# >>> name` / `# <<< name`).
Edit a block there, then run `python3 build.py` to sync it into every `setup-*.sh`.
