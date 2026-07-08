#!/usr/bin/env bash
# Acceptance gate (harness ladder L3/L4). In a CLEAN, throwaway detached worktree:
#   1. lay out BASE_BRANCH at state/gate/<task>.<pid> (no clone — refs are local)
#   2. trial-merge the worker branch into it (catches conflicts/integration breakage)
#   3. run the project's checks on the merged result (gate-scope secrets via secret_exec)
# Exit 0 = pass, non-zero = fail. `land.sh` runs this before merging.
#   exit 3 = merge conflict against base
#   exit 4 = the worker branch modified a PROTECTED_PATH (e.g. tests/) — supervisor-owned.
#            This is the HARD guarantee enforcement point: it runs supervisor-side, where the
#            worker cannot reach it, unlike the client-side guard-paths hook (D5).
#
# After a PASS, the codex second opinion (if enabled) reviews the merged tree here — this is
# the only moment the merged tree exists on disk. Its verdict goes to state/gate/<task>.codex.json
# and NEVER changes the gate's own exit code (policy is applied by verify.sh).
#
# Check resolution order (first match wins):
#   1. <repo>/harness/check.sh           (commit this in your repo to make the gate blocking)
#   2. CHECK_CMD from config.env          (or --cmd "<...>" here)
#   3. package.json present               -> npm ci && npm test
#   4. nothing                            -> advisory pass (warn, do not block)
#
#   ./control/gate.sh <task> [--cmd "<check command>"]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK=""; CMD_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cmd) CMD_OVERRIDE="${2:-}"; shift 2;;
    *)     TASK="$1"; shift;;
  esac
done
[ -n "$TASK" ] || die "usage: gate.sh <task> [--cmd \"<check command>\"]"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"
: "${CHECK_CMD:=}"
[ -n "$CMD_OVERRIDE" ] && CHECK_CMD="$CMD_OVERRIDE"

git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BRANCH" \
  || die "no branch '$BRANCH' yet — the worker has not committed."

echo "GATE: $TASK ($BRANCH) — trial-merge into $BASE_BRANCH in a clean worktree, then run checks."

mkdir -p "$STATE_DIR/gate"
WT="$STATE_DIR/gate/$TASK.$$"
cleanup() {
  git -C "$CANONICAL" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$CANONICAL" worktree prune 2>/dev/null || true
}
trap cleanup EXIT
git -C "$CANONICAL" worktree add --detach "$WT" "$BASE_BRANCH" >/dev/null

rc=0
# D5 HARD guarantee: reject any branch that touched a PROTECTED_PATH since it forked from base.
# merge-base comparison means the supervisor updating tests/ on base (which the worker is then
# rebased onto) is NOT a violation — only the worker authoring changes there is.
if [ -n "${PROTECTED_PATHS:-}" ]; then
  mb="$(git -C "$WT" merge-base "$BASE_BRANCH" "$BRANCH")"
  # shellcheck disable=SC2086  # PROTECTED_PATHS is a space-separated pathspec list by design
  touched="$(git -C "$WT" diff --name-only "$mb" "$BRANCH" -- $PROTECTED_PATHS)"
  if [ -n "$touched" ]; then
    echo "GATE: branch modifies supervisor-owned protected path(s) — land DENIED:"
    echo "$touched" | sed 's/^/  /'
    echo "GATE FAIL: $TASK (exit 4)"
    exit 4
  fi
fi

if ! git -C "$WT" -c user.name=gate -c user.email=gate@local merge --no-ff -q "$BRANCH" -m "gate trial merge" 2>&1; then
  git -C "$WT" merge --abort 2>/dev/null || true
  echo "GATE: merge conflict against $BASE_BRANCH — resolve on the worker before landing."
  echo "GATE FAIL: $TASK (exit 3)"
  exit 3
fi

# Checks on the merged tree. Gate-scope secrets (secret.gate.sops.env) are injected ONLY into
# this deterministic child process — they never enter any Claude process.
if [ -f "$WT/harness/check.sh" ]; then
  echo "GATE: running harness/check.sh"
  if ( cd "$WT" && secret_exec gate -- bash harness/check.sh ); then rc=0; else rc=$?; fi
elif [ -n "${CHECK_CMD:-}" ]; then
  echo "GATE: running CHECK_CMD"
  if ( cd "$WT" && secret_exec gate -- bash -c "$CHECK_CMD" ); then rc=0; else rc=$?; fi
elif [ -f "$WT/package.json" ]; then
  echo "GATE: npm ci && npm test"
  if ( cd "$WT" && secret_exec gate -- bash -c "npm ci && npm test" ); then rc=0; else rc=$?; fi
else
  echo "GATE: no checks configured (advisory pass). Commit harness/check.sh to make this blocking."
fi

if [ "$rc" -ne 0 ]; then
  echo "GATE FAIL: $TASK (exit $rc)"
  exit "$rc"
fi

# Second opinion on the merged tree (independent codex review; artifacts only). Evaluation
# only — exit 3 (skip) and concerns alike leave the gate's PASS untouched; verify.sh applies
# the policy from the verdict file.
so_mode="${SECOND_OPINION_GATE:-${SECOND_OPINION:-advise}}"
if [ "$so_mode" != off ] && [ -x "$CONTROL_DIR/second-opinion.sh" ]; then
  mb="${mb:-$(git -C "$WT" merge-base "$BASE_BRANCH" "$BRANCH")}"
  if "$CONTROL_DIR/second-opinion.sh" gate \
       --task "$TASK" --dir "$WT" --base "$mb" --branch "$BRANCH" \
       --brief "$(harness_dir "$TASK")/task.md" \
       --out "$STATE_DIR/gate/$TASK.codex.json"; then :; fi
fi

echo "GATE PASS: $TASK"
