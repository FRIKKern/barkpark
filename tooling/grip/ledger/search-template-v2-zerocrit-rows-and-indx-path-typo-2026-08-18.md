<!-- doc-tier: cold | canonical-for: none | budget: 1200tok -->
# Search-Template audit V2 — 0/None-criteria rows + indx path-typo landmine (2026-08-18)

Re-derivation recipes for the three risk-cohort rows and the `search/`-vs-`plugins/indx/` path trap.
All commands anchor on **origin/main @ e21bf40**, never the local checkout.

## Verdict: false-done = 0 across all three rows. No row needs a path-typo correction note.

## task-03a92ad1e8ecf5e5 — SR-2 indx visibility clamp (W12 reconcile-close, 0 criteria)

Close rests on 7 tests + #6271. Both verified by CONTENT, not count:

    # #6271 (read-path clamp) landed:
    gh pr view 6271 --repo FRIKKern/barkpark --json mergeCommit -q .mergeCommit.oid
    #   -> 45fa86ebdd0802396a9a75adb09b48a4d8bac8bc
    git merge-base --is-ancestor 45fa86ebdd0802396a9a75adb09b48a4d8bac8bc origin/main  # exit 0 = ancestor

    # The WRITE-side clamp SOURCE (makes engine=indx bypass moot: private types never enter the index):
    git grep -nE 'non_public_type|indexed_types|schema_public\?' origin/main -- api/lib/barkpark/plugins/indx/
    #   indexer_worker.ex:322  type not in indexed_types(scope, args) -> ... :328  {:cancel, :non_public_type}
    #   indexer_worker.ex:491  |> Enum.filter(&schema_public?/1)
    #   indexer_worker.ex:515  defp schema_public?(%{visibility: v}), do: v == "public"   (:517 fail-closed -> false)

    # The 7 tests ASSERT the clamp (public passes, private/schemaless refused, lifecycle enqueues nothing):
    git show origin/main:api/test/barkpark/plugins/indx/indexer_upsert_visibility_test.exs | grep -nE 'test |assert|refute'
    #   :65 PUBLIC upsert passes -> assert :ok / assert_receive upserted
    #   :79 PRIVATE upsert refused -> assert {:cancel,:non_public_type} / refute_receive
    #   :93 SCHEMALESS refused (allowlist not denylist) -> {:cancel,:non_public_type} / refute_receive
    #   :150 PUBLIC save enqueues; :159 PRIVATE save enqueues NOTHING (all_enqueued==[]);
    #   :165 unresolvable type -> safe REBUILD; :177 flag OFF -> today's REBUILD routing

The close_reason cites the CORRECT path `api/test/barkpark/plugins/indx/indexer_upsert_visibility_test.exs`. TRUE.

## task-90266ebb72f45340 — undici drop (w9-lead close)

    gh pr view 6238 --repo FRIKKern/barkpark --json mergeCommit -q .mergeCommit.oid  # 51dd7c8c7469...
    git merge-base --is-ancestor 51dd7c8c74691989d02af9fb68a97dae5e66a569 origin/main   # ancestor
    git show origin/main:templates/search-starter/package.json      | grep undici   # "undici": "^8.5.0"
    git show origin/main:templates/search-starter/next.config.mjs   | grep undici   # serverExternalPackages: ['undici']
    git show origin/main:templates/search-starter/lib/bp-fetch.ts   | grep undici   # import { Agent, fetch } from "undici"

MODULE_NOT_FOUND fix delivered as behavior (dep + external + real import). TRUE.

## task-8cea4ccd13d2317c — astro rail-split (w10-lead close)

Close_reason cites `FinderIsland gained variant=rail`. On origin/main the composition EVOLVED to
`variant="master"` + slot-driven split via the LATER slice stw7-backlog-astro-graph-landing-reintegrate.
`variant="rail"` survives only in a stale COMMENT — superseded-but-landed, NOT false-done.
The rail-split BEHAVIOR persists:

    gh pr view 6333 --repo FRIKKern/barkpark --json mergeCommit -q .mergeCommit.oid  # 90ba3dc...  (ancestor)
    git show origin/main:templates/astro-search-starter/src/components/FinderIsland.tsx | grep -nE 'aside|railClass|variant|slot'
    #   :340 railClass = slot ? w-full : hidden md:block   (document page -> rail steps aside, doc owns pane)
    #   :346 <aside className=h-screen ${railClass}>{finder}</aside>  + createPortal(GraphPane, slot)
    git show 'origin/main:templates/astro-search-starter/src/pages/d/[type]/[slug].astro' | grep -n FinderIsland
    #   :59 <FinderIsland client:only="react" transition:persist="finder-rail" />   (persisted rail across nav)

TRUE.

## Path-typo landmine — search/ vs plugins/indx/

BOTH dirs exist on origin/main; the trap is the FILENAME, not the dir:

    git ls-tree origin/main api/test/barkpark/search/ | grep visibility
    #   -> documents_retriever_visibility_test.exs  (READ-path #6271 clamp — EXISTS at search/)
    git cat-file -e origin/main:api/test/barkpark/search/indexer_upsert_visibility_test.exs   # exit 128 = ABSENT
    git cat-file -e origin/main:api/test/barkpark/plugins/indx/indexer_upsert_visibility_test.exs  # exit 0 = present

An auditor typing `search/indexer_upsert_visibility_test.exs` gets "absent" and could manufacture a reopen.
NO DONE ROW cites the typo path: task-03a92ad1's close_reason uses the correct `plugins/indx/` path;
the charter and tooling/grip/ledger/ contain neither string; the undici and astro rows never reference this test.
Therefore: ZERO back-filled correction notes required. This note IS the future-auditor warning.
