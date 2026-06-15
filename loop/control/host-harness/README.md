# host-harness — optional secret guard for an interactive host supervisor

**You probably don't need this.** The template's concealment of credentials (goal #3) is
*structural*: in the autonomous design **no Claude runs on the host** — only deterministic bash
(`loop.sh`, `watch.sh`, …) does, and it passes a *disposable* worker key into isolated
containers. There is no host-side Claude process to read your secrets, so there is nothing to
guard.

Use this **only** if you deliberately keep an interactive supervisor Claude open in the project
root (e.g. for brainstorming goals). Then these hooks add a second, best-effort layer that
blocks the obvious leaks:

- reading/editing `control/secret.env`
- `env` / `printenv` dumps that mention `ANTHROPIC` / `API_KEY` / `secret`
- any reference to `ANTHROPIC_API_KEY`
- `docker inspect` (which can print a container's env, i.e. the key)

## Install

Merge `host-harness/settings.json`'s `hooks` block into your project `.claude/settings.json`
(or run `./control/scaffold.sh --install-host-guard`). `$CLAUDE_PROJECT_DIR` resolves to the
project root at hook time.

## Limit

This is **best-effort**, not a guarantee — a capable agent has side channels (`/proc/self/environ`,
crafted scripts, etc.). The only real boundary is the one the template already enforces:
**credentials never enter a Claude-readable process.** Keep it that way; treat this hook as a
seatbelt, not a vault.
