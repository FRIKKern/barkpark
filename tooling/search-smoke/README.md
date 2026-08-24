<!-- doc-tier: human | canonical-for: search-starter-journey-smoke | budget: 1800tok -->
# search-smoke — does the search demo actually work?

`journey-smoke.mjs` drives a real headless Chrome through the six beats of the
search-starter journey and asserts what a person would actually check. It exists
because the Next edition of the template had **zero** browser-level coverage:
every acceptance it ever passed was an HTTP status code or a `grep` over a
`.tsx` file. That is how three defects shipped and sat live for nine days —

- a red **"Search failed."** banner at first paint (HTTP 200),
- a **dead live-search websocket** (the join-refused path is silent by design;
  the finder falls back to HTTP and the DOM is pixel-identical),
- **100% soft-404 detail routes** (Next streaming a not-found body with 200).

Every one of them is invisible to `curl` and obvious to an eye in one second.

## Run

```bash
# report on a deployed site — always exits 0, the OUTPUT is the signal
node tooling/search-smoke/journey-smoke.mjs --url https://host/sites/slug/

# seal mode — exits 1 unless every beat PASSED
node tooling/search-smoke/journey-smoke.mjs --url https://host/sites/slug/ --strict

# certify the harness itself, offline, no network, ~45s
node tooling/search-smoke/journey-smoke.mjs --self-test
```

Flags: `--query <q>` (default `search`), `--engine <e>` (default `postgres`),
`--json` (machine-readable ledger after the report), `--help`.
Env: `CHROME=/path/to/chrome`, `SMOKE_URL`, `SMOKE_QUERY`, `SMOKE_ENGINE`.

**Zero dependencies.** Node 22's native `fetch` + native `WebSocket` speak the
Chrome DevTools Protocol straight to `--headless=new`. No puppeteer, no
playwright, no browser download — the transport, the exit-code doctrine and the
never-block-on-the-child teardown are lifted from the CI-proven
`cloud/priv/static/__preview__/cssom-parity.mjs`.

## The six beats

| Beat | What it proves |
|---|---|
| `LAND` | no search-error banner (`[data-search-error]`, copy-text fallback) · `[data-nav-result]` rows > 0 · zero `Runtime.exceptionThrown` |
| `TYPE` | a real keystroke transitions the result set **and** the websocket carried it |
| `CLICK` | clicking the first result reaches a `.bp-paper-surface` with non-empty text, no new exception |
| `E404` | `/d/zzztype/foo` returns a **real** HTTP 404, not a 200 with a not-found body |
| `ENGINE` | the keystroke leg again with an explicit `?engine=postgres` |
| `PHONE` | at **390x844**, zero requests match `/bp-graph.js|graph.json/` — **and**, at 1440x900, the same page *does* fetch the renderer and *does* mount the pane |

Each beat is `PASS`, `FAIL` or `PENDING`. **`PENDING` is never a pass** — it
means a prerequisite failed so the assertion never ran. Report mode prints it;
`--strict` refuses it.

### Why `PHONE` is a pair, not an assertion

Hiding is not not-shipping. The Astro flagship hid the corpus-graph pane below
`md` in CSS alone, and at a 390x844 emulation `#bp-graph-slot` had a computed
`display` of literally `none` while the page had still pulled `bp-graph.js`
(140,221 B) and `graph.json` (436,769 B) — **576,990 B delivered to a viewport
that never shows a pixel of it** (charter D79). The portal mounted the pane into
the hidden element and the mount effect appended the `<script>`. `display: none`
stops paint; it does not stop a subtree that ran.

No `grep` can see this: the CSS class is identical whether or not the assets are
also fetched, and the fetch is three modules away inside an effect. Only the wire
distinguishes them.

The desktop arm is **not optional**. "The phone requests no graph" is also true
of a graph that is dead at *every* width, so a phone-only assertion would ship
green over a completely broken landing. `PHONE` therefore fails in both
directions, and `--self-test` demonstrates both reds.

The phone arm also waits the **full** settle cap before reading, because "zero
requests" passes trivially if you look too early — and the desktop arm proves
that cap is long enough by producing its own request inside it.

**Honest limit, stated in the harness header too:** 390x844 is CDP
`Emulation.setDeviceMetricsOverride` — a real layout viewport, a real `mobile`
flag, a real `matchMedia` result. It is **not a physical device**: no device CPU,
no device network, no touch hardware. The beat proves what the page *asks for* at
that width, which is exactly its claim and nothing more.

### Why the websocket is asserted at the transport, not the DOM

The DOM **cannot** express this beat. When the channel join is refused,
`use-live-search.ts:104-112` silently serves HTTP results that look exactly like
live ones, so a "the results changed" assertion passes green over a completely
dead socket. `TYPE` therefore reads the CDP `Network` domain directly:
`webSocketCreated` fired, a `query` frame was **sent** after the keystroke, and a
reply frame came back carrying `count > 0`. Phoenix v2 array frames and v1
object frames are both decoded; an unrecognised serializer degrades to a text
scan rather than a false red.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | every beat passed — or report mode, which never fails on site content |
| `1` | a beat was not `PASS` under `--strict` — a fact about the **site** |
| `2` | GUARD: no Chrome, no Node-22 `WebSocket`, missing `--url`, unknown flag — a fact about the **environment or the invocation**, refused before Chrome is spawned |

The 1/2 split is load-bearing. A misconfigured runner must never red a PR with a
message that reads like a site defect, and a mistyped `--stict` must never sail
through report mode and certify a broken demo as fine.

## `--self-test` is the mutation proof

It boots a local fixture server (`node:http` plus a hand-rolled RFC-6455
websocket — no `ws` package) serving **three** sites and asserts the harness's
verdict on each:

| Fixture | What it is | Expected verdict |
|---|---|---|
| `/good/` | a healthy miniature finder; graph pane CSS-hidden **and** mount-gated below `md` | 6/6 `PASS` |
| `/rot/` | the shipped defects: red banner, zero rows, soft-404 — **and no graph at any width** | `LAND` `E404` `ENGINE` `PHONE` **FAIL**, `TYPE` `CLICK` `PENDING` |
| `/mute/` | lands, types and re-renders perfectly over a **dead socket** — and mounts the graph at **every** width | `TYPE` `ENGINE` `PHONE` **FAIL**, the rest `PASS` |

`/mute/` is the one that matters most: a DOM-only harness passes it green on
both of its defects. It is what proves the transport assertions are load-bearing
rather than decorative — its `PHONE` red names the wasted bytes outright.

`/rot/` carries the *opposite* graph defect on purpose: with no graph at all its
phone arm is trivially green, and `PHONE` still refuses the site because the
desktop arm reds. That is the false seal, demonstrated rather than argued.

A check whose red has never been demonstrated is not a check — so every red is
demonstrated on every run, offline.

## CI

`.github/workflows/search-starter-smoke.yml`, two jobs that answer two different
questions and are deliberately not merged:

- **harness-self-test** — path-filtered on `templates/search-starter/**` and
  `tooling/search-smoke/**`. `node --check` + `--self-test`. No network, so it
  is safe as a required check. It certifies the *instrument*.
- **live-journey** — `schedule` (06:20 UTC) + `workflow_dispatch`, report mode,
  never on a PR. A deploy outage is not a property of anyone's diff, so it can
  never be a merge gate. **This job is the rot alarm.**

The strict live run is not wired: it is the wave-seal evidence, run by hand
after a redeploy. Scheduling it would red the repo daily for as long as a known
defect is knowingly in flight, and a gate that cries wolf is disabled within a
wave.

## Reading a real failure

Live `search-ember`, 2026-07-26, report mode — the harness catching all three
shipped defects plus one the ledger had not yet named:

```
✗ FAIL  LAND    ✗ the red first-paint banner is on the page · rows=0
· PEND  TYPE    · the finder never landed
· PEND  CLICK   · no result rows to click — LAND failed
✗ FAIL  E404    ✗ /d/zzztype/foo → 200 (SOFT-404: a 200 carrying a not-found body)
✗ FAIL  ENGINE  ✓ keystroke transitions the result set (engine=postgres)
                ✗ NO websocket was ever created — silent HTTP fallback
```

Note the last beat: with `?engine=postgres` the site *does* land results, so the
first-paint failure is the **default (indx) engine**, and the socket is dead on
both. Neither fact is reachable from a status code.
