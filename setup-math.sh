#!/usr/bin/env bash
# setup-math.sh: "math" environment for Claude Code sessions (Ubuntu 24.04).
#
#   fetch      clone github.com/davidmiheev/mtengine (or fast-forward an existing checkout)
#   cas        Macaulay2, gfan, polymake, Singular, nauty   (the backends mtengine calls)
#   lean       elan (Lean toolchain manager; toolchains come from the Lake project)
#   regina     Regina from its official apt repo, only if this mtengine has a Regina backend
#   mtengine   venv + `pip install -e ".[test]"`, `mte`/`mtengine-mcp` on PATH, verification
#   mcp        registers the `mtengine` MCP server with Claude Code (user scope) and checks that it
#              answers tools/list
#   typst      Typst (Python package) + `typst-compile`, what ai-safety-ladder uses for its PDF write-ups
#   tex        pandoc + XeLaTeX + latexmk + fonts for matroid_toric's thesis/paper
#              (TeX Gyre Pagella, eulervm, newpxmath, bbold) and atcoder-style notes (DejaVu,
#              TeX Gyre Termes Math), plus what regina_experiments' writeup build needs
#
# What mtengine needs (read from its pyproject.toml and src/): Python >= 3.11, the `mcp` package
# (+ pytest for the tests), and the executables M2, gfan, polymake, Singular, dreadnaut and
# lean/lake. Regina is a backend only in the unmerged PR #1 (branch claude/add-regina-backend).
#
# Idempotent: safe to re-run. Run as root (environment setup) or as a user with sudo.
# Exits non-zero if any stage failed, after trying all the others.
#
# Knobs (environment variables):
#   SKIP="lean regina"                stages to skip (space or comma separated)
#   MTENGINE_DIR=$HOME/mtengine       MTENGINE_REPO=https://github.com/davidmiheev/mtengine.git
#   MTENGINE_REF=claude/add-regina-backend   branch to check out (default: the default branch)
#   WITH_REGINA=auto|1|0              auto = install Regina iff the checked-out source mentions it
#   RUN_TESTS=1                       run the mtengine test suite (minus the Lean tests) at the end
#   MTENGINE_LEAN_PROJECT=...         Lake project with Mathlib, e.g. a matroid_toric checkout's formal/
#                                     (also passed to the registered MCP server when set)
set -euo pipefail

MTENGINE_REPO="${MTENGINE_REPO:-https://github.com/davidmiheev/mtengine.git}"
MTENGINE_DIR="${MTENGINE_DIR:-$HOME/mtengine}"
MTENGINE_REF="${MTENGINE_REF:-}"
WITH_REGINA="${WITH_REGINA:-auto}"
RUN_TESTS="${RUN_TESTS:-0}"
SKIP="${SKIP:-}"

export PATH="$HOME/.local/bin:$HOME/.elan/bin:$PATH"

# ------------------------------------------------------------------ helpers ----
log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
skip() { case ",${SKIP//[ ]/,}," in *",$1,"*) return 0 ;; esac; return 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

APT_UPDATED=0
apt_update() {
  if [ "$APT_UPDATED" = 1 ]; then return 0; fi
  $SUDO apt-get update -qq || { sleep 3; $SUDO apt-get update -qq; }
  APT_UPDATED=1
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
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "${ok[@]}" >/dev/null \
    || { APT_UPDATED=0; apt_update
         DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --fix-missing --no-install-recommends "${ok[@]}" >/dev/null; }
}

append_once() { # append_once FILE LINE
  mkdir -p "$(dirname "$1")"; touch "$1"
  grep -qxF -- "$2" "$1" || printf '%s\n' "$2" >> "$1"
}
persist_env() { # persist_env 'export FOO=bar'  (single-quote it so $HOME expands later)
  append_once "$HOME/.bashrc" "$1"
  if [ "$(id -u)" -eq 0 ]; then append_once /etc/profile.d/math-env.sh "$1"; fi
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then append_once "$CLAUDE_ENV_FILE" "$1"; fi
}
link_bin() { # link_bin TARGET NAME: make a command available on PATH
  local dir
  if [ "$(id -u)" -eq 0 ]; then dir=/usr/local/bin; else dir="$HOME/.local/bin"; mkdir -p "$dir"; fi
  $SUDO ln -sf "$1" "$dir/$2"
}

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

# ------------------------------------------------------------------- stages ----
stage_base() {
  apt_install git curl ca-certificates python3 python3-venv python3-pip build-essential
}

stage_fetch() {
  log "mtengine -> $MTENGINE_DIR${MTENGINE_REF:+ ($MTENGINE_REF)}"
  if [ -d "$MTENGINE_DIR/.git" ]; then
    if [ -n "$MTENGINE_REF" ]; then
      git -C "$MTENGINE_DIR" fetch --quiet origin "$MTENGINE_REF" \
        && git -C "$MTENGINE_DIR" checkout --quiet "$MTENGINE_REF" \
        && git -C "$MTENGINE_DIR" pull --ff-only --quiet origin "$MTENGINE_REF" \
        || warn "could not switch/update $MTENGINE_DIR to $MTENGINE_REF; using it as is"
    else
      git -C "$MTENGINE_DIR" pull --ff-only --quiet \
        || warn "could not fast-forward $MTENGINE_DIR (local changes?); using it as is"
    fi
  else
    mkdir -p "$(dirname "$MTENGINE_DIR")"
    GIT_LFS_SKIP_SMUDGE=1 git clone --quiet ${MTENGINE_REF:+--branch "$MTENGINE_REF"} "$MTENGINE_REPO" "$MTENGINE_DIR"
  fi
  git -C "$MTENGINE_DIR" log -1 --format='at %h %s'
}

stage_cas() {
  # Package names as in mtengine's Dockerfile; they provide M2, gfan, polymake, Singular, dreadnaut.
  apt_install macaulay2 gfan polymake singular nauty
  local b
  for b in M2 gfan polymake Singular dreadnaut; do
    command -v "$b" >/dev/null 2>&1 || { echo "missing executable after install: $b" >&2; return 1; }
  done
}

stage_lean() {
  if ! command -v elan >/dev/null 2>&1; then
    log "installing elan"
    curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain none >/dev/null
  fi
  persist_env 'export PATH="$HOME/.elan/bin:$PATH"'
  elan --version
  echo "note: mtengine's Lean backend needs a Lake project with Mathlib; set MTENGINE_LEAN_PROJECT"
  echo "      (matroid_toric/formal does; run 'lake exe cache get' there for the prebuilt Mathlib)."
}

stage_regina() {
  case "$WITH_REGINA" in
    0) echo "WITH_REGINA=0: not installing Regina"; return 0 ;;
    auto) if ! grep -rqi regina "$MTENGINE_DIR/src" 2>/dev/null; then
            echo "this mtengine checkout has no Regina backend; skipping (set MTENGINE_REF=claude/add-regina-backend or WITH_REGINA=1)"
            return 0
          fi ;;
  esac
  # Steps follow https://regina-normal.github.io/install/ubuntu.html (same as regina_experiments)
  local codename
  codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
  case "$codename" in noble|plucky|questing) ;; *) echo "Regina's apt repo has no build for '$codename'" >&2; return 1 ;; esac
  if command -v regina-python >/dev/null 2>&1; then echo "Regina already installed"; return 0; fi
  apt_install debian-keyring curl ca-certificates
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/regina-$codename.sources" "https://regina-normal.github.io/repos/regina-$codename.sources"
  $SUDO cp "$tmp/regina-$codename.sources" /etc/apt/sources.list.d/
  rm -rf "$tmp"
  APT_UPDATED=0
  apt_install regina-normal
  t="$(mktemp --suffix=.py)"; echo 'import regina; print("Regina", regina.versionString())' > "$t"; regina-python -q "$t"; rm -f "$t"
}

stage_mtengine() {
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
    || { echo "mtengine needs Python >= 3.11, found $(python3 --version)" >&2; return 1; }
  cd "$MTENGINE_DIR"
  [ -x .venv/bin/python ] || python3 -m venv .venv
    # uv when present: from a cold cache it installs this in ~1.5 min, pip in ~3.7 min
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python .venv/bin/python -q -e ".[test]"
  else
    .venv/bin/pip install -q --upgrade pip
    .venv/bin/pip install -q -e ".[test]"
  fi
  link_bin "$MTENGINE_DIR/.venv/bin/mte" mte
  link_bin "$MTENGINE_DIR/.venv/bin/mtengine-mcp" mtengine-mcp
  persist_env "export MTENGINE_DIR=\"$MTENGINE_DIR\""

  log "mte versions"
  .venv/bin/mte versions | tee /tmp/mte-versions.json
  # Every backend except Lean (which needs a Lake project) must be present.
  if grep -Eq '"(macaulay2|gfan|polymake|singular|nauty|regina)": "(MISSING|UNAVAILABLE)' /tmp/mte-versions.json; then
    echo "a mtengine backend is missing (see above)" >&2; return 1
  fi
  .venv/bin/mte call hessenberg_betti '{"kbar": [2, 2], "h": [2, 2]}' >/dev/null   # Gr(2,4): no external tool
  echo "mtengine OK. MCP server: $MTENGINE_DIR/.venv/bin/mtengine-mcp (also on PATH as mtengine-mcp)"
  if [ "$RUN_TESTS" = 1 ]; then
    log "pytest (Lean tests excluded)"
    .venv/bin/pytest -q -k "not lean" --deselect tests/test_backends.py::test_versions_present
  fi
}

stage_tex() {
  # texlive-fonts-extra carries eulervm / newpxmath / bbold (the thesis preamble); it is large.
  apt_install pandoc latexmk texlive-xetex texlive-latex-recommended texlive-latex-extra \
    texlive-fonts-recommended texlive-fonts-extra texlive-pictures texlive-plain-generic texlive-science \
    lmodern fontconfig poppler-utils fonts-dejavu fonts-texgyre fonts-texgyre-math fonts-inter \
    fonts-liberation2 python3-matplotlib   # last one: regina_experiments' install-writeup-deps.sh
  $SUDO fc-cache -f >/dev/null 2>&1 || true

  local f fonts
  fonts="$(fc-list)"   # not `fc-list | grep -q`: grep exiting early SIGPIPEs fc-list under pipefail
  for f in "DejaVu Serif" "DejaVu Sans Mono" "TeX Gyre Termes Math" "TeX Gyre Pagella"; do
    grep -qi "$f" <<<"$fonts" || { echo "font missing after install: $f" >&2; return 1; }
  done

  local d; d="$(mktemp -d)"
  # 1. the preamble of matroid_toric/docs/thesis-v2/thesis_en.tex (docs/paper uses the same fonts)
  cat > "$d/thesis.tex" <<'EOF'
\documentclass[11pt,a4paper]{article}
\usepackage{amsmath,amssymb,amsthm,mathtools}
\usepackage{eulervm}
\usepackage{newpxmath}
\usepackage{bbold}
\usepackage[no-math]{fontspec}
\setmainfont{TeX Gyre Pagella}
\usepackage{enumitem,booktabs,array,tikz,microtype,xurl}
\usepackage[hidelinks]{hyperref}
\begin{document}
Smoke test: $\mathbb{1}$, $H^*_T(X)$, $\sum_i \alpha_i$ and \textit{italic}.
\begin{tikzpicture}\draw (0,0)--(1,1);\end{tikzpicture}
\end{document}
EOF
  ( cd "$d" && xelatex -interaction=nonstopmode -halt-on-error thesis.tex >thesis.log 2>&1 ) \
    || { echo "thesis-style preamble failed:" >&2; tail -25 "$d/thesis.log" >&2; return 1; }
  # 2. the preamble of atcoder_lectures' lecturestyle.sty
  cat > "$d/lecture.tex" <<'EOF'
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
\end{document}
EOF
  ( cd "$d" && xelatex -interaction=nonstopmode -halt-on-error lecture.tex >lecture.log 2>&1 ) \
    || { echo "lecture-style preamble failed:" >&2; tail -25 "$d/lecture.log" >&2; return 1; }
  # 3. pandoc -> XeLaTeX
  printf '# Title\n\nInline $x^2$ and a list:\n\n- one\n- two\n' \
    | pandoc -o "$d/p.pdf" --pdf-engine=xelatex -V mainfont="TeX Gyre Pagella" -V mathfont="TeX Gyre Termes Math" \
    || return 1
  rm -rf "$d"
  echo "pandoc $(pandoc --version | head -1 | cut -d' ' -f2), $(xelatex --version | head -1): smoke tests OK"

  # regina_experiments renders writeups as pandoc -> HTML -> headless Chromium -> PDF (not XeLaTeX).
  # Ubuntu's chromium package is a snap stub, so it is not installed here; just report.
  if ! have_chrome; then
    warn "no Chromium/Chrome found: regina_experiments' 'make writeups' needs one (set CHROME=/path/to/chrome)"
  fi
}

have_chrome() { # same search order as regina_experiments/scripts/build-writeup.sh
  local c
  for c in "${CHROME:-}" chromium chromium-browser google-chrome google-chrome-stable /opt/pw-browsers/chromium; do
    if [ -n "$c" ] && command -v "$c" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

stage_typst() {
  local v="${TYPST_VENV:-$HOME/.venvs/typst}"
  [ -x "$v/bin/python" ] || { mkdir -p "$(dirname "$v")"; python3 -m venv "$v"; }
  typst_setup "$v/bin/python"
}

stage_mcp() {
  local bin="$MTENGINE_DIR/.venv/bin/mtengine-mcp" rc=0 envs=()
  [ -x "$bin" ] || { warn "$bin not found (run the mtengine stage first)"; return 1; }
  mcp_support
  if [ -n "${MTENGINE_LEAN_PROJECT:-}" ]; then envs=(-e "MTENGINE_LEAN_PROJECT=$MTENGINE_LEAN_PROJECT"); fi
  log "registering the mtengine MCP server"
  mcp_add mtengine "${envs[@]}" -- "$bin" || rc=1
  mcp_summary || rc=1
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
for s in fetch cas lean regina mtengine mcp typst tex; do run_stage "$s"; done

echo
echo "stage times (total $((SECONDS - T0))s):"; printf '  %s\n' "${TIMES[@]}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "math setup finished with failures: ${FAILED[*]}" >&2
  exit 1
fi
echo "math setup complete."
