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

## Standing rule

Adding a receipt to `internal/cli` means adding its registry row. Shell and Elixir
stay honest-and-unguarded until a real population exists to calibrate against —
**refusing to ship a fake green is the successful outcome for those two surfaces.**

## Code anchors

- `internal/cli/success_claim_registry_test.go` — the gate: registry, contradiction property, anti-prose reflection, enrollment floor
- `internal/cli/cloud_autoupdate_cmd.go` — the A3 site converted with it (`autoupdateReceipt`, `autoupdateApplied`)
- `templates/place-directory/install.sh` — the two unguarded shell claims (lines 29, 33)
- `api/lib/mix/tasks/barkpark.workspace.provision_schemas.ex` — the single Elixir console claim (A2, compliant)
