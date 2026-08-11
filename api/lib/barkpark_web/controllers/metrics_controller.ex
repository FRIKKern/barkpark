defmodule BarkparkWeb.MetricsController do
  @moduledoc """
  Prometheus scrape surface for the instance's telemetry aggregates.

  `BarkparkWeb.Telemetry` starts a `TelemetryMetricsPrometheus.Core` aggregator
  (name `:barkpark_metrics`) that folds the events in
  `BarkparkWeb.Telemetry.prometheus_metrics/0` into ETS. This controller renders
  that state in the Prometheus text exposition format so a Prometheus/agent
  scraper can answer the production questions the reporter exists for: p95 Ecto
  query time, which route is slow, and whether VM memory is climbing.

  Auth: rides the SAME `[:api, :require_token]` Bearer seam as
  `RequestStatsController` — instance-operational data is never anonymous. The
  route is deliberately NOT the conventional public `/metrics`; it lives under
  the token-gated `/v1/instance/*` namespace next to `request-stats`.
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
