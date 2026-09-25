<!-- doc-tier: human | canonical-for: mutate-load-harness | budget: 900tok -->
# barkpark-mutate-load

Drives N concurrent task create+publish rounds over
`POST /w/<ws>/p/<proj>/v1/data/mutate/<dataset>` — the two requests
`bp task create --publish` sends — and prints per-leg p50/p95/p99/max and
error classes: `ok`, `http_<status>:<error.code>` (`-` when the body is not
the error envelope), `transport:<timeout|refused|eof|reset|other>`, `no_id`.
`transport_resends` counts silent resends by Go's transport (it resends a
request carrying `Idempotency-Key` when a reused connection dies; bp does too).

Exit: `0` every round landed, `1` any leg failed, `2` usage error or REFUSED
target.

## Safety

It writes real task rows. A target whose host is not literally loopback
(`localhost`, `127.0.0.0/8`, `::1`) is refused before any request is built;
names are not resolved. `--i-own-this-target` overrides — only for a box you
alone own. Never point it at a shared or production instance.

## Run

```bash
go build -o /tmp/mload ./cmd/barkpark-mutate-load
# local API: cd api && BARKPARK_DEV_DATABASE=<your_db> mix ecto.setup && \
#            BARKPARK_DEV_DATABASE=<your_db> PORT=4817 mix phx.server
/tmp/mload --server http://localhost:4817 --token barkpark-dev-token \
  --rounds 100 --concurrency 25 --desc-bytes 3400
```

- `--desc-bytes 3400` is the 2026-07-31 calibration datum (creates 500'd on
  the publish dedup scan).
- `--dedup-bypass` seeds a backlog fast; drop it when measuring.
- `--tag` (default `loadtest`) is created and published first
  (`--ensure-tag`), because the publish wall needs a registered weighted tag.
- `--json` prints the report as JSON; `--label` tags it with the commit.

Before you measure a dev server: dev's defaults distort the result. The write
rate limit is 60/min per token (`config/config.exs`; the env override in
`runtime.exs` applies under `:prod` only), and `code_reloader: true` puts
`Phoenix.CodeReloader` and `CheckRepoStatus` in front of every request. For a
measurement, override locally (never commit) in `api/config/dev.exs`:

```elixir
config :barkpark, :rate_limits, read_per_minute: 1_000_000, write_per_minute: 1_000_000
config :barkpark, BarkparkWeb.Endpoint, code_reloader: false, debug_errors: false
config :logger, level: :info
```

and wait for the Oban backlog to drain after seeding (`oban_jobs` rows in
`available`/`executing`) so that queued background jobs do not skew the first
measurement.

Tests: `go test ./cmd/barkpark-mutate-load/` (fake server returning 500/409/
HTML 500/no-id/hang-ups; refusal of non-loopback targets with zero requests).
