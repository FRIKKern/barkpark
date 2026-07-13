defmodule BarkparkWeb.ServerVitalsLive do
  @moduledoc """
  Live host-vitals readout embedded in the Studio bottom bar.

  A small nested (`sticky: true`) LiveView rendered by `studio_footer/1` beside
  the build-version span. It subscribes once to the shared `"server_vitals"`
  topic and re-renders on each broadcast — the single `Barkpark.HostVitals.Sampler`
  is the one clock, so there is no per-socket timer here.

  Seeds from `Sampler.snapshot/0` (`:persistent_term`, free) so the bar is
  populated on first paint. Any `nil` metric renders as `—` (honest-meters law);
  memory/disk crossing 90% tint the value with the danger accent.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.HostVitals.Sampler

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: BarkparkWeb.Endpoint.subscribe(Sampler.topic())
    {:ok, assign(socket, :vitals, Sampler.snapshot()), layout: false}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "tick", payload: snap}, socket) do
    {:noreply, assign(socket, :vitals, snap)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: line(assigns)

  @doc """
  The host-vitals readout markup. Shared by the live `render/1` and the
  dead-view static path in `studio.html.heex`, so both render identically.
  Takes a `:vitals` snapshot map (the `Sampler.snapshot/0` shape).
  """
  attr :vitals, :map, required: true

  def line(assigns) do
    ~H"""
    <span id="server-vitals-line" style="color: var(--fg-dim);">
      · CPU <span style={pct_style(@vitals.cpu_pct, 90)}><%= fmt_pct(@vitals.cpu_pct) %></span>
      · RAM <span style={pct_style(@vitals.mem_pct, 90)}><%= fmt_ram(@vitals) %></span>
      · disk <span style={pct_style(@vitals.disk_pct, 90)}><%= fmt_pct(@vitals.disk_pct) %></span>
      · load <%= fmt_load(@vitals.load1) %>
      · up <%= fmt_uptime(@vitals.host_uptime_s) %>
    </span>
    """
  end

  # ── formatting (nil → "—", never a fabricated number) ──────────────────────

  defp fmt_pct(nil), do: "—"
  defp fmt_pct(v) when is_number(v), do: "#{round(v)}%"

  defp fmt_load(nil), do: "—"
  defp fmt_load(v) when is_number(v), do: :erlang.float_to_binary(v / 1, decimals: 2)

  defp fmt_ram(%{mem_used_mb: used, mem_total_mb: total})
       when is_number(used) and is_number(total) do
    "#{gb(used)}/#{gb(total)} GB"
  end

  defp fmt_ram(_), do: "—"

  defp gb(mb), do: :erlang.float_to_binary(mb / 1024, decimals: 1)

  defp fmt_uptime(nil), do: "—"

  defp fmt_uptime(secs) when is_integer(secs) do
    days = div(secs, 86_400)
    hours = div(rem(secs, 86_400), 3_600)
    mins = div(rem(secs, 3_600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{mins}m"
      true -> "#{mins}m"
    end
  end

  # Tint the value with the danger accent once it crosses `threshold` percent.
  # var(--danger) only (the Studio theme defines it) — the literal-color gate
  # (scripts/studio-literal-check.sh) forbids hardcoded hex in Studio chrome.
  defp pct_style(v, threshold) when is_number(v) and v >= threshold,
    do: "color: var(--danger);"

  defp pct_style(_v, _threshold), do: nil
end
