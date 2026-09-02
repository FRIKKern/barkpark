<!-- doc-tier: cold | canonical-for: connectors-audit-two-lane-content-and-prior-rederivation | budget: 2000tok -->
# Connectors done-set audit — two-lane content + prior false-done re-derivation (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

VERIFIER lane `two-lane-content-and-prior`. origin/main = e21bf409893d9de66542a31b06716e3c33d8f102.
Verdict: 6/6 rows TRUE-DONE, content landed in BOTH directions; the 4 non-ancestor SHAs are branch-tip/pre-squash commits whose content is on origin/main — correctly NOT reopens. Zero false-done in this lane.

## Re-run recipe (each command re-derives one fact)

```
# scaffold-reconcile: exactly ONE package.json/lock + PROVISIONAL header gone
git ls-tree -r --name-only origin/main connectors/ | grep -E 'package(-lock)?\.json$' | grep -v node_modules
#   => connectors/package-lock.json, connectors/package.json  (single copy each)
git grep -in PROVISIONAL origin/main -- 'connectors/src/chat-client/*'   # exit 1, no hits

# encrypt-install-credentials: AAD binds provider+installKey+workspaceId
git grep -n setAAD origin/main -- connectors/src/crypto/credential-cipher.ts   # 3 hits incl setAAD(credentialAad(...))
git show origin/main:connectors/src/crypto/credential-cipher.ts | sed -n '179,192p'   # tuple [provider, installKey, workspaceId]

# bp search verb (task-e647694737fd7436)
bp search query connectors    # exit 0, count 404
grep -nE 'D166|D175' <(git show origin/main:.claude/workflows/bp-connectors-charter.md)   # both present

# land-w17-wavelog-orphan: W17-5 STALLED block reachable on origin/main charter
grep -nE 'W17-5|STALLED: W17' <(git show origin/main:.claude/workflows/bp-connectors-charter.md)   # lines 861,882

# vitest v4 major bump
git show origin/main:connectors/package.json | grep vitest    # "vitest": "^4.1.10"

# p3-slack: PR #3174 squash-merge ancestor + single-import registration
gh pr view 3174 --repo FRIKKern/barkpark --json state,mergeCommit   # MERGED, oid 02c28b7a880fe746...
git merge-base --is-ancestor 02c28b7a880fe746e2df9d60e1b80238c0dc49a6 origin/main   # exit 0
git grep -n createSlackConnector origin/main -- connectors/src/index.ts   # :43 import, :175 single register

# the 4 non-ancestor SHAs — NOT reopens (branch-tip/pre-squash, content landed)
for s in d21e3d85a 6f3439528 a95ad8d78; do git merge-base --is-ancestor $s origin/main; echo "$s exit=$?"; done  # all exit 1
#   6f3439528 = W4-1 AAD seal  -> setAAD present on main
#   a95ad8d78 = W19 DECIDE     -> W17 STALLED block present in charter
#   d21e3d85a = W3-3 turn tests-> connectors/test/turn-loop.test.ts present on main
git cat-file -e origin/main:connectors/test/turn-loop.test.ts && echo present
```
