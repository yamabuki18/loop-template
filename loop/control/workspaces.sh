#!/usr/bin/env bash
# List every central loop workspace under $LOOP_HOME/workspaces (the `loop here` fleet of
# fleets): which project it belongs to, backlog counters, and how many workers are running.
#   ./control/workspaces.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
set +e   # pure reporting — a missing file must not kill the listing

printf '%-16s %-6s %-14s %s\n' NAME WORKERS "BACKLOG(t/d/x)" PROJECT
found=0
for m in "$LOOP_HOME"/workspaces/*/.loop-workspace; do
  [ -f "$m" ] || continue
  found=1
  ws="$(dirname "$m")"
  name="$( (source "$ws/config.env" 2>/dev/null; echo "${PROJECT_NAME:-?}") )"
  proj="$(sed -n 's/^PROJECT_PATH=//p' "$m" | head -1)"
  # `grep -c` prints "0" AND exits 1 on zero matches — no `|| echo 0` (it would double-print).
  todo="$(grep -c '^- \[ \] '  "$ws/memory/backlog.md" 2>/dev/null)";  todo="${todo:-0}"
  doing="$(grep -c '^- \[~\] ' "$ws/memory/backlog.md" 2>/dev/null)"; doing="${doing:-0}"
  done_="$(grep -c '^- \[x\] ' "$ws/memory/backlog.md" 2>/dev/null)"; done_="${done_:-0}"
  running="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^cw-${name}-")"
  printf '%-16s %-6s %-14s %s\n' "$name" "$running" "$todo/$doing/$done_" "${proj:-$ws}"
done
[ "$found" = 1 ] || echo "(no central workspaces yet — attach one with:  cd <project> && loop here)"
exit 0
