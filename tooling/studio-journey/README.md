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
scripts/studio-journey-smoke.sh self-test   # offline: no network, no credentials
scripts/studio-journey-smoke.sh live        # deployed host, real verdict
scripts/studio-journey-smoke.sh report      # deployed host, never exits 1
```

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

## The two legs

**LEG A** creates its own document — never `--doc`, never "the first row", because
the drill that clicked the first row is how a draft-only fossil made three
verifiers time out on a selector that could never appear. Beats: AUTH (a minted
login ticket plus an admin identity discriminator), DESK (Structure rows, and
`#item-paper` really is a `<button>`, and the LiveView socket has joined), CREATE
(the row patches the URL, the pane lands document rows, the "+" has an accessible
name, a new document id appears), HYDRATE, TYPE (real key events), PERSIST (read
back from the API), RELOAD, and a PRE/POST served-commit stamp.

**LEG B** opens the two named draft-only fossils and reports each one's shell /
body / contenteditable / add-block / footer counts. **It fails today, on purpose**
— those documents render a wordlessly blank editor, which is the open never-blank
defect. LEG B never moves the exit code: it measures a known defect, it does not
gate on it. It goes green on its own when the named-state contract ships.

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

Two in-process fixtures, no network. `/good/` is a healthy miniature Barkpark.
`/rot/` upgrades the canvas element with a truthy `_editor` and leaves `blocks`
empty **forever** — the trap a `_editor` readiness check cannot see. The fixture
also mints a USER-shaped ticket when the mint body is not `{}`, reproduces the
add-button decoy (the airdrop share button shares the class *and* the
`phx-value-type`), and drops a click that arrives before the socket joins. Every
one of those rules is therefore enforced offline rather than remembered.

## Not a merge gate

`.github/workflows/studio-journey-smoke.yml` runs the self-test on PRs and the
deployed walk on a schedule in report mode. **Neither job gates a merge and
neither can be made to** — that workflow's header gives both reasons. Its output
is the signal.
