#!/usr/bin/env bash
# Re-sync worker branch(es) onto the current BASE_BRANCH after a land (D3/A3). Runs the
# fetch+rebase+force-push INSIDE the worker container via docker exec — this path legitimately
# bypasses the client-side guard hooks (the supervisor is the trusted party), and pushing the
# rebased work/* branch is allowed by the exchange pre-receive (only protected branches are
# blocked). On rebase conflict it ABORTS and routes the conflicting file list back to the worker
# as feedback instead of guessing a resolution.
#   ./control/sync.sh <task> [<task> ...]   # rebase the named workers
#   ./control/sync.sh --others <task>       # rebase every worker EXCEPT <task> (post-land)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tasks=()
if [ "${1:-}" = "--others" ]; then
  exclude="${2:?usage: sync.sh --others <task>}"
  while read -r t; do [ "$t" = "$exclude" ] || tasks+=("$t"); done < <(worker_tasks)
else
  [ $# -ge 1 ] || die "usage: sync.sh <task> [<task> ...]   |   sync.sh --others <task>"
  tasks=("$@")
fi

[ "${#tasks[@]}" -ge 1 ] || { echo "sync: no other workers to re-sync."; exit 0; }

rc_any=0
for TASK in "${tasks[@]}"; do
  [ -f "$STATE_DIR/$TASK.env" ] || { echo "sync: unknown task '$TASK' (skipped)"; continue; }
  ( source "$STATE_DIR/$TASK.env"
    container_running "$TASK" || { echo "sync: '$TASK' not running (skipped)"; exit 0; }

    # Refresh the exchange's base ref so the in-container fetch sees the just-landed commit.
    git -C "$EXCHANGE" fetch -q "$CANONICAL" "refs/heads/$BASE_BRANCH:refs/heads/$BASE_BRANCH" 2>/dev/null || true

    inner='set -e; cd /work
      git fetch -q origin
      if git rebase "origin/'"$BASE_BRANCH"'"; then
        git push -q --force-with-lease origin HEAD
        echo "SYNC_OK"
      else
        files="$(git diff --name-only --diff-filter=U)"
        git rebase --abort || true
        mkdir -p /work/.harness
        { echo "# Rebase conflict onto '"$BASE_BRANCH"' — resolve these, then commit (auto-pushes):";
          echo "$files"; } > /work/.harness/feedback.md
        echo "SYNC_CONFLICT"
      fi'
    out="$(docker exec "$CONTAINER" bash -lc "$inner" 2>&1 || true)"
    if printf '%s' "$out" | grep -q SYNC_OK; then
      echo "sync: '$TASK' rebased onto $BASE_BRANCH and pushed."
      progress_log SYNCED "$TASK" "$BRANCH" "rebased onto $BASE_BRANCH"
    else
      echo "sync: '$TASK' has a rebase CONFLICT — routed to its feedback.md for the worker to resolve."
      progress_log SYNC_CONFLICT "$TASK" "$BRANCH" "rebase conflict onto $BASE_BRANCH"
      notify "$TASK rebase conflict — needs attention"
      exit 9
    fi
  ) || rc_any=$?
done
exit "$rc_any"
