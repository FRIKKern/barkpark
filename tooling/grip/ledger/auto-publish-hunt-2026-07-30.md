# Re-derivation recipes — auto-publish hunt (PDS wave 26, 2026-07-30)

Verifier lane `auto-publish-hunt`: does ANYTHING publish a task's `drafts.` twin
without a human typing `bp doc publish`, and can that publish erase a landed
`bp task stamp`? Everything below reads `origin/main` (3693f2541) or runs the
Elixir suite from `api/` with `CC=clang MIX_ENV=test` (the `cc` alias shadows the
compiler on this host).

The probe file referenced by rows 6-7 is NOT in the repo (verifier carve-out) —
it lives at
`$SCRATCH/autopublish_revert_test.exs`; row 7 quotes its output. A builder
should re-author it as a real regression test under
`api/test/barkpark/content/` when the fix lands.

| # | Claim | Command |
|---|---|---|
| 1 | `publish_document/4` has exactly SIX real call sites on origin/main: content.ex (delegate), lifecycle.ex (def), mutations.ex:203 (the `publish` mutation), papers/value_writeback.ex:312, plugins/github/adopt.ex:178, plugins/github/link.ex:193, studio handlers/doc.ex:34 + shared.ex:491 | `for f in $(git ls-tree -r --name-only origin/main api/lib \| grep '\.ex$'); do git show origin/main:$f \| grep -n 'publish_document(' \| sed "s\|^\|$f:\|"; done \| grep -v unpublish` |
| 2 | `github/projection.ex` NEVER publishes — it only reads `acceptance_criteria` to build the issue body | `git show origin/main:api/lib/barkpark/plugins/github/projection.ex \| grep -n 'publish\|acceptance_criteria'` |
| 3 | `Link.put/4` is called by the BACKGROUND MirrorJob (mirror_job.ex:560, enqueued by the DrainWorker GenServer) and by the inbound WEBHOOK detach path (inbound_events.ex:172) — neither has a human in the loop | `for f in $(git ls-tree -r --name-only origin/main api/lib \| grep '\.ex$'); do git show origin/main:$f \| grep -n 'Link\.put(' \| sed "s\|^\|$f:\|"; done` |
| 4 | `Link.put` merges DRAFT-FIRST (`fetch_task/3`) and then republishes that draft wholesale over the published row when a published row existed | `git show origin/main:api/lib/barkpark/plugins/github/link.ex \| sed -n '120,152p;226,236p'` |
| 5 | The task rail (stamp/claim/close/pulse/release/ttl_sweeper/compactor) writes rows with raw `Repo.update_all` — it never touches the `drafts.` twin, so the twin goes stale the moment a stamp lands | `for f in $(git ls-tree -r --name-only origin/main api/lib/barkpark/tasks/); do git show origin/main:$f \| grep -n 'Repo.update_all' \| sed "s\|^\|$f:\|"; done` |
| 6 | The publish door's stale-draft guard keys ONLY on `lifecycle_status` legality and on the published row's `claim` map differing from the draft's (`stale_claim?/2`); a stamp writes criteria and rev ONLY, never the claim — so a draft minted AFTER the claim passes the guard with stale criteria | `git show origin/main:api/lib/barkpark/content/lifecycle.ex \| sed -n '296,316p'` |
| 7 | OBSERVED end-to-end: published+claimed task, draft minted from current published content, stamp lands `met:true` on the published row, then an automatic `Link.put` collapse publishes → published row reads `met:false, evidence:""` and the publish returns `{:ok, _}` with NO warning | `cd api && CC=clang MIX_ENV=test mix test $SCRATCH/autopublish_revert_test.exs` |
| 8 | The SAME probe with the draft minted BEFORE the claim is REFUSED (`{:invalid_task_content, %{"claim" => ["stale draft: …"]}}`) — the guard exists and works, its blind spot is claim-identical drafts only | same as #7 with the `upsert_document` call moved above `Tasks.claim_by_id` |
| 9 | The github plugin's routes ARE mounted on guerrilla (`POST /v1/plugins/github/webhook` → 401 signature-refused, not 404) — the plugin is whitelisted there, so `register_workers` supervises Auth + (config-gated) DrainWorker | `for p in /v1/github/webhook /webhooks/github /v1/plugins/github/webhook; do printf "%s " $p; curl -s -m 10 -o /dev/null -w '%{http_code}\n' -X POST https://guerrilla.barkpark.cloud$p; done` |
| 10 | No `github` verb appears in guerrilla's published capabilities manifest (0 matches in 12 kB) — the CLI surface is dark even though the route is mounted | `curl -s https://guerrilla.barkpark.cloud/v1/capabilities \| grep -c -i github` |
| 11 | `Sync.Pusher` (pusher.ex:329) and `Sync.Applier` (applier.ex:189) also emit `%{"publish" => …}` mutations automatically — the cross-instance sync engine is a THIRD automatic publisher, exempted from the publish-door gate entirely by `source: :sync` | `for f in $(git ls-tree -r --name-only origin/main api/lib \| grep '\.ex$'); do git show origin/main:$f \| grep -n '"publish" =>' \| sed "s\|^\|$f:\|"; done` |
| 12 | `github/projection_test.exs` is green on origin/main (54 tests, 0 failures) — the projection is not the leak | `cd api && CC=clang MIX_ENV=test mix test test/barkpark/plugins/github/projection_test.exs` |
