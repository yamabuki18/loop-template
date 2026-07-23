#!/usr/bin/env bash
# Safety net for the toolkit itself (D7). Pure, herdr/network-free checks:
#   1. bash -n on every script        (syntax)
#   2. shellcheck if installed         (lint; skipped with a note otherwise)
#   3. deterministic hook unit tests   (stdin JSON / file state -> exit code, the hooks' contract)
#   4. lib helpers (secret_exec, codex_gate_policy, worker_head, validate_slices, ...)
#   5. second-opinion.sh against a fake codex shim
# Run from anywhere:  ./tests-toolkit/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$(cd "$HERE/../control" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko()   { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Keep every test hermetic: never talk to a real herdr server or real host secrets. A failing
# `herdr` shim shadows any real binary, so herdr_ok is deterministically false everywhere.
HERMETIC_BIN="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$HERMETIC_BIN/herdr"; chmod +x "$HERMETIC_BIN/herdr"
export PATH="$HERMETIC_BIN:$PATH"

# --- 1. syntax ---
echo "== bash -n =="
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "syntax $(basename "$f")"; else ko "syntax $f"; fi
done < <(find "$CTL" "$CTL/../packs" -type f \( -name '*.sh' -o -name 'harness-*' -o -name 'guard-*' \) 2>/dev/null; ls "$CTL/../bin/loop" 2>/dev/null)

# --- 2. lint ---
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # SC1090 excluded: the toolkit's state files (state/<task>.env) and config are sourced via
  # variables BY DESIGN; shellcheck cannot follow them and the warning is pure noise here.
  if shellcheck -x -S warning -e SC1090 "$CTL"/*.sh "$CTL"/worker-harness/harness-* \
       "$CTL"/host-harness/harness-* "$CTL/../bin/loop" \
       "$CTL"/../packs/*/guards/* "$CTL"/../packs/*/check.d/*.sh >/tmp/sc.out 2>&1; then ok "shellcheck clean (>=warning, SC1090 excluded)";
  else ko "shellcheck reported issues:"; sed 's/^/    /' /tmp/sc.out | head -40; fi
else
  printf '  \033[33mSKIP\033[0m shellcheck not installed\n'
fi

# --- helper: run a hook with JSON on stdin, assert exit code ---
GUARD_GIT="$CTL/worker-harness/harness-guard-git"
GUARD_PATHS="$CTL/worker-harness/harness-guard-paths"
GUARD_SECRETS="$CTL/worker-harness/harness-guard-secrets"
SESS="$CTL/worker-harness/harness-session-start"
STOP="$CTL/worker-harness/harness-stop-gate"

expect_bash() { # <hook> <desc> <expected-exit> <command-string>
  local hook="$1" desc="$2" exp="$3" cmd="$4" rc
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" | bash "$hook" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "$(basename "$hook") $desc (exit $rc)" || ko "$(basename "$hook") $desc: expected $exp got $rc"
}

echo "== guard-git =="
gg() { expect_bash "$GUARD_GIT" "$@"; }
gg "block merge"             2 "git merge origin/main"
gg "block rebase"            2 "git rebase origin/main"
gg "block cherry-pick"       2 "git cherry-pick abc123"
gg "block pull (D6)"         2 "git pull origin main"
gg "block reset --hard"      2 "git reset --hard HEAD~1"
gg "block push main"         2 "git push origin main"
gg "block push HEAD (v3: ALL pushes)"      2 "git push origin HEAD"
gg "block push work branch (v3)"           2 "git push origin work/main-page"
gg "block force-push"        2 "git push --force origin HEAD"
gg "block worktree surgery"  2 "git worktree remove ../w2"
gg "block update-ref"        2 "git update-ref refs/heads/main abc123"
gg "block gc (shared objects)" 2 "git gc --aggressive"
gg "block branch force-move" 2 "git branch -f main HEAD"
gg "block branch delete"     2 "git branch -D main"
gg "block config write"      2 "git config user.name evil"
gg "block config --global"   2 "git config --global user.name evil"
gg "allow config read"       0 "git config --get user.name"
gg "allow config list"       0 "git config --list"
gg "allow branch list"       0 "git branch"
gg "allow fetch"             0 "git fetch origin"
gg "allow commit"            0 "git commit -m 'done'"
gg "allow normal build"      0 "npm test"
# global-option / env-prefix evasions of the plain `git <verb>` form (D12 speed-bump).
gg "block push via git -C"       2 "git -C /path/to/repo push origin main"
gg "block push via -c cfg"       2 "git -c protocol.version=2 push origin HEAD"
gg "block push via --git-dir"    2 "git --git-dir=/r/.git push origin main"
gg "block push via GIT_DIR env"  2 "GIT_DIR=/r/.git git push origin main"
gg "block merge via git -C"      2 "git -C . merge origin/main"
gg "block config write via -C"   2 "git -C /r config user.name evil"
gg "allow git -C status"         0 "git -C /r status"
gg "allow git -c pager log"      0 "git -c core.pager=cat log --oneline"
gg "allow config read via -C"    0 "git -C /r config --get user.name"

echo "== guard-paths =="
gpws="$(mktemp -d)"; mkdir -p "$gpws/wt" "$gpws/hd"
export HARNESS_WORKTREE="$gpws/wt" HARNESS_DIR="$gpws/hd"
gp() { # <desc> <expected> <json>
  local desc="$1" exp="$2" json="$3" rc
  printf '%s' "$json" | bash "$GUARD_PATHS" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "guard-paths $desc (exit $rc)" || ko "guard-paths $desc: expected $exp got $rc"
}
export PROTECTED_PATHS="tests/"
owned="$(mktemp)"; printf 'src/featureA/\n' > "$owned"; export HARNESS_OWNED_PATHS="$owned"
gp "block protected tests/"          2 "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$gpws/wt/tests/x.spec.ts\"}}"
gp "block protected via ./ (norm)"   2 "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$gpws/wt/./tests/x.spec.ts\"}}"
gp "block notebook in tests/ (D10)"  2 "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$gpws/wt/tests/x.ipynb\"}}"
gp "allow owned src/featureA"        0 "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$gpws/wt/src/featureA/m.ts\"}}"
gp "allow owned via relative path"   0 '{"tool_name":"Edit","tool_input":{"file_path":"src/featureA/m.ts"}}'
gp "block outside owned domain"      2 "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$gpws/wt/src/featureB/m.ts\"}}"
gp "allow harness dir (STATUS)"      0 "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$gpws/hd/STATUS\"}}"
gp "block host path /etc"            2 '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}'
gp "block host path \$HOME"          2 "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$HOME/x.txt\"}}"
gp "block ../ worktree escape"       2 "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$gpws/wt/../escape.txt\"}}"
unset HARNESS_OWNED_PATHS

echo "== guard-secrets (v3 host-mode concealment, L2) =="
gs() { expect_bash "$GUARD_SECRETS" "$@"; }
gs "block sops invocation"        2 "sops -d secret.worker.sops.env"
gs "block age-keygen"             2 "age-keygen -y ~/.config/sops/age/keys.txt"
gs "block age key cat"            2 "cat ~/.config/sops/age/keys.txt"
gs "block secret file reference"  2 "grep TOKEN secret.gate.sops.env"
gs "block plaintext secret cat"   2 "cat secret.worker.env"
gs "block plaintext secret grep"  2 "grep TOKEN ../secret.codex.env"
gs "block bare env dump"          2 "env"
gs "block env pipe dump"          2 "env | grep KEY"
gs "block printenv"               2 "printenv"
gs "block bare set dump"          2 "set > /tmp/vars"
gs "block export -p"              2 "export -p"
gs "block /proc environ"          2 "cat /proc/self/environ"
gs "block credential var echo"    2 'echo "$ANTHROPIC_API_KEY"'
gs "block ~/.claude access"       2 "cat ~/.claude/.credentials.json"
gs "block ~/.codex access"        2 "cat ~/.codex/auth.json"
gs "block ~/.ssh access"          2 "cat ~/.ssh/id_ed25519"
gs "allow env VAR=x cmd"          0 "env FOO=1 npm test"
gs "allow set -e"                 0 "set -e; npm test"
gs "allow 'op' as mere argument"  0 "grep op src/file.ts"
gs "allow normal command"         0 "npm test"
gsp() { # file-path form
  local desc="$1" exp="$2" p="$3" rc
  printf '{"tool_name":"Read","tool_input":{"file_path":%s}}' "$(jq -Rn --arg c "$p" '$c')" | bash "$GUARD_SECRETS" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "guard-secrets(path) $desc (exit $rc)" || ko "guard-secrets(path) $desc: expected $exp got $rc"
}
gsp "block Read of sops env"     2 "/somewhere/secret.gate.sops.env"
gsp "block Read of plaintext secret" 2 "/somewhere/secret.worker.env"
gsp "block Read of age key"      2 "$HOME/.config/sops/age/keys.txt"
gsp "block Read of ssh key"      2 "$HOME/.ssh/id_rsa"
gsp "block Read of claude creds" 2 "$HOME/.claude/.credentials.json"
gsp "allow Read of project file" 0 "$gpws/wt/src/app.ts"
rm -rf "$gpws"; unset HARNESS_WORKTREE HARNESS_DIR

echo "== gate protected-path logic (D5) =="
# Reproduce the merge-base comparison gate.sh runs, on a local temp repo.
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

echo "== worktree structural guarantees (v3 signal + base protection) =="
tmp="$(mktemp -d)"
( set -e
  export LOOP_PROJECT="$tmp"
  mkdir -p "$tmp/canonical"
  git -C "$tmp/canonical" init -q -b main
  git -C "$tmp/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  source "$CTL/lib.sh"
  [ "$(worker_head w1)" = none ] || exit 21                       # no branch yet -> none
  git -C "$CANONICAL" worktree add -b work/w1 "$tmp/wt-w1" main >/dev/null 2>&1
  h1="$(worker_head w1)"; [ "$h1" != none ] || exit 22            # branch exists -> sha
  git -C "$tmp/wt-w1" -c user.email=w@l -c user.name=w commit -q --allow-empty -m c1
  h2="$(worker_head w1)"; [ "$h2" != "$h1" ] || exit 23           # commit in worktree -> ref moved
  # base is checked out in canonical -> a worker worktree CANNOT check it out (native git wall)
  if git -C "$tmp/wt-w1" checkout main >/dev/null 2>&1; then exit 24; fi
) >/dev/null 2>&1
case $? in
  0) ok "worker_head tracks none->sha->new-sha; base checkout structurally blocked";;
  21) ko "worker_head: expected none before branch";;
  22) ko "worker_head: branch not seen";;
  23) ko "worker_head: commit in worktree did not move the ref";;
  24) ko "structural: worker could check out the base branch";;
  *) ko "worktree structural test: unexpected error";;
esac

echo "== lib: slice_stats (per-slice telemetry) =="
tmp="$(mktemp -d)"
out="$( set -e
  export LOOP_PROJECT="$tmp"
  mkdir -p "$tmp/canonical"
  git -C "$tmp/canonical" init -q -b main
  git -C "$tmp/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  source "$CTL/lib.sh"
  git -C "$CANONICAL" worktree add -b work/w1 "$tmp/wt" main >/dev/null 2>&1
  printf 'a\nb\nc\n' > "$tmp/wt/f.txt"
  git -C "$tmp/wt" -c user.email=w@l -c user.name=w add -A
  git -C "$tmp/wt" -c user.email=w@l -c user.name=w commit -q -m c1
  slice_stats w1
)"
printf '%s' "$out" | grep -qE 'commits=1 \+3 -0 files=1' \
  && ok "slice_stats reports commits/+ins/-del/files ($out)" \
  || ko "slice_stats: wrong output ($out)"
out2="$( export LOOP_PROJECT="$tmp"; source "$CTL/lib.sh"; slice_stats nope )"
[ "$out2" = "commits=0" ] && ok "slice_stats: no branch -> commits=0" || ko "slice_stats: nope gave '$out2'"
rm -rf "$tmp"
rm -rf "$tmp"

echo "== stop-gate feedback delivery (A2) =="
tmp="$(mktemp -d)"; ( set -e; cd "$tmp"
  git init -q -b main; git config user.email a@b; git config user.name a
  # .harness/ is worker state, never committed (production keeps it OUT of the worktree
  # entirely); gitignore it so the porcelain-based clean check doesn't treat feedback.md as
  # uncommitted work.
  mkdir -p .harness; echo x>f; printf '.harness/\n' > .gitignore; git add -A; git commit -qm c1
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
# UNTRACKED files must also force the worker to commit (git diff alone would miss them, so the
# work would be silently lost). Tree is clean/committed above; add a new untracked file.
( cd "$tmp"; echo new > untracked_new.txt )
bash "$STOP" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "stop-gate: untracked file forces commit (exit 2)" || ko "stop-gate: untracked: expected 2 got $rc"
( cd "$tmp"; git add -A; git commit -qm addnew )
bash "$STOP" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "stop-gate: committed new file allows stop (exit 0)" || ko "stop-gate: post-commit: expected 0 got $rc"
# .gitignore'd files must NOT trip the gate (build artifacts are expected debris).
( cd "$tmp"; echo 'ignored.log' >> .gitignore; git add .gitignore; git commit -qm gitignore; echo junk > ignored.log )
bash "$STOP" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "stop-gate: gitignored file does not block stop (exit 0)" || ko "stop-gate: gitignored: expected 0 got $rc"
# absolute HARNESS_DIR variant (production shape: harness dir OUTSIDE the worktree)
hd2="$(mktemp -d)"; sleep 1; touch "$hd2/feedback.md"
HARNESS_DIR="$hd2" bash "$STOP" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "stop-gate: out-of-tree HARNESS_DIR feedback honored (exit 2)" || ko "stop-gate: out-of-tree feedback: expected 2 got $rc"
unset HARNESS_WORKDIR
rm -rf "$tmp" "$hd2"

echo "== session-start injection (A2) =="
hd="$(mktemp -d)"; printf '# Task\nbuild X\n' > "$hd/task.md"
out="$(HARNESS_DIR="$hd" bash "$SESS" </dev/null 2>/dev/null)"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("build X")' >/dev/null 2>&1; then
  ok "session-start injects task.md into additionalContext"
else ko "session-start: task not injected ($out)"; fi
out="$(bash "$SESS" </dev/null 2>/dev/null)"   # no HARNESS_DIR -> must stay silent
[ -z "$out" ] && ok "session-start silent without HARNESS_DIR" || ko "session-start: emitted without HARNESS_DIR"
rm -rf "$hd"

echo "== guard-worktree (built-in worktree tools stay supervisor-only) =="
GUARD_WT="$CTL/worker-harness/harness-guard-worktree"
for tool in EnterWorktree ExitWorktree WorktreeCreate; do
  printf '{"tool_name":"%s","tool_input":{}}' "$tool" | bash "$GUARD_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "guard-worktree blocks $tool (exit 2)" || ko "guard-worktree $tool: expected 2 got $rc"
done
grep -q 'EnterWorktree|ExitWorktree' "$CTL/worker-harness/settings.template.json" \
  && grep -q '"WorktreeCreate"' "$CTL/worker-harness/settings.template.json" \
  && ok "settings.template wires guard-worktree (PreToolUse matcher + WorktreeCreate)" \
  || ko "settings.template: guard-worktree not wired"

echo "== guard-write (Bash write-escape wall, L2 speed-bump) =="
GUARD_WRITE="$CTL/worker-harness/harness-guard-write"
gww="$(mktemp -d)"; mkdir -p "$gww/wt" "$gww/hd" "$gww/ccd"
gw() { # <desc> <expected> <command>
  local desc="$1" exp="$2" cmd="$3" rc
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
    | HARNESS_WORKTREE="$gww/wt" HARNESS_DIR="$gww/hd" CLAUDE_CONFIG_DIR="$gww/ccd" \
      bash "$GUARD_WRITE" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "guard-write $desc (exit $rc)" || ko "guard-write $desc: expected $exp got $rc"
}
gw "allow redirect inside worktree"   0 'echo x > out.txt'
gw "allow plain command"              0 'npm test'
gw "allow read from host"             0 'cat /etc/hosts'
gw "allow pipe redirect inside"       0 'grep foo src/a.ts > results.txt'
gw "allow tee inside worktree"        0 'echo hi | tee notes.log'
gw "allow write to HARNESS_DIR"       0 "echo status > $gww/hd/STATUS"
gw "allow fd-dup 2>&1"                0 'ls -la 2>&1'
gw "block redirect to host path"      2 'echo x > /etc/passwd'
gw "block write to config dir (self-disarm)" 2 'echo {} > $CLAUDE_CONFIG_DIR/settings.json'
gw "block tee to /tmp"                2 'cat data | tee /tmp/evil'
gw "block cp escaping worktree"       2 'cp secret.txt ../../other/x'
gw "block mv to host path"            2 'mv a.txt /home/somewhere/b.txt'
gw "block dd of= host path"           2 'dd if=/dev/zero of=/host/disk'
gw "block sed -i on ../ escape"       2 'sed -i s/a/b/ ../escape.txt'
gw "block append ../ escape"          2 'echo x >> ../../../outside.txt'
rm -rf "$gww"
grep -q 'harness-guard-write' "$CTL/worker-harness/settings.template.json" \
  && ok "settings.template wires guard-write on Bash" \
  || ko "settings.template: guard-write not wired"

echo "== guards fail CLOSED when jq / realpath are missing =="
# A jq-less (or realpath/python3-less) host must never silently DISARM the guards. Run each
# guard with a PATH that lacks the tool and assert it denies (exit 2) rather than allowing.
BASH_BIN="$(command -v bash)"
# jq absent -> every parsing guard denies.
for h in "$GUARD_GIT" "$GUARD_PATHS" "$GUARD_SECRETS"; do
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | PATH="" "$BASH_BIN" "$h" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "$(basename "$h") fails closed without jq (exit 2)" \
    || ko "$(basename "$h") without jq: expected 2 got $rc"
done
# jq present but realpath AND python3 absent -> the path-normalizing guards deny.
minbin="$(mktemp -d)"; ln -s "$(command -v jq)" "$minbin/jq" 2>/dev/null
for h in "$GUARD_PATHS" "$GUARD_SECRETS"; do
  printf '{"tool_name":"Edit","tool_input":{"file_path":"x"}}' | PATH="$minbin" "$BASH_BIN" "$h" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "$(basename "$h") fails closed without realpath/python3 (exit 2)" \
    || ko "$(basename "$h") without realpath/python3: expected 2 got $rc"
done
rm -rf "$minbin"

echo "== spawn seams: model routing + per-workspace harness extension (v3.1) =="
# Hermetic fixture: fake HOME (no real creds), workspace + canonical with one commit.
sx="$(mktemp -d)"
mkdir -p "$sx/ws" "$sx/home" "$sx/bin"
touch "$sx/ws/.loop-workspace"
git -C "$sx/ws" init -q -b main canonical 2>/dev/null || { mkdir -p "$sx/ws/canonical"; git -C "$sx/ws/canonical" init -q -b main; }
git -C "$sx/ws/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
# Workspace-side harness extension: one executable guard + one advisory overlay.
mkdir -p "$sx/ws/worker-harness.d"
printf '#!/bin/sh\nexit 0\n' > "$sx/ws/worker-harness.d/guard-project"; chmod +x "$sx/ws/worker-harness.d/guard-project"
printf 'PROJECT_LOCAL_RULE: never touch legacy/\n' > "$sx/ws/CLAUDE.worker.local.md"
if ( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"
     bash "$CTL/spawn.sh" w1 ) >/dev/null 2>&1; then
  ok "spawn.sh runs hermetically (no herdr, fake HOME)"
else ko "spawn.sh failed in hermetic fixture"; fi
scd="$sx/ws/state/workers/w1/claude"
jq -e '.hooks.PreToolUse[] | select(.hooks[]?.command | endswith("worker-harness.d/guard-project"))' \
   "$scd/settings.json" >/dev/null 2>&1 \
  && ok "spawn: worker-harness.d guard merged into settings.json" \
  || ko "spawn: project guard missing from settings.json"
grep -q 'PROJECT_LOCAL_RULE' "$scd/CLAUDE.md" 2>/dev/null \
  && ok "spawn: CLAUDE.worker.local.md appended to worker CLAUDE.md" \
  || ko "spawn: local overlay missing from worker CLAUDE.md"
jq -e '.hooks.PreToolUse[] | select(.matcher=="EnterWorktree|ExitWorktree")' "$scd/settings.json" >/dev/null 2>&1 \
  && ok "spawn: built-in worktree guard present in generated settings" \
  || ko "spawn: worktree guard matcher missing"
# Model routing: a fake `claude` captures its argv; worker-run must pass WORKER_MODEL through.
cat > "$sx/bin/claude" <<'SHIM'
#!/bin/sh
printf '%s\n' "$@" > "${FAKE_CLAUDE_CAPTURE:-/dev/null}"
exit 0
SHIM
chmod +x "$sx/bin/claude"
( export LOOP_PROJECT="$sx/ws" HOME="$sx/home" PATH="$sx/bin:$PATH" \
         WORKER_MODEL=test-sonnet FAKE_CLAUDE_CAPTURE="$sx/cap.txt"
  bash "$CTL/worker-run.sh" w1 </dev/null ) >/dev/null 2>&1 || true
if grep -qx -- '--model' "$sx/cap.txt" 2>/dev/null && grep -qx 'test-sonnet' "$sx/cap.txt" \
   && grep -qx -- '--dangerously-skip-permissions' "$sx/cap.txt"; then
  ok "worker-run: WORKER_MODEL routed as claude --model"
else ko "worker-run: model flag missing (argv: $(tr '\n' ' ' < "$sx/cap.txt" 2>/dev/null))"; fi
( export LOOP_PROJECT="$sx/ws" HOME="$sx/home" PATH="$sx/bin:$PATH" \
         WORKER_MODEL= FAKE_CLAUDE_CAPTURE="$sx/cap2.txt"
  bash "$CTL/worker-run.sh" w1 </dev/null ) >/dev/null 2>&1 || true
if ! grep -qx -- '--model' "$sx/cap2.txt" 2>/dev/null; then
  ok "worker-run: empty WORKER_MODEL keeps the CLI default (no --model)"
else ko "worker-run: --model passed despite empty WORKER_MODEL"; fi

echo "== supervise.sh (interactive supervision seam, --dry-run) =="
if out="$( export LOOP_PROJECT="$sx/ws" HOME="$sx/home" PATH="$sx/bin:$PATH" \
                  CLAUDE_CODE_OAUTH_TOKEN=dummy SUPERVISOR_MODEL=test-opus
           bash "$CTL/supervise.sh" --dry-run 2>&1 )"; then
  ok "supervise --dry-run exits 0"
else ko "supervise --dry-run failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
printf '%s' "$out" | grep -q -- '--model test-opus' \
  && ok "supervise: SUPERVISOR_MODEL routed as claude --model" \
  || ko "supervise: model flag missing from dry-run command"
svd="$sx/ws/state/supervisor/claude"
grep -q 'VERTICAL slices' "$svd/CLAUDE.md" 2>/dev/null && grep -q "Canonical repo : $sx/ws/canonical" "$svd/CLAUDE.md" \
  && ok "supervise: playbook + generated environment in supervisor CLAUDE.md" \
  || ko "supervise: supervisor CLAUDE.md incomplete"
jq -e '.hooks.PreToolUse[0].hooks[0].command | endswith("host-harness/harness-guard-secrets")' \
   "$svd/settings.json" >/dev/null 2>&1 \
  && ok "supervise: host-harness secrets guard wired by absolute path" \
  || ko "supervise: secrets guard missing from supervisor settings"
# Supervisor-only skills: deployed into the isolated config dir, and NOWHERE the loop's
# planner/worker could pick them up (design stays in the dialogue; artifacts flow via plans).
[ -f "$svd/skills/test-architecture-design/SKILL.md" ] \
  && ok "supervise: supervisor-skills synced into CLAUDE_CONFIG_DIR/skills" \
  || ko "supervise: test-architecture-design skill not deployed to $svd/skills"
grep -q 'テスト設計表を計画本文に含めて' "$svd/skills/test-architecture-design/SKILL.md" 2>/dev/null \
  && ok "supervise: skill carries the loop-mapping section (plan-capture handoff)" \
  || ko "supervise: loop-mapping section missing from deployed skill"
[ ! -e "$sx/ws/canonical/.claude/skills" ] && [ ! -e "$scd/skills/test-architecture-design" ] \
  && ok "supervise: skill NOT leaked into canonical repo or worker config (loop-separated)" \
  || ko "supervise: supervisor skill leaked outside the supervisor session"

echo "== plan-mode handoff (plan capture hook + handoff.sh) =="
PLANCAP="$CTL/host-harness/harness-plan-capture"
PLAN_JSON='{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Auth Plan\n1. add login\n2. add tests"}}'
out="$( printf '%s' "$PLAN_JSON" | LOOP_PROJECT="$sx/ws" HOME="$sx/home" bash "$PLANCAP" 2>/dev/null )"
if grep -q 'add login' "$sx/ws/memory/plans/latest.md" 2>/dev/null; then
  ok "plan-capture: approved plan persisted to memory/plans/latest.md"
else ko "plan-capture: latest.md missing or wrong"; fi
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("handoff.sh")' >/dev/null 2>&1 \
  && ok "plan-capture: steers the session to handoff (additionalContext)" \
  || ko "plan-capture: no handoff instruction in output"
out="$( printf '{"tool_name":"ExitPlanMode","tool_input":{}}' | LOOP_PROJECT="$sx/ws" HOME="$sx/home" bash "$PLANCAP" 2>/dev/null )"
[ -z "$out" ] && ok "plan-capture: silent without a plan payload" || ko "plan-capture: emitted without plan"
# Legacy-fallback protection: from a foreign cwd with NO workspace, the hook must do nothing —
# especially not write into the ENGINE's own memory/ (lib.sh would resolve there as fallback).
out="$( cd /tmp && printf '%s' "$PLAN_JSON" | env -u LOOP_PROJECT HOME="$sx/home" bash "$PLANCAP" 2>/dev/null )"
if [ -z "$out" ] && [ ! -e "$CTL/../memory/plans/latest.md" ]; then
  ok "plan-capture: refuses legacy-fallback resolution (engine memory untouched)"
else ko "plan-capture: acted outside a genuine workspace"; fi
# handoff.sh: archive + backlog entry from the captured plan.
if ( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"
     bash "$CTL/handoff.sh" "Add User Auth" --latest ) >/dev/null 2>&1; then
  ok "handoff.sh runs on the captured plan"
else ko "handoff.sh failed"; fi
grep -qE '^- \[ \] Add User Auth \(plan: memory/plans/[0-9TZ]+-add-user-auth\.md\)$' "$sx/ws/memory/backlog.md" 2>/dev/null \
  && ok "handoff: backlog goal references the archived plan" \
  || ko "handoff: backlog entry missing/wrong ($(tail -1 "$sx/ws/memory/backlog.md" 2>/dev/null))"
arch="$(ls "$sx/ws/memory/plans/"*-add-user-auth.md 2>/dev/null | head -1)"
[ -n "$arch" ] && grep -q 'add login' "$arch" \
  && ok "handoff: plan archived verbatim" || ko "handoff: archive missing or wrong"
grep -q $'\tHANDOFF\t' "$sx/ws/memory/PROGRESS.md" 2>/dev/null \
  && ok "handoff: HANDOFF event logged to PROGRESS" || ko "handoff: PROGRESS event missing"
printf 'stdin plan body\n' | ( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"
  bash "$CTL/handoff.sh" "From Stdin" --plan - ) >/dev/null 2>&1
arch2="$(ls "$sx/ws/memory/plans/"*-from-stdin.md 2>/dev/null | head -1)"
[ -n "$arch2" ] && grep -q 'stdin plan body' "$arch2" \
  && ok "handoff: --plan - reads the plan from stdin" || ko "handoff: stdin variant failed"
# Idempotence: a second handoff with the same open title must refuse, not duplicate the goal.
if ( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"
     bash "$CTL/handoff.sh" "Add User Auth" --latest ) >/dev/null 2>&1; then
  ko "handoff: duplicate open title was accepted"
else
  n="$(grep -c '^- \[ \] Add User Auth ' "$sx/ws/memory/backlog.md" 2>/dev/null || true)"
  [ "$n" = 1 ] && ok "handoff: duplicate open title refused (backlog still has 1 entry)" \
               || ko "handoff dedup: backlog has $n entries for the title"
fi
# ...but a completed goal may be re-queued (dedup only guards OPEN [ ]/[~] marks).
sed -i 's/^- \[ \] Add User Auth /- [x] Add User Auth /' "$sx/ws/memory/backlog.md"
if ( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"
     bash "$CTL/handoff.sh" "Add User Auth" --latest ) >/dev/null 2>&1; then
  ok "handoff: completed [x] title may be handed off again"
else ko "handoff: re-queue of a completed title refused"; fi
grep -q 'decompose THAT plan faithfully' "$CTL/plan.sh" \
  && ok "plan.sh: planner instructed to honor referenced plans (no re-planning)" \
  || ko "plan.sh: handoff instruction missing from the planner prompt"

echo "== scaffold.sh (legacy full-copy: re-run guard) =="
sct="$(mktemp -d)/proj"
if bash "$CTL/scaffold.sh" "$sct" >/dev/null 2>&1; then
  ok "scaffold: first run succeeds"
else ko "scaffold: first run failed"; fi
[ -e "$sct/control/lib.sh" ] && [ -f "$sct/memory/backlog.md" ] \
  && ok "scaffold: control/ + memory/ laid down" || ko "scaffold: layout incomplete"
if ls "$sct"/control/secret.*.env >/dev/null 2>&1; then
  ko "scaffold: plaintext secrets leaked into the new project"
else ok "scaffold: no plaintext secrets carried over"; fi
printf '# BACKLOG\n\n## Goals\n- [ ] precious user goal\n' > "$sct/memory/backlog.md"
if bash "$CTL/scaffold.sh" "$sct" >/dev/null 2>&1; then
  ko "scaffold: re-run onto an existing scaffold was accepted"
else ok "scaffold: re-run refused (not re-run-safe by design)"; fi
grep -q 'precious user goal' "$sct/memory/backlog.md" \
  && ok "scaffold: refused re-run left the user's backlog untouched" \
  || ko "scaffold: re-run clobbered the backlog"
[ ! -e "$sct/control/control" ] \
  && ok "scaffold: no nested control/control after refused re-run" \
  || ko "scaffold: nested control/control appeared"
rm -rf "$(dirname "$sct")"
jq -e '.hooks.PostToolUse[] | select(.matcher=="ExitPlanMode")' "$svd/settings.json" >/dev/null 2>&1 \
  && ok "supervise: plan-capture wired on ExitPlanMode" \
  || ko "supervise: plan-capture hook missing from supervisor settings"

echo "== heartbeat exclusivity (loop.sh vs watch.sh) =="
mkdir -p "$sx/ws/state"
echo $$ > "$sx/ws/state/loop.pid"   # this test process is alive -> watch must refuse
out="$( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"; bash "$CTL/watch.sh" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'already driving the gate' \
  && ok "watch.sh refuses while loop.pid is alive" \
  || ko "watch.sh did not refuse (rc=$rc)"
echo 99999999 > "$sx/ws/state/loop.pid"   # stale pid -> watch may start (kill after 2s)
out="$( export LOOP_PROJECT="$sx/ws" HOME="$sx/home"; timeout 2 bash "$CTL/watch.sh" 2>&1 )"; rc=$?
printf '%s' "$out" | grep -q 'commit-driven gate active' \
  && ok "watch.sh starts over a stale loop.pid" \
  || ko "watch.sh blocked by a stale pid (rc=$rc: $(printf '%s' "$out" | head -1))"
rm -f "$sx/ws/state/loop.pid"
echo $$ > "$sx/ws/state/watch.pid"   # symmetric direction: live watch.pid -> loop.sh refuses
out="$( export LOOP_PROJECT="$sx/ws" HOME="$sx/home" CLAUDE_CODE_OAUTH_TOKEN=dummy
        timeout 5 bash "$CTL/loop.sh" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && printf '%s' "$out" | grep -q 'already driving the gate' \
  && ok "loop.sh refuses while watch.pid is alive" \
  || ko "loop.sh did not refuse (rc=$rc)"
rm -rf "$sx"

echo "== lib: secret_exec (scoped plaintext injection) =="
ws="$(mktemp -d)"; touch "$ws/.loop-workspace"
bin="$(mktemp -d)"   # shim dir; later sections (fake codex) install binaries here
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok123\nANTHROPIC_API_KEY=key456\n' > "$ws/secret.worker.env"
outv="$( (export LOOP_PROJECT="$ws"
          source "$CTL/lib.sh"
          secret_exec worker -- sh -c 'echo "${ANTHROPIC_API_KEY:-EMPTY}:${CLAUDE_CODE_OAUTH_TOKEN:-EMPTY}"') 2>/dev/null )"
if [ "$outv" = "EMPTY:tok123" ]; then
  ok "secret_exec worker: OAuth precedence strips ANTHROPIC_API_KEY in the child env"
else ko "secret_exec precedence: got '$outv' (want EMPTY:tok123)"; fi
# scope isolation: the values must exist ONLY in the child, never in the sourcing shell
outv="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"
          secret_exec worker -- true
          echo "${CLAUDE_CODE_OAUTH_TOKEN:-CLEAN}") 2>/dev/null )"
[ "$outv" = "CLEAN" ] \
  && ok "secret_exec: values never leak into the calling shell" \
  || ko "secret_exec isolation: got '$outv' (want CLEAN)"
outv="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; secret_exec gate -- echo bare-ok) 2>/dev/null )"
[ "$outv" = "bare-ok" ] \
  && ok "secret_exec: missing scope file runs the command bare" \
  || ko "secret_exec bare: got '$outv'"
# quoting robustness: args with spaces/quotes must survive the sh -c re-exec
outv="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"
          secret_exec worker -- printf '%s|%s' "two words" "it's quoted") 2>/dev/null )"
[ "$outv" = "two words|it's quoted" ] \
  && ok "secret_exec: shell_quote preserves spaces and quotes" \
  || ko "secret_exec quoting: got '$outv'"
# gate scope injects independently of worker scope
printf 'GATE_TOKEN=g789\n' > "$ws/secret.gate.env"
outv="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"
          secret_exec gate -- sh -c 'echo "${GATE_TOKEN:-EMPTY}:${CLAUDE_CODE_OAUTH_TOKEN:-EMPTY}"') 2>/dev/null )"
[ "$outv" = "g789:EMPTY" ] && ok "secret_exec gate: scope file injected, worker values absent" || ko "secret_exec gate scope: got '$outv'"
# auth_mode probes without leaking
outv="$( (export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; auth_mode) 2>/dev/null )"
[ "$outv" = "subscription" ] && ok "auth_mode: subscription detected via probe (no value printed)" || ko "auth_mode: got '$outv'"
# an empty seeded template must NOT count as a configured secret (host fallback stays alive)
tpl="$(mktemp -d)"; touch "$tpl/.loop-workspace"
printf '# template only\nCLAUDE_CODE_OAUTH_TOKEN=\n' > "$tpl/secret.worker.env"
outv="$( (export LOOP_PROJECT="$tpl"; source "$CTL/lib.sh"
          secret_present worker && echo present || echo absent) 2>/dev/null )"
[ "$outv" = "absent" ] \
  && ok "secret_present: empty template file does not count as configured" \
  || ko "secret_present template: got '$outv' (want absent)"
rm -rf "$tpl"

echo "== lib: codex_gate_policy (advise/block round accounting) =="
mkdir -p "$ws/state"
cgp() { # <desc> <expected-rc> <mode> <verdict-json> [pre-count]
  local desc="$1" exp="$2" mode="$3" vjson="$4" pre="${5:-}"
  printf '%s' "$vjson" > "$ws/state/v.json"
  [ -n "$pre" ] && echo "$pre" > "$ws/state/t1.codex-rounds" || rm -f "$ws/state/t1.codex-rounds"
  ( export LOOP_PROJECT="$ws" SECOND_OPINION="$mode"
    source "$CTL/lib.sh"; codex_gate_policy "$ws/state/v.json" t1 ) >"$ws/state/fb.out" 2>/dev/null
  local rc=$?
  [ "$rc" = "$exp" ] && ok "codex_gate_policy $desc (rc $rc)" || ko "codex_gate_policy $desc: expected $exp got $rc"
}
HIGH='{"verdict":"concerns","issues":[{"slice":null,"severity":"high","note":"real bug"}]}'
MED='{"verdict":"concerns","issues":[{"slice":null,"severity":"medium","note":"meh"}]}'
OKV='{"verdict":"ok","issues":[]}'
cgp "ok verdict passes"                  0 advise "$OKV"
cgp "medium-only concerns pass (log)"    0 advise "$MED"
cgp "high + advise + fresh budget -> 7"  7 advise "$HIGH"
grep -q "real bug" "$ws/state/fb.out" && ok "codex_gate_policy: feedback body carries the issues" \
                                      || ko "codex_gate_policy: feedback body empty"
[ "$(cat "$ws/state/t1.codex-rounds" 2>/dev/null)" = 1 ] && ok "codex_gate_policy: round counter incremented" \
                                                         || ko "codex_gate_policy: counter wrong"
cgp "high + advise + budget spent -> 0"  0 advise "$HIGH" 1
cgp "high + block always routes -> 7"    7 block  "$HIGH" 5
cgp "off mode ignores verdict"           0 off    "$HIGH"
( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; codex_gate_policy "$ws/state/missing.json" t1 ) >/dev/null 2>&1 \
  && ok "codex_gate_policy: missing verdict file passes" || ko "codex_gate_policy: missing file should pass"

echo "== second-opinion.sh (fake codex shim) =="
# Fake codex: answers the --output-last-message probe, captures argv+prompt, writes a canned
# payload, honors FAKE_CODEX_RC / FAKE_CODEX_SLEEP.
cat > "$bin/codex" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "exec" ] && [ "$2" = "--help" ]; then echo "  --output-last-message <file>"; exit 0; fi
printf '%s\n' "$@" > "${FAKE_CODEX_CAPTURE:-/dev/null}"
[ -n "${FAKE_CODEX_SLEEP:-}" ] && sleep "$FAKE_CODEX_SLEEP"
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then printf '%s' "${FAKE_CODEX_PAYLOAD:-}" > "$out"; else printf '%s' "${FAKE_CODEX_PAYLOAD:-}"; fi
exit "${FAKE_CODEX_RC:-0}"
SHIM
chmod +x "$bin/codex"
# Fixture repo: a base + a work branch, plus a feedback.md whose MARKER must never reach codex.
sows="$(mktemp -d)"; touch "$sows/.loop-workspace"
mkdir -p "$sows/canonical" "$sows/state/workers/t1/harness"
git -C "$sows/canonical" init -q -b main
( cd "$sows/canonical" && git config user.email a@b && git config user.name a \
  && mkdir src && echo v1 > src/app.txt && git add -A && git commit -qm base \
  && git checkout -qb work/t1 && echo v2-the-diff-content > src/app.txt && git commit -qam change )
echo "INDEPENDENCE_MARKER_survives" > "$sows/state/workers/t1/harness/feedback.md"
printf '# Task\ndo the thing\n' > "$sows/state/workers/t1/harness/task.md"
base_sha="$(git -C "$sows/canonical" rev-parse main)"
so() { # <desc> <expected-rc> [env pairs...]
  local desc="$1" exp="$2"; shift 2
  ( export LOOP_PROJECT="$sows" PATH="$bin:$PATH" "$@"
    bash "$CTL/second-opinion.sh" gate --task t1 --dir "$sows/canonical" \
      --base "$base_sha" --branch work/t1 \
      --brief "$sows/state/workers/t1/harness/task.md" --out "$sows/state/verdict.json"
  ) >/dev/null 2>&1
  local rc=$?
  [ "$rc" = "$exp" ] && ok "second-opinion $desc (rc $rc)" || ko "second-opinion $desc: expected $exp got $rc"
}
cap="$sows/capture.txt"
so "clean JSON verdict -> 0"        0 FAKE_CODEX_CAPTURE="$cap" FAKE_CODEX_PAYLOAD='{"verdict":"concerns","issues":[{"slice":null,"severity":"high","note":"bug at src/app.txt"}]}'
jq -e '.verdict=="concerns" and (.issues|length)==1' "$sows/state/verdict.json" >/dev/null 2>&1 \
  && ok "second-opinion: verdict normalized to schema" || ko "second-opinion: verdict file wrong"
grep -q -- '--sandbox' "$cap" && grep -q 'read-only' "$cap" \
  && ok "second-opinion: codex runs with --sandbox read-only" || ko "second-opinion: sandbox flag missing"
if grep -q 'v2-the-diff-content' "$cap" && grep -q 'do the thing' "$cap" \
   && ! grep -q 'INDEPENDENCE_MARKER' "$cap"; then
  ok "second-opinion: sees diff+brief, NEVER the feedback history (independence)"
else ko "second-opinion: independence violated or artifacts missing"; fi
so "fenced JSON still parses -> 0"  0 FAKE_CODEX_PAYLOAD='```json
{"verdict":"ok","issues":[]}
```'
so "garbage output -> skip 3"       3 FAKE_CODEX_PAYLOAD='I think it looks fine!'
so "codex non-zero exit -> skip 3"  3 FAKE_CODEX_RC=1 FAKE_CODEX_PAYLOAD='{"verdict":"ok","issues":[]}'
so "codex timeout -> skip 3"        3 FAKE_CODEX_SLEEP=5 CODEX_TIMEOUT=1 FAKE_CODEX_PAYLOAD='{"verdict":"ok","issues":[]}'
( export LOOP_PROJECT="$sows" PATH="/usr/bin:/bin"
  bash "$CTL/second-opinion.sh" gate --task t1 --dir "$sows/canonical" --base "$base_sha" \
    --branch work/t1 --out "$sows/state/verdict.json" ) >/dev/null 2>&1
rc=$?
[ "$rc" = 3 ] && ok "second-opinion: codex absent -> skip 3" || ko "second-opinion absent: expected 3 got $rc"
# plan mode
printf '[{"name":"a","paths":["src/a/"],"brief":"build a","tests":["tests/a.txt"]}]' > "$sows/slices.json"
( export LOOP_PROJECT="$sows" PATH="$bin:$PATH" FAKE_CODEX_CAPTURE="$cap" \
         FAKE_CODEX_PAYLOAD='{"verdict":"concerns","issues":[{"slice":"a","severity":"medium","note":"brief too vague"}]}'
  bash "$CTL/second-opinion.sh" plan --slices "$sows/slices.json" --goal "ship feature A" \
    --out "$sows/state/pverdict.json" ) >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] && jq -e '.issues[0].slice=="a"' "$sows/state/pverdict.json" >/dev/null 2>&1 \
   && grep -q 'ship feature A' "$cap"; then
  ok "second-opinion plan mode: verdict written, goal in prompt"
else ko "second-opinion plan mode failed (rc=$rc)"; fi
rm -rf "$sows" "$bin"

echo "== lib: validate_slices (deterministic plan validation) =="
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

echo "== lib: worker_watchdog_action (liveness decision) =="
ww() { # <desc> <expected> <idle> <warned> [TIMEOUT] [GRACE]
  local desc="$1" exp="$2" idle="$3" warned="$4" to="${5:-100}" gr="${6:-50}" out
  out="$( export LOOP_PROJECT="$ws" WORKER_TIMEOUT_SECS="$to" WORKER_HANG_GRACE="$gr"; source "$CTL/lib.sh"; worker_watchdog_action "$idle" "$warned" )"
  [ "$out" = "$exp" ] && ok "worker_watchdog_action $desc ($out)" || ko "worker_watchdog_action $desc: expected $exp got $out"
}
ww "below timeout -> none"        none 50  0
ww "at timeout, unwarned -> warn" warn 100 0
ww "past timeout, unwarned -> warn" warn 150 0
ww "warned but within grace -> none" none 40 1
ww "warned past grace -> act"     act  60  1
ww "disabled (timeout 0) -> none" none 9999 0 0 0

echo "== lib: sync_unknown_decision (herdr-down anti-corruption) =="
su() { # <desc> <expected> <quiet_secs> [SYNC_IDLE_SECS]
  local desc="$1" exp="$2" q="$3" idle="${4:-120}" out
  out="$( export LOOP_PROJECT="$ws" SYNC_IDLE_SECS="$idle"; source "$CTL/lib.sh"; sync_unknown_decision "$q" )"
  [ "$out" = "$exp" ] && ok "sync_unknown_decision $desc ($out)" || ko "sync_unknown_decision $desc: expected $exp got $out"
}
su "recent commit -> defer"        defer 10  120
su "quiet long enough -> ok"       ok    200 120
su "at threshold -> ok"            ok    120 120
su "disabled (0) -> ok even fresh" ok    1   0

echo "== lib: backlog_reset_inprogress (crash reconciliation) =="
bl="$ws/backlog.md"
printf -- '- [x] done goal\n- [~] stuck goal\n- [ ] fresh goal\n- [~] another stuck\n' > "$bl"
n="$( source "$CTL/lib.sh"; backlog_reset_inprogress "$bl" )"
if [ "$n" = 2 ] && grep -qxF -- '- [ ] stuck goal' "$bl" && grep -qxF -- '- [ ] another stuck' "$bl" \
   && grep -qxF -- '- [x] done goal' "$bl" && ! grep -qF -- '[~]' "$bl"; then
  ok "backlog_reset_inprogress flips [~] -> [ ], leaves [x]/[ ] intact (reset $n)"
else ko "backlog_reset_inprogress: wrong result (n=$n)"; fi
# idempotent: a second pass resets nothing.
n2="$( source "$CTL/lib.sh"; backlog_reset_inprogress "$bl" )"
[ "$n2" = 0 ] && ok "backlog_reset_inprogress idempotent (0 on clean backlog)" || ko "backlog_reset_inprogress: expected 0 got $n2"
# except-arg: the ledger-restored goal stays [~]; every other orphan is still reset.
printf -- '- [~] restored goal\n- [~] orphan goal\n' > "$bl"
n3="$( source "$CTL/lib.sh"; backlog_reset_inprogress "$bl" 'restored goal' )"
if [ "$n3" = 1 ] && grep -qxF -- '- [~] restored goal' "$bl" && grep -qxF -- '- [ ] orphan goal' "$bl"; then
  ok "backlog_reset_inprogress: except-goal kept [~], orphan reset"
else ko "backlog_reset_inprogress except: n=$n3 ($(tr '\n' ' ' < "$bl"))"; fi

echo "== lib: gate_now_decision (shared burst gating, loop.sh + watch.sh) =="
gnd() { # <desc> <expected "action unk"> <head> <seen> <state> <unk>
  local desc="$1" exp="$2"; shift 2
  local out
  out="$( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; gate_now_decision "$@" )"
  [ "$out" = "$exp" ] && ok "gate_now_decision $desc ($out)" || ko "gate_now_decision $desc: expected '$exp' got '$out'"
}
gnd "no new commit -> none"          "none 3"  aaa aaa idle    3
gnd "no branch yet -> none"          "none 0"  none ""  idle   0
gnd "mid-burst (working) -> wait"    "wait 0"  bbb aaa working 4
gnd "burst over (idle) -> gate"      "gate 0"  bbb aaa idle    4
gnd "burst over (blocked) -> gate"   "gate 0"  bbb aaa blocked 0
gnd "unknown inside grace -> defer"  "defer 1" bbb aaa none    0
gnd "unknown past grace -> force"    "force 0" bbb aaa none    5

echo "== lib: loop_active ledger (crash-restart reconciliation) =="
la="$( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"
       loop_active_save "goal G" '[{"name":"s2"}]' '{"w1":{"slice":"s1","rounds":2}}'
       loop_active_file )"
jq -e '.goal=="goal G" and .queue[0].name=="s2" and .busy.w1.rounds==2 and .landed==0 and .escalated==0' "$la" >/dev/null 2>&1 \
  && ok "loop_active_save: goal/queue/busy persisted as JSON (landed/escalated default 0)" \
  || ko "loop_active_save: bad ledger ($(cat "$la" 2>/dev/null))"
( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"
  loop_active_save "goal G" '[]' '{}' 0 2 )
jq -e '.landed==0 and .escalated==2' "$la" >/dev/null 2>&1 \
  && ok "loop_active_save: landed/escalated counters persisted" \
  || ko "loop_active_save counters: $(cat "$la" 2>/dev/null)"
printf -- '- [~] goal G\n' > "$bl"
g="$( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; loop_active_goal "$bl" )"
[ "$g" = "goal G" ] && ok "loop_active_goal: in-progress goal restored" || ko "loop_active_goal: got '$g'"
printf -- '- [x] goal G\n' > "$bl"
g="$( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; loop_active_goal "$bl" )"
[ -z "$g" ] && ok "loop_active_goal: stale ledger (goal no longer [~]) rejected" || ko "loop_active_goal stale: got '$g'"
( export LOOP_PROJECT="$ws"; source "$CTL/lib.sh"; loop_active_clear )
[ ! -e "$la" ] && ok "loop_active_clear removes the ledger" || ko "loop_active_clear: ledger still present"

echo "== lib: feedback_route (merge-aware feedback choke point) =="
fw="$(mktemp -d)"; touch "$fw/.loop-workspace"
mkdir -p "$fw/canonical"; git -C "$fw/canonical" init -q -b main
# Commit in the PAST: the unaddressed check is mtime(feedback) > committime(branch), and a
# same-second commit+write would be indistinguishable at stat granularity.
GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$fw/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
git -C "$fw/canonical" branch work/w1
fr() { ( export LOOP_PROJECT="$fw"; source "$CTL/lib.sh"; feedback_route w1 ); }
FB="$fw/state/workers/w1/harness/feedback.md"
printf 'FIRST failure log\n' | fr
grep -qx 'FIRST failure log' "$FB" 2>/dev/null \
  && ok "feedback_route: fresh write creates feedback.md" || ko "feedback_route fresh: $(cat "$FB" 2>/dev/null)"
# Unaddressed (no commit since the first write) -> the second note APPENDS, never erases.
printf 'SECOND note (sync)\n' | fr
if grep -qx 'FIRST failure log' "$FB" && grep -qx 'SECOND note (sync)' "$FB" && grep -qx -- '---' "$FB"; then
  ok "feedback_route: unaddressed feedback appended (both sections present)"
else ko "feedback_route append: $(tr '\n' ' ' < "$FB")"; fi
# Addressed (branch committed AFTER the feedback was written) -> start fresh.
touch -d '2000-01-01 00:00' "$FB"
git -C "$fw/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m fix
git -C "$fw/canonical" update-ref refs/heads/work/w1 HEAD
printf 'THIRD (new round)\n' | fr
if grep -qx 'THIRD (new round)' "$FB" && ! grep -q 'FIRST failure log' "$FB"; then
  ok "feedback_route: addressed feedback overwritten (fresh round)"
else ko "feedback_route overwrite: $(tr '\n' ' ' < "$FB")"; fi
rm -rf "$fw"

echo "== lib: f2p_preflight (contract tests must fail on base) =="
fp="$(mktemp -d)"; touch "$fp/.loop-workspace"
mkdir -p "$fp/canonical" "$fp/out-tests"
git -C "$fp/canonical" init -q -b main
( cd "$fp/canonical" && git config user.email a@b && git config user.name a \
  && git commit -q --allow-empty -m init )
printf 'exit 0\n' > "$fp/out-tests/passes-on-base.sh"   # F2P violation: green before any work
printf 'exit 1\n' > "$fp/out-tests/fails-on-base.sh"    # correct F2P: red until implemented
printf '[{"name":"s1","paths":["src/"],"brief":"b","tests":["tests/fails-on-base.sh"]}]' > "$fp/ok.json"
printf '[{"name":"s1","paths":["src/"],"brief":"b","tests":["tests/passes-on-base.sh"]}]' > "$fp/bad.json"
( export LOOP_PROJECT="$fp" F2P_CHECK_CMD='bash'; source "$CTL/lib.sh"
  f2p_preflight "$fp/ok.json" "$fp/out-tests" ) >/dev/null 2>&1 \
  && ok "f2p_preflight: failing-on-base contract test accepted" \
  || ko "f2p_preflight: rejected a correct F2P test"
if out="$( export LOOP_PROJECT="$fp" F2P_CHECK_CMD='bash'; source "$CTL/lib.sh"
           f2p_preflight "$fp/bad.json" "$fp/out-tests" 2>&1 )"; then
  ko "f2p_preflight: accepted a test that passes on base"
else
  printf '%s' "$out" | grep -q 'F2P violation' \
    && ok "f2p_preflight: already-passing contract test rejected with reason" \
    || ko "f2p_preflight: wrong error ($out)"
fi
( export LOOP_PROJECT="$fp"; source "$CTL/lib.sh"
  f2p_preflight "$fp/bad.json" "$fp/out-tests" ) >/dev/null 2>&1 \
  && ok "f2p_preflight: empty F2P_CHECK_CMD -> off (advisory pass)" \
  || ko "f2p_preflight: ran despite empty F2P_CHECK_CMD"
git -C "$fp/canonical" worktree list --porcelain 2>/dev/null | grep -q '/f2p\.' \
  && ko "f2p_preflight: disposable worktree leaked" \
  || ok "f2p_preflight: disposable worktree cleaned up"
rm -rf "$fp"

echo "== land.sh dirty-canonical guard =="
dw="$(mktemp -d)"; touch "$dw/.loop-workspace"; mkdir -p "$dw/state" "$dw/memory"
mkdir -p "$dw/canonical"; git -C "$dw/canonical" init -q -b main
( cd "$dw/canonical" && git config user.email a@b && git config user.name a \
  && echo base > f.txt && git add -A && git commit -qm init \
  && git checkout -qb work/w1 && echo change > g.txt && git add g.txt && git commit -qm change \
  && git checkout -q main )
printf 'TASK=w1\nBRANCH=work/w1\nWORKTREE=%s/none\n' "$dw" > "$dw/state/w1.env"
echo dirty >> "$dw/canonical/f.txt"
if out="$( export LOOP_PROJECT="$dw"; bash "$CTL/land.sh" w1 --no-verify 2>&1 )"; then
  ko "land: merged despite a dirty canonical"
else
  printf '%s' "$out" | grep -q 'uncommitted/staged changes' \
    && ok "land: dirty canonical refused with a loud message" \
    || ko "land dirty: wrong error ($(printf '%s' "$out" | tail -1))"
fi
git -C "$dw/canonical" checkout -q -- f.txt
if ( export LOOP_PROJECT="$dw"; bash "$CTL/land.sh" w1 --no-verify ) >/dev/null 2>&1 \
   && [ -f "$dw/canonical/g.txt" ]; then
  ok "land: clean canonical merges normally after the guard"
else ko "land clean: merge failed after cleaning"; fi

echo "== verify -> land freshness token (skip the redundant re-gate) =="
# New worker branch on the same fixture: verify PASS writes the (base, branch) token; an
# immediate land skips the duplicate gate run; any new commit invalidates the token.
( cd "$dw/canonical" && git checkout -qb work/w2 && echo w2 > h.txt && git add h.txt \
  && git commit -qm w2 && git checkout -q main )
printf 'TASK=w2\nBRANCH=work/w2\nWORKTREE=%s/none\n' "$dw" > "$dw/state/w2.env"
( export LOOP_PROJECT="$dw" SECOND_OPINION=off; bash "$CTL/verify.sh" w2 ) >/dev/null 2>&1 \
  && [ -f "$dw/state/w2.verified" ] \
  && ok "verify: PASS writes the freshness token" \
  || ko "verify: no freshness token after PASS"
out="$( export LOOP_PROJECT="$dw" SECOND_OPINION=off; bash "$CTL/land.sh" w2 2>&1 )" || true
if printf '%s' "$out" | grep -q 'skipping the redundant re-gate' && [ -f "$dw/canonical/h.txt" ]; then
  ok "land: fresh verify PASS skips the re-gate and merges"
else ko "land freshness: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
[ ! -f "$dw/state/w2.verified" ] \
  && ok "land: freshness token consumed on merge" \
  || ko "land: freshness token survived the merge"
# Stale token: verify, then move the branch — land must re-gate (token sha mismatch).
( cd "$dw/canonical" && git checkout -qb work/w3 && echo w3 > i.txt && git add i.txt \
  && git commit -qm w3 && git checkout -q main )
printf 'TASK=w3\nBRANCH=work/w3\nWORKTREE=%s/none\n' "$dw" > "$dw/state/w3.env"
( export LOOP_PROJECT="$dw" SECOND_OPINION=off; bash "$CTL/verify.sh" w3 ) >/dev/null 2>&1 || true
( cd "$dw/canonical" && git checkout -q work/w3 && echo more >> i.txt && git add i.txt \
  && git commit -qm more && git checkout -q main )
out="$( export LOOP_PROJECT="$dw" SECOND_OPINION=off; bash "$CTL/land.sh" w3 2>&1 )" || true
if printf '%s' "$out" | grep -q 'GATE:' && ! printf '%s' "$out" | grep -q 'skipping the redundant re-gate'; then
  ok "land: stale token (new commit) re-runs the gate"
else ko "land stale token: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
rm -rf "$dw"

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

# D12: with origin's PUSH url blanked (what setup.sh does), a worker-style `git push origin`
# must FAIL structurally (unroutable url — not a bypassable hook), while the sanctioned publish
# path still delivers because it pushes to the explicit FETCH url.
git -C "$wsc/canonical" remote set-url --push origin "no-push://blocked-by-loop.invalid"
if ( cd "$wsc/canonical" && git push origin HEAD:refs/heads/evil ) >/dev/null 2>&1; then
  ko "D12: worker-style 'git push origin' succeeded despite blanked push url"
else ok "D12: 'git push origin' structurally blocked (unroutable push url)"; fi
if ( export LOOP_PROJECT="$wsc"; bash "$CTL/publish.sh" ) >/dev/null 2>&1; then
  ok "D12: publish.sh still delivers via the explicit fetch url"
else ko "D12: publish.sh broke under blanked push url"; fi
unset LOOP_HOME
rm -rf "$zf"

echo "== lib: ontology_event / ontology_digest_refresh (AIF event graph) =="
ow="$(mktemp -d)"; touch "$ow/.loop-workspace"
( export LOOP_PROJECT="$ow"
  source "$CTL/lib.sh"
  ontology_event CA gate-fail "gate:w1 exit 1" "task:w1" "branch failed acceptance"
  ontology_event PA landed "gate:w2 pass" "task:w2" "merged"
  ontology_event XX bogus "a" "b" "must be ignored"          # invalid node -> no write
) >/dev/null 2>&1
g="$ow/memory/ontology/graph.jsonl"
if [ "$(wc -l < "$g" 2>/dev/null)" = 2 ] \
   && jq -es '[.[] | select(.node=="CA")] | length==1 and .[0].scheme=="gate-fail" and .[0].target=="task:w1"' "$g" >/dev/null 2>&1; then
  ok "ontology_event appends valid JSONL, drops invalid node types"
else ko "ontology_event: graph wrong ($(cat "$g" 2>/dev/null))"; fi
( export LOOP_PROJECT="$ow" ONTOLOGY_ENABLED=0
  source "$CTL/lib.sh"; ontology_event CA gate-fail p t n ) >/dev/null 2>&1
[ "$(wc -l < "$g")" = 2 ] && ok "ontology_event: ONTOLOGY_ENABLED=0 is a no-op" \
                          || ko "ontology_event wrote despite ONTOLOGY_ENABLED=0"
# digest: CA on w1 has no later PA -> open; CA on w2 older than its PA -> folded.
( export LOOP_PROJECT="$ow"
  source "$CTL/lib.sh"
  printf '{"ts":"2026-01-01T00:00:00Z","node":"CA","scheme":"gate-fail","premise":"g","target":"task:w2","note":"old conflict"}\n' >> "$g"
  ontology_digest_refresh ) >/dev/null 2>&1
d="$ow/memory/ontology/digest.md"
if grep -q 'task:w1: branch failed acceptance' "$d" 2>/dev/null && ! grep -q 'old conflict' "$d" 2>/dev/null; then
  ok "ontology_digest_refresh: open CA listed, PA-superseded CA folded"
else ko "ontology_digest_refresh: digest wrong ($(cat "$d" 2>/dev/null | head -6))"; fi

echo "== ontology-check.sh (upper-ontology constraints) =="
oc() { # <desc> <expected-rc> <jsonl-content>
  local desc="$1" exp="$2" body="$3" rc f
  f="$(mktemp)"; printf '%s\n' "$body" > "$f"
  ( export LOOP_PROJECT="$ow"; bash "$CTL/ontology-check.sh" "$f" ) >/dev/null 2>&1; rc=$?
  rm -f "$f"
  [ "$rc" = "$exp" ] && ok "ontology-check $desc (rc $rc)" || ko "ontology-check $desc: expected $exp got $rc"
}
oc "valid S-node passes"      0 '{"ts":"2026-01-01T00:00:00Z","node":"CA","scheme":"gate-fail","premise":"g","target":"t","note":"n"}'
oc "valid I-node passes"      0 '{"ts":"2026-01-01T00:00:00Z","node":"I","scheme":"module","note":"auth module owns login"}'
oc "S-node without target"    1 '{"ts":"2026-01-01T00:00:00Z","node":"PA","scheme":"landed","premise":"g","note":"n"}'
oc "I-node with premise (I->I forbidden)" 1 '{"ts":"2026-01-01T00:00:00Z","node":"I","scheme":"m","premise":"x","target":"y","note":"n"}'
oc "unknown node type"        1 '{"ts":"2026-01-01T00:00:00Z","node":"ZZ","scheme":"m","premise":"x","target":"y"}'
oc "garbage line"             1 'not json at all'
( export LOOP_PROJECT="$ow"; bash "$CTL/ontology-check.sh" "$ow/nonexistent.jsonl" ) >/dev/null 2>&1 \
  && ok "ontology-check: absent graph is fine (rc 0)" || ko "ontology-check: absent graph should pass"
( export LOOP_PROJECT="$ow"; bash "$CTL/ontology-check.sh" ) >/dev/null 2>&1 \
  && ok "ontology-check: validates the real event graph (rc 0)" || ko "ontology-check failed on ontology_event output"
# Auto-wired validation: a corrupt graph makes digest refresh WARN (PROGRESS) but never fail —
# the check runs inside the loop now, not only when someone remembers `loop ontology-check`.
printf 'not json at all\n' >> "$g"
if ( export LOOP_PROJECT="$ow"; source "$CTL/lib.sh"; ontology_digest_refresh ) >/dev/null 2>&1; then
  grep -q $'\tONTOLOGY_INVALID\t' "$ow/memory/PROGRESS.md" 2>/dev/null \
    && ok "digest refresh: corrupt graph logged as ONTOLOGY_INVALID (rc stays 0)" \
    || ko "digest refresh: corrupt graph not reported to PROGRESS"
else ko "digest refresh: corrupt graph broke the rc-0 contract"; fi
rm -rf "$ow"

echo "== lib: escalation_report (verifier co-evolution seam) =="
ew="$(mktemp -d)"; touch "$ew/.loop-workspace"
out="$( export LOOP_PROJECT="$ew"
  source "$CTL/lib.sh"
  mkdir -p "$(harness_dir w1)"; echo "the actual failure text" > "$(harness_dir w1)/feedback.md"
  escalation_report w1 my-slice 5 )"
if [ -n "$out" ] && [ -f "$out" ] && grep -q 'the actual failure text' "$out" \
   && grep -q 'The GATE is wrong' "$out"; then
  ok "escalation_report writes a both-hypotheses packet with the last feedback"
else ko "escalation_report: packet wrong ($out)"; fi
rm -rf "$ew"

echo "== gate.sh hardening (harness/ protection, test-gaming monitor, policy checks) =="
# Hermetic gate fixture: workspace + canonical + a committed work branch, no herdr/codex.
gws="$(mktemp -d)"; touch "$gws/.loop-workspace"
mkdir -p "$gws/canonical" "$gws/state"
git -C "$gws/canonical" init -q -b main
( cd "$gws/canonical" && git config user.email a@b && git config user.name a \
  && mkdir -p src harness && echo base > src/app.txt && echo 'exit 0' > harness/check.sh \
  && git add -A && git commit -qm base )
printf 'TASK=w1\nBRANCH=work/w1\nWORKTREE=%s/wt\n' "$gws" > "$gws/state/w1.env"
gate_fixture_branch() { # reset work/w1 to main (worktree first — a checked-out branch can't be deleted)
  git -C "$gws/canonical" worktree remove --force "$gws/wtx" >/dev/null 2>&1 || true
  git -C "$gws/canonical" worktree prune >/dev/null 2>&1 || true
  git -C "$gws/canonical" branch -Df work/w1 >/dev/null 2>&1 || true
  git -C "$gws/canonical" worktree add -b work/w1 "$gws/wtx" main >/dev/null 2>&1
}
gate_run() { # [env pairs...] -> rc
  ( export LOOP_PROJECT="$gws" SECOND_OPINION=off "$@"
    bash "$CTL/gate.sh" w1 ) >"$gws/gate.out" 2>&1
  echo $?
}
commit_wtx() { git -C "$gws/wtx" -c user.email=w@l -c user.name=w add -A >/dev/null 2>&1; git -C "$gws/wtx" -c user.email=w@l -c user.name=w commit -qm x >/dev/null 2>&1; }
# 1) clean branch passes (advisory-free: harness/check.sh exits 0)
gate_fixture_branch; echo v2 > "$gws/wtx/src/app.txt"; commit_wtx
rc="$(gate_run)"; [ "$rc" = 0 ] && ok "gate: clean branch passes (rc 0)" || ko "gate clean: rc $rc ($(tail -3 "$gws/gate.out" | tr '\n' ' '))"
# 2) worker edits harness/check.sh -> exit 4 (gate self-neutering blocked)
gate_fixture_branch; echo 'exit 0 # tampered' > "$gws/wtx/harness/check.sh"; commit_wtx
rc="$(gate_run)"; [ "$rc" = 4 ] && ok "gate: harness/ tampering denied (exit 4)" || ko "gate harness-protect: expected 4 got $rc"
rc="$(gate_run GATE_PROTECT_HARNESS=0)"
[ "$rc" = 0 ] && ok "gate: GATE_PROTECT_HARNESS=0 disables the harness wall" || ko "gate harness-protect off: expected 0 got $rc"
# 3) test-gaming monitor: added .skip in a spec file
gate_fixture_branch
mkdir -p "$gws/wtx/src"; printf 'it.skip("x", () => {})\n' > "$gws/wtx/src/app.spec.ts"; commit_wtx
rc="$(gate_run GATE_TESTGAMING=block)"
[ "$rc" = 6 ] && ok "gate: test-gaming (it.skip) blocked (exit 6)" || ko "gate gaming block: expected 6 got $rc"
rc="$(gate_run GATE_TESTGAMING=warn)"
if [ "$rc" = 0 ] && grep -q 'test-gaming patterns' "$gws/gate.out"; then
  ok "gate: test-gaming warn mode logs but passes"
else ko "gate gaming warn: rc $rc"; fi
grep -q $'\tTESTGAMING\t' "$gws/memory/PROGRESS.md" 2>/dev/null \
  && ok "gate: TESTGAMING event logged to PROGRESS" || ko "gate: TESTGAMING event missing"
jq -e 'select(.node=="CA" and .scheme=="test-gaming")' "$gws/memory/ontology/graph.jsonl" >/dev/null 2>&1 \
  && ok "gate: test-gaming recorded as CA ontology node" || ko "gate: gaming CA node missing"
rc="$(gate_run GATE_TESTGAMING=off)"
if [ "$rc" = 0 ] && ! grep -q 'test-gaming patterns' "$gws/gate.out"; then
  ok "gate: GATE_TESTGAMING=off skips the monitor"
else ko "gate gaming off: rc $rc"; fi
# 4) non-test file with .skip must NOT trip the monitor
gate_fixture_branch; printf 'queue.skip(item)\n' > "$gws/wtx/src/queue.ts"; commit_wtx
rc="$(gate_run GATE_TESTGAMING=block)"
[ "$rc" = 0 ] && ok "gate: .skip outside test files ignored" || ko "gate gaming false-positive: rc $rc"
# 5) workspace gate.d checks run on the merged tree with the GATE_* env contract
mkdir -p "$gws/gate.d"
cat > "$gws/gate.d/99-probe.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "$GATE_TASK" ] && [ -n "$GATE_MERGE_BASE" ] && [ -n "$GATE_BRANCH" ] || exit 9
grep -q v2 src/app.txt || exit 8   # merged tree contains the worker change
exit "${POLICY_PROBE_RC:-0}"
EOF
gate_fixture_branch; echo v2 > "$gws/wtx/src/app.txt"; commit_wtx
rc="$(gate_run)"; [ "$rc" = 0 ] && ok "gate: passing gate.d check keeps the gate green" || ko "gate.d pass: rc $rc ($(tail -3 "$gws/gate.out" | tr '\n' ' '))"
rc="$(gate_run POLICY_PROBE_RC=7)"
if [ "$rc" = 7 ] && grep -q 'gate.d check 99-probe.sh' "$gws/gate.out"; then
  ok "gate: failing gate.d check fails the gate with its exit code"
else ko "gate.d fail: expected 7 got $rc"; fi
git -C "$gws/canonical" worktree remove --force "$gws/wtx" >/dev/null 2>&1 || true
rm -rf "$gws"

echo "== harness.sh (packs -> existing harness/gate seams) =="
pw="$(mktemp -d)"; touch "$pw/.loop-workspace"; mkdir -p "$pw/skills" "$pw/memory"
hns() { ( export LOOP_PROJECT="$pw"; bash "$CTL/harness.sh" "$@" ) ; }
hns list >"$pw/list.out" 2>&1 \
  && grep -q backend-clean-arch "$pw/list.out" && grep -q frontend-humble-object "$pw/list.out" \
  && grep -q ontology-aif "$pw/list.out" \
  && ok "harness list: shows the shipped packs" \
  || ko "harness list wrong: $(cat "$pw/list.out")"
hns apply backend-clean-arch frontend-humble-object ontology-aif >/dev/null 2>&1 \
  && ok "harness apply: three packs adopted" || ko "harness apply failed"
grep -q 'loop-pack: backend-clean-arch/rules' "$pw/skills/RULES.md" 2>/dev/null \
  && grep -q 'loop-pack: frontend-humble-object/worker' "$pw/CLAUDE.worker.local.md" 2>/dev/null \
  && ok "harness: L1 snippets appended with markers" || ko "harness: L1 snippets missing"
[ -x "$pw/worker-harness.d/backend-clean-arch-guard-layer-imports" ] \
  && [ -x "$pw/worker-harness.d/frontend-humble-object-guard-no-e2e" ] \
  && ok "harness: L2 guards installed executable" || ko "harness: L2 guards missing"
[ -f "$pw/gate.d/backend-clean-arch-10-layer-deps.sh" ] \
  && [ -f "$pw/gate.d/frontend-humble-object-20-no-e2e.sh" ] \
  && ok "harness: L3 gate.d checks installed" || ko "harness: L3 checks missing"
[ -f "$pw/gate.d/clean-arch.env" ] && [ -f "$pw/gate.d/frontend-testing.env" ] \
  && ok "harness: config templates placed in gate.d/ (no-clobber)" || ko "harness: configs missing"
[ -f "$pw/memory/ontology/README.md" ] && [ -f "$pw/memory/ontology/forms.md" ] \
  && ok "harness: ontology scaffold placed" || ko "harness: ontology scaffold missing"
hns apply backend-clean-arch >/dev/null 2>&1
[ "$(grep -c 'loop-pack: backend-clean-arch/rules' "$pw/skills/RULES.md")" = 1 ] \
  && ok "harness apply: idempotent (marker prevents duplicate append)" \
  || ko "harness apply duplicated snippets"
grep -q 'adopted pack: backend-clean-arch' "$pw/memory/PROGRESS.md" 2>/dev/null \
  && ok "harness: HARNESS_PACK event logged to PROGRESS" || ko "harness: PROGRESS event missing"

echo "== pack guards + gate.d checks (pack contract) =="
# guard-no-e2e: default config blocks e2e paths and runners, allows normal work.
GNE="$pw/worker-harness.d/frontend-humble-object-guard-no-e2e"
gne() { # <desc> <expected> <json>
  local desc="$1" exp="$2" json="$3" rc
  printf '%s' "$json" | HARNESS_WORKTREE=/wt bash "$GNE" >/dev/null 2>&1; rc=$?
  [ "$rc" = "$exp" ] && ok "guard-no-e2e $desc (exit $rc)" || ko "guard-no-e2e $desc: expected $exp got $rc"
}
gne "block e2e/ dir file"        2 '{"tool_name":"Write","tool_input":{"file_path":"/wt/e2e/login.spec.ts"}}'
gne "block *.cy.ts"              2 '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/login.cy.ts"}}'
gne "block playwright.config"    2 '{"tool_name":"Write","tool_input":{"file_path":"/wt/playwright.config.ts"}}'
gne "allow unit spec"            0 '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/login.spec.ts"}}'
gne "block cypress run (Bash)"   2 '{"tool_name":"Bash","tool_input":{"command":"npx cypress run"}}'
gne "allow npm test (Bash)"      0 '{"tool_name":"Bash","tool_input":{"command":"npm test"}}'
# guard-layer-imports: unconfigured -> allow; configured -> block outward import in core.
GLI="$pw/worker-harness.d/backend-clean-arch-guard-layer-imports"
CORE_JSON='{"tool_name":"Write","tool_input":{"file_path":"/wt/src/domain/user.ts","content":"import pg from \"pg\""}}'
printf '%s' "$CORE_JSON" | HARNESS_WORKTREE=/wt bash "$GLI" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "guard-layer-imports: unconfigured pack is advisory (exit 0)" \
             || ko "guard-layer-imports unconfigured: expected 0 got $rc"
cat > "$pw/gate.d/clean-arch.env" <<'EOF'
CORE_DIRS="src/domain/"
FORBIDDEN_IMPORT_REGEX="from ['\"](pg|express)"
EOF
printf '%s' "$CORE_JSON" | HARNESS_WORKTREE=/wt bash "$GLI" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "guard-layer-imports: outward import into core blocked (exit 2)" \
             || ko "guard-layer-imports block: expected 2 got $rc"
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/adapters/db.ts","content":"import pg from \"pg\""}}' \
  | HARNESS_WORKTREE=/wt bash "$GLI" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "guard-layer-imports: adapters may import infra (exit 0)" \
             || ko "guard-layer-imports adapter: expected 0 got $rc"
# L3 twins on a fixture repo (cwd = tree, GATE_* env contract).
lr="$(mktemp -d)"
git -C "$lr" init -q -b main; ( cd "$lr" && git config user.email a@b && git config user.name a \
  && mkdir -p src/domain && echo 'clean' > src/domain/user.ts && git add -A && git commit -qm base \
  && git checkout -qb work/w1 && printf 'import pg from "pg"\n' >> src/domain/user.ts \
  && mkdir e2e && echo spec > e2e/x.spec.ts && git add -A && git commit -qm change )
mb="$(git -C "$lr" merge-base main work/w1)"
( cd "$lr" && GATE_MERGE_BASE="$mb" GATE_BRANCH=work/w1 bash "$pw/gate.d/backend-clean-arch-10-layer-deps.sh" ) >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "10-layer-deps: added outward core import fails the gate" \
             || ko "10-layer-deps: expected 1 got $rc"
( cd "$lr" && GATE_MERGE_BASE="$mb" GATE_BRANCH=work/w1 bash "$pw/gate.d/frontend-humble-object-20-no-e2e.sh" ) >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "20-no-e2e: added e2e/ file fails the gate" \
             || ko "20-no-e2e: expected 1 got $rc"

echo "== harness.sh (external pack intake, pack spec v1) =="
# A well-formed external pack: frontmatter contract, one L2 guard + selftest fixtures,
# an L3 check and its config template. Guard reads its regex from ../gate.d/ exactly like
# shipped-pack guards (one source of truth), so the staged selftest also proves that layout.
xproot="$(mktemp -d)"; xp="$xproot/extpack"
mkdir -p "$xp/guards" "$xp/selftest" "$xp/check.d" "$xp/config"
cat > "$xp/pack.md" <<'EOF'
---
enforces: no files named forbidden.* (test fixture)
when-to-remove: fixture pack — remove immediately
origin: tests-toolkit/run.sh
requires: nothing (fixture)
---
# extpack — external intake fixture
EOF
printf -- '- fixture rule: never create forbidden.* files\n' > "$xp/RULES.snippet.md"
cat > "$xp/guards/guard-forbid" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate.d/extpack.env"
FORBID_REGEX=''
[ -f "$CFG" ] && source "$CFG"
[ -n "$FORBID_REGEX" ] || exit 0
grep -qE "\"file_path\"[^,}]*$FORBID_REGEX" - && { echo "blocked" >&2; exit 2; }
exit 0
EOF
echo 'FORBID_REGEX="forbidden\."' > "$xp/config/extpack.env"
printf '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/forbidden.ts"}}' > "$xp/selftest/guard-forbid.block.exit2.json"
printf '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/allowed.ts"}}'   > "$xp/selftest/guard-forbid.allow.exit0.json"
echo 'exit 0' > "$xp/check.d/50-extpack.sh"
hns apply "$xp" > "$pw/ext.out" 2>&1 \
  && ok "external pack: adopted from a directory path" \
  || ko "external pack apply failed: $(tail -3 "$pw/ext.out" | tr '\n' ' ')"
grep -q '2 case(s) passed' "$pw/ext.out" \
  && ok "external pack: selftest ran before adoption (2 cases)" \
  || ko "external pack: selftest did not run ($(grep -i selftest "$pw/ext.out" | head -1))"
grep -q 'origin  : tests-toolkit' "$pw/ext.out" && grep -q 'requires: nothing' "$pw/ext.out" \
  && ok "external pack: origin/requires surfaced at the door" \
  || ko "external pack: provenance lines missing"
[ -x "$pw/worker-harness.d/extpack-guard-forbid" ] && [ -f "$pw/gate.d/extpack-50-extpack.sh" ] \
  && [ -f "$pw/gate.d/extpack.env" ] && grep -q 'loop-pack: extpack/rules' "$pw/skills/RULES.md" \
  && ok "external pack: artifacts land in the same seams as shipped packs" \
  || ko "external pack: artifacts missing from workspace seams"
printf '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/forbidden.ts"}}' \
  | HARNESS_WORKTREE=/wt bash "$pw/worker-harness.d/extpack-guard-forbid" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "external pack: installed guard enforces via installed config (exit 2)" \
             || ko "external pack: installed guard inert (expected 2 got $rc)"
# Spec enforcement at the door: a guard with NO selftest case is refused, nothing installed.
xb="$xproot/badpack"; mkdir -p "$xb/guards"
printf -- '---\nenforces: x\nwhen-to-remove: x\n---\n' > "$xb/pack.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$xb/guards/guard-untested"
if hns apply "$xb" >/dev/null 2>&1; then
  ko "external pack: guard without selftest was adopted (must be refused)"
else
  [ ! -e "$pw/worker-harness.d/badpack-guard-untested" ] \
    && ok "external pack: unverified guard refused, nothing installed" \
    || ko "external pack: refused pack still left artifacts"
fi
# A LYING selftest (guard does not behave as the fixture claims) aborts before install.
xl="$xproot/liarpack"; mkdir -p "$xl/guards" "$xl/selftest"
printf -- '---\nenforces: x\nwhen-to-remove: x\n---\n' > "$xl/pack.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$xl/guards/guard-liar"
printf '{"tool_name":"Write","tool_input":{"file_path":"/wt/x"}}' > "$xl/selftest/guard-liar.block.exit2.json"
if hns apply "$xl" >/dev/null 2>&1; then
  ko "external pack: failing selftest was adopted (must abort)"
else
  [ ! -e "$pw/worker-harness.d/liarpack-guard-liar" ] \
    && ok "external pack: failing selftest aborts adoption pre-install" \
    || ko "external pack: failed selftest still installed the guard"
fi
# Missing when-to-remove: the removability contract is mandatory for external packs.
xw="$xproot/nowtr"; mkdir -p "$xw"
printf -- '---\nenforces: x\n---\n' > "$xw/pack.md"
hns apply "$xw" >/dev/null 2>&1 \
  && ko "external pack: missing when-to-remove accepted" \
  || ok "external pack: missing when-to-remove refused"
rm -rf "$xproot"
rm -rf "$lr" "$pw"

echo "== design SSOT direct-read (plan.sh wiring) =="
# The planner must be pointed at the typed-design tree ITSELF (no exported bundle, no cached
# copy): DESIGN_SSOT_DIR when set, else <repo>/atlas auto-detection.
grep -q 'DESIGN_SSOT_DIR' "$CTL/plan.sh" && grep -q 'repo/atlas' "$CTL/plan.sh" \
  && ok "plan.sh: DESIGN_SSOT_DIR honored + in-repo atlas/ auto-detected" \
  || ko "plan.sh: design SSOT direct-read wiring missing"
grep -q 'AUTHORITATIVE' "$CTL/plan.sh" \
  && ok "plan.sh: design contracts framed as authoritative over implementation" \
  || ko "plan.sh: authority framing missing"
grep -q 'DESIGN_SSOT_DIR' "$CTL/config.env" && grep -q 'DESIGN_SSOT_DIR' "$CTL/lib.sh" \
  && ok "config: DESIGN_SSOT_DIR knob documented with a lib default" \
  || ko "config: DESIGN_SSOT_DIR knob missing"

echo "== lib: usage guard (pure decisions) =="
uw="$(mktemp -d)"; touch "$uw/.loop-workspace"
ud() { # <desc> <expected> <five> <seven> [env pairs...]
  local desc="$1" exp="$2" f="$3" s="$4"; shift 4
  local out
  out="$( export LOOP_PROJECT="$uw" USAGE_GUARD=1 "$@"
          source "$CTL/lib.sh"; usage_guard_decision "$f" "$s" )"
  [ "$out" = "$exp" ] && ok "usage_guard_decision $desc ($out)" || ko "usage_guard_decision $desc: expected $exp got $out"
}
ud "below thresholds -> ok"        ok    50  50
ud "5h at 80 -> drain"             drain 80  10
ud "7d at 95 -> drain"             drain 10  95
ud "5h at 100 -> halt"             halt  100 10
ud "7d at 100 -> halt"             halt  10  100
ud "probe broken (none) -> ok"     ok    none none
ud "custom pause pct honored"      drain 60  10 USAGE_PAUSE_PCT=60
out="$( export LOOP_PROJECT="$uw" USAGE_GUARD=0; source "$CTL/lib.sh"; usage_guard_decision 100 100 )"
[ "$out" = ok ] && ok "usage_guard_decision: guard off -> always ok" || ko "guard off: got $out"
out="$( export LOOP_PROJECT="$uw" USAGE_GUARD=1; source "$CTL/lib.sh"; usage_pause_target 85 1000 10 2000 )"
[ "$out" = 1000 ] && ok "usage_pause_target: only the tripped window counts" || ko "pause_target: got $out"
out="$( export LOOP_PROJECT="$uw" USAGE_GUARD=1; source "$CTL/lib.sh"; usage_pause_target 85 1000 96 2000 )"
[ "$out" = 2000 ] && ok "usage_pause_target: latest tripped reset wins (weekly)" || ko "pause_target weekly: got $out"
out="$( export LOOP_PROJECT="$uw" USAGE_GUARD=1; source "$CTL/lib.sh"; usage_pause_target 10 1000 10 2000 )"
[ "$out" = 0 ] && ok "usage_pause_target: nothing tripped -> 0" || ko "pause_target none: got $out"
out="$( export LOOP_PROJECT="$uw" USAGE_RESUME_MARGIN_SECS=90; source "$CTL/lib.sh"; usage_wait_secs 1100 1000 )"
[ "$out" = 190 ] && ok "usage_wait_secs: delta + margin" || ko "wait_secs: got $out"
out="$( export LOOP_PROJECT="$uw" USAGE_RESUME_MARGIN_SECS=90; source "$CTL/lib.sh"; usage_wait_secs 500 1000 )"
[ "$out" = 90 ] && ok "usage_wait_secs: past reset -> margin only" || ko "wait_secs past: got $out"

echo "== lib: usage_probe (OAuth endpoint contract, shimmed) =="
ubin="$(mktemp -d)"
cat > "$ubin/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_CURL_CAPTURE:-/dev/null}"
[ "${FAKE_CURL_RC:-0}" != 0 ] && exit "${FAKE_CURL_RC}"
printf '%s' "${FAKE_CURL_BODY:-}"
SHIM
chmod +x "$ubin/curl"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok123\n' > "$uw/secret.worker.env"
UBODY='{"five_hour":{"utilization":42.0,"resets_at":"2026-02-06T22:00:00+00:00"},"seven_day":{"utilization":14.4,"resets_at":"2026-02-12T20:00:00+00:00"}}'
exp_fr="$(date -u -d '2026-02-06T22:00:00+00:00' +%s)"
exp_sr="$(date -u -d '2026-02-12T20:00:00+00:00' +%s)"
out="$( export LOOP_PROJECT="$uw" PATH="$ubin:$PATH" FAKE_CURL_BODY="$UBODY" FAKE_CURL_CAPTURE="$uw/curl.cap"
        source "$CTL/lib.sh"; usage_probe )"
[ "$out" = "42 $exp_fr 14 $exp_sr" ] \
  && ok "usage_probe: parses utilization + ISO resets_at -> '42 <epoch> 14 <epoch>'" \
  || ko "usage_probe: got '$out' (want '42 $exp_fr 14 $exp_sr')"
if grep -q 'Bearer tok123' "$uw/curl.cap" && grep -q 'anthropic-beta: oauth-2025-04-20' "$uw/curl.cap" \
   && grep -q 'claude-code/' "$uw/curl.cap" && grep -q 'api.anthropic.com/api/oauth/usage' "$uw/curl.cap"; then
  ok "usage_probe: token via secret_exec + mandatory beta/User-Agent headers"
else ko "usage_probe: request shape wrong ($(tr '\n' ' ' < "$uw/curl.cap" 2>/dev/null | head -c 200))"; fi
out="$( export LOOP_PROJECT="$uw" PATH="$ubin:$PATH" FAKE_CURL_RC=22
        source "$CTL/lib.sh"; usage_probe )"
[ "$out" = none ] && ok "usage_probe: curl failure -> none (fail-open)" || ko "usage_probe fail: got '$out'"
out="$( export LOOP_PROJECT="$uw" PATH="$ubin:$PATH" FAKE_CURL_BODY='not json'
        source "$CTL/lib.sh"; usage_probe )"
[ "$out" = none ] && ok "usage_probe: garbage body -> none" || ko "usage_probe garbage: got '$out'"
out="$( export LOOP_PROJECT="$uw" USAGE_PROBE_CMD='echo "81 123 10 456"'
        source "$CTL/lib.sh"; usage_probe )"
[ "$out" = "81 123 10 456" ] && ok "usage_probe: USAGE_PROBE_CMD override honored" || ko "probe override: got '$out'"
# usage_status caching: within USAGE_POLL_SECS the cache answers, no live probe.
cnt="$uw/probe.count"; : > "$cnt"
out="$( export LOOP_PROJECT="$uw" USAGE_POLL_SECS=3600 USAGE_PROBE_CMD='echo p >> '"$cnt"'; echo "50 1 50 2"'
        source "$CTL/lib.sh"; usage_status >/dev/null; usage_status )"
if [ "$out" = "50 1 50 2" ] && [ "$(wc -l < "$cnt")" = 1 ]; then
  ok "usage_status: cached within USAGE_POLL_SECS (1 live probe for 2 reads)"
else ko "usage_status cache: out='$out' probes=$(wc -l < "$cnt")"; fi
rm -rf "$ubin"

echo "== loop.sh usage guard (pause/resume integration) =="
lw="$(mktemp -d)"; mkdir -p "$lw/ws" "$lw/home"
touch "$lw/ws/.loop-workspace"
mkdir -p "$lw/ws/canonical"; git -C "$lw/ws/canonical" init -q -b main
git -C "$lw/ws/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
printf '# Backlog\n\n- [ ] some goal\n' > "$lw/ws/memory/backlog.md" 2>/dev/null || { mkdir -p "$lw/ws/memory"; printf '# Backlog\n\n- [ ] some goal\n' > "$lw/ws/memory/backlog.md"; }
out="$( export LOOP_PROJECT="$lw/ws" HOME="$lw/home" CLAUDE_CODE_OAUTH_TOKEN=dummy WORKER_COUNT=1 \
               USAGE_GUARD=1 USAGE_PROBE_CMD='echo "100 0 100 0"' USAGE_POLL_SECS=1 USAGE_RESUME_MARGIN_SECS=1
        timeout 6 bash "$CTL/loop.sh" 2>&1 )" || true
if printf '%s' "$out" | grep -q 'USAGE PAUSE' && grep -q $'\tUSAGE_PAUSE\t' "$lw/ws/memory/PROGRESS.md" 2>/dev/null; then
  ok "loop: hard-limited probe pauses before planning (USAGE_PAUSE logged)"
else ko "loop usage pause: not triggered ($(printf '%s' "$out" | tail -3 | tr '\n' ' '))"; fi
if ! printf '%s' "$out" | grep -q 'next goal'; then
  ok "loop: no goal planned while hard-limited (tokens protected)"
else ko "loop: planned a goal despite hard limit"; fi
# ok path in a FRESH workspace (a paused run above leaves a poisoned usage.cache behind —
# sharing it here would test cache reuse, not the ok path).
mkdir -p "$lw/ws2/memory" "$lw/ws2/canonical"; touch "$lw/ws2/.loop-workspace"
git -C "$lw/ws2/canonical" init -q -b main
git -C "$lw/ws2/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
printf '# Backlog\n' > "$lw/ws2/memory/backlog.md"
out="$( export LOOP_PROJECT="$lw/ws2" HOME="$lw/home" CLAUDE_CODE_OAUTH_TOKEN=dummy WORKER_COUNT=1 \
               USAGE_GUARD=1 USAGE_PROBE_CMD='echo "10 0 5 0"' USAGE_POLL_SECS=3600
        timeout 10 bash "$CTL/loop.sh" 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'DONE'; then
  ok "loop: guard ok-path leaves the normal flow untouched (empty backlog -> DONE)"
else ko "loop guard ok-path: rc=$rc ($(printf '%s' "$out" | tail -2 | tr '\n' ' '))"; fi
rm -rf "$lw"

echo "== loop.sh crash-restart reconciliation (assignment ledger) =="
# Run 1: PLANNER_ENABLED=0 + human slices -> the loop assigns s1 to w1 and persists the ledger;
# we kill it mid-goal (timeout) to simulate a heartbeat crash.
lr2="$(mktemp -d)"; mkdir -p "$lr2/ws/memory/slices" "$lr2/home"
touch "$lr2/ws/.loop-workspace"
mkdir -p "$lr2/ws/canonical"; git -C "$lr2/ws/canonical" init -q -b main
git -C "$lr2/ws/canonical" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
printf '# Backlog\n\n- [ ] goalX\n' > "$lr2/ws/memory/backlog.md"
printf '[{"name":"s1","paths":["src/"],"brief":"do X"}]\n' > "$lr2/ws/memory/slices/current.json"
out="$( export LOOP_PROJECT="$lr2/ws" HOME="$lr2/home" CLAUDE_CODE_OAUTH_TOKEN=dummy \
               WORKER_COUNT=1 PLANNER_ENABLED=0 LOOP_POLL_SECS=1
        timeout 8 bash "$CTL/loop.sh" 2>&1 )" || true
jq -e '.busy.w1.slice=="s1" and (.queue|length)==0' "$lr2/ws/state/loop-active.json" >/dev/null 2>&1 \
  && ok "loop restart: ledger persisted on assign (busy w1 <- s1)" \
  || ko "loop restart: ledger missing/wrong ($(cat "$lr2/ws/state/loop-active.json" 2>/dev/null))"
ls "$lr2/ws/memory/slices/current.json.consumed-"* >/dev/null 2>&1 && [ ! -f "$lr2/ws/memory/slices/current.json" ] \
  && ok "loop: PLANNER_ENABLED=0 slices file archived after consumption" \
  || ko "loop: consumed slices file not archived"
grep -qxF -- '- [~] goalX' "$lr2/ws/memory/backlog.md" \
  && ok "loop restart: crashed run leaves the goal marked [~]" \
  || ko "loop restart: goal mark wrong ($(grep goalX "$lr2/ws/memory/backlog.md"))"
# Between runs: tamper the worker's task brief with a sentinel (re-assignment would overwrite
# it) and add an orphan [~] goal (a run that died before assigning — must still be reset).
printf 'SENTINEL-DO-NOT-CLOBBER\n' > "$lr2/ws/state/workers/w1/harness/task.md"
printf -- '- [~] orphan goal\n' >> "$lr2/ws/memory/backlog.md"
# Run 2: the restarted loop must RESTORE (goal + busy w1), not re-plan/re-assign.
out2="$( export LOOP_PROJECT="$lr2/ws" HOME="$lr2/home" CLAUDE_CODE_OAUTH_TOKEN=dummy \
                WORKER_COUNT=1 PLANNER_ENABLED=0 LOOP_POLL_SECS=1 AGENT_UNKNOWN_GRACE=99
         timeout 6 bash "$CTL/loop.sh" 2>&1 )" || true
printf '%s' "$out2" | grep -q 'restored in-flight goal' \
  && ok "loop restart: ledger restored on start" \
  || ko "loop restart: no restore ($(printf '%s' "$out2" | head -3 | tr '\n' ' '))"
if ! printf '%s' "$out2" | grep -qE 'next goal|assign w1'; then
  ok "loop restart: no re-plan / re-assign while the slice is in flight"
else ko "loop restart: re-planned or re-assigned ($(printf '%s' "$out2" | grep -E 'next goal|assign' | head -2 | tr '\n' ' '))"; fi
grep -qxF 'SENTINEL-DO-NOT-CLOBBER' "$lr2/ws/state/workers/w1/harness/task.md" \
  && ok "loop restart: in-flight worker's task.md untouched" \
  || ko "loop restart: task.md was overwritten"
grep -qxF -- '- [~] goalX' "$lr2/ws/memory/backlog.md" && grep -qxF -- '- [ ] orphan goal' "$lr2/ws/memory/backlog.md" \
  && ok "loop restart: restored goal stays [~], orphan goal reset to [ ]" \
  || ko "loop restart: backlog reconciliation wrong ($(grep -E 'goalX|orphan' "$lr2/ws/memory/backlog.md" | tr '\n' ' '))"
rm -rf "$lr2"

echo "== planner + engine wiring (static contracts) =="
grep -q 'ontology/digest.md' "$CTL/plan.sh" \
  && ok "plan.sh: planner reads the ontology digest when present" \
  || ko "plan.sh: digest read missing"
grep -q 'F2P' "$CTL/plan.sh" && grep -q 'P2P' "$CTL/plan.sh" \
  && ok "plan.sh: contract tests carry the F2P/P2P framing" \
  || ko "plan.sh: F2P/P2P framing missing"
# The contract-test commit must be pathspec-scoped: a bare `git commit` sweeps whatever the
# supervisor left staged in canonical (supervise mode runs with cwd=canonical).
grep -qE 'commit -q -m "contract tests[^"]*" -- tests/' "$CTL/plan.sh" \
  && ok "plan.sh: contract-test commit is pathspec-scoped (-- tests/)" \
  || ko "plan.sh: contract-test commit not scoped to tests/"
grep -q 'f2p_preflight "$slices"' "$CTL/plan.sh" \
  && ok "plan.sh: F2P preflight wired before the contract-test commit" \
  || ko "plan.sh: f2p_preflight not wired"
# Fresh assignment resets spent per-slice state (codex budget + verify token): an ESCALATED
# slice never lands, so land.sh's reset alone leaks both into the worker's next slice.
grep -q 'codex_rounds_reset "$TASK"' "$CTL/assign.sh" && grep -q '\.verified' "$CTL/assign.sh" \
  && ok "assign.sh: codex rounds + verify token reset on new assignment" \
  || ko "assign.sh: spent per-slice state leaks across assignments"
# watch.sh: one in-flight gate per task, and codex-only exit 7 is not reported as a gate FAIL.
grep -q 'GATEPID' "$CTL/watch.sh" \
  && ok "watch.sh: per-task in-flight gate guard present" \
  || ko "watch.sh: concurrent verifies on one task possible"
grep -q 'CONCERNS' "$CTL/watch.sh" \
  && ok "watch.sh: exit 7 (codex concerns) reported distinctly from gate FAIL" \
  || ko "watch.sh: exit 7 misreported as FAIL"
# Honest goal completion: all-escalated goals are marked [!], never a silent [x].
grep -q 'GOAL_INCOMPLETE' "$CTL/loop.sh" && grep -q "mark_goal '!'" "$CTL/loop.sh" \
  && ok "loop.sh: all-escalated goal marked [!] (GOAL_INCOMPLETE)" \
  || ko "loop.sh: escalated-only goal still marked [x]"
# Burst gating is the SHARED lib decision in both heartbeats (no drifting copies).
grep -q 'gate_now_decision' "$CTL/loop.sh" && grep -q 'gate_now_decision' "$CTL/watch.sh" \
  && ok "loop.sh + watch.sh: burst gating via shared gate_now_decision" \
  || ko "burst gating still duplicated"
# Worker-pool bring-up is the SHARED lib helper in all three launchers (no drifting copies).
if grep -q 'spawn_pool' "$CTL/loop.sh" && grep -q 'spawn_pool' "$CTL/up.sh" \
   && grep -q 'spawn_pool' "$CTL/supervise.sh" \
   && ! grep -q 'seq 1 "\$WORKER_COUNT".*spawn\.sh' "$CTL/loop.sh" "$CTL/up.sh" "$CTL/supervise.sh"; then
  ok "loop.sh + up.sh + supervise.sh: pool bring-up via shared spawn_pool"
else ko "worker-pool bring-up still duplicated"; fi
grep -q 'F2P' "$CTL/verify.sh" \
  && ok "verify.sh: feedback explains F2P vs P2P failures" \
  || ko "verify.sh: F2P/P2P explanation missing"
grep -q 'not evidence' "$CTL/second-opinion.sh" \
  && ok "second-opinion: judge told to ignore provenance/self-assessment cues" \
  || ko "second-opinion: bias-hygiene instruction missing"
if grep -qi 'another AI wrote' "$CTL/second-opinion.sh"; then
  ko "second-opinion: provenance cue still present in the judge prompt"
else ok "second-opinion: no provenance cue in the judge prompt"; fi
grep -q 'escalation_report' "$CTL/loop.sh" \
  && ok "loop.sh: escalation writes the co-evolution review packet" \
  || ko "loop.sh: escalation_report not wired"
grep -q 'USAGE_DRAIN" = 0 \] && \[ "${#QUEUE\[@\]}" -gt 0' "$CTL/loop.sh" \
  && ok "loop.sh: ASSIGN suspended while draining" \
  || ko "loop.sh: drain does not gate ASSIGN"
grep -q 'usage_pause "worker stall coincides' "$CTL/loop.sh" \
  && ok "loop.sh: watchdog pauses (not respawns) when the window is exhausted" \
  || ko "loop.sh: watchdog usage interception missing"

echo
echo "tests-toolkit: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
