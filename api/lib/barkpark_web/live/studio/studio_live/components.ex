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
  # `Icons.drawable_name/2` guards the DYNAMIC `name={…}` sites below — a pane
  # item's icon is Structure/schema/plugin data, so it can be nil or an
  # unmapped string, and both used to reach `icon/1` bare (spd-w18-nil-icon-500:
  # HTTP 500 on /studio/rest and /studio/plugins). The literal `name="…"` sites
  # in this file stay literal — the icons tripwire owns those.
  alias BarkparkWeb.Icons
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.{DocActions, PaperCanvas, Paths}
  alias Phoenix.LiveView.JS

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
  attr(:paper_links, :map, default: %{})
  attr(:shares_admin?, :boolean, default: false)
  attr(:dataset, :string, required: true)
  attr(:api_token_raw, :string, default: "")
  attr(:streams, :map, required: true)
  attr(:backlinks_used_by, :list, default: [])
  attr(:backlinks_linked, :list, default: [])
  attr(:backlinks_unlinked, :list, default: [])
  # t6 — WordPress-style metadata sidebar (doctrine Rule 4). All optional so the
  # call site can lean on the component's own defaults on first paint.
  attr(:sidebar_open, :boolean, default: true)
  # D91: "the user explicitly asked for the inspector", threaded down to the
  # <aside> as `data-user-opened`. Defaults false so an un-threaded call site
  # gets the bucket-aware closed default rather than a silent always-open.
  attr(:sidebar_user_opened, :boolean, default: false)
  # spd-b29f — the desk's post-connect width bucket, threaded PAST this component
  # to the inspector's collapse control so it can announce what the user SEES
  # rather than what the server holds. Default "wide" matches mount's seed (D91),
  # so an un-threaded call site renders byte-identically to the pre-b29f build.
  attr(:width_bucket, :string, default: "wide")
  attr(:sidebar_collapsed, :any, default: nil)
  attr(:sidebar_slug_draft, :string, default: nil)
  attr(:sidebar_slug_feedback, :any, default: nil)
  attr(:workspace_label, :string, default: nil)
  # sup-w5 — the socket-owned save mirror (Shared.Paper computes both on every
  # write). Threaded into the canvas <.paper_block_editor> below so the footer
  # echoes the REAL status and a plugin-halt raises the shared banner, instead
  # of the old hardcoded "✓ Auto-saved" that lied through "Save failed"/halts.
  # Both default calm — save_status is assigned ONLY in write handlers, so it is
  # UNASSIGNED on a fresh paper open (the outer call site Map.get-guards it).
  attr(:save_status, :string, default: "")
  attr(:paper_halt, :string, default: nil)
  # spd-w19 / D257 — the `/w/:ws/p/:proj` scope prefix, threaded from the shell.
  # It was MISSING (a third instance of the b39 missing-thread class): every URL
  # this component emits fell to `assigns[:scope_prefix] || ""`, which on a
  # scoped Studio mount — the ONLY Studio mount since the P3 cutover — produced
  # an UNROUTABLE flat `/d/:dataset/studio/...` href. The default keeps a
  # hypothetical unthreaded call site rendering the flat grammar, which
  # `doc_list_href/3` at the bottom of this module now spells routably too.
  attr(:scope_prefix, :string, default: "")
  # spd-bl-focus-after-select — threaded through to document_header.
  attr(:focus_on_mount, :boolean, default: false)

  # ── THERE IS NO `doc_actions` ATTR, AND THAT IS THE RULING (spd-b34) ────────
  #
  # `DocActions.resolved_doc_actions/1` is threaded into `studio_editor_shell`
  # — the CLASSIC branch — and into that branch only. Its absence here is a
  # decision, not a forgotten attribute, and it was ruled explicitly rather
  # than left to be inferred from an omission:
  #
  #   THE PAPER PANE OWNS ITS OWN HEADER. It carries Share, and since #13042 a
  #   Publish control (drafts only, `data-test-id="paper-publish"`), plus the
  #   sidebar metadata affordances. The classic actions — open-secondary-picker,
  #   select-secondary, duplicate-doc, view-graph — are EXCLUDED ON PURPOSE,
  #   because the paper surface is a single-document reading/writing canvas
  #   whose secondary pane is the paper SIDEBAR, not a second editor.
  #
  # So `doc_actions` is not the repair for a missing paper affordance. Anything
  # a paper needs from that set is added to THIS header explicitly, one control
  # at a time, with its own handler and its own reason — never by threading the
  # whole classic bar in, which would also drag in three actions the surface has
  # no meaning for.
  #
  # Pinned in BOTH directions (so a refactor cannot re-decide it by accident) by
  # `test/barkpark_web/live/studio/studio_paper_doc_actions_ruling_test.exs`:
  # threading the bar in reds the exclusion arm, dropping the pane's own
  # controls reds the inclusion arm.
  def studio_paper_view(assigns) do
    slug = assigns.paper_doc && assigns.paper_doc.doc_id
    title = (assigns.paper_doc && assigns.paper_doc.title) || slug || "Paper"

    edit_blocks =
      case assigns.paper_doc do
        %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
        _ -> []
      end

    # Doctrine rule 5 — no modes. With the canvas the mainline default (D7/D9),
    # opening a block-backed paper IS the editor: the always-editable canvas
    # renders DIRECTLY on open, with no View⇄Edit toggle and no `paper_edit_mode`
    # gate. `paper_edit_mode` is derived-away here — the surface follows the flag
    # + block_mode, not a mode the user has to be in.
    #
    # The flag-OFF opt-out (`BARKPARK_PAPER_CANVAS=0`, D3) keeps the legacy shape
    # verbatim: the read-only streamed View pane PLUS the toggle, whose
    # `paper_edit_mode` still gates Edit. HTML-only (legacy, blockless) papers have
    # nothing to edit — they render the streamed/raw body in BOTH paths.
    canvas_on = PaperCanvas.paper_canvas_enabled?()

    show_editor = assigns.paper_block_mode && (canvas_on || assigns.paper_edit_mode)

    # spd-b39 / D169 — TIER 3: the inspector is a SUMMONED DESTINATION, not a
    # dock. The tier predicate itself now lives in ONE place —
    # `inspector_destination?/2` at the bottom of this module — because this
    # module used to compute the same enumeration twice (here, and again in
    # `paper_metadata_sidebar/1`) and a two-copy predicate is a two-copy bug.
    # It is a bare `defp` at MODULE BOTTOM on purpose: declared underneath an
    # `attr(...)` block Phoenix binds the pending attrs to it and raises
    # "cannot declare attributes for function inspector_destination?/2.
    # Components must be functions with arity 1".
    #
    # `has_editor?` is NOT implied here (this component renders with or without
    # a paper), so the paper check stays at this call site; the sidebar's own
    # call site is already under `:if={@paper_doc}`.
    inspector_destination? =
      assigns.paper_doc != nil and
        inspector_destination?(assigns.width_bucket, assigns.sidebar_user_opened)

    # spd-w18 — the pane's REAL document type. The paper pane is opened by every
    # blocks-doc type (`PaneBuilder` keys on `Content.blocks_type?/1`), so a
    # session lands on this exact component; the header badge used to print the
    # literal "paper" over it and the empty-body sentence used to call it a
    # paper. Fall back to the paper type ONLY when there is no document at all,
    # so the no-document paint stays byte-identical.
    doc_type = (assigns.paper_doc && Map.get(assigns.paper_doc, :type)) || Content.paper_type()

    # spd-w18 review — mirror the OP layer's own refusal so the never-blank
    # notice never offers a repair the write path rejects.
    # `Papers.BlockOps.reject_implicit_html_conversion/1` halts any block op on a
    # document whose content carries a `body_html` STRING while `blocks` is not a
    # list — precisely the shape `blank_body?/1` routes here when that HTML
    # paints nothing (`"<p></p>"`, `"&nbsp;"`, `""`).
    html_backed_body =
      is_binary(get_in((assigns.paper_doc && assigns.paper_doc.content) || %{}, ["body_html"]))

    # spd-bl-publish-affordance-triple — whether the open document is a genuine
    # `drafts.<slug>` row. Only that shape can take `Content.publish_document/4`
    # (which REQUIRES a drafts twin), so the Publish control below renders for
    # it and ONLY for it — absent on an in-place-published paper, where the
    # action could never succeed.
    paper_draft? = (assigns.paper_doc && Map.get(assigns.paper_doc, :status)) == "draft"

    assigns =
      assign(assigns,
        slug: slug,
        title: title,
        doc_type: doc_type,
        html_backed_body: html_backed_body,
        edit_blocks: edit_blocks,
        canvas_on: canvas_on,
        show_editor: show_editor,
        paper_draft?: paper_draft?,
        inspector_destination: inspector_destination?
      )

    ~H"""
    <div class="editor-panel" data-role="content" data-test-id="studio-paper-editor">
      <.document_header dataset={@dataset} title={@title} focus_on_mount={@focus_on_mount}>
        <:status_pill>
          <span class="badge badge-published">{@doc_type}</span>
        </:status_pill>
        <:actions>
          <%!-- spd-bl-publish-affordance-triple — the hand path's missing
                Publish. The doc-actions Publish CTA reaches the DOM only
                through the studio_editor_shell branch, and papers do not take
                that branch BY DESIGN (the ruling above `studio_paper_view/1`),
                so the fix was to give this header its own control rather than
                to thread the classic bar in. That is the pattern for every
                future paper affordance. Draft-only (see paper_draft? above);
                the handler re-guards server-side and the publish wall itself
                is untouched (charter D229/D230). --%>
          <button
            :if={@slug && @paper_draft?}
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="paper-publish"
            aria-label="Publish"
            data-test-id="paper-publish"
          >
            Publish
          </button>
          <%!-- View ⇄ Edit toggle — the flag-OFF OPT-OUT path ONLY. With the
                canvas on (the D7/D9 default) there are no modes: the editor is
                always open, so this toggle is not rendered (rule 5). It survives
                for `BARKPARK_PAPER_CANVAS=0`, where View is the read-only live
                stream and Edit renders the per-block controls. Block-backed
                papers only. --%>
          <button
            :if={@slug && @paper_block_mode && not @canvas_on}
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
            href={Paths.paper_path(@scope_prefix, @slug)}
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
        <%!-- spd-b39 / D164/D165 — the covered content leaves the a11y tree.
              At Tier 3 the inspector is an opaque `inset:0` panel over this
              body, so everything under it is unreachable by sight yet fully
              reachable by Tab and by AT. `inert` is the honest fix.

              IT MUST BE SERVER-RENDERED, never JS-set. Proven twice on the
              deployed build: an imperative `el.inert = true` is stripped by
              morphdom on the very next LiveView diff — and toggling the
              inspector IS that diff — so a hook self-disables on first use
              with no error to show for it. As a HEEx attribute the value is
              part of the diff instead of a casualty of it.

              `aria-modal` is REFUSED (D164): there is no outside content to
              mark as outside — at phone `display_state/4` returns :hidden for
              every pane, and a scrim beneath an opaque inset:0 panel can never
              be hit-tested. The truthful semantics are the ones below: a named
              landmark on the destination, a truthful `aria-expanded` on its
              control, and `inert` on what the panel covers. --%>
        <div class="editor-body editor-panel-main bp-paper-body" inert={@inspector_destination}>
          <%!-- The accessible name is added ONLY when the always-editable
                canvas is the surface (@canvas_on keeps the OFF path
                byte-identical, D3; @show_editor keeps the name honest — an
                HTML-only legacy paper on the ON path renders a READ-ONLY raw
                body, which must not be announced as "Editing"). --%>
          <main
            class="bp-paper-shell bp-paper-surface"
            data-test-id="studio-paper-shell"
            aria-label={@canvas_on && @show_editor && @slug && "Editing #{@title}"}
          >
            <%!-- Sentinel: rendered once, OUTSIDE the streamed/re-assigned
                  container. It survives a handle_info DOM diff but would be
                  torn down by a remount/navigate — the no-reload proof. --%>
            <div id="paper-sentinel" data-slug={@slug} hidden></div>

            <%= cond do %>
              <% is_nil(@slug) -> %>
                <article id="paper-body" data-rev={@paper_rev}>
                  <p id="paper-empty">No paper selected.</p>
                </article>
              <% @show_editor -> %>
                <%!-- Rule 5 — opening a paper IS the editor. On the canvas
                      default this renders DIRECTLY on open (no toggle); on the
                      opt-out path it renders once the user toggles into Edit. --%>
                <.paper_block_editor
                  slug={@slug}
                  doc_type={@doc_type}
                  blocks={@edit_blocks}
                  paper_rev={@paper_rev}
                  dataset={@dataset}
                  api_token_raw={@api_token_raw}
                  scope_prefix={@scope_prefix}
                  canvas_eligible={true}
                  task_previews={@task_previews}
                  paper_links={@paper_links}
                  save_status={@save_status}
                  paper_halt={@paper_halt}
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
              <% blank_body?(@paper_html) -> %>
                <%!-- spd-w18 — THE NEVER-BLANK ARM. A document RESOLVED into the
                      pane but with no renderable body used to fall through to
                      the legacy HTML arm below and paint an EMPTY <article>:
                      the paper shell plus the metadata sidebar and nothing
                      between — no editor, no message, no way out. That is the
                      owner's bug in its general form (an unrenderable document
                      answering "I cannot render this" with absence), and it is
                      still reachable for any document whose content carries no
                      block LIST at all (`Projection.read_blocks/1` returns nil
                      ⇒ `paper_block_mode` false ⇒ `show_editor` false) and no
                      body_html either — the two production draft-only fossils.

                      The <article> wrapper and its data-rev are kept verbatim so
                      the DOM contract of this branch is unchanged; only the
                      emptiness inside it is replaced by a named, announced
                      state.

                      spd-w19 — its id is the ONE thing that had to change, and
                      it is a correctness fix, not cosmetics. This arm shipped
                      with the SAME `paper-body-<slug>` id the streamed block arm
                      uses, and the repair below crosses precisely that
                      boundary: with `BARKPARK_PAPER_CANVAS=0` the repaired
                      document renders the streamed arm, so LiveView saw one node
                      keep its id while GAINING `phx-update="stream"` — and a
                      stream container never removes children it did not insert
                      (`dom_patch.js` deletes only `[data-phx-stream-ref]` rows
                      on reset). The notice would have SURVIVED its own repair,
                      sitting above the new paragraph. `LiveViewTest` refuses the
                      same transition outright ("phx-update stream requires
                      setting an ID on each child"), which is how it was caught.
                      A distinct id makes the swap a node REPLACEMENT, which is
                      what a swap is. --%>
                <article id={"paper-body-unrenderable-#{@slug}"} data-rev={@paper_rev}>
                  <%!-- The id the human owns is the PUBLISHED id: `drafts.` is a
                        storage prefix, and a never-published fossil arrives here
                        as `drafts.paper-…` (the same normalisation the sidebar's
                        slug field does — showing the raw prefix is the product
                        quoting its own plumbing back at the author). The
                        <article> id above keeps the raw slug, unchanged. --%>
                  <.unrenderable_document_notice
                    doc_id={Content.published_id(@slug)}
                    doc_type={@doc_type}
                    html_backed={@html_backed_body}
                    repairable={@doc_type == Content.paper_type() and not @html_backed_body}
                    if_rev={@paper_rev}
                    list_href={doc_list_href(@scope_prefix, @doc_type, @dataset)}
                  />
                </article>
              <% true -> %>
                <%!-- HTML-only (legacy): whole opaque body, re-assigned on
                      update. Keyed on the slug too so a jump swaps the node.

                      spd-w18 — its id is `paper-body-legacy-<slug>`, NOT the
                      streamed arm's `paper-body-<slug>`, for exactly the reason
                      spd-w19 gave the never-blank arm its own id one clause
                      above. A legacy `body_html` paper that GAINS a block list
                      while its pane is open (an ingest write, or any future
                      html-to-blocks path) crosses the same boundary: with
                      `BARKPARK_PAPER_CANVAS=0` the converted document renders
                      the STREAMED arm, so a shared id meant one node kept its
                      identity while GAINING `phx-update="stream"` — and a
                      stream container never removes children it did not insert
                      (`dom_patch.js` deletes only `[data-phx-stream-ref]` rows
                      on reset). The opaque raw body would have SURVIVED its own
                      replacement, stacked above the streamed blocks;
                      `LiveViewTest` refuses the same transition outright
                      ("phx-update stream requires setting an ID on each
                      child"), which is how it is pinned. A distinct id makes
                      the swap a node REPLACEMENT, which is what a swap is.

                      Nothing keys on the old id: every `#paper-body…` CSS rule
                      in `paper-surface.css` pins the EXACT id `#paper-body`
                      (the reader's container and the nil-slug arm), never the
                      slug-suffixed Studio one, so this rename touches no
                      styling. --%>
                <article id={"paper-body-legacy-#{@slug}"} data-rev={@paper_rev}>
                  {raw(@paper_html)}
                </article>
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
          user_opened={@sidebar_user_opened}
          width_bucket={@width_bucket}
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

  # ── spd-w18: the never-blank state for a resolved-but-unrenderable doc ───────
  #
  # A document the pane RESOLVED but cannot render must say so BY NAME. Modelled
  # on `StudioComponents.Editor.doc_conflict_banner/1` (role="alert" +
  # aria-live="assertive" + a stable data-test-id + a recovery control carrying
  # its own test-id) and deliberately NOT on `empty_editor/1`, which has no
  # action slot — an actionless empty state is exactly where the owner's bug
  # landed.
  #
  # It carries four things, because a state that omits any of them is still a
  # shrug: the document's OWN id, its REAL type (not the literal "paper"), a
  # plain-language reason, and at least one keyboard-focusable way out. The way
  # out is a REAL repair on the paper path — `paper-add-block` appends through
  # `Content.apply_paper_block_op/4`, whose `get_in(content, ["blocks"]) || []`
  # mints the missing list — and a plain link back to the type's list for the
  # types whose pane is read-only (a session refuses writes by design, so
  # offering it a repair button would be a second lie).
  #
  # spd-w18 review — `repairable` is NOT "is a paper". The op layer's
  # `reject_implicit_html_conversion/1` HALTS an append on a document that has a
  # `body_html` STRING but no block list, and `blank_body?/1` deliberately calls
  # a visually-empty `"<p></p>"` / `"&nbsp;"` body blank — so an HTML-backed
  # blank paper reaches this notice and the write layer would refuse its repair.
  # A button that cannot do what it says is the owner's complaint in a new
  # costume, so that case gets the honest reason and the link only.
  attr(:doc_id, :string, required: true)
  attr(:doc_type, :string, required: true)
  attr(:repairable, :boolean, default: false)
  attr(:html_backed, :boolean, default: false)
  attr(:if_rev, :integer, required: true)
  attr(:list_href, :string, required: true)

  def unrenderable_document_notice(assigns) do
    ~H"""
    <div
      class="bp-paper-unrenderable"
      role="alert"
      aria-live="assertive"
      data-test-id="paper-unrenderable-notice"
      data-doc-id={@doc_id}
      data-doc-type={@doc_type}
    >
      <p class="bp-paper-unrenderable-title">
        Studio cannot render the body of this {@doc_type}.
      </p>
      <p :if={not @html_backed} class="bp-paper-unrenderable-reason">
        <code>{@doc_id}</code> ({@doc_type}) was stored without a body block list and without
        saved HTML, so there is nothing here to show or edit yet. The document itself is intact —
        its metadata is in the panel beside this message.
      </p>
      <p :if={@html_backed} class="bp-paper-unrenderable-reason">
        <code>{@doc_id}</code> ({@doc_type}) was stored as saved HTML that renders nothing a reader
        can see, and it has no body block list. Studio will not silently convert stored HTML into
        blocks, so the body cannot be started from here — the document itself is intact, and its
        metadata is in the panel beside this message.
      </p>
      <div class="bp-paper-unrenderable-actions">
        <button
          :if={@repairable}
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="paper-add-block"
          phx-value-block-type="paragraph"
          phx-value-if_rev={@if_rev}
          data-test-id="paper-unrenderable-start-body"
        >
          Start the body with a paragraph
        </button>
        <a href={@list_href} class="btn btn-ghost btn-sm" data-test-id="paper-unrenderable-back">
          Back to the {@doc_type} list
        </a>
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
  # D91. Distinct from `panel_open` and NOT a synonym for it: `panel_open` is
  # the server's state (and it also gates whether the body/title exist in the
  # DOM at all), while this says only whether the user ASKED. The pair spans
  # three states, not two — collapsed (body absent), open-and-asked-for
  # (visible everywhere), and open-but-never-asked, which below the `wide`
  # bucket the cascade paints as the collapsed strip. CSS-hidden is not
  # collapsed; do not conflate them.
  attr(:user_opened, :boolean, default: false)
  # spd-b29f. The third input the collapse control needs to tell the truth: below
  # `wide`, spd-b29's cascade paints an open-but-never-asked-for inspector AS the
  # collapsed strip (D102), so `panel_open` alone made the button announce
  # aria-expanded="true" over 41px of chrome — the a11y lie #4633 landed to fix.
  # Default "wide" is mount's own seed (D91): at first byte this component paints
  # exactly what it painted before, and the announcement reconciles with the rest
  # of the bucket-aware desk once the real bucket arrives post-connect.
  attr(:width_bucket, :string, default: "wide")
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

    # spd-b29f — what the control ANNOUNCES, as distinct from what the DOM holds.
    # `panel_open` keeps its existing job (it gates whether the title/body exist
    # at all); this says only "can the reader actually SEE an open panel right
    # now". The three states of the D91 pair collapse to two here: open-and-asked
    # and (below `wide`) open-but-never-asked are geometrically identical strips,
    # so they must announce identically too. Never gate rendering on this — the
    # pixels at first byte must not move, only the announcement.
    visually_open? =
      assigns.panel_open && (assigns.width_bucket == "wide" || assigns.user_opened)

    # spd-b39 / D169 — the SAME enumeration the paper view computes for `inert`
    # (studio_paper_view above), now through the ONE shared predicate at the
    # bottom of this module rather than a second hand-written copy.
    destination? = inspector_destination?(assigns.width_bucket, assigns.user_opened)

    # D167 — the header tells the truth. At Tier 3 this panel is not a strip of
    # chrome beside the document, it IS the screen, so its title must name the
    # document you came from rather than the literal word "Document", and its
    # control must point the way the action goes (back, not down). Mirrors the
    # title expression in `studio_paper_view/1` above — same fallback ladder.
    destination_title = (paper && Map.get(paper, :title)) || slug || "Paper"

    # spd-bl-publish-affordance-triple — the metadata affordances below render
    # only for a genuine drafts row (same predicate as the pane's Publish
    # control): the whole-content meta-write path can only land on a draft.
    draft? = status == "draft"

    description =
      case paper && Map.get(paper, :content) do
        %{"description" => d} when is_binary(d) -> d
        _ -> ""
      end

    assigns =
      assign(assigns,
        status: status,
        slug: slug,
        draft?: draft?,
        description: description,
        destination: destination?,
        destination_title: destination_title,
        feedback: feedback,
        visually_open: visually_open?,
        labels: PaperCanvas.paper_label_entries(paper),
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
      id="bp-doc-sidebar"
      class={"bp-doc-sidebar " <> if(@panel_open, do: "is-open", else: "is-collapsed")}
      data-user-opened={@user_opened && ""}
      data-role="inspector"
      data-test-id="paper-metadata-sidebar"
      data-inspector-destination={@destination && ""}
      aria-label={if @destination, do: "Document metadata for #{@destination_title}", else: "Document metadata"}
      tabindex={@destination && "-1"}
    >
      <%!-- spd-w12 / D173 — THE KEYBOARD EXIT. Escape leaves the destination.

            THE LISTENER IS THE HOOK'S OWN, AT BUBBLE PHASE, AND CAPTURE IS
            FORBIDDEN. LiveView's `phx-window-keydown` would register the right
            phase but offers NO client-side veto seam (`on()` is a bare
            bubble-phase `window.addEventListener` and `bind()` pushes
            unconditionally), and this binding needs a veto — see the aside
            comment on the hook in root.html.heex. Capture in EITHER placement
            eats the nested-menu grammar: measured in a real browser, a
            window-CAPTURE hook with the command palette open runs FIRST
            (hook=1 menu=1, so Escape closes the inspector instead of the
            palette), and document-CAPTURE fails identically because the menus
            register their own capture listener inside `open()`
            (slash-menu.js:202) — mounted earlier, our hook is still first.
            An aside-scoped listener is dead for the real case: an Escape
            targeted at <body> never reaches it at all.

            NESTED PRECEDENCE IS PRESERVED, NOT WORKED AROUND. The slash menu,
            the wikilink menu, the `#` tag menu and the command palette each
            `stopImmediatePropagation()` at document CAPTURE
            (slash-menu.js:436-439, wikilink-menu.js:251-254), so a bubble-phase
            window listener NEVER sees the first Escape while one of them is
            open: the first Escape closes the menu, the second leaves the
            destination. That is the nested-modal grammar for free.

            NO `phx-keydown` MAY BE ADDED ANYWHERE INSIDE THIS SUBTREE. Standing
            law: a focused element carrying `phx-keydown` suppresses EVERY
            `phx-window-keydown` on the page — live_socket.js matches the RAW
            event target with no ancestor walk — so one such attribute would
            silently kill the desk's other window bindings.

            FOCUS IN, THEN FOCUS BACK (D165/D163). `phx-mounted` moves focus
            onto the destination landmark itself the moment Tier 3 renders
            (this element exists ONLY at Tier 3, so mount IS the transition);
            the dismiss controls carry `JS.focus(to: …)` back to the trigger.
            Focus-return has NO precedent anywhere in `api/lib` — the one
            APG-cited focus-trapping primitive in this repo lives in
            `cloud/priv/static/app.js` and is OUT OF FENCE (D163); it is not
            ported here, and `aria-modal` stays REFUSED (D164).
            On sequencing: `inert`'s blur is ASYNCHRONOUS (~38ms), so
            focus-in-first is an ARIA-correctness requirement and NOT a race
            against a synchronous blur — and in this layout it cannot race at
            all, because the focus target (this aside) is a SIBLING of the
            inert `.editor-body`, never inside it. Any code that sets inert and
            then synchronously reads `document.activeElement` reads stale
            focus. --%>
      <div
        :if={@destination}
        id="bp-inspector-escape"
        phx-hook="InspectorEscape"
        phx-mounted={JS.focus(to: "#bp-doc-sidebar")}
        data-escape-key="Escape"
        data-escape-event="sidebar-toggle-panel"
        data-escape-veto=".bp-paper-format"
        data-escape-return="#bp-doc-sidebar-toggle"
        hidden
      >
      </div>
      <div class="bp-doc-sidebar__head">
        <%!-- D167. At Tier 3 this control is the ONLY way out of a full-screen
              destination, so the glyph must point the way the action goes:
              `arrow-left`, not `chevron-down`. It stays one button and one
              event — `sidebar-toggle-panel` is already classified in caps.ex,
              so the return grammar costs ZERO new capability entries.

              `aria-expanded` is the truthful half of the D164 refusal: no
              `aria-modal` anywhere, just an honest expanded/collapsed state on
              the control that owns `#bp-doc-sidebar-body`. --%>
        <button
          type="button"
          id="bp-doc-sidebar-toggle"
          class="bp-doc-sidebar__collapse"
          phx-click={dismiss_or_toggle(@destination, "#bp-doc-sidebar-toggle")}
          aria-expanded={to_string(@visually_open)}
          aria-controls="bp-doc-sidebar-body"
          title={
            cond do
              @destination -> "Back to #{@destination_title}"
              @visually_open -> "Collapse document panel"
              true -> "Expand document panel"
            end
          }
          data-test-id={if @destination, do: "sidebar-dismiss", else: "sidebar-toggle-panel"}
        >
          <.icon
            name={
              cond do
                @destination -> "arrow-left"
                @visually_open -> "chevron-down"
                true -> "chevron-right"
              end
            }
            size={16}
          />
        </button>
        <span :if={@panel_open} class="bp-doc-sidebar__title">
          {if @destination, do: @destination_title, else: "Document"}
        </span>
      </div>

      <div :if={@panel_open} id="bp-doc-sidebar-body" class="bp-doc-sidebar__body">
        <%!-- Publish state — read-only for an IN-PLACE-published paper only
              (spd-bl-publish-affordance-triple corrected the old rationale
              here, which claimed it for every paper): `Content.upsert_paper/1`
              always writes `doc_id = slug`, `status: "published"` — no
              drafts-twin row — so the doc-level `publish` / `unpublish`
              events (which REQUIRE a `drafts.<slug>` row / would DELETE the
              published row and strand an unresolvable twin) can never apply
              to THAT shape. But every HAND-created paper is the opposite
              shape: `Content.create_document` forces
              `doc_id = DraftId.draft_id(raw_id)` and coerces status to
              "draft" — a genuine `drafts.<slug>` row, exactly what
              `Content.publish_document/4` requires. For those the pane header
              carries the Publish control, and this section + Labels below
              carry the description / weighted-tag affordances that satisfy
              the publish wall. The wall itself is UNTOUCHED (charter
              D229/D230). --%>
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
          <%!-- spd-bl-publish-affordance-triple — the description the publish
                wall demands FIRST (LabelSpine fires on it before anything
                else, and no amount of body authoring moves it). Draft-only:
                the meta-write path can only land on a drafts row. --%>
          <form
            :if={@draft?}
            phx-change="sidebar-description-change"
            class="bp-doc-field bp-doc-field--stacked"
          >
            <label for="bp-doc-desc-input" class="bp-doc-field__label">Description</label>
            <textarea
              id="bp-doc-desc-input"
              name="value"
              class="form-input"
              rows="3"
              phx-debounce="400"
              spellcheck="true"
              aria-describedby="bp-doc-desc-hint"
              data-test-id="sidebar-description-input"
            >{@description}</textarea>
            <p id="bp-doc-desc-hint" class="bp-doc-empty">
              Publishing needs a description of at least 20 characters.
            </p>
          </form>
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
          <%!-- ae-w10 / D76 — the Labels section renders the WEIGHT the publish
                wall enforces, not bare names: entries arrive from
                `paper_label_entries/1` sorted strength DESC (legacy nil-strength
                last), each chip carries its rationale as a hover tooltip and a
                small numeric strength badge, and the stamped main tag reads as
                a flag icon + bold name. Reuses the existing `.bp-doc-*` classes
                only (root.html.heex is spd territory — zero new CSS). --%>
          <%= if @labels == [] do %>
            <p class="bp-doc-empty" data-test-id="sidebar-labels-empty">No labels yet.</p>
          <% else %>
            <ul class="bp-doc-tags" data-test-id="sidebar-labels">
              <li
                :for={label <- @labels}
                class="bp-doc-tag"
                title={label.rationale}
                data-strength={label.strength}
                data-main-tag={label.main? && ""}
                data-test-id={if label.main?, do: "sidebar-label-main", else: "sidebar-label"}
              >
                <.icon name={if label.main?, do: "flag", else: "tag"} size={11} />
                <%= if label.main? do %>
                  <strong>{label.name}</strong>
                <% else %>
                  {label.name}
                <% end %>
                <small :if={label.strength} data-test-id="sidebar-label-strength">
                  {label.strength}
                </small>
              </li>
            </ul>
          <% end %>
          <%!-- spd-bl-publish-affordance-triple — the add affordance the
                read-only chip list never had: one complete weighted-tag entry
                (tag, strength 1–100, rationale ≥ 20 chars — the publish
                wall's own per-entry floors, surfaced at add time in the same
                plain words). Draft-only, like the description input above. --%>
          <form
            :if={@draft?}
            phx-submit="sidebar-label-add"
            class="bp-doc-field bp-doc-field--stacked"
            data-test-id="sidebar-label-add"
          >
            <input
              type="text"
              name="tag"
              required
              class="form-input"
              placeholder="tag"
              aria-label="Tag name"
              data-test-id="sidebar-label-add-tag"
            />
            <input
              type="number"
              name="strength"
              required
              min="1"
              max="100"
              class="form-input"
              placeholder="strength 1–100"
              aria-label="Tag strength, 1 to 100"
              data-test-id="sidebar-label-add-strength"
            />
            <input
              type="text"
              name="rationale"
              required
              class="form-input"
              placeholder="why this tag fits (at least 20 characters)"
              aria-label="Tag rationale"
              data-test-id="sidebar-label-add-rationale"
            />
            <button type="submit" class="btn btn-ghost btn-sm" data-test-id="sidebar-label-add-submit">
              Add label
            </button>
          </form>
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

  # ── Phone drill breadcrumb (spd-s6) ─────────────────────────────────────────
  #
  # At the phone bucket the pane row has NO way back: `display_state/4` hides
  # every nav column when a document is open, and hides all but the leaf when
  # one is not — so the 44px strip spd-s4 made the primary back affordance is
  # not on the page at all. Open a document on a phone and you are trapped.
  # This crumb trail is that missing route.
  #
  # It renders as a SIBLING BEFORE `<.pane_layout>` (charter D27) — never
  # inside the flex row (it would become a squeezed column) and never in the
  # topbar, whose DOM identity is locked by `nav_parity_sweep` (D13).
  #
  # Zero new server events: a crumb click is the SAME `expand-pane` the strip
  # fires, with the same `phx-value-idx` truncation (`Enum.take(nav_path, idx)`
  # in `Handlers.Scope.expand_pane/2`), so crumb `idx` lands exactly where the
  # strip for pane `idx` lands. Nothing to classify in `caps.ex`.
  #
  # The full CSS contract (`.bp-desk-crumbs` / `-crumb` / `-sep` / `--current`)
  # already ships in root.html.heex under the "spd-s6 PRE-PROVISION" comment,
  # hidden in every bucket but phone. The server ALSO gates on the bucket so
  # the desktop first render stays byte-identical and the trail is testable
  # without a stylesheet. It renders only when there is somewhere to go back
  # to — an undrilled root desk gets no vestigial one-crumb trail.
  #
  # spd-b39 / D168 — the trail now reaches NARROW as well as phone, and it
  # learns the inspector. Two facts forced both halves:
  #
  #   · at `narrow` the <nav> was never emitted at all (live-confirmed:
  #     `document.querySelector('.bp-desk-crumbs')` is null at 800px), yet
  #     `narrow` is one of the two buckets where the wave-10 geometry paints a
  #     full-screen summoned inspector. A destination with no trail out of it
  #     is a trap. The gate is the SAME enumeration the destination predicate
  #     uses — `in ["narrow","phone"]`, never `!= "wide"`.
  #   · when the inspector IS that destination, the document is no longer where
  #     you are: the inspector is. So the trail grows a trailing inspector
  #     segment and the document crumb — dead static text since it shipped —
  #     becomes a real control that takes you back to the prose.
  #
  # Still zero new server events: the document crumb fires the SAME
  # `sidebar-toggle-panel` the inspector's own back button fires, already in
  # `@safe_events` (caps.ex:82). Nothing new to classify.
  #
  # spd-w12 / D180 — THE TRAIL REACHES STANDARD. With the wave-10 ladder
  # engaged at `standard` the rail YIELDS to a 44px strip, so the measured
  # affordance inventory on that screen is exactly two: the collapse toggle and
  # the strip. That made `standard` the one bucket that hides the whole nav rail
  # WITHOUT offering the trail that replaces it — the trail was gated
  # `in ["narrow","phone"]` and stopped one bucket short of the tier that needs
  # it. The gate widens to include the ladder tier, and ONLY when the ladder is
  # actually engaged (`standard` + a user-opened panel): an untouched `standard`
  # desk still has its rail and must render byte-identically.
  #
  # The gate stays an ENUMERATION. `!= "wide"` is FORBIDDEN (D169) and there is
  # a live textual guard in the ladder test that refutes it in code — it strips
  # comment lines first, so this prose explaining the ban does not false-red it.
  # A negation would also be WRONG here and not merely banned: it would paint
  # the trail on an untouched `standard` desk that still has its rail.
  attr(:panes, :list, required: true)
  attr(:editor_doc, :any, default: nil)
  attr(:width_bucket, :string, default: "wide")
  attr(:sidebar_user_opened, :boolean, default: false)

  defp desk_crumbs(assigns) do
    has_editor = assigns.editor_doc != nil

    assigns =
      assigns
      |> assign(:has_editor, has_editor)
      |> assign(:leaf_idx, length(assigns.panes) - 1)
      # The inspector is the leaf only where it is actually the summoned
      # DESTINATION — the same shared predicate `inert` and the back arrow use.
      # This is deliberately NARROWER than "the user opened the panel": at
      # `standard` the wave-10 ladder docks the inspector IN FLOW beside prose
      # the reader can still see, so the document is still where you are and
      # the trail must not claim you have left it.
      |> assign(
        :inspector_leaf,
        has_editor and inspector_destination?(assigns.width_bucket, assigns.sidebar_user_opened)
      )
      |> assign(
        :trail_visible,
        crumb_trail_bucket?(assigns.width_bucket, has_editor, assigns.sidebar_user_opened)
      )

    ~H"""
    <nav
      :if={@trail_visible and (length(@panes) > 1 or @has_editor)}
      class="bp-desk-crumbs"
      aria-label="Desk breadcrumb"
      data-test-id="desk-crumbs"
    >
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <span :if={idx > 0} class="bp-desk-crumb-sep" aria-hidden="true">/</span>
        <%!-- The trail's last entry is where you already ARE: static text, not
              a control. With a document open that entry is the document, so
              every pane crumb — including the leaf list — stays clickable and
              the way out of the editor is one tap. --%>
        <span
          :if={idx == @leaf_idx and not @has_editor}
          class="bp-desk-crumb bp-desk-crumb--current"
          aria-current="page"
        ><%= pane.title %></span>
        <button
          :if={idx != @leaf_idx or @has_editor}
          type="button"
          class="bp-desk-crumb"
          phx-click="expand-pane"
          phx-value-idx={idx}
        ><%= pane.title %></button>
      <% end %>
      <span :if={@has_editor} class="bp-desk-crumb-sep" aria-hidden="true">/</span>
      <%!-- The document crumb. Static text while the document IS where you are;
            a real control the moment the inspector takes over the screen, and
            then it is the way back to the prose. Same event as the inspector's
            own back button — no new capability. --%>
      <span
        :if={@has_editor and not @inspector_leaf}
        class="bp-desk-crumb bp-desk-crumb--current"
        aria-current="page"
      ><%= @editor_doc.title || "Untitled" %></span>
      <button
        :if={@inspector_leaf}
        type="button"
        class="bp-desk-crumb"
        phx-click={dismiss_or_toggle(true, "#bp-doc-sidebar-toggle")}
        data-test-id="desk-crumb-document"
      ><%= @editor_doc.title || "Untitled" %></button>
      <span :if={@inspector_leaf} class="bp-desk-crumb-sep" aria-hidden="true">/</span>
      <span
        :if={@inspector_leaf}
        class="bp-desk-crumb bp-desk-crumb--current"
        aria-current="page"
        data-test-id="desk-crumb-inspector"
      >Document</span>
    </nav>
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

    <%!-- The pane row reads ONE table: PaneBuilder.display_state/4 (spd-s4,
          charter D6/D7/D35). `:full` is today's expanded column, `:strip` the
          44px collapsed back affordance, `:hidden` skips the pane server-side
          so no starving column is even in the flex row. @width_bucket comes
          from the WidthBucket hook on this container (root.html.heex) and
          stays "wide" until the client connects, so the static first render is
          byte-identical to pre-spd-s4 main. --%>
    <%!-- The phone drill trail — a SIBLING BEFORE the pane row (D27), and at
          the phone bucket the ONLY route back out of a drilled pane or an open
          document. See `desk_crumbs/1` above. --%>
    <.desk_crumbs
      panes={@panes}
      editor_doc={@editor_doc}
      width_bucket={@width_bucket}
      sidebar_user_opened={Map.get(assigns, :sidebar_user_opened, false) == true}
    />

    <.pane_layout id="studio-panes" phx_hook="WidthBucket">
      <% has_editor = @editor_doc != nil %>
      <% num_panes = length(@panes) %>
      <%!-- spd-w5/D79: the pane index a just-handled `expand-pane` named, set
            by Handlers.Scope. Only THAT pane gets `phx-mounted={JS.focus()}`,
            so activating the collapsed strip returns focus to the pane it
            named instead of dropping it on <body>, while an initial page load
            (where every pane mounts) never steals focus. Map.get, not @, so a
            socket that never navigated renders exactly as before. --%>
      <% focus_pane_idx = Map.get(assigns, :focus_pane_idx) %>
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <%!-- spd-b39/D151: the Tier-2 ladder's fifth input. `/5` is a pure
              additive arity — with the inspector CLOSED it delegates to the
              `/4` table VERBATIM in all 40 cells (pinned by the
              "inspector CLOSED is /4 verbatim" equivalence suite, which is
              what keeps D94(a)'s exhaustive table load-bearing after this
              swap rather than merely still-passing). `@sidebar_user_opened`
              is read as an assign, NOT `Map.get/3` with a default: it is
              seeded in mount.ex beside `width_bucket`, so an absent key is a
              wiring bug that must crash loudly instead of silently pinning
              the desk to false. --%>
        <% display =
          PaneBuilder.display_state(
            idx,
            num_panes,
            has_editor,
            @width_bucket,
            @sidebar_user_opened
          ) %>
        <% collapsed = display == :strip %>
        <% doc_count = Enum.count(pane.items, &(&1.type == :doc)) %>
        <.pane_column
          :if={display != :hidden}
          id={"pane-#{pane.title |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")}"}
          title={pane.title}
          count={doc_count}
          last={idx == num_panes - 1 and not has_editor}
          collapsed={collapsed}
          data_role={pane[:role]}
          data_priority={pane[:priority]}
          marker_class={if pane[:type_name], do: "bp-doc-list", else: nil}
          phx_click={if collapsed, do: "expand-pane", else: nil}
          phx_value_idx={if collapsed, do: "#{idx}", else: nil}
          controls={if collapsed, do: "studio-panes", else: nil}
          focus_on_mount={not collapsed and focus_pane_idx == idx}
        >
          <:header_actions>
            <%= if pane[:type_name] do %>
              <%!-- Post-type Share-access entry (airdrop-grants): mints a grant
                    scoped to THIS post type. Gated on holding shareable access,
                    not admin — the sheet's picker offers only held caps. --%>
              <%!-- Icon-only: title= is mouse-hover only in several AT/browser
                    pairs, so without aria-label the accessible name is the
                    empty string (the defect PR #7567 fixed for the "+"). --%>
              <button
                :if={@airdrop_can_share?}
                class="pane-add-btn"
                phx-click="airdrop-open"
                phx-value-type={pane.type_name}
                title={"Share access to #{pane.type_name}"}
                aria-label={"Share access to #{pane.type_name}"}
                data-test-id="airdrop-open-type"
              ><.icon name="share-2" size={14} /></button>
              <%!-- Access panel entry (airdrop-grants): review + revoke scoped
                    access. Open to any authenticated principal (grantees too). --%>
              <button
                :if={@airdrop_can_share?}
                class="pane-add-btn"
                phx-click="access-open"
                title="Review scoped access grants"
                aria-label="Review scoped access grants"
                data-test-id="access-open-type"
              ><.icon name="clock" size={14} /></button>
              <%!-- Icon-only: without an explicit label its accessible name
                    is the empty string, so AT announces a nameless button. --%>
              <button
                class="pane-add-btn"
                phx-click="new-document"
                phx-value-type={pane.type_name}
                title={"New #{pane.type_name}"}
                aria-label={"New #{pane.type_name}"}
              ><.icon name="plus" size={14} /></button>
            <% end %>
          </:header_actions>

          <%= if Map.get(pane, :desk_groups, []) != [] do %>
            <%!-- spd-w18-desk-chips-answer / charter D244 — the chips are LINKS,
                  and they say so. The old markup claimed role="tablist"/"tab"
                  with aria-selected={active}: no aria-controls, no tabpanel
                  anywhere in the tree, no roving tabindex — and HEEx rendered
                  the boolean as a BARE VALUELESS aria-selected when true and
                  omitted it when false, neither a valid ARIA boolean. Worse,
                  role="tab" on an <a href> overwrites the link role, so AT
                  stopped announcing a control that navigates (D79: an ARIA
                  state that never changes truthfully is worse than absence).
                  Resolution per D244: DROP the fake tab semantics — a plain
                  group of links, every chip Tab-reachable (N tab stops is the
                  correct link grammar; a one-tab-stop roving pattern belongs
                  to the tablist D244 rejected), selection spoken as
                  aria-current="true" exactly like the sibling pane rows (the
                  vocabulary is written down once, in StudioComponents.Panes'
                  moduledoc). --%>
            <div class="bp-desk-filter" role="group" aria-label="Desk filters">
              <%= for grp <- pane.desk_groups do %>
                <% gname = Map.get(grp, "name") || Map.get(grp, :name) %>
                <% gtitle = Map.get(grp, "title") || Map.get(grp, :title) || gname %>
                <% active = to_string(gname) == to_string(pane[:active_desk] || "") %>
                <a
                  class={"bp-desk-chip " <> if(active, do: "is-active", else: "")}
                  aria-current={active && "true"}
                  href={Paths.desk_chip_href(@scope_prefix, @nav_path, @dataset, gname)}
                  phx-click="select-desk"
                  phx-value-desk={gname}
                ><%= gtitle %></a>
              <% end %>
            </div>
          <% end %>

          <%!-- A STORED filter this pane could not apply (an unsupported op in a
                desk-group chip or a plugin/structure filter). The list is empty
                because nothing was queried, NOT because the type has no
                documents — saying "No documents yet" here would be a lie, so the
                empty state below is suppressed and this states the real reason. --%>
          <%= if pane[:filter_error] do %>
            <div class="bp-pane-notice bp-pane-notice-error" role="status" data-test-id="pane-filter-error">
              <.icon name="alert-triangle" size={14} />
              <span><%= pane[:filter_error] %></span>
            </div>
          <% end %>

          <div class="pane-body">
            <%= if pane.items == [] and pane[:type_name] != nil and pane[:filter_error] == nil do %>
              <.pane_empty message="No documents yet">
                <%!-- `drawable_name/2`, not `||` (icons-tab-icon-tenant-guard):
                      a pane's icon is schema/structure DATA, and `||` answers
                      only nil/false. An unknown string, or a truthy non-binary
                      (`:folder || "file"` is `:folder`), reached `icon/1` — a
                      document glyph in dev/prod, a RAISE in :test. --%>
                <:icon><.icon name={Icons.drawable_name(pane[:icon], "file")} size={32} /></:icon>
                <button
                  class="btn btn-primary btn-sm"
                  phx-click="new-document"
                  phx-value-type={pane.type_name}
                >
                  <.icon name="plus" size={14} /> New document
                </button>
              </.pane_empty>
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
                    <.icon name={Icons.drawable_name(item[:icon], "folder")} size={12} /> <%= item.title %>
                  </.pane_section_header>

                <% :plugin_link -> %>
                  <%!-- A real anchor ON PURPOSE (spd-bl-plugin-link-aria-current):
                        it navigates by plain href — no phx-click — and the bare
                        .pane-item class targeting keeps it in the rows' visual
                        rhythm (see the comment in root.html.heex). Do NOT
                        convert to a button. Selection: aria-current="page" when
                        the URL names this link as the destination — the "page"
                        token because an anchor's target is a page, where a
                        sibling in-desk row speaks aria-current="true". The full
                        selection vocabulary is documented ONCE, in
                        `StudioComponents.Panes`' moduledoc. --%>
                  <a
                    id={"plugin-link-#{item.id}"}
                    href={item.href}
                    class="pane-item nav-plugin-entry"
                    aria-current={item.id == pane[:selected] && "page"}
                    data-test-id="nav-plugin-entry"
                  >
                    <%!-- UNGUARDED UNTIL icons-tab-icon-tenant-guard, between two
                          guarded siblings (`:header` above, the `_` catch-all
                          below, both already on `drawable_name/2`). A
                          `:plugin_link` node's `:icon` is `item[:icon]` copied
                          verbatim off a PLUGIN's declared nav item
                          (`Barkpark.Structure.plugin_item_to_node/2`), so it is
                          an unbounded out-of-tree value that the `lib/` literal
                          tripwire structurally cannot see. The `if` covers nil;
                          it does NOT cover an unknown string or a truthy
                          non-binary, both of which reached `icon/1`. "circle" —
                          the neutral glyph `tab_icon/1` already uses — because a
                          link is not a document and "file" would claim it is. --%>
                    <%= if item.icon do %>
                      <span class="pane-item-icon"><.icon name={Icons.drawable_name(item.icon, "circle")} size={16} /></span>
                    <% end %>
                    <span class="pane-item-label"><%= item.title %></span>
                    <span class="pane-item-chevron"><.icon name="chevron-right" size={14} /></span>
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
                    meta={item[:meta] || item[:updated]}
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
                    <:icon><.icon name={Icons.drawable_name(item.icon)} size={16} /></:icon>
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
      <%!-- spd-b39 — `width_bucket` below closes a thread that was MISSING.
            `studio_paper_view/1` has declared the attr since spd-b29f and
            passes it straight on to the inspector, but this — its ONLY call
            site — never supplied it, so the component fell to its "wide"
            default on every viewport. The b29f aria-expanded fix downstream was
            therefore pinned to the wide branch, and the Tier-3 destination
            predicate could never fire at all. One attribute closes it, and the
            default keeps the pre-connect first paint byte-identical. --%>
      <%!-- spd-w19 — and `scope_prefix` below closes the SAME class of missing
            thread one attribute further down. Without it every href the paper
            pane emits (the never-blank notice's way back, "Open standalone")
            was built against an empty prefix — i.e. against a grammar this
            router does not serve. `rebuild_panes/1` already carries it. --%>
      <%!-- spd-b34 — `doc_actions` is NOT a third member of that missing-thread
            class, and must not be "closed" the way b39 and w19 were. Its
            absence from this call site is the RULING written above
            `studio_paper_view/1`: papers deliberately do not carry the classic
            doc-action bar, and a paper affordance is added to the paper header
            explicitly instead. Pinned both ways by
            studio_paper_doc_actions_ruling_test.exs. --%>
      <%= cond do %>
        <% @editor_view == :paper -> %>
        <.studio_paper_view
          focus_on_mount={@focus_doc_on_open}
          paper_doc={@paper_doc}
          paper_rev={@paper_rev}
          paper_html={@paper_html}
          paper_block_mode={@paper_block_mode}
          paper_edit_mode={@paper_edit_mode}
          task_previews={@paper_task_previews}
          paper_links={@paper_link_details}
          save_status={Map.get(assigns, :save_status, "")}
          paper_halt={Map.get(assigns, :paper_halt)}
          shares_admin?={@caps.admin}
          dataset={@dataset}
          scope_prefix={@scope_prefix}
          streams={@streams}
          backlinks_used_by={@backlinks_used_by}
          backlinks_linked={@backlinks_linked}
          backlinks_unlinked={@backlinks_unlinked}
          sidebar_open={Map.get(assigns, :sidebar_open, true)}
          sidebar_user_opened={Map.get(assigns, :sidebar_user_opened, false) == true}
          width_bucket={@width_bucket}
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
              surface; `{:sheets_op,…}` deltas reach it via send_update.

              THREE PROPS, THREE AXES (SheetGrid's moduledoc is the contract):

              `write_capable` is the CAPABILITY, not a display flag: a
              `phx-target`ed event carries a component cid and LiveView runs the
              COMPONENT socket's lifecycle for it, so the parent socket's
              `:handle_event` hooks — the `Caps` deny-gate among them — are never
              consulted. A fourth `attach_hook` on the parent therefore cannot
              gate this surface at all; the capability has to travel INTO the
              component, where `SheetGrid`'s write-head guards and the last wall
              in `SheetGrid.Ops.send_ops/2` already read it
              (`grep -n 'write_capable' lib/barkpark_web/live/studio/sheet_grid.ex`).
              Until this prop existed those guards were dead code on the Studio
              path — the component defaults `write_capable: false`.

              `live_session={true}` is a SEPARATE decision and stays a literal
              here rather than a derivation of the capability: a Studio member
              entitled to READ this desk sees the same live draft session their
              write-capable colleagues are editing. Wave 41 wired the single
              overloaded flag and a denied member silently dropped to the
              PUBLISHED row — two people, one sheet, different numbers. It is
              also NOT derived from `chrome`, which is what keeps this line the
              place to reconsider if a principal-LESS public-demo socket ever
              needs the draft withheld.

              `chrome={:studio}` is presentation only, and carries no authority:
              document header, editor identity, selection highlight, keyboard
              navigation. A denied member is still in Studio. --%>
        <.live_component
          module={BarkparkWeb.Studio.SheetGrid}
          id={"sheet-grid-#{Content.published_id(@sheet_doc.doc_id)}"}
          doc={@sheet_doc}
          dataset={@dataset}
          is_draft={@editor_is_draft}
          write_capable={sheet_write_capable?(assigns)}
          live_session={true}
          chrome={:studio}
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
          data-role="content"
          style="flex: 1; display: flex; flex-direction: column; min-height: 0; overflow: hidden;"
        >
          <%!-- Scope-level share affordance for the media library (P6b). The
                media panel is hand-rolled (no document_header), so the Share
                button rides a thin header row. Admin-only; opens the panel with
                the media surface pre-selected. --%>
          <div :if={@caps.admin or @airdrop_can_share?} class="media-explorer-bar">
            <button
              :if={@caps.admin}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="shares-open"
              phx-value-surface="media"
              title="Share this workspace's media library"
              data-test-id="media-share"
            >
              <.icon name="share-2" size={14} /> Share media
            </button>
            <%!-- Workspace Share-access entry (airdrop-grants): a workspace-scoped
                  grant (no post-type). Held-cap gated, not admin-only. --%>
            <button
              :if={@airdrop_can_share?}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="airdrop-open"
              title="Share scoped access to this workspace"
              data-test-id="airdrop-open-workspace"
            >
              <.icon name="send" size={14} /> Share access
            </button>
            <%!-- Access panel (airdrop-grants): review your own scoped access +
                  (for members) the workspace's active grants, with one-click
                  revoke. Open to any authenticated principal — a grantee sees
                  their own "Your access" section even without membership. --%>
            <button
              :if={@airdrop_can_share?}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="access-open"
              title="Review scoped access grants"
              data-test-id="access-open"
            >
              <.icon name="clock" size={14} /> Access
            </button>
          </div>
          <div style="flex: 1; display: flex; min-height: 0; overflow: hidden;">
            <bp-asset-explorer
              dataset={@dataset}
              data-token={Map.get(assigns, :api_token_raw, "")}
              data-kind-filter={@media_kind_filter || "all"}
              data-open-path={Paths.studio_path(assigns[:scope_prefix] || "", @nav_path, @dataset)}
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
          <div class="editor-panel" data-role="content" data-test-id="studio-doc-beta-editor">
            <.document_header
              dataset={@dataset}
              title={@editor_doc.title || "Untitled"}
              focus_on_mount={@focus_doc_on_open}
            >
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
                    slug={Content.published_id(@editor_doc.doc_id)}
                    doc_type={@editor_doc.type}
                    blocks={@editor_blocks}
                    table_editor_target_ids={Map.get(assigns, :editor_table_target_ids, MapSet.new())}
                    expected_fields={beta_expected_fields(@editor_schema, @editor_blocks)}
                    descriptors={beta_all_descriptors(@editor_schema, @editor_blocks)}
                    document_rev={@editor_doc.rev}
                    dataset={@dataset}
                    api_token_raw={Map.get(assigns, :api_token_raw, "")}
                    scope_prefix={Map.get(assigns, :scope_prefix, "")}
                    paper_links={Map.get(assigns, :paper_link_details, %{})}
                  />
                </main>
              </div>
            </div>
          </div>
        <% else %>
          <.studio_editor_shell
            focus_on_mount={@focus_doc_on_open}
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
            paper_halt={@paper_halt}
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
              <span
                :if={Map.get(assigns, :editor_blocks_identity_error)}
                role="alert"
                data-test-id="studio-beta-identity-error"
              >
                {beta_identity_error_message(@editor_blocks_identity_error)}
              </span>
            </:extra_actions>
            <%!-- spd-w19 — the third seam. The slot has been DECLARED and never
                  filled since D222; unfilled it fell to
                  `<.empty_editor message="Select a document to edit">`, which
                  answers a named-but-unresolvable document with absence. The
                  reason is derived ONCE in `Shared.rebuild_panes` (assign
                  `:editor_empty`, from `(panes, nav_path)`) because every
                  nil-editor producer in PaneBuilder returns a bare nil. Filling
                  the slot makes the default string unreachable on this path. --%>
            <:empty_state>
              <% empty = Map.get(assigns, :editor_empty) || %{reason: :nothing_selected, doc_id: nil, doc_type: nil} %>
              <%!-- Only `:not_found` gets a type-list link: for `:no_schema` that
                    list IS the pane that could not open the document, so
                    offering it would be a second shrug. --%>
              <BarkparkWeb.StudioComponents.Editor.unresolved_document_notice
                reason={empty.reason}
                doc_id={empty.doc_id}
                doc_type={empty.doc_type}
                cause={Map.get(empty, :cause)}
                elsewhere_name={Map.get(empty, :elsewhere_name)}
                elsewhere_href={Map.get(empty, :elsewhere_href)}
                grant_scope={Map.get(empty, :grant_scope)}
                list_href={
                  if empty.reason == :not_found and empty.doc_type,
                    do:
                      Paths.studio_path(
                        Map.get(assigns, :scope_prefix) || "",
                        [empty.doc_type],
                        @dataset
                      )
                }
                desk_href={
                  Paths.studio_path(Map.get(assigns, :scope_prefix) || "", [], @dataset)
                }
              />
            </:empty_state>
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
        <div
          class="delete-modal"
          data-test-id="unpublish-guard-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="unpublish-guard-modal-title"
          phx-window-keydown="close-unpublish-guard"
          phx-key="escape"
        >
          <div class="delete-modal-header">
            <span id="unpublish-guard-modal-title" style="font-weight: 600; font-size: 16px;">Unpublish document</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close-unpublish-guard" aria-label="Close">x</button>
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
        <div
          class="delete-modal"
          data-test-id="valueref-writeback-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="valueref-writeback-modal-title"
          phx-window-keydown="valueref-writeback-close"
          phx-key="escape"
        >
          <div class="delete-modal-header">
            <span id="valueref-writeback-modal-title" style="font-weight: 600; font-size: 16px;">Shared value</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="valueref-writeback-close" aria-label="Close">x</button>
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
                <p class="text-sm" style="color: var(--danger); margin: 8px 0;" data-test-id="valueref-error">
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
        admin?={@caps.admin}
        scope_prefill={@shares_scope_prefill}
        prefill_surfaces={@shares_prefill_surfaces}
        rows={@shares_rows}
        error={@shares_error}
      />

      <.item_share_popover
        show={@item_share_open}
        admin?={@caps.admin}
        title={(@item_share && @item_share.title) || "this item"}
        links={@item_share_links}
        error={@item_share_error}
      />

      <.airdrop_sheet
        show={@airdrop_open}
        type={@airdrop_type}
        caps={@airdrop_caps}
        link={@airdrop_link}
        error={@airdrop_error}
        suggestions={@airdrop_suggestions}
      />

      <.access_panel
        show={@access_open}
        own_grants={@access_grants}
        workspace_view={@access_workspace_view}
        workspace_grants={@access_workspace_grants}
        error={@access_error}
      />
    </.pane_layout>

    """
  end

  defp beta_identity_error_message({:malformed_block_authority, _path}) do
    "Block editing is unavailable because this document's stored content cannot be safely edited as blocks. No content was changed."
  end

  defp beta_identity_error_message(_reason) do
    "Block editing is unavailable because this document has duplicate block IDs. No content was changed."
  end

  # ── the SheetGrid capability prop ───────────────────────────────────────────
  #
  # May the socket's principal WRITE the mounted desk? This does NOT re-state
  # the rule — it CALLS the one owner, `Caps.write_capable?/2`, which the
  # socket-level deny-gate also calls. The component-targeted path never reaches
  # that hook (a `phx-target`ed event runs the COMPONENT socket's lifecycle), so
  # a fork here would be a security rule maintained in two places; the review of
  # pds-w41-caps-component-gate collapsed it into one.
  #
  # `@caps` is the freshly-derived map StudioLive re-assigns on every grant
  # change and expiry tick (`grep -n 'defp refresh_caps' lib/barkpark_web/live/studio/studio_live.ex`),
  # so an expired grant drops the write prop on the next render.
  #
  # pds-w41-livescope-component-bypass — THE SECOND QUESTION: *which* sheet.
  #
  # `Caps.write_capable?/2` answers "may this PRINCIPAL write this DESK". It
  # takes no target and cannot get one, and it must not: it is also the
  # socket-level deny-gate's predicate, and widening it would move a second
  # surface that has no doc to reason about. But for a GRANT-graded socket the
  # per-TARGET containment IS the authorization, and the desk answer is strictly
  # too broad — `Caps.derive/1` computes `write` through `Access.admits_desk?/3`,
  # which OVERWRITES the requested scope's `type`/`doc_id` with the GRANT'S OWN
  # before validating (its documented job — a desk cannot name a doc). So a
  # DOC-scoped write grant self-satisfies at desk granularity and this prop used
  # to arrive `true` on EVERY sheet of the desk.
  #
  # Reproduced by run on origin/main: a signed-in non-member holding a write
  # grant naming ONE sheet, mounting a DIFFERENT sheet on the same desk (read
  # reach from a second, read-only grant), wrote it through `phx-target` at
  # `#sheet-grid-…` while the SAME socket's `save` was HALTED by
  # `LiveScope`'s `:live_scope_write_scope`. A granularity gap, not a missing
  # gate: socket route doc-granular, component route desk-granular.
  #
  # NOT a fourth `attach_hook`: a `phx-target`ed event carries a component cid
  # and LiveView runs the COMPONENT socket's lifecycle for it, so the parent's
  # hook list is never consulted on that branch — that IS the bug. The narrowing
  # has to travel in as the prop, exactly as `Shared.Paper.grant_target_denied?/3`
  # travelled it into the paper door for the same finding on the paper surface.
  #
  # ARMED ONLY FOR GRANT-DERIVED WRITE. A membership-derived socket carries no
  # `caller_context` and no `write_gate?`, so `grant_graded?/1` is false and this
  # arm returns `false` without looking at anything — the member path and the
  # anonymous public-demo path are byte-identical (no new denial, no new query).
  defp sheet_write_capable?(assigns) do
    Caps.write_capable?(assigns, Map.get(assigns, :caps) || %{}) and
      not sheet_grant_target_denied?(assigns)
  end

  defp sheet_grant_target_denied?(assigns) do
    grant_graded?(assigns) and not grant_admits_sheet?(assigns)
  end

  # The two assigns that mean "this socket's write descends from a GRANT":
  # `LiveScope.assign_grant_scope/2` sets `caller_context`, and
  # `attach_write_gate/2` sets `write_gate?`. Same pair `Caps.restricted?/1` and
  # `Shared.Paper.grant_graded?/1` read.
  defp grant_graded?(assigns) do
    not is_nil(Map.get(assigns, :caller_context)) or Map.get(assigns, :write_gate?) == true
  end

  # `Access.validate/3` — the SAME containment ladder `attach_write_gate/2`'s
  # `write_target_permitted?/4` walks, over the SAME grant set it captured, so
  # the two routes now answer this target identically. Deliberately NOT
  # `Access.admits_desk?/3`: that helper is the mechanism this closes.
  #
  # The grants come from `caller_context` rather than a fresh reload because
  # this runs in RENDER, not in an event handler — a `Repo` round trip per
  # render is not a thing to add to a hot path, and it would buy nothing:
  # expiry truth already arrives through `@caps` (a grant that expired makes
  # `caps.write` false and the `and` above short-circuits), while a grant ADDED
  # mid-session leaves this set stale-NARROW, which over-restricts and never
  # under-restricts — the same disposition `attach_write_gate/2` documents for
  # its own captured ctx.
  defp grant_admits_sheet?(assigns) do
    case sheet_write_target(assigns) do
      %{} = target ->
        Enum.any?(
          grant_ctx_grants(assigns),
          &(Barkpark.Access.validate(&1, :write, target) == :ok)
        )

      nil ->
        false
    end
  end

  defp grant_ctx_grants(assigns) do
    case Map.get(assigns, :caller_context) do
      %{grants: grants} when is_list(grants) -> grants
      _ -> []
    end
  end

  # The desk levels come from the MOUNT and the leaf levels from the SHEET the
  # component is about to write — the same broad→narrow ladder
  # `LiveScope.write_target/3` feeds `Access.validate/3`, including its
  # `Content.published_id/1` normalisation so a draft id is matched against the
  # grant by its published identity.
  #
  # FAIL-CLOSED on an unresolvable target (no workspace / project / dataset, or
  # a sheet doc with no type or doc_id): `nil` here denies for a grant-graded
  # socket, matching `write_target/3`'s `:error -> halt`. Inert for every other
  # socket, which never reaches this.
  defp sheet_write_target(assigns) do
    ws = Map.get(assigns, :current_workspace)
    proj = Map.get(assigns, :current_project)
    dataset = Map.get(assigns, :dataset)
    doc = Map.get(assigns, :sheet_doc)
    type = sheet_doc_field(doc, :type)
    doc_id = sheet_doc_field(doc, :doc_id)

    if is_map(ws) and is_binary(Map.get(ws, :id)) and is_map(proj) and
         is_binary(Map.get(proj, :id)) and is_binary(dataset) and is_binary(type) and
         is_binary(doc_id) do
      %{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: dataset,
        type: type,
        doc_id: Content.published_id(doc_id)
      }
    end
  end

  # Read TOTALLY: the sheet doc is a `%Content.Document{}` on the live path but a
  # bare map in unit fixtures, so `doc.type` would raise a KeyError on a shape
  # that has always been legal here. A missing key yields nil, which
  # `sheet_write_target/1` treats as unresolvable (fail-closed).
  defp sheet_doc_field(doc, key) when is_map(doc), do: Map.get(doc, key)
  defp sheet_doc_field(_doc, _key), do: nil

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

  # ── The tier predicate — ONE definition, at module bottom ───────────────────
  #
  # spd-b39/spd-w12, charter D169/D181. Three call sites read this: the `inert`
  # gate in `studio_paper_view/1`, the destination clothes in
  # `paper_metadata_sidebar/1`, and the crumb trail's inspector leaf in
  # `desk_crumbs/1`. It used to be written out twice by hand; the third reader
  # is what made a shared definition non-optional.
  #
  # WHY IT LIVES DOWN HERE and not beside its first caller: Phoenix binds any
  # pending `attr(...)` declarations to the next function defined in the module,
  # so declared underneath an attr block this raises at COMPILE time —
  # "cannot declare attributes for function inspector_destination?/2. Components
  # must be functions with arity 1". Module bottom, after every component, is
  # the only placement that compiles.
  #
  # It is an ENUMERATION of the buckets where the wave-10 geometry paints
  # `position:absolute; inset:0` over an opaque surface. `!= "wide"` is
  # FORBIDDEN: the wave-10 ladder made `standard` + user-opened a REAL DOCKED
  # state (the rail yields to one 44px strip and the panel sits in flow beside
  # the prose), so a negation would hand a docked panel destination semantics —
  # it would `inert` prose the reader can still see and edit, announce a
  # landmark for a screen the reader never left, and bind Escape to an exit
  # from somewhere they are not. Enumerate the covered buckets; never negate
  # the uncovered one.
  defp inspector_destination?(width_bucket, user_opened) do
    width_bucket in ["narrow", "phone"] and user_opened == true
  end

  # spd-w19 / D257 — the never-blank notice's way BACK, spelled as a ROUTE.
  #
  # Both grammars this router actually serves, and neither of them is the one the
  # notice shipped with. `Paths.studio_path("", ["paper"], ds)` yields
  # `/d/:dataset/studio/paper` — a path that exists ONLY under the
  # `/w/:ws/p/:proj` scope, so with an empty prefix `Router.route_info/4` returns
  # `:error` and a real request 404s. The scoped form is that same suffix WITH
  # the prefix; the flat form the router serves is `/studio/:dataset/*path`
  # (`Paths.flat_root/1`), which 302s into the scoped canonical.
  #
  # Composed from the two existing `Paths` owners rather than interpolated here —
  # `Paths` stays the single owner of both grammars.
  defp doc_list_href(scope_prefix, doc_type, dataset) do
    if is_binary(scope_prefix) and scope_prefix != "" do
      Paths.studio_path(scope_prefix, [doc_type], dataset)
    else
      Paths.flat_root(dataset) <> "/" <> doc_type
    end
  end

  # Where the desk crumb trail renders (D168 + D180). Two clauses of the same
  # enumeration, never a negation: the buckets that have no rail at all, plus
  # the ladder tier at the moment the ladder has taken the rail away.
  defp crumb_trail_bucket?(width_bucket, has_editor, user_opened) do
    width_bucket in ["narrow", "phone"] or
      (width_bucket == "standard" and has_editor and user_opened == true)
  end

  # The dismissal command. One event either way — `sidebar-toggle-panel`, which
  # is ALREADY classified in `caps.ex` `@safe_events`, so the whole keyboard and
  # crumb grammar costs ZERO new capability entries and adds no `handle_event`
  # head. At Tier 3 the push is followed by an explicit FOCUS RETURN to the
  # trigger, so leaving a full-screen destination never drops focus on <body>
  # (which is exactly what it did before this slice). Below Tier 3 the plain
  # event string is emitted, byte-for-byte what shipped before.
  defp dismiss_or_toggle(true, return_to),
    do: JS.push("sidebar-toggle-panel") |> JS.focus(to: return_to)

  defp dismiss_or_toggle(_not_destination, _return_to), do: "sidebar-toggle-panel"

  # spd-w18 — "this body renders NOTHING a reader can see", the gate on the
  # never-blank arm. It is deliberately NOT `html == ""`:
  #
  #   * `== ""` is too narrow. A stored `"<p></p>"` / `"<div>\n</div>"` /
  #     `"&nbsp;"` body_html is a non-empty STRING that paints an empty screen,
  #     which is the very blank being fixed — the string is not the surface.
  #   * a bare tag-strip is too WIDE, and that is the byte-identity risk: an
  #     image-only, table-only or embed-only legacy body carries no text yet is
  #     perfectly visible, and swallowing it behind a "cannot render" notice
  #     would be a NEW blank of our own making. So any visible-by-itself element
  #     answers "not blank" before the text test runs.
  #
  # Net effect on a legitimate legacy HTML-only paper: `false`, so it falls
  # through to the unchanged `raw(@paper_html)` arm byte for byte.
  @self_visible_tags ~w(img svg picture video audio iframe embed object canvas
                        table hr input button select textarea math)

  defp blank_body?(html) when is_binary(html) do
    cond do
      Regex.match?(~r/<\s*(#{Enum.join(@self_visible_tags, "|")})\b/i, html) ->
        false

      true ->
        html
        |> String.replace(~r/<[^>]*>/, "")
        |> String.replace(~r/&nbsp;|&#160;|&#xa0;/i, " ")
        |> String.trim()
        |> Kernel.==("")
    end
  end

  defp blank_body?(_not_a_string), do: true
end
