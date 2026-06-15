# Work board  (maintained by the supervisor)

BASE_BRANCH: main

## Ownership — who may edit what, THIS cycle
| worker | owned paths (globs)             | task                | status      |
|--------|---------------------------------|---------------------|-------------|
| w1     | `src/featureA/**`               | <describe>          | in-progress |
| w2     | `src/featureB/**`               | <describe>          | idle        |
| w3     | `src/featureC/**`, `docs/**`    | <describe>          | in-progress |

## Shared files — single-owner or contract-first this cycle
- `package.json` + lockfile   — owner: w1 (others request via supervisor)
- `src/types/index.ts`        — owner: supervisor (land contract first)

## Backlog — unassigned, not yet started
- [ ] ...
- [ ] ...

## Landed
- (none yet)
