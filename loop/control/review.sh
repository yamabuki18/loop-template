#!/usr/bin/env bash
# Supervisor-side: lay out a FROZEN snapshot of a worker's branch as a detached worktree under
# review/<task> for inspection — distinct from the worker's LIVE worktree, which keeps moving.
#   ./control/review.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: review.sh <task>}"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"

git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BRANCH" \
  || die "no branch '$BRANCH' yet — the worker has not committed."

wt="$REVIEW_DIR/$TASK"
git -C "$CANONICAL" worktree remove --force "$wt" 2>/dev/null || true
git -C "$CANONICAL" worktree add --detach "$wt" "$BRANCH" >/dev/null

echo "review worktree: $wt  (snapshot of $BRANCH)"
echo "diff vs $BASE_BRANCH:  git -C \"$wt\" diff $BASE_BRANCH"
