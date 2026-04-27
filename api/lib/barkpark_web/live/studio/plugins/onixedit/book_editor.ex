defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor do
  @moduledoc """
  Phase 5 WI1 — OnixEdit `book` editor LiveView shell + 8-tab framework.

  This module is the **shell only** — it owns layout, document state, the tab
  nav strip, and the `?tab=` URL contract. It does NOT implement any tab body.
  WI3 (Subjects, Contributors) and WI4 (Identity, Title, Publishing, Supply,
  Marketing, Related) drop their components into the seam below.

  ## Module namespace

  Lives at `BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor`, matching the
  `BarkparkWeb.Studio.*` convention used by every other LiveView under
  `api/lib/barkpark_web/live/studio/` (StudioLive, MediaLive, SettingsLive,
  DocumentEditLive, Plugins.Adapter, …). The Phase 4 WI4 commit (726cf76)
  documented this convention and chose it over the brief's nominal
  `BarkparkWeb.Live.Studio.*` for Phoenix endpoint coherence; we follow the
  same precedent.

  ## Route

      live "/onixedit/book/:doc_id", Plugins.OnixEdit.BookEditor

  Mounted under the existing `/studio/:dataset` scope, so `@dataset` is
  available in `params`. Auth follows the same convention as `StudioLive`
  (no extra `on_mount` — Studio is open per existing decision).

  ## Tabs

  Eight tabs, in this order, with URL slugs in parentheses:

      Identity (identity) | Title (title) | Contributors (contributors)
      Subjects (subjects) | Publishing (publishing) | Supply (supply)
      Marketing (marketing) | Related (related)

  `handle_params/3` reads `?tab=<slug>` and assigns `@active_tab` as an atom.
  Default when none given: `:identity`. Unknown slug falls back to default and
  flashes a warning. Tab nav uses `<.link patch={~p"…?tab=…"}>` so URL state
  survives without a full LiveView re-mount.

  ## Seam contract for WI3 / WI4

  The shell renders each tab body via `render_tab/2`, a private dispatch on
  the `@active_tab` atom. Each clause currently emits a placeholder
  paragraph. WI3 and WI4 replace clauses by swapping the placeholder for a
  function-component or `<.live_component>` call. The contract WI3/WI4 must
  honor:

    * **Render shape** — function component (`<.identity_tab assigns={…} />`)
      or LiveComponent (`<.live_component module={…} id={…} … />`). Either
      works; the seam is just "swap the placeholder block".

    * **Assigns available in `render_tab/2`** —
      `:doc` (the `%Document{}` or `nil` for new),
      `:schema` (the `%SchemaDefinition{}` for `book`),
      `:form` (current form-data map, string-keyed),
      `:dataset`,
      `:doc_id`,
      `:active_tab`,
      `:save_status`.

    * **Save / change events** — child components emit a phx-change/phx-submit
      event named `"autosave"` (matching Studio's existing convention) with
      params shaped `%{"doc" => %{<field> => <value>, …}}`. The shell handles
      it via `handle_event/3` and patches `@form`.

    * **No new auth surface** — D7 and D12 hold; no `Code.eval_*`, no TUI
      changes. v1 schemas are untouched (they never reach this module —
      StudioLive routes them through its existing `render_input/2`).

  ## Phase 4 v2 adapter handshake

  The Phase 4 v2 field adapter (`BarkparkWeb.Studio.Plugins.Adapter`) renders
  individual v2 fields inline. WI3/WI4 will call into that adapter (and into
  `BarkparkWeb.Studio.Plugins.FieldComponents`) to draw the actual editor
  primitives for composites, arrayOf, codelist, and localizedText. The shell
  passes `:schema`, `:form`, `:doc` so each tab can run the adapter on the
  subset of `schema.fields` it owns.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.ThemaTreePicker

  @type tab ::
          :identity
          | :title
          | :contributors
          | :subjects
          | :publishing
          | :supply
          | :marketing
          | :related

  @tabs [
    {:identity, "Identity"},
    {:title, "Title"},
    {:contributors, "Contributors"},
    {:subjects, "Subjects"},
    {:publishing, "Publishing"},
    {:supply, "Supply"},
    {:marketing, "Marketing"},
    {:related, "Related"}
  ]

  @tab_keys Enum.map(@tabs, &elem(&1, 0))
  @tab_slug_to_atom Map.new(@tabs, fn {atom, _} -> {Atom.to_string(atom), atom} end)
  @default_tab :identity
  @schema_name "book"

  @doc "Returns the ordered tab list as `[{atom, label}, …]`."
  def tabs, do: @tabs

  @doc "Returns just the tab atoms in display order."
  def tab_keys, do: @tab_keys

  @impl true
  def mount(%{"dataset" => dataset, "doc_id" => doc_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
    end

    pub_id = Content.published_id(doc_id)

    schema =
      case Content.get_schema(@schema_name, dataset) do
        {:ok, s} -> s
        _ -> nil
      end

    socket =
      socket
      |> assign(
        dataset: dataset,
        doc_id: pub_id,
        type: @schema_name,
        schema: schema,
        active_tab: @default_tab,
        save_status: "",
        subjects_thema: MapSet.new()
      )
      |> load_document()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {tab, flash?} = parse_tab(params["tab"])

    socket =
      socket
      |> assign(active_tab: tab)
      |> assign(:page_title, tab_title(tab))

    socket =
      if flash?,
        do: put_flash(socket, :error, "Unknown tab — showing #{tab_title(tab)}"),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_info({:document_changed, %{type: type, doc_id: changed_id}}, socket) do
    if type == socket.assigns.type and Content.published_id(changed_id) == socket.assigns.doc_id do
      {:noreply, load_document(socket)}
    else
      {:noreply, socket}
    end
  end

  # Emission contract from ThemaTreePicker (Phase 5 WI2). The picker emits its
  # current selection as a MapSet whenever the user toggles a code; we mirror it
  # into `@subjects_thema` AND persist it to `doc.content["themaSubjectCategory"]`
  # as a sorted list (Phase 5 WI3). The persistence path bypasses `build_content/2`
  # because the v2 schema field for `themaSubjectCategory` is declared as a
  # single-value `codelist` while the picker is intrinsically multi-select; we
  # store the MapSet as a list directly so the round-trip survives even when the
  # registered schema has empty `fields` (e.g. minimal test fixtures).
  def handle_info({:thema_selection_changed, %MapSet{} = codes}, socket) do
    {:noreply, persist_thema(socket, codes)}
  end

  @impl true
  def handle_event("autosave", %{"doc" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    {:noreply, save(socket, form)}
  end

  def handle_event("save", %{"doc" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    socket = save(socket, form)
    {:noreply, put_flash(socket, :info, "Changes saved")}
  end

  def handle_event("publish", _params, socket) do
    case Content.publish_document(
           socket.assigns.doc_id,
           socket.assigns.type,
           socket.assigns.dataset
         ) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Document published") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to publish")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    case Content.unpublish_document(
           socket.assigns.doc_id,
           socket.assigns.type,
           socket.assigns.dataset
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Document unpublished") |> load_document()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unpublish")}
    end
  end

  def handle_event("discard-draft", _params, socket) do
    case Content.discard_draft(socket.assigns.doc_id, socket.assigns.type, socket.assigns.dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Draft discarded") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "No draft to discard")}
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp parse_tab(nil), do: {@default_tab, false}

  defp parse_tab(slug) when is_binary(slug) do
    case Map.fetch(@tab_slug_to_atom, slug) do
      {:ok, atom} -> {atom, false}
      :error -> {@default_tab, true}
    end
  end

  defp parse_tab(_), do: {@default_tab, true}

  defp tab_title(atom) do
    Enum.find_value(@tabs, "Identity", fn
      {^atom, label} -> label
      _ -> false
    end)
  end

  defp save(socket, form) do
    doc = socket.assigns[:doc]
    type = socket.assigns.type
    schema = socket.assigns.schema
    dataset = socket.assigns.dataset

    if doc do
      content = build_content(form, schema)
      published_id = Content.published_id(doc.doc_id)

      attrs = %{
        "doc_id" => Content.draft_id(published_id),
        "title" => Map.get(form, "title", doc.title),
        "status" => Map.get(form, "status", doc.status),
        "content" => content
      }

      case Content.upsert_document(type, attrs, dataset) do
        {:ok, saved} ->
          assign(socket,
            doc: saved,
            is_draft: Content.draft?(saved.doc_id),
            form: form,
            save_status: "Saved"
          )

        {:error, _} ->
          assign(socket, save_status: "Save failed")
      end
    else
      assign(socket, form: form)
    end
  end

  defp build_content(form, nil), do: Map.drop(form, ["title", "status"])

  defp build_content(form, schema) do
    schema.fields
    |> Enum.reduce(%{}, fn field, acc ->
      key = field["name"]
      val = Map.get(form, key, "")

      cond do
        key in ["title", "status"] -> acc
        val == "" or is_nil(val) -> acc
        true -> Map.put(acc, key, val)
      end
    end)
  end

  defp load_document(socket) do
    type = socket.assigns.type
    doc_id = socket.assigns.doc_id
    schema = socket.assigns.schema
    dataset = socket.assigns.dataset
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)

    draft_result = Content.get_document(draft_id, type, dataset)
    pub_result = Content.get_document(pub_id, type, dataset)

    {doc, is_draft} =
      case draft_result do
        {:ok, d} ->
          {d, true}

        _ ->
          case pub_result do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    assign(socket,
      doc: doc,
      is_draft: is_draft,
      has_published: match?({:ok, _}, pub_result),
      form: doc_to_form(doc, schema),
      subjects_thema: extract_thema(doc),
      page_title: (doc && doc.title) || "New Book"
    )
  end

  # Re-hydrate the picker's MapSet from `doc.content["themaSubjectCategory"]`.
  # Tolerates string lists (the canonical shape we persist), nil / missing keys,
  # and accidental scalar values (treated as a single-element selection).
  defp extract_thema(nil), do: MapSet.new()

  defp extract_thema(%{content: content}) when is_map(content) do
    case Map.get(content, "themaSubjectCategory") do
      list when is_list(list) -> MapSet.new(Enum.filter(list, &is_binary/1))
      code when is_binary(code) and code != "" -> MapSet.new([code])
      _ -> MapSet.new()
    end
  end

  defp extract_thema(_), do: MapSet.new()

  # Persist the picker's selection to `doc.content["themaSubjectCategory"]` as
  # a sorted list. Always writes to the draft id (per Studio's draft/published
  # model). When no document exists yet we still keep the MapSet in assigns so
  # the picker UI stays in sync; persistence resumes on the next save.
  defp persist_thema(socket, codes) do
    socket = assign(socket, subjects_thema: codes)

    case socket.assigns[:doc] do
      nil ->
        socket

      doc ->
        type = socket.assigns.type
        dataset = socket.assigns.dataset
        published_id = Content.published_id(doc.doc_id)
        list = codes |> MapSet.to_list() |> Enum.sort()

        content =
          (doc.content || %{})
          |> Map.put("themaSubjectCategory", list)

        attrs = %{
          "doc_id" => Content.draft_id(published_id),
          "title" => doc.title,
          "status" => doc.status || "draft",
          "content" => content
        }

        case Content.upsert_document(type, attrs, dataset) do
          {:ok, saved} ->
            assign(socket,
              doc: saved,
              is_draft: Content.draft?(saved.doc_id),
              save_status: "Saved"
            )

          {:error, _} ->
            assign(socket, save_status: "Save failed")
        end
    end
  end

  defp doc_to_form(nil, _), do: %{"title" => "", "status" => "draft"}

  defp doc_to_form(doc, schema) do
    base = %{"title" => doc.title || "", "status" => doc.status || "draft"}

    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]

        val =
          case key do
            k when k in ["title", "status"] -> Map.get(acc, key, "")
            _ -> get_in(doc.content || %{}, [key]) || ""
          end

        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  defp tab_path(dataset, doc_id, tab) do
    "/studio/#{dataset}/onixedit/book/#{doc_id}?tab=#{tab}"
  end

  # ── render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="main-header" style="margin: -24px -24px 24px; padding: 0 24px;">
      <div class="main-header-left">
        <a href={"/studio/#{@dataset}"} class="btn btn-ghost btn-sm">&larr;</a>
        <div>
          <h1 class="h2"><%= (@doc && @doc.title) || "New Book" %></h1>
          <div class="toolbar" style="gap: 6px; margin-top: 2px;">
            <span class="text-xs text-muted">
              <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: "book" %>
            </span>
            <span class={"badge badge-#{badge_status(@is_draft, @doc)}"}>
              <%= status_label(@is_draft, @doc) %>
            </span>
          </div>
        </div>
      </div>
      <div class="main-header-right">
        <%= if @is_draft do %>
          <button class="btn btn-primary btn-sm" phx-click="publish">Publish</button>
          <%= if @has_published do %>
            <button
              class="btn btn-ghost btn-sm"
              phx-click="discard-draft"
              data-confirm="Discard this draft?"
            >Discard draft</button>
          <% end %>
        <% else %>
          <%= if @doc do %>
            <button class="btn btn-sm" phx-click="unpublish">Unpublish</button>
          <% end %>
        <% end %>
      </div>
    </div>

    <nav class="tab-nav" data-test-id="book-editor-tabs"
         style="display: flex; gap: 4px; border-bottom: 1px solid var(--border-muted); margin-bottom: 16px;">
      <%= for {tab_key, label} <- tabs() do %>
        <.link
          patch={tab_path(@dataset, @doc_id, tab_key)}
          class={tab_link_class(tab_key, @active_tab)}
          data-tab={Atom.to_string(tab_key)}
          data-active={if tab_key == @active_tab, do: "true", else: "false"}
        ><%= label %></.link>
      <% end %>
    </nav>

    <div class="card" data-test-id="book-editor-body">
      <div class="card-header">
        <span class="text-sm text-muted">
          <%= tab_title_for(@active_tab) %>
        </span>
        <span class="text-xs text-dim" style="font-family: var(--font-mono);">
          id: <%= @doc_id %>
        </span>
      </div>

      <form phx-submit="save" phx-change="autosave" id="book-editor-form" style="padding: 24px;">
        <%= render_tab(@active_tab, assigns) %>

        <div style="display: flex; gap: 8px; padding-top: 16px; border-top: 1px solid var(--border-muted);">
          <button type="submit" class="btn btn-primary">Save changes</button>
          <a href={"/studio/#{@dataset}"} class="btn">Cancel</a>
          <span class="save-status" style="margin-left: auto; align-self: center;"><%= @save_status %></span>
        </div>
      </form>
    </div>
    """
  end

  # ── Tab body dispatch — the WI3 / WI4 seam. ────────────────────────────────
  #
  # Each clause currently renders a placeholder. To wire a real tab, replace
  # the placeholder with a component call:
  #
  #     defp render_tab(:identity, assigns) do
  #       ~H"""
  #       <.live_component
  #         module={BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.IdentityTab}
  #         id="tab-identity"
  #         doc={@doc}
  #         schema={@schema}
  #         form={@form}
  #       />
  #       """
  #     end
  #
  # Owner: WI4 owns Identity / Title / Publishing / Supply / Marketing /
  # Related. WI3 owns Subjects / Contributors.
  defp render_tab(:identity, assigns) do
    ~H"""
    <div data-tab-body="identity">
      <p class="text-sm text-muted">Identity tab — implemented in WI4</p>
    </div>
    """
  end

  defp render_tab(:title, assigns) do
    ~H"""
    <div data-tab-body="title">
      <p class="text-sm text-muted">Title tab — implemented in WI4</p>
    </div>
    """
  end

  defp render_tab(:contributors, assigns) do
    ~H"""
    <div data-tab-body="contributors">
      <p class="text-sm text-muted">Contributors tab — implemented in WI3</p>
    </div>
    """
  end

  defp render_tab(:subjects, assigns) do
    ~H"""
    <div data-tab-body="subjects">
      <p class="text-sm text-muted" style="margin-bottom: 12px;">
        Thema subject categories. Selections autosave to the draft on every change.
      </p>
      <.live_component
        module={ThemaTreePicker}
        id="thema-picker"
        selected={@subjects_thema}
      />
    </div>
    """
  end

  defp render_tab(:publishing, assigns) do
    ~H"""
    <div data-tab-body="publishing">
      <p class="text-sm text-muted">Publishing tab — implemented in WI4</p>
    </div>
    """
  end

  defp render_tab(:supply, assigns) do
    ~H"""
    <div data-tab-body="supply">
      <p class="text-sm text-muted">Supply tab — implemented in WI4</p>
    </div>
    """
  end

  defp render_tab(:marketing, assigns) do
    ~H"""
    <div data-tab-body="marketing">
      <p class="text-sm text-muted">Marketing tab — implemented in WI4</p>
    </div>
    """
  end

  defp render_tab(:related, assigns) do
    ~H"""
    <div data-tab-body="related">
      <p class="text-sm text-muted">Related tab — implemented in WI4</p>
    </div>
    """
  end

  # ── Render helpers ─────────────────────────────────────────────────────────

  defp tab_link_class(tab, active) when tab == active, do: "tab tab-active"
  defp tab_link_class(_, _), do: "tab"

  defp tab_title_for(atom), do: tab_title(atom)

  defp badge_status(true, _), do: "draft"
  defp badge_status(false, %{status: status}) when is_binary(status), do: status
  defp badge_status(_, _), do: "draft"

  defp status_label(true, _), do: "draft"
  defp status_label(false, %{status: status}) when is_binary(status), do: status
  defp status_label(_, _), do: "draft"
end
