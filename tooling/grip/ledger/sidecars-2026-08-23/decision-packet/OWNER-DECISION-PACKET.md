# Owner Decision Packet — 2026-08-23

**Corpus:** 2,338 open rows pulled paged (`lifecycle_status=open`, limit 200, offsets 0–2400) at 2026-08-23T17:2xZ. Read-only: nothing claimed, stamped, closed or built.

**Selector:** an UNMET criterion matching `owner ruling|owner decides|owner confirms|owner reads|sign-off|ruling|human gate|owner must|owner picks` — with merge-gate wording (`MERGE-GATED`, `LEAD closes`, `the PR is merged`, `merged to main`, `once merged`) excluded **per-criterion, not per-row**, so a row keeps its place if any one criterion is a genuine fork. That yielded **148 rows**, of which **142** carry at least one non-gate ruling criterion and **6** match only inside gate wording.

**The collapse: 148 rows → 19 real decisions.** Ordered by rows unblocked, descending.

---

## D1 · Restart the PPCC block-id migration, or retire it — **37 rows**

**The fork:** Staff `task-57451a6ce0a0505e` (93 shards, 37 currently open) to completion, **or** declare the PortableDoc stable-block-id migration abandoned and cancel the shards.

**Evidence already gathered.** The root row states it plainly: each `ppcc-build-task-NNN` owns exactly three Papers and runs `mode=apply` of `ppcc-e012-portabledoc-migration-and-reader-gate-v1`; the applied repair is overwhelmingly `add_stable_block_id`. It is a **mechanical data migration, not editorial polish** — the parent epic's prose misdescribes it, which is likely why it stalled. The shards sat at **priority 0 in the ready queue for three weeks while 7% built**. The original parent `task-f5cbd8be8f278caf` is `done`, closed on "586/586 editorial outcomes, zero hard failures" — a close the root row itself argues is defensible for the ANALYSIS phases and **not** for this build phase. All 37 are unclaimed.

**Costs.** RESTART: ~37 shards × 3 Papers = ~111 Papers, each needing preimage/postimage or no-op proof plus rollback evidence (criterion 2 on every shard). RETIRE: the published Paper corpus keeps unstable block ids permanently — every downstream feature keying on block identity (comments, anchors, diffing) stays unbuildable.

**Recommendation: RESTART, but re-title the shards first.** The single highest-leverage act is one sentence — the titles are opaque hashes (`PPCC-B017 sealed shard 19c639d5 23b06a7a…`), which is *why* nobody picked them up at priority 0 for three weeks. This is the cheapest 37 rows on the board and the work is mechanical. If you will not staff it, cancel all 37 explicitly — leaving them open at priority 0 poisons every `bp task ready` read.

**Clears:** `task-57451a6ce0a0505e` + `ppcc-build-task-{001…100}` (37 open today).

---

## D2 · Where do orphaned rows go when their epic sealed? — **177 rows**

**The fork:** Adopt a standing rule — an open row under a `done` parent is either (A) **auto-reparented** to a named successor epic or a standing backlog root, or (B) **auto-cancelled** at seal time — **or** rule case-by-case, 47 times.

**Evidence (measured here, and it corrects the brief).** 177 open rows sit under a parent that is not open, across **47 parents**: 44 `done`, 2 `MISSING` (the parent document does not resolve at all), 1 `cancelled`. **I measure 177, not ~256** — my convention is *direct* parent only, over the 2,338-row open set; a recursive walk or a different open-set snapshot would count higher. Stating the convention because this packet is worthless if its numbers are quoted without one.

Biggest concentrations: `spd-b39-user-opened-inspector-shape-successor` 31 · `pds-w1-crown-proof` 21 · `jarl-flagship-epic` 18 · `bp-scaffy-epic` 10 · `task-09f4775e7ccc2cca` 8 · `jarl-innleggene-epic` 8 · `task-tui-goal` 6.

The two `MISSING` parents (`codebase-quality-goal` 4 rows, `security-hardening-goal` 3 rows) are worse than orphaned — their parent id resolves to nothing, so those 7 rows cannot be found from any tree walk at all.

**Costs.** (A) Reparenting preserves the work but inflates whichever root receives it. (B) Cancelling 177 rows destroys real filed findings — several carry measurements. Case-by-case is 47 separate readings and is how they got here.

**Recommendation: (A), with a seal-time gate.** Make "zero open children" a *precondition* of sealing rather than a thing discovered afterwards — the seal text already names an open-row-under-a-done-parent as the shape that "disappears from every triage," so the doctrine exists and only the enforcement is missing. Retire the 2 MISSING parents first; those 7 rows are invisible today.

**Clears:** 177 rows across 47 parents (list at `orphans.json`).

---

## D3 · The `cch-w53` fix-or-waive batch — **10 rows, one sitting**

**The fork:** ten independent console defects, each carrying the **byte-identical** criterion *"The fix (or the explicit ruling that no fix is warranted) is decided and recorded, naming which of the options in this brief was taken and why."* This is one template, so it is one sitting — but **ten separate yes/no answers**, not one. Do not answer it once.

| Row | The actual question |
|---|---|
| `cch-w53-bl-the-emailed-confirmation-link-has-no-client` | Console mails a confirmation link nothing handles. Build the handler, or stop mailing it? |
| `cch-w53-bl-the-support-claim-discards-five-keys-including-a-live-agent-token` | Support provision ships 5 keys the worker cannot receive, one a fresh agent token. Stop minting, or add the fields? |
| `cch-w53-bl-env-var-round-2-product-call` | **Explicitly labelled LEAD DECISION OWED.** Does the team env-var feature survive now that the console stops promising delivery? |
| `cch-w53-bl-site-deleted-audit-discard-after-a-hard-delete` | `site.deleted` discards its audit result; the obvious fix creates an inverse orphan. Accept the gap, or take the orphan? |
| `cch-w53-bl-per-row-session-revoke-does-not-end-that-sessions-stream` | Per-row revoke leaves the device event stream live. Needs a new column — worth it? |
| `cch-w53-bl-a-produced-twofa-row-is-unreadable-to-the-member-who-acted` | A member enabling 2FA writes an audit row only their admin can read. Widen the read, or accept? |
| `cch-w53-bl-device-push-tokens-survive-sign-out-everywhere` | Sign-out-everywhere misses push tokens; copy says "device". Latent (push unconfigured). Fix now or when push ships? |
| `cch-w53-bl-env-var-rows-drop-the-timestamps-the-wire-already-carries` | Row discards `inserted_at`/`updated_at` the wire already sends. Render them? |
| `cch-w53-bl-record-audit-discard-census-criterion-1-is-too-wide` | A sibling row's criterion 1 would force a harmful mass conversion. Narrow it? |
| `cch-w53-bl-escape-ratchet-is-literal-shaped` | Path-escape ratchet sees only double-quoted literals; a segment-list read is invisible. Widen the ratchet? |

**Recommendation.** Two are **product calls only you can make** — `env-var-round-2` (self-labelled) and `the-emailed-confirmation-link` (a live user-visible dead end). Rule those two yourself. The remaining eight are engineering-severity calls with the options already enumerated in each brief; **delegate them to the CCH lead with a default of FIX**, except `device-push-tokens` (recommend **defer to when push ships** — it is structurally real but latent, and a fix now cannot be tested).

**Clears:** all 10.

---

## D4 · Is membership the tenant predicate? — **~9 rows, and it unseals an epic**

**The fork (A/B, already written on the row):** (A) **RATIFY MEMBERSHIP** — `Barkpark.Tenancy.Auth.authorize/3`, the repo's declared tenant chokepoint — or (B) **KEEP `workspace_id`-with-nil-escape**.

**Keystone:** `task-46e7d44068e7185e` (priority 0, unclaimed, `NO CODE SHIPS FROM THIS ROW`). Its criterion 0 explicitly fences it: any build-shaped work found while ruling is filed as a separate row.

**Why it is worth more than one row.** `api-read-path-security-sweep`'s own criterion 2 says the epic **cannot seal** until this ruling *and* `pdf-bl-anon-read-exposure` (packet already written: `/papers/arpss-anon-exposure-ruling-2026-08-17`) are both ruled **with their downstream amendments made**. Sequenced behind it: `arpss-share-controller-edit-token-authz` criteria 4 and 6 (a nil-workspace admin seeing all — the direct conflict), open **PR #12404** which must be re-planned, and `arpss-flat-doc-mutate-default-scope-write` which the row notes is *currently recorded as DELIBERATELY UNRULED* — and which a membership predicate would answer as a side effect.

Siblings in the same authz family, each a separate but smaller ruling: `arpss-w10-bl-admin-capability-grant-mintable-over-http` (POST /v1/access mints admin-capability grants with no narrowing), `arpss-w10-bl-workspace-admin-denies-custom-role-admin`, `arpss-schema-action-write-tier-ruling` (schema mutation + bulk-publish are `:write`, not `:admin` — any write member can restructure schema), `arpss-w9-bl-role-permits-builtin-reachability-tripwire`, `arpss-w8-require-admin-workspace-blind-program` (~40 routes), `arpss-bulldocs-anon-paper-event-write-ruling`, `arpss-classa-lowsev-hygiene-rulings`, `arpss-media-callback-signed-tokens`.

**Recommendation: (A) RATIFY MEMBERSHIP** — it is the repo's *declared* chokepoint, so (B) keeps a documented lie standing, and (A) also resolves the deliberately-unruled Default-binding question instead of deferring it a third time. Cost is honest and stated on the row: three downstream amendments plus re-planning PR #12404. **Rule `arpss-schema-action-write-tier-ruling` in the same sitting** — "any write member can restructure schema and bulk-publish" is the sharpest item in this family and it is independent of A/B.

**Clears:** `task-46e7d44068e7185e`, `pdf-bl-anon-read-exposure`, unseals `api-read-path-security-sweep`, and sequences 7 sibling rulings.

---

## D5 · Enable branch protection / required checks — **~5 rows, and every gate this repo ships is advisory until you do**

**The fork:** Perform the `required-checks-apply.sh --confirm` PUT (owner-only; no agent may), or rule that checks stay advisory.

**Evidence.** `pds-bl-go-tests-not-required`: *"The Go suite runs on every .go PR and cannot refuse a merge — so every Go gate this epic ships is advisory."* `hg-bl-branch-protection-required-checks`: *"Nothing in this repo is required-by-name"*, and it names the ordering constraint — **path-filter skip-shims come first**, or correct PRs red. `cch-w37-bl-register-spec-gate-human-gate` wants the spec gate registered as the fifth required context and carries a costed sequence. `dr-bl-internal-tree-has-no-blocking-gate`: `internal/**` trips **zero** required contexts while auto-deploying to production. `task-b3c622daa4087f52`: `scaffy-catalog-drift` has never been green as an acting gate — six reds since promotion — blocked on an unminted `BARKPARK_SEED_TOKEN` repo secret no agent can install.

**Recommendation: DO IT, in the stated order** — skip-shims, then the PUT. This is the highest-leverage item on the whole board that is not a decision at all but an *action*: until it lands, every merge gate in every epic is decoration. Mint `BARKPARK_SEED_TOKEN` in the same sitting.

**Clears:** `hg-bl-branch-protection-required-checks`, `pds-bl-go-tests-not-required`, `cch-w37-bl-register-spec-gate-human-gate`, `dr-bl-internal-tree-has-no-blocking-gate`, `task-b3c622daa4087f52` (partially — its criterion 0 is a real diagnostic question: which of two causes does that gate actually report, and does either mask the other).

---

## D6 · A default retention rule for unbounded tables — **4 rows**

**The fork:** Adopt a standing rule (every durable record gets a bound or an explicit written "unbounded is correct" with its growth rate measured), or rule each table separately.

**Evidence.** `dr-bl-deployments-table-grows-forever` ("a fifth unbounded table nobody named"), `dr-w23-bl-run-state-dir-has-no-swept-siting` ("no siting that is both swept and safe"), `cch-bl-lifecycle-token-reaper` (reset/confirm/change_email `user_tokens` have no reaper — and it asks a second, real question: **no-grace like the sibling reapers, or a grace window longer than the largest throttle window?**), `dr-w29-bl-no-sent-email-body-is-recoverable-anywhere` (which is really a **PII/retention position**, not a bound — it must be stated *before* any body is stored).

**Recommendation: adopt the standing rule.** Three of the four rows already phrase their criterion in exactly that shape ("a bound, or an explicit ruling that unbounded is correct **with the growth rate measured**"), so the doctrine is already written four times — ratify it once. Rule the email-body PII position **separately and first**; it is the only one where the wrong default is irreversible.

**Clears:** 4 rows, and pre-answers the shape for future tables.

---

## D7 · The map-landing contradiction — **2 rows, and building either reds the other**

**The fork:** Which framing is true — fail-**closed** (`dr-bl-map-landing-empty-marker`: the marker emptied and the cause is discarded) or fail-**open** (`dr-w17-bl-map-fail-open-premise-is-inverted`: the marker *can never* be empty, so the gate can never refuse)?

**Evidence.** Row 2 is the later, better-measured row and it refutes row 1 directly: `listings.ts` falls back to `SAMPLE_LISTINGS` on every arm via the `!LISTINGS_TYPE` early return, so **row 1's criterion 1 is dead code** — it asks for an emit that can never fire. Row 2 also records the blast radius honestly: **zero place-directory sites, zero of 31,137 rows**, and a live `/proc` environ read over 11 slots showing no `NEXT_PUBLIC_*` or `LISTINGS_TYPE`. It names `lib/graph.ts:273-283` as the in-repo precedent for the three-way distinction (unconfigured / empty / upstream-failed).

**Recommendation: adopt the fail-OPEN framing (row 2) and rewrite row 1 to match, do not build row 1 as written.** Row 2 has the measurement and the precedent; row 1 has prose. But note the honest consequence row 2 itself records: impact is **zero sites today**, so this is a correctness-of-the-ledger fix, not a user-facing one — schedule it accordingly. Row 2's criterion 3 (`templates.ex:84` publicly advertises an uncarryable env key) is a genuinely separate defect and should be split out.

**Clears:** 2 rows; prevents one wasted build.

---

## D8 · The `dr-w35` durable-venue batch — **3 rows, one sitting**

Byte-identical criterion across three rows: *"The defect is fixed or explicitly adjudicated, with the deciding command output or ruling recorded in a durable venue the merge carries, and the evidence NAMES WHICH venue."*

- `dr-w35-bl-charter-d106-phantom` — the charter cites **D106 as law but defines it nowhere**. Restore the definition or strike the citation.
- `dr-w35-bl-digest-blind-to-never-covered-sites` — the digest discards the never-covered site names the ledger now computes. Render them or record the silence.
- `dr-w35-bl-wave-papers-422-semantic-empty` — the epic's own wave 32/33/34 Papers **422 on every public reader edge**.

**Recommendation: FIX all three; none needs a product call.** D106 in particular is a phantom law being cited as binding — that is a correctness bug in the charter, not a decision. Ruling "adjudicated" on any of these three would be using a decision verb to avoid a small fix.

---

## D9 · PR #10129 — supersede D185, or close the PR — **1 row + 3 sequenced**

**The fork:** the lead either **supersedes charter D185 in writing** (ratifying two ladder rulings on their merits — `deploys_failing` outranking strained/filling/unreported, and `unmetered` as a discontiguous rung) **or closes PR #10129**. `dr-w24-bl-129-ladder-decision-is-owed`, priority 1.

**Evidence, re-derived 2026-08-08 and unusually complete.** All four required contexts **GREEN**; it passes the task gate today (`open_lead +1737s`) and the gate is **push-invariant, so a rebase-and-push is safe from the lease angle**. It conflicts with main in **six paths**, and that set is **unchanged after the four predecessors merge — so ordering buys it nothing**. Charter D428 records the tension and defers to D185. Wave-24 lead notes say "rebase-not-close", which **overrides a ratified decision** — that conflict is the thing you are being asked to settle.

**Hard constraint on the row, worth repeating:** never close/reopen it and never re-cut onto a fresh PR — a fresh `created_at` is past every lapse and the required task gate reds for real.

**Recommendation: no recommendation on the merits — this is genuinely yours.** The two ladder rulings are product semantics (what a deploy status *means*), and I have no evidence about which ordering is right. What I can say is that the **cost of a fourth wave of deferral is now larger than either answer**, and the row states it: leaving it open a fourth wave is the cost. Pick either; the mechanics are safe in both directions.

---

## D10 · Public-mirror exposure — **1 row, and it is the one that gets worse while it waits**

**The fork:** keep-public / dataset-scope / allowlist / body-strip / separate-private-repo. `github-bridge-mirror-exposure-decision`, unclaimed since **2026-07-10**.

**Evidence, and the growth is the finding.** At filing: **609** App-authored issues on public `FRIKKern/barkpark` (was 442 the day before — ~100/day), 100% authored by the bridge App, 0 human-authored. **Today: 4,173** (count supplied by the lead's census — I did not re-run `gh api` myself). That is roughly **6.8x** in six weeks. Bodies carry full internal engineering prose with `file:line` paths, internal doc ids and acceptance checklists; **labels leak worker identities** (`worker:fable-main`, `worker:cmux-smoke-…`), priority and status. Dataset scoping already exists as `:github_mirror_datasets` (`settings.ex:149-159`) but is coarse. The row's criterion 2 has held: zero destructive action taken, no bulk close, no visibility change.

**Recommendation: rule it this week, and if you cannot decide the end state, take the reversible half now — turn the mirror OFF or scope it via the existing `:github_mirror_datasets`, then decide.** Every option except keep-public gets more expensive at ~100 issues/day, and the reversible action costs nothing. Note the row's own instruction: **re-count at ruling time; do not trust the number.** Related debris, separate rows: `spd-b45-deleted-task-orphans-github-mirror` and `gr-bl-throwaway-mirror-orphans-sweep` (deleting a task never closes its mirror issue).

---

## D11–D19 · Single-row rulings that do not collapse

Each is a genuine, independent fork. Listed with the fork only; all are unclaimed.

| # | Row | The fork |
|---|---|---|
| D11 | `pds-w29-bl-twin-policy-split` | Four readers hold **three different draft-twin policies** and none labels a row as a draft. Which policy per surface — and must a draft be VISIBLY labelled on every reader? (4 criteria, 4 code sites) |
| D12 | `cchi-w67-bl-the-epic-paper-floor-forbids-the-spacing-doctrine` | The Paper publish floor hard-fails on `empty_paragraph_spacer`; the Mechanical Spacing Doctrine **requires** it. **Two laws contradict — one document must change.** Which? |
| D13 | `dr-w16-bl-platform-admin-emails-human-gate` | Should `PLATFORM_ADMIN_EMAILS` be set on prod? Unset today, so the operator deploy census **403s for every account**. |
| D14 | `dr-bl-w7-bless-v0-2-26-ordering-hazard` (priority **0**) | Arm `BARKPARK_SELF_UPDATE_APPLY=1` on four frozen boxes, or freshen over ssh? **Different blast radii.** Blessing v0.2.26 first would permanently pause five of six boxes. |
| D15 | `pws-bl-claude-md-deploy-rules-false-as-instruction` (priority **0**) | CLAUDE.md **Golden Rules 1, 2 and 7 are false as instructions** — following GR1 literally on the server nukes the live serving build. Needs owner sign-off to edit the verbatim-exempt block. |
| D16 | `dr-w19-rollout-brake-is-machine-only` | The fleet rollout brake is readable only by a machine token. Ship a human-tier read route + `bp` verb, or rule it machine-only? (the census predicate must be revisited either way) |
| D17 | `dr-w14-bl-pat-cannot-read-the-owners-number` | No automation credential can compute a site owner's deploy number. Re-tier the list route, or **deliberately refuse** automation access? Cross-epic with cloud-console-hardening. |
| D18 | `dr-bl-graph-phantom-id-exposure` | Are `/v1/graph` phantom node ids a public-read leak? **Explicitly a DECISION ROW answered by MEASUREMENT** — per field shape, show live whether a public caller can already read the target id via `GET /v1/data/doc`. |
| D19 | `ecd-bl-charter-corpus-hygiene` | The tracked charter corpus **publishes prod IPs and a customer email on a public repo**. Accept / scrub-forward / redact-worst? |

---

## Findings — rows I am DROPPING from the packet

Per the quality bar: these matched the selector but do **not** ask the owner anything.

1. **Six rows match only inside merge-gate wording.** Their "ruling" word sits inside a `MERGE-GATED`/`LEAD closes` clause. They need a flag set, not a decision.
2. **`connectors-mcp-serve-citation-hygiene`** — the word "ruling" appears because the row is about *miscited* charter rulings (`mcp_serve.go` over-cites D18 7× and miscites D19 for the loopback-proxy shape). It is a **comment-fixing build task**, not a decision.
3. **Rows whose "RULED ADDITION" criteria record rulings that ALREADY EXIST** — e.g. `cch-w44-bl-me-envelope-census-blindness-is-dodgeable-by-dotting` criteria 4 and 5 are stamped *"coordinator ruling 2026-08-23, fail-closed adopted."* The decision is made; the build is owed.
4. **`cch-w17-bl-css-slice-gate-must-include-leg-a`, `dr-w34-bl-seal-run-predicate-flag-is-a-decoy`, `cch-w19-bl-op-gate-dot-centring-at-320`** — these carry *"REWORDED 2026-08-22 (bucket-D dead-clause sweep, lead ruling)"* provenance text. The ruling happened; the word is a citation.
5. **`clk-bl-mirror-job-snooze-ceiling-unasserted`** — pure build task; it matched the mirror keyword only.

**One caution I could not fully discharge.** `cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width` looks gate-only at a glance, but its criterion 1 demands a real **reachability answer** (can a person obtain the full identity value any other way — the wave-31 reading found `app.js:757` renders `<div class="am-line">` with **no title attribute**, so at that tree the answer is no), and a sibling row `cchi-w26-bl-eight-live-rows-can-never-be-stamped` requires it be **driven at 320–900 in both themes before any build decision**. This is exactly the trap you flagged. It is a genuine ruling and it is in D3's family in spirit, but it needs a measurement run first, which I did not perform.

---

## Method caveats, stated rather than hidden

- The corpus is a **snapshot**; rows move. Every count above is as of the pull, and the pull convention is stated with each number.
- **`criteria_progress` does not exist** in `bp doc query` output — all met/unmet derivation is from the top-level `acceptance_criteria` list.
- The **orphan count is 177, not ~256** (direct-parent convention over the open set). I did not reconcile to 256; a different convention would be needed and I did not want to quote a number I had not taken myself.
- Ownership was checked with `bp doc get task <id>` on the keystone rows of D1, D4, D7, D9, D10 — **all unclaimed**. I did not check all 148.
- Checkpoints: `open_all.json` (2,338 rows), `hits.json` (148 selected), `orphans.json` (177 rows by parent), `raw/open_*.json` (13 pages).
