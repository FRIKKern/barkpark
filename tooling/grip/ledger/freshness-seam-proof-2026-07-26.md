# Re-derivation recipes — freshness-sweep residue proof, search-template W10, 2026-07-26

Verifier lane: `freshness-seam-proof` (task `task-f8f33cebc90d4d15`, W9 second-review F5/F6).
Probes were planted INTO `cloud/test/barkpark_cloud/sites/template_freshness_worker_test.exs`,
run, and reverted (`git checkout -- cloud/`; `git status --short cloud/` empty). Every row is one
literal command that re-derives the fact.

| # | Fact | Rerun |
|---|---|---|
| 1 | `Deployment` has NO `code_rev` column (only `content_rev`) — residue 2b has no cheap key available | `git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex \| grep -n 'field :' \| grep -i rev` |
| 2 | `code_rev/1` falls back to the constant `"unknown"` when a box reports neither `git_commit` nor `version` | `git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex \| sed -n '176,178p'` |
| 3 | The summary reduce is `Map.update!(acc, outcome, …)` over a 5-key `zero` — a SIXTH OUTCOME ATOM raises `KeyError`; a sixth SUMMARY KEY must be seeded in `zero` | `git show origin/main:cloud/lib/barkpark_cloud/sites/template_freshness_worker.ex \| grep -n 'zero =\|Map.update!'` |
| 4 | LIVE fleet: every deployed content site rides `guerrilla`, which reports a real `git_commit` — residue 1 is LATENT, not live | `ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select s.slug, b.slug as box, b.git_commit from sites s left join barkparks b on b.id=s.barkpark_id\""` |
| 5 | LIVE: 3 of 6 `barkparks` rows carry NULL `git_commit` AND NULL `version` (gyldendal ×2 stubs, muscle-1) — the dark-box class exists, it just hosts no deployed site yet | same host: `… -c "select count(*) filter (where coalesce(git_commit,'')='' ) as no_commit, count(*) from barkparks"` |
| 6 | guerrilla's `code_rev` is current with `origin/main` (moves on merge) — the sweep's trigger input is alive | `git merge-base --is-ancestor ea3849a5e3e4fa87c7c26498136a0380ce482909 origin/main && echo ANCESTOR` |
| 7 | LIVE: the sweep has actually fired — 4 `template-auto` deployments, all `live`, latest 2026-07-26 15:41 | `… -c "select trigger, count(*), max(inserted_at) from deployments group by trigger"` |
| 8 | Baseline suite is green before any probe (8 tests) | `cd cloud && CC=clang mix test test/barkpark_cloud/sites/template_freshness_worker_test.exs` |
| 9 | PROBE 1 — a commit-less box's quiet tick reports `%{duplicate: 1, enqueued: 0, skipped: 0, failed: 0, deferred: 0}`, key-for-key identical to a healthy quiet fleet | planted `dark_barkpark/2` fixture (`git_commit: nil, version: nil`) + `Map.keys(dark_quiet) == Map.keys(ok_quiet)` |
| 10 | PROBE 1b — two DISTINCT commit-less boxes hash to the SAME `build_id` for the same site, while a moved `git_commit` changes it (proves constant fallback, non-vacuously) | `Deploy.build_id(site, dark_bp, "rev-X") == Deploy.build_id(site, other_dark, "rev-X")` and `!= Deploy.build_id(site, %{dark_bp \| git_commit: "…"}, "rev-X")` |
| 11 | PROBE 1c — `Map.update!(zero, :code_rev_unknown, &(&1+1))` raises `KeyError`; seeding the key first works | `assert_raise KeyError, fn -> Map.update!(zero, :code_rev_unknown, &(&1 + 1)) end` |
| 12 | PROBE 2a — TWO analytics reads per site per tick, on BOTH the enqueue tick and the quiet tick | `StudioLinkFakeHttpClient.requests() \|> Enum.count(&String.contains?(&1.url, "/v1/data/analytics/"))` → `{2, 2}` |
| 13 | PROBE 2b — `content_rev` is BYTE-IDENTICAL across a box code-roll (`"a861a62e740c"` → `"a861a62e740c"`), so a content_rev-keyed quiet check returns `:duplicate` on the exact event the sweep exists for, while `build_id` correctly differs | simulate: `if last.content_rev == rev_after, do: :duplicate` → `:duplicate` |
| 14 | `Deploy.enqueue/4` blast radius: 3 production call sites, 30 test call sites | `git grep -n 'Deploy\.enqueue(' -- cloud/lib` ; `git grep -h 'Deploy\.enqueue(' -- cloud/test \| wc -l` |
| 15 | Probes fully reverted; working tree clean under `cloud/` | `cd /Volumes/SATECHI/github/barkpark && git status --short cloud/` (no output) |
