#!/usr/bin/env bash
# Launch ONE worker's Claude inside its worktree — this is what the herdr pane runs (spawn.sh),
# and what a human runs manually when no herdr server is around. It is the single seam where
# the worker credential enters a process: secret_exec injects the worker scope's env into the
# claude process only (nothing lands in this shell or the pane env).
#   ./control/worker-run.sh <task>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: worker-run.sh <task>}"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK' — run ./control/spawn.sh $TASK first."
source "$STATE_DIR/$TASK.env"
WT="${WORKTREE:-$(worktree_for "$TASK")}"
[ -e "$WT/.git" ] || die "worktree missing for '$TASK' — run ./control/spawn.sh $TASK."

# Env contract with the worker harness hooks (they are children of claude and inherit this):
#   CLAUDE_CONFIG_DIR : isolated per-worker config (hooks, CLAUDE.md, onboarding pre-seed)
#   HARNESS_DIR       : out-of-tree task.md / feedback.md / owned-paths / STATUS
#   HARNESS_WORKTREE  : the wall — guard-paths denies any edit outside it
CLAUDE_CONFIG_DIR="$(claude_cfg_dir "$TASK")"; export CLAUDE_CONFIG_DIR
HARNESS_DIR="$(harness_dir "$TASK")"; export HARNESS_DIR
export HARNESS_WORKTREE="$WT"
export TASK FEAT_BRANCH="$BRANCH" BASE_BRANCH PROTECTED_PATHS
# Worker identity via env, not `git config` (repo config is shared across worktrees; the
# guard blocks config writes — this is the sanctioned channel).
export GIT_AUTHOR_NAME="worker-$TASK"  GIT_AUTHOR_EMAIL="worker-$TASK@loop.local"
export GIT_COMMITTER_NAME="worker-$TASK" GIT_COMMITTER_EMAIL="worker-$TASK@loop.local"
export DISABLE_AUTOUPDATER=1

cd "$WT"
# Model routing: workers are the parallel, high-volume role — config.env routes them to a
# cheaper model (WORKER_MODEL, default sonnet). Empty = the claude CLI's own default.
claude_args=(--dangerously-skip-permissions)
[ -n "${WORKER_MODEL:-}" ] && claude_args=(--model "$WORKER_MODEL" "${claude_args[@]}")
secret_exec worker -- claude "${claude_args[@]}" || true
# Keep the pane alive after Claude exits so the operator can inspect/restart in place.
exec bash
