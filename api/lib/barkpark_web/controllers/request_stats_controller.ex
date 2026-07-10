defmodule BarkparkWeb.RequestStatsController do
  @moduledoc """
  Exposes the instance's rolling request throughput + latency window over one
  authed GET route, so the on-box agent (sibling slice
  `cloud-console-w5-agent-reqstats-beat`) can fold machine req/s + p95 into its
  beat without ssh.

  The route rides the `[:api, :require_token]` pipeline — the SAME Bearer-token
  seam the agent's health gate already probes (it curls the instance API with
  `Authorization: Bearer <admin token>`; `RequireToken` verifies it). It is never
  unauthenticated: a raw request-rate/latency read is instance-operational data,
  not public.

  Contract (pinned by charter OC24): `200 {"req_per_s": float, "p95_ms": int|null,
  "window_s": int}`. `p95_ms` is `null` — never a fabricated `0` — when the
  window holds no samples.
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.RequestStats

  def show(conn, _params) do
    json(conn, RequestStats.stats())
  end
end
