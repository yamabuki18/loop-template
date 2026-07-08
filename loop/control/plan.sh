#!/usr/bin/env bash
# DISCOVER/PLAN — decompose ONE backlog goal into vertical slices + thin contract tests, using a
# HEADLESS, throwaway Claude run (the "planner"). The planner works in a detached, disposable
# worktree of canonical (discarded afterwards; only /out artifacts are consumed) with a CLEAN
# per-run CLAUDE_CONFIG_DIR — no worker guard hooks, because the planner is the supervisor role
# and MAY author tests/ (workers may not). Its credential comes from secret_exec (worker scope)
# and enters only the claude process.
#
# Output (consumed by loop.sh):
#   state/plan/out/slices.json -> [{ "name": "...", "paths": ["src/x/"], "brief": "..." }, ...]
# Side effect:
#   contract tests the planner wrote are committed into canonical's tests/ on BASE_BRANCH, so the
#   acceptance gate enforces them for every slice.
#
#   ./control/plan.sh "<the goal text>"
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GOAL="${1:?usage: plan.sh \"<goal text>\"}"
have_credential || die "no credential: run 'claude setup-token' then 'loop secrets edit worker' (or log in to claude on this host)."
[ -d "$CANONICAL/.git" ] || die "canonical not found — run ./control/setup.sh first."
command -v claude >/dev/null 2>&1 || die "claude CLI not found on the host."

PLAN_DIR="$STATE_DIR/plan"
# The planner repo is a git worktree — remove it via git before recreating the dir.
git -C "$CANONICAL" worktree remove --force "$PLAN_DIR/repo" 2>/dev/null || true
rm -rf "$PLAN_DIR"; mkdir -p "$PLAN_DIR/out/tests" "$PLAN_DIR/cfg"
cleanup() {
  git -C "$CANONICAL" worktree remove --force "$PLAN_DIR/repo" 2>/dev/null || true
  git -C "$CANONICAL" worktree prune 2>/dev/null || true
}
trap cleanup EXIT
git -C "$CANONICAL" worktree add --detach "$PLAN_DIR/repo" "$BASE_BRANCH" >/dev/null

# Clean planner config: onboarding pre-seeded, NO hooks (supervisor role). Host-login
# convenience mirrors spawn.sh when no worker-scope secret exists.
sed "s|__WORKTREE__|$PLAN_DIR/repo|g" "$CONTROL_DIR/worker-claude.template.json" > "$PLAN_DIR/cfg/.claude.json"
if ! secret_present worker && [ -f "$HOME/.claude/.credentials.json" ]; then
  cp "$HOME/.claude/.credentials.json" "$PLAN_DIR/cfg/.credentials.json"
  chmod 600 "$PLAN_DIR/cfg/.credentials.json" 2>/dev/null || true
fi

# Scoped LLM-wiki fragments (WIKI_ENABLED): the planner reads the wiki BEFORE exploring code,
# and makes each slice own its wiki/modules/ page so the worker keeps it fresh as part of DONE.
WIKI_READ=""; WIKI_RULE=""
if [ "${WIKI_ENABLED:-1}" = 1 ]; then
  WIKI_READ="- $PLAN_DIR/repo/wiki/index.md if it exists — then open ONLY the module pages relevant to
  this goal. Prefer wiki pages over re-reading source; explore the repo only where the wiki is
  missing or insufficient.
"
  WIKI_RULE="   - Include \"wiki/modules/<slice-name>.md\" in each slice's paths — the worker owns and
     updates its module wiki page as part of the slice. NEVER assign wiki/index.md to anyone
     (the supervisor regenerates it by script on every land).
"
fi

prompt="$(cat <<EOF
You are the PLANNER for an autonomous parallel-development loop. You decompose ONE goal into
independent vertical slices that separate worker agents will implement in parallel.

GOAL TO DECOMPOSE:
$GOAL

Read these first:
- $SKILLS_DIR/VISION.md, $SKILLS_DIR/ARCHITECTURE.md, $SKILLS_DIR/RULES.md  (project intent, structure, rules)
- $MEMORY_DIR/REPO_MAP.md  (auto-generated directory map with file counts — trust it and only
  explore the repo where the map is not enough)
${WIKI_READ}- $MEMORY_DIR/PROGRESS.md  (what already landed / failed — do NOT re-plan finished work)
- the codebase in your working directory ($PLAN_DIR/repo) — treat it as READ-ONLY

Then produce, under $PLAN_DIR/out:

1) $PLAN_DIR/out/slices.json — a JSON array of AT MOST ${PLANNER_MAX_SLICES} slices. Each slice:
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

2) $PLAN_DIR/out/tests/... — thin ACCEPTANCE/contract tests (one per slice) that encode "done"
   for each slice. Mirror the project's existing test layout and framework (infer from the repo
   and ARCHITECTURE.md). These become the gate the workers must pass. Keep them small and sharp:
   they are the spec, not an exhaustive suite. Reference each slice by name in a comment.

Write ONLY under $PLAN_DIR/out. Do not modify the repo. When done, stop.
EOF
)"

echo "plan: decomposing goal via headless planner (disposable worktree)…"
echo "  goal: $GOAL"

set +e
# `timeout` guards against a hung planner Claude (observed hanging for many hours), which would
# otherwise block plan.sh -> loop.sh forever. On timeout the planner is killed; with no
# slices.json the loop reports PLAN_FAIL and moves on. Tune via PLAN_TIMEOUT (seconds).
PLAN_TIMEOUT="${PLAN_TIMEOUT:-900}"
# --output-format json: stdout becomes ONE result object (final text + token usage + cost),
# captured to a file for usage accounting; stderr still streams through the [planner] prefix.
# (`2>&1 >file` sends stderr to the sed pipe and stdout to the file — order is deliberate.)
RESULT_JSON="$PLAN_DIR/planner-result.json"
# Model routing: the planner authors the decomposition AND the contract tests — quality here
# multiplies across every worker, so PLANNER_MODEL may point at a stronger model than workers.
planner_model_args=()
[ -n "${PLANNER_MODEL:-}" ] && planner_model_args=(--model "$PLANNER_MODEL")
( cd "$PLAN_DIR/repo" && \
  secret_exec worker -- timeout --kill-after=30 "$PLAN_TIMEOUT" \
    env CLAUDE_CONFIG_DIR="$PLAN_DIR/cfg" DISABLE_AUTOUPDATER=1 \
    claude -p "$prompt" --output-format json --dangerously-skip-permissions \
    ${planner_model_args[@]+"${planner_model_args[@]}"} \
) 2>&1 > "$RESULT_JSON" | sed 's/^/  [planner] /'
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

# Independent second opinion on the PLAN (codex; artifacts only — it never sees the planner's
# reasoning). advise: concerns are folded into each slice's brief so the WORKER sees them.
# block: concerns abort the plan like a validation failure. skip (codex absent/timeout) is
# silent — second-opinion.sh already logged CODEX_SKIP.
so_mode="${SECOND_OPINION_PLAN:-${SECOND_OPINION:-advise}}"
if [ "$so_mode" != off ] && [ -x "$CONTROL_DIR/second-opinion.sh" ]; then
  verdict="$PLAN_DIR/codex-verdict.json"
  if "$CONTROL_DIR/second-opinion.sh" plan --slices "$slices" --goal "$GOAL" --out "$verdict"; then
    if jq -e '.verdict=="concerns"' "$verdict" >/dev/null 2>&1; then
      progress_log CODEX_PLAN "-" "-" "goal: $GOAL | $(jq -c '[.issues[]? | {slice, severity}]' "$verdict" 2>/dev/null | head -c 300)"
      if [ "$so_mode" = block ]; then
        jq -r '.issues[]? | "  [\(.severity)] \(.slice // "-"): \(.note)"' "$verdict" 2>/dev/null >&2 || true
        die "second opinion: blocking concerns on the plan — $verdict"
      fi
      if jq --slurpfile v "$verdict" 'map(.name as $n | .brief +=
           ([$v[0].issues[]? | select(.slice==$n) | "- [" + .severity + "] " + .note]
            | if length>0 then "\n\nSecond opinion notes (independent codex review, advisory — weigh them, they may be wrong):\n" + join("\n") else "" end))' \
           "$slices" > "$slices.tmp" 2>/dev/null; then
        mv "$slices.tmp" "$slices"
        echo "plan: second-opinion notes folded into slice briefs."
      else
        rm -f "$slices.tmp"
      fi
    fi
  fi
fi

# Commit the planner's contract tests into canonical tests/ on BASE_BRANCH so the gate enforces
# them. Only files under /out/tests are taken (supervisor owns tests/; nothing else is trusted).
# Workers see the new base instantly (shared refs) — sync.sh rebases the live ones.
if [ -n "$(ls -A "$PLAN_DIR/out/tests" 2>/dev/null)" ]; then
  mkdir -p "$CANONICAL/tests"
  cp -r "$PLAN_DIR/out/tests/." "$CANONICAL/tests/"
  git -C "$CANONICAL" add tests/
  if ! git -C "$CANONICAL" diff --cached --quiet; then
    git -C "$CANONICAL" commit -q -m "contract tests for goal: $GOAL" \
      && echo "plan: committed contract tests to $BASE_BRANCH (canonical)."
  fi
fi

n="$(jq 'length' "$slices")"
echo "plan: $n slice(s) ready -> $slices"
progress_log PLANNED "-" "-" "goal: $GOAL ($n slices)"
echo "$slices"
