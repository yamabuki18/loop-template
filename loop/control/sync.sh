#!/usr/bin/env bash
# Re-sync worker branch(es) onto the current BASE_BRANCH after a land (A3). v3 rebases each
# worker's WORKTREE directly (supervisor-side git — the client guard hooks only fence the
# worker's own Claude, not this script). Race guards, in order:
#   - herdr agent state 'working'      -> SYNC_DEFERRED, skip (never rebase under a live edit;
#                                         the next land or a manual sync retries)
#   - herdr unknown/none (server down) -> defer if the worktree committed within SYNC_IDLE_SECS
#                                         (can't confirm idle -> don't corrupt a live worktree)
#   - dirty/staged worktree            -> feedback "commit so I can rebase you", exit 9
#   - rebase conflict                  -> abort + route conflicting files as feedback, exit 9
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
    WT="${WORKTREE:-$(worktree_for "$TASK")}"
    [ -e "$WT/.git" ] || { echo "sync: '$TASK' has no worktree (skipped)"; exit 0; }
    HD="$(harness_dir "$TASK")"

    # Never rebase under a worker that is mid-burst — a moving worktree is how you corrupt work.
    # herdr is the primary signal but best-effort: when it can't report (server down, crashed
    # pane) agent_state is 'none', NOT 'working', so the old check would happily rebase a
    # live-but-unreported worker. Fall back to a recency heuristic in that case (SYNC_IDLE_SECS).
    st="$(agent_state "$TASK")"
    case "$st" in
      working)
        echo "sync: '$TASK' is busy (agent working) — deferred."
        progress_log SYNC_DEFERRED "$TASK" "$BRANCH" "agent working; will retry on next land"
        exit 0 ;;
      idle|blocked|done)
        : ;;  # herdr confirms the worker is not mid-burst — safe to proceed.
      *)
        # Unknown/none: herdr can't confirm. Defer if the worktree committed too recently.
        last="$(git -C "$WT" log -1 --format=%ct 2>/dev/null || echo 0)"
        quiet=$(( "$(date +%s)" - ${last:-0} ))
        if [ "$(sync_unknown_decision "$quiet")" = defer ]; then
          echo "sync: '$TASK' herdr state unknown and last commit ${quiet}s ago (< ${SYNC_IDLE_SECS}s) — deferring (cannot confirm idle)."
          progress_log SYNC_DEFERRED "$TASK" "$BRANCH" "herdr unknown; recent activity ${quiet}s; deferred"
          exit 0
        fi ;;
    esac
    if ! git -C "$WT" diff --quiet 2>/dev/null || ! git -C "$WT" diff --cached --quiet 2>/dev/null; then
      mkdir -p "$HD"
      { echo "# Rebase pending onto $BASE_BRANCH — you have uncommitted changes."
        echo "Commit them (or discard) so the supervisor can rebase your branch onto the new base."
      } > "$HD/feedback.md"
      echo "sync: '$TASK' has uncommitted changes — asked the worker to commit first."
      progress_log SYNC_CONFLICT "$TASK" "$BRANCH" "dirty worktree; rebase deferred to worker"
      exit 9
    fi

    if git -C "$WT" rebase "$BASE_BRANCH" >/dev/null 2>&1; then
      echo "sync: '$TASK' rebased onto $BASE_BRANCH."
      progress_log SYNCED "$TASK" "$BRANCH" "rebased onto $BASE_BRANCH"
      agent_send "$TASK" "Your branch was rebased onto the new $BASE_BRANCH by the supervisor — run 'git status' before continuing." || true
    else
      files="$(git -C "$WT" diff --name-only --diff-filter=U 2>/dev/null || true)"
      git -C "$WT" rebase --abort 2>/dev/null || true
      mkdir -p "$HD"
      { echo "# Rebase conflict onto $BASE_BRANCH — resolve these, then commit:"
        echo "$files"
        echo
        echo "You are NOT allowed to run 'git rebase' yourself; instead re-apply your intent on top"
        echo "of the current files (the supervisor will rebase again), or ask the supervisor."
      } > "$HD/feedback.md"
      echo "sync: '$TASK' has a rebase CONFLICT — routed to its feedback.md for the worker to resolve."
      progress_log SYNC_CONFLICT "$TASK" "$BRANCH" "rebase conflict onto $BASE_BRANCH"
      notify "$TASK rebase conflict — needs attention"
      exit 9
    fi
  ) || rc_any=$?
done
exit "$rc_any"
