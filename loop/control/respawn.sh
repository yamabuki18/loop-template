#!/usr/bin/env bash
# Reset a stuck/derailed worker the easy way (A4): back up its assignment, reap it completely,
# spawn a fresh worktree, and restore the assignment. Landed work lives in canonical and is
# safe; the branch and any un-landed commits die with the reap — which is the point of "the
# box is disposable". Use when a worker's worktree is wedged or it has wandered off-task.
#   ./control/respawn.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: respawn.sh <task>}"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"

backup="$STATE_DIR/backup/$TASK"
rm -rf "$backup"; mkdir -p "$backup"
echo "respawn: backing up $TASK's assignment (owned-paths, task.md)…"
hd="$(harness_dir "$TASK")"
for f in owned-paths task.md; do
  [ -f "$hd/$f" ] && cp "$hd/$f" "$backup/" || true
done

echo "respawn: reaping $TASK (landed work in canonical is safe)…"
"$CONTROL_DIR/reap.sh" "$TASK"

echo "respawn: spawning fresh $TASK…"
"$CONTROL_DIR/spawn.sh" "$TASK" "$BRANCH" >/dev/null

hd="$(harness_dir "$TASK")"; mkdir -p "$hd"
for f in owned-paths task.md; do
  [ -f "$backup/$f" ] && cp "$backup/$f" "$hd/" || true
done

echo "respawn: '$TASK' is fresh with its assignment restored. The SessionStart hook re-injects the task on next attach."
progress_log RESPAWNED "$TASK" "$BRANCH" "fresh worktree, assignment restored"
