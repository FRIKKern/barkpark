<!-- doc-tier: agent | canonical-for: success-claim-census | budget: 4800tok -->
# Success-claim census — where the law is enforced, and where it plainly is not

**The law (PDS wave 22).** No Barkpark verb may report success on an exit code alone.
Every success claim must be backed by a post-condition READ of the state it claims to
have produced, and any claim it cannot back must say so in the same breath.

**Every integer below is a READ, and each one names the command that re-reads it.**
This doc shipped three consecutive waves of transcribed numbers — a census doc lying
about its own census is this epic's disease on this epic's own paperwork. Re-derive,
never transcribe; figures here were derived at `974d412ca` unless stated otherwise.

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
names goes stale the first time the registry grows, and this doc carried one for three
waves. Count it instead:

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
| in `api/lib` almost every glyph is LiveView chrome, not a claim | `grep -r -o '✓' api/lib \| wc -l` and `grep -rl '✓' api/lib \| wc -l` | 48 across 17 files |

(The earlier wording — "ZERO match a quoted-glyph grep" — was false as literally
written: the glyphs ARE inside quoted strings. What is true, and now falsifiable, is
that they never appear as an argument to a print call, so a lint keyed on `fmt.Print*`
sees nothing.) `barkpark status` and `bp export` print success carrying no glyph at
all. A gate keyed on the glyph would be loud where there is nothing and silent where
the lies are.

**The A3 lie this shipped with the gate.** `cloud_autoupdate_cmd.go`
`autoupdateReceipt` took the server-returned policy and, for `unpin`/`pause`/
`resume`/`default`, read NOTHING from it — every sentence was keyed on the local verb,
so "autoupdate paused" printed unchanged when the control plane returned
`paused:false`. Only `pin` read `policy.PinnedRelease`. Now every branch reads the
returned policy, a contradicted claim carries `✗` and names the contradiction, and
`autoupdateApplied` makes the verb exit non-zero (and `ok:false` on `-o json`) instead
of printing a checkmark over a change that did not land.

**Mutation proof.** Reverting `autoupdateReceipt` to the verb-keyed original turns the
gate RED on `autoupdateReceipt/{unpin,pause,resume,default}` with
`prints the SAME line whether the server backs the claim or contradicts it`, plus four
failures in `TestAutoupdateReceiptNamesTheContradiction` (including `pin`, whose
contradicted output was the malformed `✓ box-1 pinned to  —`). Restoring the fix
returns it green. Note honestly: `pin` was already A2 and does NOT fail the registry
row under mutation — the registry catches the four verb-keyed branches, the wording
test catches all five.

## Shell — NOT ENFORCED. No gate ships. Here is the measured reason.

Denominator, re-derived (`grep -rn "✓" --include="*.sh" .`, excluding `.git`): **24
glyph occurrences across 12 files.** Correcting the survey figure, which counted FILES:

| bucket | count | evidence |
|---|---|---|
| proof harnesses | 13 | `deploy/site-spawner-live-proof.sh` 5, `-node-live-` 4, `-autorebuild-` 4 — a proof harness asserting its own findings is not a product success claim |
| `ok()` helper DEFINITIONS inside smoke/doctor scripts | 7 | `scripts/{create-quickstart,media,cmux,onramp-live-client}-smoke.sh`, `scripts/doctor.sh`, `scripts/bp-vercel-quick-setup.sh`, `scripts/local-update.sh` — one definition each; the claim lives at every call site, which the glyph never reaches |
| a comment | 1 | `scripts/demo-living-values.sh:23` |
| **real product success claims** | **3** | `templates/place-directory/install.sh:29,33,49` |

Of those three: line 49 is gated on a genuine read-back (step 3 re-queries the public
API, counts `_id`s, and prints an honest `⚠ 0 published places` instead of Done) —
**A1, compliant**. Lines 29 and 33 (`✓ schema upserted`, `✓ places written`) print on
`curl -fsS` exiting 0 — an HTTP-status echo about a record nobody read back. `-f`
makes a 4xx non-zero, so this is stronger than a bare exit code, but it is still
**A3 by the ruling**: the sentence claims the record exists and would print unchanged
if the server 200'd without persisting.

**Ruling: no shell gate.** Two sites, in one optional template installer, is not a
population a repo-wide guard can be calibrated against — a guard over 24 occurrences
of which 21 are harness plumbing greens on the plumbing and teaches the reader that
shell is covered. **It is not covered.** The two sites are filed as
`pds-bl-place-directory-install-echoes-transport`, to be fixed by read-back
(re-`GET` the schema / count the seeded docs) rather than by a lint.

## Elixir — NOT ENFORCED. No gate ships. And the glyph census is structurally blind here.

Denominator, re-derived (`grep -r -o "✓" api/lib | wc -l`): **48 occurrences across 17
files** (the survey said 47). Of these, **47 are LiveView/HEEx/render chrome** —
`panes.ex`, `chat_live.ex`, `paper_editor.ex`, `board_live.ex`, `components.ex`,
`portable_doc/render/components.ex`, `root.html.heex` and friends. A checkmark in a
template is a UI affordance, not a claim about a post-condition.

Exactly **one** console emitter carries the glyph:
`api/lib/mix/tasks/barkpark.workspace.provision_schemas.ex:114` —
`case Content.upsert_schema(...) do {:ok, _} -> Mix.shell().info("  ✓ #{name}")`.
That is **A2**: the success arm is the Repo returning the record it wrote, and the
`{:error, cs}` arm prints `✗` with the changeset errors. Compliant.

**Ruling: no Elixir gate.** A guard over one compliant site is a fake green. Shipping
it would let the next reader believe the Elixir surface is policed. It is not.

### The lie the glyph census cannot see (PDS-D311)

Restricting the census to a glyph — or to console output at all — misses the shape
that actually bites on this surface: **`mix ecto.migrations` reporting `up` reads a
row in `schema_migrations`; it never reads the object the migration claims to have
produced.** A migration amended in place after it ran leaves its version row stamped
`up` forever, so the trigger/index/column the amended body would have created is
absent while the check still reports clean — a success claim backed by a bookkeeping
row instead of by the state. This is the same A3 failure as
`autoupdateReceipt`, wearing a schema instead of a checkmark, and no lint over `IO.puts`
will ever find it. The honest fix is a post-condition read of the OBJECT
(`pg_trigger` / `pg_indexes` / `information_schema.columns`), not a wider glyph grep.

### THE POPULATION AND ITS OWNER (PDS wave 38) — `router.ex`, not the string `ok: true`

**This doc used to say the population was 91 emitted `ok: true` claims. That is now the
population of one LENS, not of the surface.** The string `ok: true` is a convention an
author may decline; a ROUTE is not. An unrouted write is unreachable, and a routed
write is in the table by construction — so the denominator's owner is
`api/lib/barkpark_web/router.ex`, and the 91 is a numerator measured against it.

**The key is the QUAD `{method, path, module, action}`.** A `{module, action}` key
collapses this population **252 → 196** and, worse, goes BLIND to arrivals: a new
route onto an already-disposed `{Controller, action}` pair vanishes into the existing
row and the completeness arm never notices it arrive. The quad is why
`ROUTED-POPULATION-COMPLETE` reds on an **undisposed arrival** rather than on a count
— a count-shaped arm over this surface reds on unrelated churn (PDS-D524).

Derived by `scripts/pds-elixir-receipt-census.exs` (build-free AST over 804
`api/lib/**/*.ex` files, no mix project and no compile — it never boots the app; it
prints its own `user cpu … ms` line (D605) on every run, which is where a runtime figure
belongs rather than in this sentence):

| figure | today | what it is |
|---|---|---|
| routed entries from `router.ex` AST | 469 | plus 83 plugin specs mounted at 17 `plugin_routes/1` callsites |
| **ROUTED-WRITE population** | **252** | `post`/`put`/`patch`/`delete` plus every LiveView mount |
| JUDGED | 67 | reaches a receipt this lens emitted AND the register judged |
| ROSTERED | 7 | reaches a hand-named roster site outside the lens |
| EXCLUDED | 178 | committed, dated disposition row — see the classes below |
| **UNDISPOSED** | **0** | `ROUTED-POPULATION-COMPLETE` reds on this |
| sum | 252 | == the population, both directions, no duplicate key |

**EXCLUDED is not a silence — it is written, dated prose, counted by class:**

| class | n | why |
|---|---|---|
| `liveview_handle_event` | 40 | a LiveView route names a MOUNT; its writes live in `handle_event/3`, which carries no routed action name for a receipt register to key on (26 distinct modules) |
| **`status_only_receipt`** | **138** | **THE HOLE.** The routed action reaches no `ok: true` / `"ok" => true` receipt this lens can see and carries no roster anchor. SCIM's three IdP write routes land here. Wave 38 also called it "success by STATUS alone"; wave 40 MEASURED that and RETIRED the clause — most of these rows DO render the stored row, they just do not spell the key the lens greps for. The run prints the retirement and the derivation partition that replaced it. |

The run emits exactly these TWO classes; `action_not_in_corpus` was listed here and
occurs ZERO times in the output.

**THE JUDGMENT-COVERAGE LADDER, four rungs printed every run (wave 45):** population
**252** members -> judged-coverage **74** -> VERDICTED **23** -> **PROVEN-BACKED 23
MEMBERS**. The top rung is ONE `Enum.count` over ONE `MapSet.union` of two INDEPENDENT
legs, never `leg_a + leg_b` — OVERLAP is 0 today, so the addition prints the same 23 and
the integer is no evidence. The selftest case `LADDER-UNION-NOT-SUM` is the only
discriminator: it injects a leg-B def into leg A and requires `naive > UNION`, which an
addition can never print. MEMBERS is load-bearing — 23 is also the size of a wrong set
(proven register defs ∪ every roster def, crediting the roster's UNJUDGED rows).

**THE JUDGED FRACTION IS 74/252 = 29.4%** — printed, never thresholded. Naming the 40
LiveView mounts while omitting the 138 would satisfy the letter of "excluded is
disclosed" and conceal the finding: **the largest single class in this population is a
receipt shape this lens cannot see at all.** The register's completeness claim never
covered the 138; wave 38 made them COUNTED instead of absent.

**LENS-CAN-MISS — the blind-shape roll, printed with a count on every run.** A
completeness claim without a stated blind spot is the vacuous green wearing the lens
instead of the corpus:

- **17** `plugin_routes/1` callsites RESOLVED. A plain substring count over `router.ex`
  reads **23**; the difference is comment prose the AST does not count. (This is why
  `GithubWebhookController` appears zero times in `router.ex` directly.)
- **1** route-generating macro callsite this lens CANNOT expand, NAMED rather than
  swallowed: `live_dashboard/2` at `barkpark_web/router.ex:2601` — expanded by a
  dependency a build-free lens never compiles, so its routes are UNCOUNTED, not judged.

Re-derive every figure in this section, and every figure below it, with one command:

```sh
elixir scripts/pds-elixir-receipt-census.exs        # add --sites for all 91 emitted sites
```

### The `ok: true` lens — the numerator, and what it costs

| layer | n | what it is |
|---|---|---|
| textual occurrences | 104 | plain substring, 103 lines (`auth_controller.ex:351` carries two): 100 `ok: true` + 4 `"ok" => true` |
| AST-literal pairs | 95 | real `ok:`/`"ok" =>` pairs — a bare `{:ok, true}` tuple quotes identically and is excluded by key metadata (`format: :keyword` / `assoc:`) |
| phantoms | 9 | 8 prose in `@doc`/comments + `github/web/ops_live.ex:285`, which is `db_ok: true` — **a different key** |
| consumers | 4 | `connectors/bridge_client.ex:66,83,97` + `sync/pusher.ex:286` pattern-match a REMOTE response; they make no claim |
| **emitted claims** | **91** | the numerator over the 252 |

Routed through the call graph (defdelegate followed, and a defdelegate costs **zero**
depth — it is a rename, not logic; charging it a hop is how the 21-entry
`Barkpark.Tasks` facade makes a naive detector report 24/25 false). At depth 3:
write **34** / read 20 / unrouted 37. At depth 6 (the census depth): 54 / 14 / 23.

**54 is a FLOOR, and so is 34.** The write count is a function of the depth budget, not
a property of the code — which is why the script prints the whole sweep instead of one
integer, and why it prints the DRIFT against PDS-D448's hand-followed 64/17/10 rather
than hiding it. The harder finding: **23 emitted claims reach no `Repo` verb at all
within six hops** — and they are unrouted because the lens gave up or could not resolve
an alias, not because they touch no state.

Shapes (PDS-D453) are assertion-backed — `classified 16 + unclassified 75 == emitted 91`:
POST-READ **15** · CATCH-ALL-TO-SUCCESS **1** · UNCLASSIFIED **75** · the other four
shapes 0, each printing why it is 0. Read POST-READ as a **ceiling**: its evidence is
line order (a `Repo` read below a `Repo` write inside the writing function) —
necessary, not sufficient, since the lens cannot prove the read is *of the row written*.
Only `select:` **inside** the update query proves that; `returning:` is silently ignored
by `update_all` (`auth.ex:139-141`) and proves nothing.

**Blind spots, re-derived by the same run**: 218 `json(conn, …)`, 66 `put_status(2xx)`,
3 `send_resp(conn, 2xx)` — every one of them a success claim this lens never sees, and
the same shape the 138 `status_only_receipt` routes wear one axis up.

**The lens is part of the finding (PDS-D448a).** On macOS, Apple Git 2.39.5's POSIX ERE
has no `\b`, and the engines disagree — measured, with the command beside each:

| engine | command | result |
|---|---|---|
| Apple git ERE | `git grep -cE '\bok: true' -- 'api/lib/**/*.ex'` | **0 lines, exit 1, SILENTLY** |
| git PCRE | `git grep -cP '\bok: true' -- 'api/lib/**/*.ex'` | 98 lines |
| BSD grep | `grep -rEo '\bok: true' --include='*.ex' api/lib \| wc -l` | 99 occurrences |
| substring | `grep -rFo 'ok: true' --include='*.ex' api/lib \| wc -l` | 100 occurrences |

The three non-empty engines do not agree with each other either: `\b` refuses
`db_ok: true` (the wrong-key phantom) where the substring accepts it, and a per-line
count loses the second pair on `auth_controller.ex:351`. **The census uses no regex at
all.** Two greens that could not fail were closed: a corpus of only the carrier files
reports `write=0` with no error (now **refused** by naming missing route-bearing
sentinels, exit 2), and the delegate facade — proven by mutation at
`api/lib/barkpark/tasks/internal.ex`, where neutering BOTH `Repo.update_all:57` and
`Repo.insert!:386` flips `DELEGATE-REACHES-WRITE` to FAIL at exit 1, while neutering
only `Repo.update_all` correctly stays PASS at depth 2. (The mutation recorded here for
two waves named `close.ex`, which holds ZERO `Repo` write verbs — the record was
unperformable as written.)

**Ruling: still no Elixir gate (PDS-D454).** A population now exists on both axes, but a
gate keyed on these integers would be the number-shaped guard this epic keeps filing as
a defect. Wave 38 bucketed the write-routed sites MECHANICALLY from `router.ex`'s AST —
not by hand, and not against `ok: true`. The script ships as a census, not a check: its
*integrity* can go red, its *numbers* never do.

**How many arms can actually go red — counted, not asserted:**

```sh
elixir scripts/pds-elixir-receipt-census.exs | grep -cE '^  (PASS|FAIL) '
```

That prints the number of PASS/FAIL arms the run emitted. **One of them is not
red-capable in normal operation**: `CORPUS-INTACT` tests `files >= 600`, and
`guard_corpus!/1` refuses on exactly that condition and exits 2 before the arm is ever
evaluated — the script says so in its own words at the arm, and the selftest reaches it
only by BYPASSING the guard (PDS-D467b). Every other arm is reachable. Do not carry a
number forward from this paragraph; run the command.

## Standing rule

Adding a receipt to `internal/cli` means adding its registry row. Shell and Elixir
stay unguarded — but Elixir is no longer uncounted, and the count is no longer keyed on
a string an author may decline: rerun
`elixir scripts/pds-elixir-receipt-census.exs` (add `--sites` for all 91).
**Refusing to ship a fake green is the successful outcome for those two surfaces.**

## Code anchors

- `internal/cli/success_claim_registry_test.go` — the gate: registry, contradiction property, anti-prose reflection, enrollment floor
- `internal/cli/cloud_autoupdate_cmd.go` — the A3 site converted with it (`autoupdateReceipt`, `autoupdateApplied`)
- `templates/place-directory/install.sh` — the two unguarded shell claims (lines 29, 33)
- `api/lib/barkpark_web/router.ex` — the owner of the 252-member ROUTED-WRITE denominator
- `scripts/pds-elixir-receipt-census.exs` — the census: routed population, disposition, lens, blind shapes, register, and the integrity arms that can go red
