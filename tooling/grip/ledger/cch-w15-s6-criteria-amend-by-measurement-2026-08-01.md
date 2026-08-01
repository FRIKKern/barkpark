# cch-w15-s6 — three criteria amended BY MEASUREMENT (re-run recipe)

Ledger-only slice. No code changed. This file is the durable record of the
measurements the amendments were paid with, so the reviewer can re-derive any
of them from source rather than take the amended wording on trust.

All numbers below were driven on **origin/main `32662d0c4`**, served bytes ==
disk bytes (`app.css` sha256 `480fe6ad1e7a14c207190072a99d9382605b491a4104e619651dae9b12013cd5`,
`app.js` sha256 `d265b3bf87c8481cda019c82ed44b65691ec147c0a3bb24252953368dd2909e4`),
Chrome `150.0.7871.187`. Probe scripts live outside the repo (scratch
`.w15s6/probe*.mjs`), per the v8 review's precedent.

    node cloud/priv/static/__preview__/serve.mjs --port 4194

## 1. `cch-w14-s3` — the 2x height bar cannot discriminate

Amended criterion: the one opening `NO TEXT IS SHREDDED`.

`.fleet-row` heights, viewport 900 tall, `?scen=…&theme=…#fleet`:

| shape | width | tallest `.fleet-row` | at 1440 | ratio |
|---|---|---|---|---|
| GR65, shipped + accepted | 768 | 212.19 | 94.19 | **2.253** |
| S3, this fix | 769 / 789 / 790 / 899 | 212.19 | 94.19 | **2.253** |

Identical to three decimals in both themes on `mixed-fleet` and `fleet-v4`,
because S3 **moved** the accepted declaration to a wider band rather than
authoring a new shape. A 2x bar reds the accepted shape too; no threshold on
this axis passes one and reds the other. `flex-direction` reads `column` at
768 and 769 alike, `row` at 900+.

The axis that DOES discriminate, and which the amended criterion keeps: every
`.fleet-name` / `.fleet-url` has `clientWidth == scrollWidth` (0 clipped of 72
elements across 16 cells), plus criterion 1's `scrollWidth == clientWidth` on
`#fleet` across 769-789 (14 cells red before the fix, 0 after).

REFUSED as bar-moving: deleting the clause; raising 2x to 2.3x.

## 2. `cch-w14-s1` — the 745.88 pin died by MERGE ORDER, not by width

Amended criterion: the one opening ``A full `--render` run``.

    BREAKPOINT_SWEEP_PORT=4217 node cloud/priv/static/__preview__/breakpoint-sweep.mjs --render

    >> cost       338 cells in 412.1s (1.22s/cell)
       ✓ liveness — 338/338 cells rendered the screen they asked for, populated (3-clause)
       ✗ Q1 SIDEWAYS  fleet-archives@721: scrollWidth 731 > viewport 721
       ✗ Q2 CLIP_NO_CUE  billing-trial@901: button.btn scrollWidth 110 > clientWidth 62
       · Q3 PINNED  130 cells at widths <= 720 start at 328px (allowance 745.88px)
    >> verdict    14 measured defects (Q1 1 · Q2 13 · Q3 0) — exit 1

All three of the criterion's frozen reconciliation values are dead:

| old wording | measured now | why it moved |
|---|---|---|
| Q1 reds only `#fleet` in 769-789 | Q1 reds one cell, `fleet-archives@721` | #8656 merged the S3 fix 22:08:39 |
| Q3's worst `.content` top is 745.88 | 328, Q3 = 0 defects | #8655 merged 21:44:23 |
| every Q2 hit is the rail select / a hiding utility | 12 `CUT_BY_VIEWPORT` on `fleet-archives@721` + 1 `CLIP_NO_CUE` on `billing-trial@901` | the two defects the sweep found |

**The merge-order fact, measured — and it refutes the circulating claim.** The
brief said #8660 and #8655 are siblings, "neither an ancestor of the other".
Git disagrees:

    gh pr view 8660 → merged 2026-07-31T21:43:38Z  c3d7fe30…   (the sweep itself)
    gh pr view 8655 → merged 2026-07-31T21:44:23Z  aec3be35…   (the folded-shell fix)
    gh pr view 8656 → merged 2026-07-31T22:08:39Z  caafb5fa…   (the S3 band fix)

    git merge-base --is-ancestor c3d7fe30 aec3be35   → exit 0
    git merge-base --is-ancestor aec3be35 c3d7fe30   → exit 1

#8655 landed **on top of** the sweep, 45 seconds later. The pin was measured on
bytes that stopped being `origin/main` three quarters of a minute afterwards.

**328 is a HEIGHT number, not a width number** — which is why `cch-w15-s1`
deletes the pin rather than lowering it. Independent drive, four screens
(`overview-fleet`, `tokens-member`, `operator`, `operator-halted`) x widths
320/480/619/620/720 x both themes:

    viewport height 800 → .content top = 328.00   (16 live cells, zero variance)
    viewport height 667 → .content top = 282.77   (16 live cells, zero variance)

The sweep only ever drives `HEIGHT = 800` (`breakpoint-sweep.mjs:187`), so the
height axis is genuinely unmeasured — that is wave 15's widening work, not this
slice's.

REFUSED as bar-moving: deleting the reconciliation clause; re-pinning 745.88
down to 328. The new wording binds the run to **filed row ids**, so an unfiled
hit blocks the criterion and the clause cannot go stale on the next merge.

## 3. `cch-w14-bl-independent-review-owed` — the pre-merge form is unsatisfiable

    gh pr view 8659 --json reviews,comments,mergedAt,mergeCommit
    {"comments":[],"mergedAt":"2026-07-31T21:43:45Z",
     "mergeCommit":{"oid":"702bd9cb410bdd639ef6d5e3d2879343f5d01652"},"reviews":[]}

Merged with zero reviews and zero comments. No future action makes a past merge
pre-reviewed; the form went 0-for-2 across waves 14 and 15. The amendment keeps
independence, the driven re-derivation, the explicit upholds-or-reverses
verdict, and adds a follow-up-PR-on-reversal clause.

REFUSED as bar-moving: dropping independence; accepting a diff-read instead of a
drive; softening "upholds or reverses" to "comments on".

### Discharge stamped on that row (criteria 0-2), two of three re-run here

- **DOM drive**, `?scen=sites#sites` at 1440x900: `acme-labs` reads
  `.site-status .status-pill` textContent `"Not deployed"`, className
  `"status-pill status-pill--neutral"` — matches v8 §3 exactly. Ruling UPHELD.
- **Design-corpus census**, re-run over `origin/main`:

      cd cloud/priv/static/__preview__ && node -e '<walk SCENARIOS.*.data.sites>'
      → 20 scenarios carry sites · 44 site rows · 40 last_deployment == null · 0 preview-only

  Reproduces v8 §5's 44/40/0. **No production number is quoted** — no production
  DB is reachable, and that absence is stated rather than filled in.
- **The 5-red price is CITED from v8, not re-run here** (it needs a `mix
  compile`). Caveat recorded as a `--miss` note on the row: v8 reports 104 tests
  / 5 failures but itemises only FOUR (keyset x2, badge x2); the fifth is
  unnamed.

The same drive independently reproduced v8 §6 — all five site rows, `acme-labs`
included, paint `Visit ↗ / title="Open the live site"`. Already filed as
`cch-w15-bl-visit-link-ungated-on-deployment-state`; nothing new was owed.

## 4. Closed by content

- **`cch-w14-bl-navwall-worse-on-operator-tokens`** — paid by #8655. The row's
  complaint was that Operator (783.38) and `tokens-member` (746.88) opened
  *worse* than the 745.88 wall. All four named screens now read an identical
  328.00 / 282.77; no screen differs from any other. Closed `done`, 1831-byte
  reason, no code change, no PR. Parentage (`cch-instruments-epic`) left alone.
- **`cch-w13-bl-detail-url-text-truncation`** — adjudicated against its own
  stated test, **both halves on `origin/main`**:

      git grep detail-url-text origin/main -- cloud/priv/static/app.css  → 1 hit, app.css:4594
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap
      git grep detail-url-text origin/main -- cloud/priv/static/app.js   → 1 hit, app.js:5618
        <span class="detail-url-text">esc(publicUrl(bp))</span>
        <button class="copy-btn" data-copy="esc(publicUrl(bp))" aria-label="Copy address">

  One emission path, so the surveyor's residual doubt is closed; painted text
  and `data-copy` come from the same expression and cannot drift. Driven at
  320/721/1440, light and dark: `renderedText === data-copy ===
  "production-5b2c1e.barkpark.cloud"`, `title = null`. Closed.

  Two residuals recorded rather than buried: **no `title` attribute**, so a
  hover-only user gets nothing (recovery is the copy control alone — the weakest
  affordance the row's test permits); and this fixture's hostname **never
  overflows** (`scrollWidth == clientWidth` in all four cells), so the recovery
  path is proven present but truncation itself was not observed.

## 5. The mechanics, and the one write that silently did not land

No `bp task` verb can write a criterion's text — `stamp` and `close` read
`criterion` as a CAS guard only. The path used for all three amendments:

    bp task get <id> -o json                              # copy the WHOLE array
    # edit ONE criterion string, matched BY TEXT (both circulating index
    # citations are off by one); assert every other entry byte-identical
    bp doc patch task <id> --yes --set 'acceptance_criteria:=[…]'
    bp doc publish task <id> --yes                        # a patch writes a DRAFT
    bp task get <id> -o json                              # RE-READ and diff

Re-reads, each diffed against the payload sent: `cch-w14-s3` `SENT ==
PUBLISHED: True len 7 7`; `cch-w14-bl-independent-review-owed` `True len 4 4`;
`cch-w14-s1` `True len 11 11`.

**A printed rev is not persistence, and this run proved it.** Stamping criterion
index 2 of `cch-w14-bl-independent-review-owed` printed `✓ the store holds it —
met=true evidence 925 bytes` and then read back `met=False, evidence 0B`. It was
caught by the read-back and re-issued until the server agreed.

**Amending the array invalidates the holder's claim digest.** The
independent-review row's `claim.work_field_digests.acceptance_criteria` moved to
`57e203a3ad4a25c6`. Every amended row's description now ends with the sentence
telling its closer to pass `--set observed_rev=<current rev>` or eat a 409
`doc_changed_since_claim`.

## 6. Gate, and proof it can fail

`.w15s6/gate.sh` re-fetches all five touched rows and asserts published +
parentage unchanged + published-array == payload-sent + the amendment marker +
the `REFUSED` clause + the `observed_rev` note. Final run: **GATE PASS**.

Proven able to fail by mutation, both ways, each restored afterwards:

    strip "REFUSED as bar-moving" from the PAYLOAD    → FAIL published array == payload sent   · exit 1
    strip it from the PUBLISHED copy                  → FAIL no bar quietly dropped            · exit 1
    restore                                           → exit 0

## 7. Honest residue

- Two of the five touched rows (`cch-w14-s1`, `cch-w14-bl-navwall-…`) sit under
  `cch-instruments-epic`, not `cloud-console-hardening-epic`, by wave 14's own
  split. This slice's criterion 7 asks for the latter; re-parenting is forbidden
  by the wave brief, so the gate asserts parentage **unchanged** instead. Named,
  not smoothed over.
- The 5-red price on the freshness alternative is inherited from v8, not re-run.
- No production census exists for the preview-only population, and none was
  invented.
