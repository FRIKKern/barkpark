# webview-spike — THROWAWAY D11 harness (not product code)

**This is a spike artifact.** It exists to render one numeric verdict (charter
D11) and then die. It is deliberately **not** a member of any pnpm workspace
glob — install it standalone with `npm`. Nothing in `apps/` or `js/` may import
from here; nothing here ships.

**The question it answers:** can react-native-webview **13.16.1** (Expo-curated;
Expo SDK 57 / RN 0.86, new architecture) render the capstone paper
(`barkpark-tasks-mobile-capstone`: 104 blocks, 16 headings, 3 inert mermaid
mounts, 0 images) through the real `@barkpark/react` `renderPortableDocument` +
the real `paper-surface.css` (93,449 B, zero `url()`) within the D11 budgets?
**Any single FAIL** promotes the native prose fast-path into v1 and re-plans
wave 2's renderer budget (crown cr-059).

## D11 thresholds (fixed at Decide)

| Axis | Threshold |
|---|---|
| 1 · cold-load → FMP, 10 runs | P50 ≤ 800 ms, P95 ≤ 1500 ms |
| 2 · full-document scroll | ≥ 50 fps avg, ≤ 17% janky (16.6 ms budget), 0 frames > 100 ms |
| 3 · memory, 3–4 warm WebViews | ≤ 350 MB total PSS, ≤ 60 MB marginal per warm WebView |
| 4 · file/baseUrl vs inline | cold-load P50 ≤ 1.3× inline OR ≤ +200 ms |

Emulator numbers are **advisory tripwires only**. The binding verdict is a
**human-executed run on real mid-tier Android hardware**; the epic lead stamps
the verdict criterion from `results/RESULTS.md`.

## Layout

```
build-harness.mjs      renders the capstone -> assets/ (self-asserting; exit != 0 on failure)
assets/                generated: capstone-inline.html, capstone-file.html,
                       paper-surface.css, generated.js (JS-string module), capstone.json (cache)
App.js + index.js      bare Expo app: one full-screen WebView (owns its own scroll)
scripts/run-*.sh       adb drivers for the four axes
scripts/parse-results.mjs  raw output -> numeric verdict table + results/RESULTS.md
scripts/test-parse.sh  no-device self-test of the parser (synthetic fixtures)
results/               raw runs + RESULTS.md (gitignored)
```

## 1 · Build the harness (any machine, no device)

```bash
# from the repo root — build the real renderer first
pnpm install --filter @barkpark/core --filter @barkpark/react
(cd js/packages/core && pnpm build)
(cd js/packages/react && pnpm build)

cd tooling/webview-spike
node build-harness.mjs            # fetches the capstone via `bp` (read-only, guerrilla token)
node build-harness.mjs --cached   # offline re-run from assets/capstone.json
```

Self-asserts: 104 blocks each render non-empty; 16 `<h1-3>` with **zero empty**
(the D12 heading `content[]` fix must be on main); 3 inert mermaid mounts
(mermaid is deliberately NOT bundled — the mounts stay `<pre class="mermaid">`);
CSS self-contained; both variants + `generated.js` written; ~178 KB inline payload.

## 2 · Install the app on a device (HUMAN, on hardware)

```bash
cd tooling/webview-spike
npm install                       # standalone on purpose — NOT pnpm
npx expo install --fix            # reconcile Expo-curated pins if npm drifted them
npx expo run:android --variant release
```

**Release build required for the binding verdict** — debug JS + dev WebView skew
every axis. Verify the device: `adb devices` shows exactly one `device` row.

## 3 · Measure — one command

```bash
bash scripts/run-all.sh           # all four axes -> results/RESULTS.md + verdict table
```

Or per axis: `scripts/run-cold-load.sh <inline|file> [runs]`,
`scripts/run-scroll.sh`, `scripts/run-memory.sh`, then
`node scripts/parse-results.mjs`. Exit codes: 0 PASS · 2 FAIL · 3 incomplete.

The RESULTS.md carries device identification (model, Android version, System
WebView version, emulator flag) — the lead needs it to stamp the verdict.

## Measurement notes (traps, honestly)

- **FMP proxy** = double `requestAnimationFrame` after `DOMContentLoaded`,
  posted to RN via `postMessage`. Sound for THIS document: fully static, 0
  images, inert mermaid. `rn_ms` (WebView mount → FMP, includes WebView
  spin-up) is the graded number; `dom_ms` is the in-page cross-check.
- **The WebView owns its own scroll** — it is never nested in a ScrollView
  (react-native-webview issue #22; `nestedScrollEnabled` is the documented
  Android workaround if a product surface ever must nest — the spike measures
  the clean full-screen shape).
- **Scroll axis** rides `adb shell dumpsys gfxinfo <pkg> framestats` — modern
  Android WebView renders in-process, so the app package's frame data covers it.
  `Flags != 0` rows (first-draw frames) are excluded per the Android docs.
- **Memory axis** compares `warm0` (1 active WebView) against `warm3` (1 active
  + 3 mounted-undestroyed) — marginal = delta/3. Warm views are stacked behind
  the active one, `pointerEvents="none"`, never unmounted.
- **Axis-1 grading is on the inline variant** (the shippable primary); the
  file/baseUrl variant is graded relatively on axis 4.
- The capstone fetch is **read-only** (`bp doc get paper
  barkpark-tasks-mobile-capstone`), token from `~/.config/barkpark/config.json`
  `known_servers`.

## Verifying the toolchain with no device

```bash
node build-harness.mjs --cached   # self-assertions
bash scripts/test-parse.sh        # parser vs synthetic fixtures (plants one FAIL)
```
