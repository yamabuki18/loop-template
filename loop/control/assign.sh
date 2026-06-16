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
container_running "$TASK" || die "worker '$TASK' is not running. Run ./control/up.sh first."

printf '%s\n' "${prefixes[@]}" \
  | docker exec -i "$(cname "$TASK")" bash -lc 'mkdir -p /work/.harness && cat > /work/.harness/owned-paths'
echo "ownership domain for '$TASK':"; printf '  %s\n' "${prefixes[@]}"
echo "edits outside these prefixes (and anywhere under $PROTECTED_PATHS) are blocked by the harness."

if [ -n "$BRIEF" ]; then
  printf '# Task for %s\n\n%s\n' "$TASK" "$BRIEF" \
    | docker exec -i "$(cname "$TASK")" bash -lc 'mkdir -p /work/.harness && cat > /work/.harness/task.md'
  echo "wrote task brief to $TASK:/work/.harness/task.md"
  if tmux has-session -t "$SESSION" 2>/dev/null \
     && tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$TASK"; then
    # Send the instruction text and the submitting Enter as SEPARATE send-keys calls. Sending them
    # in one call races the Claude TUI: the trailing Enter can arrive before the pasted text is
    # committed to the input box, leaving the nudge typed-but-unsubmitted so the worker never starts.
    tmux send-keys -t "$SESSION:$TASK" "Read /work/.harness/task.md — this is your assignment. Implement on your branch and commit (it auto-pushes). Do not run the test suite; the supervisor verifies."
    sleep 1
    tmux send-keys -t "$SESSION:$TASK" Enter
    echo "nudged worker '$TASK' to start."
  fi
fi
