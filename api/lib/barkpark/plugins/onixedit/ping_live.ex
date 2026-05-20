defmodule Barkpark.Plugins.OnixEdit.PingLive do
  @moduledoc """
  Pilot route for the plugin-route highway (Goal `barkpark-G2`, task s4).

  Proves end-to-end that plugin-contributed routes mount through the host
  router's `plugin_routes/1` macro. Returns a tiny HTML page confirming the
  pipe is alive. Not a real admin UI — `bokbasen_live`,
  `onixedit_staleness_live`, and friends move to the plugin namespace in G3.

  Mounted at `/studio/onixedit/ping` via OnixEdit's `register_routes/1`
  callback. Admin-only by default (Q3 locked grill decision — the pilot
  inherits admin-only gating via the macro's `:plugin_admin` scope).
  """

  use BarkparkWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :body, "OnixEdit plugin route alive.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container">
      <h1>OnixEdit · Plugin Route Highway</h1>
      <p data-role="ping-payload"><%= @body %></p>
      <p>
        <small>
          This page proves Barkpark's <code>plugin_routes/1</code> macro emitted
          the route declared by OnixEdit's <code>register_routes/1</code> callback.
        </small>
      </p>
    </main>
    """
  end
end
