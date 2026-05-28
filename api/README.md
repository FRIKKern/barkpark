# Barkpark — Phoenix API

The Elixir/Phoenix backend for Barkpark — all CRUD, real-time, and the LiveView Studio. Runs on `:4000` in dev; the dev auth token is `barkpark-dev-token` (`Authorization: Bearer barkpark-dev-token`). See the guides:

- [`../docs/SETUP.md`](../docs/SETUP.md) — standalone setup (deps, DB, running locally)
- [`../docs/SETUP-WITH-PAPERFLOW.md`](../docs/SETUP-WITH-PAPERFLOW.md) — paperflow integration
- [`CLAUDE.md`](CLAUDE.md) — architecture, key files, conventions

Quick start: `mix deps.get && mix ecto.setup && mix phx.server`, then open [`localhost:4000/studio`](http://localhost:4000/studio).
