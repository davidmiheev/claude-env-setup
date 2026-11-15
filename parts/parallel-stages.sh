# >>> parallel-stages (shared by the setup-*.sh scripts) ------------------------------
# spawn NAME runs stage_<name> in a background subshell (output to $LOGDIR/NAME.log);
# join NAME... waits, prints each stage's log with its duration, and records it in TIMES.
T0="${T0:-$SECONDS}"
FAILED=()
TIMES=()
LOGDIR="$(mktemp -d)"
declare -A PID STARTED
spawn() {
  local name="$1"
  if skip "$name"; then echo "[+$((SECONDS - T0))s] skipping $name"; return 0; fi
  echo "[+$((SECONDS - T0))s] start $name"
  STARTED[$name]=$SECONDS
  ( set +e; s0=$SECONDS; ( set -euo pipefail; "stage_${name//-/_}" ) >"$LOGDIR/$name.log" 2>&1; echo $? >"$LOGDIR/$name.rc"; echo $((SECONDS - s0)) >"$LOGDIR/$name.secs" ) &
  PID[$name]=$!
}
join() {
  local name rc secs
  for name in "$@"; do
    [ -n "${PID[$name]:-}" ] || continue
    wait "${PID[$name]}" || true
    rc="$(cat "$LOGDIR/$name.rc" 2>/dev/null || echo 1)"
    secs="$(cat "$LOGDIR/$name.secs" 2>/dev/null || echo $((SECONDS - STARTED[$name])))"
    log "stage: $name (${secs}s, $([ "$rc" = 0 ] && echo ok || echo "FAILED, exit $rc"))"
    cat "$LOGDIR/$name.log"
    TIMES+=("$(printf '%-12s %4ss  (started +%ss)%s' "$name" "$secs" "$((STARTED[$name] - T0))" "$([ "$rc" -ne 0 ] && echo '  FAILED')")")
    if [ "$rc" -ne 0 ]; then warn "stage '$name' failed (exit $rc)"; FAILED+=("$name"); fi
    unset "PID[$name]"
  done
}
print_times() { echo; echo "stage times (wall $((SECONDS - T0))s):"; printf '  %s\n' "${TIMES[@]}"; }
# <<< parallel-stages
