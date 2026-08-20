# Re-home three below-bar instrument-hygiene rows → cch-instruments-epic (2026-08-18)

Wave: `cloud-gui-remake-wave-2026-08-18` (Cloud GUI remake RECONCILE wave).
Slice task: `gr-r-rehome-belowbar-instruments`.
Owner-of-record after this slice: `cch-instruments-epic` ("keep the measuring equipment honest").
origin/main HEAD at diagnosis time: `f532028339`.

The reconcile census found the GUI-remake epic's only genuinely-unbuilt open rows (besides the
GR112 audit) are three BELOW-BAR instrument-hygiene defects. None is an above-bar, user-facing,
offline-buildable GUI defect, so none is fixed this wave. Each was characterized to a
mutation-provable root cause and re-homed to its live owner carrying that diagnosis
(Felix-D211 spin-with-diagnosis-to-a-live-owner). No repo code changed; no PR.

Each move used the dedicated reparent verb `bp task move <row> cch-instruments-epic`
(POST /v1/tasks/:id/move → Tasks.Move, rail-l3 CAS + `task.reparented` event) — NEVER a flat
`parent_id` patch. Each move was verified by a single-doc `bp task get <row>` read of
`doc.parent_id == cch-instruments-epic` (never a `filter[parent_id]` list, never the move's own output).
All three stay `lifecycle=open` for the instruments epic to dispose of.

## 1) gr-blk-studio-presence-perf-flake

Timing assertion at `api/test/barkpark_web/live/studio/studio_live_sheet_presence_test.exs:321`
(`assert frame_ms < 10`; the MEASURE test starts at `:257`). It is NOT
`api/test/bench/validation_perf_test.exs` (that asserts shape, not timing — the prior fence-check
mis-cited it). Ran 5x on a quiet host: `frame_ms = 7.45 / 5.35 / 0.0 / 0.0 / 9.05 ms` — all PASS
(budget `<10`), peak `9.05` near the ceiling. Only failure mode is false-RED under host load; a
real render regression inflates the `moving` median, not the no-op identical-presence baseline, so
there is NO false-GREEN. BELOW-BAR: it never ships a bug, it only flakes red under load.
Fix shape if ever taken: widen the absolute budget to ~15-20ms with recorded rationale, or convert
to a reductions ratio (in-repo precedent
`api/test/barkpark_web/live/studio/chat_transcript_window_test.exs:181` `assert ratio < 30`).

## 2) gr-blk-shootsh-scen-suggester

`cloud/priv/static/__preview__/shoot.sh` lines 145-154: the unknown-SCEN handler greps
`${want%%-*}`. For a no-hyphen typo (`SCEN=empy`) the expansion is a no-op and matches nothing, so
the "Closest by prefix:" header prints with an EMPTY suggestion list — but the `exit 1` at line 154
sits outside the loop and fires unconditionally, so the abort is fully preserved: NEVER a false
green, purely a cosmetic empty-header. Fix commit `8a1545bd7` is NOT an ancestor of origin/main
(`git merge-base --is-ancestor 8a1545bd7 origin/main` exits 1), so the defect is LIVE on main.
Fix shape if ever taken: awk-Levenshtein fallback ranking all scenario names by edit distance to
the full typo when the fast prefix path returns empty; mutation-proof = `SCEN=empy` would then
suggest "empty".

## 3) gr-p5r7-badcode-shot-nondeterministic

The account-modal-2fa-badcode screenshot is not byte-reproducible because the badcode
confirm-error branch (`cloud/priv/static/app.js:1359`
`var again=$("#a2f-otp"); if(again){again.value=code; again.focus();}`) leaves a BLINKING TEXT
CARET in the focused `#a2f-otp` input — non-deterministic pixel state the shoot.sh
`--virtual-time-budget` does not freeze. It is NOT the QR (rendered as a byte-matched SVG per
`cloud/priv/static/app.js:22484` "THE GATE IS A BYTE-MATCH against the committed
__qr_fixture.json"; `qrSvg` at `app.js:22811`). The badcode capture is the only preview scenario
ending on a live caret, so relative to every other shot it cannot serve as a stable byte baseline.
Fix shape if ever taken: suppress the caret at shoot time
(inject `* { caret-color: transparent !important }` or blur before capture), or declare this shot
hash-unstable-by-design so no gate pins it.
