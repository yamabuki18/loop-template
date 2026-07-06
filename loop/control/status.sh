#!/usr/bin/env bash
# Show all workers, their branch, agent state, and last STATUS line.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

printf "%-8s %-16s %-9s %s\n" TASK BRANCH STATE STATUS
shopt -s nullglob
for f in "$STATE_DIR"/*.env; do
  (
    source "$f"
    state="$(agent_state "$TASK")"
    st="$(tail -1 "$(harness_dir "$TASK")/STATUS" 2>/dev/null || true)"
    printf "%-8s %-16s %-9s %s\n" "$TASK" "$BRANCH" "$state" "${st:--}"
  )
done
