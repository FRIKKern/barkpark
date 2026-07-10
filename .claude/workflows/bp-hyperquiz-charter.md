# Hyperquiz — Founding Charter

Epic root: `hyperquiz-epic` (guerrilla, published). Charter written 2026-07-10 by the Decide-phase strategist.

## Vision

A live-quiz game running on Barkpark itself: a projector shows the spectacle (`/quiz/host/:pin` — question, choices, a swarm of live cursors or a heatmap cloud), phones are the input (`/quiz/play/:pin` — tap a choice, stream a cursor), and Studio is the authoring desk — the host live-edits a question mid-game and every connected screen updates in under a second. Server-authoritative realtime (Room GenServer, 15Hz binary cursor codec, O(1) heatmap), honest states, no fake realtime, styled from the same theme tokens as the rest of Barkpark, live on guerrilla where merged = deployed.

The engine already exists: local branch `hyperquiz-p1-recovered`, 28 commits, +2,952 lines / 35 files, 99 tests green when applied to current main (verified by an actual port attempt 2026-07-09). Priority order for this epic: **landing the stranded engine on main beats any new feature work.**

## Decisions

Provenance note: decisions A/B/C were originally recorded by the bp-autopilot loop (local `hyperquiz-decisions` paper, 2026-06-29) with no human sign-off. This charter **ratifies them on the merits** after a provenance audit against the built code. **The human may veto any of them**; all are reversible-by-design as noted.

1. **A — Split-surface (RATIFIED, text corrected).** Projector = spectacle, phones = simple input. Why: it is built, structurally embodied (`data-quiz-role` host/player, host joins `observe: true`), and it is the product's differentiator. **Correction to the recorded text:** players stream *continuous* pointer/touch position at ~30Hz (quiz-cursors.js pointermove, throttled 33ms), not the paper's "tap-hold = hover, drag a dot". Ratified as built. Reversal cost: client-only — the gesture lives in one branch of quiz-cursors.js; the server treats cursors as opaque normalized coords.
2. **B — ~2,000/room hybrid, single node (RATIFIED).** Individual cursors below a crossover threshold, O(1) 32×32 heatmap (fixed 2,048-byte payload) above it. Why: cleanly embodied and already runtime-tunable — `@heatmap_threshold 300` (room.ex:58) with a live `set_heatmap_threshold/2` setter, test-pinned on both sides of the crossover. Single node suffices for the target. Reversal cost: one integer / one runtime call.
3. **C — Demo-first (RATIFIED, boundary restated).** Ship the demo value now; defer P7 infra spend. **Honesty note:** the recorded text says "ship P1–P4, skip most P6" but the autopilot actually built P1–P6 in full (signed reconnect identity, backpressure, observability, anti-abuse — all tested). The overshoot is free, delivered work. The real, honored boundary is: **stop before P7.** `hq-p7-billing` (pricing = genuinely human), `hq-p7-shard` (only if a proven load ceiling demands it) are filed and PARKED on guerrilla. Region placement needs nothing: guerrilla exists. P7-deploy is NOT parked — it is this wave (merge → auto-deploy → live smoke).
4. **D — Land as a `Barkpark.Plugin`, not a straight rebase.** Why: the branch's only conflicts are the 3 core files it hardwires (application.ex/endpoint.ex/router.ex) — exactly the plugins-off-doctrine violation. `register_workers/1` absorbs the supervision children (pulse.ex:75 precedent), `register_routes/1` with `:public_root` absorbs the routes (bulldocs.ex:116-130 precedent; router auto-injects at router.ex:883), `register_schemas/1` replaces the branch's dead `Quiz.Content.register_schema/1` (never called — schemas register via Plugins.Bootstrap). The **one irreducible core edit** is the `socket "/quiz"` line in endpoint.ex — Phoenix `socket/3` is a compile-time macro with no plugin callback; Pulse hand-adds its socket the same way, so this is the accepted bar, not a violation. Accepted tradeoff (same as Pulse): the socket compiles unconditionally, so a disabled quiz plugin still exposes a dormant `/quiz` socket path — harmless with no reachable channel. Module naming: keep the `Barkpark.Quiz.*` namespace (pulse precedent: `Barkpark.Pulse.*`) fronted by a `Barkpark.Plugins.Quiz` plugin module.
5. **E — Re-skin onto the theme-token stylesheet.** quiz.html.heex hardcodes an 11-hex palette; since the branch was cut, derive(theme) became the color source. Why: consistency with the shipped theme system; the conforming pattern is bulldocs.html.heex:67 — consume `Barkpark.PortableDoc.Render.Stylesheet.css()` for core tokens; the Kahoot-style 4-choice palette (c0..c3) may remain as quiz-scoped named tokens since the theme manifest has no game palette. One-file change; the LiveViews hardcode zero colors.
6. **F — Guerrilla is the canonical ledger; local hq-\* history is evidence-of-work only.** The 45 local hq-\* tasks are unpublished DRAFTS on localhost:4000, invisible to the epic machinery and to pr-task-gate. Their "done" statuses reflect real-but-stranded branch work, not a published ledger. Fresh published tree filed on guerrilla under `hyperquiz-epic`; the 7 local design papers get re-ingested to guerrilla so the design history survives.
7. **G — Demo go-live gate list is short and known.** Quiz's diff is all `api/**` → merge triggers guerrilla blue/green auto-deploy; zero migrations, zero new env vars, zero Caddy work (blanket reverse_proxy carries websockets). The ONE runtime footgun is check_origin (Past-Mistake-11): the demo must reach guerrilla via its PHX_HOST domain (guerrilla.barkpark.cloud) or a `BARKPARK_EXTRA_ORIGINS` entry, else `/quiz/websocket` 403s silently. The branch's own admitted gap — cursor canvas + heatmap never verified in a real browser — is closed this wave via chrome-devtools against the live surface.

## Roadmap

Wave 1 (this wave — land the engine, go live):

1. `hq-w1-plugin-port` (large) — Port the hyperquiz engine from `hyperquiz-p1-recovered` onto main as a Barkpark.Plugin; one core line (endpoint socket); schema wired via register_schemas; 99 tests green; PR through Elixir Test + pr-task-gate.
2. `hq-w1-theme-reskin` (small, after port merges) — quiz.html.heex onto the token stylesheet, bulldocs pattern.
3. `hq-w1-live-verify` (medium, after port deploys) — chrome-devtools against live `/quiz/host|play/:pin` on guerrilla: websocket 101 (not 403), cursor canvas, answer flow, Studio live-edit round-trip, honest error states. Closes the browser-verification gap.
4. `hq-w1-papers-docs` (medium, parallel) — re-ingest the 7 hyperquiz papers to guerrilla; amend `hyperquiz-decisions` with the ratification + the two text corrections (A's gesture, C's P6 overshoot); rewrite HYPERQUIZ.md for the plugin architecture and parked P7.

Parked (filed on guerrilla, priority 4, label `parked` — do not build):

- `hq-p7-billing` — pricing is a human/business decision. Unpark only by human direction.
- `hq-p7-shard` — multi-node sharding. Unpark only if a measured load ceiling on guerrilla demands it (Decision B says single node covers ~2,000/room).

Future waves (candidates, not committed): load-proofing toward the 2,000/room target on guerrilla; gesture polish if Decision A's input mode gets human-revised; quiz content library / templates in Studio; P7 unparks if vetoes or load data arrive.

## Wave log

(empty — the reviewer appends one entry per wave)
