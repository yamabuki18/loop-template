# Supervisor — task allocation playbook (3 fixed workers: w1, w2, w3)

You (with the human) own decomposition, assignment, **running the tests**, and integration.
Workers never merge/rebase, and never run the test suite — they implement and fix only.

Roles:
- **Supervisor (you + human):** 壁打ち / decompose & assign → workers return branches →
  `verify.sh wN` runs the tests → on failure the result is routed back to the worker to fix
  → on pass, `land.sh wN` merges.
- **Worker:** implementation and fixes only. Reacts to `/work/.harness/feedback.md`.

The loop, concretely:
1. Assign work (and ownership domain) to each worker.
2. Worker implements, commits (auto-pushes).
3. `./control/verify.sh wN` — supervisor runs the acceptance tests on the pushed branch.
   - FAIL → failures are written to the worker as feedback; the worker fixes and re-pushes.
     Re-run `verify.sh wN`.
   - PASS → `./control/land.sh wN`.
4. After landing, rebase the other live workers onto the new base.

## Objective, in priority order
1. **Zero merge conflicts.**
2. **Keep all three workers busy.**
Conflicts cost far more than brief idle time — bias toward clean partitions even if a
worker has to wait a little.

## 1. Decompose by VERTICAL slices, not horizontal
- Good: `w1 = feature A` (its own dir), `w2 = feature B`, `w3 = feature C`. Disjoint paths.
- Bad: `w1 = all tests`, `w2 = all styling`, `w3 = all refactors` — these touch the same
  files, so conflicts are guaranteed.

## 2. Assign an OWNERSHIP DOMAIN per worker
- Give each worker a set of path globs it **exclusively** edits this cycle. Record it in
  `board.md`. Two workers must never edit the same file concurrently.

## 3. Handle cross-cutting files deliberately (they are conflict magnets)
Examples: `package.json` / lockfiles, central type/index files, routing tables, DB
schema / migrations.
- **Contract-first:** make the shared edit yourself as a tiny change, land it first, then
  fan out the work that builds on it.
- **Single-owner:** one worker owns the shared file this cycle; the others request changes
  through you. Never let two workers edit a lockfile or manifest in parallel.

## 4. Dependencies between tasks
- If B needs A's interface: define the contract (types / stubs / signatures) up front,
  land that tiny contract, then run A and B in parallel against it.
- Otherwise sequence: land A, rebase B onto the new base, continue.

## 5. Schedule the 3 fixed slots
- Keep a backlog in `board.md`. When a worker reports `...DONE` in its STATUS, assign the
  next task in its domain. If its domain is empty, give it a backlog item that does not
  overlap the other two.
- After each land: `./control/land.sh wN`, then rebase the other live workers onto the new
  base (land.sh prints the command), then re-check overlap.

## 6. Use the instruments every cycle
- Before assigning new work AND before landing: run `./control/overlap.sh`.
  Any flagged file is an imminent conflict — resolve the partition (narrow a scope,
  reassign, or land one branch first and rebase the rest) before it bites.
- `./control/status.sh` shows who is busy / idle / DONE.

## 7. Landing order
- Land the branch that touches shared / foundational files first, then rebase others.
- When unsure, land the smallest / lowest-risk branch first.

## 8. The harness — absolute rules vs per-task instruction
Rules split into two kinds. Keep them in the right layer:
- **Absolute (harness, deterministic):** baked into the worker image as hooks, so they
  fire on every tool call regardless of context — you never restate them.
  - integration ops (merge/rebase/cherry-pick), protected-branch / force pushes → blocked
  - edits outside the worker's ownership domain → blocked
  - read isolation (container, no host mounts) and protected-branch push (pre-receive)
- **Per-task (prompt, variable):** WHAT to build. This is the only thing you relay each time.

Declare each worker's domain so the edit-guard can enforce the vertical-slice partition:
```
./control/assign.sh w1 src/featureA/ docs/featureA/
```
After this, w1's harness rejects edits outside those prefixes — the partition becomes an
enforced invariant, not a hope. Re-run after reassigning a worker to a new area.

## 9. Grow the harness (escalation ladder)
Don't make everything absolute on day one. Start project-specific style/naming rules as
guidance in `CLAUDE.worker.md` (advisory). When a rule keeps getting violated, promote it:
add a PreToolUse guard (deterministic block) or a structural test that fails on violation.
Promote based on violation frequency + how mechanically detectable it is. The harness
itself needs upkeep — prune rules that no longer earn their keep.

## 10. The acceptance gate (ladder L3/L4) — supervisor runs the tests
You run the tests, not the workers. `verify.sh` (and `land.sh`) spin up a CLEAN throwaway
container, trial-merge the worker branch into the base, and run the project's checks on the
result. Workers never execute the suite — they only receive failures and fix them.
- `./control/verify.sh wN` — the loop command. PASS → land it. FAIL → the failure log is
  written to the worker (`/work/.harness/feedback.md`) and the worker is nudged to fix.
- `./control/land.sh wN` — gated merge (re-runs the gate as a final guard). `--no-verify` to
  override (you are the trusted party; use sparingly).
- Make checks real: commit `harness/check.sh` to the repo (template
  `control/harness-check.sample.sh`) or set `CHECK_CMD` in `control/config.env`.

## 11. Test strategy — thin contract-first, pipelined per slice
You own and run the tests, but you do NOT write the whole suite up front (that would serialize
the workers). Split tests by layer and hand each slice off as soon as its contract is ready:
- **Acceptance / contract tests** — YOU author, thin, per slice. This is roughly the effort of
  a sharp task spec, and it *is* the assignment ("make these pass"). Live under `tests/`
  (supervisor-owned; the harness blocks all workers from editing it).
- **Unit tests** — the WORKER writes, co-located inside its own `src/<slice>/` area.
- **Integration / cross-cutting tests** — YOU author (they touch shared surfaces).

Pipeline, don't batch. Write w1's contract → `assign.sh w1 --brief "..." src/featureA/`
(declares the domain, hands the brief, pings the worker to start) → w1 begins. Then write
w2's contract and assign w2, etc. Parallelism starts at the FIRST contract, not after a
monolithic test-writing phase. The serial part is only "define this slice's contract" — the
decomposition you do anyway. Workers can't lower the bar: they don't own the acceptance tests,
and you run them.
