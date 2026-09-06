<!-- doc-tier: human | canonical-for: studio-create-journey-smoke | budget: 1800tok -->
# studio-journey — can a person ADD A THING in the Studio?

`journey.mjs` drives a real headless Chrome through the create → type → save
journey on a live Barkpark and asserts, at every step, a binary the DOM or the
API answers.

It exists because the owner reported that the desk buttons looked inert and that
he could not add things; wave 17 of the space-priority-desk epic found three real
defects on that seam and fixed them; and the confirmation that the fix *worked*
was then a hand-driven walk written down as prose. **This epic has six logged
overturns of exactly that shape.** A sentence about a screen somebody remembers
seeing is not evidence. This is.

## Run it

```bash
scripts/studio-journey-smoke.sh self-test              # offline: no network, no credentials
scripts/studio-journey-smoke.sh live                   # deployed host, real verdict
scripts/studio-journey-smoke.sh report                 # deployed host, never exits 1
scripts/studio-journey-smoke.sh report --legs c        # the CENSUS ALONE — creates nothing
```

`--legs <abc>` selects which legs run (default `abc`). **`--legs c` is the mode
for a host other people are using**: LEG A creates a real document, and the
desk-row census needs none of it. With `a` absent, an `authOnly` beat mints the
same ticket, makes the same desk navigation, applies the same 5xx guard and
asserts the same admin discriminator LEG A's AUTH beat does — a census recorded
against a login wall would call every row dead for a reason that is not about
the rows. An unknown letter is a GUARD, never a silently narrower run. The run
summary names what it tallied (`legs=c gating 1/1 beats PASS`), because printing
a census run under "LEG A" would report it as a create-journey run.

Credentials for `live`/`report` come from `~/.config/barkpark/config.json` (the
`guerrilla` entry that `bp login` wrote) or, where there is no such file, from
`JOURNEY_BASE` + `JOURNEY_TOKEN` **together**. `--keep` leaves the document the
run created; by default the run deletes it, so re-running never litters.

The sweep is bounded twice: a candidate must have been created **after** the `+`
press *and* still look untouched (no title of its own, no more blocks than the
seeded `tpl-title` + `tpl-body` template). A document with a title or with
authored content is never deleted, whatever its timestamp says. What remains is
a seconds-wide window in which an empty untitled draft created by somebody else
could be swept — pass `--keep` when running against a host other people are
using right now.

## Exit codes

| code | means |
|---|---|
| 0 | LEG A green (or `--report`, which never fails on content) |
| 1 | a LEG A beat FAILED — a fact about the **product** |
| 2 | GUARD — the **environment** or the invocation: no Chrome, no Node 22, no credentials, a ticket that would not mint, a 5xx from the host, or a deploy that landed mid-run |

The 1/2 split is load-bearing. A transport failure must never be reported as a
product fact, and a misconfigured runner must never red with a message that reads
like a defect in the Studio.

## The three legs

**LEG A** creates its own document — never `--doc`, never "the first row", because
the drill that clicked the first row is how a draft-only fossil made three
verifiers time out on a selector that could never appear. Beats: AUTH (a minted
login ticket plus an admin identity discriminator), DESK (Structure rows, and
`#item-paper` really is a `<button>`, and the LiveView socket has joined), CREATE
(the row patches the URL, the pane lands document rows, the "+" has an accessible
name, a new document id appears), HYDRATE, TYPE (real key events), PERSIST (read
back from the API), RELOAD, and a PRE/POST served-commit stamp.

**LEG B** opens the two named draft-only fossils and reports each one's shell /
body / contenteditable / add-block / footer counts, **the named state it finds by
`data-test-id`**, and *which region the visible-character count was measured
against*. LEG B never moves the exit code: it measures a known defect, it does not
gate on it, and it goes green on its own when the named-state contract ships.

> Its oracle was **vacuous until this wave**. It looked for the editor region as
> `.bp-paper-editor || [data-test-id=studio-editor]`, and the unrenderable notice
> renders in `main.bp-paper-shell > article#paper-body-<slug>` with no
> `.bp-paper-editor` anywhere on that branch — so the region was `null`, the char
> count was measured against nothing, and the beat printed **`WORDLESSLY BLANK`
> for a page whose server HTML carried the shipped named state**, for both id
> forms. A count taken against a null region is not a low number, it is *no
> measurement*, which is why the region is now printed on every line.

**LEG C — the desk-row census** presses every row the desk offers, of every *kind*
it offers, and records **row kind · element id · visible label · outcome** on one
line. Report-only, and it cannot be made a gate.

A row goes green **only on an effect that names it**: `aria-current` landing on
that element, or the URL newly carrying that row's own `phx-value-id` *as a path
segment*, or — for a plugin entry, which is an `<a>` with neither witness — the
page becoming its own `href`. Pane and row counts are recorded and **decide
nothing**: a snapshot diff over `{url, aria-current, pane count, row count}`
credited a dead row with its neighbour's answer arriving 900 ms later, and no
quiesce can fix that, because measured answer latency runs from 1.6 s to
never-within-15 s.

Controls that cannot be pressed without destroying the measurement are
**inventoried with the reason instead**: the `+` creates a document and the
airdrop/access buttons open a modal over the desk. None of those three carries an
`id` (two have a `data-test-id`, the `+` has neither), which is recorded, because
`#id` addressing cannot reach them at all. A `.pane-section-header` is a static
`<div>` at its only desk call site — dead by construction. Each inventory row
*asserts its own reason*, so the day one of them stops being true the row reds and
says "re-decide" rather than quietly staying green.

**`LEG_C_MAX_ROWS` is not a safety margin on a real desk, it is a blindfold.**
Measured on deployed guerrilla, 2026-09-06: the desk opens with 7 `.pane-item`
rows, and the first press grows the roster by ~100 `.pane-doc-item` rows. At the
default 40 the census reported **0 inventoried** and `587 further row(s) beyond
LEG_C_MAX_ROWS=40` — the `add_btn` and `section_header` rows the leg exists to
inventory never entered the roster at all. The same run at `LEG_C_MAX_ROWS=900`
took 5.4 s and inventoried 21. Raise it on a real desk.

Bounded by a hard `LEG_C_BUDGET` (default 90 s, `LEG_C_BUDGET_MS`); per-row
`LEG_C_ROW_CAP_MS` (default 3 s) and `LEG_C_MAX_ROWS` (default 40). Anything the
budget does not reach is reported **`UNMEASURED, which is not the same as
working`** — never FAIL. Turning an exhausted runner budget into a dead row would
fabricate a defect, which is the failure this epic exists to stop.

## Three traps this file exists to not fall into

1. **Hydration is not `_editor` existing.** Measured on deployed guerrilla:
   `{ed:true, blocks:0}` at t≈2s, `{ed:true, blocks:85}` at t≈4s. Readiness is
   `el.blocks.length` / `.ProseMirror` child count, and a canvas still empty at
   the ceiling is a **failed beat**, never "wait longer".
2. **Poll, never sleep.** The Papers patch has been measured from 936 ms to >8 s.
   Every wait is `poll(predicate, cap, label)` and reports how long it took.
   Also: Structure rows and document rows *both* carry `phx-click="select"`, so
   discriminate by class.
3. **There is no Save button.** `[data-test-id="bp-paper-footer-save"]` is a
   `role="status"` span with `tabIndex -1`. Persistence is autosave on a 300 ms
   debounce, and the oracle is the API — the canvas wrapper is
   `phx-update="ignore"`, so no DOM state inside it proves anything.

## `--self-test` is the mutation proof

**The coverage guard is the part that keeps the rest honest.** The self-test used
to verify by walking the *expected* beat keys, so a beat the run produced and
`SELF_TEST_EXPECT` did not name was **silently unasserted** — LEG C's first
version failed on `/rot/` with five FAIL rows and the self-test still printed
`SELF-TEST PASS` and exited 0. So it now also walks the **produced** keys and reds
on anything nobody named, at both levels: beats, and LEG C's individual census
rows. Every future leg is asserted by default instead of decorative by default,
and the `HARNESS` beat that `journeyOne` adds when the harness itself throws can
no longer read as a pass. Prove it by mutation: delete one key from
`SELF_TEST_EXPECT` and the self-test reds while the run is unchanged.

Two in-process fixtures, no network. `/good/` is a healthy miniature Barkpark.
`/rot/` upgrades the canvas element with a truthy `_editor` and leaves `blocks`
empty **forever** — the trap a `_editor` readiness check cannot see. The fixture
also mints a USER-shaped ticket when the mint body is not `{}`, reproduces the
add-button decoy (the airdrop share button shares the class *and* the
`phx-value-type`), and drops a click that arrives before the socket joins. Every
one of those rules is therefore enforced offline rather than remembered.

For LEG C the fixture desk is a **row-kind roster in the real markup**: a plugin
`<a class="pane-item">`, a collapsed strip (`button.pane-column--collapsed`), a
`.pane-doc-item` DIV whose control is the inner `button.bp-doc-row-body`, three
id-less `.pane-add-btn` header controls and a static `.pane-section-header`.
`/good/` is **honest** — every row on it answers or names its refusal — and
`/rot/` differs on purpose: its rows are dead, and `#item-counts-decoy` moves the
pane and row counts *without naming itself*, so "counts cannot make a row green"
is demonstrated rather than promised. `/good/`'s unrenderable page renders the
shipped shape (`main.bp-paper-shell`, **no** `.bp-paper-editor`), so reverting the
region list re-reds LEG B offline.

## Not a merge gate

`.github/workflows/studio-journey-smoke.yml` runs the self-test on PRs and the
deployed walk on a schedule in report mode. **Neither job gates a merge and
neither can be made to** — that workflow's header gives both reasons. Its output
is the signal.
