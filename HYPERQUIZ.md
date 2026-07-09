<!-- doc-tier: human | canonical-for: hyperquiz | budget: 900tok -->

# Hyperquiz

A live-quiz game running on Barkpark itself: a projector shows the spectacle
(`/quiz/host/:pin` — question, choices, a swarm of live cursors or a heatmap
cloud), phones are the input (`/quiz/play/:pin` — tap a choice, stream a
cursor), and Studio is the authoring desk — the host live-edits a question
mid-game and every screen updates in under a second. Server-authoritative
realtime, honest states, no fake realtime, styled from the shared theme tokens.

**Canonical ledger:** the `hyperquiz-epic` task tree on guerrilla (published).
The design papers live at
`https://guerrilla.barkpark.cloud/papers/hyperquiz-{vision,architecture,realtime-protocol,scaling,content-model,decisions,risks}`.
This file is the short human map; the papers and the epic are the source of
truth. (The 7 papers were **reconstructed 2026-07-10** from the charter + the
recovered engine branch after the localhost:4000 originals became unreachable —
grounded in the built code, not byte-copies of the lost bodies.)

## Status

Wave 1 (2026-07-10) ported the engine onto main as `Barkpark.Plugins.Quiz` —
**99 tests green** (`mix test $(git ls-files 'test' | grep -i quiz)`). The
source branch `hyperquiz-p1-recovered` (28 commits, +2,952 lines / 35 files)
remains as evidence-of-work only. Still open: theme re-skin (Decision E) and
the live browser verification on guerrilla.

## Architecture — land as a `Barkpark.Plugin` (Decision D)

The branch hardwires three core files (`application.ex` / `endpoint.ex` /
`router.ex`) — the plugins-off-doctrine violation. The plugin form dissolves it:

- `register_workers/1` absorbs the supervision children (pulse.ex:75 precedent).
- `register_routes/1` with the `:public_root` bucket absorbs `/quiz/host|play/:pin`
  (bulldocs.ex:116-130 precedent; router auto-injects at router.ex:883).
- `register_schemas/1` registers the quiz schema on every boot via
  `Plugins.Bootstrap` — replacing the branch's dead
  `Quiz.Content.register_schema/1` (never called).
- **The one irreducible core edit** is the `socket "/quiz"` line in
  `endpoint.ex`: Phoenix `socket/3` is a compile-time macro with no plugin
  callback. Pulse hand-adds its socket the same way — the accepted bar, not a
  violation. A disabled quiz plugin still exposes a dormant `/quiz` socket path;
  harmless with no reachable channel.

Keep the `Barkpark.Quiz.*` namespace fronted by `Barkpark.Plugins.Quiz`
(pulse precedent). Colors come from `derive(theme)` — re-skin
`quiz.html.heex` onto `PortableDoc.Render.Stylesheet.css()` (Decision E).

## Go-live path

The quiz diff is all `api/**`, so **merge = live**: it triggers guerrilla's
blue/green auto-deploy. Zero migrations, zero new env vars, zero Caddy work
(the blanket `reverse_proxy` carries websockets).

**The one footgun — `check_origin` (Past-Mistake-11):** the demo must reach
guerrilla via its `PHX_HOST` domain (`guerrilla.barkpark.cloud`) or a
`BARKPARK_EXTRA_ORIGINS` entry, else `/quiz/websocket` **403s silently** — the
LiveView drops and the surface goes click-dead with no error.

## Parked (do not build)

- **`hq-p7-billing`** — pricing is a human/business decision. Unpark only by
  human direction.
- **`hq-p7-shard`** — multi-node sharding. Unpark only if a *measured* load
  ceiling on guerrilla demands it; Decision B holds that a single node covers
  the ~2,000/room target (individual cursors below `@heatmap_threshold 300`, an
  O(1) 32x32 heatmap above it).
