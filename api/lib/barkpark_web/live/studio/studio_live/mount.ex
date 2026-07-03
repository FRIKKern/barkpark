defmodule BarkparkWeb.Studio.StudioLive.Mount do
  @moduledoc """
  `mount/3` initial-assigns block extracted from
  `BarkparkWeb.Studio.StudioLive`. `init/1` reads identity from the client's
  localStorage connect params, seeds every editor/panel assign, opens the
  paper_blocks stream, and allows the image upload — returning the assigned
  socket. `mount/3` itself stays in StudioLive (the LiveView callback) and
  calls straight in.

  `shares_admin?/1` (the shares-panel authorization predicate) lives here too
  since the initial assign needs it; StudioLive's shares-* handlers call it
  via this module so the gate stays single-sourced.
  """

  import Phoenix.Component, only: [assign: 2, assign_new: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1, stream: 3, allow_upload: 3]

  alias BarkparkWeb.Studio.PresenceState

  @doc """
  Seed the initial socket assigns for a Studio mount. Returns the socket; the
  caller wraps it in `{:ok, ...}`.
  """
  def init(socket) do
    # Read identity from client localStorage via connect params
    connect_params = get_connect_params(socket) || %{}
    user_id = connect_params["user_id"] || PresenceState.generate_user_id()
    stored_name = connect_params["user_name"]
    stored_color = connect_params["user_color"]

    user_name =
      if stored_name && stored_name != "",
        do: stored_name,
        else: "User #{String.slice(user_id, 0..3)}"

    user_color =
      if stored_color && stored_color != "",
        do: stored_color,
        else: PresenceState.pick_color(user_id)

    # Presence subscription happens in handle_params via
    # ensure_presence_subscription/1 — the topic is workspace-keyed
    # (tsk-url-p0) and the workspace isn't resolved until
    # ensure_tenancy_scope runs there.
    socket
    # LiveScope (scoped mount) assigns the real prefix BEFORE mount runs;
    # assign_new keeps it. The flat mount lands here unset → "" → every
    # studio_path stays byte-identical to the pre-scoped era.
    |> assign_new(:scope_prefix, fn -> "" end)
    |> assign(
      nav_section: :structure,
      page_title: "Studio",
      presence_topic: nil,
      subscribed_doc: nil,
      image_picker_field: nil,
      media_files: [],
      ref_picker_field: nil,
      ref_candidates: [],
      ref_search: "",
      show_history: false,
      revisions: [],
      show_delete: false,
      delete_refs: [],
      show_discard: false,
      # ── Blast-radius graph pane (Goal ges/graph-edge-seam, Phase 5) ──────
      # A `graph` doc opens the Cytoscape blast-radius pane
      # (`editor_view: :graph`), rendered by the GraphView LiveComponent. The
      # unpublish guard (gap #5) probes `Content.Graph.reverse_referencers/2`
      # — the arrayOf-aware inbound-edge query — and pops a confirm modal when
      # a doc has live referencers that would dangle on unpublish.
      graph_doc: nil,
      graph_data: %{nodes: [], edges: []},
      show_unpublish_guard: false,
      unpublish_refs: [],
      user_id: user_id,
      user_name: user_name,
      user_color: user_color,
      presences: [],
      show_profile: false,
      # ── Network shares panel (scoped-sharing P6) ─────────────────────
      # Admin-only. `shares_admin?` is resolved ONCE from the mounted
      # api_token (StudioLive runs in :studio_public, so the token may be
      # nil or non-admin); it both hides the top-bar Share button and is
      # re-checked in every shares-* handler (the hidden button is UX, the
      # handler gate is the security boundary). The panel calls
      # Barkpark.Sharing.* in-process — the SAME registry the admin-only
      # /v1/shares API and `bp share` CLI write.
      shares_admin?: shares_admin?(socket),
      show_shares: false,
      shares_rows: [],
      shares_scope_prefill: "",
      shares_prefill_surfaces: [],
      shares_error: nil,
      # ── Item (per-document) share popover (P7) ────────────────────────
      # Google-Docs-style "share THIS one item" — distinct from the section
      # shares panel above. Mints a direct /s/<token> link to the open
      # paper/doc via Barkpark.Sharing.Links (admin-only, re-checked here).
      item_share_open: false,
      item_share: nil,
      item_share_links: [],
      item_share_error: nil,
      validation_errors: %{},
      # ── Cross-field validations (Task barkpark-cgn) ──────────────────
      # Populated after every autosave by `Barkpark.Content.CrossValidator
      # .violations/2`. Each entry is a string-keyed map carrying name,
      # title, level (error|warning), and fields. The editor banner reads
      # this assign directly; non-rule schemas keep `[]` and never render
      # the banner row.
      cross_violations: [],
      # ── valueref edit-through inspector (lvw-t10) ─────────────────────
      # Set by the paper-valueref-inspect handler; nil = closed. The panel's
      # write control renders ONLY when the server authorized the TARGET
      # (ValueWriteback.inspect_target) — and the confirm handler re-checks.
      valueref_panel: nil,
      confirm_modal: nil,
      nav_group: nil,
      # ── Content preview side-pane (Goal barkpark-G1, task s3) ─────────
      # Doc-type-agnostic. Pane is rendered iff a plugin's
      # `content_renderer/3` callback contributes iodata via
      # `Plugins.Registry.collect_content_renderer/3` AND the user has
      # not toggled the pane off. With plugins=[] this assign stays
      # nil → pane is absent from the layout (fresh-install
      # invariant, Goal `barkpark-G1`).
      content_preview_rendered: nil,
      content_preview_visible: true,
      # ── Document actions (Task barkpark-3yq) ─────────────────────────
      # E2 split-view: read-only secondary editor pane.
      secondary_doc: nil,
      secondary_schema: nil,
      secondary_type: nil,
      show_secondary_picker: false,
      secondary_search: "",
      secondary_candidates: [],
      # E3 bulk publish: per-pane multi-select MapSet of published ids.
      selected_doc_ids: MapSet.new(),
      bulk_status: nil,
      # ── Draft-vs-Published diff view (Task barkpark-uix) ─────────────
      # `diff_visible` toggles the editor pane between the form and the
      # field-level diff table. `published_doc` is the fetched published
      # twin of the current draft (nil when no draft is open, or when
      # the draft has no published counterpart). The toggle button in
      # the editor header only surfaces when both sides exist.
      diff_visible: false,
      published_doc: nil,
      # Subscribed document-list PubSub topic (barkpark-fe2k). Tracked so the
      # unsubscribe on a dataset switch matches the exact topic we subscribed
      # — workspace-scoped (`documents:ws:#{ws}:#{dataset}`) when a workspace
      # is resolved, bare (`documents:#{dataset}`) otherwise.
      list_topic: nil,
      # ── In-Studio live paper view (convergence/papers-in-studio) ─────
      # A paper opens LIVE inside the editor pane (read-only block stream),
      # NOT the field form. `editor_view` is `:paper` while a paper is open,
      # `:form` (the default) otherwise. The paper's per-doc topic is
      # subscribed at open; `{:paper_block,…}` / `{:paper_updated,…}` frames
      # update the pane in place with NO remount — mirroring BulldocsLive's
      # streaming. `paper_rev` tracks the last applied monotonic streaming
      # rev for gap detection; `paper_block_mode` flips false for HTML-only
      # papers (the raw-HTML fallback). `paper_topic` is the subscribed
      # topic so it can be unsubscribed on navigation.
      editor_view: :form,
      media_kind_filter: "all",
      paper_doc: nil,
      paper_rev: 0,
      paper_html: "",
      paper_block_mode: false,
      paper_topic: nil,
      # ── In-Studio sheet grid editor (Sheets M2) ───────────────────────
      # A type:"sheet" document opens as the collaborative grid editor
      # (`editor_view: :sheet`), not the field form. The LiveView
      # subscribes to the sheet session's delta topic
      # (`Barkpark.Plugins.Sheets.Session.topic/3` — the doc topic suffixed with
      # ":sheets:op"); `{:sheets_op, …}` payloads forward into the
      # SheetGrid LiveComponent via send_update — the component owns all
      # grid state and applies deltas in place (no rebuild, no remount).
      # `sheet_topic` is tracked for the diff-and-resubscribe on
      # navigation, mirroring `list_topic`.
      sheet_doc: nil,
      sheet_topic: nil,
      # Sheets M4 grid presence: the per-sheet presence topic
      # (`Session.presence_topic/3`) this LV is tracked on while a sheet
      # is open, and the materialised collaborator list the SheetGrid
      # component renders (cursors, selections, editing tags). Lifecycle
      # lives in resub_sheet_presence/2.
      sheet_presence_topic: nil,
      sheet_presences: [],
      # ── In-Studio paper block editor (convergence/studio-paper-editor) ───
      # `paper_edit_mode` flips the paper pane between the read-only live
      # stream (View — the default, unchanged) and the block edit form (Edit).
      # In Edit mode each per-block control fires a `paper-*` event that maps
      # to ONE DocPatchOp and calls `Content.apply_paper_block_op/3`; the
      # resulting `{:paper_block,…}` delta flows through the SAME stream
      # handler that a remote viewer sees, so the View stays in sync and the
      # pane never remounts. `paper_edit_block` builds the edit form straight
      # from `paper_doc.content["blocks"]` (the source of truth, refetched
      # after every op) — it never bypasses the op pipeline.
      paper_edit_mode: false,
      # Per-document Classic <-> Beta toggle (Exp-P3.2, barkpark-g2ql).
      # `editor_mode` flips an Expectation-bearing document's editor between
      # the Classic schema form (`:classic`, default - reads projected
      # content[fieldName]) and the Beta premium block editor (`:beta` -
      # reuses `paper_block_editor` over the doc's content["blocks"]). Both
      # views read the ONE block list; flipping re-projects, never converts,
      # so it is lossless both ways. `editor_blocks` holds the block list
      # backing the Beta view (the stored content["blocks"] or, when absent,
      # an in-memory synthesis via Content.resolve_blocks_for_edit/3 that is
      # persisted on the first Beta edit). `editor_blocks_synth?` records
      # whether that list was synthesized (nothing on disk yet).
      editor_mode: :classic,
      editor_blocks: [],
      editor_blocks_synth?: false,
      # ── Concurrent-edit guard (studio-concurrent-edit) ────────────────
      # `editor_dirty` = the form buffer holds user edits not yet reconciled
      # with the remote snapshot. Set by the form edit handlers (autosave /
      # array_op / slug_generate), reset on navigation, explicit save, and
      # reload. While set, a remote save of the open doc (`doc_updated` /
      # `document_changed`) does NOT overwrite the buffer; it flips
      # `doc_conflict`, which renders the "Updated by another user — Reload"
      # banner (studio_editor_shell). "reload-remote-doc" reloads from the DB.
      editor_dirty: false,
      doc_conflict: false,
      # ── Switcher create affordances (Task barkpark-ylrw) ──────────────
      # Which inline "+ New" form the WorkspaceSwitcher shows: "workspace",
      # "project", or nil (both closed). The "＋" buttons toggle this via
      # `toggle-create`; a successful create or a re-click closes it. The
      # affordances themselves are hidden when `api_token` is nil (no
      # principal to own a new workspace) — see the layout's `can_create`.
      create_open: nil
    )
    |> stream(:paper_blocks, [])
    |> allow_upload(:image,
      accept: ~w(.jpg .jpeg .png .gif .webp .svg),
      max_entries: 1,
      max_file_size: 10_000_000
    )
  end

  @doc """
  The single authorization predicate for the shares panel. StudioLive runs in
  :studio_public, so the mounted api_token may be nil or non-admin — a nil /
  non-struct token denies (never raises). Re-evaluated in every shares-*
  handler, not just at mount.
  """
  def shares_admin?(socket) do
    case socket.assigns[:api_token] do
      %_{} = token -> Barkpark.Auth.has_permission?(token, "admin")
      _ -> false
    end
  end
end
