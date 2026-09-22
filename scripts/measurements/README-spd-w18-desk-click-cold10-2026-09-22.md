# spd-w18 c1 — ten COLD loads, one press each, on the deployed desk

`spd-w18-desk-click-latency`, criterion c1: *"A single press on `#item-paper` reliably patches the
URL across 10 consecutive cold loads with no retry, and the observed latencies are quoted."*

Data: `spd-w18-desk-click-cold10-2026-09-22.json`.

**Nothing was built for this.** The instrument is the harness PR #16603 (`41de602a0`) shipped for
c0, run with the invocation the row itself recorded. What is new here is the measurement and its
three controls.

## The numbers

Host `https://guerrilla.barkpark.cloud`, served **`1b3856eed`** (the harness's own PRE/POST
served-commit stamp read the same sha on all ten runs, so no deploy landed mid-measurement).
Headless Chrome `153.0.8010.53` at its `--headless=new` default viewport — `journey.mjs` passes no
`--window-size`. 2026-09-22 01:43:07Z → 01:47:09Z.

    run   latency   presses   wire
      1     0.3 s      1      SENT · 1 click frame
      2     0.7 s      1      SENT · 1 click frame
      3     1.1 s      1      SENT · 1 click frame
      4     0.5 s      1      SENT · 1 click frame
      5     1.3 s      1      SENT · 1 click frame
      6     0.5 s      1      SENT · 1 click frame
      7     0.5 s      1      SENT · 1 click frame
      8     0.6 s      1      SENT · 1 click frame
      9     0.5 s      1      SENT · 1 click frame
     10     0.5 s      1      SENT · 1 click frame

min **0.3 s** · median **0.5 s** · mean **0.65 s** · max **1.3 s**. The harness prints one decimal;
0.1 s is the quantisation, not a distribution rounded away. 10/10 patched, 0 retries.

Compare the filing, measured on deployed `e4ed31a10` (2026-07-29): **1.6 s, 2.4 s, and never within
15 s**, with one run's socket joining at 4.9 s. Here the socket joins in **0.2 s** on every run.

## Three controls, because each of these numbers is a claim that could be manufactured

**"COLD" is proved, not asserted.** `journey.mjs` builds its Chrome user-data-dir with
`fs.mkdtempSync(os.tmpdir(), "studio-journey-")` and deletes it at teardown. Each run was handed its
own `TMPDIR`, created empty by the driver and **verified empty** (`entries_before=0`) immediately
before launch. A separately watched run polled that directory at 2 Hz *during* the run and saw the
profile appear at t=1.0 s as `studio-journey-pA6teo` with **`Cookies=0`** and 97 cache files, rising
to 172 by t=1.5 s, and the directory empty again after teardown. An empty cookie jar at first sight
means the session cookie came from that run's own ticket redeem; a cache growing from zero means the
HTTP cache started empty; a deleted profile means nothing crosses into the next run.

**"No retry" is an absence, and an absence is never caught by inspection.** `1 press(es)` is only
evidence if the counter can print something else. Mutation **M-RETRY** was applied to the *offline*
self-test fixture's `#item-paper` handler — `if ((window.__mSwallowFirst = (window.__mSwallowFirst||0)+1) === 1) return;` —
so the first click is swallowed. The same check line, on the same `clickUntil` path, then printed
**`in 5.5s after 2 press(es) · SENT — 2 "type":"click" frame(s)`**. Both counters move. The mutation
was reverted and does not ship.

**"10/10 green" is only a result if the probe could have gone red.** Offline: `self-test` executes
134 assertions (floor 40) and exits `good=0, rot=1`. Live, on the deployed desk: a **single**
`evaluate_script` — arming and reading never split across two calls — set `data-phx-ref-src` on
`#item-paper` (the row's own named gate 3), pressed, and polled 6 s; then removed the attribute and
pressed **the same button on the same page** in the same evaluation.

    ARM 1  gate 3 armed     answered=false   URL unchanged after 6.010 s   SWALLOWED
    ARM 2  attribute gone   answered=true    /studio/paper in 0.371 s

## What this does NOT say

**The row's title defect is not fixed.** ARM 1 above reproduces the swallow on `1b3856eed` in
6.0 s: LiveView's `bindClick` still returns early on an element carrying `data-phx-ref-src`, with no
exception, no flash and no server trace. c1 is a reliability claim about a press on a settled cold
desk, and on that narrow question the deployed desk answers first-press every time. The swallow
window did not close — it **shrank**, because it is proportional to the socket-join latency, and that
went from 4.9 s to 0.2 s.

## Retraction: c1 never needed a deploy

The 2026-09-06 attempt note on c1 reads *"NEEDS A DEPLOY, not more build … Re-run it once
`41de602a0` is live on the box."* That is wrong. `41de602a0` touched exactly two files —
`tooling/studio-journey/README.md` and `tooling/studio-journey/journey.mjs` — and nothing
server-side. The harness is a local client that drives a headless Chrome **against** a deployed
host; it is never itself deployed. It became runnable the moment #16603 merged to `main`, and c1 was
measurable from that day. Sixteen days were spent waiting for a deploy the criterion did not need.

Separately, and not a blocker here: the prod micro-block `89.167.28.206` reports commit
`ca4534461` (2026-08-31) and does **not** contain `41de602a0`. That host is not what this harness
targets; `guerrilla`, the host the row's own description was measured on, serves `1b3856eed`.
