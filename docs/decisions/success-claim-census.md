<!-- doc-tier: agent | canonical-for: success-claim-census | budget: 3200tok -->
# Success-claim census — where the law is enforced, and where it plainly is not

**The law (PDS wave 22).** No Barkpark verb may report success on an exit code alone.
Every success claim must be backed by a post-condition READ of the state it claims to
have produced, and any claim it cannot back must say so in the same breath.

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

17 rows enrolled at first ship: `autoupdateReceipt` ×5 branches,
`autoupdatePolicySummary`, `renderRollbackResult` ×2 branches, `renderProvisioned`,
`hzDone`, `hzResDone`, `instTransferDone`, `emitDeviceLoginSuccess`,
`emitFrontierClaim`, `supportAddRun.done`, `supportRemoveRun.done`,
`supportAddRun.success`.

**Why behavior and not a glyph lint.** Three measured facts kill the grep:
`vercel_cmd.go` carries 13 checkmarks and ZERO match a quoted-glyph grep (they are
interpolated inside `out.progressf`); `barkpark status` and `bp export` print success
carrying no glyph at all; and in `api/lib` 47 of 48 glyphs are LiveView chrome, not
claims. A gate keyed on the glyph would be loud where there is nothing and silent
where the lies are.

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

Denominator, re-derived in this wave (`grep -rn "✓" --include="*.sh"`): **23 glyph
occurrences across 12 files.** Correcting the survey figure, which counted FILES:

| bucket | count | evidence |
|---|---|---|
| proof harnesses | 12 | `deploy/site-spawner-{live,node-live,autorebuild}-proof.sh`, 4 each — a proof harness asserting its own findings is not a product success claim |
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
population a repo-wide guard can be calibrated against — a guard over 23 occurrences
of which 20 are harness plumbing greens on the plumbing and teaches the reader that
shell is covered. **It is not covered.** The two sites are filed as
`pds-bl-place-directory-install-echoes-transport`, to be fixed by read-back
(re-`GET` the schema / count the seeded docs) rather than by a lint.

## Elixir — NOT ENFORCED. No gate ships. And the glyph census is structurally blind here.

Denominator, re-derived (`grep -rc "✓" api/lib`): **48 occurrences across 17 files**
(the survey said 47). Of these, **47 are LiveView/HEEx/render chrome** — `panes.ex`,
`chat_live.ex`, `paper_editor.ex`, `board_live.ex`, `components.ex`,
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

### The real Elixir population (PDS wave 33) — the `ok: true` census

The glyph was the wrong lens; the API's success claims are written `ok: true`. Derived
by `scripts/pds-elixir-receipt-census.exs` (build-free AST over 804 `api/lib/**/*.ex`,
~5 s, no mix project and no compile — it never boots the app):

| layer | n | what it is |
|---|---|---|
| textual occurrences | 103 | plain substring, 102 lines (`auth_controller.ex:351` carries two) |
| AST-literal pairs | 95 | real `ok:`/`"ok" =>` pairs — a bare `{:ok, true}` tuple quotes identically and is excluded by key metadata (`format: :keyword` / `assoc:`) |
| phantoms | 8 | 7 prose in `@doc`/comments + `github/web/ops_live.ex:285`, which is `db_ok: true` — **a different key** |
| consumers | 4 | `connectors/bridge_client.ex:66,83,97` + `sync/pusher.ex:286` pattern-match a REMOTE response; they make no claim |
| **emitted claims** | **91** | the actual population |

Routed through the call graph (defdelegate followed, and a defdelegate costs **zero**
depth — it is a rename, not logic; charging it a hop is how the 21-entry
`Barkpark.Tasks` facade makes a naive detector report 24/25 false). At depth 3:
write **33** / read 12 / unrouted 46. At depth 6: 42 / 14 / 35.

**33 is a FLOOR, and so is 42.** The write count is a function of the depth budget, not
a property of the code — which is why the script prints the whole sweep instead of one
integer. PDS-D448 recorded 64/17/10 by hand-following; both are honest and differ only
in lens, and the script prints the DRIFT rather than hiding it. The harder finding:
**35 emitted claims reach no `Repo` verb at all within six hops.**

Shapes (PDS-D453), assertion-backed — `classified 44 + unclassified 47 == emitted 91`:
POST-READ 17 · UNREACHABLE-ERROR 27 · UNCLASSIFIED 47 · the other four shapes 0, each
printing why it is 0. Read POST-READ as a **ceiling**: its evidence is line order (a
`Repo` read below a `Repo` write inside the writing function) — necessary, not
sufficient, since the lens cannot prove the read is *of the row written*. Only `select:`
**inside** the update query proves that; `returning:` is silently ignored by `update_all`
(`auth.ex:139-141`) and proves nothing.

**Blind spots, re-derived by the same run**: 218 `json(conn, …)`, 66 `put_status(2xx)`,
3 `send_resp(conn, 2xx)` — every one of them a success claim this lens never sees.

**The lens is part of the finding (PDS-D448a).** On macOS, Apple git 2.39.5's POSIX ERE
has no `\b`: `git grep -E '\bok: true'` returns **0** and exits 1 *silently*, while
`git grep -P`, BSD `grep -rE` and `rg` return 97. The census uses no regex at all. Two
greens that could not fail were closed: a corpus of only the 27 carrier files reports
`write=0` with no error (now **refused** by naming missing route-bearing sentinels, exit
2), and the delegate facade — proven by mutation, removing all five write verbs from
`close.ex` flips `DELEGATE-REACHES-WRITE` to FAIL and exit 1, while removing only the
three `Repo.update_all` correctly stays green.

**Ruling: still no Elixir gate (PDS-D454).** A population now exists, but a gate keyed on
these integers would be the number-shaped guard this epic keeps filing as a defect. Wave
34 buckets the write-routed sites by hand and decides the gate from the shapes. The
script ships as a census, not a check: its *integrity* can go red (corpus, partition,
delegate reach), its *numbers* never do.

## Standing rule

Adding a receipt to `internal/cli` means adding its registry row. Shell and Elixir
stay unguarded — but Elixir is no longer uncounted: rerun
`elixir scripts/pds-elixir-receipt-census.exs` (add `--sites` for all 91).
**Refusing to ship a fake green is the successful outcome for those two surfaces.**

## Code anchors

- `internal/cli/success_claim_registry_test.go` — the gate: registry, contradiction property, anti-prose reflection, enrollment floor
- `internal/cli/cloud_autoupdate_cmd.go` — the A3 site converted with it (`autoupdateReceipt`, `autoupdateApplied`)
- `templates/place-directory/install.sh` — the two unguarded shell claims (lines 29, 33)
- `api/lib/mix/tasks/barkpark.workspace.provision_schemas.ex` — the single Elixir console claim (A2, compliant)
- `scripts/pds-elixir-receipt-census.exs` — the Elixir census: population, lens, blind spots, shapes, and the three integrity checks that can go red
