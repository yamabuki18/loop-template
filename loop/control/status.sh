#!/usr/bin/env bash
# Show all workers, their branch, run state, and last STATUS line.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

printf "%-8s %-16s %-9s %s\n" TASK BRANCH STATE STATUS
shopt -s nullglob
for f in "$STATE_DIR"/*.env; do
  (
    source "$f"
    if container_running "$TASK"; then
      state=running
      st="$(docker exec "$CONTAINER" bash -lc 'tail -1 /work/STATUS 2>/dev/null' 2>/dev/null || true)"
    else
      state=stopped; st=""
    fi
    printf "%-8s %-16s %-9s %s\n" "$TASK" "$BRANCH" "$state" "${st:--}"
  )
done
