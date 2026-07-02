#!/usr/bin/env bash
# Safety net for the toolkit itself (D7). Pure, Docker-free checks:
#   1. bash -n on every script        (syntax)
#   2. shellcheck if installed         (lint; skipped with a note otherwise)
#   3. deterministic hook unit tests   (stdin JSON / file state -> exit code, the hooks' contract)
# Run from anywhere:  ./tests-toolkit/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$(cd "$HERE/../control" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko()   { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# --- 1. syntax ---
echo "== bash -n =="
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "syntax $(basename "$f")"; else ko "syntax $f"; fi
done < <(find "$CTL" -type f \( -name '*.sh' -o -name 'harness-*' -o -name 'worker-prepare' -o -name 'pre-receive' -o -name 'post-receive' \) ; ls "$CTL/../bin/loop" 2>/dev/null)

# --- 2. lint ---
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # SC1090 excluded: the toolkit's state files (state/<task>.env) and config are sourced via
  # variables BY DESIGN; shellcheck cannot follow them and the warning is pure noise here.
  if shellcheck -x -S warning -e SC1090 "$CTL"/*.sh "$CTL"/worker-harness/harness-* "$CTL"/host-harness/harness-* \
       "$CTL"/hooks/* "$CTL"/worker-prepare "$CTL/../bin/loop" >/tmp/sc.out 2>&1; then ok "shellcheck clean (>=warning, SC1090 excluded)";
  else ko "shellcheck reported issues:"; sed 's/^/    /' /tmp/sc.out | head -40; fi
else
  printf '  \033[33mSKIP\033[0m shellcheck not installed\n'
fi

# --- helper: run a hook with JSON on stdin, assert exit code ---
GUARD_GIT="$CTL/worker-harness/harness-guard-git"
GUARD_PATHS="$CTL/worker-harness/harness-guard-paths"
SESS="$CTL/worker-harness/harness-session-start"
STOP="$CTL/worker-harness/harness-stop-gate"

expect_bash() { # <desc> <expected-exit> <command-string>
  local desc="$1" exp="$2" cmd="$3" rc
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" | bash "$GUARD_GIT" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "guard-git $desc (exit $rc)" || ko "guard-git $desc: expected $exp got $rc"
}

echo "== guard-git =="
expect_bash "block merge"             2 "git merge origin/main"
expect_bash "block rebase"            2 "git rebase origin/main"
expect_bash "block cherry-pick"       2 "git cherry-pick abc123"
expect_bash "block pull (D6)"         2 "git pull origin main"
expect_bash "block reset --hard"      2 "git reset --hard HEAD~1"
expect_bash "block push main"         2 "git push origin main"
expect_bash "block force-push"        2 "git push --force origin HEAD"
expect_bash "allow push HEAD"         0 "git push origin HEAD"
expect_bash "allow fetch"             0 "git fetch origin"
expect_bash "allow push work/main-page (no false +)" 0 "git push origin work/main-page"
expect_bash "allow normal build"      0 "npm test"

echo "== guard-paths =="
gp() { # <desc> <expected> <json>
  local desc="$1" exp="$2" json="$3" rc
  printf '%s' "$json" | bash "$GUARD_PATHS" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "guard-paths $desc (exit $rc)" || ko "guard-paths $desc: expected $exp got $rc"
}
export PROTECTED_PATHS="tests/"
owned="$(mktemp)"; printf 'src/featureA/\n' > "$owned"; export HARNESS_OWNED_PATHS="$owned"
gp "block protected tests/"          2 '{"tool_name":"Edit","tool_input":{"file_path":"/work/tests/x.spec.ts"}}'
gp "block protected via ./ (norm)"   2 '{"tool_name":"Edit","tool_input":{"file_path":"/work/./tests/x.spec.ts"}}'
gp "block notebook in tests/ (D10)"  2 '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/work/tests/x.ipynb"}}'
gp "allow owned src/featureA"        0 '{"tool_name":"Edit","tool_input":{"file_path":"/work/src/featureA/m.ts"}}'
gp "block outside owned domain"      2 '{"tool_name":"Edit","tool_input":{"file_path":"/work/src/featureB/m.ts"}}'
gp "allow STATUS"                    0 '{"tool_name":"Write","tool_input":{"file_path":"/work/STATUS"}}'
gp "allow .harness/*"                0 '{"tool_name":"Write","tool_input":{"file_path":"/work/.harness/notes"}}'

echo "== gate protected-path logic (D5, Docker-free) =="
# Reproduce the merge-base comparison gate.sh runs in-container, on a local temp repo.
tmp="$(mktemp -d)"; ( set -e; cd "$tmp"
  git init -q -b main; git config user.email a@b; git config user.name a
  mkdir -p tests src; echo base > src/app.txt; echo "t" > tests/contract.txt
  git add -A; git commit -qm base
  git checkout -q -b work/w1
  echo feature > src/app.txt; git commit -qam work          # touches only src -> OK
  base="$(git merge-base main work/w1)"
  [ -z "$(git diff --name-only "$base" work/w1 -- tests/)" ] || exit 11
  echo tamper > tests/contract.txt; git commit -qam tamper  # now touches tests/ -> violation
  base="$(git merge-base main work/w1)"
  [ -n "$(git diff --name-only "$base" work/w1 -- tests/)" ] || exit 12
)
case $? in
  0) ok "gate merge-base detects tests/ tampering (clean=OK, tampered=blocked)";;
  11) ko "gate logic: clean branch wrongly flagged";;
  12) ko "gate logic: tampered branch not detected";;
  *) ko "gate logic: unexpected error";;
esac
rm -rf "$tmp"

echo "== stop-gate feedback delivery (A2) =="
tmp="$(mktemp -d)"; ( set -e; cd "$tmp"
  git init -q -b main; git config user.email a@b; git config user.name a
  mkdir -p .harness; echo x>f; git add -A; git commit -qm c1
)
export HARNESS_WORKDIR="$tmp"
# feedback newer than last commit -> must force continue (exit 2)
sleep 1; touch "$tmp/.harness/feedback.md"
bash "$STOP" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "stop-gate: fresh feedback forces re-engage (exit 2)" || ko "stop-gate: expected 2 got $rc"
# after a newer commit, feedback is considered addressed -> allow stop (exit 0)
( cd "$tmp"; git commit -q --allow-empty -m fix )
bash "$STOP" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "stop-gate: addressed feedback allows stop (exit 0)" || ko "stop-gate: expected 0 got $rc"
unset HARNESS_WORKDIR
rm -rf "$tmp"

echo "== session-start injection (A2) =="
hd="$(mktemp -d)"; printf '# Task\nbuild X\n' > "$hd/task.md"
out="$(HARNESS_DIR="$hd" bash "$SESS" </dev/null 2>/dev/null)"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("build X")' >/dev/null 2>&1; then
  ok "session-start injects task.md into additionalContext"
else ko "session-start: task not injected ($out)"; fi
rm -rf "$hd"

echo "== lib: validate_slices (deterministic plan validation) =="
ws="$(mktemp -d)"
vs() { # <desc> <expected-exit> <slices-json>
  local desc="$1" exp="$2" json="$3" rc
  printf '%s' "$json" > "$ws/slices.json"
  ( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; validate_slices "$ws/slices.json" ) >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "validate_slices $desc (exit $rc)" || ko "validate_slices $desc: expected $exp got $rc"
}
vs "valid disjoint slices"     0 '[{"name":"a","paths":["src/a/"],"brief":"x","tests":["tests/a.spec.ts"]},{"name":"b","paths":["src/b/"],"brief":"y"}]'
vs "overlapping paths"         1 '[{"name":"a","paths":["src/"],"brief":"x"},{"name":"b","paths":["src/b/"],"brief":"y"}]'
vs "claims protected tests/"   1 '[{"name":"a","paths":["tests/unit/"],"brief":"x"}]'
vs "schema: empty paths"       1 '[{"name":"a","paths":[],"brief":"x"}]'
vs "schema: missing brief"     1 '[{"name":"a","paths":["src/a/"]}]'
vs "schema: non-string tests"  1 '[{"name":"a","paths":["src/a/"],"brief":"x","tests":[1]}]'

echo "== lib: progress_compact (bounded PROGRESS.md) =="
if ( export LOOP_PROJECT="$ws" PROGRESS_MAX_LINES=50 PROGRESS_KEEP_LINES=10
     source "$CTL/lib.sh"
     mkdir -p "$MEMORY_DIR"; printf '# PROGRESS\n\n## Log\n' > "$MEMORY_DIR/PROGRESS.md"
     for i in $(seq 1 40); do printf '2026-01-01T00:00:00Z\tLANDED\tw1\t-\ts%d\n' "$i" >> "$MEMORY_DIR/PROGRESS.md"; done
     printf '2026-01-01T00:00:00Z\tESCALATED\tw1\t-\tstuck-early\n' >> "$MEMORY_DIR/PROGRESS.md"
     for i in $(seq 41 80); do printf '2026-01-01T00:00:00Z\tLANDED\tw1\t-\ts%d\n' "$i" >> "$MEMORY_DIR/PROGRESS.md"; done
     progress_log LANDED w1 - trigger
     lines="$(wc -l < "$MEMORY_DIR/PROGRESS.md")"
     [ "$lines" -lt 30 ] && grep -q 'stuck-early' "$MEMORY_DIR/PROGRESS.md" \
       && grep -q '\[compacted' "$MEMORY_DIR/PROGRESS.md" && grep -q 'trigger' "$MEMORY_DIR/PROGRESS.md"
   ) >/dev/null 2>&1; then
  ok "progress_compact folds old events, keeps ESCALATED + recent tail"
else
  ko "progress_compact: fold/keep behavior wrong"
fi
echo "== lib: plan_usage_note (claude -p JSON accounting) =="
cat > "$ws/result.json" <<'EOF'
{"type":"result","subtype":"success","num_turns":7,"total_cost_usd":0.42,
 "usage":{"input_tokens":1200,"output_tokens":345,"cache_read_input_tokens":9000,"cache_creation_input_tokens":800},
 "result":"done"}
EOF
note="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; plan_usage_note "$ws/result.json") 2>/dev/null )"
if [ "$note" = "in=1200 out=345 cache_read=9000 cache_write=800 turns=7 cost_usd=0.42" ]; then
  ok "plan_usage_note extracts usage fields"
else ko "plan_usage_note: got '$note'"; fi
echo 'not json' > "$ws/result.json"
note="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; plan_usage_note "$ws/result.json") 2>/dev/null )"
[ -z "$note" ] && ok "plan_usage_note silent on garbage input" || ko "plan_usage_note: expected empty, got '$note'"

echo "== lib: wiki_index_refresh (scripted index from frontmatter) =="
mkdir -p "$ws/canonical/wiki/modules" "$ws/canonical/wiki/concepts"
cat > "$ws/canonical/wiki/modules/auth.md" <<'EOF'
---
title: Auth module
type: module
sources:
  - src/auth/
updated: 2026-07-02
---
body
EOF
cat > "$ws/canonical/wiki/concepts/tokens.md" <<'EOF'
---
title: Token efficiency
type: concept
sources:
  - raw/notes.md
  - raw/paper.pdf
---
body
EOF
if ( export LOOP_PROJECT="$ws"
     source "$CTL/lib.sh"
     wiki_index_refresh
     idx="$CANONICAL/wiki/index.md"
     grep -q '\[Auth module\](modules/auth.md) — sources: src/auth/' "$idx" \
       && grep -q '\[Token efficiency\](concepts/tokens.md) — sources: raw/notes.md, raw/paper.pdf' "$idx" \
       && grep -q '^## Modules' "$idx" && grep -q '^## Concepts' "$idx" \
       && ! grep -q '^## Entities' "$idx" \
       && grep -q 'AUTO-GENERATED' "$idx"
   ) >/dev/null 2>&1; then
  ok "wiki_index_refresh builds sectioned index with sources"
else
  ko "wiki_index_refresh: index content wrong"
fi
# WIKI_ENABLED=0 must be a no-op (existing index untouched).
if ( export LOOP_PROJECT="$ws" WIKI_ENABLED=0
     source "$CTL/lib.sh"
     echo sentinel > "$CANONICAL/wiki/index.md"
     wiki_index_refresh
     grep -q sentinel "$CANONICAL/wiki/index.md"
   ) >/dev/null 2>&1; then
  ok "wiki_index_refresh respects WIKI_ENABLED=0"
else ko "wiki_index_refresh ran despite WIKI_ENABLED=0"; fi
rm -rf "$ws"

echo "== zero-footprint daily-dev flow (here / resolve / publish / refresh) =="
zf="$(mktemp -d)"; proj="$zf/proj"
export LOOP_HOME="$zf/loophome"
mkdir -p "$proj"
( cd "$proj" && git init -qb main . && git config user.email a@b && git config user.name a \
  && echo hello > app.txt && git add -A && git commit -qm A )

slug="$( (cd "$zf"; unset LOOP_PROJECT; source "$CTL/lib.sh"; path_slug "$proj") 2>/dev/null )"
[ -n "$slug" ] && ok "path_slug: '$proj' -> '$slug'" || ko "path_slug: empty"

( cd "$proj" && bash "$CTL/here.sh" ) >/dev/null 2>&1
wsc="$LOOP_HOME/workspaces/$slug"
if [ -f "$wsc/.loop-workspace" ] && grep -q "^PROJECT_PATH=$proj$" "$wsc/.loop-workspace"; then
  ok "here: central workspace created + bound to project"
else ko "here: workspace missing or unbound ($wsc)"; fi

r="$( cd "$proj" && bash -c "unset LOOP_PROJECT; source '$CTL/lib.sh'; echo \$ROOT" 2>/dev/null )"
[ "$r" = "$wsc" ] && ok "lib: project dir resolves to its central workspace" \
                  || ko "lib: resolution got '$r' (want $wsc)"

dirty="$( cd "$proj" && git status --porcelain )"
[ -z "$dirty" ] && ok "zero footprint: project repo has no new/changed files" \
                || ko "project polluted: $dirty"

# canonical = clone of the project (what setup.sh would create); loop lands commit B there.
git clone -q "$proj" "$wsc/canonical"
( cd "$wsc/canonical" && git config user.email l@l && git config user.name loop \
  && echo feature > f.txt && git add -A && git commit -qm B )
if ( export LOOP_PROJECT="$wsc"; bash "$CTL/publish.sh" ) >/dev/null 2>&1 \
   && [ "$(git -C "$proj" rev-parse -q --verify refs/heads/loop/main)" = "$(git -C "$wsc/canonical" rev-parse main)" ]; then
  ok "publish: landed work arrives in the project as loop/main"
else ko "publish: loop/main missing or wrong sha"; fi

# Human commits C in the project -> histories diverge -> refresh must REFUSE (publish-first).
( cd "$proj" && echo human > h.txt && git add -A && git commit -qm C )
if ( export LOOP_PROJECT="$wsc"; bash "$CTL/refresh.sh" ) >/dev/null 2>&1; then
  ko "refresh: must refuse when histories diverged"
else ok "refresh: refuses non-ff on divergence (publish-first enforced)"; fi

# Project merges the loop's branch; now refresh fast-forwards canonical cleanly.
( cd "$proj" && git merge -q --no-edit loop/main ) >/dev/null 2>&1
if ( export LOOP_PROJECT="$wsc"; bash "$CTL/refresh.sh" ) >/dev/null 2>&1 \
   && [ "$(git -C "$wsc/canonical" rev-parse main)" = "$(git -C "$proj" rev-parse main)" ]; then
  ok "refresh: canonical fast-forwarded to the project's main"
else ko "refresh: canonical did not reach project main"; fi
unset LOOP_HOME
rm -rf "$zf"

echo
echo "tests-toolkit: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
