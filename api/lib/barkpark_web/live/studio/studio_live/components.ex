defmodule BarkparkWeb.Studio.StudioLive.Components do
  @moduledoc """
  Function components extracted from `BarkparkWeb.Studio.StudioLive` — the
  in-Studio live paper view (`studio_paper_view/1`) and the full Studio shell
  (`studio_live_shell/1`), plus the pure expected-field helpers. Imported back
  into StudioLive so the `<.studio_paper_view ...>` call sites in render/1 keep
  working verbatim.

  The Beta paper-editor cluster (`editor_mode_toggle/1`, `paper_block_editor/1`,
  `properties_panel/1`, `paper_block_fields/1` + their private helpers) lives in
  `Components.PaperEditor` to keep both files under the per-file token budget.
  This module imports it so the `<.paper_block_editor ...>` /
  `<.editor_mode_toggle ...>` call sites in `studio_paper_view/1` and
  `studio_live_shell/1` resolve verbatim. Behavior-preserving move.
  """
  use BarkparkWeb, :html

  import Phoenix.HTML, only: [raw: 1]
  import BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.{DocActions, PaperCanvas, Paths}

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
  # t9 — live task-block previews (block_id ⇒ preview entry), display-only rows
  # the Edit-mode boundary widgets paint (Shared.push_task_previews fills it).
  attr(:task_previews, :map, default: %{})
  attr(:shares_admin?, :boolean, default: false)
  attr(:dataset, :string, required: true)
  attr(:api_token_raw, :string, default: "")
  attr(:streams, :map, required: true)
  attr(:backlinks_used_by, :list, default: [])
  attr(:backlinks_linked, :list, default: [])
  attr(:backlinks_unlinked, :list, default: [])
  attr(:backlinks_open, :boolean, default: true)
  # t6 — WordPress-style metadata sidebar (doctrine Rule 4). All optional so the
  # call site can lean on the component's own defaults on first paint.
  attr(:sidebar_open, :boolean, default: true)
  attr(:sidebar_collapsed, :any, default: nil)
  attr(:sidebar_slug_draft, :string, default: nil)
  attr(:sidebar_slug_feedback, :any, default: nil)
  attr(:workspace_label, :string, default: nil)

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
                  canvas_eligible={true}
                  task_previews={@task_previews}
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
                  phx-hook="BarkparkValuerefInspect"
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
        <%!-- t6 + pdd-t11: the ONE WordPress-style document sidebar. The
              backlinks aside used to be a SECOND right panel stacked beside this
              one (the two-right-panels UX debt wave 1 pre-loaded into t11) —
              inbound references now fold into this sidebar's Relations section, so
              a paper carries a single calm metadata column. Collapsing it (or any
              section) never reflows or transforms the body — chrome around
              content. --%>
        <.paper_metadata_sidebar
          :if={@paper_doc}
          paper_doc={@paper_doc}
          dataset={@dataset}
          workspace_label={@workspace_label}
          panel_open={@sidebar_open}
          collapsed={@sidebar_collapsed}
          slug_draft={@sidebar_slug_draft}
          slug_feedback={@sidebar_slug_feedback}
          backlinks_used_by={@backlinks_used_by}
          backlinks_linked={@backlinks_linked}
          backlinks_unlinked={@backlinks_unlinked}
        />
      </div>
    </div>
    """
  end

  # ── t6: WordPress-style metadata sidebar (function component) ────────────────
  #
  # The calm right document panel (doctrine Rule 4). Sections: Publish
  # (status/visibility — read-only, see the section comment), Slug (instant
  # format validation),
  # Context (dataset/workspace, read-only), Labels, Relations. Only metadata that
  # FAILS the article test lives here — the title + featured image stay LOCKED
  # body blocks (t1/t4), never duplicated into the sidebar. Rule 5: no modes, no
  # overlays; every affordance is inline chrome. Section headers are real
  # <button>s so Enter/Space toggle them and `aria-expanded` rides each one; the
  # panel and every section collapse independently without touching the canvas.
  attr(:paper_doc, :map, required: true)
  attr(:dataset, :string, required: true)
  attr(:workspace_label, :string, default: nil)
  attr(:panel_open, :boolean, default: true)
  attr(:collapsed, :any, default: nil)
  attr(:slug_draft, :string, default: nil)
  attr(:slug_feedback, :any, default: nil)
  # pdd-t11: inbound references (backlinks), folded into the Relations section so
  # a paper carries ONE right panel instead of two stacked asides. All resolved
  # (each ref carries a :title from reverse_referencers) — never a raw id.
  attr(:backlinks_used_by, :list, default: [])
  attr(:backlinks_linked, :list, default: [])
  attr(:backlinks_unlinked, :list, default: [])

  def paper_metadata_sidebar(assigns) do
    paper = assigns.paper_doc
    status = (paper && Map.get(paper, :status)) || "draft"
    slug = assigns.slug_draft || (paper && Map.get(paper, :doc_id)) || ""
    feedback = assigns.slug_feedback || PaperCanvas.slug_feedback(slug)

    blocks =
      case paper do
        %{content: %{"blocks" => b}} when is_list(b) -> b
        _ -> []
      end

    assigns =
      assign(assigns,
        status: status,
        slug: slug,
        feedback: feedback,
        labels: PaperCanvas.paper_labels(paper),
        relations:
          blocks
          |> PaperCanvas.paper_relations()
          |> Enum.map(fn rel ->
            # The sidebar shows the referenced doc's TITLE, never the raw id
            # (the id stays as hover detail). Same resolver View mode uses;
            # a missing doc falls back to the id string, exactly like the body.
            Map.put(
              rel,
              :title,
              Barkpark.Content.reference_title(rel.id, rel.ref_type, assigns.dataset)
            )
          end)
      )

    ~H"""
    <aside
      class={"bp-doc-sidebar " <> if(@panel_open, do: "is-open", else: "is-collapsed")}
      data-test-id="paper-metadata-sidebar"
      aria-label="Document metadata"
    >
      <div class="bp-doc-sidebar__head">
        <button
          type="button"
          class="bp-doc-sidebar__collapse"
          phx-click="sidebar-toggle-panel"
          aria-expanded={to_string(@panel_open)}
          aria-controls="bp-doc-sidebar-body"
          title={if @panel_open, do: "Collapse document panel", else: "Expand document panel"}
          data-test-id="sidebar-toggle-panel"
        >
          <.icon name={if @panel_open, do: "chevron-down", else: "chevron-right"} size={16} />
        </button>
        <span :if={@panel_open} class="bp-doc-sidebar__title">Document</span>
      </div>

      <div :if={@panel_open} id="bp-doc-sidebar-body" class="bp-doc-sidebar__body">
        <%!-- Publish is READ-ONLY state, deliberately: papers publish IN PLACE
              (`Content.upsert_paper/1` always writes `doc_id = slug`,
              `status: "published"` — there is no drafts-twin row), while the
              doc-level `publish` / `unpublish` events ride the twin-row model
              (`Handlers.Doc` → `Content.publish_document/4`, which REQUIRES a
              `drafts.<slug>` row, and `unpublish_document/4`, which DELETES the
              published row and strands a `drafts.<slug>` twin that
              `Content.get_paper/3` — exact-id, used by pane_builder AND the
              public reader — can never resolve again). Wiring those buttons
              here would make Publish always fail and Unpublish brick the paper.
              A paper-aware publish action lands with the papers draft model
              (t5/t7 territory), not this slice. --%>
        <.sidebar_section
          key="publish"
          title="Publish"
          open={PaperCanvas.sidebar_section_open?(@collapsed, "publish")}
        >
          <div class="bp-doc-field">
            <span class="bp-doc-field__label">Status</span>
            <span class={"bp-doc-badge bp-doc-badge--#{@status}"} data-test-id="sidebar-status">
              {@status}
            </span>
          </div>
          <div class="bp-doc-field">
            <span class="bp-doc-field__label">Visibility</span>
            <span class="bp-doc-field__val" data-test-id="sidebar-visibility">
              {PaperCanvas.visibility_label(@status)}
            </span>
          </div>
        </.sidebar_section>

        <.sidebar_section
          key="slug"
          title="Slug"
          open={PaperCanvas.sidebar_section_open?(@collapsed, "slug")}
        >
          <% {tone, msg} = @feedback %>
          <form phx-change="sidebar-slug-change" class="bp-doc-slug">
            <input
              type="text"
              name="value"
              class="form-input bp-doc-slug__input"
              value={@slug}
              phx-debounce="150"
              spellcheck="false"
              autocomplete="off"
              aria-describedby="bp-doc-slug-fb"
              aria-invalid={to_string(tone == :danger)}
              data-test-id="sidebar-slug-input"
            />
            <p
              id="bp-doc-slug-fb"
              class={"bp-doc-slug__fb bp-doc-slug__fb--#{tone}"}
              role="status"
              data-tone={to_string(tone)}
              data-test-id="sidebar-slug-feedback"
            >
              {msg}
            </p>
          </form>
        </.sidebar_section>

        <.sidebar_section
          key="context"
          title="Context"
          open={PaperCanvas.sidebar_section_open?(@collapsed, "context")}
        >
          <div class="bp-doc-field">
            <span class="bp-doc-field__label">Dataset</span>
            <span class="bp-doc-field__val" data-test-id="sidebar-dataset">{@dataset}</span>
          </div>
          <div :if={@workspace_label} class="bp-doc-field">
            <span class="bp-doc-field__label">Workspace</span>
            <span class="bp-doc-field__val" data-test-id="sidebar-workspace">{@workspace_label}</span>
          </div>
        </.sidebar_section>

        <.sidebar_section
          key="labels"
          title="Labels"
          open={PaperCanvas.sidebar_section_open?(@collapsed, "labels")}
        >
          <%= if @labels == [] do %>
            <p class="bp-doc-empty" data-test-id="sidebar-labels-empty">No labels yet.</p>
          <% else %>
            <ul class="bp-doc-tags" data-test-id="sidebar-labels">
              <li :for={label <- @labels} class="bp-doc-tag">
                <.icon name="tag" size={11} /> {label}
              </li>
            </ul>
          <% end %>
        </.sidebar_section>

        <%!-- Relations = OUTBOUND references (this paper → other docs, from its
              body/fields) + INBOUND backlinks (other docs → this paper), folded
              into one section (pdd-t11: was a second right aside). A refresh
              re-queries the inbound edges; outbound relations come from the block
              list itself, so they need no refetch. Every row shows a resolved
              TITLE (reference_title for outbound, reverse_referencers' :title for
              inbound) — NEVER a raw id (wave-1 integration lesson). --%>
        <.sidebar_section
          key="relations"
          title="Relations"
          open={PaperCanvas.sidebar_section_open?(@collapsed, "relations")}
        >
          <% has_any =
            @relations != [] or @backlinks_used_by != [] or @backlinks_linked != [] or
              @backlinks_unlinked != [] %>
          <div class="bp-doc-rel-head">
            <button
              type="button"
              class="bp-doc-rel-refresh"
              phx-click="backlinks-refresh"
              title="Refresh inbound references"
              data-test-id="backlinks-refresh"
            >
              <.icon name="refresh-cw" size={12} />
            </button>
          </div>

          <%= if not has_any do %>
            <p class="bp-doc-empty" data-test-id="sidebar-relations-empty">No relations.</p>
          <% else %>
            <%!-- Outbound: docs THIS paper references (its own body/fields). --%>
            <section :if={@relations != []} class="bp-doc-rel-group">
              <h4 class="bp-doc-rel-group__h">References ({length(@relations)})</h4>
              <ul class="bp-doc-rels" data-test-id="sidebar-relations">
                <li :for={rel <- @relations} class="bp-doc-rel">
                  <span class="bp-doc-rel__label">{rel.label}</span>
                  <span class="bp-doc-rel__id" title={rel.id}>{rel.title}</span>
                </li>
              </ul>
            </section>

            <%!-- Inbound (backlinks): docs that reference THIS paper. Used-by
                  (valueref impact) first, then linked + derived mentions. Each
                  group renders only when non-empty (folded chrome stays calm). --%>
            <.backlink_group title="Used by" refs={@backlinks_used_by} test_id="backlinks-used-by" />
            <.backlink_group
              title="Linked mentions"
              refs={@backlinks_linked}
              test_id="backlinks-linked"
            />
            <.backlink_group
              title="Derived mentions"
              refs={@backlinks_unlinked}
              test_id="backlinks-unlinked"
            />
          <% end %>
        </.sidebar_section>
      </div>
    </aside>
    """
  end

  # One collapsible chrome section. The <button> header gives Enter/Space toggle
  # and `aria-expanded` for free; the body renders only when open, so collapsing
  # removes it from the flow WITHOUT reflowing the canvas (the sidebar is a
  # fixed-width flex column beside the body).
  attr(:key, :string, required: true)
  attr(:title, :string, required: true)
  attr(:open, :boolean, default: true)
  slot(:inner_block, required: true)

  defp sidebar_section(assigns) do
    ~H"""
    <section class="bp-doc-sec" data-test-id={"sidebar-section-" <> @key}>
      <h3 class="bp-doc-sec__h">
        <button
          type="button"
          class="bp-doc-sec__toggle"
          phx-click="sidebar-toggle-section"
          phx-value-section={@key}
          aria-expanded={to_string(@open)}
          aria-controls={"bp-doc-sec-body-" <> @key}
          data-test-id={"sidebar-section-toggle-" <> @key}
        >
          <.icon name={if @open, do: "chevron-down", else: "chevron-right"} size={14} />
          <span>{@title}</span>
        </button>
      </h3>
      <div :if={@open} id={"bp-doc-sec-body-" <> @key} class="bp-doc-sec__body">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  # One inbound-backlinks group inside the Relations section (pdd-t11). Renders
  # only when it has rows, so an ordinary paper with no dependents shows nothing.
  # Each ref carries a resolved :title (from reverse_referencers) — a row is a
  # <button> when the referencer is navigable (`from_doc_id`), else a static div;
  # both paths show the title, never the raw id. `open-backlink` jumps to it.
  attr(:title, :string, required: true)
  attr(:refs, :list, required: true)
  attr(:test_id, :string, required: true)

  defp backlink_group(assigns) do
    ~H"""
    <section :if={@refs != []} class="bp-doc-rel-group" data-test-id={@test_id}>
      <h4 class="bp-doc-rel-group__h">{@title} ({length(@refs)})</h4>
      <ul class="bp-doc-backlinks">
        <li :for={ref <- @refs}>
          <button
            :if={ref[:from_doc_id]}
            type="button"
            class="bp-doc-backlink is-clickable"
            phx-click="open-backlink"
            phx-value-slug={ref.from_doc_id}
            phx-value-type={ref.type}
            data-test-id="backlink-row"
          >
            <span class="bp-doc-backlink__title">{ref.title || "Untitled"}</span>
            <span class="bp-doc-backlink__meta">{ref.type} / {ref.via_field}</span>
          </button>
          <div :if={!ref[:from_doc_id]} class="bp-doc-backlink" data-test-id="backlink-row">
            <span class="bp-doc-backlink__title">{ref.title || "Untitled"}</span>
            <span class="bp-doc-backlink__meta">{ref.type} / {ref.via_field}</span>
          </div>
        </li>
      </ul>
    </section>
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
            <%!-- Presence hoist: scan the presence list ONCE per pane (filter by
                  dataset, group by doc_id) instead of re-running PresenceState.on_doc/3
                  inside the per-item loop below (O(N×M) → O(N+M) on every
                  presence_diff re-render). Map.get(_, item.id, []) is exactly
                  on_doc's predicate: pre-filtering by dataset then grouping by
                  doc_id yields the same per-item list; nil-doc_id metas bucket
                  under the nil key and are never fetched. --%>
            <% presences_by_doc =
                 @presences
                 |> Enum.filter(&(Map.get(&1, :dataset) == @dataset))
                 |> Enum.group_by(& &1.doc_id) %>
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
                  <% item_presences = Map.get(presences_by_doc, item.id, []) %>
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
          task_previews={@paper_task_previews}
          shares_admin?={@shares_admin?}
          dataset={@dataset}
          streams={@streams}
          backlinks_used_by={@backlinks_used_by}
          backlinks_linked={@backlinks_linked}
          backlinks_unlinked={@backlinks_unlinked}
          backlinks_open={@backlinks_open}
          sidebar_open={Map.get(assigns, :sidebar_open, true)}
          sidebar_collapsed={Map.get(assigns, :sidebar_collapsed)}
          sidebar_slug_draft={Map.get(assigns, :sidebar_slug_draft)}
          sidebar_slug_feedback={Map.get(assigns, :sidebar_slug_feedback)}
          workspace_label={
            case Map.get(assigns, :current_workspace) do
              %{name: name} when is_binary(name) and name != "" -> name
              %{slug: slug} when is_binary(slug) -> slug
              _ -> nil
            end
          }
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
              owns the Canvas2D surface (bp-graph.js); its div carries the CONSTANT id
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
            doc_conflict={@doc_conflict}
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

      <%!-- valueref edit-through inspector (lvw-t10, writeback v1.5).
            Opened by paper-valueref-inspect (view-mode click on a valueref
            span, delegated by BarkparkValuerefInspect). The write control —
            the EXPLICIT edit-through affordance — renders ONLY when the
            server authorized the caller against the TARGET canonical doc's
            write scope; an unauthorized/cross-scope target gets the denied
            note and NO control (and the confirm handler re-authorizes
            server-side regardless). The impact list is reverse_referencers
            under the caller's scope opts — out-of-scope referencers are
            dropped entirely upstream; there is deliberately NO "and K you
            cannot see" remainder here. --%>
      <%= if @valueref_panel do %>
        <div class="image-picker-overlay" phx-click="valueref-writeback-close"></div>
        <div class="delete-modal" data-test-id="valueref-writeback-modal">
          <div class="delete-modal-header">
            <span style="font-weight: 600; font-size: 16px;">Shared value</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="valueref-writeback-close">x</button>
          </div>
          <div class="delete-modal-body">
            <p class="text-sm" style="margin-bottom: 8px;">
              <code><%= @valueref_panel.target %>.<%= @valueref_panel.field %></code>
              <%= if @valueref_panel[:title] do %>
                &mdash; <strong><%= @valueref_panel.title %></strong>
              <% end %>
            </p>
            <%= if @valueref_panel.authorized do %>
              <p class="text-sm" style="margin-bottom: 12px;">
                Current canonical value:
                <strong data-test-id="valueref-current-value"><%= @valueref_panel.current_value || "(unset)" %></strong>
              </p>
              <p class="text-sm" style="margin-bottom: 8px;" data-test-id="valueref-impact">
                Writing to the canonical source changes
                <strong><%= @valueref_panel.impact.count %></strong>
                doc<%= if @valueref_panel.impact.count != 1, do: "s" %>:
              </p>
              <div class="delete-ref-list">
                <%= for ref <- @valueref_panel.impact.referencers do %>
                  <div class="delete-ref-item" data-test-id="valueref-impact-ref">
                    <span class="delete-ref-title"><%= ref.title || "Untitled" %></span>
                    <span class="delete-ref-meta"><%= ref.type %> / <%= ref.kind %></span>
                  </div>
                <% end %>
              </div>
              <%= if @valueref_panel[:error] do %>
                <p class="text-sm" style="color: #b91c1c; margin: 8px 0;" data-test-id="valueref-error">
                  <%= @valueref_panel.error %>
                </p>
              <% end %>
              <form phx-submit="valueref-writeback-confirm" data-test-id="valueref-writeback-form">
                <input
                  type="text"
                  name="value"
                  class="form-input"
                  value={@valueref_panel.current_value}
                  autocomplete="off"
                />
                <div class="delete-modal-actions" style="margin-top: 12px;">
                  <button type="button" class="btn btn-sm" phx-click="valueref-writeback-close">Cancel</button>
                  <button type="submit" class="btn btn-primary btn-sm" data-test-id="valueref-writeback-confirm">
                    Write to canonical
                  </button>
                </div>
              </form>
            <% else %>
              <p class="text-sm" data-test-id="valueref-writeback-denied">
                This value lives on a canonical document you do not have write
                access to. It can only be changed at its source.
              </p>
              <div class="delete-modal-actions">
                <button type="button" class="btn btn-sm" phx-click="valueref-writeback-close">Close</button>
              </div>
            <% end %>
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
