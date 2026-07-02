#!/usr/bin/env bash
# Tear down a single worker completely (container, volume, exchange, review worktree, window).
#   ./control/reap.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: reap.sh <task>}"
# Fleet-pane layout kills the worker's pane; legacy layout kills its dedicated window.
if p="$(worker_pane "$TASK")"; then
  case "$p" in
    %*) tmux kill-pane -t "$p" 2>/dev/null || true
        tmux select-layout -t "$SESSION:fleet" tiled 2>/dev/null || true ;;
    *)  tmux kill-window -t "$p" 2>/dev/null || true ;;
  esac
fi
docker rm -f "$(cname "$TASK")" 2>/dev/null || true
docker volume rm "$(volname "$TASK")" 2>/dev/null || true
git -C "$CANONICAL" worktree remove --force "$REVIEW_DIR/$TASK" 2>/dev/null || true
git -C "$CANONICAL" remote remove "ex-$TASK" 2>/dev/null || true
rm -rf "$EXCHANGE_DIR/$TASK.git" "$STATE_DIR/$TASK.env"
echo "reaped '$TASK'"
