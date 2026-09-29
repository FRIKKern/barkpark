<!-- doc-tier: agent | canonical-for: success-claim-census | budget: 4800tok -->
# Success-claim census — where the law is enforced, and where it plainly is not

**The law (PDS wave 22).** No Barkpark verb may report success on an exit code alone.
Every success claim must be backed by a post-condition READ of the state it claims to
have produced, and any claim it cannot back must say so in the same breath.

**Every integer below is a READ, and each one names the command that re-reads it.**
Re-derive, never transcribe; figures here were derived at `4f98108a2` unless stated
otherwise.

**The ruling this census classifies against (PDS-D313).** "Response-backed" is three
classes, and the axis is the MEASUREMENT POINT — not response-vs-second-read:

| class | what it is | verdict |
|---|---|---|
| **A1** | relayed post-condition — the server measured the field AFTER the change, FROM the state | satisfies the law; no second read needed |
| **A2** | persisted-record echo — the server echoes back the record it wrote | satisfies the law for claims ABOUT THAT RECORD |
| **A3** | verb-derived / request echo — the sentence is keyed on the local verb or on what we asked for | **VIOLATES** the law, even though a round trip happened |

The mechanical test, and the only admissible evidence: **would the printed sentence
change if the response said the opposite?**

## Go CLI — ENFORCED, behaviorally, mutation-proven

`internal/cli/success_claim_registry_test.go` is a table-driven gate over an enrolled
registry of receipt-RENDER functions. Each row carries the real production function
plus two responses that disagree about the post-condition; the test asserts the
printed line CHANGES. A classification string cannot satisfy that — and
`TestSuccessClaimRegistryCarriesNoProse` reflects over the entry struct to prove no
prose field exists to hide behind. `TestSuccessClaimRegistryHoldsItsFloor` fails when
an entry is un-enrolled, so the registry can only grow.

**The enrolment count is COUNTED, never listed here.** A transcribed inventory of row
names goes stale the first time the registry grows. Count it instead:

```sh
awk '/^func successClaimRegistry\(\) \[\]claimSite \{/,/^\}/' \
  internal/cli/success_claim_registry_test.go | grep -c '^\t\t\tName:'
```

**Why behavior and not a glyph lint.** Three measured facts kill the grep, and each
names the exact command it rests on so a reader can refute it:

| fact | command | today |
|---|---|---|
| `vercel_cmd.go` carries checkmarks… | `grep -c '✓' internal/cli/vercel_cmd.go` | 13 |
| …and a print-call glyph lint reaches NONE of them — every one is an argument to the `out.progressf` wrapper, not to `fmt.Print*` | `grep -cE 'fmt\.(Print\|Printf\|Println\|Fprint\|Fprintf\|Fprintln)\([^)]*✓' internal/cli/vercel_cmd.go` | 0 |
| in `api/lib` almost every glyph is LiveView chrome, not a claim | `grep -r -o '✓' api/lib \| wc -l` and `grep -rl '✓' api/lib \| wc -l` | 49 across 17 files |

`barkpark status` and `bp export` print success carrying no glyph at all. A gate keyed
on the glyph would be loud where there is nothing and silent where the lies are.

**The A3 lie this shipped with the gate.** `cloud_autoupdate_cmd.go`
`autoupdateReceipt` took the server-returned policy and, for `unpin`/`pause`/`resume`/
`default`, read NOTHING from it — every sentence was keyed on the local verb, so
"autoupdate paused" printed unchanged when the control plane returned `paused:false`.
Only `pin` read `policy.PinnedRelease`. Now every branch reads the returned policy, a
contradicted claim carries `✗` and names the contradiction, and `autoupdateApplied` makes
the verb exit non-zero (`ok:false` on `-o json`) instead of ticking over a change that did
not land.

**Mutation proof.** Reverting `autoupdateReceipt` to the verb-keyed original turns the
gate RED on `autoupdateReceipt/{unpin,pause,resume,default}` with `prints the SAME line
whether the server backs the claim or contradicts it`, plus four failures in
`TestAutoupdateReceiptNamesTheContradiction`. Honestly: `pin` was already A2 and does NOT
fail its registry row under mutation — the registry catches the four verb-keyed branches,
the wording test catches all five.

## Shell — NOT ENFORCED. No gate ships. Here is the measured reason.

Denominator, re-derived (`grep -rn "✓" --include="*.sh" .`, excluding `.git`): **25
glyph occurrences across 13 files**, bucketed:

| bucket | count | evidence |
|---|---|---|
| proof harnesses | 13 | `deploy/site-spawner-live-proof.sh` 5, `-node-live-` 4, `-autorebuild-` 4 — a proof harness asserting its own findings is not a product success claim |
| `ok()` helper DEFINITIONS inside smoke/doctor scripts | 7 | `scripts/{create-quickstart,media,cmux,onramp-live-client}-smoke.sh`, `scripts/{doctor,bp-vercel-quick-setup,local-update}.sh` — one definition each; the claim lives at every call site, which the glyph never reaches |
| comments | 2 | `scripts/{demo-living-values.sh,taskboard-drive/drive.sh}` |
| **real product success claims** | **3** | `templates/place-directory/install.sh` — all three A1 since `2b99269f9`, below |

Of those three: line 49 is gated on a genuine read-back (step 3 re-queries the public
API, counts `_id`s, and prints an honest `⚠ 0 published places` instead of Done) —
**A1, compliant**. Lines 29 and 33 (`✓ schema upserted`, `✓ places written`) print on
`curl -fsS` exiting 0 — an HTTP-status echo about a record nobody read back. `-f`
makes a 4xx non-zero, so this is stronger than a bare exit code, but it is still
**A3 by the ruling**: the sentence claims the record exists and would print unchanged
if the server 200'd without persisting.

**Ruling: no shell gate.** Two sites, in one optional template installer, is not a
population a repo-wide guard can be calibrated against — a guard over 25 occurrences
of which 22 are harness plumbing greens on the plumbing and teaches the reader that
shell is covered. **It is not covered.**

**FIXED at the two sites, as ruled — no shell gate ships. 2026-09-11, `2b99269f9`,
`pds-bl-place-directory-install-echoes-transport`.** Each step now POSTs and then reads
the state back (step 2 reads `perspective=raw`, because `createOrReplace` writes the
DRAFT row and a `published` read legitimately returns 0), ticks only if what reads back
covers the mutations sent, names a `✗` and exits non-zero on a 2xx over an empty store,
and prints `CANNOT READ` when the read-back is unperformable — so a failed read is never
byte-identical to a zero. `scripts/place-directory-install.test.sh` pins it with a fake
`curl` that 2xxes every POST: 27 assertions, including a MUTATION arm requiring the
pre-fix `post … && printf ✓` shape to pass on the SAME empty fixture. Reverting the
installer reds 14 of 27. Job `place-directory-install` in
`.github/workflows/shell-harnesses.yml` — RUN, not BLOCK.

## Elixir — NOT ENFORCED. No gate ships. And the glyph census is structurally blind here.

Denominator, re-derived (`grep -r -o "✓" api/lib | wc -l`): **49 occurrences across 17
files**. Of these, **48 are LiveView/HEEx/render chrome** (live views, function
components, `root.html.heex`). A checkmark in a template is a UI affordance, not a
claim about a post-condition.

Exactly **one** console emitter carries the glyph:
`api/lib/mix/tasks/barkpark.workspace.provision_schemas.ex:115` —
`case Content.upsert_schema(...) do {:ok, _} -> Mix.shell().info("  ✓ #{name}")`.
That is **A2**: the success arm is the Repo returning the record it wrote, and the
`{:error, cs}` arm prints `✗` with the changeset errors. Compliant.

**Ruling: no Elixir gate.** A guard over one compliant site is a fake green — it would
let the next reader believe the Elixir surface is policed. It is not.

### The lie the glyph census cannot see (PDS-D311)

A glyph — or console output at all — misses the shape that bites here: **`mix
ecto.migrations` reporting `up` reads a row in `schema_migrations`; it never reads the
object the migration claims to have produced.** A migration amended in place after it ran
stays stamped `up` forever, so the trigger/index/column its amended body would have
created is absent while the check reports clean — the same A3 failure as
`autoupdateReceipt`, wearing a schema instead of a checkmark. The honest fix is a
post-condition read of the OBJECT (`pg_trigger` / `pg_indexes` /
`information_schema.columns`).

### THE POPULATION AND ITS OWNER (PDS wave 38) — `router.ex`, not the string `ok: true`

**The 98 emitted `ok: true` claims are the population of one LENS, not of the
surface.** The string `ok: true` is a convention an author may decline; a ROUTE is not. An unrouted write is unreachable, and a routed
write is in the table by construction — so the denominator's owner is
`api/lib/barkpark_web/router.ex`, and the 95 is a numerator measured against it.

**The key is the QUAD `{method, path, module, action}`**, never `{module, action}` — the
pair collapses the population and goes BLIND to a new route arriving onto an
already-disposed action, which is why `ROUTED-POPULATION-COMPLETE` reds on an UNDISPOSED
ARRIVAL rather than on a count (PDS-D524).

Derived by `scripts/pds-elixir-receipt-census.exs` (build-free AST over 825
`api/lib/**/*.ex` files, no mix project and no compile — it never boots the app; it
prints its own `user cpu … ms` line (D605) on every run, which is where a runtime figure
belongs rather than in this sentence):

| figure | today | what it is |
|---|---|---|
| routed entries from `router.ex` AST | 481 | plus 85 plugin specs mounted at 17 `plugin_routes/1` callsites |
| **ROUTED-WRITE population** | **260** | `post`/`put`/`patch`/`delete` plus every LiveView mount |
| JUDGED | 68 | reaches a receipt this lens emitted AND the register judged |
| ROSTERED | 7 | reaches a hand-named roster site outside the lens |
| EXCLUDED | 185 | committed, dated disposition row — see the classes below |
| **UNDISPOSED** | **0** | `ROUTED-POPULATION-COMPLETE` reds on this |
| sum | 260 | == the population, both directions, no duplicate key |

**EXCLUDED is not a silence — it is written, dated prose, counted by class:**
`liveview_handle_event` **40** (a LiveView route names a MOUNT; its writes live in
`handle_event/3`, which carries no routed action name to key on — 26 modules) and
`status_only_receipt` **145**, **THE HOLE**: the routed action reaches no `ok: true`
receipt this lens can see and carries no roster anchor (SCIM's three IdP write routes land
here). Most of those DO render the stored row; they just do not spell the key it greps for.

The run emits exactly these TWO classes; `action_not_in_corpus` was listed here and
occurs ZERO times in the output.

**THE JUDGMENT-COVERAGE LADDER, four rungs printed every run (wave 45):** population
**260** -> judged-coverage **75** -> VERDICTED **24** -> **PROVEN-BACKED 24 MEMBERS**. The
top rung is ONE `Enum.count` over ONE `MapSet.union` of two INDEPENDENT legs, never
`leg_a + leg_b` — OVERLAP is 0 today, so the addition prints the same 24 and the integer
is no evidence. The selftest case `LADDER-UNION-NOT-SUM` is the only discriminator:
it injects a leg-B def into leg A and requires `naive > UNION`. MEMBERS is load-bearing —
24 is also the size of a WRONG set (proven register defs union every roster def).

**THE JUDGED FRACTION IS 75/260 = 28.8%** — printed, never thresholded. Naming the 40
LiveView mounts while omitting the 145 would satisfy the letter of "excluded is
disclosed" and conceal the finding: **the largest single class in this population is a
receipt shape this lens cannot see at all.**

**LENS-CAN-MISS** — the blind-shape roll (resolved `plugin_routes/1` callsites, and every
route-generating macro this lens cannot expand) is PRINTED WITH ITS COUNT on every run as
an integrity arm. Read it there; a transcribed copy is the one that goes stale.

Re-derive every figure in this section, and every figure below it, with one command:

```sh
elixir scripts/pds-elixir-receipt-census.exs        # add --sites for all 100 emitted sites
```

### The `ok: true` lens — the numerator, and what it costs

| layer | n | what it is |
|---|---|---|
| textual occurrences | 111 | plain substring, 107 lines (`auth_controller.ex:441` carries two): 104 `ok: true` + 4 `"ok" => true` |
| AST-literal pairs | 102 | real `ok:`/`"ok" =>` pairs — a bare `{:ok, true}` tuple quotes identically and is excluded by key metadata (`format: :keyword` / `assoc:`) |
| phantoms | 9 | 8 prose in `@doc`/comments + `github/web/ops_live.ex:342`, which is `db_ok: true` — **a different key** |
| consumers | 4 | `connectors/bridge_client.ex:66,83,97` + `sync/pusher.ex:286` pattern-match a REMOTE response; they make no claim |
| **emitted claims** | **98** | the numerator over the 260 |

Routed through the call graph, defdelegate followed at **zero** depth — a rename, not
logic; charging it a hop is how the 21-entry `Barkpark.Tasks` facade makes a naive
detector report 24/25. At depth 3: write **36** / read 24 / unrouted 38. At the census
depth 6: 57 / 29 / 14. **Every write count is a FLOOR** — a function of the depth budget,
not of the code — which is why the script prints the whole sweep, and the DRIFT against
PDS-D448's hand-followed 64/17/10, rather than one integer. The buckets below are taken
over the CLOSURE population of 81.

Shapes (PDS-D453) are assertion-backed — `classified 24 + unclassified 76 == emitted 100`:
POST-READ **21** · CATCH-ALL-TO-SUCCESS **3** · UNCLASSIFIED **76** · the other four
shapes 0, each printing why it is 0. Read POST-READ as a **ceiling**: its evidence is line
order (a `Repo` read below a `Repo` write inside the writing function) — necessary, not
sufficient, since the lens cannot prove the read is *of the row written*. Only `select:`
**inside** the update query proves that; `returning:` is silently ignored by `update_all`
(`auth.ex:139-141`) and proves nothing.

**Ruling: still no Elixir gate (PDS-D454).** A population now exists on both axes, but a
gate keyed on these integers would be the number-shaped guard this epic keeps filing as a
defect. Wave 38 bucketed the write-routed sites MECHANICALLY from `router.ex`'s AST — not
by hand, and not against `ok: true`. The script ships as a census, not a check: its
*integrity* can go red, its *numbers* never do. **The wave-33 follow-on below does not
overturn that ruling — it supplies the calibration D454 said was missing, and the answer
is still NO GATE.**

**How many arms can go red — count them, never quote a number:**
`elixir scripts/pds-elixir-receipt-census.exs | grep -cE '^  (PASS|FAIL) '`. One arm is
not red-capable in normal operation — `CORPUS-INTACT` tests `files >= 600` and
`guard_corpus!/1` exits 2 on that same condition first (PDS-D467b). Every other arm is.

### The unrouted sites, and THE WRITE-RECEIPT BUCKETS (wave 33 follow-on)

Re-derived by run at `d8bd23c1d`; every integer here MOVED off the figures this section
carried, and the per-site table is `docs/ledgers/pds-w33-write-receipt-buckets.md`.

**Unrouted is 14 at depth 6, not 12 and not 10.** **11** of the 14 route at depth 10 —
all `github_webhook_controller.ex` (`:99 :100 :124 :128 :133 :165 :170 :174 :186 :202
:212`): the budget, not the code. **3 are still unrouted at closure**, reaching no `Repo`
verb at any depth — `search_controller.ex:232` (`Oban.insert()`),
`self_update_controller.ex:25`, `site_deploy_controller.ex:132` (GenServer + `Port.open`,
status via ETS). All three post-read through non-`Repo` state: honest, NOT write receipts.

**THE POPULATION IS 81** — write-routed at `@route_depth` 10, where the route relation
closes. Evidence stays at depth 6; the 54 POST-READ the dial prints at 10 is not an
evidence figure. PDS-D448's 64 survives as a FLOOR (81 >= 64), never as the integer.

| bucket | n | basis |
|---|---|---|
| DECLARED-HONEST | 24 | asserts only what it measured, or NAMES what it did not |
| POST-READ (admissible @6) | 21 | `select:` scoped to the updated query |
| UNCLASSIFIED | 32 | evidence held, no verdict — all 32 named in the appendix |
| CATCH-ALL-TO-SUCCESS | 2 | `search_controller.ex:381`, `v1/media_controller.ex:223` |
| PURE ECHO — DECLARED | 2 | `auth_controller.ex:534`, `:562` — anti-enumeration, by design |
| CAS-CONFIRMED ECHO · WRONG-ROW · DISCARDED-POST-READ | 0 | not proven; not guessed |

`24 + 21 + 32 + 2 + 2 == 81`, one bucket per site key. **UNREACHABLE-ERROR is a name this
instrument does not emit**; the shape is `CATCH-ALL-TO-SUCCESS`, 3 fired (2 undeclared).

**`github_webhook_controller` is the DECLARED-HONEST exemplar, and it is not paid.** 17
sites, 14 honest: `ok: true` there means *the delivery was verified and the named outcome
happened* — every clause carries a discriminator, every real failure is 5xx, and THERE IS
NO STATE TO READ BACK. `:202` names the ABSENCE of a write (`recorded: false`;
`intake.ex:249-253` writes nothing by construction) and `:186`'s `recorded` is MEASURED
(`intake.ex:299-300`). **The "one open MIXED defect" this section recorded at `gwc:161` is
REPAIRED** — the refusal is typed `:dedup_recorded | :dedup_unrecorded | :vetoed`
(`intake.ex:134`), each with its own clause; the line moved 161 -> 186.

**RULING: NO GATE**, the outcome the standing rule admits. 32 of 81 UNCLASSIFIED, so a
guard pins the lens not the law; 24 DECLARED-HONEST, so a read-backed floor reds on 24
CORRECT receipts and the only way green is reads that measure nothing; **2** live defects
is a repair order, not a gate population, exactly as shell was ruled at 2; and the one
keyable integer moves 57/64/81 across depths 6/8/10 on one unchanged tree (PDS-D454).

## Standing rule

Adding a receipt to `internal/cli` means adding its registry row. Shell and Elixir
stay unguarded — but Elixir is no longer uncounted, and the count is no longer keyed on
a string an author may decline: rerun
`elixir scripts/pds-elixir-receipt-census.exs` (add `--sites` for all 100).
**Refusing to ship a fake green is the successful outcome for those two surfaces.**

## Code anchors

- `internal/cli/success_claim_registry_test.go` — the gate: registry, contradiction property, anti-prose reflection, enrollment floor
- `internal/cli/cloud_autoupdate_cmd.go` — the A3 site converted with it (`autoupdateReceipt`, `autoupdateApplied`)
- `templates/place-directory/install.sh` — the two unguarded shell claims (lines 29, 33)
- `api/lib/barkpark_web/router.ex` — the owner of the 260-member ROUTED-WRITE denominator
- `docs/ledgers/pds-w33-write-receipt-buckets.md` — the per-site bucket table, the ruling's evidence
- `scripts/pds-elixir-receipt-census.exs` — the census: routed population, disposition, lens, blind shapes, register, and the integrity arms that can go red
