#!/usr/bin/env bash
# Conflict radar. Shows each worker branch's changed files (vs BASE_BRANCH) and flags any
# file touched by more than one worker — i.e. an imminent merge conflict. Run it before
# assigning new work and before landing. v3: branches live in canonical (shared worktree
# refs), so this is one local diff per worker — no exchange fetch.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

declare -A OWNERS   # file -> "w1 w2 ..."
any=0

echo "Per-worker change footprint (vs $BASE_BRANCH, committed state):"
shopt -s nullglob
for f in "$STATE_DIR"/*.env; do
  source "$f"   # TASK BRANCH WORKTREE
  any=1
  files="$(git -C "$CANONICAL" diff --name-only "${BASE_BRANCH}...${BRANCH}" 2>/dev/null || true)"
  cnt=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    OWNERS["$file"]+=" $TASK"
    cnt=$((cnt+1))
  done <<< "$files"
  printf "  %-6s %-18s %d files\n" "$TASK" "$BRANCH" "$cnt"
done
[ "$any" = 1 ] || { echo "  (no workers found — run ./control/up.sh)"; exit 0; }

echo
echo "Files touched by more than one worker:"
conflicts=0
for file in "${!OWNERS[@]}"; do
  # shellcheck disable=SC2086
  set -- ${OWNERS[$file]}
  if [ "$#" -gt 1 ]; then
    printf "  ! %-52s -> %s\n" "$file" "${OWNERS[$file]# }"
    conflicts=$((conflicts+1))
  fi
done
if [ "$conflicts" -eq 0 ]; then
  echo "  none — partitions are clean."
else
  echo
  echo "  $conflicts overlapping file(s). Narrow a scope, reassign, or land one branch first then rebase the others."
fi
