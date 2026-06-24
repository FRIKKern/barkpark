defmodule BarkparkWeb.StudioComponents.EditorFields do
  @moduledoc """
  Studio editor-pane **secondary chrome** — the bulk-publish floating
  action bar, the read-only secondary editor card and its picker modal,
  and the presence-nav overlay. Split out of
  `BarkparkWeb.StudioComponents.Editor` (which keeps the editor shell,
  header, field renderer, and doc-action buttons) so neither half is a
  god-module; re-exported through the `BarkparkWeb.StudioComponents`
  facade via `defdelegate` so every call site keeps working unchanged.

  These four components are self-contained: none call back into `Editor`
  and `Editor` never calls them, so the boundary is a clean cut. The
  block needs no editor-specific imports — only `Barkpark.Content`
  (fully qualified) plus `Enum`/`String`/`Map`/`MapSet` built-ins.
  """
  use Phoenix.Component

  # ── Document actions chrome (Task barkpark-3yq) ───────────────────────────
  # Three small components for the Sanity-style document actions: bulk
  # publish floating action bar, read-only secondary editor card, and the
  # secondary-doc picker modal. Kept here next to the other Studio chrome.

  @doc """
  Floating action bar shown at the bottom of the viewport when one or
  more documents are checkbox-selected on the active list pane. Hidden
  entirely when the set is empty so the bar never crowds normal browsing.

  Buttons emit `phx-click="bulk-publish"` / `"bulk-unpublish"` /
  `"bulk-clear"` against the parent LV. The "Selected" count comes from
  `MapSet.size(@selected_doc_ids)`.
  """
  attr :selected_doc_ids, :any, required: true

  def bulk_action_bar(assigns) do
    count = MapSet.size(assigns.selected_doc_ids)
    assigns = assign(assigns, :count, count)

    ~H"""
    <%= if @count > 0 do %>
      <div class="bp-bulk-action-bar" role="region" aria-label="Bulk actions" data-test-id="bulk-action-bar">
        <span class="bp-bulk-action-count">
          <%= @count %> selected
        </span>
        <div class="bp-bulk-action-buttons">
          <button
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="bulk-publish"
            data-test-id="bulk-publish"
          >Publish selected</button>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="bulk-unpublish"
            data-test-id="bulk-unpublish"
          >Unpublish selected</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="bulk-clear"
            data-test-id="bulk-clear"
          >Clear</button>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Read-only secondary editor card — the "Open in new pane" target. Shows
  the secondary doc's title, type, status pill, and a flat key-value
  table of its content fields. v1 is deliberately read-only so primary
  autosave never collides with a secondary edit (decision in task brief).
  The Close button reveals the floating "Open another" button again via
  the `close-secondary` event.
  """
  attr :secondary_doc, :map, default: nil
  attr :secondary_schema, :map, default: nil
  attr :secondary_type, :string, default: nil

  def secondary_editor_card(assigns) do
    ~H"""
    <%= if @secondary_doc do %>
      <aside class="bp-secondary-pane" data-test-id="secondary-pane">
        <header class="bp-secondary-pane-header">
          <div class="bp-secondary-pane-title">
            <span class="badge badge-draft" :if={Barkpark.Content.draft?(@secondary_doc.doc_id)}>
              draft
            </span>
            <span class="badge" :if={!Barkpark.Content.draft?(@secondary_doc.doc_id)}>
              <%= @secondary_doc.status %>
            </span>
            <span class="bp-secondary-pane-type"><%= @secondary_type %></span>
            <strong><%= @secondary_doc.title || "Untitled" %></strong>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="close-secondary"
            data-test-id="close-secondary"
            aria-label="Close secondary pane"
          >×</button>
        </header>
        <div class="bp-secondary-pane-body">
          <dl class="bp-secondary-pane-fields">
            <%= for field <- secondary_visible_fields(@secondary_schema) do %>
              <% key = field["name"] %>
              <dt><%= field["title"] || key %></dt>
              <dd><%= secondary_format_value(get_in(@secondary_doc.content || %{}, [key])) %></dd>
            <% end %>
          </dl>
          <p class="bp-secondary-pane-readonly">Read-only — edit via primary pane.</p>
        </div>
      </aside>
    <% end %>
    """
  end

  defp secondary_visible_fields(nil), do: []

  defp secondary_visible_fields(%{fields: fields}) when is_list(fields) do
    Enum.reject(fields, &(&1["name"] in ["title", "status"]))
  end

  defp secondary_visible_fields(_), do: []

  defp secondary_format_value(nil), do: "—"
  defp secondary_format_value(""), do: "—"
  defp secondary_format_value(v) when is_binary(v), do: v
  defp secondary_format_value(v) when is_boolean(v), do: to_string(v)
  defp secondary_format_value(v) when is_number(v), do: to_string(v)
  defp secondary_format_value(v), do: inspect(v, limit: 50)

  @doc """
  Secondary-doc picker modal — reuses the reference-picker visual
  treatment so users get a familiar interaction. Filter is client-side
  string-contains against the candidates list bound on `open-secondary-picker`.
  Selecting a row fires `select-secondary`; clicking the backdrop or the
  ✕ fires `close-secondary-picker`.
  """
  attr :show_secondary_picker, :boolean, default: false
  attr :secondary_search, :string, default: ""
  attr :secondary_candidates, :list, default: []

  def secondary_picker_modal(assigns) do
    filtered =
      if assigns.secondary_search == "" do
        assigns.secondary_candidates
      else
        q = String.downcase(assigns.secondary_search)

        Enum.filter(assigns.secondary_candidates, fn c ->
          String.contains?(String.downcase(c.title || ""), q) or
            String.contains?(String.downcase(c.id || ""), q)
        end)
      end

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <%= if @show_secondary_picker do %>
      <div class="modal-backdrop" phx-click="close-secondary-picker" data-test-id="secondary-picker-modal">
        <div class="modal-card" phx-click-away="close-secondary-picker" onclick="event.stopPropagation()">
          <div class="modal-header">
            <h3>Open in new pane</h3>
            <button class="btn btn-ghost btn-sm" phx-click="close-secondary-picker" aria-label="Close">×</button>
          </div>
          <div class="modal-body">
            <input
              type="text"
              class="form-input"
              placeholder="Search documents…"
              value={@secondary_search}
              phx-keyup="secondary-search"
              phx-debounce="150"
              autofocus
            />
            <ul class="bp-secondary-candidates">
              <%= for c <- @filtered do %>
                <li
                  class="bp-secondary-candidate"
                  phx-click="select-secondary"
                  phx-value-id={c.id}
                  data-test-id={"secondary-candidate-#{c.id}"}
                >
                  <strong><%= c.title %></strong>
                  <span class="bp-secondary-candidate-id"><%= c.id %></span>
                </li>
              <% end %>
              <%= if @filtered == [] do %>
                <li class="bp-secondary-empty">No matches.</li>
              <% end %>
            </ul>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Presence-nav overlay (top-right) extracted from `studio_live.ex:947-984`.
  Renders one avatar+tooltip per other user plus the self pill. The
  outer wrapper preserves the LV hook contract:

      <div class="presence-nav" id="presence-hook" phx-hook="PresenceIdentity">

  Both `id="presence-hook"` AND `phx-hook="PresenceIdentity"` are
  load-bearing — the localStorage-sync mechanism declared in
  `root.html.heex` listens on this element. Do NOT change either.

  Events bubble to the parent LV: `jump-to-user`, `show-profile`.
  Helpers `truncate_text/2` and `resolve_presence_doc_title/2` migrate
  from StudioLive into module-private of this component.
  """
  attr :user_id, :string, required: true
  attr :user_name, :string, required: true
  attr :user_color, :string, required: true
  attr :presences, :list, default: []
  attr :editor_doc, :map, default: nil
  attr :dataset, :string, required: true
  attr :current_workspace, :map, default: nil
  attr :current_project, :map, default: nil

  def presence_nav(assigns) do
    ~H"""
    <div class="presence-nav" id="presence-hook" phx-hook="PresenceIdentity">
      <% scope_opts = build_scope_opts(@current_workspace, @current_project) %>
      <% others = Enum.reject(@presences, & &1.user_id == @user_id) %>
      <%= for p <- others do %>
        <% p_doc_title = resolve_presence_doc_title(p, @dataset, scope_opts) %>
        <%= if p.doc_id && p.type do %>
          <div class="presence-user-wrap"
               phx-click="jump-to-user" phx-value-type={p.type} phx-value-doc-id={p.doc_id}>
            <div class="presence-avatar clickable" style={"background: #{p.color}"}>
              <%= String.first(Map.get(p, :name, "U")) %>
            </div>
            <div class="presence-tooltip">
              <div class="presence-tooltip-name"><%= Map.get(p, :name, "User") %></div>
              <div class="presence-tooltip-location">editing <strong><%= truncate_text(p_doc_title, 24) %></strong></div>
              <div class="presence-tooltip-hint">Click to jump there</div>
            </div>
          </div>
        <% else %>
          <div class="presence-user-wrap">
            <div class="presence-avatar" style={"background: #{p.color}"}>
              <%= String.first(Map.get(p, :name, "U")) %>
            </div>
            <div class="presence-tooltip">
              <div class="presence-tooltip-name"><%= Map.get(p, :name, "User") %></div>
              <div class="presence-tooltip-location">browsing</div>
            </div>
          </div>
        <% end %>
      <% end %>
      <div class="presence-me-group" phx-click="show-profile" title={"#{@user_name} — profile"}>
        <div class="presence-me-info">
          <span class="presence-me-name"><%= @user_name %></span>
          <span class="presence-me-location"><%= truncate_text(if(@editor_doc, do: @editor_doc.title || "Untitled", else: "browsing"), 24) %></span>
        </div>
        <div class="presence-me" style={"background: #{@user_color}"}>
          <%= String.first(@user_name) %>
        </div>
      </div>
    </div>
    """
  end

  defp truncate_text(nil, _max), do: ""
  defp truncate_text(text, max) when byte_size(text) <= max, do: text
  defp truncate_text(text, max), do: String.slice(text, 0, max - 1) <> "..."

  # Build scope opts from the workspace/project assigns the parent LV holds.
  # Mirrors `BarkparkWeb.ScopeHelpers.scope_opts(%Socket{})` for the Socket
  # variant — no `memoize: true` (LV processes are long-lived; see sknf).
  # Nil-safe: an absent workspace or project drops its key entirely.
  defp build_scope_opts(workspace, project) do
    []
    |> put_scope_key(:workspace_id, workspace)
    |> put_scope_key(:project_id, project)
  end

  defp put_scope_key(opts, _key, nil), do: opts
  defp put_scope_key(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope_key(opts, _key, _other), do: opts

  defp resolve_presence_doc_title(presence, dataset, scope_opts) do
    type = presence.type
    doc_id = presence.doc_id

    if type && doc_id do
      case Barkpark.Content.get_document(doc_id, type, dataset, scope_opts) do
        {:ok, doc} ->
          doc.title || doc_id

        _ ->
          case Barkpark.Content.get_document("drafts.#{doc_id}", type, dataset, scope_opts) do
            {:ok, doc} -> doc.title || doc_id
            _ -> doc_id
          end
      end
    else
      "browsing"
    end
  end

end
