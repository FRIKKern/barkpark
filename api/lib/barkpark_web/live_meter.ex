defmodule BarkparkWeb.LiveMeter do
  @moduledoc """
  Gate B of anonymous metering (charter D4, am-w2-s6): the /live socket's
  half of the `:browser` class.

  Websockets bypass every plug, so `Plugs.RateLimit`'s `:browser` class meters
  a public reader's dead render and then never sees it again: the connected
  mount and every `phx-*` event ride the socket. This hook debits the same
  per-IP budget for both.

  It is attached in two places, both router-side:

    * every `:public_root` LiveView, by `BarkparkWeb.Router.Plugins` at the
      live_session it emits per route (papers, sheets, quiz);
    * FinderLive's `:finder` live_session in `router.ex`.

  THE SHADOW LAW (charter D2): this hook NEVER refuses. Past the budget it
  logs one line and emits `would_429` on the same telemetry event the plug
  uses, with `surface: :live` beside `class: :browser` (a dimension, never a
  new class, D9), and returns `{:cont, socket}`. `:browser_enforce` does not
  reach it: a LiveView cannot answer 429, so an enforcing socket gate needs
  its own refusal shape and its own decision.

  The address is the canonical trust walk: `SpawnBudget.principal/1` hands
  the socket's `:peer_data` + `:x_headers` to `RateLimiter.client_ip/1`
  (pinned by #21250). A socket with no peer data shares one `:fallback`
  bucket, labelled as such.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2, attach_hook: 4]

  require Logger

  alias Barkpark.Quiz.SpawnBudget
  alias Barkpark.RateLimiter
  alias BarkparkWeb.Plugs.RateLimit

  def on_mount(:public, _params, _session, socket) do
    if connected?(socket) do
      info = %{
        peer_data: get_connect_info(socket, :peer_data),
        x_headers: get_connect_info(socket, :x_headers) || []
      }

      meter = {info, key(info)}
      debit(meter, :mount)

      {:cont,
       attach_hook(socket, :live_meter, :handle_event, fn _event, _params, socket ->
         debit(meter, :event)
         {:cont, socket}
       end)}
    else
      # The dead render already passed the `:browser` plug; counting it here
      # would bill one page load twice.
      {:cont, socket}
    end
  end

  # One bucket per resolved address, distinct from the plug's
  # `ip:<ip>:browser:<dataset>` keys so the two surfaces are measured apart.
  defp key(info) do
    case SpawnBudget.principal(info) do
      {:client_ip, ip} -> "ip:#{ip}:browser:live"
      :fallback -> "fallback:browser:live"
    end
  end

  # `what` is :mount or :event, never the event NAME: that string is chosen by
  # the client and has no place in a log line.
  defp debit({info, key}, what) do
    with {per_minute, opts} <- RateLimit.browser_budget(),
         :rate_limited <- RateLimiter.check(RateLimiter.scoped_key(info, key), opts) do
      Logger.warning(
        "rate_limit shadow would_429 class=browser surface=live key=#{key} " <>
          "per_minute=#{per_minute} on=#{what}"
      )

      :telemetry.execute(
        RateLimit.shadow_event(),
        %{would_429: 1},
        %{class: :browser, surface: :live, key: key, per_minute: per_minute, on: what}
      )
    end

    :ok
  end
end
