# cch-w23 VERIFY — Law 0 read live, five merge-gate closes diff-confirmed, `cch-w22-s2` adjudicated

Verifier row `law0-live-and-s2-adjudication` · read 2026-08-02T09:05:49.628Z · ships NO product code.
This file is a re-derivation recipe. Every number below has the command that regenerates it.

---

## 1. LAW 0, LIVE — `orphans=93`, read twice, two different predicates

```sh
cd /Volumes/SATECHI/github/barkpark
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic 2>&1 \
  | grep -E 'roster:|CLAUSE \(a\)|UNNAMED RESIDUE|VERDICT-TOKEN'
```

```
roster: 285 children  {"open":95,"done":159,"cancelled":30,"considering":1}
CLAUSE (a) forwarding — residue 96 (live 95, considering 1)
  UNNAMED RESIDUE (orphans) : 93
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=93 considering=1 successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
```

Two consecutive reads both printed `orphans=93`. Published roster 285 vs `bp doc query --perspective raw` 286;
the single delta is `drafts.cch-w22-s2-site-row-name-and-host-bounded`. **Correction constant is +1, not +4.**

```sh
bp doc query task --filter "parent_id=cloud-console-hardening-epic" --limit 500 --perspective raw -o json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d), [x['_id'] for x in d if x['_id'].startswith('drafts.')])"
```

**The six wave-22 slices are the first six orphans the predicate prints, by name.** Closing them is a direct
−N against clause (a): `orphans = residue − PERMANENT_HUMAN_GATES − forwarded` (`seal-predicate.mjs:794-798`),
and none of the six is gated or forwarded.

### The predicate I ran is NOT origin/main's — and it did not matter for clause (a)

```sh
shasum -a 256 cloud/priv/static/__preview__/seal-predicate.mjs          # c25b6b49…
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | shasum -a 256   # 47796657…
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs > /tmp/sp.mjs && node /tmp/sp.mjs --successor cch-instruments-epic
```

Origin's predicate printed the identical `orphans=93 / roster 285`. Clause (a) is a NETWORK read (`fetchRoster`,
`:346`) and is checkout-independent. **Clause (b) is not**, and that is the next section.

## 2. `b=FAIL` IS A CHECKOUT ARTEFACT, NOT A REGRESSION — read Law 0 only in a tree at origin/main

Wave 22's own receipt printed `b=PASS` twice on 2026-08-02. This read prints `b=FAIL` on
`CCH-D5-rate-limiter-sees-every-user-as-one`. The predicate did not change (last touch `c6f7f865a`, before
wave 22). The TREE did:

```sh
git rev-parse --short HEAD          # a31faa52d
git rev-parse --short origin/main   # 28f4cd473
git rev-list --count HEAD..origin/main            # 327
git merge-base --is-ancestor HEAD origin/main     # rc=1 — DIVERGED, not merely behind
ls cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test.exs        # No such file
git show origin/main:cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test.exs | head -1   # exists
```

D5's sole `measured_by` path (`seal-predicate.mjs:309`) is `existsSync`-tested against DISK. The file is on
origin/main and absent from this checkout, so rung 2 collapses to rung 3 and clause (b) fails on a phantom.
The same staleness explains the charter: local max rule `D250`, origin/main max rule `D262`.

```sh
grep -oE '^\| D[0-9]+ ' .claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '[0-9]+' | sort -n | tail -1   # 250
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '^\| D[0-9]+ ' | grep -oE '[0-9]+' | sort -n | tail -1   # 262
```

**Rule for the debrief read: quote `orphans` from any tree, but never quote `a=/b=/c=` from a diverged one.**

## 3. THE REPAYMENT IS FIVE, AND EACH SHA IS CONFIRMED BY DIFF, NEVER BY SUBJECT LINE

All six ANCESTOR:

```sh
for s in fb2f4fce8 f7886f46c 72bf79920 f0410ab8b cb7aa7963 9b0ea9af1; do
  printf '%s ' $s; git merge-base --is-ancestor $s origin/main && echo ANCESTOR || echo NOT; done
```

Mapping proven by diff CONTENT against each row's remedy — the artefact the criterion names, not the subject:

| row | met | SHA | the diff artefact that proves the mapping | rerun |
|---|---|---|---|---|
| `cch-w22-s1-font-pin-every-shipped-weight` | 11/12 | `fb2f4fce8` | new `font-pin.mjs` with `{ family: "Inter", min: 1 }`, `{ family: "IBM Plex Mono", min: 3 }` — c0 demands all THREE Plex weights | `git show fb2f4fce8 -- cloud/priv/static/__preview__/font-pin.mjs \| grep -E '^\+.*min: [0-9]'` |
| `cch-w22-s2-site-row-name-and-host-bounded` | **8/10** | `f7886f46c` | `+.site-name{…overflow-wrap:break-word}` `+.site-host{…break-word}` `+.site-meta .mono{…anywhere}` | `git show f7886f46c -- cloud/priv/static/app.css \| grep -E '^\+[^ /*].*\{'` |
| `cch-w22-s3-env-comment-500-and-note-bounded` | 11/12 | `72bf79920` | `-validate_length(:comment, max: 1000)` → `+validate_length(:comment, max: 255)` — c0's 500-at-256 root | `git show 72bf79920 -- cloud/lib/barkpark_cloud/registry/env_var.ex \| grep -E '^[+-].*validate_length'` |
| `cch-w22-s4-2fa-enroll-modal-phone-band` | 9/10 | `f0410ab8b` | `+.modal-root:has(.am-modal){grid-template-columns:minmax(0,1fr)}` + `.am-*` band inside `@media (max-width:620px)` | `git show f0410ab8b -- cloud/priv/static/app.css \| grep -E '^\+ *\.(modal-root\|am-)'` |
| `cch-w22-s5-console-stops-asserting-false-things` | 10/11 | `cb7aa7963` | `+var BIDI_CONTROLS = /[‎…⁦-⁩]/g` + `.replace(BIDI_CONTROLS,"")` inside `esc()`; and the removal of the `Math.max(0,…)` future-timestamp clamp | `git show cb7aa7963 -- cloud/priv/static/app.js \| grep -E '^[+-].*(BIDI_CONTROLS\|Math\.max\(0)'` |
| `cch-w22-s6-law0-executes-the-23-row-repayment` | 9/10 | `9b0ea9af1` | the receipt itself, `tooling/grip/ledger/cch-w22-law0-23-row-repayment-2026-08-02.md`, carrying both VERDICT-TOKEN lines | `git show 9b0ea9af1 --name-only \| tail -1` |

Five rows read N−1/N with the merge gate as the sole unmet criterion. `cch-w22-s2` reads **8/10**: two unmet.

## 4. ADJUDICATION — `cch-w22-s2`, criterion [3] vs criterion [4]

**[3]** *"THE REMEDY IS DECLARATION-MINIMAL and lands on the hosts, not on their ancestors: the diff adds wrap
protection to `.site-name` and `.site-host` only."*
**[4]** *"`.site-meta .mono` … is either fixed in the same block or REFUSED IN WRITING."*

The shipped diff adds exactly five rule heads:

```
.site-name { … overflow-wrap: break-word; }
.site-meta .mono { … overflow-wrap: anywhere; }
.site-host { … overflow-wrap: break-word; }
.site-row:not(.site-row--global) { flex-wrap: wrap; }
.site-row:not(.site-row--global) .site-main { flex: 1 1 200px; }
```

`.site-row > .site-main > {.site-name,.site-host,.site-meta}` in BOTH builders (`app.js:7659` compact,
`app.js:9619-9623` global), so heads 4 and 5 land on **ancestors**. Head 2 is a third **host**, required by [4].

### Two independent conflicts, one verdict each

**(A) The "only two hosts" clause vs [4] — DRAFTING DEFECT, resolve for the diff.** [4] is the later, more
specific criterion and it explicitly authorises "fixed in the same block". Specific governs general. A reading
under which [3] and [4] are jointly satisfiable does not exist for any diff; a criterion that cannot be met by
any artefact measures nothing. `.site-meta .mono` is a leaf text host (`app.js:7617`, one `<span class="mono">`),
so the *doctrine* [3] encodes — wrap protection belongs on the text host, not on a box above it — is honoured.

**(B) "not on their ancestors" vs heads 4 and 5 — REAL, and it is the reason the builder refused to flip.**
This is NOT the same conflict, and it does not dissolve under (A). But read what [3]'s own evidence clause asks
for: *"one sentence naming why `.site-main`'s existing `min-width: 0` could not do the job alone."* The
criterion is aimed at the epic's refuted shortcut — solving overflow by CLIPPING on an ancestor (the D253
ellipsis family). **The diff contains zero clipping properties:**

```sh
git show f7886f46c -- cloud/priv/static/app.css | grep -E '^\+' \
  | grep -cE 'overflow *: *(hidden|clip|auto|scroll)|text-overflow'      # -> 0
```

Heads 4 and 5 are flex SIZING, and they were measured as a **precondition of the wrap, not an alternative to
it**: on origin/main bytes with KIND content and no cruelty, the compact builder resolves `.site-main` to
literally 0px (`.site-name` "acme-web" 70/0 at 320/390/900), inside which `break-word` breaks every character —
the wrap alone shipped "acme-web" 168px tall, one glyph per line. Removing heads 4-5 does not make the remedy
minimal; it makes it a defect.

### VERDICT (recommended to Decide — a verifier proposes, the lead stamps)

**Stamp [3] MET with an AMENDED criterion text recorded as its own evidence**, in the shape the epic already
uses for `criteria_override`:

> *[ADJUDICATED 2026-08-02, wave 23 verify] "only" is read on the WRAP axis: `overflow-wrap` appears on
> `.site-name`, `.site-host` and — per criterion [4], which is the later and more specific rule — `.site-meta
> .mono`, all three leaf text hosts, and on nothing else. The two `.site-row`/`.site-main` flex declarations are
> ancestor rules and are NOT wrap protection; the diff carries zero `overflow`/`text-overflow` properties
> (grep count 0), so the ancestor-clipping shortcut [3] exists to forbid was never taken. They are a MEASURED
> precondition: without `flex: 1 1 200px` the compact builder's `.site-main` resolves to 0px and `break-word`
> shreds to one glyph per line (168px tall, measured pre-ship). Criteria [3] and [4] as written are jointly
> unsatisfiable by any artefact; a criterion no diff can meet measures nothing, and this ruling is the fix.*

Then close `cch-w22-s2` with the merge gate [9] stamped against `f7886f46c` (ANCESTOR, diff-confirmed above).
**Repayment is therefore SIX rows, not five** — five clean N−1/N plus s2 on this written ruling.

The honest alternative, if Decide will not amend a criterion: leave s2 open, repay five (93 → 88), and file the
criterion contradiction forward as its own row under `cch-instruments-epic`. That costs one orphan and buys a
permanently unpayable criterion. **Not recommended** — an unsatisfiable criterion left standing is the same
false-instrument shape the fifth clause names.

## 5. THE `drafts.cch-w22-s2` SHADOW IS DISCARDABLE RESIDUE — it holds NOTHING unpublished

```sh
bp doc get task drafts.cch-w22-s2-site-row-name-and-host-bounded --perspective raw -o json
```

Draft: 10 criteria, **5 met**, `claim.epoch 5` (expired 06:48). Published: 10 criteria, **8 met**,
`claim.epoch 9`. Field-by-field the draft is a strict SUBSET: criteria 0-2, 4-5 byte-identical; criteria 6, 7, 8
carry empty evidence in the draft and 544/892/681 chars in the published row; criteria 3 and 9 unmet in both.
The draft is a mid-build snapshot the builder superseded by publishing — **no unpublished criterion edit exists
in it.** Discarding it is hygiene worth exactly 0 orphans (the roster query is published-only,
`seal-predicate.mjs:346`), and it is the entire 286-vs-285 gap.

---

## WHAT THIS ROW REFUSED TO CLAIM

- **It did not re-run the harness.** Every number here is a ledger read, a `git show`, or a `git merge-base`.
- **It did not stamp anything.** The adjudication in §4 is a recommendation with its reasoning written down;
  the flip belongs to Decide.
- **`b=FAIL` is not adjudicated, only explained.** Whether `CCH-D5` measures on a CLEAN origin/main checkout is
  unverified here — this tree cannot answer it, and saying so is the finding.
