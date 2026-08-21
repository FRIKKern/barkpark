# D8 re-derivation recipe — denial status is a RESOURCE-TIER question, not a caller-tier one

Baseline: origin/main `a07a0baa138d628987706e94a31329379410f23a` (charter's pinned `6f724edfd8` is stale).
All commands run from repo root. `grep` on this host is a ugrep wrapper that honours ignore-files —
use `/usr/bin/grep` or counts undercount.

## R1 — the two census numbers the assignment demanded
    cd api && /usr/bin/grep -rn 'existence-hiding\|existence oracle' lib/ | wc -l      # 32
    cd api && /usr/bin/grep -rn 'put_status(:not_found)\|put_status(404)' lib/barkpark_web | wc -l   # 30
Neither number is the population D8 governs. Split them:
    cd api && /usr/bin/grep -rn 'existence-hiding\|existence oracle' lib/
12 of the 32 are in capabilities.ex / capabilities_controller.ex / openapi.ex / tickets/cli.ex /
router.ex:1657 and concern MANIFEST VERB PROJECTION, not an HTTP status. The HTTP-404-as-read-denial
population with an explicit written rationale is 7 endpoints, not 29.

## R2 — the candidate discriminator ("valid token -> 403") is refuted by production code
    cd api && sed -n '664,681p' lib/barkpark_web/controllers/query_controller.ex
    cd api && sed -n '131,146p' lib/barkpark_web/plugs/public_read.ex
Both deliberately 404 a caller holding a VALID token (the public-read tier). public_read.ex's own
moduledoc (`sed -n '44,58p'`) names the leak that mount closed: 52,208,330 bytes / 2,500 documents.

## R3 — the live in-repo policy split (same question, two answers)
    cd api && sed -n '882,912p' lib/barkpark_web/controllers/workspace_controller.ex   # non-member -> 404
    cd api && sed -n '116,135p'  lib/barkpark_web/plugs/resolve_workspace.ex           # non-member -> 403
    cd api && /usr/bin/grep -n 'WorkspaceController' lib/barkpark_web/router.ex
Flat `/api/workspaces/*` rides `[:api, :require_token]` (no ResolveWorkspace); scoped `/w/:ws/*`
rides ResolveWorkspace. Identical predicate (`member?`), opposite status.

## R4 — the access-grant oracle is PINNED GREEN by test
    cd api && sed -n '185,200p' test/barkpark_web/controllers/access_controller_test.exs
    cd api && BARKPARK_TEST_POOL_SIZE=4 mix test test/barkpark_web/controllers/access_controller_test.exs
    # => 17 tests, 0 failures
Foreign grant id -> 403, missing id -> 404, both asserted. Task
`arpss-w8-bl-access-grant-id-existence-oracle` cannot land without flipping a green test.

## R5 — the assigned MUST-RUN cites a file that does not exist
    ls api/test/barkpark_web/plugs/resolve_workspace_test.exs   # No such file or directory
ResolveWorkspace has no dedicated test module; its behaviour is covered indirectly
(`/usr/bin/grep -rl ResolveWorkspace api/test/`).

## R6 — host hazard
Local Postgres saturates under fleet load: `FATAL 53300 too_many_connections`, and `mix test`
then dies with "Could not start application barkpark ... killed". Retry with
`BARKPARK_TEST_POOL_SIZE=4`; a red here is the HOST, not the tree.

## The rule this recipe supports
TIER A (scope containers named in the path: workspace, project, dataset) — unknown name 404,
known name + denied 403.  TIER B (resources addressed by an id/name inside a scope: document,
revision, tag, type, secret, share link, access grant, support token, media) — 404 always,
every caller tier.  TIER C (capability/route/perspective refusals naming no resource) — 403.
D8 as written ("never, anywhere") converts Tier B into an oracle and must be narrowed to Tier A.
