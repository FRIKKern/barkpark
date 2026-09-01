defmodule BarkparkWeb.MetricsController do
  @moduledoc """
  Prometheus scrape surface for the instance's telemetry aggregates.

  `BarkparkWeb.Telemetry` starts a `TelemetryMetricsPrometheus.Core` aggregator
  (name `:barkpark_metrics`) that folds the events in
  `BarkparkWeb.Telemetry.prometheus_metrics/0` into ETS. This controller renders
  that state in the Prometheus text exposition format so a Prometheus/agent
  scraper can answer the production questions the reporter exists for: p95 Ecto
  query time, which route is slow, and whether VM memory is climbing.

  ## Auth — `[:api, :require_admin]`, and NOT "cited safe" (task-d7ac954aa57aa522)

  The route is deliberately NOT the conventional public `/metrics`; it lives
  under `/v1/instance/*`. Until task-d7ac954aa57aa522 it rode
  `[:api, :require_token]`, the same seam as `RequestStatsController`, on the
  stated intent "instance-operational data is never anonymous". That sentence
  is what the mount implemented, and it is weaker than what this payload needs:
  `:require_token` is `RequireToken` + `PublicRead` (which denies only the
  `public-read` tier) + `RequireWriteForMutation` (method-gated, so a GET passes
  untouched), so ANY read/write/admin token from ANY workspace scraped this —
  a disposable 48h playground visitor token included.

  The verdict is recorded here so the next census does not re-derive it: this
  route is **NOT** cited-safe, and the CITED SAFE argument that covers
  `request-stats` does not transfer. That argument turns on the payload
  carrying no path, no identifier and no tenant row — true of `RequestStats`
  (a five-class route enum plus rates), false here. `scrape/2` itself is
  tenant-blind (no `scope_opts`, no `workspace_id`), but the tenancy is in the
  Prometheus LABEL SET, not the request path:

    * `:workspace_id` tags FOUR series in
      `BarkparkWeb.Telemetry.prometheus_metrics/0` —
      `barkpark.content.mutate.stop.duration`,
      `barkpark.search.query.stop.duration`,
      `barkpark.content.lifecycle.stop.duration` and
      `barkpark.media.mutate.count`. One scrape therefore enumerates the box's
      workspace-id roster AND each tenant's write, search, publish and media
      volume and latency. Unscoped work carries a `"global"` sentinel; scoped
      work carries the real id.
    * `:dataset` tags `barkpark.authoring.wall_rejection.count` and
      `barkpark.authoring.findability_miss.count`.
    * `:module` on `barkpark.hooks.hook.stop.duration` enumerates which plugins
      this instance actually runs; `:route` and `:view`/`:component` enumerate
      which routes and LiveViews other tenants exercise.

  So the disclosure here is BROADER than the `in_flight_slugs` list that moved
  its neighbour `GET /v1/instance/site-deploy` to the same pipeline: slugs name
  the sites building right now, these labels name every workspace that has
  written, searched or published since the aggregator started. The real caller
  is unaffected — the on-box agent's health gate already curls this with the
  instance admin token.
  """
  use BarkparkWeb, :controller

  def scrape(conn, _params) do
    # Core's distribution fold is a read-modify-write over ETS, not a serialized
    # GenServer call. Route every scrape through the pruner so an idle timer and
    # an external Prometheus request cannot overwrite one another's aggregate.
    metrics = BarkparkWeb.Telemetry.DistributionPruner.scrape()

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, metrics)
  end
end
