#!/usr/bin/env bash
# Acceptance gate (harness ladder L3/L4). In a CLEAN, throwaway container:
#   1. clone the worker's exchange repo (read-only mount)
#   2. trial-merge the worker branch into BASE_BRANCH (catches conflicts/integration breakage)
#   3. run the project's checks on the merged result
# Exit 0 = pass, non-zero = fail. `land.sh` runs this before merging.
#   exit 3 = merge conflict against base
#   exit 4 = the worker branch modified a PROTECTED_PATH (e.g. tests/) — supervisor-owned.
#            This is the HARD guarantee enforcement point: it lives on the host (gate), where
#            the worker cannot reach it, unlike the client-side guard-paths hook (D5).
#
# Check resolution order (first match wins):
#   1. <repo>/harness/check.sh           (commit this in your repo to make the gate blocking)
#   2. CHECK_CMD from control/config.env  (or --cmd "<...>" here)
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

# Make sure the exchange's base ref is current before the trial merge.
git -C "$EXCHANGE" fetch -q "$CANONICAL" "refs/heads/$BASE_BRANCH:refs/heads/$BASE_BRANCH" 2>/dev/null || true

echo "GATE: $TASK ($BRANCH) — trial-merge into $BASE_BRANCH in a clean container, then run checks."

inner='
set -e
mkdir -p /cache/npm /cache/pnpm /cache/yarn /cache/pip /cache/go /cache/cargo 2>/dev/null || true
# Clone to /tmp (always writable by USER dev). With GATE_CACHE=0 we keep the image USER
# (dev) and "/" is root-owned, so cloning to /check would fail — this was bug D2.
git clone -q /origin.git /tmp/check
cd /tmp/check
git checkout -q -B "$BASE_BRANCH" "origin/$BASE_BRANCH"
# D5 HARD guarantee: reject any branch that touched a PROTECTED_PATH since it forked from base.
# merge-base comparison means the supervisor updating tests/ on base (which the worker then
# rebases in) is NOT a violation — only the worker authoring changes there is.
if [ -n "${PROTECTED_PATHS:-}" ]; then
  base="$(git merge-base "origin/$BASE_BRANCH" "origin/$BRANCH")"
  touched="$(git diff --name-only "$base" "origin/$BRANCH" -- $PROTECTED_PATHS)"
  if [ -n "$touched" ]; then
    echo "GATE: branch modifies supervisor-owned protected path(s) — land DENIED:"; echo "$touched" | sed "s/^/  /"
    exit 4
  fi
fi
if ! git -c user.name=gate -c user.email=gate@local merge --no-ff -q "origin/$BRANCH" -m "gate trial merge"; then
  echo "GATE: merge conflict against $BASE_BRANCH — resolve on the worker before landing."; exit 3
fi
if [ -f harness/check.sh ]; then
  echo "GATE: running harness/check.sh"; bash harness/check.sh
elif [ -n "${CHECK_CMD:-}" ]; then
  echo "GATE: running CHECK_CMD"; bash -lc "$CHECK_CMD"
elif [ -f package.json ]; then
  echo "GATE: npm ci && npm test"; npm ci && npm test
else
  echo "GATE: no checks configured (advisory pass). Commit harness/check.sh to make this blocking."
fi
'

# Persistent download cache (keeps node_modules etc. clean per run, but reuses downloads).
# Runs as root so the fresh cache volume is writable; the gate is a throwaway CI-like runner.
cache_args=()
if [ "${GATE_CACHE:-1}" = "1" ]; then
  cache_args=(
    --user root
    -v "$(gatecache)":/cache
    -e npm_config_cache=/cache/npm
    -e PNPM_HOME=/cache/pnpm
    -e YARN_CACHE_FOLDER=/cache/yarn
    -e PIP_CACHE_DIR=/cache/pip
    -e GOMODCACHE=/cache/go
    -e CARGO_HOME=/cache/cargo
  )
fi

# Test-time secrets (control/secret.gate.env) are injected ONLY here — the gate runs deterministic
# checks, not Claude, so a DB URL / test API key used by the suite never reaches the worker Claude.
mapfile -t GSEC < <(gate_secret_docker_args)

# --entrypoint bash is REQUIRED: the image's ENTRYPOINT is ["sleep","infinity"] (workers stay
# alive for `docker exec`). Without overriding it, `docker run IMAGE bash -lc ...` becomes
# `sleep infinity bash -lc ...` and the gate ALWAYS fails with a sleep error instead of running.
if docker run --rm "${cache_args[@]}" \
     --entrypoint bash \
     -e BRANCH="$BRANCH" -e BASE_BRANCH="$BASE_BRANCH" -e CHECK_CMD="$CHECK_CMD" \
     -e PROTECTED_PATHS="${PROTECTED_PATHS:-}" \
     "${GSEC[@]}" \
     -v "$EXCHANGE":/origin.git:ro \
     "$IMAGE" -lc "$inner"; then
  echo "GATE PASS: $TASK"
else
  rc=$?
  echo "GATE FAIL: $TASK (exit $rc)"
  exit "$rc"
fi
