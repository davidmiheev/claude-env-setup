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
