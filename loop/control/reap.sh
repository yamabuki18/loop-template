#!/usr/bin/env bash
# Tear down a single worker completely (pane, worktree, work branch, review worktree, state).
# NOTE: v3 reap DESTROYS un-landed work (the branch dies with the worker) — land first, or use
# respawn.sh which preserves the assignment.
#   ./control/reap.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: reap.sh <task>}"

if p="$(agent_pane "$TASK")"; then
  herdr pane close "$p" >/dev/null 2>&1 || true
fi
git -C "$CANONICAL" worktree remove --force "$(worktree_for "$TASK")" 2>/dev/null || true
git -C "$CANONICAL" worktree remove --force "$REVIEW_DIR/$TASK" 2>/dev/null || true
git -C "$CANONICAL" branch -D "$(branch_for "$TASK")" 2>/dev/null || true
git -C "$CANONICAL" worktree prune 2>/dev/null || true
rm -rf "$STATE_DIR/workers/$TASK" "$STATE_DIR/$TASK.env" "$STATE_DIR/$TASK.codex-rounds"
echo "reaped '$TASK'"
