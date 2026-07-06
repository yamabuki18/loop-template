#!/usr/bin/env bash
# Supervisor-only: merge a worker's branch into BASE_BRANCH inside canonical.
# Runs the acceptance gate first; merge is aborted unless the gate passes.
# v3: the branch already lives in canonical (worktrees share refs) — no remotes, no fetch,
# and no base propagation (the v2 D3 exchange sync is now structural: every worker sees the
# new base ref the instant this merge lands).
#   ./control/land.sh <task>              # gated merge (default)
#   ./control/land.sh <task> --no-verify  # supervisor override, skip the gate
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK=""; NO_VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-verify) NO_VERIFY=1; shift;;
    *) TASK="$1"; shift;;
  esac
done
[ -n "$TASK" ] || die "usage: land.sh <task> [--no-verify]"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"

if [ "$NO_VERIFY" -eq 1 ]; then
  echo "land: --no-verify set, SKIPPING acceptance gate (supervisor override)."
else
  "$CONTROL_DIR/gate.sh" "$TASK" \
    || die "acceptance gate failed — merge aborted. Fix on the worker and re-verify, or override with: ./control/land.sh $TASK --no-verify"
fi

git -C "$CANONICAL" checkout -q "$BASE_BRANCH"
git -C "$CANONICAL" merge --no-ff -m "merge $BRANCH" "$BRANCH"
echo "merged $BRANCH into $BASE_BRANCH (canonical)."

# This slice's codex-round budget is spent state — reset it for the next assignment.
codex_rounds_reset "$TASK"

# Refresh the planner's structural map from the NEW base (deterministic, tokenless), so the
# next DISCOVER/PLAN cycle sees the code that just landed without re-exploring the repo.
repo_map_refresh

# Regenerate wiki/index.md from page frontmatter and land it with the merge (deterministic,
# tokenless). Workers own their module pages; the index — the file everyone would fight over —
# is owned by this script, so it can never be a merge conflict or drift from the pages.
wiki_index_refresh
if [ -f "$CANONICAL/wiki/index.md" ]; then
  git -C "$CANONICAL" add wiki/index.md
  git -C "$CANONICAL" diff --cached --quiet || git -C "$CANONICAL" commit -qm "wiki: refresh index (auto)"
fi

# Re-sync the OTHER live workers onto the new base (rebases their worktrees directly; on
# conflict it aborts and routes the conflicting files back to the worker instead of guessing).
echo "next: re-sync the other workers onto the new base:  ./control/sync.sh --others $TASK"
