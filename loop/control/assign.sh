#!/usr/bin/env bash
# Supervisor: hand a slice to a worker (async, as soon as its contract test is ready).
# Declares the worker's ownership domain (path PREFIXES) and, optionally, the task brief.
# The worker's edit guard then rejects edits outside these prefixes (and tests/ is always
# off-limits). With --brief, the brief is written to the worker and it is nudged to start.
#   ./control/assign.sh w1 src/featureA/ docs/featureA/
#   ./control/assign.sh w1 --brief "Implement featureA so tests/featureA.spec.ts passes." src/featureA/
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: assign.sh <task> [--brief \"...\"] <path-prefix> [more-prefixes...]}"; shift
BRIEF=""; prefixes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) BRIEF="${2:-}"; shift 2;;
    *) prefixes+=("$1"); shift;;
  esac
done
[ "${#prefixes[@]}" -ge 1 ] || die "give at least one path prefix, e.g. src/featureA/"
[ -e "$(worktree_for "$TASK")/.git" ] || die "worker '$TASK' has no worktree. Run ./control/spawn.sh $TASK (or up.sh) first."
st="$(agent_state "$TASK")"
[ "$st" = none ] && echo "assign: NOTE — no live herdr pane for '$TASK'; the SessionStart hook delivers the task on next launch."

HD="$(harness_dir "$TASK")"
mkdir -p "$HD"
printf '%s\n' "${prefixes[@]}" > "$HD/owned-paths"
# Fresh assignment = fresh codex-round budget. land.sh also resets, but an ESCALATED slice
# never lands — without this, the next slice on the same worker would inherit a spent budget
# and codex high-severity concerns would silently pass. Same for the verify freshness token:
# it certifies the PREVIOUS slice's (base, branch) pair, not this one.
codex_rounds_reset "$TASK"
rm -f "$STATE_DIR/$TASK.verified" 2>/dev/null || true
echo "ownership domain for '$TASK':"; printf '  %s\n' "${prefixes[@]}"
echo "edits outside these prefixes (and anywhere under $PROTECTED_PATHS) are blocked by the harness."

if [ -n "$BRIEF" ]; then
  printf '# Task for %s\n\n%s\n' "$TASK" "$BRIEF" > "$HD/task.md"
  echo "wrote task brief to $HD/task.md"
  if agent_send "$TASK" "Read $HD/task.md — this is your assignment. Implement on your branch and commit. Do not run the test suite; the supervisor verifies."; then
    echo "nudged worker '$TASK' to start."
  fi
fi
