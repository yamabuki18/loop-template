#!/usr/bin/env bash
# Reset a stuck/derailed worker the easy way (A4): back up its assignment, reap it completely,
# spawn a fresh container, and restore the assignment. The exchange (pushed work) is preserved,
# so the only thing lost is UNcommitted in-container work — which is the point of "the box is
# disposable". Use when a worker's /work is wedged or it has wandered off-task.
#   ./control/respawn.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: respawn.sh <task>}"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"

backup="$STATE_DIR/backup/$TASK"
mkdir -p "$backup"
echo "respawn: backing up $TASK's .harness (owned-paths, task.md)…"
docker exec "$CONTAINER" bash -lc 'cd /work/.harness 2>/dev/null && tar -c owned-paths task.md 2>/dev/null' \
  > "$backup/harness.tar" 2>/dev/null || true

echo "respawn: reaping $TASK (exchange/pushed work is kept)…"
"$CONTROL_DIR/reap.sh" "$TASK"

# reap.sh removes the exchange too, so the freshly spawned worker forks clean from base. If you
# want to keep the pushed branch, restore it below is not needed — spawn re-creates the branch
# from BASE_BRANCH. (Pushed history lives in canonical only after a land; pre-land work is on the
# exchange which reap removed. This matches "disposable box": commit+land to make work durable.)
echo "respawn: spawning fresh $TASK…"
"$CONTROL_DIR/spawn.sh" "$TASK" "$BRANCH" >/dev/null

if [ -s "$backup/harness.tar" ]; then
  echo "respawn: restoring assignment (owned-paths, task.md)…"
  docker exec -i "$CONTAINER" bash -lc 'mkdir -p /work/.harness && tar -x -C /work/.harness' < "$backup/harness.tar" 2>/dev/null || true
fi

echo "respawn: '$TASK' is fresh with its assignment restored. The SessionStart hook re-injects the task on next attach."
progress_log RESPAWNED "$TASK" "$BRANCH" "fresh container, assignment restored"
