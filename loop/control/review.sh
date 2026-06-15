#!/usr/bin/env bash
# Supervisor-side: fetch a worker's branch into canonical and lay it out as a worktree
# under review/<task> for inspection. Read-only review; does not touch protected branches.
#   ./control/review.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: review.sh <task>}"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"

git -C "$CANONICAL" remote remove "ex-$TASK" 2>/dev/null || true
git -C "$CANONICAL" remote add "ex-$TASK" "$EXCHANGE"
git -C "$CANONICAL" fetch "ex-$TASK" "$BRANCH" >/dev/null

wt="$REVIEW_DIR/$TASK"
git -C "$CANONICAL" worktree remove --force "$wt" 2>/dev/null || true
git -C "$CANONICAL" worktree add --detach "$wt" "ex-$TASK/$BRANCH" >/dev/null

echo "review worktree: $wt  (branch $BRANCH)"
echo "diff vs $BASE_BRANCH:  git -C \"$wt\" diff $BASE_BRANCH"
