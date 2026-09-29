# The 1440 wide-bucket open-leg no-op — forcing repro transcript

Charter D184 / task `spd-w13-open-leg-wide-bucket-flake`. Produced by
`node scripts/measurements/open-leg-wide-bucket-repro.mjs` on 2026-09-10,
real chromium, viewport 1440x900, `data-width-bucket="wide"`.

The BEFORE leg reproduces the deployed artefact's terminal reading exactly —
`width_px 41, left_px 1399, user_opened false, bucket "wide"` — with the
control present and clicked all three times. The CONTROL leg (nothing
swallowed) reaches the marker in two clicks against the same handler
arithmetic, which is why the collapse is not the defect.

```
playwright 1.59.1 — chromium, viewport 1440x900, wide bucket

=== CONTROL — faithful handler, nothing swallowed (swallow 0 click(s) after the collapse) ===
  ms: 2033
  before:            {"user_opened":false,"is_open_class":true,"left_px":1140,"width_px":300,"bucket":"wide"}
  click 1 [collapsed-by-us]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
  click 2 [user-opened]: {"user_opened":true,"is_open_class":true,"position":"static","transform":"none","left_px":1140,"width_px":300,"z_index":"auto","bucket":"wide"}
  reached: true  clicks_needed=2  landed=2 swallowed=0
  what the "server" saw: ["collapsed","opened"]

=== BEFORE — blind three-click budget (swallow 2 click(s) after the collapse) ===
  ms: 561
  before:            {"user_opened":false,"is_open_class":true,"left_px":1140,"width_px":300,"bucket":"wide"}
  click 1: {"user_opened":false,"is_open_class":false,"left_px":1399,"width_px":41,"bucket":"wide"}
  click 2: {"user_opened":false,"is_open_class":false,"left_px":1399,"width_px":41,"bucket":"wide"}
  click 3: {"user_opened":false,"is_open_class":false,"left_px":1399,"width_px":41,"bucket":"wide"}
  reached: false
  what the "server" saw: ["collapsed","swallowed","swallowed"]

=== AFTER — landed-click budget + bounded swallow allowance (swallow 2 click(s) after the collapse) ===
  ms: 6429
  before:            {"user_opened":false,"is_open_class":true,"left_px":1140,"width_px":300,"bucket":"wide"}
  click 1 [collapsed-by-us]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
  click 2 [no-transition]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
  click 3 [no-transition]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
  click 4 [user-opened]: {"user_opened":true,"is_open_class":true,"position":"static","transform":"none","left_px":1140,"width_px":300,"z_index":"auto","bucket":"wide"}
  reached: true  clicks_needed=4  landed=2 swallowed=2
  what the "server" saw: ["collapsed","swallowed","swallowed","opened"]

=== AFTER — swallowing past the bounded allowance (swallow 99 click(s) after the collapse) ===
  ms: 6420
  before:            {"user_opened":false,"is_open_class":true,"left_px":1140,"width_px":300,"bucket":"wide"}
  reached: false
  SKIP: INSTRUMENT FAILURE — 4 real clicks on [data-test-id="sidebar-toggle-panel"] (1 landed, 3 swallowed; budget 3 landed + 2 swallowed) never produced [data-user-opened] on .bp-doc-sidebar. The harness never reached the user-opened state, so it has NO user-opened measurement to report — this is not a desk fact and must not be recorded as one (D97).

  VERDICT: 3 of those 4 click(s) moved NOTHING observable on .bp-doc-sidebar (no change to data-user-opened, .is-open, width, left or transform), so they never reached Handlers.Paper.sidebar_toggle_panel/1 — the desk did not answer "no", it did not answer at all. That is a SWALLOWED click (a re-render swapping the button under the pointer, or a socket still joining), not the desk refusing to re-open, and the bounded allowance of 2 was exhausted.

  What it saw after each click:
      click 1 ([data-test-id="sidebar-toggle-panel"]) [collapsed-by-us]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
      click 2 ([data-test-id="sidebar-toggle-panel"]) [no-transition]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
      click 3 ([data-test-id="sidebar-toggle-panel"]) [no-transition]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
      click 4 ([data-test-id="sidebar-toggle-panel"]) [no-transition]: {"user_opened":false,"is_open_class":false,"position":"static","transform":"none","left_px":1399,"width_px":41,"z_index":"auto","bucket":"wide"}
  what the "server" saw: ["collapsed","swallowed","swallowed","swallowed"]
```
