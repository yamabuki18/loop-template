#!/usr/bin/env bash
# Stop the environment. Default keeps volumes so `up.sh` resumes instantly.
#   ./control/down.sh            # stop containers, keep work (resumable)
#   ./control/down.sh --purge    # also remove containers + volumes (fresh start next time)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PURGE="${1:-}"
shopt -s nullglob
for f in "$STATE_DIR"/*.env; do
  (
    source "$f"
    if [ "$PURGE" = "--purge" ]; then
      docker rm -f "$CONTAINER" 2>/dev/null || true
      docker volume rm "$(volname "$TASK")" 2>/dev/null || true
    else
      docker stop "$CONTAINER" 2>/dev/null || true
    fi
  )
done
tmux kill-session -t "$SESSION" 2>/dev/null || true

# The secret broker is part of the environment.
if [ "$PURGE" = "--purge" ]; then
  docker rm -f "$(brokername)" 2>/dev/null || true
else
  docker stop "$(brokername)" 2>/dev/null || true
fi

if [ "$PURGE" = "--purge" ]; then
  docker volume rm "$(gatecache)" 2>/dev/null || true
  docker network rm "$(netname)" "$(extnetname)" 2>/dev/null || true
  # D11: also clean review worktrees the toolkit created (never touch canonical itself).
  [ -d "$CANONICAL/.git" ] && git -C "$CANONICAL" worktree prune 2>/dev/null || true
  rm -rf "$REVIEW_DIR" "$STATE_DIR/plan" 2>/dev/null || true
  echo "down — containers, work volumes, gate cache, and review worktrees purged."
else
  echo "down — containers stopped, work volumes kept (run ./control/up.sh to resume)."
fi
