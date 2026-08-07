defmodule BarkparkWeb.RequestStatsController do
  @moduledoc """
  Exposes the instance's rolling request throughput, latency and 5xx window over
  one authed GET route, so the on-box agent (sibling slice
  `cloud-console-w5-agent-reqstats-beat`) can fold machine req/s, p95 and error
  rate into its beat without ssh.

  The route rides the `[:api, :require_token]` pipeline — the SAME Bearer-token
  seam the agent's health gate already probes (it curls the instance API with
  `Authorization: Bearer <admin token>`; `RequireToken` verifies it). It is never
  unauthenticated: a raw request-rate/latency read is instance-operational data,
  not public.

  Wire contract — FOUR keys: `200 {"req_per_s": float, "p95_ms": int|null,
  "err_5xx_per_s": float|null, "window_s": int}`. The shape is owned by
  `BarkparkWeb.RequestStats` (this controller only serialises what `stats/1`
  returns) and pinned on the wire by
  `BarkparkWeb.RequestStatsControllerTest`. `p95_ms` and `err_5xx_per_s` are
  `null` — never a fabricated `0` — when the window holds no samples: zero
  samples is not "0ms" and it is not "no errors".
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.RequestStats

  def show(conn, _params) do
    json(conn, RequestStats.stats())
  end
end
