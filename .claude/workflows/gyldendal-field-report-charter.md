# Epic charter — Gyldendal field report: make the core Barkpark tools perfect

Epic task (GOAL): `task-3f1fe755ed53738e`
Charter written to this epic-specific path, NOT the shared `bp-cloud-epic-charter.md` rotating slot (rotating-slot trap: that slot holds other waves' live charters).
Lead triage performed against origin/main `6f724edfd8`.
Wave 1 Decide reconciled against origin/main `f0b2bdcf2` (2026-08-20T16:20Z) — **five heads past the
triage pin, and three of them landed inside this wave**: `#12826` (flat admin derive), `#12824`
(workspace DELETE/export binding), `#12827` (blob-push binding). Re-read the Decisions below before
quoting any of them: several were amended or refuted by run output.

## Provenance — why this epic exists

On 2026-08-20 Gyldendal migrated a REAL production site — `agency.gyldendal.no`,
1 074 documents, 956 assets, all 16 GROQ queries, the full publish chain — from
Sanity to Barkpark in one day, and wrote down every point of friction.

The migration SUCCEEDED, with measured parity: sitemap 1057/1057 identical,
title/h1/meta 24/24, adapter parity 17/17 against LIVE Sanity, 672 byte-identical
frontend files, webhook chain proven end-to-end against real signed server
deliveries. Their verdict on the data plane was **zero findings** — once the app
was running, nothing in Barkpark's content consumption failed.

**Every defect they found is in the TOOL and ADMIN layers.** That is the whole
subject of this epic. The platform carried the load; the road to it did not.

Source papers live on **gyl.barkpark.cloud**, not guerrilla:

| Paper | Contents |
|---|---|
| `2026-08-20-barkpark-rapporten` | The crown report addressed to us |
| `2026-08-20-friksjonsloggen` | All 35 numbered findings — the spine |
| `2026-08-20-studio-gjennomgangen` | Studio editorial review |
| `2026-08-20-paritetsrapporten` | The parity proof numbers |
| `2026-08-20-agency-pa-barkpark` | The 10-agent read-only pre-study |

Read them with:

    curl -s "https://gyl.barkpark.cloud/v1/data/query/production/paper?limit=200"

The report's own headline count is "55 improvement points". The friction log
carries **35 numbered** findings; the remaining ~20 are unnumbered asks scattered
through the pre-study's phase-0 list and the Studio review. **The 35 numbered
findings are the canonical spine.** Do not invent items to reach 55.

## Vision

Take the tools we ALREADY have to the standard a paying customer would call
perfect. Not new surface — earned trust in the existing surface.

The owner's directive, verbatim: *"the most important is the core Barkpark
trouble — the Sanity Migrate is a bit too specific — but we need to fix the major
core Barkpark things — then we should consider the Sanity Migrate thing — our
goal is to make the tools we already have... perfect."*

Finished experience: a competent outside engineer migrates a real site onto
Barkpark using only `bp`, the API and Studio, and is never once lied to. Every
command that reports success has done the thing. Every denial says which of
route / access / absence it was. Every limit is either enforced with a 422 or
documented — never silently swallowed. An editor completes a full round trip in a
non-default workspace without touching the API.

## Scope and fence

**IN:** `api/lib/barkpark/**` (content, media, tenancy, plugs), `api/lib/barkpark_web/**`
(router, pipelines, controllers), `internal/cli/**` + `internal/manifest/**` (the
`bp` CLI), the Studio LiveView surface, and their test trees.

**OUT — explicitly parked until this GOAL closes:** `bp migrate sanity`.
Gyldendal offered their migration engine, GROQ→port adapter and
`create-content-type.scaffy` upstream, and called it ~80% of the command. It is a
good idea and it is a NEW TOOL. Building it before the core is perfect would be
exactly the reflex this epic exists to correct. Revisit after the GOAL closes.

**Also out:** the Gyldendal monorepo's own universal-blocks programme
(`2026-08-20-universal-blocks-program`) is their internal Sanity work, not
feedback on us. And `kevin-touch-grass-git-revisjon-2026-08-20` is a joke paper.
Neither is in scope; both were checked and dismissed by the lead.

## Decisions (D1–D12 lead triage; D3/D4/D6/D7/D8 AMENDED by wave 1; D13–D20 new)

- **D1 — Every remaining finding is re-verified against current main BEFORE any
  builder touches it.** *Why: Gyldendal tested v0.2.26.382; 126 commits have since
  landed. Finding #9 is already fixed (below) — proof the report has decayed. A
  finding that turns out fixed is a CLOSE WITH EVIDENCE, not a build. Per memory
  `distrust-vacuous-green` and `stamped-evidence-can-overstate`: re-verify by
  RUNNING, not by reading.*

- **D2 — #9 is ALREADY FIXED. Close it, do not build it.** `bp whoami` exists at
  `internal/cli/cli.go:148` and is registered in `builtins.go:352` and
  `usage.go:26`. *Why: the report says it does not exist. It did not, at their
  version. It does now. Verify the adjacent half — that `bp auth me`'s error hint
  now points at something real.*

- **D3 — AMENDED BY WAVE 1. Half right, and misattributed. BOTH the charter and
  Gyldendal are correct, about DIFFERENT query shapes.** Measured live against
  `guerrilla` and re-run in-tree against a 3-document corpus:

  | shape | HTTP | rows | class |
  |---|---|---|---|
  | `filter[status][bogus]=x` (unknown OP) | **400 `invalid_filter`** | — | fail-CLOSED; the D75 guard at `query_controller.ex:51` already seals this door |
  | `filter[]=a&filter[]=b` (list-valued param) | 200 | **UNFILTERED** | silent OVER-return — the only HTTP shape that reaches it |
  | `filter[status][contains]=pub` | 200 | **0** | silent UNDER-return, wrong column |
  | `filter[title][eq][]=a` | 400 `internal_error` | — | an `Ecto.Query.CastError` dressed as a client error |

  *Why the amendment: D3 credits the over-return to `query.ex:548`, but the shape
  that actually over-returns never reaches `apply_field_op/4` — it dies one layer
  up at `normalize_filter_map(_), do: %{}` (`query_controller.ex:833`), where the
  D75 guard is structurally blind because `invalid_filter_op(%{})` is `nil`. And
  the WIDE, customer-facing defect is the opposite sign: `status` carries
  column-backed clauses for only `eq/in/nin/neq/is`, so a VALID op like `contains`
  or `startsWith` falls through to the generic arm and reads `content->>'status'`
  — a JSONB key that does not exist — returning zero rows at 200 with no hint.
  `doc_id` prefix filtering is unreachable by ANY spelling (`starts_with` is
  400'd by the op allowlist; `startsWith` reads the wrong column). That is what
  cost Gyldendal, it is reproducible on demand, and **strictness at
  `apply_field_op/4` cannot catch it** — the op is legal, a generic clause
  exists, the query runs happily. Re-grade S2's headline to "silent zero rows at
  scale, with one narrow security-adjacent over-return alongside."*

- **D4 — REFUTED BY WAVE 1 AT ITS CITATION. Do not implement it as written; it
  ships a no-op.** Three of its four clauses are false, proven by run:
  - `internal/cli/cli.go:654` IS `flags := map[string]string{}` — but it is
    `resolveContext`'s six-key SCOPE map (`token/workspace/project/dataset/output`)
    fed to `manifest.Resolve`. **It never sees `--filter`.** Command flags are a
    different model: `map[string][]string`, built by `splitArgs` (`run.go:649`).
  - **The CLI does NOT last-wins.** `applyQuery` (`run.go:801-806`) does
    `q.Add(f.Name, v)` for EVERY value. Dry-run at origin/main:
    `?filter=status%3Dpublished&filter=title%3Dx` — both reach the wire.
  - `--set` is NOT special-cased in `splitArgs`; every flag appends. The
    special-casing is downstream in `buildBody`.
  - **TRUE, and verified live:** the API's bracket form already ANDs
    (`filter[featured][eq]=false&filter[title][eq]=Untitled` → 2 rows, vs 17 and
    3 alone). Do not add AND to the query builder.

  *Why: the drop is SERVER-side, Plug's duplicate-key decode. Four prod curls,
  no CLI in the path: `featured=false` → 17, `title=Untitled` → 3, the pair →
  **3 or 17 depending purely on ORDER**. Order-dependent last-wins at 200 OK. A
  builder handed D4 verbatim edits innocent code in `resolveContext` and reports
  #16 closed. Superseded by D17.*

- **D5 — #4's proposed fix is WRONG and must not be implemented as written.** The
  report says: serve the stored `mimeType` instead of the extension-derived one.
  *Why: ingest is ALSO extension-derived (`api/lib/barkpark/media.ex:89`) and
  that is DELIBERATE — the comment there explains the client Content-Type is
  distrusted on purpose so a header lie cannot set the persisted mime
  (stored-XSS defence; default asset visibility is public). For Gyldendal's real
  case — 816 assets all named `remote.axd`, no extension — the STORED type is
  ALREADY `application/octet-stream`, so serving it changes nothing. The real fix
  is CONTENT SNIFFING at ingest (`Media.probe` already exists and already takes an
  optional mime), extension as fallback, client header still distrusted,
  `neutralize_dangerous_mime` retained — then serve the stored value through
  `MediaFile.serve_content_type/1`, the shape
  `tickets_attachments_controller.ex:220` already uses. The serve edge is
  `media_controller.ex:87` and `:139`. Both halves must hold: fix octet-stream
  WITHOUT regressing the XSS defence.*

- **D6 — ANSWERED BY WAVE 1: the seven-mask hypothesis is REFUTED. It is not one
  bug, and it is not two. Five independent surveyors plus five verifiers
  converged on SIX mechanisms and one ratified policy.**

  | # | Mechanism | Owns | State after wave 1 |
  |---|---|---|---|
  | M1 | `AssignDefaultScope` pins flat routes to the seeded Default | #1 server half, #26, 4 of 15 admin scopes | **3/4 CLOSED by `#12826`**; `fleet_support_token_controller` remains |
  | M2 | CLI `-w` silently dropped on a flat route template (`internal/manifest/url.go`), **and unknown long flags like `--workspace` ignored too** | #1 client half | LIVE |
  | M3 | Token-tier gap is at the MINT surface, not the authorization layer | #7 | LIVE — split out of S1, see D14 |
  | M4 | HTTP workspace create binds the api_token; the `%User{}` head at `tenancy.ex:918-922` is unreachable from EVERY caller | #6 | LIVE — and it is a DATA problem, see D15 |
  | M5 | Capability-subset predicate at `access_controller.ex:68`, one call site | #5's third symptom | not tenancy at all; not a defect this wave |
  | M6 | Studio scope derivation is PRINCIPAL-KIND BLIND — four sites read `api_token` only and fail OPEN to Default for a `%User{}` session | #34, #15 | LIVE — see D16 |

  *Why this matters more than the count: `#12826` — the "headline S1 fix" —
  reaches M1 only. Selling it as "S1 is solved" would have been the wave's own
  sin. The customer's single CRITICAL (#34) is M6, on a surface that **never runs
  the `:api` pipeline at all** (`AssignDefaultScope` is mounted in seven
  pipelines; Studio rides `:browser`/`:scoped_browser`/`:shared_studio_browser`/
  `:soft_token` and is in none of them).*

  **Also settled: #15 was never hit in practice.** The Studio review says
  verbatim *"Kjent fra forstudien; ikke re-testet denne runden"* — so the wish's
  "every one hit in practice" is false for exactly the mask most likely to make a
  family fix regress correct code. Its real mechanism is M6 at the
  Studio→web-component→HTTP token handoff, and the "non-admin" framing is a
  MIS-ATTRIBUTION manufactured by `content/errors.ex:308`, which renders every
  `:forbidden` as *"token lacks required permission"* with a write/admin hint —
  while the gate that actually fired is membership. **An S2-class lie sitting
  inside an S1-classified finding.**

- **D7 — LARGELY DISCHARGED BY `#12826`, WITH ONE NAMED REMNANT — and the census
  it demanded proves the 15 were never one family.** The behavioural
  re-derivation (one workspace-bound `admin` token, live HTTP, every route)
  splits them FOUR ways:

  | Class | Count | Verdict |
  |---|---|---|
  | **A — defective**: tenant data resolved to the seeded Default | 4 | 3 CLOSED by `#12826` (structure, schemas, webhooks). **`POST /v1/fleet/support-tokens` REMAINS** — it binds the MINTED CREDENTIAL to Default and inserts a `workspace_memberships` row there |
  | **B — genuinely global**: no tenant data | 7 | **DO NOT MOVE.** `/v1/secrets` persists at `workspace_id = NULL`; `status_incidents` has no `workspace_id` column at all. Deriving here CHANGES STORED IDENTITY |
  | **C — self-resolving from a path slug** | 3 | CLOSED mid-wave by `#12824` (DELETE + export) and `#12827` (blob-push). Unreachable by any derivation fix — they needed a membership predicate |
  | **D — empty** | 1 | `plugin_routes(scope: :api)` expands to zero routes; latent for the first plugin declaring `auth: :api` |

  *Why the fence on Class B is now a RULE, not a note: `secret_controller.ex:177-190`
  had already hand-immunised itself, keying its tier off the ROUTE
  (`Map.has_key?(conn.path_params, "workspace_slug")`) with a comment naming
  `AssignDefaultScope` as the hazard. Prior-art task `task-2b396416a680ff0b`
  ordered ALL 15 moved; that instruction, followed literally, would have re-tiered
  the global secret store under a green proof. **Amend that task before anyone
  claims it.** The count 15 was a coincidence twice over: the task itself counted
  15 ROUTES across 3 SCOPES (`structure` 1 + `schemas` 4 + `webhooks` 10), while
  `grep -c 'pipe_through(\[:api, :require_admin\])'` also returned 15 SCOPES.
  Different things, same number.*- **D8 — REFUTED AS WRITTEN AND REPLACED BY D13. As stated it is a security
  regression, and its own justifying anecdote does not survive the sources.**
  Three independent kills:
  1. **The discriminator "a caller holding a VALID token gets a 403" is refuted by
     production code.** `query_controller.ex:670` deliberately 404s a caller with
     a valid public-read token, saying so: *"existence-hiding, not a 403, so the
     refusal never becomes a probe."* `public_read.ex:141` does the same for a
     non-public schema — while denying route and perspective with **403** two
     clauses above. The rule keys on WHAT is denied, never on WHO asks.
  2. **#34 is not a masked denial at all.** `ResolveWorkspace` plainly 403s a
     non-member (`:130`) and 404s only an unknown slug; Studio's
     `empty_editor_state/2` (`live/studio/studio_live/shared.ex:934-972` — note
     the path, `live/studio/shared.ex` does NOT exist) derives its reason from
     PANE SHAPE alone and has no `:forbidden` arm, so it structurally cannot
     report a denial. The "does not exist" card is a TRUTHFUL answer to a question
     the flat→scoped 302 funnel silently rewrote to Default. **A builder who
     implements D8 and then re-tests #34 gets a false negative.**
  3. **"Three hours" appears in NONE of the five source papers.** It is a
     lead-side embellishment. Do not quote it back to Gyldendal.

  *Also corrected: the digest's "29 deliberate existence-hiding sites" over-counts
  by ~4x. Of 32 markers, 12 govern MANIFEST VERB PROJECTION (`capabilities.ex` ×8,
  `openapi.ex`, `tickets/cli.ex`, `capabilities_controller.ex`, a router comment)
  and touch no HTTP status. The real HTTP population is SEVEN endpoints.*

- **D9 — #26 is CONFIRMED, and it is the SAME family as S1.** The graph routes are
  declared in a FLAT `scope "/v1"` with `pipe_through([:api, :require_token])` —
  `router.ex` ~1915-1927, `/graph`, `/graph/orphans`, `/graph/dangling`,
  `/graph/:id`, `/graph/:id/tasks`. *Why: no `/w/:ws/p/:project` prefix means
  `AssignDefaultScope` pins them to the seeded Default, which is exactly the S1
  mechanism. So S4's #26 is not an independent mount bug — it is one more member
  of the flat-route family D7 says to census. Do not fix it in isolation; fold it
  into S1's family census so the fix and the sibling sweep are the same work.*

- **D10 — #12 is CONFIRMED: the asset DOCUMENT is never deleted.**
  `Media.delete_file/2` (`api/lib/barkpark/media.ex:440`) resolves
  `doc = asset_doc_for_file(file, file.dataset)` at :446 — but only to carry the
  `media.deleted` webhook payload. It then `Repo.delete(file)` (the media_files
  ROW), `Blobstore.delete(file.path)` and `Renditions.delete_for_file(file.id)`.
  The mediaAsset document is READ and never removed. *Why: this is the precise
  mechanism behind Gyldendal's 517 dangling drafts. Note the ordering constraint
  the existing comment already states — the payload is resolved BEFORE the delete
  so a phantom `media.deleted` cannot fire — so the document delete must join the
  same transaction without moving that resolve.*

- **D11 — #32 is CONFIRMED and the CLI verb is DEAD, but the fix may be
  server-side.** `api/lib/barkpark/webhooks/webhook.ex:90` is
  `validate_required([:name, :url])`. `bp webhook create --help` declares exactly
  one argument, `<url>`. So every invocation 422s and the verb has never worked.
  *Why: `bp` is MANIFEST-DRIVEN from `GET /v1/capabilities` — so the missing
  `--name` is likely a declaration gap in the server's capability manifest, not
  Go code. Check the manifest before editing `internal/cli`. Contrast
  `bp cloud webhook create`, which DOES take `--name`
  (`internal/cli/cloud_webhook_cmd.go:158`): the cloud family is right and the
  instance family is wrong, so sweep the two families for further drift.*

- **D12 — #33 is CONFIRMED, and the codebase asserts the opposite in a comment.**
  `webhook_controller.ex` create responds `%{webhook: render_webhook(wh)}` with no
  `secret` key. Only rotate returns `secret: new_secret` (:127). Yet the rotate
  docstring at :117-118 says it "returns the NEW secret exactly once in the
  response body — subsequent reads never re-expose it (**mirrors create's
  secret-exposure semantics**)". *Why: create has no secret-exposure semantics to
  mirror. The published contract and this moduledoc BOTH describe behaviour that
  does not exist. Prefer changing the CODE — the documented behaviour is the
  better one — and delete the false clause. Per memory
  `bespoke-checks-lie-in-four-ways`, distrust a comment most when it confirms
  what you hoped.*

### New decisions from wave 1 (D13–D20)

- **D13 — THE DENIAL RULE, replacing D8. The discriminator is the RESOURCE TIER,
  never the caller tier.** Three tiers, one sentence each, and one test a builder
  can apply without reading this charter:

  | Tier | What is denied | Status |
  |---|---|---|
  | **A** | a scope container the caller NAMED IN THE PATH (workspace, project, dataset) | **403** when it exists and the caller is refused; **404** only when the name does not exist |
  | **B** | a resource addressed by an identifier INSIDE an already-resolved scope (document id, revision, tag, type name, secret name, share link, grant id, media asset, invite email) | **404 always, for every caller tier including a valid admin token** |
  | **C** | a capability, route, perspective or config refusal naming no resource | **403** |

  **The builder's test:** *if flipping this 404 to a 403 would let a caller learn
  that an identifier they GUESSED is real, it is Tier B — keep the 404.*

  *Why: Tier B is not sloppiness, it is a shipped defence. `public_read.ex`'s own
  moduledoc names what its 404 closed — a public-read token reading
  `GET /v1/data/export/production`: **52,208,330 bytes, 2,500 documents, 129
  drafts**. D8 as written converts that into an enumeration oracle. Tier B is the
  EXEMPT LIST: `query_controller.ex` ×7 (:101 :124 :154 :192 :296 :331 :372/:378),
  `public_read.ex:141`, `require_share_scope.ex:130`, `access_controller.ex:26/:199`,
  `fleet_support_token_controller.ex:46`, `share_controller.ex:332`,
  `item_share.ex:107`, `accounts.ex:492`, `auth_controller.ex:704`. Do not touch
  them. `content/related.ex:121` returns `[]` and is already correct — do not
  "fix" it.*

  **The one live Tier-A violation, and it is the highest-value denial change in
  the repo:** the SAME membership question gets OPPOSITE answers on two route
  families. `resolve_workspace.ex:134` 403s a non-member on a known slug;
  `workspace_controller.ex` `projects` (:944), `datasets` (:962) and
  `create_project` (:78) 404 one, with a comment proudly explaining why — because
  the flat `/api` scope rides `[:api, :require_token]` and **never mounts
  `ResolveWorkspace`**, so the 403 chokepoint never runs. Three call sites. This
  is the likeliest true cause of Gyldendal's #1/#34 confusion and it is what makes
  the workspace switcher stop lying.

  **A known collision the lead must not let a builder rediscover:** filed task
  `arpss-w8-bl-access-grant-id-existence-oracle` argues D13's Tier B on
  `GET|DELETE /v1/access/:id` — and is RIGHT — but the current 403-foreign/404-missing
  pairing is **pinned green** by `access_controller_test.exs:185-191` (17 tests, 0
  failures). Landing it requires deliberately flipping a passing assertion.

- **D14 — #7 SPLITS OUT of S1. Its two literal claims are REFUTED at the
  authorization layer and CONFIRMED at the minting layer.** Proven live:
  `POST /w/<ws>/p/default/v1/tokens` with `{"permissions":["read"]}` returned
  **HTTP 201** with `"permissions":["read"]`. `public_read_token?/1` is a plain
  membership test on the string `"public-read"`; a `["read"]` token no-ops out of
  the clamp entirely and `authed?/1` treats it as authenticated, so it reads
  private schemas TODAY. `@allowed_permissions` is `~w(public-read read)`.
  *Why: there is nothing to unclamp. The gap is that no surface a customer can
  reach ASKS for it — there is no `bp token` verb (`"token"` appears in
  `builtins.go:351` only as a reserved name), no Studio mint panel, and every
  in-repo caller hardcodes `["public-read"]` (`internal/bootstrap/bootstrap.go:374`,
  `internal/cli/vercel_cmd.go:549`). A builder told "unclamp the server" will find
  nothing and may loosen the allowlist for no reason. This is a product-surface
  slice, not a tenancy fix. Backlogged, not built this wave.*

- **D15 — M4 is CONFIRMED, and it is a DATA problem in production RIGHT NOW.**
  Live HTTP + live prod SQL: `POST /api/workspaces` writes exactly one membership
  row, `principal_type=api_token`, and no `user` row ever. A real `%User{}` against
  that workspace then gets `membership → nil`, `member? → false`,
  `workspace_admin? → false`, `list_workspaces_for → []`. On guerrilla
  `barkpark_prod`: `default | 2 user | 99 token` and **`gyldendal | 0 user | 3
  token`** — the customer's own production workspace is in that state.
  *Why three pieces, not one: the `%User{}` head at `tenancy.ex:918-922`, whose own
  comment says it exists so "the creator would [not] be locked out of the workspace
  they just made", is unreachable from EVERY caller in `api/lib` — not just HTTP.
  Studio's own create affordance guards on `%ApiToken{}` too (`handlers/scope.ex:111`,
  `studio_chrome.ex:252`) and flashes "Sign in to create a workspace". The ONLY
  exerciser is `tenancy_test.exs:246` — a unit test proving a function no route can
  call. And `git ls-tree … api/lib/barkpark_web/controllers | grep -i 'member\|invit'`
  returns NOTHING: there is no membership verb anywhere, so the damage cannot be
  repaired through the product. **Ship the code half alone and Gyldendal stays
  locked out.** The wave ships (a) the binding and (b) a backfill; (c) the member
  verb is backlogged as new surface.*
  The binding is buildable: `api_tokens.owner_user_id` exists (migration
  `20260708130000`) and `Plugs.ResolveTokenOwner` already does exactly this
  resolution on another pipeline.

- **D16 — #34 and #15 LEAVE the S1 tenancy family and join the Studio
  principal-kind family, whose repair is already half-shipped.** Run-proven by
  three account-session probes against the flat Studio deep link:

  | principal | 302 Location |
  |---|---|
  | ACCOUNT session, member of `gyl-b-11555` ONLY, `api_token` nil | `/w/**default**/…` ← WRONG |
  | TOKEN, member of `gyl-b-11299` ONLY | `/w/**gyl-b-11299**/…` ← CORRECT |

  The correct answer is already in the resolver and simply never asked for:
  `ScopeResolver.resolve_workspace(user)` returns `"gyl2-b-292"` while the
  funnel's own call — one line away, passing `conn.assigns[:api_token]` — returns
  `default`. *Why it cost hours rather than minutes: the workspace SWITCHER is
  built from the same nil token (`studio_chrome.ex:310`), so the user is
  teleported to Default **and has no in-UI escape** — `render_click(v,
  "scope-open")` listed Default only. Fix the redirect without the switcher and
  the user is correctly placed but still cannot move; fix the switcher alone and
  they are still teleported. **One slice, not two.** And the fixture is
  load-bearing: an ACCOUNT (`user_session`) principal, because a token fixture
  passes today and would certify nothing. Prior art `arpss-w10-bl-workspace-admin-bare-user-id-silent-false`
  (PR #12710, closed the day before) split the tenancy PREDICATES on principal
  kind and never reached `ScopeResolver` — same family, actively being repaired,
  two sites missed.*
  **Honest residue: nobody knows which principal Gyldendal held.** The twin repo
  is not on this host. If they pasted a token, the funnel resolved correctly for
  them and #34 has a cause we have not found. One question to the customer settles
  it and is cheaper than any build.

- **D17 — #16 gets the CAPABLE fix, not just the honest one — and the honest one
  is deliberately deferred.** Two halves exist:
  (a) **capable**: teach `normalize_filter_map/1` a `when is_list(l)` clause that
  AND-composes each element through the existing flat parser, flip
  `capabilities.ex:911` `repeatable: false → true` on `filter`, and have
  `applyQuery` emit the list form for repeatable flags. Pure capability, no compat
  break. **This wave.**
  (b) **honest**: make `Repeatable:false` MEAN something in `splitArgs` — measured
  at 22 lines with the ENTIRE repo Go suite green and ZERO in-repo scripts broken.
  **Deferred to the backlog with an owner ruling attached.**
  *Why (b) waits despite being proven safe: it converts ~148 non-repeatable flag
  declarations (82 distinct names, 150 commands) from silent last-wins into exit 2,
  and the population at risk — the `CMD="bp doc ls --limit 10"; $CMD --limit 100`
  idiom in other people's scripts — is unmeasurable from inside this repo. For
  `--filter` a repeat LOSES A CLAUSE (a lie); for `--limit` last-wins is the
  override semantics every CLI on earth has. Shipping (a) closes what Gyldendal
  actually asked for; shipping only (b) and reporting #16 fixed would be exactly
  the S2 sin.*
  Note for whoever takes (b): `Repeatable` is already honoured by ONE surface —
  `mcp_bridge.go:221/302` emits an array schema for repeatable flags and a scalar
  otherwise, so **an MCP client cannot express the bug; only the CLI can.** And
  `repeatable: false` is written exactly ONCE in all of `api/lib`, on this flag.
  Someone typed the constraint on purpose and nothing on the wire path reads it.

- **D18 — #3's fix REFUSES; it must never FOLD. This is a hard constraint, not a
  preference.** The mechanism, proven end-to-end through the real mutate
  controller: `from_envelope/1` (`writer.ex:1165`) branches on *"is there a MAP
  under the key `content`"* — nothing about caller intent — and on that branch
  passes `attrs` through VERBATIM, so flat sibling keys stay top-level and die
  silently at `Document.changeset/2`'s 11-key `cast/3` whitelist. **Nobody wrote a
  line that says discard this.** The trigger is therefore a FIELD-NAME COLLISION,
  not a malformed request: a pure flat Sanity document whose own editorial field is
  named `content` (a Norwegian localized body, `content: {nb: "…"}`) returned 200
  and lost `slug`, `publishedAt` and `authorRef`. All four create-family verbs drop
  identically; the response carries keys `["results","transactionId"]` and no
  warning.
  *Why no-fold: `mutations.ex:876`'s ledger close-bypass guard resolves payloads
  through the SAME `from_envelope/1`, so on a mixed shape it sees only the nested
  map and is blind to flat siblings. That is safe TODAY only because the drop also
  prevents those siblings from landing. A well-meaning "just merge the orphans
  into content" fix SHIPS A TASK-LIFECYCLE BYPASS.* **Decision: 422 naming the
  discarded keys** — `out |> Map.drop(@reserved_in) |> Map.keys()` yields them
  exactly, at the line that throws them away. Loud, not advisory: the failure mode
  of a warning in a bulk migration is precisely Gyldendal's story. Callers this
  breaks are losing data right now and do not know it.

- **D19 — S2's chokepoint relocation SHIPS WITH ITS ERROR MAPPING AND ITS STUDIO
  ARM, or not at all.** Making both silent arms strict (`apply_field_op/4:548` and
  hasStrong's `:error -> query` at `:524`) was run-proven free: **`27 doctests,
  14246 tests, 0 failures`** on the full suite. No opt-in list is needed. But two
  things the census could not see:
  1. **Strictness ALONE regresses the refusal shape 400 → 500.** With the
     controller guard deleted, the escaping exceptions reach Phoenix; one broken
     contract test is literally named *"a range op with a non-scalar
     (array-bracket) value is a 4xx envelope, not a 500"*. The controller guard is
     not redundant defence — it is the only thing that shapes a refusal.
  2. **The desk-chip hazard is real and the green suite is exactly why nobody
     notices.** `PaneBuilder.build` with a customer desk group carrying a typo'd op
     RAISES — from `shared.ex:786`, inside the LiveView. `desk_groups` is cast as a
     bare `{:array, :map}` with NO content validation, so the typo is accepted at
     write, stored, and detonates at render. **No test covers this shape.**
  *Also: the named mutation-proof target is VACUOUS.
  `query_controller_filter_test.exs` is a white-box unit test calling
  `invalid_filter_op_for_test/1` directly — delete the guard and it fails to
  COMPILE, proving nothing. Re-point every mutation proof at
  `test/barkpark_web/contract/filter_ops_test.exs` (ConnCase, real HTTP), where
  the mutation bit properly: 19 tests, 4 failures with the guard deleted, 0 with
  it restored.* And the existing refusal is **400 `invalid_filter`**, not the 422
  this charter and the wish both assert.

- **D20 — THE REPORT DECAYS IN BOTH DIRECTIONS, and so does this charter. Re-pin
  before you quote.** #9's headline half is fixed (`bp whoami` → `auth_tier admin`,
  exit 0) and its ADJACENT half is a fresh confirmed defect: `bp auth me` returns
  *"authentication required — run bp setup"* at exit 3, seconds later, in the same
  shell, with the same config that `bp whoami` just used. A prior-art task
  (`gr-bl-tasks-route-parent-filter-ignored`, "MEASURED TWICE") is likewise
  REFUTED on current main — 9 docs, one parent.
  *Gate baseline, re-derived at `f0b2bdcf2`:* all three renderable required
  contexts GREEN (`Elixir gate`, `Cloud gate`, `Console gate`); the fourth,
  `PR references an active task`, renders on PR heads only — its absence on a main
  commit is CORRECT, not a red. **`go-tests` is neither required nor excluded** —
  it carries a workflow-level `paths:` filter, so it can never gate a merge; its
  red is advisory-by-absence. And the "Go is red on main" premise is **7/8
  obsolete**: the chronic failure was `TestMomentumInFlightDenominatorCollapsed`
  (internal/taskboard), fixed by `0bdc9f8bf2` four hours before this wave started.
  The residual `TestRemoveFullCycleByteClean` flake is real, diagnosed
  (`snapshotTree` walks the fixture's `.git` with no exclusion; CI's git 2.55
  creates `.git/objects/maintenance.lock` mid-walk, this host's 2.39.5 does not)
  and **structurally unreproducible locally** — do not let a builder chase it.

## Roadmap

Nine slices, all filed and published under GOAL `task-3f1fe755ed53738e`:

| Slice | task_id | prio | Findings |
|---|---|---|---|
| S1 — Tenancy inversion: prove or refute the one-bug hypothesis | `task-3a5a2a0662b0a661` | 0 | #1 #5 #6 #7 #8 #15 #34 |
| S2 — Silent failures: never answer success for work not done | `task-19b7ca7ff92fb710` | 0 | #2a #2b #3 #14 #20 #21 |
| S3 — Media pipeline: sniffing, delete atomicity, receipt, metadata | `task-57ee9fff4aae9217` | 1 | #4 #11 #12 #13 |
| S4 — Query surface and data plane | `task-7b361c1ea0217afb` | 1 | #16 #26 #28 #30 |
| S5 — One response envelope | `task-840853f7e84dfcb1` | 2 | #19 #31 |
| S6 — Mutation and draft semantics | `task-7f06080cfd584194` | 1 | #17 #18 #29 |
| S7 — CLI contract and operations | `task-f0e49432f1653c2f` | 1 | #27 #32 #33 (+#9 close) |
| S8 — Schema language | `task-6bfcb72042178fd0` | 2 | #22 #23 #24 #25 |
| S9 — Studio editorial quality | `task-6d80c6cc7d97b1d1` | 1 | #35 + rich text, preview, altText |

**Wave 1 = S1 + S2** (both priority 0), CUT INTO EIGHT SLICES — see the wave
plan below. Three of the original S1 members were closed by merges that landed
DURING this wave (`#12826` `#12824` `#12827`); #7 and #9's adjacent half moved to
the backlog; #34 and #15 moved to the Studio principal-kind family.

Original framing, for the record: S1 is the root-cause diagnosis that S3's
403s, S8's private-vs-public conflict and S9's preview token tier all depend on;
S2 is the defect class the customer named as costing the most hours. They are
file-disjoint enough to run together: S1 lives in `api/lib/barkpark_web` router
and plugs plus `internal/manifest/url.go`; S2 lives in
`api/lib/barkpark/content/query.ex`, the create path, and `internal/cli/cli.go`.

Later waves take S3/S6/S7 (build-shaped), then S4/S9, then S5/S8 (contract and
expressiveness, largest blast radius, last).

## Standing rules for every wave

1. **Re-verify before you build** (D1). Run output, not reading. The report is
   three weeks of commits stale and already wrong once.
2. **Mutation-prove every fix.** A test that cannot fail is not evidence
   (`make-the-check-able-to-fail`). Re-introduce the defect and watch it red.
3. **Never fix 4 and leave 15** (D7). Census the family; defer explicitly with a
   reason, never silently.
4. **Read denial is 403, never not-found** (D8).
5. **Honest close.** A finding that is already fixed closes WITH EVIDENCE and is
   reported to Gyldendal as fixed — not quietly dropped, and not rebuilt.
6. **Their credit is part of the deliverable.** This is the best external field
   report the project has received. The eventual reply paper should say which
   findings were already fixed, which we fixed, which we are declining and why.


## Wave 1 plan (Decide, 2026-08-20)

Wave Paper: `gyldendal-field-report-wave-2026-08-20`. Eight slices, all children
of GOAL `task-3f1fe755ed53738e`.

| # | Slice | task_id | round | model | surface |
|---|---|---|---|---|---|
| 1 | Studio principal-kind: the flat→scoped funnel and the switcher (#34, #15's sibling) | `gfr-w1-studio-principal-kind` | 1 | fable | `studio/scope_resolver.ex`, 2 redirect controllers, `studio_chrome.ex` |
| 2 | The two pipeline mounts `#12826` did not reach (#15, fleet-support-token) | `gfr-w1-pipeline-tenancy-remnants` | 1 | fable | `router.ex` pipelines, `fleet_support_token_controller.ex` |
| 3 | Workspace controller: bind the human creator; stop 404-ing a known workspace (D13 Tier A, D15) | `gfr-w1-workspace-creator-and-denial` | 1 | fable | `workspace_controller.ex`, `tenancy.ex`, a backfill task |
| 4 | The filter chokepoint: strictness + error mapping + the Studio desk arm (D19) | `gfr-w1-filter-chokepoint-strict` | 1 | fable | `content/query.ex`, `schema_definition.ex`, `studio/pane_builder.ex` |
| 5 | Repeated `--filter` composes with AND, end to end (D17a, #16) | `gfr-w1-filter-and-composition` | 1 | fable | `query_controller.ex`, `capabilities.ex`, `internal/cli/run.go` |
| 6 | The write spine stops eating documents named `content` (D18, #3) | `gfr-w1-write-spine-collide-refusal` | 1 | opus | `content/writer.ex` |
| 7 | Per-field op capability table — the wrong-column zero rows (D3) | `gfr-w1-per-field-op-table` | 2 after 4 | opus | `content/query.ex` |
| 8 | The stdin guard fires on 72 write commands and only 13 can consume stdin (#20) | `gfr-w1-stdin-guard-altitude` | 2 after 5 | opus | `internal/cli/run.go` |

HIGH-FLIP-RISK (a second independent reviewer is owed before merge): slices 1, 2
and 3 — every one turns on a tenancy/principal-kind judgment, and every one has
already had a premise refuted once in this wave.

## Standing rules — amended

7. **Re-pin the baseline before quoting a decision.** This charter's own triage
   pin went five heads stale inside one wave, and three of those heads closed
   findings the wave was about to build. `git rev-parse origin/main` first.
8. **A green suite is not a safe suite.** Twice this wave a passing test file was
   the reason a defect survived: `sibling_controller_leak_test.exs` names
   `/v1/schemas` and tests the SCOPED door, and `mix test` silently drops
   non-matching paths so a three-file command reported "18 tests, 0 failures"
   while two of the three files did not exist. Name what actually ran.
9. **A guard belongs in the room, not at the door — but it ships with the room's
   furniture.** D19 is the shape: relocating a refusal downward without its error
   mapping and its UI arm converts a silence into a crash, which is worse.
