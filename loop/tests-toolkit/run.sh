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
done < <(find "$CTL" -type f \( -name '*.sh' -o -name 'harness-*' -o -name 'worker-prepare' -o -name 'pre-receive' -o -name 'post-receive' \) )

# --- 2. lint ---
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -S warning "$CTL"/*.sh "$CTL"/worker-harness/harness-* "$CTL"/host-harness/harness-* \
       "$CTL"/hooks/* "$CTL"/worker-prepare >/tmp/sc.out 2>&1; then ok "shellcheck clean (>=warning)";
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

echo
echo "tests-toolkit: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
