# host-harness — optional secret guard for an interactive host supervisor

**You probably don't need this.** In the autonomous design the LOOP itself runs no Claude —
only deterministic bash (`loop.sh`, `watch.sh`, …) does, and secrets stay sops-encrypted on
disk, decrypted only into the single process that consumes them (`secret_exec`). The v3
WORKERS do run on the host, but they carry their own mandatory guard
(`worker-harness/harness-guard-secrets`).

Use this **only** if you deliberately keep an interactive supervisor Claude open in the project
root (e.g. for brainstorming goals). Then these hooks add a second, best-effort layer that
blocks the obvious leaks:

- reading/editing `secret.*env` files (encrypted or not) and age key material
- `env` / `printenv` dumps that mention `ANTHROPIC` / `API_KEY` / `OAUTH` / `secret`
- any reference to credential variable names

## Install

Merge `host-harness/settings.json`'s `hooks` block into your project `.claude/settings.json`
(or run `./control/scaffold.sh --install-host-guard`). `$CLAUDE_PROJECT_DIR` resolves to the
project root at hook time.

## Limit

This is **best-effort**, not a guarantee — a capable agent has side channels (`/proc/self/environ`,
crafted scripts, etc.). The real boundaries are the ones the template enforces structurally:
secrets encrypted at rest, per-scope injection, and gate/codex secrets never entering any
Claude process. Treat this hook as a seatbelt, not a vault.
