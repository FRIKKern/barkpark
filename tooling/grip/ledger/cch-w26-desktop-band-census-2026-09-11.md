# The desktop band above 1280 — width census + an honest negative (2026-09-11)

Task: `cch-w26-bl-desktop-band-above-1280-unswept`.
Tree measured: `console/desktop-band-1280`, Chrome 153.0.8010.36, node v22.22.0,
`OVERFLOW_GUARD_PORT=4783`, served-bytes == disk-bytes asserted before every run.

**Verdict: the band measured CLEAN, no leg was added, and the reason is
structural — the console STOPS RESPONDING TO WIDTH AT EXACTLY 1280.** A leg at
1440 or 1920 could only re-measure 1280. The proof is R4 below.

---

## C0 — the width census, derived by grep from the bytes

Every width-bearing array in `cloud/priv/static/__preview__`, re-derivable with:

```bash
cd cloud/priv/static/__preview__
grep -nE '(const|let|var)\s+[A-Za-z_0-9]*(WIDTHS|VIEWPORTS|_W)[A-Za-z_0-9]*\s*=' *.mjs
grep -cE '\b(1280|1440|1920)\b' *.mjs | sort -t: -k2 -rn
```

### Widths ABOVE 1024 that any instrument drives today

| Width | Driven by | Routes / fixtures it reaches |
|---|---|---|
| 1920 | **NOTHING.** `grep -c '\b1920\b' *.mjs` is 0 in every file. | — |
| 1700 | `breakpoint-sweep.mjs:2523` `TIERS5_WIDTHS` | the five-tier plan-catalog CTA control only — not a route sweep |
| 1440 | `overflow-guard.mjs` `WIDTHS` (GR108), `REF_WIDTHS` (W27-deploy-ref-branch-bounded), `AM_WIDTHS` (W23-account-modal-identity-bounded), `DETAIL_WIDTHS` (W21-detail-url-text-page-bound), `CLIP_WIDTHS` (W26-deploy-fail-clip), `DD_WIDTHS` (W34-deploy-detail-render-bound); plus `modal-oracle.mjs:312` and `hashchange-wiring.mjs:170` (`VIEW_W = env.WIDTH \|\| 1440`) | billing/overview past-due, deploy-ref, account modal, instance-cruel-detail, deploy-fail, deploy-detail; account modal states; hash routing |
| 1280 | `overflow-guard.mjs:2671` `FLICK_VIEWPORTS = [[320,568],[390,844],[1280,900]]` (W27-failed-retry-reachable-after-flick) and `:7610` `TRACK_WIDTHS` (W26-instance-track-min-content) | failed-provision retry dock; `sites-on-instance` at `#instance/…` |
| 1200 | `breakpoint-sweep.mjs` `TIERS5_WIDTHS` | tier cards only |
| 1042/1043 | `REF_WIDTHS`, `CLIP_WIDTHS` | deploy-ref, deploy-fail |
| 1040 | `breakpoint-sweep.mjs` `TIERS5_WIDTHS` | tier cards only |
| 1024 | `BAND_WIDTHS` (W13-detail-route-band), `REF_WIDTHS`, `CLIP_WIDTHS`, `DD_WIDTHS` | five detail routes + `#fleet`; deploy-ref; deploy-fail; deploy-detail |

`breakpoint-sweep.mjs`'s CONTINUOUS sweep — the one derived from app.css's own
`@media` set — tops out at **905**:

```bash
node -e 'import("./breakpoint-sweep.mjs").then(m=>console.log(Math.max(...m.WIDTHS)))'   # 905
```

### Routes NOT covered above 1024, by route

| Route | Highest width any instrument drives it at |
|---|---|
| `#instance/<id>` (instance workspace) | 1440 (`DETAIL_WIDTHS`, instance-cruel-detail) / 1280 (`TRACK_WIDTHS`, sites-on-instance) |
| `#site/<id>` | 1440 (`CLIP_WIDTHS`, `DD_WIDTHS`) |
| `#fleet` | **1024** (`BAND_WIDTHS`) |
| `#billing` | 1440 (`WIDTHS`, GR108 past-due) |
| `#overview` | 1440 (`WIDTHS`, `AM_WIDTHS`) |
| `#settings/members` | **900** (`MEM_WIDTHS`) |
| `#settings/tokens` | **430** (`TOK_WIDTHS`) |
| `#settings/providers` | **nothing above 905** (breakpoint-sweep only) |
| `#notifications` | 1440 (W12's wide control) |
| `#activity`, `#operator`, `#sites` | **nothing above 1024** |

## C1 — driven, at 1280/1440/1920, in both themes

**Every routable scenario in the corpus**, not a hand-picked list. 99 of 125
scenarios carry a resolvable `deepLink` (6 refuse to route at all — `loggedout`,
`loggedout-twofactor`, `operator-denied` × 2 themes — they render the auth
screen, not a `section.view`; 20 more carry no `deepLink`).

```
99 routable scenarios x 3 widths (1280/1440/1920) x 2 themes = 594 cells
>> 594 cells, 0 page-level overflows
```

Per cell the probe read `documentElement.scrollWidth/clientWidth`, the rendered
`section.view` id, `data-theme`, every leaf whose `scrollWidth > clientWidth+1`,
and every `overflow-y:hidden` host whose `scrollHeight > clientHeight+1`.
Representative cells, both themes, all three widths identical:

```
billing-past-due/light        1280:1280/1280 n=37   1440:1440/1440 n=37   1920:1920/1920 n=37
fleet-cruel-content/dark      1280:1280/1280 n=60   1440:1440/1440 n=60   1920:1920/1920 n=60
site-deploy-rail-failed/light 1280:1280/1280 n=170  1440:1440/1440 n=170  1920:1920/1920 n=170
members-cruel-content/dark    1280:1280/1280 n=66   1440:1440/1440 n=66   1920:1920/1920 n=66
overview-past-due/light       1280:1280/1280 n=95   1440:1440/1440 n=95   1920:1920/1920 n=95
instance-cruel-detail/light   1280:1280/1280 n=165  1440:1440/1440 n=165  1920:1920/1920 n=165
```

### The four leaf clips that survived, and why none is a body

| Host | sw/cw | Verdict |
|---|---|---|
| `.detail-url-text` 1958/649 (261ch, instance-cruel-detail) | ellipsis + `.copy-btn[data-copy]` carrying the full address | BY DESIGN — `W21-detail-url-text-page-bound` documents in-file that "`.detail-url-text` ellipsises, so ITS scrollWidth is EXPECTED to exceed clientWidth" |
| `.detail-url-text` 300/102 (40ch, panel-overview-member, timeline-events-only) | same rule, same copy button | BY DESIGN |
| `.deploy-detail` 414/108 (vertical) | computed `-webkit-line-clamp` is a number; `W34-deploy-detail-render-bound` asserts the disclosed cut per cell | BY DESIGN |
| `.visually-hidden` 985/1, 392/1, 89/1, 65/1 | the 1px screen-reader clip technique | BY DESIGN |

### THE CONTROL THAT KILLED A FALSE BODY

The first pass reported `.cli-chip-code 1076/584 163ch` on 6 scenarios
(`fleet-support-online`, `offload-filing/working/done/blocked`) — a 163-char
shell command 45% ellipsised, at 1920, with 1271px of empty viewport beside it.
That is the exact shape `app.css:5060-5100` already rules on for
`.archive-resurrect .cli-chip-code` ("a green sweep over a truncated shell
command is the failure this epic exists to prevent … an ellipsis on a scroller
is a lie"). **It was not a body.** The host lives inside the `#inst-cli-toggle`
disclosure, which ships `aria-expanded="false"`; the guard's own rendered-host
floor refused a run whose readiness selector was `.cli-chip-code`, naming it as
a host that "matches 1 node and NONE paints a box". Re-running the identical
sweep with `el.checkVisibility({checkOpacity:true, checkVisibilityCSS:true})`
required, `.cli-chip-code` disappears from the spill set entirely and the other
four survive unchanged. **A leaf scan without a visibility gate manufactures
bodies out of closed disclosures.**

## R4 — THE FINDING: the console saturates at exactly 1280

`.content { … max-width: 1040px; margin: 0 auto; }` (`cloud/priv/static/app.css:954`)
wraps every `section.view` (`index.html:285`), and the highest `@media` breakpoint
in the whole stylesheet is **904**:

```bash
grep -ohE '@media[^{]*' cloud/priv/static/app.css |
  grep -oE '(min|max)-width:\s*[0-9]+px' | grep -oE '[0-9]+' | sort -n | uniq -c | tail -3
#    3 899
#    1 900
#    1 904
```

Measured ladder on `instance-cruel-detail`, both themes, `.content` box width:

```
1024: .content=792   1040: .content=808   1100: .content=868   1200: .content=968
1240: .content=1008  1260: .content=1028  1280: .content=1040  1300: .content=1040
1440: .content=1040  1600: .content=1040  1920: .content=1040  2560: .content=1040
```

1280 − 1040 = the 240px sidebar: **1280 is the first width at which the content
column reaches its cap.** Dumping every `#view-instance *` box (left/top relative
to `.content`, width, height, 2dp) and comparing the 151 boxes that paint a
non-zero area:

```
1280 vs 1300 painted-boxes: IDENTICAL (md5 4c1a6323077e493c963a43e6731db6e6)
1280 vs 1440 painted-boxes: IDENTICAL (md5 4c1a6323077e493c963a43e6731db6e6)
1280 vs 1600 painted-boxes: IDENTICAL (md5 4c1a6323077e493c963a43e6731db6e6)
1280 vs 1920 painted-boxes: IDENTICAL (md5 4c1a6323077e493c963a43e6731db6e6)
1280 vs 2560 painted-boxes: IDENTICAL (md5 4c1a6323077e493c963a43e6731db6e6)
1280 vs 1024/1100/1200/1240/1260: DIFFER (every one)
```

The only rows that move above 1280 are 13 zero-area (`0.00,0.00`) boxes anchored
to the viewport rather than to `.content`.

**Consequence for instrument design: above 1280 there is exactly one layout.**
A width added to any leg at 1440 or 1920 is a re-run of its 1280 cell — it cannot
detect anything 1280 does not, and adding one would be a green by construction of
the purest kind. The band is worth ONE width, and one leg already drives it.

## C2 — no body, so NO LEG

Nothing person-level was found, so no leg was added and nothing in
`overflow-guard.mjs` changed. The probe used to produce every number above was a
throwaway `PROBE-desktop-band` leg, driven and then reverted
(`git checkout -- cloud/priv/static/__preview__/overflow-guard.mjs`); this packet
is the deliverable in its place.

---

## What the filing got wrong

The row's description was written 2026-08-02. Checked line by line against
today's bytes:

| Claim | Verdict |
|---|---|
| "GR108 tops out at 1440 for two past-due scenarios only" | **TRUE** — `overflow-guard.mjs:779` `WIDTHS = [721,750,768,769,775,780,785,800,900,1024,1440]` |
| "W13 stops at 1024" | **TRUE** — `:707` `BAND_WIDTHS` tops 1024 |
| "W15 at 1000" | **TRUE** — `:637` `FLEET_WIDTHS` tops 1000 |
| "W18 at 800" | **TRUE** — `:534` `CARD_WIDTHS` tops 800 |
| "every phone leg at 430" | **FALSE** — `PHONE_WIDTHS`, `SITE_PHONE_WIDTHS` and `LIVE_WIDTHS` all top at **620**, `ATT_WIDTHS` at **800**. Only `FLOOR_WIDTHS`/`TOK_WIDTHS`/`FAIL_WIDTHS`/`W26_WIDTHS` stop at 430 |
| "the W26 leg is the first to reach 1280 at all" | **TRUE WHEN FILED, STALE NOW.** `TRACK_WIDTHS` landed 2026-08-02 (`3a45111ab`, #9297); `FLICK_VIEWPORTS`'s `[1280,900]` landed 2026-08-03 (`7c8fa229a`, #9358) — the very next day. Two legs drive 1280 today |
| "No instrument sweeps the desktop band above 1280" (title) | **FALSE as a coverage claim.** 1440 is driven by SIX overflow-guard legs plus `modal-oracle.mjs` and `hashchange-wiring.mjs` (both default `VIEW_W = 1440`), and `breakpoint-sweep.mjs`'s `TIERS5_WIDTHS` reaches **1700**. What is genuinely undriven is **1920 alone** — and R4 proves that costs nothing |

**A stale in-file sentence this packet also corrects.** `overflow-guard.mjs:7584`
still reads "1280 APPEARS IN NO INSTRUMENT IN THIS REPO TODAY", and the leg's own
`okLine` at `:7704` prints "1280 is driven by NO other instrument in this repo" on
every clean run. `FLICK_VIEWPORTS` refuted both the day after they were written,
and `:2697` even carries an axis check asserting `[1280,900]` is present. Not
edited here — this branch adds no code — but it is a live false sentence in a
guard whose whole doctrine is that a quoted claim must be re-derived when quoted.
