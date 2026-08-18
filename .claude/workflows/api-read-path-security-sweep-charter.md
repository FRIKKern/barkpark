# Epic charter — API read-path security sweep · share-token admin confinement

Epic task: `api-read-path-security-sweep`
Wave Paper: `api-read-path-security-sweep-wave-share-token-confinement-2026-08-18`
Grounded against origin/main `c9b25c8ea1b099fd2335bc168529b838e0ec2aa6`.

## Vision

Close the cross-tenant authorization holes on Barkpark's sharing surface with ONE predicate, applied at every action that can mint, reveal, destroy or enable a share credential — and prove each closure by mutation, never by a passing gate.

The sharing surface (`/v1/shares`, `/v1/shares/tokens`, `/v1/shares/links`) sits entirely behind a single `[:api, :require_admin]` pipeline whose whole implementation is `Auth.has_permission?(token, "admin")`. That gate answers "is this bearer an admin **somewhere**" and never "an admin **of what**". Everything downstream — a scope slug, a workspace slug, an opaque token id — is client-supplied. The epic's job on this fence is to install the missing half of the question.

The wave that this charter opens settles the predicate itself, because two open PRs (#12405 on the token half, #12404 on the link half) both ship a predicate that is **inverted on both arms**: it confines by `api_token.workspace_id != nil`, which is not a tenancy fact but a backfill/default artifact. That reading is not an opinion — it is CI-measured. The binding predicate reds four tests across three files that neither PR touches, every one of them a legitimate admin flow, while granting unconfined cross-tenant reach to any row written outside `create_token/5`. Fail-closed for real operators, fail-open for unclassified rows.

The replacement is a RELATION, not a property: resolve the TARGET workspace from the request, then ask whether this actor holds an admin-or-owner **membership grant** there. Nothing is granted by the absence of a binding, so the NULL escape hatch disappears rather than being narrowed.

Fence for this wave: `api/lib/barkpark_web/controllers/share_controller.ex`, `api/lib/barkpark/sharing/**`, and their `api/test` trees ONLY. NOT `share_link_controller.ex` or `sharing/links.ex` (open PR #12404 owns them), NOT `barkpark_web/live`, `content/`, `search/`, `media/`, `auth/` (beyond reading the token model), `cloud/`, `js/`, `web/`.

## Decisions

- **D1 — The predicate is `Tenancy.Auth.workspace_admin?(actor, target_workspace_id)`, NOT `authorize/3`, and NOT `actor.workspace_id` equality.** Why: a run probe proved `authorize(tok, ws_B, :admin) == :ok` for a global-admin token holding only a plain `member` membership in B, because `authorize/3`'s api_token arm is `member? AND the token's GLOBAL permissions[]` and never reads `membership.role`; `workspace_admin?/2` reads the role column and returns `false` on the same input. On a surface that hands back a raw live credential, the weaker gate is not acceptable, and it is free (one `Repo.one` on the row `member?/2` already reads).

- **D2 — Neither branch A nor branch B of the wish: this is branch C, and the wave paper says so plainly.** Why: the wish framed it as "the tests are wrong" vs "the confinement over-reaches". The evidence says both are half right — the confinement DOES over-reach (B's diagnosis) AND the fixture flow IS genuinely cross-tenant (A's conclusion) — because `workspace_id != nil` measures the wrong thing entirely. Picking either label ships a bad control.

- **D3 — The deciding fact is settled and is not re-opened by any later wave.** Why: an ExUnit probe printed the fixture admin's literal `workspace_id` as `da076f64-9549-4ad3-9fa8-86eba2a6efdc`, byte-identical to the seeded Default Workspace (planted by migration `20260527110200`, which `mix.exs:166`'s test alias always runs) and different from the fresh `tok-ws` the suite mints against. `confine_scope` takes its `is_binary` arm, the slug lookup misses, `cross_tenant` → 404 vs the asserted 201, and `list_tokens` filters every row. ONE root cause, three failures.

- **D4 — A behaviour change ships, and the changed tests are written as a statement of the new contract, never as gate appeasement.** Why: a Default-bound admin minting into a brand-new foreign workspace stops working, because that IS the cross-tenant flow. `share_token_controller_test.exs`'s mint and list-and-revoke assertions move to the fail-closed status, and a SIBLING test runs the same flow inside the actor's own workspace and stays green — so the file proves both directions rather than recording a new status.

- **D5 — The HARD INVARIANT is proved through the flow a self-hosted install actually runs, never through a hand-inserted NULL row.** Why: `create_token/5` branches on `ws_id` AFTER the Default fallback and writes an admin-role membership in the resolved workspace, so a self-hosted admin minted by `Auth.create_token/4` IS an admin member of Default and passes the predicate end to end. Both #12405 and #12404 could only demonstrate their safe arm by `Repo.insert`-ing an `%ApiToken{workspace_id: nil}` no deployment produces — two independent authors documenting the unreachability of the arm their criteria protect.

- **D6 — A host-admin-PRESERVED proof can never red under full reversion, and the paper states that limit rather than claiming "mutation-proven" flat.** Why: a permissive assertion only reds toward OVER-confinement. Measured: mutating the role floor to `owner`, or refusing to honour a Default-workspace membership, both red it (403 where 201 is expected); reverting the whole fix does not, and neither does the actor-vs-target confusion (M1 went GREEN). The actor-vs-target class is the LEAK proof's job — the two proofs cover disjoint mutation classes and neither substitutes for the other.

- **D7 — The leak-closed proof gives the ws-A actor a real `member` membership in ws-B, and mutation-verifies by swapping `workspace_admin?/2` for `authorize/3`.** Why: that single-token swap must turn it RED. Written against a genuine NON-member of B instead, the same test would pass under the weaker predicate too — a materially weaker statement that reads identical in the paper.

- **D8 — Predicate calls are UUID-guarded and nil-guarded before they are made.** Why: `workspace_admin?/2` and `membership_role/2` raise `FunctionClauseError` on `nil` and `Ecto.Query.CastError` on any non-UUID binary (including the empty string) at `tenancy/auth.ex:145` — a 500 on a credential surface, i.e. trading a leak for a crash oracle. `Barkpark.Repo.uuid_or_nil/1` is the repo's existing remedy; `nil` must route to the same denial as a forbidden verdict.

- **D9 — Resolve the scope slug BEFORE authorizing, so the existing 422 contract survives.** Why: `POST /v1/shares/tokens` with an unresolvable scope returns 422 `validation_failed` / "the scope is not edit-shared" today, pinned by `share_token_controller_test.exs:75`. #12405's predicate turned that into a 404. The natural resolve-then-authorize ordering preserves it; the obvious code does not. Status contract: mint cross-tenant → **403 forbidden** (the scope names the workspace, so 403 leaks nothing the 422/non-422 fork does not); revoke foreign id → **404 not_found**, byte-identical to the missing-token arm (an opaque id must not become an existence oracle); list → **200 with foreign rows absent**, filtered before `token_json`.

- **D10 — `Barkpark.Auth.revoke_token/1` stays an unscoped shared primitive; confinement lives in the controller.** Why: 9 of its 12 call sites have no HTTP actor at all (background teardown, LiveView mint-rollback, a root-shell provisioning `mix run -e`), so an actor-scoped primitive would need a `:system` bypass at every one and the bypass would become the norm. #12405's architectural call is CORRECT and is inherited.

- **D11 — Confining mint/list/revoke while `POST`/`DELETE /v1/shares` stay open is DECORATIVE, so `create`/`delete` carry the same predicate — in a sequenced round-2 slice, not the same diff.** Why: proved end to end on clean origin/main — a ws-A-bound admin POSTs an `:edit` share for ws-B's scope (201, no tenancy check anywhere in `Sharing.add_share/1`) and then mints a **live raw** `bpshare_…` token for ws-B legitimately, because by then the precondition is one it wrote itself. `DELETE /v1/shares` mirrors it as a cross-tenant DoS: `remove_share/3` hard-revokes the victim's live edit tokens. Sequenced because both slices edit the same controller region — one file, one builder at a time.

- **D12 — `POST /v1/shares` for a NON-EXISTENT workspace must fail closed.** Why: it returns 201 today and persists a ghost share, so the row sits pre-planted waiting for someone to create that workspace slug, at which point a foreign `:edit` share is live over their content. `create_share_token/5` already fails closed on the same input; `create` is the asymmetry.

- **D13 — Share fixtures are planted through `Sharing.add_share/1`, never a bare `Application.put_env(:barkpark, :shares, …)`, and every leak assertion is status-EXACT.** Why: `Sharing.refresh/0` unconditionally recomputes `:shares` from `shares_env() ++ list_stored()`, and in test `shares_env()` is `[]`. A put_env-planted share with no `StoredShare` row is ERASED by any `add_share`/`remove_share` — proved: mint flips 201 → **422** for a reason with nothing to do with tenancy, and a `refute status == 201` assertion passes on the wiped fixture with the confinement code deleted. The fixture wipe is a fake-green generator sitting directly on this wave's evidence path. `share_token_controller_test.exs` must also snapshot/restore `:shares_env`, which it does not today.

- **D14 — PR #12405 is superseded, never pushed to; PR #12404 is sequenced BEHIND this wave and reworked, not merged then patched.** Why: #12404's Elixir gate is RED with exactly two failures, both cross-file regressions it caused in files it never touched — `pds_delete_receipt_differential_test.exs:245` (DELETE link → 404 "link not found", its new bound `fetch_scoped/2` arm) and `http_cache_policy_test.exs:198` (media link create → 404, its new mint confinement). Same Default-binding trap, different half. Landing it first ships a known-red predicate to main and then forces a revert.

- **D15 — Adopting membership costs a RECORDED SUPERSEDING RULING, not a silent swap.** Why: `arpss-share-controller-edit-token-authz` criteria 4 and 6 are marked `met=true` and positively REQUIRE the nil arm to stay open ("a nil-workspace admin still sees all"; "still reaches revoke/list/mint across any workspace"), and the sibling strategize paper records the binding predicate as THE decision. This charter IS that ruling: criteria 4 and 6 are superseded by D1/D5, and the lead must flip them to `met=false` and re-word them to the membership contract before that task can honestly close. The ruling row is `task-46e7d44068e7185e`.

- **D16 — The Default-fallback question is answered HERE, narrowly, and the answer is recorded rather than assumed.** Why: `arpss-flat-doc-mutate-default-scope-write` files "is Default a customer-shared bucket?" as a deliberately UNRULED product question. This charter does not rule the product question. It rules only that **`workspace_id` binding is not admissible as a tenancy grant on a credential surface**, because membership is available, total in the directions that matter, and positively identifies the self-hosted operator. A later product ruling on Default can change what Default MEANS without reopening the predicate.

- **D17 — `require_admin`'s workspace-blindness is an epic-level finding, filed, not fixed here.** Why: ~40 routes ride the same gate, and `AssignDefaultScope` stamps `current_workspace = Default` for every caller before it (the router's own comment admits `[:api, :require_admin]` cannot attribute a tenant). Three routes name the target tenant directly in the URL. That is a program, not a slice; the wave writes its predicate as a reusable resolve → authorize → act SHAPE so the sibling fixes are three lines, and explicitly does NOT extract a shared controller helper while a concurrent wave audits `controllers/` broadly.

- **D18 — `DELETE /v1/fleet/support-tokens/:token_id` is a strictly WIDER instance of the same hole, outside the fence, filed with its proof.** Why: it hands a client-supplied id to `Auth.revoke_token/1` with no object authz AND no token-family check, so any admin bearer can revoke ANY `api_tokens` row by id — another tenant's PAT, a share edit token, an instance admin token. Filed as `task-f11c6ed5e211476b`.

- **D19 — The gate command is the corrected seven-file set; the wish's version cannot run.** Why: `api/test/barkpark_web/controllers/share_link_controller_test.exs` DOES NOT EXIST (the real file is `share_link_test.exs`), and the wish's set omits `api/test/barkpark/sharing/`, which is inside the declared fence. The corrected set was run green on clean origin/main at `102 tests, 0 failures`.

- **D20 — Builder model is `fable` on both slices despite the Fable cap, because both are tenancy predicates on a credential-revealing surface.** Why: the difficulty axis alone carries it — subtle design judgment, cross-surface coupling, high blast radius, and a proof standard where the obvious implementation is silently wrong in three separate ways (D8 crash class, D9 ordering class, D13 fake-green class). Mis-classifying either as routine costs twice.

## Roadmap

| # | Slice | Round | Size | Model | Surface |
|---|---|---|---|---|---|
| 1 | Rebuild the share-EDIT-TOKEN confinement on the membership+role predicate — mint/list/revoke, both mutation-verified proofs, honest test updates, fixture hygiene | 1 | large | fable | `share_controller.ex` (token actions) + `share_controller_test.exs` + `share_token_controller_test.exs` |
| 2 | Extend the SAME predicate to `POST`/`DELETE /v1/shares` — close the forgeable mint precondition and the cross-tenant share DoS, and fail closed on a ghost workspace | 2 (after 1) | medium | fable | `share_controller.ex` (create/delete) + `sharing/sharing.ex` + `sharing_test.exs` + `sharing/stored_share_test.exs` |

Sequenced, not parallel: both slices edit `share_controller.ex`. Slice 2 dispatches only after slice 1 MERGES.

### Filed, not built this wave

- Rework PR #12404 (ShareLink half) onto the membership+role predicate — do NOT merge as-is, its gate is red on two self-inflicted cross-file regressions.
- `DELETE /v1/fleet/support-tokens/:token_id` — identical by-id hole, strictly wider, outside the fence.
- `require_admin` workspace-blindness across ~40 routes — the program D17 names.
- `Tenancy.Auth`'s totality claim is false (raises on nil and on non-UUID) and its moduledoc oversells membership EXISTENCE as isolation.
- 16 test files plant `:barkpark, :shares` via bare `put_env` with no `:shares_env` awareness — the D13 hazard as a file class.

## Wave log

_(empty — the lead appends one line per wave on merge)_
