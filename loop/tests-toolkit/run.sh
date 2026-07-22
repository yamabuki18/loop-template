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
grep -q 'decompose THAT plan faithfully' "$CTL/plan.sh" \
  && ok "plan.sh: planner instructed to honor referenced plans (no re-planning)" \
  || ko "plan.sh: handoff instruction missing from the planner prompt"
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

echo "== lib: secret_exec (scoped injection, backend contract) =="
ws="$(mktemp -d)"; touch "$ws/.loop-workspace"
bin="$(mktemp -d)"
# Fake sops: mimics `sops exec-env <file> <one-command-string>` — sources the dotenv file
# (our fixture is plain text) into the child env and runs the command via sh -c.
cat > "$bin/sops" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_SOPS_LOG:-/dev/null}"
if [ "$1" = "exec-env" ]; then
  f="$2"; cmd="$3"
  set -a; . "$f"; set +a
  exec sh -c "$cmd"
fi
exit 0
SHIM
chmod +x "$bin/sops"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok123\nANTHROPIC_API_KEY=key456\n' > "$ws/secret.worker.sops.env"
export FAKE_SOPS_LOG="$ws/sops.log"
outv="$( (export LOOP_PROJECT="$ws" PATH="$bin:$PATH"
          source "$CTL/lib.sh"
          secret_exec worker -- sh -c 'echo "${ANTHROPIC_API_KEY:-EMPTY}:${CLAUDE_CODE_OAUTH_TOKEN:-EMPTY}"') 2>/dev/null )"
if [ "$outv" = "EMPTY:tok123" ]; then
  ok "secret_exec worker: OAuth precedence strips ANTHROPIC_API_KEY in the child env"
else ko "secret_exec precedence: got '$outv' (want EMPTY:tok123)"; fi
grep -q "exec-env $ws/secret.worker.sops.env" "$FAKE_SOPS_LOG" \
  && ok "secret_exec routes through 'sops exec-env <file> <one-string>'" \
  || ko "secret_exec: sops argv wrong ($(cat "$FAKE_SOPS_LOG" 2>/dev/null))"
: > "$FAKE_SOPS_LOG"
outv="$( (export LOOP_PROJECT="$ws" PATH="$bin:$PATH"; source "$CTL/lib.sh"; secret_exec gate -- echo bare-ok) 2>/dev/null )"
if [ "$outv" = "bare-ok" ] && [ ! -s "$FAKE_SOPS_LOG" ]; then
  ok "secret_exec: missing scope file runs the command bare (no sops call)"
else ko "secret_exec bare: got '$outv' (sops log: $(cat "$FAKE_SOPS_LOG" 2>/dev/null))"; fi
# quoting robustness: args with spaces/quotes must survive the single-string contract
outv="$( (export LOOP_PROJECT="$ws" PATH="$bin:$PATH"; source "$CTL/lib.sh"
          secret_exec worker -- printf '%s|%s' "two words" "it's quoted") 2>/dev/null )"
[ "$outv" = "two words|it's quoted" ] \
  && ok "secret_exec: shell_quote preserves spaces and quotes" \
  || ko "secret_exec quoting: got '$outv'"
# plain backend
printf 'GATE_TOKEN=g789\n' > "$ws/secret.gate.env"
outv="$( (export LOOP_PROJECT="$ws" SECRET_BACKEND=plain; source "$CTL/lib.sh"
          secret_exec gate -- sh -c 'echo "${GATE_TOKEN:-EMPTY}"') 2>/dev/null )"
[ "$outv" = "g789" ] && ok "secret_exec plain backend injects the scope env" || ko "secret_exec plain: got '$outv'"
# auth_mode probes without leaking (fake sops again)
outv="$( (export LOOP_PROJECT="$ws" PATH="$bin:$PATH"; source "$CTL/lib.sh"; auth_mode) 2>/dev/null )"
[ "$outv" = "subscription" ] && ok "auth_mode: subscription detected via probe (no value printed)" || ko "auth_mode: got '$outv'"

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

echo "== planner + engine wiring (static contracts) =="
grep -q 'ontology/digest.md' "$CTL/plan.sh" \
  && ok "plan.sh: planner reads the ontology digest when present" \
  || ko "plan.sh: digest read missing"
grep -q 'F2P' "$CTL/plan.sh" && grep -q 'P2P' "$CTL/plan.sh" \
  && ok "plan.sh: contract tests carry the F2P/P2P framing" \
  || ko "plan.sh: F2P/P2P framing missing"
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

echo
echo "tests-toolkit: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
