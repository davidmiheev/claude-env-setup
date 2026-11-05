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
