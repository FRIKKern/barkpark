defmodule BarkparkWeb.Studio.StudioLive.Components.PaperEditor do
  @moduledoc """
  The Beta paper-editor function-component cluster, split out of
  `BarkparkWeb.Studio.StudioLive.Components` to keep both modules well under the
  per-file token budget. Holds the Classic⇄Beta editor mode toggle
  (`editor_mode_toggle/1`), the Beta block editor (`paper_block_editor/1`), the
  Storage-Model-A Properties panel (`properties_panel/1`), and the
  per-block-type edit fields (`paper_block_fields/1`), plus the private helpers
  used exclusively by them (`beta_doc_stats/1`, `beta_node_text/1`,
  `descriptor_for/2`, `prop_label/2`, `prop_badge/1`, `prop_at_cap?/1`).

  Imported back into `StudioLive` (alongside `Components`) so the
  `<.paper_block_editor ...>` / `<.editor_mode_toggle ...>` call sites keep
  resolving verbatim. `Components.studio_paper_view/1` and
  `Components.studio_live_shell/1` render these same components, so `Components`
  imports this module. Behavior-preserving move.
  """
  use BarkparkWeb, :html

  alias Barkpark.PortableDoc.Projection
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

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

  # ── Paper block editor (function component) ─────────────────────────────────
  #
  # Edit mode for a block-backed paper. Renders per-block edit controls; each
  # control fires a `paper-*` event that maps to ONE DocPatchOp. The container
  # is keyed on the slug + rev so a jump or an op refreshes it cleanly. This is
  # plain assign-driven HTML (no stream) — the read-only View pane is the
  # streamed surface; this editor reads from `paper_doc.content["blocks"]`.
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

  # Phase-4 S2: may this surface host the continuous canvas? TRUE only for the
  # paper pane, whose canvas ops persist via `paper-ops` → `paper_doc`. The Beta
  # per-document editor (which persists via `editor_doc`/document_op) leaves this
  # at its FALSE default, so the canvas never mounts where its ops can't land —
  # the canvas flag stays gated to the one surface whose persist path is wired.
  attr(:canvas_eligible, :boolean, default: false)

  def paper_block_editor(assigns) do
    # Gate the bound/free split on having descriptors: only the Beta editor (with
    # an Expectation) shows the Properties panel. The paper pane passes
    # descriptors=[] ⇒ properties?=false ⇒ free == all blocks, panel self-hides.
    properties? = assigns.descriptors != []

    {bound, free} =
      if properties?, do: Projection.partition(assigns.blocks), else: {[], assigns.blocks}

    # Phase-4 S2: the continuous-canvas flag. DEFAULT FALSE — when false the
    # body renders the EXISTING per-block list verbatim (the `else` arm below).
    # When true, the free-block list is partitioned into maximal prose runs and
    # each run renders as ONE <bp-paper-canvas>; non-prose blocks stay on their
    # existing per-block widgets between runs. Computed once here so the template
    # branch is a single `if @canvas_on?`. ALSO gated on `canvas_eligible` (the
    # paper pane only) so a flag-on canvas never mounts in the Beta document
    # editor, where `paper-ops` (→ paper_doc) is the wrong persist path.
    canvas_on? = PaperCanvas.paper_canvas_enabled?() and assigns.canvas_eligible

    assigns =
      assigns
      |> assign(:bound_blocks, bound)
      |> assign(:free_blocks, free)
      |> assign(:last_index, length(free) - 1)
      |> assign(:doc_stats, beta_doc_stats(assigns.blocks))
      |> assign(:canvas_on?, canvas_on?)
      |> assign(
        :segments,
        if(canvas_on?, do: index_segments(PaperCanvas.partition_runs(free)), else: [])
      )

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

      <%= if @canvas_on? do %>
        <%!-- Phase-4 S2 (flag ON) — the continuous-canvas render. The free-block
              list was partitioned into maximal contiguous PROSE runs upstream
              (@segments). Each {:run, blocks} becomes ONE <bp-paper-canvas> in a
              phx-update="ignore" wrapper KEYED BY THE RUN'S FIRST block id (a
              stable run id), so the canvas survives re-renders in place and a
              mid-edit re-partition only re-keys the affected run. The run's
              blocks ride a data-canvas-blocks attribute the BarkparkPaperCanvas
              hook reads into `el.blocks`. Each {:block, b} (a non-prose run
              boundary) renders via the UNCHANGED per-block widget below
              (edit_block/1) — same toolbar, same fields, same ops. The
              data-expected-fields carrier above stays OUTSIDE every ignore
              wrapper (it re-renders on each block-list change). --%>
        <%= for segment <- @segments do %>
          <%= case segment do %>
            <% {:run, run_blocks} -> %>
              <.canvas_run run_blocks={run_blocks} />
            <% {:block, block, index} -> %>
              <.edit_block
                block={block}
                index={index}
                last_index={@last_index}
                dataset={@dataset}
                api_token_raw={@api_token_raw}
              />
          <% end %>
        <% end %>
      <% else %>
        <%!-- Flag OFF (default): the EXISTING per-block list render, verbatim and
              unmoved. This is the shipped path — byte-identical to before S2. --%>
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
      <% end %>

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

  # Phase-4 S2: stamp each `{:block, b}` segment with its index in the FREE-block
  # list (the same index the OFF-path :for would assign), so the move ▲/▼ buttons
  # disable at the real body boundaries. Runs pass through unchanged. The running
  # counter advances by `length(run)` across a `{:run, …}` so the index of the
  # NEXT non-prose block stays aligned with its position among the free blocks
  # (the move-block handler resolves the index by id; this only drives `disabled`).
  defp index_segments(segments) do
    {out, _i} =
      Enum.map_reduce(segments, 0, fn
        {:run, blocks}, i -> {{:run, blocks}, i + length(blocks)}
        {:block, block}, i -> {{:block, block, i}, i + 1}
      end)

    out
  end

  # Phase-4 S2 (flag ON): ONE <bp-paper-canvas> over a maximal prose run. The
  # phx-update="ignore" wrapper is KEYED BY THE RUN'S FIRST block id (a stable
  # run id) so LiveView never re-diffs the canvas's internal DOM (caret/selection
  # preserved) and a mid-edit re-partition only re-keys the affected run. The
  # run's blocks ride `data-canvas-blocks` (Jason-encoded); the BarkparkPaperCanvas
  # hook reads it into `el.blocks` and forwards the canvas's bp-canvas-ops as a
  # `paper-ops` pushEvent. The <bp-paper-canvas> element + run-convert projector
  # already ship in the bundle (S0+S1) — this only mounts it.
  attr(:run_blocks, :list, required: true)

  def canvas_run(assigns) do
    assigns = assign(assigns, :run_id, PaperCanvas.run_id(assigns.run_blocks))

    ~H"""
    <div
      phx-update="ignore"
      id={"paper-canvas-" <> @run_id}
      phx-hook="BarkparkPaperCanvas"
      class="bp-paper-edit-canvas"
      data-canvas-blocks={Jason.encode!(@run_blocks)}
      data-test-id="paper-canvas-run"
    >
      <bp-paper-canvas></bp-paper-canvas>
    </div>
    """
  end

  # The per-block edit row (toolbar + type-aware fields). Extracted verbatim from
  # paper_block_editor/1's block :for so BOTH the flag-OFF list render and the
  # flag-ON non-prose run-boundary render call the SAME markup — the OFF path is
  # byte-identical (a function component inlines the same ~H output). `index` /
  # `last_index` drive the move ▲/▼ disabled state exactly as before.
  attr(:block, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:last_index, :integer, required: true)
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")

  def edit_block(assigns) do
    ~H"""
    <div
      class="bp-paper-edit-block"
      data-edit-block-id={Map.get(@block, "id")}
      data-block-type={Map.get(@block, "type")}
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
        <span class="bp-paper-edit-kind"><%= Map.get(@block, "type") %></span>
        <span class="bp-paper-edit-actions">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            title="Move up"
            phx-click="paper-move-block"
            phx-value-id={Map.get(@block, "id")}
            phx-value-dir="up"
            disabled={@index == 0}
            data-test-id="paper-move-up"
          >▲</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            title="Move down"
            phx-click="paper-move-block"
            phx-value-id={Map.get(@block, "id")}
            phx-value-dir="down"
            disabled={@index == @last_index}
            data-test-id="paper-move-down"
          >▼</button>
          <button
            type="button"
            class="btn btn-destructive btn-sm"
            title="Delete block"
            phx-click="paper-delete-block"
            phx-value-id={Map.get(@block, "id")}
            data-test-id="paper-delete-block"
          >×</button>
        </span>
      </div>
      <.paper_block_fields block={@block} dataset={@dataset} api_token_raw={@api_token_raw} />
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
end
