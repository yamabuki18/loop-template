#!/usr/bin/env bash
# DISCOVER/PLAN — decompose ONE backlog goal into vertical slices + thin contract tests, using a
# HEADLESS, throwaway Claude container (the "planner"). The planner is isolated exactly like a
# worker: it sees only a READ-ONLY copy of the code + skills/ + memory/, plus a scratch /out dir
# with no secrets. It never gets host credentials (credential concealment, #3) — just a disposable
# key. The planner is the supervisor role, so it MAY author tests/ (workers may not).
#
# Output (consumed by loop.sh):
#   state/plan/slices.json   -> [{ "name": "...", "paths": ["src/x/"], "brief": "..." }, ...]
# Side effect:
#   contract tests the planner wrote are committed into canonical's tests/ on BASE_BRANCH, so the
#   acceptance gate enforces them for every slice.
#
#   ./control/plan.sh "<the goal text>"
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GOAL="${1:?usage: plan.sh \"<goal text>\"}"
have_credential || die "no credential set ($CONFIG_DIR/secret.env): set CLAUDE_CODE_OAUTH_TOKEN (subscription) or ANTHROPIC_API_KEY (metered API)."
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "worker image missing — run ./control/setup.sh first."

PLAN_DIR="$STATE_DIR/plan"
rm -rf "$PLAN_DIR"; mkdir -p "$PLAN_DIR/out/tests" "$PLAN_DIR/cfg"

# Scoped LLM-wiki fragments (WIKI_ENABLED): the planner reads the wiki BEFORE exploring code,
# and makes each slice own its wiki/modules/ page so the worker keeps it fresh as part of DONE.
WIKI_READ=""; WIKI_RULE=""
if [ "${WIKI_ENABLED:-1}" = 1 ]; then
  WIKI_READ="- /repo/wiki/index.md if it exists — then open ONLY the module pages relevant to this
  goal. Prefer wiki pages over re-reading source; explore /repo only where the wiki is missing
  or insufficient.
"
  WIKI_RULE="   - Include \"wiki/modules/<slice-name>.md\" in each slice's paths — the worker owns and
     updates its module wiki page as part of the slice. NEVER assign wiki/index.md to anyone
     (the supervisor regenerates it by script on every land).
"
fi

# Snapshot of the current code for the planner to read (canonical mounted read-only).
prompt="$(cat <<EOF
You are the PLANNER for an autonomous parallel-development loop. You decompose ONE goal into
independent vertical slices that separate worker agents will implement in parallel.

GOAL TO DECOMPOSE:
$GOAL

Read these first:
- /skills/VISION.md, /skills/ARCHITECTURE.md, /skills/RULES.md  (project intent, structure, rules)
- /memory/REPO_MAP.md  (auto-generated directory map with file counts — trust it and only
  explore /repo where the map is not enough)
${WIKI_READ}- /memory/PROGRESS.md  (what already landed / failed — do NOT re-plan finished work)
- the codebase under /repo (READ-ONLY)

Then produce, under /out:

1) /out/slices.json — a JSON array of AT MOST ${PLANNER_MAX_SLICES} slices. Each slice:
   { "name": "kebab-case-id",
     "paths": ["src/featureX/", "docs/featureX/"],   // path PREFIXES this slice exclusively owns
     "brief": "Imperative spec: what to build so the contract test passes. Be concrete.",
     "tests": ["tests/featureX.spec.ts"] }           // the contract test file(s) YOU wrote for
                                                     // this slice (repo paths, i.e. tests/...)
   HARD RULES for slices:
   - Paths MUST be DISJOINT across slices (no two slices share a prefix) — this prevents merge
     conflicts. Vertical slices (own a directory), never horizontal (e.g. "all tests").
   - Never assign anything under: $PROTECTED_PATHS (tests are supervisor-owned).
${WIKI_RULE}   - Fewer, cleanly-separated slices beat many overlapping ones. 1 slice is fine.

2) /out/tests/... — thin ACCEPTANCE/contract tests (one per slice) that encode "done" for each
   slice. Mirror the project's existing test layout and framework (infer from /repo and
   ARCHITECTURE.md). These become the gate the workers must pass. Keep them small and sharp:
   they are the spec, not an exhaustive suite. Reference each slice by name in a comment.

Write ONLY those files under /out. Do not modify /repo. When done, stop.
EOF
)"

echo "plan: decomposing goal via headless planner (isolated container)…"
echo "  goal: $GOAL"

# Empty config dir over /home/dev/.claude => planner runs WITHOUT the worker guard hooks (it is
# the supervisor role and must be able to author tests/). All instructions come via the prompt,
# passed as an env var (-e) so quoting/newlines survive. Claude reads it from $PLAN_PROMPT.
mapfile -t CRED < <(cred_docker_args)   # subscription OAuth token OR metered API key (never both)
set +e
# --entrypoint bash overrides the image's `sleep infinity` keepalive entrypoint (see gate.sh).
# `timeout` guards against a hung planner Claude (observed hanging for many hours), which would
# otherwise block plan.sh -> loop.sh forever. On timeout the container is killed; with no
# slices.json the loop reports PLAN_FAIL and moves on. Tune via PLAN_TIMEOUT (seconds).
PLAN_TIMEOUT="${PLAN_TIMEOUT:-900}"
# --output-format json: stdout becomes ONE result object (final text + token usage + cost),
# captured to a file for usage accounting; stderr still streams through the [planner] prefix.
# (`2>&1 >file` sends stderr to the sed pipe and stdout to the file — order is deliberate.)
RESULT_JSON="$PLAN_DIR/planner-result.json"
timeout --kill-after=30 "$PLAN_TIMEOUT" \
docker run --rm \
  --entrypoint bash \
  "${CRED[@]}" \
  -e DISABLE_AUTOUPDATER=1 \
  -e PLAN_PROMPT="$prompt" \
  -v "$CANONICAL":/repo:ro \
  -v "$SKILLS_DIR":/skills:ro \
  -v "$MEMORY_DIR":/memory:ro \
  -v "$PLAN_DIR/out":/out \
  -v "$PLAN_DIR/cfg":/home/dev/.claude \
  -w /out \
  "$IMAGE" -lc 'claude -p "$PLAN_PROMPT" --output-format json --dangerously-skip-permissions' 2>&1 \
  > "$RESULT_JSON" \
  | sed 's/^/  [planner] /'
prc=${PIPESTATUS[0]}
set -e

[ "$prc" -eq 0 ] || echo "plan: planner exited $prc (continuing to validate any output)."

# Show the planner's final message and log its token bill to PROGRESS.md (PLAN_USAGE), so the
# cost of every DISCOVER/PLAN pass is measurable — tune WIKI_ENABLED / prompts against DATA.
if [ -s "$RESULT_JSON" ]; then
  jq -r '.result // empty' "$RESULT_JSON" 2>/dev/null | sed 's/^/  [planner] /' || true
  usage="$(plan_usage_note "$RESULT_JSON")"
  if [ -n "$usage" ]; then
    echo "plan: planner usage — $usage"
    progress_log PLAN_USAGE "-" "-" "goal: $GOAL | $usage"
  fi
fi

slices="$PLAN_DIR/out/slices.json"
[ -f "$slices" ] || die "planner produced no slices.json — inspect $PLAN_DIR/out and the planner log above."
# Deterministic plan validation (schema + disjoint paths + protected-path claims): catch a bad
# plan HERE, before workers burn tokens on slices that can only end in gate exit 3/4.
validate_slices "$slices" \
  || die "slices.json failed validation (see reasons above): $slices"

# Commit the planner's contract tests into canonical tests/ on BASE_BRANCH so the gate enforces
# them. Only files under /out/tests are taken (supervisor owns tests/; nothing else is trusted).
if [ -n "$(ls -A "$PLAN_DIR/out/tests" 2>/dev/null)" ]; then
  mkdir -p "$CANONICAL/tests"
  cp -r "$PLAN_DIR/out/tests/." "$CANONICAL/tests/"
  git -C "$CANONICAL" add tests/
  if ! git -C "$CANONICAL" diff --cached --quiet; then
    git -C "$CANONICAL" commit -q -m "contract tests for goal: $GOAL" \
      && echo "plan: committed contract tests to $BASE_BRANCH (canonical)."
    # Propagate the new base (with tests) into existing exchanges so workers fork from it.
    shopt -s nullglob
    for f in "$STATE_DIR"/*.env; do
      ( source "$f"; git -C "$EXCHANGE" fetch -q "$CANONICAL" "refs/heads/$BASE_BRANCH:refs/heads/$BASE_BRANCH" 2>/dev/null || true )
    done
  fi
fi

n="$(jq 'length' "$slices")"
echo "plan: $n slice(s) ready -> $slices"
progress_log PLANNED "-" "-" "goal: $GOAL ($n slices)"
echo "$slices"
