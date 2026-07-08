#!/usr/bin/env bash
# Credential-free end-to-end check of the orchestration plumbing — v3 needs NO Docker and NO
# herdr server, so this runs in CI. It simulates a worker by committing into the worker's
# worktree directly (bypassing the worker Claude) and exercises the host-side guarantees:
#   D1  verify.sh FAIL path writes feedback.md   (was dead code)
#   D5  gate exit 4 when the branch touches tests/ (protected)   then land is refused
#   PASS path: gate green -> land merges into base -> other workers rebase (sync.sh)
# Fully self-contained: builds its own throwaway workspace + canonical, redirects $HOME so no
# real credential/key is ever touched.
#   ./tests-toolkit/e2e-nocreds.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; CTL="$(cd "$HERE/../control" && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Hermetic sandbox: fresh workspace, fake HOME (no host creds/keys), no herdr, no codex.
# The failing `herdr` shim shadows any real binary so the test can NEVER touch a live server.
SBX="$(mktemp -d)"
export LOOP_PROJECT="$SBX/ws" HOME="$SBX/home"
export SECOND_OPINION=off NOTIFY=0
mkdir -p "$SBX/ws" "$SBX/home" "$SBX/bin"
printf '#!/bin/sh\nexit 1\n' > "$SBX/bin/herdr"; chmod +x "$SBX/bin/herdr"
export PATH="$SBX/bin:$PATH"
touch "$SBX/ws/.loop-workspace"
git config --global user.email e2e@loop.local
git config --global user.name  e2e
trap 'rm -rf "$SBX"' EXIT

source "$CTL/lib.sh"
set +e   # lib.sh turns on `set -e`; this test deliberately inspects non-zero exits.

# Canonical with a BLOCKING check: passes only when src/done.txt exists on the merged result.
mkdir -p "$CANONICAL/harness" "$CANONICAL/tests"
git -C "$CANONICAL" init -q -b "$BASE_BRANCH"
cat > "$CANONICAL/harness/check.sh" <<'EOF'
#!/usr/bin/env bash
set -e
test -f src/done.txt && echo "check: src/done.txt present — OK"
EOF
chmod +x "$CANONICAL/harness/check.sh"
echo "spec" > "$CANONICAL/tests/contract.txt"
git -C "$CANONICAL" add -A && git -C "$CANONICAL" commit -qm "base: blocking check + contract test"

echo "== spawn workers (no Claude, no herdr) =="
"$CTL/spawn.sh" w1 >/dev/null 2>&1 && ok "spawn w1" || ko "spawn w1"
"$CTL/spawn.sh" w2 >/dev/null 2>&1 && ok "spawn w2" || ko "spawn w2"
W1="$(worktree_for w1)"
[ -e "$W1/.git" ] && ok "w1 worktree materialized" || ko "w1 worktree missing"
[ -f "$STATE_DIR/w1.env" ] && ok "w1 state recorded" || ko "w1 state missing"

wcommit() { ( cd "$W1" && eval "$1" && git add -A && git commit -q -m "$2" ); }

echo "== FAIL path (no src/done.txt) -> gate fails, verify writes feedback.md (D1) =="
wcommit "mkdir -p src && echo wip > src/app.txt" "wip" >/dev/null 2>&1
"$CTL/verify.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "verify FAIL returns non-zero (rc=$rc)" || ko "verify should have failed"
[ -f "$(harness_dir w1)/feedback.md" ] && ok "D1: feedback.md written to worker state on FAIL" || ko "D1: feedback.md NOT written (dead FAIL path!)"

echo "== D5: touch tests/ -> gate exit 4, land refused =="
wcommit "echo tamper >> tests/contract.txt" "tamper tests" >/dev/null 2>&1
"$CTL/gate.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "D5: gate exits 4 on protected-path change" || ko "D5: expected exit 4, got $rc"
"$CTL/land.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "D5: land refused while tests/ tampered" || ko "D5: land should be refused"

echo "== recover + PASS path -> land merges, others rebase =="
# Truly revert the tamper to BASE content (checkout the FILE from base — allowed; only branch
# checkout of base is structurally blocked) so the merge-base diff on tests/ is empty again.
( cd "$W1" && git checkout "$BASE_BRANCH" -- tests/contract.txt \
  && echo done > src/done.txt && git add -A && git commit -qm fix ) >/dev/null 2>&1
"$CTL/verify.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "PASS path: gate green after fix" || ko "PASS path: gate still failing (rc=$rc)"
before="$(git -C "$CANONICAL" rev-parse "$BASE_BRANCH")"
"$CTL/land.sh" w1 --no-verify >/dev/null 2>&1 && ok "land merged into $BASE_BRANCH" || ko "land failed"
after="$(git -C "$CANONICAL" rev-parse "$BASE_BRANCH")"
[ "$before" != "$after" ] && ok "base advanced after land" || ko "base did not advance"
# gate worktrees must not leak
n_gate="$(ls -d "$STATE_DIR"/gate/*/ 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_gate" = 0 ] && ok "gate worktrees cleaned up" || ko "gate worktrees leaked ($n_gate)"

"$CTL/sync.sh" --others w1 >/dev/null 2>&1; rc=$?
w2_sha="$(git -C "$CANONICAL" rev-parse "work/w2" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$w2_sha" = "$after" ]; then
  ok "sync: w2 rebased onto the new base (shared refs, no exchange)"
else
  ko "sync: w2 not on new base (rc=$rc, w2=$w2_sha, base=$after)"
fi

echo "== structural: worker cannot check out the base branch =="
if ( cd "$W1" && git checkout "$BASE_BRANCH" ) >/dev/null 2>&1; then
  ko "worker checked out base (structural wall broken!)"
else
  ok "base checkout refused inside a worker worktree"
fi

echo "== reap: worker teardown leaves canonical intact =="
"$CTL/reap.sh" w2 >/dev/null 2>&1
if [ ! -e "$(worktree_for w2)" ] && [ ! -f "$STATE_DIR/w2.env" ] \
   && git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
  ok "reap w2: worktree+state gone, canonical intact"
else
  ko "reap w2 left debris or damaged canonical"
fi

echo
echo "e2e-nocreds: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
