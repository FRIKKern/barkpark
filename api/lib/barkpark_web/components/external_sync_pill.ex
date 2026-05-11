defmodule BarkparkWeb.Components.ExternalSyncPill do
  @moduledoc """
  Plugin-agnostic status pill for any external sync integration registered in
  `Barkpark.ExternalSync`.

  The component is a thin renderer — it owns no state. The parent LiveView is
  expected to subscribe to `Barkpark.ExternalSync.topic(system, doc_id)`,
  pattern-match on `{:external_sync_status, %{state: state}}`, and re-assign
  the `:state` attribute on each broadcast. The pill itself never holds a
  process.

  ## Visual contract

  Renders a `<span class="badge bp-pill bp-pill-<color>">` carrying:

    * `data-test-id="external-sync-pill-<system>"` — stable test hook
    * `data-bp-system` — raw system name
    * `data-bp-state`  — the current state string (or empty for `nil`)
    * a `title` attribute when a `tooltip` is supplied

  Color classes (`bp-pill-gray | -blue | -green | -red | -orange`) mirror
  the existing badge palette so it slots into the Studio toolbar without
  CSS additions. The system label is rendered with a muted prefix
  (`<span class="muted">…:</span>`) so the eye can find the state quickly.

  ## Hiding the pill

  When `:hide_when_unsynced` is `true`, the pill is omitted entirely if
  the state is `nil`. The default is `false` — the "Not synced" placeholder
  is shown — because the consumer (a per-document toolbar) typically wants
  the user to know which external systems exist even before they've been
  triggered.
  """

  use Phoenix.Component

  alias Barkpark.ExternalSync

  @doc """
  Render the pill.

  Attrs:

    * `:system` — required string (the registry key, e.g. `"bokbasen"`)
    * `:state` — the current state string/atom/nil from the most recent
      `{:external_sync_status, …}` broadcast or persisted status read
    * `:tooltip` — optional `title` attribute; suppressed when nil/empty
    * `:hide_when_unsynced` — when true, returns an empty fragment if
      `state` is nil
  """
  attr :system, :string, required: true
  attr :state, :any, default: nil
  attr :tooltip, :string, default: nil
  attr :hide_when_unsynced, :boolean, default: false

  def external_sync_pill(assigns) do
    system_label = ExternalSync.system_label(assigns.system)
    state_meta = ExternalSync.state_meta(assigns.system, assigns.state)
    state_str = state_to_string(assigns.state)

    assigns =
      assigns
      |> assign(:system_label, system_label)
      |> assign(:state_meta, state_meta)
      |> assign(:state_str, state_str)

    ~H"""
    <%= if @hide_when_unsynced and is_nil(@state) do %>
    <% else %>
      <span
        class={"badge bp-pill bp-pill-" <> @state_meta.color}
        data-test-id={"external-sync-pill-" <> @system}
        data-bp-system={@system}
        data-bp-state={@state_str}
        title={@tooltip || ""}
      ><span class="muted"><%= @system_label %>:</span> <%= @state_meta.label %></span>
    <% end %>
    """
  end

  defp state_to_string(nil), do: ""
  defp state_to_string(state) when is_binary(state), do: state
  defp state_to_string(state) when is_atom(state), do: Atom.to_string(state)
  defp state_to_string(_), do: ""
end
