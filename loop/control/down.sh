#!/usr/bin/env bash
# Stop the environment. Default keeps worktrees + branches so `up.sh` resumes instantly.
#   ./control/down.sh            # close the herdr panes, keep work (resumable)
#   ./control/down.sh --purge    # also remove worktrees, work branches, worker state
# The herdr SERVER is never stopped here — it is shared across projects (herdr server stop).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PURGE="${1:-}"
shopt -s nullglob

# Close this project's panes. Workspace close takes everything at once; fall back to per-agent.
if herdr_ok; then
  ws="$(herdr_workspace)"
  if [ -n "$ws" ] && herdr workspace close "$ws" >/dev/null 2>&1; then
    :
  else
    for a in loop dashboard watch; do
      if p="$(agent_pane "$a")"; then herdr pane close "$p" >/dev/null 2>&1 || true; fi
    done
    for f in "$STATE_DIR"/*.env; do
      t="$(basename "$f" .env)"
      if p="$(agent_pane "$t")"; then herdr pane close "$p" >/dev/null 2>&1 || true; fi
    done
  fi
fi
rm -f "$STATE_DIR/herdr-workspace" 2>/dev/null || true

if [ "$PURGE" = "--purge" ]; then
  for f in "$STATE_DIR"/*.env; do
    ( source "$f"
      git -C "$CANONICAL" worktree remove --force "${WORKTREE:-$(worktree_for "$TASK")}" 2>/dev/null || true
      git -C "$CANONICAL" branch -D "$BRANCH" 2>/dev/null || true
      rm -rf "$STATE_DIR/workers/$TASK" )
    rm -f "$f"
  done
  # D11: also clean review worktrees the toolkit created (never touch canonical itself).
  [ -d "$CANONICAL/.git" ] && git -C "$CANONICAL" worktree prune 2>/dev/null || true
  rm -rf "$REVIEW_DIR" "$WORKTREES_DIR" "$STATE_DIR/plan" "$STATE_DIR/gate" "$STATE_DIR/workers" "$STATE_DIR/supervisor" 2>/dev/null || true
  echo "down — panes closed; worktrees, work branches, and worker state purged."
else
  echo "down — panes closed; worktrees and branches kept (run ./control/up.sh to resume)."
fi
