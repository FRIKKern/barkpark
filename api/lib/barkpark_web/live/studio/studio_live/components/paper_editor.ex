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

  import BarkparkWeb.StudioComponents.Controls, only: [bp_select: 1]
  # sup-w5 — reuse the classic editor's server-truth halt banner (charter D5/D6:
  # the editor never authors halt copy, it mirrors the server reason verbatim).
  import BarkparkWeb.StudioComponents.Editor, only: [paper_halt_banner: 1]

  import BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor,
    only: [technical_block_editor: 1]

  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.{Projection, Render, TaskResolver}
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias Phoenix.LiveView.JS

  # t9 — the task block types whose boundary widget paints a LIVE preview
  # (mirrors TaskResolver's @snapshot_types + @detail_type). These are the fleet
  # blocks that can carry a `query` and thus need the session-scoped preview map
  # (loading state until the rows resolve).
  @task_preview_types ~w(tasks task-list task-board roadmap task-detail)

  # pdd-t8 — the FULL non-prose fleet whose boundary widget paints the reader's own
  # HTML (rule 3: one producer, byte for byte). Beyond the query-carrying task types
  # above, these are the STATIC component blocks that render directly from their own
  # carried data (no query, no scope) — cards / pipeline / notes / status-legend /
  # form / asciicast. `diagram` is absent: it rides its editable bpDiagram atom in a
  # canvas run, not a boundary widget. Keep aligned with shared/paper.ex:
  # @fleet_render_types (the canvas-node twin of this boundary paint).
  #
  # t12a NOTE — as of the pdd-t12 partition FLIP, a top-level fleet block in the
  # flag-ON PAPER PANE (canvas_eligible) no longer reaches this boundary widget: it is
  # now CANVAS-ELIGIBLE (paper_canvas.ex:@canvas_fleet_types), so partition_runs folds
  # it INTO a `{:run, …}` and it paints IN-CANVAS via the `bpFleet` node-view +
  # push_block_renders' `bp:block-html` (D8), never through `edit_block` here. The
  # boundary widget (edit_block → task_block_preview, below) renders ONLY for the
  # `{:block, …}` boundaries the flag-ON canvas path emits, and after the flip those are
  # exclusively the nested-structure fields (composite / arrayOf / …), never a fleet
  # kind — so this fleet paint is now DORMANT in the paper pane. It is deliberately KEPT
  # (not deleted): the widget + these types stay as retained infra whose contract is
  # still proven directly, and legacy retirement is a wave-4/human step, out of scope.
  @fleet_preview_types @task_preview_types ++
                         ~w(notes cards pipeline status-legend form questionnaire asciicast)

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
  # spd-w18 — the document's REAL type. This editor is opened by every blocks-doc
  # type (paper today, session too), and the empty-body sentence below used to
  # tell a session's author "This paper has no body blocks yet". Default "paper"
  # keeps the Beta document-editor call site (which passes none) unchanged.
  attr(:doc_type, :string, default: "paper")
  attr(:paper_rev, :integer, default: 0)
  attr(:document_rev, :string, default: nil)
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")
  attr(:scope_prefix, :string, default: "")
  attr(:picker_browse, :boolean, default: true)
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

  # t9 — live task-block previews (block_id ⇒ preview entry from
  # TaskResolver.preview/2), display-only rows the flag-ON boundary widgets
  # paint via task_block_preview/1. The flag-OFF list render never reads it.
  attr(:task_previews, :map, default: %{})
  attr(:paper_links, :map, default: %{})
  # sup-w5 — the socket-owned save mirror (Shared.Paper computes both on every
  # write). `save_status` drives the footer echo; `paper_halt` (a server reason
  # string or nil) raises the shared halt banner near the top of the editor.
  # Both default calm so the Beta document-editor call site (which passes
  # neither) keeps the quiet, unhalted footer.
  attr(:save_status, :string, default: "")
  attr(:paper_halt, :string, default: nil)

  def paper_block_editor(assigns) do
    assigns =
      if assigns.canvas_eligible and assigns.doc_type == "paper",
        do: assign(assigns, :blocks, Barkpark.Content.ensure_block_ids(assigns.blocks)),
        else: assigns

    # Gate the bound/free split on having descriptors: only the Beta editor (with
    # an Expectation) shows the Properties panel. The paper pane passes
    # descriptors=[] ⇒ properties?=false ⇒ free == all blocks, panel self-hides.
    properties? = assigns.descriptors != []

    {bound, free} =
      if properties?, do: Projection.partition(assigns.blocks), else: {[], assigns.blocks}

    # Phase-4 S2: the continuous-canvas flag. DEFAULT TRUE (the D7/D9 cutover) —
    # only the explicit opt-out `BARKPARK_PAPER_CANVAS=0/false` is false, and when
    # false the body renders the EXISTING per-block list verbatim (the `else` arm
    # below).
    # When true, the free-block list is partitioned into maximal prose runs and
    # each run renders as ONE <bp-paper-canvas>; non-prose blocks stay on their
    # existing per-block widgets between runs. Computed once here so the template
    # branch is a single `if @canvas_on?`. ALSO gated on `canvas_eligible` (the
    # paper pane only) so a flag-on canvas never mounts in the Beta document
    # editor, where `paper-ops` (→ paper_doc) is the wrong persist path.
    canvas_on? = PaperCanvas.paper_canvas_enabled?() and assigns.canvas_eligible

    segments = if canvas_on?, do: index_segments(PaperCanvas.partition_runs(free)), else: []

    assigns =
      assigns
      |> assign(:paper_doc_key, "#{assigns.dataset}:#{assigns.doc_type}:#{assigns.slug}")
      |> assign(:bound_blocks, bound)
      |> assign(:free_blocks, free)
      |> assign(:last_index, length(free) - 1)
      |> assign(:doc_stats, beta_doc_stats(assigns.blocks))
      |> assign(:canvas_on?, canvas_on?)
      |> assign(:segments, segments)
      # pdd-t20c: the doc's constraint vocabulary, JSON-encoded for the canvas host
      # (only for docs that carry locked blocks — additive), + the ghost slots the
      # canvas branch interleaves between runs (the t13 featured-placeholder pattern
      # generalized). Both are [] / nil for a non-doctrine paper, so its render is
      # byte-untouched.
      |> assign(:paper_constraints, doc_constraints(free))
      |> assign(:render_items, if(canvas_on?, do: interleave_ghosts(segments, free), else: []))

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
      data-paper-doc-key={@paper_doc_key}
      data-paper-rev={@doc_type == "paper" && @paper_rev}
      data-document-rev={@doc_type != "paper" && @document_rev}
    >
      <%!-- sup-w5 — server-truth write-halt mirror. `@paper_halt` is nil on a
            clean edit (nothing renders); a `{:error, {:halted, reason}}` write
            stashes the reason and this banner shows it VERBATIM (charter D5/D6),
            the same component the classic editor raises. --%>
      <.paper_halt_banner reason={@paper_halt} />

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

      <%!-- Right-click block context-menu host. A zero-layout hidden carrier for
            the BarkparkPaperContextMenu hook (defined in root.html.heex). It is a
            SEPARATE hook because BarkparkPaperSortable already owns this editor
            container and LiveView allows one hook per element. On `contextmenu`
            over a [data-edit-block-id] block the hook opens a fixed singleton
            menu (appended to <body>) whose items push the SAME paper-move-block /
            paper-delete-block events as the hover toolbar; off a block the native
            browser menu is left alone. No layout impact at rest. --%>
      <div
        id="bp-paper-context-menu-host"
        phx-hook="BarkparkPaperContextMenu"
        data-test-id="bp-paper-context-menu-host"
        hidden
      ></div>

      <.properties_panel
        rows={Enum.map(@bound_blocks, fn b -> {b, descriptor_for(@descriptors, b)} end)}
        unbound={Enum.filter(@descriptors, fn d -> d.count == 0 end)}
        dataset={@dataset}
        api_token_raw={@api_token_raw}
        scope_prefix={@scope_prefix}
        picker_browse={@picker_browse}
        doc_type={@doc_type}
        paper_rev={@paper_rev}
        document_rev={@document_rev}
        root_slug={@slug}
        doc_key={@paper_doc_key}
        canvas_enabled={@canvas_on?}
        paper_links={@paper_links}
      />

      <%!-- spd-w18 — an honest empty state names WHICH document is empty and
            WHAT it is. It used to read "This paper has no body blocks yet" to
            someone editing a SESSION (sessions take this identical path), with
            no id to tell one empty document from another, painted in the same
            faint grey the owner read as inert chrome (contrast raised in
            root.html.heex). --%>
      <p :if={@free_blocks == []} class="bp-paper-editor-empty">
        This {@doc_type} (<code>{@slug}</code>) has no body blocks yet. Add one below.
      </p>

      <%= if @canvas_on? do %>
        <%!-- Phase-4 S2 (flag ON) — the continuous-canvas render. The free-block
              list was partitioned into maximal contiguous PROSE runs upstream
              (@segments). Each {:run, blocks} becomes ONE <bp-paper-canvas> in a
              phx-update="ignore" wrapper KEYED BY THE PAPER'S SLUG + THE RUN'S
              ORDINAL (stable within a paper, unique across papers), so the
              canvas survives re-renders in place, a mid-edit re-partition only
              re-keys the affected run, and a paper→paper jump remounts fresh
              instead of morphdom reusing the old paper's wrapper. The run's
              blocks ride a data-canvas-blocks attribute the BarkparkPaperCanvas
              hook reads into `el.blocks`. Each {:block, b} (a non-prose run
              boundary) renders via the UNCHANGED per-block widget below
              (edit_block/1) — same toolbar, same fields, same ops. The
              data-expected-fields carrier above stays OUTSIDE every ignore
              wrapper (it re-renders on each block-list change). --%>
        <%= for item <- @render_items do %>
          <%= case item do %>
            <% {:seg, {:run, run_blocks, run_ordinal, locked_tail}} -> %>
              <.canvas_run
                slug={@slug}
                run_blocks={run_blocks}
                run_ordinal={run_ordinal}
                locked_tail={locked_tail}
                constraints={@paper_constraints}
                dataset={@dataset}
                api_token_raw={@api_token_raw}
                scope_prefix={@scope_prefix}
                picker_browse={@picker_browse}
                doc_key={@paper_doc_key}
                paper_rev={@doc_type == "paper" && @paper_rev}
                document_rev={@doc_type != "paper" && @document_rev}
              />
            <% {:seg, {:block, block, index}} -> %>
              <.edit_block
                block={block}
                index={index}
                last_index={@last_index}
                prev_locked={
                  index > 0 and
                    Map.get(Enum.at(@free_blocks, index - 1) || %{}, "locked") == true
                }
                dataset={@dataset}
                api_token_raw={@api_token_raw}
                scope_prefix={@scope_prefix}
                picker_browse={@picker_browse}
                task_previews={@task_previews}
                paper_links={@paper_links}
                doc_type={@doc_type}
                paper_rev={@paper_rev}
                document_rev={@document_rev}
                root_slug={@slug}
                doc_key={@paper_doc_key}
                canvas_enabled={@canvas_on?}
              />
            <% {:ghosts, ghosts, anchor_id} -> %>
              <.ghost_slots_group ghosts={ghosts} anchor_id={anchor_id} />
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
          data-block-locked={Map.get(block, "locked") == true && "true"}
        >
          <div class="bp-paper-edit-toolbar">
            <%!-- pdd-t2: a locked block's grip is INERT — no draggable, no
                  data-drag-grip, a template hint instead of "Drag to reorder"
                  (same contract as edit_block/1 below). --%>
            <span
              class="bp-paper-drag-grip"
              data-drag-grip={Map.get(block, "locked") != true}
              draggable={Map.get(block, "locked") != true && "true"}
              title={
                if Map.get(block, "locked") == true,
                  do: "Part of the document template",
                  else: "Drag to reorder"
              }
              aria-label={
                if Map.get(block, "locked") == true,
                  do: "Part of the document template",
                  else: "Drag to reorder block"
              }
              tabindex={Map.get(block, "locked") == true && "0"}
              data-test-id="paper-drag-grip"
            >⋮⋮</span>
            <span class="bp-paper-edit-kind"><%= Map.get(block, "type") %></span>
            <span class="bp-paper-edit-actions">
              <%!-- Doctrine template lock (pdd-t2): a locked mandated block can't
                    be moved or deleted, so its ▲▼/× controls are HIDDEN and a calm
                    lock note stands in their place — chrome, never an error. The
                    server backstops it either way (patch.ex). The block BELOW a
                    locked block disables ▲ (moving it up would displace the
                    locked block — an affordance the server would reject). --%>
              <button
                :if={Map.get(block, "locked") != true}
                type="button"
                class="btn btn-ghost btn-sm"
                title="Move up"
                phx-click="paper-move-block"
                phx-value-id={Map.get(block, "id")}
                phx-value-dir="up"
                disabled={
                  index == 0 or
                    Map.get(Enum.at(@free_blocks, index - 1) || %{}, "locked") == true
                }
                data-test-id="paper-move-up"
              >▲</button>
              <button
                :if={Map.get(block, "locked") != true}
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
                :if={Map.get(block, "locked") != true}
                type="button"
                class="btn btn-destructive btn-sm"
                title="Delete block"
                phx-click="paper-delete-block"
                phx-value-id={Map.get(block, "id")}
                data-test-id="paper-delete-block"
              >×</button>
              <span
                :if={Map.get(block, "locked") == true}
                class="bp-paper-lock-note"
                title="Part of the document template"
                data-test-id="paper-locked-note"
              >🔒 Locked</span>
            </span>
          </div>
          <.paper_block_fields
            block={block}
            dataset={@dataset}
            api_token_raw={@api_token_raw}
            scope_prefix={@scope_prefix}
            picker_browse={@picker_browse}
            doc_type={@doc_type}
            paper_rev={@paper_rev}
            document_rev={@document_rev}
            root_slug={@slug}
            doc_key={@paper_doc_key}
            canvas_enabled={@canvas_on?}
            paper_links={@paper_links}
          />
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
          <.bp_select name="block-type" options={add_block_options()} />
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
        <%!-- sup-w5 — the save affordance now ECHOES the socket-owned
              @save_status instead of a hardcoded "✓ Auto-saved" that lied
              through "Save failed"/plugin halts. role=status + aria-live=polite
              so assistive tech announces each state change (accessibility parity
              with the classic editor's save-status region). The ✓ affix is kept
              ONLY for the calm "Auto-saved" token; every other state (incl. the
              empty pre-write open) shows the raw server text. --%>
        <span
          class="bp-paper-footer-save"
          role="status"
          aria-live="polite"
          data-test-id="bp-paper-footer-save"
        ><%= save_status_label(@save_status) %></span>
      </footer>
    </div>
    """
  end

  # sup-w5 — footer save label. The calm token keeps its premium ✓ affix; every
  # other server state ("Save failed", the empty pre-write open, …) is echoed
  # VERBATIM so the footer can never lie about a failed or vetoed write.
  defp save_status_label("Auto-saved"), do: "✓ Auto-saved"
  defp save_status_label(status) when is_binary(status), do: status
  defp save_status_label(_), do: ""

  # The `+ Add block` menu, grouped by optgroup so the (long) list of creatable
  # portable-doc block types stays scannable. Each value resolves to
  # `default_block/2` and is applied through the paper-add-block → paper_op
  # pipeline. `{group, [{value, label}, …]}` tuples render as `<optgroup>`s via
  # `StudioComponents.Controls.bp_select/1`.
  defp add_block_options do
    [
      {"Text",
       [
         {"paragraph", "Paragraph"},
         {"heading", "Heading"},
         {"list", "List"},
         {"callout", "Callout"},
         {"code", "Code"},
         {"blockquote", "Blockquote"},
         {"divider", "Divider"},
         {"section", "Section"},
         {"steps", "Steps"}
       ]},
      {"Article chrome",
       [
         {"eyebrow", "Eyebrow"},
         {"byline", "Byline"},
         {"ingress", "Ingress"},
         {"pullquote", "Pullquote"}
       ]},
      {"Visual",
       [
         {"diagram", "Diagram"},
         {"equation", "Equation"},
         {"route", "Route"},
         {"toc", "Table of contents"},
         {"criteria-progress", "Criteria progress"},
         {"gauge-list", "Gauge list"}
       ]},
      {"Technical",
       [
         {"diff", "Diff"},
         {"filetree", "File tree"},
         {"footnote", "Footnotes"},
         {"code-tabs", "Code tabs"},
         {"api-endpoint", "API endpoint"}
       ]},
      {"Basic fields",
       [
         {"field-string", "String"},
         {"field-slug", "Slug"},
         {"field-text", "Long text"},
         {"field-boolean", "Boolean"},
         {"field-select", "Select"},
         {"field-datetime", "Date & time"},
         {"field-color", "Color"},
         {"field-number", "Number"}
       ]},
      {"Media & reference",
       [
         {"field-image", "Image"},
         {"field-reference", "Reference"},
         {"video", "Video"}
       ]},
      {"Structured",
       [
         {"composite", "Composite"},
         {"arrayOf", "Array of"},
         {"codelist", "Code list"},
         {"localizedText", "Localized text"}
       ]}
    ]
  end

  # Phase-4 S2: stamp each `{:block, b}` segment with its index in the FREE-block
  # list (the same index the OFF-path :for would assign), so the move ▲/▼ buttons
  # disable at the real body boundaries. The running counter advances by
  # `length(run)` across a `{:run, …}` so the index of the NEXT non-prose block
  # stays aligned with its position among the free blocks (the move-block handler
  # resolves the index by id; this only drives `disabled`).
  #
  # Bug #1a: ALSO stamp each `{:run, …}` with its run ORDINAL (0, 1, 2 … over runs
  # in document order) via PaperCanvas.with_run_ordinals/1 — the SAME helper
  # push_canvas_echo uses — so the wrapper id and the echo are keyed identically.
  # The two counters are independent: the free-block index (for ▲/▼ disabled) and
  # the run ordinal (for the stable wrapper id). We compute the run ordinal first,
  # then thread the free-block index across the now-ordinal-tagged segments.
  defp index_segments(segments) do
    {out, _i} =
      segments
      |> PaperCanvas.with_run_ordinals()
      |> Enum.map_reduce(0, fn
        {:run, blocks, ordinal}, i -> {{:run, blocks, ordinal}, i + length(blocks)}
        {:block, block}, i -> {{:block, block, i}, i + 1}
      end)

    annotate_locked_tails(out)
  end

  # pdd-t2: stamp each `{:run, …}` with whether the segment DIRECTLY AFTER it is
  # a template-locked boundary block (the locked featured image right after the
  # title run is THE case — `image` is not canvas-eligible, so the locked title
  # rides alone in run 0 and the run's transaction veto cannot see the featured
  # block a run-growing edit would displace). The flag rides to the canvas as
  # `data-locked-tail`, where locks.js vetoes run GROWTH. Two runs are never
  # adjacent (runs are maximal), so only the run→block seam needs a look-ahead.
  defp annotate_locked_tails([{:run, blocks, ordinal} | rest]) do
    locked_tail =
      case rest do
        [{:block, block, _index} | _] -> Map.get(block, "locked") == true
        _ -> false
      end

    [{:run, blocks, ordinal, locked_tail} | annotate_locked_tails(rest)]
  end

  defp annotate_locked_tails([segment | rest]), do: [segment | annotate_locked_tails(rest)]
  defp annotate_locked_tails([]), do: []

  # ── pdd-t20c: the constraint vocabulary in the editor (ghost slots + the stamp) ──

  # The JSON constraint payload for the canvas host — ONLY for docs that already
  # carry locked blocks (a doctrine paper). A plain paper (no locked title) gets
  # nil, so the `data-canvas-constraints` attribute renders empty and the WC vetoes
  # nothing — byte-untouched (D3).
  defp doc_constraints(blocks) when is_list(blocks) do
    if doctrine_paper?(blocks), do: Jason.encode!(Template.client_declarations()), else: nil
  end

  defp doc_constraints(_), do: nil

  defp doctrine_paper?(blocks) do
    Enum.any?(blocks, fn b -> is_map(b) and Map.get(b, "locked") == true end)
  end

  # The GHOST SLOTS to offer: each OPTIONAL declaration whose kind is ABSENT from the
  # doc AND whose materialization is provably save-safe right now (inserting after
  # its anchor would not displace a locked block — so the affordance can NEVER
  # produce a save error, doctrine rule 5). Only for a doctrine paper. The pure twin
  # of canvas/constraints.js ghostSlots, gated by the same "carries locked" rule as
  # the stamp so a non-doctrine paper offers nothing.
  @doc false
  def ghost_slots(blocks) when is_list(blocks) do
    if doctrine_paper?(blocks) do
      present = MapSet.new(blocks, &block_role/1)

      Template.client_declarations()
      |> Enum.filter(fn d ->
        d["presence"] == "optional" and not MapSet.member?(present, d["kind"]) and
          materialize_safe?(blocks, get_in(d, ["position", "after"]))
      end)
      |> Enum.map(fn d ->
        %{
          kind: d["kind"],
          role: d["kind"],
          locked: d["locked"] == true,
          after: get_in(d, ["position", "after"])
        }
      end)
    else
      []
    end
  end

  def ghost_slots(_), do: []

  # Materializing a ghost inserts its block DIRECTLY AFTER the block carrying the
  # anchor role. That is save-safe iff the block currently occupying that next slot
  # is NOT locked (inserting there would otherwise displace a locked block and the
  # server rejects it — check_locked_placement). Absent anchor / absent next block
  # ⇒ safe (nothing to displace).
  defp materialize_safe?(blocks, nil), do: is_list(blocks)

  defp materialize_safe?(blocks, anchor_role) do
    case Enum.find_index(blocks, fn b -> block_role(b) == anchor_role end) do
      nil ->
        false

      idx ->
        case Enum.at(blocks, idx + 1) do
          nil -> true
          next -> Map.get(next, "locked") != true
        end
    end
  end

  defp block_role(b) when is_map(b), do: Map.get(b, "role")
  defp block_role(_), do: nil

  defp title_block_id(blocks) do
    case Enum.find(blocks, fn b -> block_role(b) == "title" end) do
      %{"id" => id} -> id
      _ -> nil
    end
  end

  defp run_contains_role?({:run, blocks, _ordinal, _locked_tail}, role),
    do: Enum.any?(blocks, fn b -> block_role(b) == role end)

  defp run_contains_role?({:block, block, _index}, role), do: block_role(block) == role
  defp run_contains_role?(_, _), do: false

  # Interleave the ghost slots into the segment stream: wrap every segment as
  # `{:seg, segment}`, and place the whole ghost group RIGHT AFTER the first segment
  # that carries the anchor (the "title" run). The group carries the anchor block id
  # so a click materializes the block after the title via the op path. A paper with
  # no ghosts renders the segments verbatim (byte-untouched).
  defp interleave_ghosts(segments, free) do
    case ghost_slots(free) do
      [] ->
        Enum.map(segments, &{:seg, &1})

      ghosts ->
        anchor_id = title_block_id(free)

        {items, _placed} =
          Enum.map_reduce(segments, false, fn seg, placed ->
            if not placed and run_contains_role?(seg, "title") do
              {[{:seg, seg}, {:ghosts, ghosts, anchor_id}], true}
            else
              {[{:seg, seg}], placed}
            end
          end)

        List.flatten(items)
    end
  end

  # Phase-4 S2 (flag ON): ONE <bp-paper-canvas> over a maximal prose run. The
  # phx-update="ignore" wrapper is KEYED BY THE PAPER'S SLUG + THE RUN'S ORDINAL
  # (Bug #1a: the ordinal is a STABLE run id that survives a leading-block change,
  # NOT the mutable first-block id; Bug #1c: the slug namespaces the id per paper —
  # a bare ordinal collides across papers, and morphdom's global keyed-node reuse
  # then TRANSPLANTS the old paper's ignore wrapper into the new paper's editor on
  # a patch-navigation, leaving the previous paper's canvas on screen) so LiveView
  # never re-diffs the canvas's internal DOM (caret/selection preserved), a
  # leading-block delete keeps the run at the same ordinal → no remount, and a
  # paper→paper jump changes every wrapper id → fresh mount → fresh seed. The
  # run's blocks ride `data-canvas-blocks` (Jason-encoded); the BarkparkPaperCanvas
  # hook reads it into `el.blocks` and forwards the canvas's bp-canvas-ops as a
  # `paper-ops` pushEvent. The <bp-paper-canvas> element + run-convert projector
  # already ship in the bundle (S0+S1) — this only mounts it. The matching echo in
  # push_canvas_echo keys each run by the SAME slug+ordinal so it routes to this
  # wrapper.
  attr(:slug, :string, required: true)
  attr(:run_blocks, :list, required: true)
  attr(:run_ordinal, :integer, required: true)
  # pdd-t2: true when the block DIRECTLY AFTER this run is template-locked (the
  # featured image boundary after the title run). Rides to the canvas WC as
  # data-locked-tail via the hook; locks.js then vetoes any run GROWTH (a new
  # node in this run would displace the locked follower — the server invariant
  # would reject the resulting insert anyway; the veto keeps it a calm no-op).
  attr(:locked_tail, :boolean, default: false)
  # The picker FETCH-SCOPE for any field-image / field-reference riding this run. The
  # canvas mounts those pickers (bp-media-picker / bp-reference-picker) as control-atom
  # node-views; each WC fetches its own data over HTTP scoped by a dataset (+ a bearer
  # token for media uploads). We carry the SAME scope the per-block picker render uses
  # (the `field-image` / `field-reference` clauses of `paper_block_fields/1` —
  # `dataset` + `data-token={@api_token_raw}`) on the canvas
  # HOST element via data-dataset / data-token, so a picker inside the run fetches /
  # uploads exactly as it does in the per-block path. A run with NO picker carries them
  # harmlessly (the canvas reads them only when mounting a picker node-view).
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")
  attr(:scope_prefix, :string, default: "")
  attr(:picker_browse, :boolean, default: true)
  # pdd-t20c: the doc's constraint vocabulary (JSON-encoded
  # Template.paper_declarations()), stamped only for docs that carry locked blocks —
  # additive. Rides to the canvas WC as data-constraints via the hook; the WC's
  # filterTransaction then vetoes a cardinality/relative-order violation calmly.
  attr(:constraints, :string, default: nil)
  attr(:doc_key, :string, required: true)
  attr(:paper_rev, :any, default: nil)
  attr(:document_rev, :string, default: nil)
  attr(:container_id, :string, default: nil)
  attr(:container_kind, :string, default: nil)
  attr(:container_row_id, :string, default: nil)

  def canvas_run(assigns) do
    assigns = assign(assigns, :run_id, PaperCanvas.run_id(assigns.slug, assigns.run_ordinal))

    ~H"""
    <div
      phx-update="ignore"
      id={"paper-canvas-" <> @run_id}
      phx-hook="BarkparkPaperCanvas"
      class="bp-paper-edit-canvas"
      data-canvas-blocks={Jason.encode!(@run_blocks)}
      data-canvas-dataset={@dataset}
      data-canvas-token={@api_token_raw}
      data-canvas-scope-prefix={@scope_prefix}
      data-canvas-picker-browse={@picker_browse && "true" || "false"}
      data-canvas-locked-tail={@locked_tail && "true"}
      data-canvas-constraints={@constraints}
      data-paper-doc-key={@doc_key}
      data-paper-rev={@paper_rev}
      data-document-rev={@document_rev}
      data-paper-container-id={@container_id}
      data-paper-container-run={@container_id && @run_ordinal}
      data-paper-container-kind={@container_kind}
      data-paper-container-row-id={@container_row_id}
      data-test-id="paper-canvas-run"
    >
      <bp-paper-canvas></bp-paper-canvas>
    </div>
    """
  end

  # pdd-t20c: the GHOST SLOTS for a doctrine paper's absent optional blocks — the
  # t13 featured-placeholder pattern GENERALIZED. Each ghost is a calm, evergreen,
  # keyboard-reachable affordance sitting in its enforced place (after the title
  # run). A click MATERIALIZES the real block after the anchor via the SAME op path
  # the canvas uses (paper-materialize-slot → insert-after) — the ghost itself is
  # LiveView-rendered chrome that NEVER enters the PM doc or the save baseline (D5):
  # an untouched paper saves zero ops. Only save-safe ghosts are offered
  # (`ghost_slots/1` gates on non-displacement), so a click can never error (rule 5).
  attr(:ghosts, :list, required: true)
  attr(:anchor_id, :string, default: nil)

  def ghost_slots_group(assigns) do
    ~H"""
    <div class="bp-paper-ghost-slots" data-test-id="paper-ghost-slots">
      <button
        :for={g <- @ghosts}
        type="button"
        class={"bp-paper-ghost-slot bp-paper-ghost-#{g.kind}"}
        phx-click="paper-materialize-slot"
        phx-value-kind={g.kind}
        phx-value-after={@anchor_id}
        data-test-id={"paper-ghost-#{g.kind}"}
        aria-label={ghost_aria_label(g.kind)}
      >
        <span class="bp-paper-ghost-icon" aria-hidden="true"><%= ghost_glyph(g.kind) %></span>
        <span class="bp-paper-ghost-body">
          <span class="bp-paper-ghost-label"><%= ghost_label(g.kind) %></span>
          <span class="bp-paper-ghost-hint"><%= ghost_hint(g.kind) %></span>
        </span>
      </button>
    </div>
    """
  end

  # Calm copy for each ghost kind — the affordance is chrome, not an error.
  defp ghost_label("featured"), do: "Add a featured image"
  defp ghost_label("ingress"), do: "Ingress — the lead paragraph"
  defp ghost_label(kind), do: "Add #{kind}"

  defp ghost_hint("featured"), do: "Optional · sits above the article, after the title"
  defp ghost_hint("ingress"), do: "Optional · the standfirst that opens the piece"
  defp ghost_hint(_), do: "Optional"

  defp ghost_glyph("featured"), do: "🖼"
  defp ghost_glyph("ingress"), do: "¶"
  defp ghost_glyph(_), do: "＋"

  defp ghost_aria_label("featured"), do: "Add the optional featured image, after the title"
  defp ghost_aria_label("ingress"), do: "Add the optional ingress lead paragraph, after the title"
  defp ghost_aria_label(kind), do: "Add the optional #{kind}"

  # The per-block edit row (toolbar + type-aware fields). Extracted verbatim from
  # paper_block_editor/1's block :for so BOTH the flag-OFF list render and the
  # flag-ON non-prose run-boundary render call the SAME markup — the OFF path is
  # byte-identical (a function component inlines the same ~H output). `index` /
  # `last_index` drive the move ▲/▼ disabled state exactly as before.
  attr(:block, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:last_index, :integer, required: true)
  # pdd-t2: whether the block DIRECTLY ABOVE this one is template-locked. Moving
  # this block up would displace that locked block (the server invariant rejects
  # it), so the ▲ control disables — the affordance is never offered and then
  # denied with an error flash.
  attr(:prev_locked, :boolean, default: false)
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")
  attr(:scope_prefix, :string, default: "")
  attr(:picker_browse, :boolean, default: true)
  # t9 — the id-keyed live-preview map (paper_block_editor passes it through);
  # only a task-type block reads its own entry. Default keeps every other call
  # site (and every non-task block) byte-identical.
  attr(:task_previews, :map, default: %{})
  attr(:doc_type, :string, default: "paper")
  attr(:paper_rev, :integer, default: 0)
  attr(:document_rev, :string, default: nil)
  attr(:root_slug, :string, default: "")
  attr(:doc_key, :string, default: nil)
  attr(:canvas_enabled, :boolean, default: false)
  attr(:paper_links, :map, default: %{})

  def edit_block(assigns) do
    ~H"""
    <div
      class="bp-paper-edit-block"
      data-edit-block-id={Map.get(@block, "id")}
      data-block-type={Map.get(@block, "type")}
      data-block-locked={Map.get(@block, "locked") == true && "true"}
    >
      <div class="bp-paper-edit-toolbar">
        <%!-- pdd-t2: a locked block's grip is INERT — no draggable, no
              data-drag-grip (the sortable hook cancels any drag not started on
              a grip), a template hint instead of "Drag to reorder". Kept in the
              row so the toolbar keeps its shape. --%>
        <span
          class="bp-paper-drag-grip"
          data-drag-grip={Map.get(@block, "locked") != true}
          draggable={Map.get(@block, "locked") != true && "true"}
          title={
            if Map.get(@block, "locked") == true,
              do: "Part of the document template",
              else: "Drag to reorder"
          }
          aria-label={
            if Map.get(@block, "locked") == true,
              do: "Part of the document template",
              else: "Drag to reorder block"
          }
          tabindex={Map.get(@block, "locked") == true && "0"}
          data-test-id="paper-drag-grip"
        >⋮⋮</span>
        <span class="bp-paper-edit-kind"><%= Map.get(@block, "type") %></span>
        <span class="bp-paper-edit-actions">
          <%!-- Doctrine template lock (pdd-t2): a locked mandated block hides its
                ▲▼/× controls and shows a calm lock note instead — same contract as
                the flag-OFF list render above. --%>
          <button
            :if={Map.get(@block, "locked") != true}
            type="button"
            class="btn btn-ghost btn-sm"
            title="Move up"
            phx-click="paper-move-block"
            phx-value-id={Map.get(@block, "id")}
            phx-value-dir="up"
            disabled={@index == 0 or @prev_locked}
            data-test-id="paper-move-up"
          >▲</button>
          <button
            :if={Map.get(@block, "locked") != true}
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
            :if={Map.get(@block, "locked") != true}
            type="button"
            class="btn btn-destructive btn-sm"
            title="Delete block"
            phx-click="paper-delete-block"
            phx-value-id={Map.get(@block, "id")}
            data-test-id="paper-delete-block"
          >×</button>
          <span
            :if={Map.get(@block, "locked") == true}
            class="bp-paper-lock-note"
            title="Part of the document template"
            data-test-id="paper-locked-note"
          >🔒 Locked</span>
        </span>
      </div>
      <.task_block_preview
        :if={task_preview_block?(@block)}
        block={@block}
        preview={Map.get(@task_previews, Map.get(@block, "id"))}
      />
      <.paper_block_fields
        block={@block}
        dataset={@dataset}
        api_token_raw={@api_token_raw}
        scope_prefix={@scope_prefix}
        picker_browse={@picker_browse}
        doc_type={@doc_type}
        paper_rev={@paper_rev}
        document_rev={@document_rev}
        root_slug={@root_slug}
        doc_key={@doc_key}
        canvas_enabled={@canvas_enabled}
        paper_links={@paper_links}
      />
    </div>
    """
  end

  # ── t9 — live task-block preview (the boundary-widget consumer) ─────────────
  #
  # The canvas renders task blocks as boundary widgets (they are non-prose), so
  # the LIVE preview paints HERE, server-rendered from @paper_task_previews —
  # the display-only rows Shared.push_task_previews resolves under the session
  # scope. The HTML producer is `Render.render_block/2` — the SAME emitter the
  # /papers reader uses (doctrine rule 3: one producer, byte for byte); the
  # Studio shell is a `.bp-paper-surface` sink, so the canonical paper-surface
  # stylesheet styles it identically. D5 by construction: the preview merges
  # rows onto a COPY (TaskResolver.apply_preview/2) — @block itself (the save
  # baseline / the ops the buttons emit) is never touched.
  attr(:block, :map, required: true)
  # This block's preview entry (snapshot/task/error) or nil (still resolving /
  # un-addressable block).
  attr(:preview, :any, default: nil)

  def task_block_preview(assigns) do
    assigns = assign(assigns, :state, task_preview_state(assigns.block, assigns.preview))

    ~H"""
    <div class="bp-paper-task-preview" data-test-id="paper-task-preview" aria-live="polite">
      <%= case @state do %>
        <% {:ok, html} -> %>
          <%= raw(html) %>
        <% :empty -> %>
          <div class="bp-tasks bp-tasks--empty">{empty_note(@block)}</div>
        <% :error -> %>
          <div class="bp-tasks bp-tasks--empty">
            Live task preview unavailable — the Tasks plugin may be off.
          </div>
        <% :loading -> %>
          <div class="bp-tasks bp-tasks--empty">Loading live tasks…</div>
      <% end %>
    </div>
    """
  end

  # pdd-t8: broadened from the task-only set to the FULL non-prose fleet — every
  # component block paints the reader's HTML in its boundary widget, not just the
  # query-carrying task blocks. A static block (cards / pipeline / form / …) has no
  # query + no preview entry, so task_preview_state renders it directly. t12a: this
  # gate only fires inside `edit_block/1`, which the flag-ON canvas path renders for
  # `{:block, …}` boundaries only — after the partition flip a fleet block is never
  # such a boundary in the paper pane (it rides a run + paints via `bpFleet`), so this
  # predicate is dormant there; retained infra, its painting proven directly.
  defp task_preview_block?(block),
    do: Map.get(block, "type") in @fleet_preview_types

  # nil/unknown entry on a query block ⇒ still resolving (or the block has no
  # id to key a preview) — an honest "loading" note, never a fake empty board.
  # An author-pinned literal (no query) renders from its own rows directly.
  # pdd-t8: :loading is gated to the QUERY-CARRYING TASK types — only those ever
  # get a preview entry (TaskResolver.preview skips everything else), so a stray
  # "query" key on a static fleet block must render directly, never spin forever.
  defp task_preview_state(block, preview) do
    cond do
      is_map(preview) and preview["error"] == true ->
        :error

      is_map(preview) ->
        block |> TaskResolver.apply_preview(preview) |> rendered_or_empty()

      Map.get(block, "type") in @task_preview_types and Map.has_key?(block, "query") ->
        :loading

      true ->
        rendered_or_empty(block)
    end
  end

  # pdd-t8: the empty note in the block's OWN vocabulary — a task block's
  # emptiness means "the query matched nothing"; a static component block's
  # (cards / pipeline / notes with no items yet) means "no content yet".
  # "No matching tasks." on an empty cards block would be a lie. The static copy
  # mirrors the canvas fleet hook's empty-paint fallback (root.html.heex).
  defp empty_note(block) do
    if Map.get(block, "type") in @task_preview_types,
      do: "No matching tasks.",
      else: "Nothing to show yet."
  end

  # task_detail_html renders "" for an empty/matchless task — surface that as
  # an explicit empty note instead of a silent blank strip.
  defp rendered_or_empty(block) do
    case Render.render_block(block, %{style: :article}) do
      html when html in ["", nil] -> :empty
      html -> if String.trim(html) == "", do: :empty, else: {:ok, html}
    end
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
  # or a map carrying text/value/children/content/items/body. Steps contribute
  # their visible row bodies, but not row titles. Unknown → "".
  defp beta_node_text(s) when is_binary(s), do: s
  defp beta_node_text(list) when is_list(list), do: Enum.map_join(list, " ", &beta_node_text/1)

  defp beta_node_text(%{"type" => "steps", "steps" => steps}) when is_list(steps) do
    Enum.map_join(steps, " ", fn
      row when is_map(row) ->
        row
        |> Map.put("type", "expandable")
        |> Blocks.container_children()
        |> beta_node_text()

      _ ->
        ""
    end)
  end

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
  attr(:scope_prefix, :string, default: "")
  attr(:picker_browse, :boolean, default: true)
  attr(:doc_type, :string, default: "paper")
  attr(:paper_rev, :integer, default: 0)
  attr(:document_rev, :string, default: nil)
  attr(:root_slug, :string, default: "")
  attr(:doc_key, :string, default: nil)
  attr(:canvas_enabled, :boolean, default: false)
  attr(:paper_links, :map, default: %{})

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
        <.paper_block_fields
          block={block}
          dataset={@dataset}
          api_token_raw={@api_token_raw}
          scope_prefix={@scope_prefix}
          picker_browse={@picker_browse}
          doc_type={@doc_type}
          paper_rev={@paper_rev}
          document_rev={@document_rev}
          root_slug={@root_slug}
          doc_key={@doc_key}
          canvas_enabled={@canvas_enabled}
          paper_links={@paper_links}
        />
      </div>

      <form
        :if={@unbound != []}
        class="bp-prop-add"
        phx-submit="paper-add-property"
        data-test-id="paper-add-property"
      >
        <label>
          + Add property
          <.bp_select
            name="fieldName"
            prompt="Choose a field…"
            options={Enum.map(@unbound, &{&1.name, &1.label})}
          />
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

  attr(:block, :map, required: true)

  defp rich_body_editor(assigns) do
    ~H"""
    <div
      phx-update="ignore"
      id={"paper-ed-" <> Map.fetch!(@block, "id")}
      phx-hook="BarkparkPaperEditor"
      class="bp-paper-edit-wc"
      data-test-id="paper-block-editor-wc"
    >
      <bp-paper-editor data-block={Jason.encode!(@block)}></bp-paper-editor>
    </div>
    """
  end

  # Per-block-type edit fields. Rich bodies use the canonical WC so its
  # PortableDoc conversion preserves marks and links while text changes.
  # Ordinary forms remain for scalar chrome such as callout tone/title/fold.
  attr(:block, :map, required: true)
  attr(:dataset, :string, default: "production")
  attr(:api_token_raw, :string, default: "")
  attr(:scope_prefix, :string, default: "")
  attr(:picker_browse, :boolean, default: true)
  attr(:doc_type, :string, default: "paper")
  attr(:paper_rev, :integer, default: 0)
  attr(:document_rev, :string, default: nil)
  attr(:root_slug, :string, default: "")
  attr(:doc_key, :string, default: nil)
  attr(:canvas_enabled, :boolean, default: false)
  attr(:paper_links, :map, default: %{})

  def paper_block_fields(assigns) do
    assigns =
      assigns
      |> assign(id: Map.get(assigns.block, "id"), type: Map.get(assigns.block, "type"))
      |> assign(
        :expandable_segments,
        if(Map.get(assigns.block, "type") == "expandable" and assigns.canvas_enabled,
          do:
            assigns.block
            |> Blocks.container_children()
            |> PaperCanvas.partition_runs()
            |> PaperCanvas.with_run_ordinals(),
          else: []
        )
      )

    ~H"""
    <%= case @type do %>
      <% t when t in ["diff", "filetree", "footnote", "code-tabs"] -> %>
        <.technical_block_editor block={@block} id={@id} />
      <%!-- Rich-text blocks are edited by the
            <bp-paper-editor> Web Component. The phx-update="ignore" wrapper
            keeps LiveView from re-diffing the WC's internal DOM (preserving
            the caret across server updates); its id is stable per block id so
            it survives re-renders. The WC reads its initial block from
            data-block and emits debounced `bp-op` events that the
            BarkparkPaperEditor hook forwards to the server's paper-op handler.
            Callout keeps a separate form for its scalar chrome, while its body
            joins ingress/pullquote on this same rich seam. --%>
      <% t when t in ["paragraph", "heading", "list"] -> %>
        <.rich_body_editor block={@block} />
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
        </form>
        <.rich_body_editor block={@block} />
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
        </form>
      <% "route" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-route-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-route-preview">
            <%= raw(Render.render_block(@block, %{style: :article})) %>
          </div>
          <details id={"route-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure route</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"route-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
                data-test-id="paper-route-editor"
              >
                <input type="hidden" name="block_id" value={@id} />
                <label class="bp-paper-edit-fieldlabel" for={"route-polyline-" <> @id}>Encoded polyline</label>
                <textarea id={"route-polyline-" <> @id} name="polyline"
                          class="bp-paper-edit-textarea bp-paper-edit-code" rows="4"><%= Blocks.form_value(Map.get(@block, "polyline")) %></textarea>
                <label class="bp-paper-edit-fieldlabel" for={"route-sport-" <> @id}>Sport</label>
                <input id={"route-sport-" <> @id} type="text" name="sport"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "sport"))} />
                <label class="bp-paper-edit-fieldlabel" for={"route-distance-" <> @id}>Distance</label>
                <input id={"route-distance-" <> @id} type="text" name="distance"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "distance"))} />
                <label class="bp-paper-edit-fieldlabel" for={"route-elevation-" <> @id}>Elevation</label>
                <input id={"route-elevation-" <> @id} type="text" name="elevation"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "elevation"))} />
                <label class="bp-paper-edit-fieldlabel" for={"route-duration-" <> @id}>Duration</label>
                <input id={"route-duration-" <> @id} type="text" name="duration"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "duration"))} />
                <label class="bp-paper-edit-fieldlabel" for={"route-caption-" <> @id}>Caption</label>
                <input id={"route-caption-" <> @id} type="text" name="caption"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "caption"))} />
              </form>
            </div>
          </details>
        </div>
      <% "api-endpoint" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-api-endpoint-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-api-endpoint-preview">
            <%= raw(Render.render_block(@block, %{style: :article})) %>
          </div>
          <details id={"api-endpoint-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure API endpoint</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"api-endpoint-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
                data-test-id="paper-api-endpoint-editor"
              >
                <input type="hidden" name="block_id" value={@id} />
                <input type="hidden" name="param-count" value={length(Blocks.api_endpoint_params(@block))} />
                <label class="bp-paper-edit-fieldlabel" for={"api-endpoint-method-" <> @id}>Method</label>
                <input id={"api-endpoint-method-" <> @id} type="text" name="method"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "method"))}
                       list={"api-endpoint-methods-" <> @id} />
                <datalist id={"api-endpoint-methods-" <> @id}>
                  <option :for={method <- ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)} value={method}></option>
                </datalist>
                <label class="bp-paper-edit-fieldlabel" for={"api-endpoint-path-" <> @id}>Path</label>
                <input id={"api-endpoint-path-" <> @id} type="text" name="path"
                       class="bp-paper-edit-text bp-paper-edit-code"
                       value={Blocks.form_value(Map.get(@block, "path"))} />

                <fieldset
                  :for={{param, index} <- Enum.with_index(Blocks.api_endpoint_params(@block))}
                  class="bp-paper-edit-form"
                  data-test-id="paper-api-endpoint-param-row"
                  data-param-index={index}
                >
                  <legend>Parameter <%= index + 1 %></legend>
                  <%= if is_map(param) do %>
                    <label class="bp-paper-edit-fieldlabel">
                      Name
                      <input type="text" name={"param-#{index}-name"} class="bp-paper-edit-text"
                             value={Blocks.api_endpoint_param_value(param, "name")} />
                    </label>
                    <label class="bp-paper-edit-fieldlabel">
                      Location
                      <input type="text" name={"param-#{index}-in"} class="bp-paper-edit-text"
                             value={Blocks.api_endpoint_param_value(param, "in")}
                             list={"api-endpoint-locations-" <> @id} />
                    </label>
                    <label class="bp-paper-edit-fieldlabel">
                      Type
                      <input type="text" name={"param-#{index}-type"} class="bp-paper-edit-text"
                             value={Blocks.api_endpoint_param_value(param, "type")} />
                    </label>
                    <label class="bp-paper-edit-check">
                      <input type="hidden" name={"param-#{index}-required"} value="false" />
                      <input type="checkbox" name={"param-#{index}-required"} value="true"
                             checked={Blocks.api_endpoint_param_required?(param)} />
                      Required
                    </label>
                  <% else %>
                    <p class="bp-paper-edit-readonly" data-test-id="paper-api-endpoint-legacy-param">
                      Legacy parameter retained until explicitly removed.
                    </p>
                  <% end %>
                  <div class="bp-paper-edit-actions">
                    <button type="submit" name="param-action" value={"up:#{index}"}
                            class="btn btn-ghost btn-sm" disabled={index == 0}>Move up</button>
                    <button type="submit" name="param-action" value={"down:#{index}"}
                            class="btn btn-ghost btn-sm"
                            disabled={index == length(Blocks.api_endpoint_params(@block)) - 1}>Move down</button>
                  </div>
                  <button type="submit" name="param-action" value={"remove:#{index}"}
                          class="btn btn-destructive btn-sm" data-test-id="paper-api-endpoint-param-remove">
                    Remove parameter
                  </button>
                </fieldset>

                <datalist id={"api-endpoint-locations-" <> @id}>
                  <option :for={location <- ~w(path query header cookie body)} value={location}></option>
                </datalist>
                <button type="submit" name="param-action" value="add" class="btn btn-ghost btn-sm"
                        data-test-id="paper-api-endpoint-param-add">Add parameter</button>
              </form>
            </div>
          </details>
        </div>
      <% "toc" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-toc-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-toc-preview">
            <%= raw(Render.render_block(@block, %{style: :article})) %>
          </div>
          <details id={"toc-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure table of contents</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"toc-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
                data-test-id="paper-toc-editor"
              >
                <input type="hidden" name="block_id" value={@id} />
                <input type="hidden" name="toc-count" value={length(Blocks.toc_items(@block))} />
                <label class="bp-paper-edit-fieldlabel" for={"toc-depth-" <> @id}>Visible depth</label>
                <input id={"toc-depth-" <> @id} type="text" inputmode="numeric" name="depth"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "depth"))} />
                <label class="bp-paper-edit-check" for={"toc-numbered-" <> @id}>
                  <input type="hidden" name="numbered" value="false" />
                  <input id={"toc-numbered-" <> @id} type="checkbox" name="numbered" value="true"
                         checked={Blocks.strict_boolean_field?(@block, "numbered")} />
                  Number entries
                </label>
                <label class="bp-paper-edit-check" for={"toc-sticky-" <> @id}>
                  <input type="hidden" name="sticky" value="false" />
                  <input id={"toc-sticky-" <> @id} type="checkbox" name="sticky" value="true"
                         checked={Blocks.strict_boolean_field?(@block, "sticky")} />
                  Sticky in article view
                </label>

                <fieldset
                  :for={{item, index} <- Enum.with_index(Blocks.toc_items(@block))}
                  class="bp-paper-edit-form"
                  data-test-id="paper-toc-row"
                  data-toc-index={index}
                >
                  <legend>Entry <%= index + 1 %></legend>
                  <%= if is_map(item) do %>
                    <label class="bp-paper-edit-fieldlabel" for={"toc-#{index}-text-#{@id}"}>Text</label>
                    <input id={"toc-#{index}-text-#{@id}"} type="text" name={"toc-#{index}-text"}
                           class="bp-paper-edit-text" value={Blocks.form_value(Map.get(item, "text"))} />
                    <label class="bp-paper-edit-fieldlabel" for={"toc-#{index}-level-#{@id}"}>Level</label>
                    <input id={"toc-#{index}-level-#{@id}"} type="text" inputmode="numeric"
                           name={"toc-#{index}-level"} class="bp-paper-edit-text"
                           value={Blocks.form_value(Map.get(item, "level"))} />
                    <label class="bp-paper-edit-fieldlabel" for={"toc-#{index}-anchor-#{@id}"}>Anchor</label>
                    <input id={"toc-#{index}-anchor-#{@id}"} type="text" name={"toc-#{index}-anchor"}
                           class="bp-paper-edit-text bp-paper-edit-code"
                           value={Blocks.form_value(Map.get(item, "anchor"))} />
                  <% else %>
                    <p class="bp-paper-edit-readonly" data-test-id="paper-toc-legacy-row">
                      Legacy entry retained until explicitly removed.
                    </p>
                  <% end %>
                  <div class="bp-paper-edit-actions">
                    <button type="submit" name="toc-action" value={"up:#{index}"}
                            class="btn btn-ghost btn-sm" disabled={index == 0}>Move up</button>
                    <button type="submit" name="toc-action" value={"down:#{index}"}
                            class="btn btn-ghost btn-sm"
                            disabled={index == length(Blocks.toc_items(@block)) - 1}>Move down</button>
                    <button type="submit" name="toc-action" value={"remove:#{index}"}
                            class="btn btn-destructive btn-sm">Remove entry</button>
                  </div>
                </fieldset>

                <button type="submit" name="toc-action" value="add" class="btn btn-ghost btn-sm"
                        data-test-id="paper-toc-add">Add entry</button>
              </form>
            </div>
          </details>
        </div>
      <% "criteria-progress" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-criteria-progress-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-criteria-progress-preview">
            <%= raw(Render.render_block(@block, %{style: :article})) %>
          </div>
          <details id={"criteria-progress-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure criteria progress</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"criteria-progress-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
                data-test-id="paper-criteria-progress-editor"
              >
                <input type="hidden" name="block_id" value={@id} />
                <input type="hidden" name="criterion-count"
                       value={length(Blocks.criteria_progress_rows(@block))} />
                <label class="bp-paper-edit-fieldlabel" for={"criteria-progress-detail-" <> @id}>Detail</label>
                <input id={"criteria-progress-detail-" <> @id} type="text" name="detail"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "detail"))}
                       list={"criteria-progress-detail-options-" <> @id} />
                <datalist id={"criteria-progress-detail-options-" <> @id}>
                  <option value="rows"></option>
                  <option value="total"></option>
                </datalist>

                <fieldset
                  :for={{row, index} <- Enum.with_index(Blocks.criteria_progress_rows(@block))}
                  class="bp-paper-edit-form"
                  data-test-id="paper-criteria-progress-row"
                  data-criterion-index={index}
                >
                  <legend>Criterion <%= index + 1 %></legend>
                  <%= if is_map(row) do %>
                    <label class="bp-paper-edit-fieldlabel" for={"criterion-#{index}-label-#{@id}"}>Label</label>
                    <input id={"criterion-#{index}-label-#{@id}"} type="text"
                           name={"criterion-#{index}-label"} class="bp-paper-edit-text"
                           value={Blocks.form_value(Map.get(row, "label"))} />
                    <label class="bp-paper-edit-fieldlabel" for={"criterion-#{index}-met-#{@id}"}>Met</label>
                    <input id={"criterion-#{index}-met-#{@id}"} type="text" inputmode="decimal"
                           name={"criterion-#{index}-met"} class="bp-paper-edit-text"
                           value={Blocks.form_value(Map.get(row, "met"))} />
                    <label class="bp-paper-edit-fieldlabel" for={"criterion-#{index}-total-#{@id}"}>Total</label>
                    <input id={"criterion-#{index}-total-#{@id}"} type="text" inputmode="decimal"
                           name={"criterion-#{index}-total"} class="bp-paper-edit-text"
                           value={Blocks.form_value(Map.get(row, "total"))} />
                  <% else %>
                    <p class="bp-paper-edit-readonly" data-test-id="paper-criteria-progress-legacy-row">
                      Legacy row retained until explicitly removed.
                    </p>
                  <% end %>
                  <div class="bp-paper-edit-actions">
                    <button type="submit" name="criterion-action" value={"up:#{index}"}
                            class="btn btn-ghost btn-sm" disabled={index == 0}>Move up</button>
                    <button type="submit" name="criterion-action" value={"down:#{index}"}
                            class="btn btn-ghost btn-sm"
                            disabled={index == length(Blocks.criteria_progress_rows(@block)) - 1}>Move down</button>
                    <button type="submit" name="criterion-action" value={"remove:#{index}"}
                            class="btn btn-destructive btn-sm">Remove criterion</button>
                  </div>
                </fieldset>

                <button type="submit" name="criterion-action" value="add" class="btn btn-ghost btn-sm"
                        data-test-id="paper-criteria-progress-add">Add criterion</button>
              </form>
            </div>
          </details>
        </div>
      <% "equation" -> %>
        <form
          id={"equation-form-" <> @id}
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
          data-test-id="paper-equation-editor"
        >
          <input type="hidden" name="block_id" value={@id} />
          <label class="bp-paper-edit-fieldlabel" for={"equation-tex-" <> @id}>TeX source</label>
          <textarea
            id={"equation-tex-" <> @id}
            name="tex"
            class="bp-paper-edit-textarea bp-paper-edit-code"
            rows="3"
            data-test-id="paper-field-equation-tex"
          ><%= Blocks.form_value(Map.get(@block, "tex")) %></textarea>
          <label class="bp-paper-edit-check">
            <input type="checkbox" name="display" value="true"
                   checked={Map.get(@block, "display") == true} />
            Display equation
          </label>
        </form>
      <%!-- Article-chrome blocks. Eyebrow + byline remain flat scalar inputs;
            ingress + pullquote use the same rich body WC as paragraphs. --%>
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
        </form>
      <% "ingress" -> %>
        <.rich_body_editor block={@block} />
      <% "pullquote" -> %>
        <.rich_body_editor block={@block} />
      <% "blockquote" -> %>
        <form
          id={"blockquote-form-" <> @id}
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
          data-test-id="paper-blockquote-editor"
        >
          <input type="hidden" name="block_id" value={@id} />
          <label class="bp-paper-edit-fieldlabel" for={"blockquote-cite-" <> @id}>Attribution</label>
          <input
            id={"blockquote-cite-" <> @id}
            type="text"
            name="cite"
            class="bp-paper-edit-text"
            value={Blocks.form_value(Blocks.blockquote_cite_value(@block))}
            placeholder="Author or source (optional)"
            data-test-id="paper-field-blockquote-cite"
          />
        </form>
        <.rich_body_editor block={@block} />
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
        </form>
      <% "paper-links" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-links-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-links-preview">
            <%= raw(Render.render_block(@block, %{style: :article, paper_links: @paper_links})) %>
          </div>
          <details id={"paper-links-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure related papers</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"paper-links-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
                data-test-id="paper-links-editor"
              >
                <input type="hidden" name="block_id" value={@id} />
                <input type="hidden" name="ref-count" value={length(Map.get(@block, "refs", []))} />
                <label class="bp-paper-edit-fieldlabel">
                  Title
                  <input type="text" name="title" class="bp-paper-edit-text"
                         value={Map.get(@block, "title", "")} />
                </label>
                <label class="bp-paper-edit-fieldlabel">
                  Description
                  <textarea name="description" class="bp-paper-edit-textarea" rows="2"><%= Map.get(@block, "description", "") %></textarea>
                </label>
                <label class="bp-paper-edit-fieldlabel">
                  Layout
                  <input type="text" name="layout" class="bp-paper-edit-text"
                         value={Map.get(@block, "layout", "")} />
                </label>

                <fieldset
                  :for={{ref, index} <- Enum.with_index(Map.get(@block, "refs", []))}
                  class="bp-paper-edit-form"
                  data-test-id="paper-link-ref-row"
                  data-ref-index={index}
                >
                  <legend>Reference <%= index + 1 %></legend>
                  <label class="bp-paper-edit-fieldlabel">
                    Slug
                    <input type="text" name={"ref-#{index}-slug"} class="bp-paper-edit-text"
                           value={Blocks.paper_link_ref_value(ref, "slug") || ""} />
                  </label>
                  <label class="bp-paper-edit-fieldlabel">
                    Authored title
                    <input type="text" name={"ref-#{index}-title"} class="bp-paper-edit-text"
                           value={Blocks.paper_link_ref_value(ref, "title") || ""} />
                  </label>
                  <label class="bp-paper-edit-fieldlabel">
                    Authored description
                    <textarea name={"ref-#{index}-description"} class="bp-paper-edit-textarea" rows="2"><%= Blocks.paper_link_ref_value(ref, "description") || "" %></textarea>
                  </label>
                  <label class="bp-paper-edit-fieldlabel">
                    Eyebrow
                    <input type="text" name={"ref-#{index}-eyebrow"} class="bp-paper-edit-text"
                           value={Blocks.paper_link_ref_value(ref, "eyebrow") || ""} />
                  </label>
                  <label class="bp-paper-edit-fieldlabel">
                    Meta
                    <input type="text" name={"ref-#{index}-meta"} class="bp-paper-edit-text"
                           value={Blocks.paper_link_ref_value(ref, "meta") || ""} />
                  </label>
                  <label class="bp-paper-edit-fieldlabel">
                    Reason
                    <textarea name={"ref-#{index}-reason"} class="bp-paper-edit-textarea" rows="2"><%= Blocks.paper_link_ref_value(ref, "reason") || "" %></textarea>
                  </label>
                  <label class="bp-paper-edit-check">
                    <input type="checkbox" name={"ref-#{index}-prefer-authored-copy"} value="true"
                           checked={Blocks.paper_link_ref_value(ref, "prefer_authored_copy") == true} />
                    Prefer authored copy
                  </label>
                  <label class="bp-paper-edit-check">
                    <input type="hidden" name={"ref-#{index}-featured"} value="false" />
                    <input type="checkbox" name={"ref-#{index}-featured"} value="true"
                           checked={Blocks.paper_link_ref_value(ref, "featured") == true} />
                    Featured reference
                  </label>
                  <button type="submit" name="ref-action" value={"remove:#{index}"}
                          class="btn btn-destructive btn-sm" data-test-id="paper-link-remove-ref">
                    Remove reference
                  </button>
                </fieldset>

                <button type="submit" name="ref-action" value="add" class="btn btn-ghost btn-sm"
                        data-test-id="paper-link-add-ref">Add reference</button>
              </form>
            </div>
          </details>
        </div>
      <% "steps" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-steps-editor">
          <%= if not editable_steps?(@block) do %>
            <%= raw(Render.render_block(@block, %{style: :article, paper_links: @paper_links})) %>
            <p class="bp-paper-edit-readonly">Step identities need repair before editing; original content is preserved.</p>
          <% else %>
          <ol class="bp-steps">
            <li :for={row <- editable_step_rows(@block)} class="bp-steps__step" data-step-row-id={row["id"]}>
              <div :if={is_binary(row["title"]) and row["title"] != ""} class="bp-steps__title"><%= row["title"] %></div>
              <div class="bp-steps__body">
                <%= for segment <- step_body_segments(row, @canvas_enabled) do %>
                  <%= case segment do %>
                    <% {:run, run_blocks, ordinal} -> %>
                      <.canvas_run
                        slug={PaperCanvas.steps_run_slug(@root_slug, @id, row["id"])}
                        run_blocks={run_blocks} run_ordinal={ordinal}
                        dataset={@dataset} api_token_raw={@api_token_raw}
                        scope_prefix={@scope_prefix} picker_browse={@picker_browse}
                        doc_key={@doc_key || "#{@dataset}:#{@doc_type}:#{@root_slug}"}
                        paper_rev={@doc_type == "paper" && @paper_rev}
                        document_rev={@doc_type != "paper" && @document_rev}
                        container_id={@id} container_kind="steps" container_row_id={row["id"]}
                      />
                    <% {:block, child} -> %>
                      <.paper_block_fields
                        block={child} dataset={@dataset} api_token_raw={@api_token_raw}
                        scope_prefix={@scope_prefix} picker_browse={@picker_browse}
                        doc_type={@doc_type} paper_rev={@paper_rev} document_rev={@document_rev}
                        root_slug={@root_slug} doc_key={@doc_key}
                        canvas_enabled={@canvas_enabled} paper_links={@paper_links}
                      />
                  <% end %>
                <% end %>
              </div>
            </li>
          </ol>
          <details id={"paper-steps-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure steps</summary>
            <div class="bp-paper-contextual-panel">
              <form id={"steps-form-" <> @id} class="bp-paper-edit-form"
                    phx-submit="paper-edit-block" phx-change="paper-block-autosave" phx-debounce="500">
                <input type="hidden" name="block_id" value={@id} />
                <input type="hidden" name="step-count" value={length(editable_step_rows(@block))} />
                <input type="hidden" name="step-new-row-id" value={Blocks.new_block_id()} />
                <input type="hidden" name="step-new-child-id" value={Blocks.new_block_id()} />
                <fieldset :for={{row, index} <- Enum.with_index(editable_step_rows(@block))}>
                  <legend>Step <%= index + 1 %></legend>
                  <input type="hidden" name={"step-#{index}-id"} value={row["id"]} />
                  <label>Title
                    <input type="text" name={"step-#{index}-title"} value={row["title"] || ""}
                           class="bp-paper-edit-text" />
                  </label>
                  <button type="submit" name="step-action" value={"up:" <> row["id"]}
                          disabled={index == 0} class="btn btn-ghost btn-sm">Move up</button>
                  <button type="submit" name="step-action" value={"down:" <> row["id"]}
                          disabled={index == length(editable_step_rows(@block)) - 1}
                          class="btn btn-ghost btn-sm">Move down</button>
                  <button type="submit" name="step-action" value={"remove:" <> row["id"]}
                          class="btn btn-destructive btn-sm">Remove step</button>
                  <button :if={empty_step_body?(row)}
                          type="submit" name="step-action" value={"add-body:" <> row["id"]}
                          class="btn btn-ghost btn-sm">Add paragraph</button>
                </fieldset>
                <button type="submit" name="step-action" value="add" class="btn btn-ghost btn-sm">Add step</button>
              </form>
            </div>
          </details>
          <% end %>
        </div>
      <% "expandable" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-expandable-editor">
          <details
            id={"paper-expandable-disclosure-" <> @id}
            class="bp-expandable"
            open={Map.get(@block, "open") == true}
            phx-mounted={JS.ignore_attributes("open")}
            data-test-id="paper-expandable-preview"
          >
            <summary><%= Map.get(@block, "summary", "") %></summary>
            <div class="bp-expandable__body" data-test-id="paper-expandable-children">
              <%= if @canvas_enabled do %>
                <%= for segment <- @expandable_segments do %>
                  <%= case segment do %>
                    <% {:run, run_blocks, ordinal} -> %>
                      <.canvas_run
                        slug={PaperCanvas.expandable_run_slug(@root_slug, @id)}
                        run_blocks={run_blocks}
                        run_ordinal={ordinal}
                        dataset={@dataset}
                        api_token_raw={@api_token_raw}
                        scope_prefix={@scope_prefix}
                        picker_browse={@picker_browse}
                        doc_key={@doc_key || "#{@dataset}:#{@doc_type}:#{@root_slug}"}
                        paper_rev={@doc_type == "paper" && @paper_rev}
                        document_rev={@doc_type != "paper" && @document_rev}
                        container_id={@id}
                      />
                    <% {:block, child} -> %>
                      <div
                        data-nested-block-id={Map.get(child, "id")}
                        data-block-type={Map.get(child, "type")}
                      >
                        <span class="bp-paper-edit-kind"><%= Map.get(child, "type") %></span>
                        <.paper_block_fields
                          block={child}
                          dataset={@dataset}
                          api_token_raw={@api_token_raw}
                          scope_prefix={@scope_prefix}
                          picker_browse={@picker_browse}
                          doc_type={@doc_type}
                          paper_rev={@paper_rev}
                          document_rev={@document_rev}
                          root_slug={@root_slug}
                          doc_key={@doc_key}
                          canvas_enabled={@canvas_enabled}
                          paper_links={@paper_links}
                        />
                      </div>
                  <% end %>
                <% end %>
              <% else %>
                <div
                  :for={child <- Blocks.container_children(@block)}
                  data-nested-block-id={Map.get(child, "id")}
                  data-block-type={Map.get(child, "type")}
                >
                  <span class="bp-paper-edit-kind"><%= Map.get(child, "type") %></span>
                  <.paper_block_fields
                    block={child}
                    dataset={@dataset}
                    api_token_raw={@api_token_raw}
                    scope_prefix={@scope_prefix}
                    picker_browse={@picker_browse}
                    doc_type={@doc_type}
                    paper_rev={@paper_rev}
                    document_rev={@document_rev}
                    root_slug={@root_slug}
                    doc_key={@doc_key}
                    canvas_enabled={false}
                    paper_links={@paper_links}
                  />
                </div>
              <% end %>
            </div>
          </details>
          <details id={"paper-expandable-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure expandable</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"expandable-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
              >
                <input type="hidden" name="block_id" value={@id} />
                <label class="bp-paper-edit-fieldlabel">
                  Summary
                  <input type="text" name="summary" class="bp-paper-edit-text"
                         value={Map.get(@block, "summary", "")} />
                </label>
                <label class="bp-paper-edit-check">
                  <input type="checkbox" name="open" value="true" checked={Map.get(@block, "open") == true} />
                  Open by default
                </label>
              </form>
            </div>
          </details>
        </div>
      <% "gauge-list" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-gauge-list-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-gauge-list-preview">
            <%= raw(Render.render_block(@block, %{style: :article})) %>
          </div>
          <details id={"gauge-list-controls-" <> @id}
                   class="bp-paper-contextual-controls bp-paper-contextual-controls--gauge-list"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure gauge list</summary>
            <div class="bp-paper-contextual-panel">
              <form id={"gauge-list-form-" <> @id} class="bp-paper-edit-form"
                    phx-submit="paper-edit-block" phx-change="paper-block-autosave"
                    phx-debounce="500" data-test-id="paper-gauge-list-editor">
                <input type="hidden" name="block_id" value={@id} />
                <label class="bp-paper-edit-fieldlabel" for={"gauge-title-" <> @id}>Title</label>
                <input id={"gauge-title-" <> @id} type="text" name="title"
                       class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "title"))} />
                <label class="bp-paper-edit-fieldlabel" for={"gauge-mode-" <> @id}>Mode</label>
                <select id={"gauge-mode-" <> @id} name="mode" class="bp-paper-edit-text">
                  <option value="share" selected={Blocks.gauge_list_mode(@block) == "share"}>Shares</option>
                  <option value="count" selected={Blocks.gauge_list_mode(@block) == "count"}>Counts from snapshot</option>
                </select>
                <%= if Blocks.gauge_list_mode(@block) == "share" do %>
                  <label class="bp-paper-edit-fieldlabel" for={"gauge-max-" <> @id}>Maximum</label>
                  <input id={"gauge-max-" <> @id} type="text" inputmode="decimal" name="max"
                         class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "max"))}
                         placeholder="Automatic: sum of values" />
                  <%= if is_nil(Map.get(@block, "rows")) or
                         (is_list(Map.get(@block, "rows")) and Enum.all?(@block["rows"], &is_map/1)) do %>
                  <input type="hidden" name="gauge-count" value={length(Blocks.gauge_list_rows(@block))} />
                  <fieldset :for={{row, index} <- Enum.with_index(Blocks.gauge_list_rows(@block))}
                            class="bp-paper-edit-form" data-test-id="paper-gauge-list-row">
                    <legend>Gauge <%= index + 1 %></legend>
                      <label class="bp-paper-edit-fieldlabel" for={"gauge-#{index}-label-#{@id}"}>Label</label>
                      <input id={"gauge-#{index}-label-#{@id}"} type="text" name={"gauge-#{index}-label"}
                             class="bp-paper-edit-text" value={Blocks.form_value(Map.get(row, "label"))} />
                      <label class="bp-paper-edit-fieldlabel" for={"gauge-#{index}-value-#{@id}"}>Value</label>
                      <input id={"gauge-#{index}-value-#{@id}"} type="text" inputmode="decimal"
                             name={"gauge-#{index}-value"} class="bp-paper-edit-text"
                             value={Blocks.form_value(Map.get(row, "value"))} />
                      <label class="bp-paper-edit-fieldlabel" for={"gauge-#{index}-note-#{@id}"}>Note</label>
                      <input id={"gauge-#{index}-note-#{@id}"} type="text" name={"gauge-#{index}-note"}
                             class="bp-paper-edit-text" value={Blocks.form_value(Map.get(row, "note"))} />
                    <div class="bp-paper-edit-actions">
                      <button type="submit" name="gauge-action" value={"up:#{index}"}
                              class="btn btn-ghost btn-sm" disabled={index == 0}>Move up</button>
                      <button type="submit" name="gauge-action" value={"down:#{index}"}
                              class="btn btn-ghost btn-sm"
                              disabled={index == length(Blocks.gauge_list_rows(@block)) - 1}>Move down</button>
                      <button type="submit" name="gauge-action" value={"remove:#{index}"}
                              class="btn btn-destructive btn-sm">Remove gauge</button>
                    </div>
                  </fieldset>
                  <button type="submit" name="gauge-action" value="add" class="btn btn-ghost btn-sm">Add gauge</button>
                  <% else %>
                    <p class="bp-paper-edit-readonly">
                      Row data has a legacy shape; title, mode and maximum remain editable.
                      Original rows are preserved.
                    </p>
                  <% end %>
                <% else %>
                  <label class="bp-paper-edit-fieldlabel" for={"gauge-group-" <> @id}>Group by</label>
                  <input id={"gauge-group-" <> @id} type="text" name="groupBy"
                         class="bp-paper-edit-text" list={"gauge-groups-" <> @id}
                         value={Blocks.gauge_list_group_by(@block)} />
                  <datalist id={"gauge-groups-" <> @id}>
                    <option :for={group <- ["worker", "phase", "status", "priority", "epic"]} value={group}></option>
                  </datalist>
                  <p class="bp-paper-edit-readonly">Snapshot data is preserved; grouping changes how it is displayed.</p>
                <% end %>
              </form>
            </div>
          </details>
        </div>
      <% "bar-chart" -> %>
        <div class="bp-paper-contextual-editor" data-test-id="paper-bar-chart-contextual-editor">
          <div class="bp-paper-contextual-preview" data-test-id="paper-bar-chart-preview">
            <%= raw(Render.render_block(@block, %{style: :article})) %>
          </div>
          <details id={"paper-chart-controls-" <> @id} class="bp-paper-contextual-controls"
                   phx-mounted={JS.ignore_attributes("open")}>
            <summary class="bp-paper-contextual-toggle">Configure bar chart</summary>
            <div class="bp-paper-contextual-panel">
              <form
                id={"bar-chart-form-" <> @id}
                class="bp-paper-edit-form"
                phx-submit="paper-edit-block"
                phx-change="paper-block-autosave"
                phx-debounce="500"
                data-test-id="paper-bar-chart-editor"
              >
          <input type="hidden" name="block_id" value={@id} />
          <input type="hidden" name="bar-count" value={length(Map.get(@block, "bars", []))} />
          <label class="bp-paper-edit-fieldlabel">
            Title
            <input type="text" name="title" class="bp-paper-edit-text"
                   value={Map.get(@block, "title", "")} />
          </label>
          <label class="bp-paper-edit-fieldlabel">
            Maximum
            <input type="number" name="max" class="bp-paper-edit-text" step="any"
                   value={Map.get(@block, "max", "")} />
          </label>
          <label class="bp-paper-edit-check">
            <input type="checkbox" name="values" value="true" checked={Map.get(@block, "values") == true} />
            Show values
          </label>
          <div :for={{bar, index} <- Enum.with_index(Map.get(@block, "bars", []))}
               class="bp-paper-edit-form" data-test-id="paper-bar-chart-row" data-bar-index={index}>
            <label class="bp-paper-edit-fieldlabel">
              Label
              <input type="text" name={"bar-#{index}-label"} class="bp-paper-edit-text"
                     value={Map.get(bar, "label", "")} />
            </label>
            <label class="bp-paper-edit-fieldlabel">
              Value
              <input type="number" name={"bar-#{index}-value"} class="bp-paper-edit-text" step="any"
                     value={Map.get(bar, "value", 0)} />
            </label>
            <button type="submit" name="bar-action" value={"remove:#{index}"}
                    class="btn btn-destructive btn-sm" data-test-id="paper-bar-chart-remove">
              Remove bar
            </button>
          </div>
                <button type="submit" name="bar-action" value="add" class="btn btn-ghost btn-sm"
                        data-test-id="paper-bar-chart-add">Add bar</button>
              </form>
            </div>
          </details>
        </div>
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

      <% "field-number" -> %>
        <form
          id={"field-number-form-" <> @id}
          class="bp-paper-edit-form bp-paper-edit-field"
          phx-update="ignore"
          phx-change="paper-edit-block"
          phx-submit="paper-edit-block"
          data-test-id="paper-field-number-editor"
        >
          <input type="hidden" name="block_id" value={@id} />
          <label class="bp-paper-edit-fieldlabel" for={"field-number-label-" <> @id}>Label</label>
          <input id={"field-number-label-" <> @id} type="text" name="label"
                 class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "label"))} />
          <label class="bp-paper-edit-fieldlabel" for={"field-number-value-" <> @id}>Value</label>
          <input
            id={"field-number-value-" <> @id}
            type="number"
            name="value"
            class="bp-paper-edit-text"
            value={Blocks.form_value(Map.get(@block, "value"))}
            step="any"
            aria-describedby={"field-number-hint-" <> @id}
            data-test-id="paper-field-field-number"
          />
          <label class="bp-paper-edit-fieldlabel" for={"field-number-min-" <> @id}>Minimum</label>
          <input id={"field-number-min-" <> @id} type="number" name="min"
                 class="bp-paper-edit-text" step="any"
                 value={Blocks.form_value(Map.get(@block, "min"))} />
          <label class="bp-paper-edit-fieldlabel" for={"field-number-max-" <> @id}>Maximum</label>
          <input id={"field-number-max-" <> @id} type="number" name="max"
                 class="bp-paper-edit-text" step="any"
                 value={Blocks.form_value(Map.get(@block, "max"))} />
          <label class="bp-paper-edit-fieldlabel" for={"field-number-step-" <> @id}>Step</label>
          <input id={"field-number-step-" <> @id} type="number" name="step"
                 class="bp-paper-edit-text" min="0" step="any"
                 value={Blocks.form_value(Map.get(@block, "step"))} />
          <label class="bp-paper-edit-fieldlabel" for={"field-number-unit-" <> @id}>Unit</label>
          <input id={"field-number-unit-" <> @id} type="text" name="unit"
                 class="bp-paper-edit-text" value={Blocks.form_value(Map.get(@block, "unit"))} />
          <small id={"field-number-hint-" <> @id} class="bp-paper-edit-kind">
            Enter a valid number<%= case Blocks.form_value(Map.get(@block, "unit")) do
              "" -> ""
              unit -> " in #{unit}"
            end %>.
          </small>
          <button type="submit" class="btn btn-primary btn-sm">Save number field</button>
        </form>

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
          <%= if @picker_browse do %>
            <bp-reference-picker
              value={Map.get(@block, "value", "")}
              ref-type={Map.get(@block, "refType", "")}
              dataset={Map.get(@block, "dataset", @dataset)}
              scope-prefix={@scope_prefix}
              data-test-id="paper-field-field-reference"
            ></bp-reference-picker>
          <% else %>
            <output class="bp-paper-picker-current" data-test-id="paper-picker-current">
              {Map.get(@block, "value", "")}
            </output>
          <% end %>
        </div>

      <% "field-image" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} data-field-name={Map.get(@block, "fieldName")} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <%= if @picker_browse do %>
            <bp-media-picker
              value={Map.get(@block, "value", "")}
              dataset={Map.get(@block, "dataset", @dataset)}
              scope-prefix={@scope_prefix}
              data-token={@api_token_raw}
              data-test-id="paper-field-field-image"
            ></bp-media-picker>
          <% else %>
            <output class="bp-paper-picker-current" data-test-id="paper-picker-current">
              {Map.get(@block, "value", "")}
            </output>
          <% end %>
        </div>

      <% "video" -> %>
        <form
          id={"video-form-" <> @id}
          class="bp-paper-edit-form"
          phx-submit="paper-edit-block"
          phx-change="paper-block-autosave"
          phx-debounce="500"
          data-test-id="paper-video-editor"
        >
          <input type="hidden" name="block_id" value={@id} />
          <input type="hidden" name="caption-count" value={length(Blocks.video_captions(@block))} />
          <label class="bp-paper-edit-fieldlabel" for={"video-src-" <> @id}>Video source</label>
          <input
            id={"video-src-" <> @id}
            type="text"
            name="src"
            class="bp-paper-edit-text"
            value={Blocks.form_value(Map.get(@block, "src"))}
            placeholder="/media/video.mp4 or https://…"
            data-test-id="paper-field-video-src"
          />
          <label class="bp-paper-edit-fieldlabel" for={"video-poster-" <> @id}>Poster image</label>
          <input
            id={"video-poster-" <> @id}
            type="text"
            name="poster"
            class="bp-paper-edit-text"
            value={Blocks.form_value(Map.get(@block, "poster"))}
            placeholder="Optional poster URL"
            data-test-id="paper-field-video-poster"
          />
          <label class="bp-paper-edit-check">
            <input type="checkbox" name="loop" value="true" checked={Map.get(@block, "loop") == true} />
            Loop playback
          </label>

          <fieldset
            :for={{caption, index} <- Enum.with_index(Blocks.video_captions(@block))}
            class="bp-paper-edit-form"
            data-test-id="paper-video-caption-row"
            data-caption-index={index}
          >
            <legend>Caption track <%= index + 1 %></legend>
            <div :if={is_map(caption)} class="bp-paper-edit-form">
              <label class="bp-paper-edit-fieldlabel" for={"video-caption-lang-#{@id}-#{index}"}>
                Language
              </label>
              <input
                id={"video-caption-lang-#{@id}-#{index}"}
                type="text"
                name={"caption-#{index}-lang"}
                class="bp-paper-edit-text"
                value={Blocks.form_value(Blocks.video_caption_value(caption, "lang"))}
                placeholder="en"
              />
              <label class="bp-paper-edit-fieldlabel" for={"video-caption-src-#{@id}-#{index}"}>
                Caption file
              </label>
              <input
                id={"video-caption-src-#{@id}-#{index}"}
                type="text"
                name={"caption-#{index}-src"}
                class="bp-paper-edit-text"
                value={Blocks.form_value(Blocks.video_caption_value(caption, "src"))}
                placeholder="/captions/en.vtt"
              />
            </div>
            <p :if={!is_map(caption)} class="bp-paper-edit-readonly">
              This legacy caption entry is retained until removed.
            </p>
            <button
              type="submit"
              name="caption-action"
              value={"remove:#{index}"}
              class="btn btn-destructive btn-sm"
              data-test-id="paper-video-caption-remove"
            >Remove caption track</button>
          </fieldset>

          <button
            type="submit"
            name="caption-action"
            value="add"
            class="btn btn-ghost btn-sm"
            data-test-id="paper-video-caption-add"
          >Add caption track</button>
        </form>

      <%!-- IMAGE content blocks (t13, pd-doctrine rule 1). The seeded locked
            `role: "featured"` image (Content.Papers.Template) is a `type:"image"`
            block with NO src — a canvas run BOUNDARY, so it renders through THIS
            per-block path on both the flag-ON canvas and the classic editor.
            Bind the SAME bp-media-picker the field-image picker uses; the bridge
            (data-field-type="image") patches the block's `src`/`alt` from the
            WC's parsed meta (a plain URL — never the JSON asset-ref blob the
            field path stores in `value`). Empty src → the WC's dashed add-card
            (restyled evergreen for the featured block via root.html.heex) IS the
            affordance; a chosen asset patches src and the public /papers render
            picks it up (compose.ex `image` clause). --%>
      <% "image" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type="image" data-block-role={image_block_role(@block)} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel">
            <%= if image_block_role(@block) == "featured", do: "Featured image", else: "Image" %>
          </label>
          <%= if @picker_browse do %>
            <bp-media-picker
              value={image_block_src(@block)}
              dataset={@dataset}
              scope-prefix={@scope_prefix}
              data-token={@api_token_raw}
              data-test-id="paper-block-image-picker"
            ></bp-media-picker>
          <% else %>
            <output class="bp-paper-picker-current" data-test-id="paper-picker-current">
              {image_block_src(@block)}
            </output>
          <% end %>
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
          if_rev={if(@doc_type == "paper", do: @paper_rev, else: @document_rev)}
        />

      <% _ -> %>
        <%!-- Genuinely-unhandled types are read-only in the MVP (view/delete/reorder).
             `table` (editable-table) and `action` (editable-action, the CTA button) are
             now canvas-eligible and render inside the run, so they no longer reach this
             per-block fallback. --%>
        <p class="bp-paper-edit-readonly">
          <%= @type %> blocks are not editable yet (view/delete/reorder only).
        </p>
    <% end %>
    """
  end

  defp editable_step_rows(%{"steps" => rows}) when is_list(rows),
    do: Enum.filter(rows, &(is_map(&1) and is_binary(&1["id"]) and &1["id"] != ""))

  defp editable_step_rows(_block), do: []

  defp editable_steps?(%{"steps" => rows} = block) when is_list(rows) do
    editable = editable_step_rows(block)
    ids = Enum.map(editable, & &1["id"])

    length(editable) == length(rows) and length(Enum.uniq(ids)) == length(ids) and
      Enum.all?(editable, &(is_nil(&1["title"]) or is_binary(&1["title"])))
  end

  defp editable_steps?(block), do: Map.get(block, "steps") == nil

  defp empty_step_body?(%{"children" => children}) when is_list(children), do: children == []
  defp empty_step_body?(%{"children" => children}) when children not in [nil, false], do: false
  defp empty_step_body?(row), do: Map.get(row, "blocks") in [nil, []]

  defp step_body_segments(row, canvas_enabled) do
    children = Blocks.container_children(Map.put(row, "type", "expandable"))

    if canvas_enabled,
      do: children |> PaperCanvas.partition_runs() |> PaperCanvas.with_run_ordinals(),
      else: Enum.map(Enum.filter(children, &is_map/1), &{:block, &1})
  end

  # Tolerant readers for the image block's `src` / `role` (t13). A raw-API
  # paper can carry a non-string in either key; the reader side degrades
  # (compose.ex stringish → skip), so the editor must too — a hostile map here
  # would raise Phoenix.HTML.Safe in the render and take the whole pane down.
  defp image_block_src(block) do
    case Map.get(block, "src") do
      src when is_binary(src) -> src
      _ -> ""
    end
  end

  defp image_block_role(block) do
    case Map.get(block, "role") do
      role when is_binary(role) -> role
      _ -> nil
    end
  end
end
