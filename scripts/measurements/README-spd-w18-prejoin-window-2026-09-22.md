# The pre-join window, measured — and it is a DIFFERENT swallow

`task-c2dd40c6f433a787`, criterion c0: *"the swallow reproduced as a PROPERTY OF THE CODE, not of a
hand-armed attribute … the attribute arriving on its own … state the width of the window you
measured and the sha."*

Instrument: `scripts/studio-prejoin-live-probe.mjs` (tracked, so it gets checked).
Data: `spd-w18-prejoin-window-2026-09-22.json`.
Host `https://guerrilla.barkpark.cloud`, served **`e02e4296d`**, 2026-09-22 ~08:5xZ, headless
Chromium via the repo's own playwright. **Nothing is set by hand**: every `data-phx-ref-src` below
was stamped by LiveView's own `putRef`, and the only number that decides anything is the count of
`"type":"click"` frames leaving `WebSocket.prototype.send`.

## Three arms, three runs

    ARM 1  PRE-JOIN    #item-paper pressable @26ms · view joined @226ms  → WINDOW 200ms
                       press @26ms (joined=false, ref=false)            → 0 click frames · SWALLOWED
    ARM 2  SETTLED     same button, same page, joined                    → 0→1 frames · URL → /studio/paper
                       ref arrived BY ITSELF, cleared after ~375ms
    ARM 3  IN-FLIGHT   press, then press again while that ref is on      → 0→1→1 · second SWALLOWED
                       ref self-arrived · window 411ms

Three consecutive runs of arm 1 measured the pre-join window at **196ms, 193ms and 200ms**
(`#item-paper` in the DOM at 23.6 / 60.8 / 26ms; `phx-connected` on `[data-phx-main]` at
220.0 / 253.8 / 226ms). Arm 3's in-flight window measured **400ms, 405ms and 411ms**.

**Arm 2 is the control, and it is why arm 1's zero is evidence.** A frame counter that has never
counted is not an instrument. The same button, in the same session, on the same page, puts exactly
one frame on the wire once the view has joined, and the URL moves to `/studio/paper`. Both counters
move.

## The remedy, answered on the same surface

`--with-fix` reads the `BP-PREJOIN-QUEUE` fence out of the worktree's `root.html.heex` and injects it
ahead of the served page's own scripts, so the remedy is exercised **on the desk the defect was
measured on**, not only in the offline fixture. Same host, same sha:

    ARM 1 PRE-JOIN  pressable @25ms · joined @261ms → WINDOW 236ms · press @25ms → 1 click frame · SENT
                    refs seen: studio-panes+@261  item-paper+@262  studio-panes-@283  item-paper-@654

`item-paper+@262` is LiveView stamping its OWN ref on the replayed press, 1ms after the join.

**That arm found a defect in the fix that the offline fixture could not.** The first draft's join
watcher bailed out when `document.documentElement` was null and armed nothing; the click listener
still swallowed the press, so the queue held it to the ceiling and the arm read `0 click frames ·
SWALLOWED` — a *worse* desk than the one being fixed, and silent. The shipped body script never
reaches that state, which is exactly why only an injected run could see it. The fence now retries on
`readystatechange`.

## What the row got wrong

c0 asks for the attribute "arriving on its own, **in the window between page load and socket join**".
It cannot. A `MutationObserver` armed before the first byte of page script recorded EVERY
`data-phx-ref-src` change on the document: the first one arrives at **t=226ms — at the join**, on
`#studio-panes`, from the WidthBucket hook's own mount `pushEvent`. **Zero before it.**

The reason is in the vendored bundle: `View.pushWithReply` opens with
`if (!this.isConnected()) return Promise.reject(new Error("no connection"))`, **before** it calls the
ref generator, so `putRef` never runs and no ref is ever stamped pre-join. The press is discarded by
the connection check, not by `bindClick`'s early return.

So there are **two swallows**, not one:

| | pre-join | in-flight |
|---|---|---|
| window | load → join (**~197ms** on `e02e4296d`) | the server round trip (**~405ms**) |
| drop site | `pushWithReply`'s connection check | `bindClick`'s early return on `data-phx-ref-src` |
| ref present? | no — it cannot be | yes, stamped by `putRef` |
| shipped remedy before this row | none | the in-flight guard (unpressable + words) |
| remedy here | QUEUE-AND-REPLAY | unchanged — still unpressable |

Arm 3 is the row's own defect, reproduced with nothing hand-armed, and it is left alone on purpose:
see the fence comment in `root.html.heex` for why replaying an in-flight press is the more dangerous
of the two.

## The window shrank, and that is not a remedy

The original filing measured a socket join at 4.9s; `e02e4296d` joins in ~0.2s. The press is still
lost — it is simply lost less often, and it will be lost more often again on a slow host, a cold
cache or a loaded box. That is the state this row was filed to end.
