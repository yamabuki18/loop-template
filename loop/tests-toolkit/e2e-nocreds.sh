#!/usr/bin/env bash
# Credential-free end-to-end check of the orchestration plumbing on REAL Docker (no Claude / no
# API key needed). It simulates a worker by committing into the worker container directly via
# `docker exec` (bypassing the worker Claude) and exercises the host-side guarantees:
#   D1  verify.sh FAIL path writes feedback.md   (was dead code)
#   D5  gate exit 4 when the branch touches tests/ (protected)   then land is refused
#   PASS path: gate green -> land merges into base -> D3 base ref propagates to exchanges
# Run AFTER ./control/setup.sh has built the image and created canonical.
#   ./tests-toolkit/e2e-nocreds.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; CTL="$(cd "$HERE/../control" && pwd)"
source "$CTL/lib.sh"
set +e   # lib.sh turns on `set -e`; this test deliberately inspects non-zero exits, so disable it.
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image missing — run ./control/setup.sh"; exit 1; }
[ -d "$CANONICAL/.git" ] || { echo "canonical missing — run ./control/setup.sh"; exit 1; }

# A blocking check in canonical: passes only when src/done.txt exists on the merged result.
mkdir -p "$CANONICAL/harness" "$CANONICAL/tests"
cat > "$CANONICAL/harness/check.sh" <<'EOF'
#!/usr/bin/env bash
set -e
test -f src/done.txt && echo "check: src/done.txt present — OK"
EOF
chmod +x "$CANONICAL/harness/check.sh"
echo "spec" > "$CANONICAL/tests/contract.txt"
# Reset any leftover src/ from a previous e2e land so the FAIL path truly starts without src/done.txt
# (this test mutates canonical; make it idempotent across runs).
rm -rf "$CANONICAL/src"
git -C "$CANONICAL" add -A && git -C "$CANONICAL" commit -q -m "e2e: blocking check + contract test (reset)" || true

echo "== spawn a worker (no Claude attached) =="
"$CTL/spawn.sh" w1 >/dev/null && ok "spawn w1" || ko "spawn w1"
C="$(cname w1)"

wcommit() { docker exec "$C" bash -lc "cd /work && $1 && git add -A && git commit -q -m '$2' && git push -q origin HEAD"; }

echo "== FAIL path (no src/done.txt) -> gate fails, verify writes feedback.md (D1) =="
docker exec "$C" bash -lc 'cd /work && worker-prepare >/dev/null 2>&1' || true
wcommit "mkdir -p src && echo wip > src/app.txt" "wip" >/dev/null 2>&1
"$CTL/verify.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "verify FAIL returns non-zero (rc=$rc)" || ko "verify should have failed"
docker exec "$C" bash -lc 'test -f /work/.harness/feedback.md' && ok "D1: feedback.md written to worker on FAIL" || ko "D1: feedback.md NOT written (dead FAIL path!)"

echo "== D5: touch tests/ -> gate exit 4, land refused =="
wcommit "echo tamper >> tests/contract.txt" "tamper tests" >/dev/null 2>&1
"$CTL/gate.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "D5: gate exits 4 on protected-path change" || ko "D5: expected exit 4, got $rc"
"$CTL/land.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "D5: land refused while tests/ tampered" || ko "D5: land should be refused"

echo "== recover + PASS path -> land merges, base propagates (D3) =="
# Truly revert the tamper to BASE content (checkout from origin/main, not HEAD which holds the
# tamper) so the merge-base diff on tests/ is empty again, then satisfy the check.
docker exec "$C" bash -lc "cd /work && git fetch -q origin && git checkout origin/$BASE_BRANCH -- tests/contract.txt && echo done > src/done.txt && git add -A && git commit -q -m fix && git push -q origin HEAD" >/dev/null 2>&1
"$CTL/verify.sh" w1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "PASS path: gate green after fix" || ko "PASS path: gate still failing (rc=$rc)"
before="$(git -C "$CANONICAL" rev-parse "$BASE_BRANCH")"
"$CTL/land.sh" w1 --no-verify >/dev/null 2>&1 && ok "land merged into $BASE_BRANCH" || ko "land failed"
after="$(git -C "$CANONICAL" rev-parse "$BASE_BRANCH")"
[ "$before" != "$after" ] && ok "base advanced after land" || ko "base did not advance"
ex_base="$(git -C "$EXCHANGE_DIR/w1.git" rev-parse "$BASE_BRANCH" 2>/dev/null || echo none)"
[ "$ex_base" = "$after" ] && ok "D3: new base propagated to w1 exchange" || ko "D3: exchange base stale ($ex_base vs $after)"

echo
echo "e2e-nocreds: $pass passed, $fail failed.  (cleanup: ./control/down.sh --purge)"
[ "$fail" -eq 0 ]
