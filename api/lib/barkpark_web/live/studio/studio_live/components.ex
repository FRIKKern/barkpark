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
  alias BarkparkWeb.Studio.StudioLive.{DocActions, Paths}

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
  attr(:backlinks_used_by, :list, default: [])
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
                  canvas_eligible={true}
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
            <%!-- Used by / impact (lvw-t3): docs whose BODY valueref-references
                  this doc as a canonical value. Rendered FIRST (it is the
                  impact panel) and only when non-empty — an ordinary paper
                  with no value-dependents gets no noise section. The list is
                  the fail-closed reverse_referencers result: out-of-scope
                  referencers were dropped upstream (no stub, no aggregate
                  count), and the published-only corpus means a draft-only
                  referencer is absent BY DESIGN (D1). --%>
            <section
              :if={@backlinks_used_by != []}
              class="bp-backlinks-section"
              data-test-id="backlinks-used-by"
            >
              <h4 class="bp-backlinks-section-title">Used by ({length(@backlinks_used_by)})</h4>
              <ul class="bp-backlinks-list">
                <li :for={ref <- @backlinks_used_by}>
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
            </section>

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
          shares_admin?={@shares_admin?}
          dataset={@dataset}
          streams={@streams}
          backlinks_used_by={@backlinks_used_by}
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
