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

  @aggregator :barkpark_metrics

  def scrape(conn, _params) do
    metrics = TelemetryMetricsPrometheus.Core.scrape(@aggregator)
    # Tells the pruner the endpoint is in use, so it leaves the samples between
    # this scrape and the next one alone.
    BarkparkWeb.Telemetry.DistributionPruner.note_scrape()

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, metrics)
  end
end
