#!/usr/bin/env bash
# Acceptance gate (harness ladder L3/L4). In a CLEAN, throwaway detached worktree:
#   1. lay out BASE_BRANCH at state/gate/<task>.<pid> (no clone — refs are local)
#   2. trial-merge the worker branch into it (catches conflicts/integration breakage)
#   3. run the project's checks on the merged result (gate-scope secrets via secret_exec)
# Exit 0 = pass, non-zero = fail. `land.sh` runs this before merging.
#   exit 3 = merge conflict against base
#   exit 4 = the worker branch modified a PROTECTED_PATH (e.g. tests/, harness/ when
#            GATE_PROTECT_HARNESS=1) — supervisor-owned. This is the HARD guarantee enforcement
#            point: it runs supervisor-side, where the worker cannot reach it, unlike the
#            client-side guard-paths hook (D5).
#   exit 6 = test-gaming patterns in the worker diff and GATE_TESTGAMING=block.
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
# Workspace gate extensions ($CONFIG_DIR/gate.d/*.sh, hand-written or from `loop harness`)
# then run IN ADDITION to the resolved check — workspace-owned, worker-unreachable (see below).
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
# GATE_PROTECT_HARNESS extends the same wall to harness/: the gate's check scripts run FROM THE
# MERGED TREE below, so a worker editing harness/check.sh would be neutering its own gate — the
# cheapest reward hack. This is a security-class guard (adversarial assumption), not a
# capability crutch: do NOT strip it when models improve.
effective_protected="${PROTECTED_PATHS:-}"
[ "${GATE_PROTECT_HARNESS:-1}" = 1 ] && effective_protected="$effective_protected harness/"
if [ -n "${effective_protected// /}" ]; then
  mb="$(git -C "$WT" merge-base "$BASE_BRANCH" "$BRANCH")"
  # shellcheck disable=SC2086  # a space-separated pathspec list by design
  touched="$(git -C "$WT" diff --name-only "$mb" "$BRANCH" -- $effective_protected)"
  if [ -n "$touched" ]; then
    echo "GATE: branch modifies supervisor-owned protected path(s) — land DENIED:"
    echo "$touched" | sed 's/^/  /'
    echo "GATE FAIL: $TASK (exit 4)"
    exit 4
  fi
fi

# Test-gaming monitor (deterministic, cheap): scan lines the worker ADDED for patterns that
# weaken the verifier instead of satisfying it — skipped/disabled tests, `|| true` swallowing a
# check's exit code. Complements (does not replace) the protected-path wall: it covers the
# worker's OWN co-located tests, which are legitimately editable and therefore gameable.
# warn (default) logs and continues; block fails with exit 6; off skips. Kept warn by default
# because the patterns are heuristics — promote to block per project once tuned.
if [ "${GATE_TESTGAMING:-warn}" != off ]; then
  mb="${mb:-$(git -C "$WT" merge-base "$BASE_BRANCH" "$BRANCH")}"
  gaming="$(git -C "$WT" diff --unified=0 "$mb" "$BRANCH" 2>/dev/null \
    | awk '
        /^\+\+\+ b\// { file = substr($0, 7) }
        /^\+/ && !/^\+\+\+/ {
          line = substr($0, 2)
          istest = (file ~ /(^|\/)(tests?|__tests__|spec)(\/|$)/ || file ~ /\.(spec|test)\.[A-Za-z]+$/)
          if (istest && line ~ /\.skip[[:space:](]|(^|[^A-Za-z_])(xit|xdescribe|xtest)[[:space:](]|@pytest\.mark\.skip|t\.Skip\(/)
            printf "  %s: added skip: %s\n", file, line
          if ((file ~ /(^|\/)harness\// || file ~ /check.*\.sh$/) && line ~ /\|\| *true|\|\| *:/)
            printf "  %s: added exit-code swallow: %s\n", file, line
        }' | head -20)"
  if [ -n "$gaming" ]; then
    echo "GATE: test-gaming patterns in the worker diff (verifier-weakening changes):"
    echo "$gaming"
    progress_log TESTGAMING "$TASK" "$BRANCH" "$(echo "$gaming" | head -1 | sed 's/^ *//')"
    ontology_event CA test-gaming "gate:$TASK" "task:$TASK" "$(echo "$gaming" | wc -l | tr -d ' ') suspicious added line(s)"
    if [ "${GATE_TESTGAMING}" = block ]; then
      echo "GATE FAIL: $TASK (exit 6 — GATE_TESTGAMING=block)"
      exit 6
    fi
    echo "GATE: continuing (GATE_TESTGAMING=warn). Set GATE_TESTGAMING=block to enforce."
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

# Workspace gate extensions (gate-owned L3 seam; hand-written or adopted via `loop harness`):
# every $CONFIG_DIR/gate.d/*.sh runs on the merged tree IN ADDITION to the project checks
# above. They live in the WORKSPACE — outside the repo and outside every worker worktree — so
# a worker structurally cannot edit its own acceptance criteria. Env contract for a check:
# cwd = merged tree; GATE_TASK / GATE_BRANCH / GATE_BASE_BRANCH / GATE_MERGE_BASE describe the
# change under review. Exit 0 = pass, non-zero = fail the gate with that code.
if [ -d "$CONFIG_DIR/gate.d" ]; then
  mb="${mb:-$(git -C "$WT" merge-base "$BASE_BRANCH" "$BRANCH")}"
  for chk in "$CONFIG_DIR/gate.d"/*.sh; do
    [ -f "$chk" ] || continue
    echo "GATE: gate.d check $(basename "$chk")"
    if ( cd "$WT" && GATE_TASK="$TASK" GATE_BRANCH="$BRANCH" GATE_BASE_BRANCH="$BASE_BRANCH" \
         GATE_MERGE_BASE="$mb" secret_exec gate -- bash "$chk" ); then :; else
      rc=$?
      echo "GATE FAIL: $TASK — gate.d check $(basename "$chk") (exit $rc)"
      exit "$rc"
    fi
  done
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
