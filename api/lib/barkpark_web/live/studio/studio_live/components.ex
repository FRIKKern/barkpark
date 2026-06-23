defmodule BarkparkWeb.Studio.StudioLive.Components do
  @moduledoc """
  Function components extracted from `BarkparkWeb.Studio.StudioLive` — the
  in-Studio live paper view (`studio_paper_view/1`), the Classic⇄Beta editor
  mode toggle (`editor_mode_toggle/1`), the Beta block editor
  (`paper_block_editor/1`), and the per-block-type edit fields
  (`paper_block_fields/1`), plus the pure footer-stats helpers. Imported back
  into StudioLive so the `<.studio_paper_view ...>` call sites in render/1 keep
  working verbatim. Behavior-preserving move.
  """
  use BarkparkWeb, :html

  import Phoenix.HTML, only: [raw: 1]

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Projection
  alias BarkparkWeb.Studio.{PaneBuilder, PresenceState}
  alias BarkparkWeb.Studio.StudioLive.{Blocks, DocActions, Paths}

  # ── In-Studio live paper view (function component) ──────────────────────────
  #
  # Renders a paper LIVE inside the editor pane. Block-backed papers stream each
  # top-level block as a keyed `phx-update="stream"` item; HTML-only (legacy)
  # papers render `raw(@paper_html)`. The `#paper-sentinel` element is rendered
  # once OUTSIDE the streamed container so a `handle_info` DOM diff preserves it
  # — the same no-reload proof BulldocsLive uses, now inside the Studio. Read-only:
  # editing stays on the paper-ingest ops endpoint.
  attr(:paper_doc, :map, default: nil)
  attr(:paper_rev, :integer, default: 0)
  attr(:paper_html, :string, default: "")
  attr(:paper_block_mode, :boolean, default: false)
  attr(:paper_edit_mode, :boolean, default: false)
  attr(:shares_admin?, :boolean, default: false)
  attr(:dataset, :string, required: true)
  attr(:api_token_raw, :string, default: "")
  attr(:streams, :map, required: true)
  attr(:backlinks_linked, :list, default: [])
  attr(:backlinks_unlinked, :list, default: [])
  attr(:backlinks_open, :boolean, default: true)

  def studio_paper_view(assigns) do
    slug = assigns.paper_doc && assigns.paper_doc.doc_id
    title = (assigns.paper_doc && assigns.paper_doc.title) || slug || "Paper"

    edit_blocks =
      case assigns.paper_doc do
        %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
        _ -> []
      end

    assigns = assign(assigns, slug: slug, title: title, edit_blocks: edit_blocks)

    ~H"""
    <div class="editor-panel" data-test-id="studio-paper-editor">
      <.document_header dataset={@dataset} title={@title}>
        <:status_pill>
          <span class="badge badge-published">paper</span>
        </:status_pill>
        <:actions>
          <%!-- View ⇄ Edit toggle. View is the read-only live stream; Edit
                renders the per-block controls. Block-backed papers only. --%>
          <button
            :if={@slug && @paper_block_mode}
            type="button"
            class={"btn btn-sm " <> if(@paper_edit_mode, do: "btn-primary", else: "btn-ghost")}
            phx-click="paper-toggle-edit"
            data-test-id="paper-edit-toggle"
          >
            <.icon name={if @paper_edit_mode, do: "eye", else: "pencil"} size={14} />
            <%= if @paper_edit_mode, do: "View", else: "Edit" %>
          </button>
          <a
            :if={@slug}
            href={(assigns[:scope_prefix] || "") <> "/papers/#{@slug}"}
            class="btn btn-ghost btn-sm"
            target="_blank"
            rel="noopener"
            data-test-id="paper-open-standalone"
          >
            <.icon name="external-link" size={14} /> Open standalone
          </a>
          <%!-- ITEM share (P7): a direct Google-Docs-style link to THIS paper,
                not the whole papers section. Admin-only; the handler re-checks
                admin server-side. --%>
          <button
            :if={@shares_admin?}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="item-share-open"
            phx-value-kind="doc"
            phx-value-ref-type="paper"
            phx-value-ref-id={@slug}
            phx-value-title={@title}
            title="Share this paper (direct link)"
            data-test-id="paper-share"
          >
            <.icon name="share-2" size={14} /> Share
          </button>
        </:actions>
      </.document_header>

      <div class="editor-with-preview">
        <div class="editor-body editor-panel-main bp-paper-body">
          <main class="bp-paper-shell bp-paper-surface" data-test-id="studio-paper-shell">
            <%!-- Sentinel: rendered once, OUTSIDE the streamed/re-assigned
                  container. It survives a handle_info DOM diff but would be
                  torn down by a remount/navigate — the no-reload proof. --%>
            <div id="paper-sentinel" data-slug={@slug} hidden></div>

            <%= cond do %>
              <% is_nil(@slug) -> %>
                <article id="paper-body" data-rev={@paper_rev}>
                  <p id="paper-empty">No paper selected.</p>
                </article>
              <% @paper_edit_mode && @paper_block_mode -> %>
                <.paper_block_editor
                  slug={@slug}
                  blocks={@edit_blocks}
                  paper_rev={@paper_rev}
                  dataset={@dataset}
                  api_token_raw={@api_token_raw}
                />
              <% @paper_block_mode -> %>
                <%!-- Block-backed: each top-level block is its own keyed stream
                      item. A delta patches/appends/deletes ONE of these.

                      The container id is keyed on the slug so jumping to a
                      DIFFERENT paper hands LiveView a NEW stream container —
                      it tears down the prior paper's block DOM instead of
                      reusing nodes whose block ids happen to collide across
                      papers (the "stale content after a jump" bug). Within
                      the SAME paper the id is stable, so `{:paper_block}`
                      deltas still diff in place with no remount. --%>
                <article
                  id={"paper-body-#{@slug}"}
                  data-rev={@paper_rev}
                  phx-update="stream"
                >
                  <div
                    :for={{dom_id, block} <- @streams.paper_blocks}
                    id={dom_id}
                    data-block-id={block.id}
                    phx-hook="BarkparkCalloutFold"
                  >
                    {raw(block.html)}
                  </div>
                </article>
              <% true -> %>
                <%!-- HTML-only (legacy): whole opaque body, re-assigned on
                      update. Keyed on the slug too so a jump swaps the node. --%>
                <article id={"paper-body-#{@slug}"} data-rev={@paper_rev}>{raw(@paper_html)}</article>
            <% end %>
          </main>
        </div>
        <aside
          :if={@paper_doc}
          class={"bp-backlinks-panel " <> if(@backlinks_open, do: "is-open", else: "is-collapsed")}
          data-test-id="studio-backlinks-panel"
        >
          <div class="bp-backlinks-head">
            <button
              type="button"
              class="bp-backlinks-toggle"
              phx-click="backlinks-toggle"
              aria-expanded={to_string(@backlinks_open)}
              data-test-id="backlinks-toggle"
            >
              <.icon name={if @backlinks_open, do: "chevron-down", else: "chevron-right"} size={14} />
              <span>Backlinks</span>
            </button>
            <button
              type="button"
              class="bp-backlinks-refresh"
              phx-click="backlinks-refresh"
              title="Refresh backlinks"
              data-test-id="backlinks-refresh"
            >
              <.icon name="refresh-cw" size={12} />
            </button>
          </div>

          <div :if={@backlinks_open} class="bp-backlinks-body">
            <section class="bp-backlinks-section" data-test-id="backlinks-linked">
              <h4 class="bp-backlinks-section-title">Linked mentions ({length(@backlinks_linked)})</h4>
              <%= if @backlinks_linked == [] do %>
                <p class="bp-backlinks-empty">No linked mentions.</p>
              <% else %>
                <ul class="bp-backlinks-list">
                  <li :for={ref <- @backlinks_linked}>
                    <button
                      :if={ref[:from_doc_id]}
                      type="button"
                      class="bp-backlinks-row is-clickable"
                      phx-click="open-backlink"
                      phx-value-slug={ref.from_doc_id}
                      phx-value-type={ref.type}
                      data-test-id="backlink-row"
                    >
                      <span class="bp-backlinks-title">{ref.title || "Untitled"}</span>
                      <span class="bp-backlinks-meta">{ref.type} / {ref.via_field}</span>
                    </button>
                    <div :if={!ref[:from_doc_id]} class="bp-backlinks-row" data-test-id="backlink-row">
                      <span class="bp-backlinks-title">{ref.title || "Untitled"}</span>
                      <span class="bp-backlinks-meta">{ref.type} / {ref.via_field}</span>
                    </div>
                  </li>
                </ul>
              <% end %>
            </section>

            <section class="bp-backlinks-section" data-test-id="backlinks-unlinked">
              <h4 class="bp-backlinks-section-title">Derived mentions ({length(@backlinks_unlinked)})</h4>
              <%= if @backlinks_unlinked == [] do %>
                <p class="bp-backlinks-empty">No derived mentions.</p>
              <% else %>
                <ul class="bp-backlinks-list">
                  <li :for={ref <- @backlinks_unlinked}>
                    <button
                      :if={ref[:from_doc_id]}
                      type="button"
                      class="bp-backlinks-row is-clickable"
                      phx-click="open-backlink"
                      phx-value-slug={ref.from_doc_id}
                      phx-value-type={ref.type}
                      data-test-id="backlink-row"
                    >
                      <span class="bp-backlinks-title">{ref.title || "Untitled"}</span>
                      <span class="bp-backlinks-meta">{ref.type} / {ref.via_field}</span>
                    </button>
                    <div :if={!ref[:from_doc_id]} class="bp-backlinks-row" data-test-id="backlink-row">
                      <span class="bp-backlinks-title">{ref.title || "Untitled"}</span>
                      <span class="bp-backlinks-meta">{ref.type} / {ref.via_field}</span>
                    </div>
                  </li>
                </ul>
              <% end %>
            </section>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  # ── Paper block editor (function component) ─────────────────────────────────
  #
  # Edit mode for a block-backed paper. Renders per-block edit controls; each
  # control fires a `paper-*` event that maps to ONE DocPatchOp. The container
  # is keyed on the slug + rev so a jump or an op refreshes it cleanly. This is
  # plain assign-driven HTML (no stream) — the read-only View pane is the
  # streamed surface; this editor reads from `paper_doc.content["blocks"]`.
  # ── Classic <-> Beta segmented toggle (Exp-P3.2, barkpark-g2ql) ─────────────
  # Two-button segmented control fired into `editor-set-mode`. The active mode
  # is `btn-primary`, the other `btn-ghost`. Rendered in the editor header for
  # a Beta-eligible document only (the caller gates on `@editor_blocks != []`).
  attr(:mode, :atom, default: :classic)
  attr(:beta_ok, :boolean, default: false)

  def editor_mode_toggle(assigns) do
    ~H"""
    <div class="editor-mode-toggle" role="group" aria-label="Editor mode" data-test-id="editor-mode-toggle">
      <button
        type="button"
        class={"btn btn-sm " <> if(@mode == :classic, do: "btn-primary", else: "btn-ghost")}
        phx-click="editor-set-mode"
        phx-value-mode="classic"
        aria-pressed={@mode == :classic}
        data-test-id="editor-mode-classic"
      >Classic</button>
      <button
        type="button"
        class={"btn btn-sm " <> if(@mode == :beta, do: "btn-primary", else: "btn-ghost")}
        phx-click="editor-set-mode"
        phx-value-mode="beta"
        aria-pressed={@mode == :beta}
        data-test-id="editor-mode-beta"
      >Beta</button>
    </div>
    """
  end

  attr(:slug, :string, required: true)
  attr(:blocks, :list, required: true)
  attr(:paper_rev, :integer, default: 0)
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")
  # EX2 — the expected fields STILL recommendable for THIS doc's current block
  # list (Content.available_expected_fields/3). Each entry carries name/type/
  # label; the slash menu reads it from `data-expected-fields` to render its
  # top EXPECTED group. Empty list ⇒ no group rendered (e.g. the paper pane,
  # which has no Expectation). Re-rendered on every block-list change because
  # the carrier <div> lives OUTSIDE any phx-update="ignore" node.
  attr(:expected_fields, :list, default: [])

  # Full expected-field descriptors (incl. bound-and-at-cap) for the Properties
  # panel. Empty list ⇒ no panel + body shows ALL blocks (the paper pane, which
  # has no Expectation, passes none — so it is byte-unchanged).
  attr(:descriptors, :list, default: [])

  def paper_block_editor(assigns) do
    # Gate the bound/free split on having descriptors: only the Beta editor (with
    # an Expectation) shows the Properties panel. The paper pane passes
    # descriptors=[] ⇒ properties?=false ⇒ free == all blocks, panel self-hides.
    properties? = assigns.descriptors != []

    {bound, free} =
      if properties?, do: Projection.partition(assigns.blocks), else: {[], assigns.blocks}

    assigns =
      assigns
      |> assign(:bound_blocks, bound)
      |> assign(:free_blocks, free)
      |> assign(:last_index, length(free) - 1)
      |> assign(:doc_stats, beta_doc_stats(assigns.blocks))

    ~H"""
    <%!-- The whole block list is a drag-sortable surface. The
          BarkparkPaperSortable hook makes ONLY the per-block grip draggable
          (never the block body — the blocks hold contenteditable editors +
          form inputs, so dragging the body would fight text selection/focus).
          On drop it fires `paper-move-block-to` → the same `move-block` op the
          ▲/▼ buttons use. The buttons are the robust core and work without JS;
          drag is a progressive enhancement layered on top. --%>
    <div
      id={"paper-editor-#{@slug}"}
      class="bp-paper-editor"
      data-test-id="studio-paper-block-editor"
      phx-hook="BarkparkPaperSortable"
    >
      <%!-- EX2 — expectation-aware slash menu carrier. A stable, LiveView-driven
            element (NOT inside any phx-update="ignore" wrapper) holding the
            JSON list of expected fields STILL recommendable for the current
            block list. It re-renders whenever @blocks/@expected_fields change,
            so the slash menu's EXPECTED group always reflects current usage
            (a field hides once it hits its cap). The slash menu in
            slash-menu.js reads `[data-expected-fields]` on open. --%>
      <div
        id="bp-expected-fields"
        data-expected-fields={Jason.encode!(@expected_fields)}
        data-test-id="bp-expected-fields"
        hidden
      ></div>

      <.properties_panel
        rows={Enum.map(@bound_blocks, fn b -> {b, descriptor_for(@descriptors, b)} end)}
        unbound={Enum.filter(@descriptors, fn d -> d.count == 0 end)}
        dataset={@dataset}
        api_token_raw={@api_token_raw}
      />

      <p :if={@free_blocks == []} class="bp-paper-editor-empty">
        This paper has no body blocks yet. Add one below.
      </p>

      <div
        :for={{block, index} <- Enum.with_index(@free_blocks)}
        class="bp-paper-edit-block"
        data-edit-block-id={Map.get(block, "id")}
        data-block-type={Map.get(block, "type")}
      >
        <div class="bp-paper-edit-toolbar">
          <span
            class="bp-paper-drag-grip"
            data-drag-grip
            draggable="true"
            title="Drag to reorder"
            aria-label="Drag to reorder block"
            data-test-id="paper-drag-grip"
          >⋮⋮</span>
          <span class="bp-paper-edit-kind"><%= Map.get(block, "type") %></span>
          <span class="bp-paper-edit-actions">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              title="Move up"
              phx-click="paper-move-block"
              phx-value-id={Map.get(block, "id")}
              phx-value-dir="up"
              disabled={index == 0}
              data-test-id="paper-move-up"
            >▲</button>
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              title="Move down"
              phx-click="paper-move-block"
              phx-value-id={Map.get(block, "id")}
              phx-value-dir="down"
              disabled={index == @last_index}
              data-test-id="paper-move-down"
            >▼</button>
            <button
              type="button"
              class="btn btn-destructive btn-sm"
              title="Delete block"
              phx-click="paper-delete-block"
              phx-value-id={Map.get(block, "id")}
              data-test-id="paper-delete-block"
            >×</button>
          </span>
        </div>
        <.paper_block_fields block={block} dataset={@dataset} api_token_raw={@api_token_raw} />
      </div>

      <%!-- Add-block dropdown. The `+ Add` <select> fires append-block (no
            anchor) of the chosen type via paper-add-block. Every portable-doc
            block type is creatable here (P3.1), grouped by optgroup so the
            list stays scannable: Text (rich-text), Basic fields (leaf field-*),
            Media & reference (picker field-*), Structured (v2 composite). Each
            choice resolves to default_block/2 and is applied through the SAME
            paper-add-block → paper_op pipeline. --%>
      <form
        class="bp-paper-add-block"
        phx-submit="paper-add-block"
        data-test-id="paper-add-block"
      >
        <label>
          + Add block
          <select name="block-type">
            <optgroup label="Text">
              <option value="paragraph">Paragraph</option>
              <option value="heading">Heading</option>
              <option value="list">List</option>
              <option value="callout">Callout</option>
              <option value="code">Code</option>
              <option value="divider">Divider</option>
              <option value="section">Section</option>
            </optgroup>
            <optgroup label="Article chrome">
              <option value="eyebrow">Eyebrow</option>
              <option value="byline">Byline</option>
              <option value="ingress">Ingress</option>
              <option value="pullquote">Pullquote</option>
            </optgroup>
            <optgroup label="Visual">
              <option value="diagram">Diagram</option>
            </optgroup>
            <optgroup label="Basic fields">
              <option value="field-string">String</option>
              <option value="field-slug">Slug</option>
              <option value="field-text">Long text</option>
              <option value="field-boolean">Boolean</option>
              <option value="field-select">Select</option>
              <option value="field-datetime">Date &amp; time</option>
              <option value="field-color">Color</option>
            </optgroup>
            <optgroup label="Media &amp; reference">
              <option value="field-image">Image</option>
              <option value="field-reference">Reference</option>
            </optgroup>
            <optgroup label="Structured">
              <option value="composite">Composite</option>
              <option value="arrayOf">Array of</option>
              <option value="codelist">Code list</option>
              <option value="localizedText">Localized text</option>
            </optgroup>
          </select>
        </label>
        <button type="submit" class="btn btn-primary btn-sm">Add</button>
      </form>

      <%!-- Doc footer (gap #4): live word + block count and a save affordance,
            mirroring the original PortableDoc editor's status bar. Counts come
            from the server-side block list (beta_doc_stats/1), refreshed on each
            persisted block op. --%>
      <footer class="bp-paper-footer" data-test-id="bp-paper-footer">
        <span><%= @doc_stats.words %> words</span>
        <span class="bp-paper-footer-sep">·</span>
        <span><%= @doc_stats.blocks %> blocks</span>
        <span class="bp-paper-footer-save">✓ Auto-saved</span>
      </footer>
    </div>
    """
  end

  # Live document stats for the Beta editor footer (gap #4): top-level block
  # count + total word count across all block text. Pure; recomputed on each
  # render so it tracks the persisted block list.
  defp beta_doc_stats(blocks) when is_list(blocks) do
    words =
      blocks
      |> Enum.map(&beta_node_text/1)
      |> Enum.map(fn t -> t |> String.split(~r/\s+/, trim: true) |> length() end)
      |> Enum.sum()

    %{blocks: length(blocks), words: words}
  end

  defp beta_doc_stats(_), do: %{blocks: 0, words: 0}

  # Recursively gather plain text from a block / inline node — a string, a list,
  # or a map carrying text/value/children/content/items/body. Unknown → "".
  defp beta_node_text(s) when is_binary(s), do: s
  defp beta_node_text(list) when is_list(list), do: Enum.map_join(list, " ", &beta_node_text/1)

  defp beta_node_text(%{} = m) do
    ["text", "value", "children", "content", "items", "body"]
    |> Enum.map_join(" ", fn k -> beta_node_text(Map.get(m, k)) end)
  end

  defp beta_node_text(_), do: ""

  # ── Properties panel (Storage Model A) ──────────────────────────────────────
  # A collapsible section ABOVE the body editor. Each row is a BOUND field-block
  # rendered as: schema label + type/cap badge + unbind × + the EXISTING value
  # control (paper_block_fields/1, unchanged — so the JS bridge + LiveComponent
  # keep working). The Add-property <select> lists unbound expected fields. The
  # panel emits NO new ops beyond paper-add-property / paper-unbind-property.
  attr(:rows, :list, default: [])
  attr(:unbound, :list, default: [])
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")

  def properties_panel(assigns) do
    ~H"""
    <details
      :if={@rows != [] or @unbound != []}
      class="bp-properties"
      open
      data-test-id="studio-properties-panel"
    >
      <summary class="bp-properties-summary">Properties</summary>

      <div :for={{block, descriptor} <- @rows} class="bp-prop-row" data-prop-block-id={Map.get(block, "id")}>
        <div class="bp-prop-head">
          <span class="bp-prop-label">{prop_label(block, descriptor)}</span>
          <span :if={descriptor} class={"bp-prop-badge " <> if(prop_at_cap?(descriptor), do: "is-at-cap", else: "")}>
            {prop_badge(descriptor)}
          </span>
          <button
            type="button"
            class="btn btn-ghost btn-sm bp-prop-unbind"
            title="Unbind property"
            phx-click="paper-unbind-property"
            phx-value-id={Map.get(block, "id")}
            data-test-id="paper-unbind-property"
          >×</button>
        </div>
        <.paper_block_fields block={block} dataset={@dataset} api_token_raw={@api_token_raw} />
      </div>

      <form
        :if={@unbound != []}
        class="bp-prop-add"
        phx-submit="paper-add-property"
        data-test-id="paper-add-property"
      >
        <label>
          + Add property
          <select name="fieldName">
            <option value="" disabled selected>Choose a field…</option>
            <option :for={d <- @unbound} value={d.name}>{d.label}</option>
          </select>
        </label>
        <button type="submit" class="btn btn-primary btn-sm">Add</button>
      </form>
    </details>
    """
  end

  # The descriptor whose name matches a bound block's fieldName (nil when the
  # block binds a field not in the current layout — still rendered, bare label).
  defp descriptor_for(descriptors, block) do
    name = Map.get(block, "fieldName")
    Enum.find(descriptors, fn d -> d.name == name end)
  end

  defp prop_label(_block, %{label: label}) when is_binary(label) and label != "", do: label

  defp prop_label(block, _descriptor),
    do: Map.get(block, "label") || Map.get(block, "fieldName") || ""

  defp prop_badge(%{count: count, max: max}) when is_integer(max), do: "#{count}/#{max}"
  defp prop_badge(%{count: count}), do: "#{count}"

  defp prop_at_cap?(%{count: count, max: max}) when is_integer(max), do: count >= max
  defp prop_at_cap?(_), do: false

  # Per-block-type edit fields. Each `<form phx-submit="paper-edit-block">`
  # carries a hidden `id` and submits its changed field(s); the handler maps
  # the params to a patch-block op. Paragraph/callout bodies are PLAIN TEXT in
  # the MVP (inline marks dropped on save).
  attr(:block, :map, required: true)
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")

  def paper_block_fields(assigns) do
    assigns =
      assign(assigns, id: Map.get(assigns.block, "id"), type: Map.get(assigns.block, "type"))

    ~H"""
    <%= case @type do %>
      <%!-- Rich-text blocks (paragraph / heading / list) are edited by the
            <bp-paper-editor> Web Component. The phx-update="ignore" wrapper
            keeps LiveView from re-diffing the WC's internal DOM (preserving
            the caret across server updates); its id is stable per block id so
            it survives re-renders. The WC reads its initial block from
            data-block and emits debounced `bp-op` events that the
            BarkparkPaperEditor hook forwards to the server's paper-op handler.
            field-type blocks (callout/code/list-as-fields/section/divider/…)
            keep their existing form-based editors below — out of scope here. --%>
      <% t when t in ["paragraph", "heading", "list"] -> %>
        <div
          phx-update="ignore"
          id={"paper-ed-" <> @id}
          phx-hook="BarkparkPaperEditor"
          class="bp-paper-edit-wc"
          data-test-id="paper-block-editor-wc"
        >
          <bp-paper-editor data-block={Jason.encode!(@block)}></bp-paper-editor>
        </div>
      <% "callout" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <select name="tone" class="bp-paper-edit-tone">
            <option :for={t <- ~w(info success warning danger neutral)} value={t} selected={Map.get(@block, "tone") == t}>
              <%= t %>
            </option>
          </select>
          <label class="bp-paper-edit-check">
            <input type="checkbox" name="collapsible" checked={Map.get(@block, "collapsible") == true} /> Foldable
          </label>
          <label class="bp-paper-edit-check">
            <input type="checkbox" name="collapsed" checked={Map.get(@block, "collapsed") == true} /> Start collapsed
          </label>
          <input
            type="text"
            name="title"
            class="bp-paper-edit-text"
            placeholder="Title (optional)"
            value={Map.get(@block, "title", "")}
          />
          <textarea
            name="text"
            class="bp-paper-edit-textarea"
            rows="3"
            data-test-id="paper-field-text"
          ><%= Blocks.inline_to_text(Map.get(@block, "content", [])) %></textarea>
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "code" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <input
            type="text"
            name="lang"
            class="bp-paper-edit-text"
            placeholder="lang"
            value={Map.get(@block, "lang", "")}
          />
          <textarea
            name="value"
            class="bp-paper-edit-textarea bp-paper-edit-code"
            rows="5"
            data-test-id="paper-field-value"
          ><%= Map.get(@block, "value", "") %></textarea>
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <%!-- diagram (barkpark-woxx): a Mermaid `source` textarea (mirrors the code
            block's value textarea, monospace) + an optional caption input. Both
            are flat strings on the block — build_block_patch reads them verbatim. --%>
      <% "diagram" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <textarea
            name="source"
            class="bp-paper-edit-textarea bp-paper-edit-code"
            rows="5"
            placeholder="graph TD&#10;  A --> B"
            data-test-id="paper-field-source"
          ><%= Map.get(@block, "source", "") %></textarea>
          <input
            type="text"
            name="caption"
            class="bp-paper-edit-text"
            placeholder="Caption (optional)"
            value={Map.get(@block, "caption", "")}
            data-test-id="paper-field-caption"
          />
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <%!-- article-chrome blocks (barkpark-54kh). eyebrow + byline are a single
            text input; ingress + pullquote are a textarea (plain-text MVP, like
            the callout body). They mirror the callout/code form markup. --%>
      <% "eyebrow" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <input
            type="text"
            name="text"
            class="bp-paper-edit-text"
            placeholder="Eyebrow (kicker) text"
            value={Map.get(@block, "text", "")}
            data-test-id="paper-field-eyebrow"
          />
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "byline" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <input
            type="text"
            name="text"
            class="bp-paper-edit-text"
            placeholder="By line — separate names with ·"
            value={Enum.join(Map.get(@block, "items", []), " · ")}
            data-test-id="paper-field-byline"
          />
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "ingress" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <textarea
            name="text"
            class="bp-paper-edit-textarea"
            rows="3"
            data-test-id="paper-field-ingress"
          ><%= Blocks.inline_to_text(Map.get(@block, "content", [])) %></textarea>
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "pullquote" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <textarea
            name="text"
            class="bp-paper-edit-textarea"
            rows="3"
            data-test-id="paper-field-pullquote"
          ><%= Blocks.inline_to_text(Map.get(@block, "content", [])) %></textarea>
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "section" -> %>
        <form
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
        >
          <input type="hidden" name="block_id" value={@id} />
          <input
            type="text"
            name="title"
            class="bp-paper-edit-text"
            placeholder="Section title"
            value={Map.get(@block, "title", "")}
            data-test-id="paper-field-title"
          />
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "divider" -> %>
        <p class="bp-paper-edit-readonly">— divider —</p>

      <%!-- field-* LEAF blocks (P2.1). Each renders a labelled native control
            inside a stable phx-update="ignore" wrapper mounted with the
            BarkparkFieldBlockBridge hook. The hook reads data-field-type to
            coerce the value, builds a patch-block op carrying {value:…}, and
            pushes it through the same `paper-op` pipeline the rich-text WC uses.
            phx-update="ignore" keeps LiveView from re-stamping the control's
            value mid-edit (server owns the model; no echo). --%>
      <% t when t in ["field-string", "field-slug"] -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="text" class="bp-paper-edit-text" value={Map.get(@block, "value", "")}
                 data-test-id={"paper-field-" <> @type} />
        </div>

      <% "field-text" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <textarea class="bp-paper-edit-textarea" rows={Map.get(@block, "rows") || 3}
                    data-test-id="paper-field-field-text"><%= Map.get(@block, "value", "") %></textarea>
        </div>

      <% "field-boolean" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="checkbox" checked={Map.get(@block, "value") == true}
                 data-test-id="paper-field-field-boolean" />
        </div>

      <% "field-select" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <select class="form-input" data-test-id="paper-field-field-select">
            <option :for={o <- Map.get(@block, "options", [])}
                    value={Map.get(o, "value")}
                    selected={Map.get(o, "value") == Map.get(@block, "value")}>
              <%= Map.get(o, "label", Map.get(o, "value", "")) %>
            </option>
          </select>
        </div>

      <% "field-datetime" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="datetime-local" class="form-input" value={Map.get(@block, "value", "")}
                 data-test-id="paper-field-field-datetime" />
        </div>

      <% "field-color" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="color" value={Map.get(@block, "value", "#000000")}
                 data-test-id="paper-field-field-color"
                 style="width:36px;height:36px;border:1px solid var(--input);border-radius:6px;cursor:pointer;background:transparent;" />
        </div>

      <%!-- field-reference / field-image PICKER blocks (P2.2). The Edit control
            is an existing picker Web Component (bp-reference-picker /
            bp-media-picker) rather than a native control. Each WC owns its own
            search / select / clear UX and emits a bubbling `bp-change`
            CustomEvent({detail:{value}}) on selection — the SAME event the
            classic field_inputs.ex renderer relies on. BarkparkFieldBlockBridge
            (root.html.heex) listens for that `bp-change` (in addition to native
            input/change) and pushes a {op:"patch-block",id,patch:{value}} op
            through the same `paper-op` pipeline. The reference WC reads its
            refType + dataset from inline block attrs; the media WC reads the
            raw bearer token from data-token (empty disables upload, browse +
            select still work). value is a plain string in both cases. --%>
      <% "field-reference" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <bp-reference-picker
            value={Map.get(@block, "value", "")}
            ref-type={Map.get(@block, "refType", "")}
            dataset={Map.get(@block, "dataset", @dataset)}
            data-test-id="paper-field-field-reference"
          ></bp-reference-picker>
        </div>

      <% "field-image" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <bp-media-picker
            value={Map.get(@block, "value", "")}
            dataset={Map.get(@block, "dataset", @dataset)}
            data-token={@api_token_raw}
            data-test-id="paper-field-field-image"
          ></bp-media-picker>
        </div>

      <%!-- v2 COMPOSITE field blocks (P2.3). composite / arrayOf / codelist /
            localizedText render as a nested PaperFieldBlock LiveComponent —
            NOT inside phx-update="ignore". These controls emit server-bound
            phx-change / phx-click into their own form (targeting @myself);
            the component recomputes its value and sends a {:paper_op, …}
            message that handle_info routes through the canonical paper_op/2
            pipeline. The component is idempotent on update/2 + updates its own
            value local-first, so the server echo never clobbers an in-flight
            edit or steals input focus. --%>
      <% t when t in ["composite", "arrayOf", "codelist", "localizedText"] -> %>
        <.live_component
          module={BarkparkWeb.Studio.PaperFieldBlock}
          id={"paper-fb-" <> @id}
          block={@block}
        />

      <% _ -> %>
        <%!-- image / table and any other type are read-only in the MVP. --%>
        <p class="bp-paper-edit-readonly">
          <%= @type %> blocks are not editable yet (view/delete/reorder only).
        </p>
    <% end %>
    """
  end

  # ── Studio shell (the full render/1 template, extracted) ────────────────────
  def studio_live_shell(assigns) do
    ~H"""
    <%!-- Presence renders in the layout's .studio-bar-right (it used to be
          a position:fixed overlay HERE, stacking over the bar's sign-out
          corner — the top-bar overlap bug). --%>
    <%!-- Beta focus mode mirror (Task barkpark-270j). This 0×0 element carries
          the live `@editor_mode` and the EditorFocus JS hook mirrors it onto
          `<html data-editor-focus="beta">` whenever the value is "beta". CSS
          gated on that attribute hides the doc-list pane, slims the topbar, and
          centers the paper column — a clean standalone-document surface. The
          element ALWAYS renders so the hook persists across Classic⇄Beta flips;
          flipping changes the data-editor-mode value, which fires the hook's
          updated() with no reload. The topbar lives in studio.html.heex (outside
          this LiveView's scope), so this attr on <html> is how the slim-topbar
          CSS reaches it. --%>
    <div id="editor-focus-mirror" phx-hook="EditorFocus" data-editor-mode={@editor_mode}
         style="display:none;"></div>

    <.pane_layout id="studio-panes">
      <% has_editor = @editor_doc != nil %>
      <% num_panes = length(@panes) %>
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <% collapsed = PaneBuilder.collapse?(idx, num_panes, has_editor) %>
        <.pane_column
          id={"pane-#{pane.title |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")}"}
          title={pane.title}
          collapsed={collapsed}
          marker_class={if pane[:type_name], do: "bp-doc-list", else: nil}
          phx_click={if collapsed, do: "expand-pane", else: nil}
          phx_value_idx={if collapsed, do: "#{idx}", else: nil}
        >
          <:header_actions>
            <%= if pane[:type_name] do %>
              <button
                class="pane-add-btn"
                phx-click="new-document"
                phx-value-type={pane.type_name}
              ><.icon name="plus" size={14} /></button>
            <% end %>
          </:header_actions>

          <%= if Map.get(pane, :desk_groups, []) != [] do %>
            <div class="bp-desk-filter" role="tablist" aria-label="Desk filters">
              <%= for grp <- pane.desk_groups do %>
                <% gname = Map.get(grp, "name") || Map.get(grp, :name) %>
                <% gtitle = Map.get(grp, "title") || Map.get(grp, :title) || gname %>
                <% active = to_string(gname) == to_string(pane[:active_desk] || "") %>
                <a
                  class={"bp-desk-chip " <> if(active, do: "is-active", else: "")}
                  role="tab"
                  aria-selected={active}
                  href={Paths.desk_chip_href(@scope_prefix, @nav_path, @dataset, gname)}
                  phx-click="select-desk"
                  phx-value-desk={gname}
                ><%= gtitle %></a>
              <% end %>
            </div>
          <% end %>

          <div class="pane-body">
            <%= if pane.items == [] and pane[:type_name] != nil do %>
              <div class="text-sm text-muted" style="padding: 20px; text-align: center;">
                No documents yet — press + to create one
              </div>
            <% end %>
            <%= for item <- pane.items do %>
              <%= case item.type do %>
                <% :divider -> %>
                  <%= if item[:label] && item[:label] != "" do %>
                    <div class="pane-divider pane-divider--labelled" role="separator" aria-label={item[:label]}>
                      <span class="pane-divider-label"><%= item[:label] %></span>
                    </div>
                  <% else %>
                    <.pane_divider />
                  <% end %>

                <% :header -> %>
                  <.pane_section_header>
                    <.icon name={item.icon} size={12} /> <%= item.title %>
                  </.pane_section_header>

                <% :plugin_link -> %>
                  <a
                    id={"plugin-link-#{item.id}"}
                    href={Paths.scoped_plugin_href(@scope_prefix || "", item.href)}
                    class="pane-item nav-plugin-entry"
                    data-test-id="nav-plugin-entry"
                  >
                    <%= if item.icon do %>
                      <span class="pane-item-icon"><.icon name={item.icon} size={16} /></span>
                    <% end %>
                    <span class="pane-item-label"><%= item.title %></span>
                  </a>

                <% :doc -> %>
                  <% item_presences = PresenceState.on_doc(@presences, item.id, @dataset) %>
                  <.pane_doc_item
                    id={"doc-#{item.id}"}
                    phx_click="select"
                    phx_value_pane={"#{idx}"}
                    phx_value_id={item.id}
                    title={item.title}
                    doc_id={item.id}
                    status={item.status || ""}
                    is_draft={item.is_draft}
                    badge={item[:badge]}
                    meta={item[:meta]}
                    selected={item.id == pane[:selected]}
                    selectable={pane[:type_name] != nil}
                    checked={MapSet.member?(@selected_doc_ids, item.id)}
                  >
                    <:trailing :if={item_presences != []}>
                      <%= for p <- item_presences do %>
                        <span class="presence-dot-sm" style={"background: #{p.color}"}></span>
                      <% end %>
                    </:trailing>
                  </.pane_doc_item>

                <% _ -> %>
                  <.pane_item
                    id={"item-#{item.id}"}
                    phx_click="select"
                    phx_value_id={item.id}
                    phx_value_pane={"#{idx}"}
                    selected={item.id == pane[:selected]}
                  >
                    <:icon><.icon name={item.icon} size={16} /></:icon>
                    <%= item.title %>
                    <:trailing :if={item[:drillable]}>
                      <.icon name="chevron-right" size={14} />
                    </:trailing>
                  </.pane_item>
              <% end %>
            <% end %>
          </div>
        </.pane_column>
      <% end %>

      <!-- TODO: editor column is hand-rolled because its header merges
           pane-header with editor-header and has presence dots + publish
           buttons. Migrating cleanly requires a custom-header slot on
           pane_column that fully replaces the default title row.
           (Design plan archived.) -->
      <!-- Editor — a paper opens as a LIVE read-only block view in this same
           pane (convergence/papers-in-studio); every other doc type opens the
           field form via studio_editor_shell. The left structure pane + the
           Papers list pane (rendered above) stay visible either way. -->
      <%= cond do %>
        <% @editor_view == :paper -> %>
        <.studio_paper_view
          paper_doc={@paper_doc}
          paper_rev={@paper_rev}
          paper_html={@paper_html}
          paper_block_mode={@paper_block_mode}
          paper_edit_mode={@paper_edit_mode}
          shares_admin?={@shares_admin?}
          dataset={@dataset}
          streams={@streams}
          backlinks_linked={@backlinks_linked}
          backlinks_unlinked={@backlinks_unlinked}
          backlinks_open={@backlinks_open}
        />
        <% @editor_view == :sheet and @sheet_doc != nil -> %>
        <%!-- Sheet grid editor (Sheets M2). One LiveComponent owns the whole
              surface; `{:sheets_op,…}` deltas reach it via send_update. --%>
        <.live_component
          module={BarkparkWeb.Studio.SheetGrid}
          id={"sheet-grid-#{Content.published_id(@sheet_doc.doc_id)}"}
          doc={@sheet_doc}
          dataset={@dataset}
          is_draft={@editor_is_draft}
          user_id={@user_id}
          presence_topic={@sheet_presence_topic}
          presences={@sheet_presences}
        />
        <% @editor_view == :graph and @graph_doc != nil -> %>
        <%!-- Blast-radius graph pane (Phase 5). The GraphView LiveComponent
              owns the Cytoscape surface; its div carries the CONSTANT id
              "studio-graph" so navigation diffs the data-* attrs rather than
              remounting the hook and losing layout. The component derives the
              JSON payloads in update/2 (the change-tracking contract). --%>
        <.live_component
          module={BarkparkWeb.Studio.GraphView}
          id="studio-graph"
          doc={@graph_doc}
          graph={@graph_data}
        />
        <% @editor_view == :media_explorer -> %>
        <div
          id={"media-explorer-#{@nav_desk || "all"}"}
          class="editor-panel media-explorer-panel"
          style="flex: 1; display: flex; flex-direction: column; min-height: 0; overflow: hidden;"
        >
          <%!-- Scope-level share affordance for the media library (P6b). The
                media panel is hand-rolled (no document_header), so the Share
                button rides a thin header row. Admin-only; opens the panel with
                the media surface pre-selected. --%>
          <div :if={@shares_admin?} class="media-explorer-bar">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="shares-open"
              phx-value-surface="media"
              title="Share this workspace's media library"
              data-test-id="media-share"
            >
              <.icon name="share-2" size={14} /> Share media
            </button>
          </div>
          <div style="flex: 1; display: flex; min-height: 0; overflow: hidden;">
            <bp-asset-explorer
              dataset={@dataset}
              data-token={Map.get(assigns, :api_token_raw, "")}
              data-kind-filter={@media_kind_filter || "all"}
              data-open-path={(assigns[:scope_prefix] || "") <> "/d/#{@dataset}/studio/" <> Enum.join(@nav_path, "/")}
            />
          </div>
        </div>
        <% true -> %>
        <%!-- Per-document Classic <-> Beta editor (Exp-P3.2, barkpark-g2ql).
              Beta reuses the premium block editor over the SAME
              content["blocks"] Classic projects from. The toggle (a `.editor-mode-toggle`
              segmented control) re-projects, never converts. Beta is offered
              only for an Expectation-bearing document (`@editor_blocks != []`);
              other docs only ever see Classic. --%>
        <% beta_ok = @editor_doc != nil and @editor_blocks != [] %>
        <%= if beta_ok and @editor_mode == :beta do %>
          <div class="editor-panel" data-test-id="studio-doc-beta-editor">
            <.document_header dataset={@dataset} title={@editor_doc.title || "Untitled"}>
              <:status_pill>
                <span class={"badge badge-#{if @editor_is_draft, do: "draft", else: @editor_doc.status}"}>
                  <%= if @editor_is_draft, do: "draft", else: @editor_doc.status %>
                </span>
              </:status_pill>
              <:actions>
                <.editor_mode_toggle mode={@editor_mode} beta_ok={beta_ok} />
              </:actions>
            </.document_header>
            <div class="editor-with-preview">
              <div class="editor-body editor-panel-main bp-paper-body">
                <main class="bp-paper-shell bp-paper-surface" data-test-id="studio-doc-beta-shell">
                  <.paper_block_editor
                    slug={@editor_doc.doc_id}
                    blocks={@editor_blocks}
                    expected_fields={beta_expected_fields(@editor_schema, @editor_blocks)}
                    descriptors={beta_all_descriptors(@editor_schema, @editor_blocks)}
                    paper_rev={0}
                    dataset={@dataset}
                    api_token_raw={Map.get(assigns, :api_token_raw, "")}
                  />
                </main>
              </div>
            </div>
          </div>
        <% else %>
          <.studio_editor_shell
            editor_doc={@editor_doc}
            editor_schema={@editor_schema}
            editor_type={@editor_type}
            editor_form={@editor_form}
            editor_is_draft={@editor_is_draft}
            dataset={@dataset}
            validation_errors={@validation_errors}
            cross_violations={@cross_violations}
            save_status={@save_status}
            presences={@presences}
            parent_assigns={assigns}
            nav_group={@nav_group}
            content_preview_rendered={@content_preview_rendered}
            content_preview_visible={@content_preview_visible}
            diff_visible={@diff_visible}
            published_doc={@published_doc}
            doc_actions={DocActions.resolved_doc_actions(assigns)}
          >
            <:extra_actions>
              <.editor_mode_toggle :if={beta_ok} mode={@editor_mode} beta_ok={beta_ok} />
            </:extra_actions>
          </.studio_editor_shell>
        <% end %>
      <% end %>
      <!-- doc_actions flows through Registry.collect_doc_actions/1 with
           the host's `default_doc_actions/2` as :baseline. Plugins
           implementing resolve_doc_actions/2 can hide, reorder, or extend
           the editor-header action list. See Goal barkpark-cjs s4. -->

      <!-- E2 secondary editor (read-only) — sits in the layout flex
           row so it lands to the right of the primary editor pane. -->
      <.secondary_editor_card
        secondary_doc={@secondary_doc}
        secondary_schema={@secondary_schema}
        secondary_type={@secondary_type}
      />

      <!-- E2 secondary picker modal -->
      <.secondary_picker_modal
        show_secondary_picker={@show_secondary_picker}
        secondary_search={@secondary_search}
        secondary_candidates={@secondary_candidates}
      />

      <!-- E3 bulk publish floating action bar -->
      <.bulk_action_bar selected_doc_ids={@selected_doc_ids} />

      <!-- Schema-action ConfirmModal — gated by `confirm_modal` assign -->
      <%= if @confirm_modal do %>
        <% modal = @confirm_modal.action["modal"] || %{} %>
        <BarkparkWeb.Components.ConfirmModal.confirm_modal
          id="schema-action-confirm-modal"
          title={modal["title"] || @confirm_modal.action["label"]}
          body={modal["body"]}
          stage={@confirm_modal.stage}
          on_cancel="close-confirm-modal"
          on_confirm="confirm-modal-dryrun"
          on_real="confirm-modal-real"
        />
      <% end %>

      <!-- Profile + content modals; all gated by their show/picker assigns -->
      <.studio_modals
        show_profile={@show_profile}
        user_name={@user_name}
        user_color={@user_color}
        image_picker_field={@image_picker_field}
        uploads={@uploads}
        media_files={@media_files}
        ref_picker_field={@ref_picker_field}
        ref_search={@ref_search}
        ref_candidates={@ref_candidates}
        show_history={@show_history}
        revisions={@revisions}
        show_delete={@show_delete}
        delete_refs={@delete_refs}
        editor_doc={@editor_doc}
        show_discard={@show_discard}
      />

      <%!-- Unpublish blast-radius guard modal (Phase 5, gap #5). Lists the
            soon-to-dangle referencers (from Content.Graph.reverse_referencers/2
            — the arrayOf-aware inbound-edge query) by title + via_field. Mirrors
            the delete modal: a confirm proceeds with the real unpublish, with an
            optional "disconnect references first" branch. --%>
      <%= if @show_unpublish_guard do %>
        <div class="image-picker-overlay" phx-click="close-unpublish-guard"></div>
        <div class="delete-modal" data-test-id="unpublish-guard-modal">
          <div class="delete-modal-header">
            <span style="font-weight: 600; font-size: 16px;">Unpublish document</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close-unpublish-guard">x</button>
          </div>
          <div class="delete-modal-body">
            <div class="delete-warning">
              <p class="text-sm" style="margin-bottom: 12px;">
                <strong><%= @editor_doc && @editor_doc.title %></strong> is referenced by
                <strong><%= length(@unpublish_refs) %></strong> document<%= if length(@unpublish_refs) != 1, do: "s" %>.
                Unpublishing it will leave those references dangling:
              </p>
              <div class="delete-ref-list">
                <%= for ref <- @unpublish_refs do %>
                  <div class="delete-ref-item" data-test-id="unpublish-ref">
                    <span class="delete-ref-title"><%= ref.title || "Untitled" %></span>
                    <span class="delete-ref-meta"><%= ref.type %> / <%= ref.via_field %></span>
                  </div>
                <% end %>
              </div>
            </div>
            <div class="delete-modal-actions">
              <button class="btn btn-sm" phx-click="close-unpublish-guard">Cancel</button>
              <button
                class="btn btn-sm"
                phx-click="confirm-unpublish"
                phx-value-disconnect="true"
                data-test-id="confirm-unpublish-disconnect"
              >Disconnect references and unpublish</button>
              <button
                class="btn btn-destructive btn-sm"
                phx-click="confirm-unpublish"
                data-test-id="confirm-unpublish"
              >Unpublish anyway</button>
            </div>
          </div>
        </div>
      <% end %>

      <.shares_modal
        show={@show_shares}
        admin?={@shares_admin?}
        scope_prefill={@shares_scope_prefill}
        prefill_surfaces={@shares_prefill_surfaces}
        rows={@shares_rows}
        error={@shares_error}
      />

      <.item_share_popover
        show={@item_share_open}
        admin?={@shares_admin?}
        title={(@item_share && @item_share.title) || "this item"}
        links={@item_share_links}
        error={@item_share_error}
      />
    </.pane_layout>

    """
  end

  # The expected fields STILL recommendable for the current Beta block list,
  # rendered into `data-expected-fields` for the slash menu's EXPECTED group.
  # Returns [] when there is no schema/Expectation (no group shown).
  defp beta_expected_fields(%Barkpark.Content.SchemaDefinition{} = schema, blocks)
       when is_list(blocks) do
    Content.available_expected_fields(blocks, Content.resolve_expectation(schema), schema)
  end

  defp beta_expected_fields(_schema, _blocks), do: []

  # Full expected-field descriptors (incl. bound-and-at-cap) for the Properties
  # panel. [] when there is no schema/Expectation.
  defp beta_all_descriptors(%Barkpark.Content.SchemaDefinition{} = schema, blocks)
       when is_list(blocks) do
    Content.all_expected_fields(blocks, Content.resolve_expectation(schema), schema)
  end

  defp beta_all_descriptors(_schema, _blocks), do: []
end
