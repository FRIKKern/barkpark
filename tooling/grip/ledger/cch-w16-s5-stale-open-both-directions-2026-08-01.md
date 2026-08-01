# cch-w16-s5 — the stale-open sweep, both directions (re-derivation recipe)

Ledger-only slice. This file is the ONLY repo byte it wrote. Everything below was
driven on **origin/main `c48fb17d565cc9c4207fd3a3fa8ac28ff38954f9`**, served bytes ==
disk bytes (`app.css` sha256 head `1cf9bac24cf0211e`, `app.js` `d265b3bf87c8481c`,
`scenarios.mjs` `b48f1c33e88961a4`), Chrome `150.0.7871.187`. Probe scripts live
outside the repo (scratch `probe/*.mjs`), per the v8-review precedent; the axes are
written out here so any of them can be rebuilt from this file alone.

    node cloud/priv/static/__preview__/serve.mjs --port <free port>

Every mutation below was reverted and the tree proved clean before the next one:
`git checkout -- cloud/priv/static/app.css` · `git status --porcelain` empty ·
`md5 -q cloud/priv/static/app.css` -> `9a4064e8d1f863443249bb48377e75b3`.

## 0. The two denominators, and why only one of them is the denominator

```sh
TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
  --data-urlencode 'limit=500' -H "Authorization: Bearer $TOKEN"
```

|  | published roster (the seal predicate's own read) | `bp task get` |
|---|---|---|
| first claim | 207 — done 112 / open 72 / cancelled 18 / in_progress 4 / considering 1 | child_count 211, cancelled 20 |
| debrief | 210 — done 121 / open 65 / cancelled 18 / in_progress 5 / considering 1 | child_count 212, cancelled 20 |

`211 − 207 = 4` = exactly the four `drafts.*` children. Discarding two of them moved
`child_count` 211 → 209 and moved the roster **not at all** — drafts are invisible to
the predicate. `child_count` is a LIFETIME total: a cancel never decrements it, which
is why its cancelled column reads 20 against the roster's 18. Quote the roster.

**Direction 2 is structurally empty here, and that must be said rather than reported
as clean.** Building a `parent_id` index over the 210 published children finds no row
that is itself a closed parent of a live child, because every child is a *direct*
child of the epic — the roster is flat. `0 found` on an axis that cannot hold a
finding is a vacuous green.

## 1. The 286-cell sweep that restates cch-w13-s4's false premise

The shipped criterion said "143-cell sweep (11 fixtures x 13 widths, both themes)".
`11 × 13 × 2 = 286`. #8609's own body and `overflow-guard.mjs:52-56` both say **286
cells, 56 OVERFLOW → 8**; charter D153 carries the wrong number too. Amended by
whole-array doc patch (D181) BEFORE stamping.

Re-derived axis (the original probe was never committed, so this is a *different*
axis of the same cardinality — say so, do not pretend otherwise):

* fixtures — `instance-detail`(panel-overview `#instance/…a1`) · `inst-timeline`(timeline) ·
  `inst-metrics`(metrics) · `site-rollback`(rollback `#site/…c1`) · `site-states` ·
  `fleet-mixed`(mixed-fleet `#fleet`) · `fleet-v4` · `overview-past-due` ·
  `billing-past-due` · `notifications`(notif-configured) · `sites-list`(sites)
* widths — 640 700 721 740 768 769 790 830 860 899 900 1024 1440
* per cell: `documentElement.scrollWidth <= clientWidth` **and** the landed
  `section.view` id (+ the instance sub-tab). `?scen=` alone does not route.

| run | verdict |
|---|---|
| shipped bytes | `286 cells · 0 OVERFLOW · 0 misrouted` (exit 0) |
| `app.css:2169` `@media (max-width: 899px) {` → `768` | `286 cells · 24 OVERFLOW · 0 misrouted` (exit 1) |

Mutation hits: instance-detail 837 @769/790/830 · site-rollback 838 @769/790/830 ·
site-states 861 @769/790/830/860 · fleet-mixed 790 @769 · fleet-v4 783 @769, both themes.

**24 is corroborated twice.** #8609's review section records "reverting the CSS reds it
with 24 findings"; the shipped leg under the same mutation prints `OVERFLOW GUARD FAIL
— 22 finding(s)`, which is 24 minus the two `fleet-v4` cells `BAND_ROUTES` does not
carry. The wave brief expected 58 — **not reproduced, and not quoted**.

## 2. The folded `.content` TOP — a top read, not a fold fraction

Budget is the shipped identity `0.4H − 4` (`app.css:4573-4581`). Widths 320/390/430/620/720
× heights 800/667/390 × screens mixed-fleet / tokens-member / operator-halted × 2 themes
= 90 cells.

| height | budget | measured `.content` top |
|---|---|---|
| 800 | 316.00 | **316.00**, zero variance |
| 667 | 262.80 | **262.80** |
| 390 (landscape) | 152.00 | **152.00** |

`--nav-fade` reads 40px with `.sidebar.is-nav-clipped` present, and **0px with the
class absent** on `tokens-member/light` — the cue is live iff clipped.

Mutation `max-height: calc(40vh - 60px)` → `none` (`app.css:4632`): 90/90 over budget —
mixed-fleet **522.88**, tokens-member 735.88, operator-halted 773.38/560.38, identical at
all three heights. The committed sweep reds on the same bytes:

    BREAKPOINT_SWEEP_PORT=<p> node cloud/priv/static/__preview__/breakpoint-sweep.mjs --render
    mutated  -> >> verdict 130 measured defects (Q1 0 · Q2 0 · Q3 130) — exit 1
    shipped  -> ✓ liveness — 338/338 cells rendered the screen they asked for, populated
                >> verdict clean across 338 cells — exit 0

**Do not run the sweep while any other probe is mutating `app.css`.** The first clean
run of this session was contaminated exactly that way (it printed `site-states@769
scrollWidth 861`, the mutation's signature) and had to be re-run untouched.

## 3. The 769 shred, the 52-cell support/archives sweep, and the rail select

| subject | shipped | mutation | mutation numbers |
|---|---|---|---|
| `.fleet-name`/`.fleet-url` @769, mixed-fleet + fleet-v4 × 2 themes | 36 elements, **0 clipped**, page 769==769 | 899 head → 768 | **5/5/8/8** clipped, page 790/790/783/783; three cells at `clientWidth 0` |
| fleet-support-failed + fleet-archives-stored × 13 widths × 2 themes | **52 cells clean**, incl. the 900-937 sliver; `.archive-resurrect` right 682.00 @721 | A: 899 head → 768 | **169px / 938 / 542.56 / 938.44** @769, both themes |
| " | " | B: `.archive-resurrect` loses `flex:0 1 100%` + `flex-wrap:wrap` + `min-width:0` | **10px / 731.20** @721, both themes |
| `select.rail-select`, 8 widths × 2 themes | 16/16 whole, `cw159 == sw159` | pre-#8658 rule **injected at runtime**, no repo file touched | **cw96 / sw137** at all 16 — width-invariant |

The runtime injection is the technique to prefer when a repo mutation would collide
with a long-running sweep:

```js
document.head.appendChild(Object.assign(document.createElement('style'), {
  textContent: "html select.rail-select{max-width:60%;appearance:auto;background-image:none;padding-right:8px;text-overflow:clip;}"
}));
```

The same 52-cell run also measured **14 clipped `.status-pill-detail` cells** across
721-860 in both themes. That is a DIFFERENT row (`cch-w15-bl-fleet-support-detail-truncated-stacked-band`,
slice `cch-w16-s3`) and it is reported separately so the two are never conflated.

## 4. Driving the publish-door 422 live (and cleaning up after)

```sh
bp task create --yes --publish --title "…" --set _id=<throwaway> --set parent_id=<none>
# label spine: description >= 20 chars AND every tag rationale >= 20 chars (api/lib/barkpark/content/label_spine.ex:55-60)
bp task claim <throwaway> <worker>
bp doc patch task <throwaway> --set 'priority:=3'        # mints the draft FIRST
bp task stamp <throwaway> <worker> <epoch> --criterion 0 --criterion-text "…" --met --evidence "…"
curl -X POST .../v1/data/mutate/production -d '{"mutations":[{"publish":{"id":"<throwaway>","type":"task"}}]}'
# -> HTTP 422 validation_failed, details.acceptance_criteria[0] names the criterion index AND its text
bp doc delete task <throwaway> --yes
```

`bp doc publish -o json` collapses this to a bare `validation_failed` with no
`details` — **go to `/v1/data/mutate` directly when you need the refusal text.**

## 5. Two traps this run hit, both worth carrying forward

1. **A stamp's own read-back said "the store holds it" and the value was gone one
   write later.** `cch-w12-bl-filing-law-parent-charter-half` criterion 1: receipt
   `met=true evidence 1981 bytes`, then a fresh-process read found `met=false`,
   evidence empty. Re-issued, it landed. A deliberate control re-ran the following
   `--miss` with the row quiescent and did NOT revert it, so the obvious story is
   refuted as stated. One loss in ~20 writes, in a run that twice hit
   `context deadline exceeded` on `/v1/capabilities`. Filed:
   `cch-w16-bl-stamp-readback-said-landed-then-gone`. **Only a second, independent
   read caught it.**
2. **`bp task close` refuses to grade its own homework.** Flipping criteria inside the
   close command does not count — "acceptance criteria 2, 4, 5 (0-BASED) are not met on
   the task AS STORED". Stamp first, or close over them on the record with
   `--set criteria_override="…"`, which persists at `content.close_override.criteria.reason`.
