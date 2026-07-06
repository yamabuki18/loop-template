#!/usr/bin/env bash
# Absorb the PROJECT's new commits into the loop (daily dev: you keep committing while the loop
# works). Fast-forwards canonical's BASE_BRANCH from the project repo (canonical's origin);
# workers see the new base instantly (shared worktree refs). ff-only ON PURPOSE: if the
# histories diverged, the loop has landed work the project hasn't merged yet — publish + merge
# first, then refresh (never auto-merge two histories behind the supervisor's back).
#
#   ./control/refresh.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ -d "$CANONICAL/.git" ] || die "no canonical yet — run setup first."
git -C "$CANONICAL" remote get-url origin >/dev/null 2>&1 \
  || die "canonical has no 'origin' (created empty) — nothing to refresh from."

before="$(git -C "$CANONICAL" rev-parse --short "$BASE_BRANCH" 2>/dev/null || echo '?')"
git -C "$CANONICAL" fetch -q origin "$BASE_BRANCH"
cur="$(git -C "$CANONICAL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
[ "$cur" = "$BASE_BRANCH" ] || git -C "$CANONICAL" checkout -q "$BASE_BRANCH"
if ! git -C "$CANONICAL" merge --ff-only -q FETCH_HEAD; then
  die "canonical and the project DIVERGED (the loop landed work the project doesn't have).
  1) deliver the loop's work:      ./control/publish.sh
  2) merge it in the project:      git merge ${PUBLISH_BRANCH:-loop/$BASE_BRANCH}
  3) re-run:                       ./control/refresh.sh"
fi
after="$(git -C "$CANONICAL" rev-parse --short "$BASE_BRANCH")"

if [ "$before" = "$after" ]; then
  echo "refresh: already up to date ($BASE_BRANCH@$after)."
  exit 0
fi

# Refresh the planner's map. Workers already see the new base ref (shared worktrees) —
# live ones still need a rebase: advise, don't surprise.
repo_map_refresh

echo "refresh: $BASE_BRANCH $before -> $after (from project)."
tasks="$(worker_tasks | tr '\n' ' ')"
[ -n "$tasks" ] && echo "next: rebase live workers onto the new base:  ./control/sync.sh $tasks"
progress_log REFRESHED "-" "$BASE_BRANCH@$after" "from project ($before -> $after)"
