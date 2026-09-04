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

  alias BarkparkWeb.Studio.Caps
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
      # ── Responsive width bucket (studio-space-priority-desk spd-s2) ─────
      # Which viewport width band the desk is rendering for: "wide" (the
      # zero-change desktop default), "standard", "narrow", or "phone". The
      # `width-bucket` handle_event updates it once a client hook reports the
      # measured band (attached in spd-s4). Seeded "wide" because first paint
      # is CSS-owned and connect_params is nil on the static render — the
      # assign only ever narrows the desk once the live socket learns better.
      width_bucket: "wide",
      # ── Focus-after-select mark (spd-bl-focus-after-select) ─────────────
      # One-shot: set by Scope.select/2 ONLY at narrow/phone (where the
      # clicked row is destroyed by the patch), rendered as tabindex="-1" +
      # phx-mounted={JS.focus()} on the opened document's own header, and
      # spent by expand_pane/2 and a width-bucket flip — the same lifecycle
      # discipline focus_pane_idx keeps. Seeded false so an initial load
      # never steals focus.
      focus_doc_on_open: false,
      # ── Inspector summon flag (spd-b39, the Tier-2 ladder) ──────────────
      # Whether the user ASKED for the Document inspector, as opposed to it
      # being open because the bucket defaults it open. `sidebar_assigns/1`
      # in shared/paper.ex owns the per-document reseed, but it is reached
      # ONLY from `setup_paper_view` — so before this seed the key was
      # measurably ABSENT on a fresh mount for sheet, graph, field form and
      # desk root (present for paper alone, 7/7 views probed). The pane
      # comprehension in components.ex reads it as `@sidebar_user_opened`,
      # and an absent assign there does not degrade, it DIES:
      # `** (KeyError) key :sidebar_user_opened not found` raised through
      # `Phoenix.LiveView.Diff.process_keyed/5` in 5 of 7 views. Seeding it
      # here — rather than `Map.get(assigns, :sidebar_user_opened, false)`
      # at the read site — is deliberate: the defaulting read compiles and
      # goes green while silently pinning every non-paper desk to false,
      # which is the same hole wearing a passing test.
      sidebar_user_opened: false,
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
      # A `graph` doc opens the Canvas2D blast-radius pane (bp-graph.js)
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
      # ── Capability map (airdrop-grants ag-studio-capability-hide) ─────
      # `caps` = %{read, write, admin} for the mounted desk: membership ∪
      # active grants (grants never confer admin). It DRIVES the `:if`
      # affordance hiding (`@caps.admin` etc.) AND — load-bearing — the
      # server-side deny-gate attached in StudioLive.mount
      # (`BarkparkWeb.Studio.Caps.attach/1`), which RE-DERIVES caps per
      # event so mid-session grant expiry denies a forged event. Refreshed
      # by the grant toast + the expiry tick.
      caps: Caps.derive(socket),
      # ── Network shares panel (scoped-sharing P6) ─────────────────────
      # Admin-only. `shares_admin?` is DERIVED from `caps.admin` (an admin
      # api_token OR an account with the workspace :admin role); it hides
      # the top-bar Share button and is re-checked in every shares-*
      # handler via `Caps.admin?/1` (the hidden button is UX, the handler
      # gate + the deny-gate are the security boundary). The panel calls
      # Barkpark.Sharing.* in-process — the SAME registry the admin-only
      # /v1/shares API and `bp share` CLI write.
      shares_admin?: Caps.admin?(socket),
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
      # ── Share-access sheet (airdrop-grants capstone) ─────────────────
      # Mints a scoped, time-boxed, account-bound grant via Barkpark.Access
      # .mint/2 IN-PROCESS. Gated on HOLDING shareable access (not admin):
      # `airdrop_can_share?` reveals the entry buttons for any authenticated
      # principal, and the sheet's picker offers only the caps the grantor
      # actually holds. `airdrop_link` carries the raw claim URL ONCE after a
      # mint, then is dropped on close (the token hash is never surfaced).
      airdrop_can_share?: (socket.assigns[:current_user] || socket.assigns[:api_token]) != nil,
      airdrop_open: false,
      airdrop_type: nil,
      airdrop_caps: [],
      airdrop_link: nil,
      airdrop_error: nil,
      airdrop_suggestions: [],
      # ── Access panel (airdrop-grants slice 3 UI) ─────────────────────
      # The read/revoke sibling of the airdrop mint sheet. `access_open`
      # toggles the panel; `access_workspace_grants` is loaded on open ONLY
      # for a workspace member (membership-gated like AccessController.index),
      # and `access_workspace_view` gates that whole section. The caller's OWN
      # inbound grants render from the separate `:access_grants` assign.
      access_open: false,
      access_workspace_view: false,
      access_workspace_grants: [],
      access_error: nil,
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
      # t9 — live task-block previews, keyed by block id. Display-only rows
      # for the canvas boundary widgets (never the save baseline — doctrine
      # D5); (re)filled by Shared.push_task_previews on open / edit / op.
      paper_task_previews: %{},
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
      # `paper_edit_mode` is the flag-OFF OPT-OUT path's mode bit ONLY
      # (pdd-t12b, rule 5): with the canvas the mainline default there are no
      # modes — opening a paper IS the editor and this assign is ignored.
      # On `BARKPARK_PAPER_CANVAS=0` it flips the paper pane between the
      # read-only live stream (View) and the block edit form (Edit).
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
      # ── Server-owned save-halt mirror (p-hollow-studio-mirror) ────────
      # nil = no active halt. Set to the verbatim `{:error, {:halted, reason}}`
      # string by the paper handlers (shared/paper.ex paper_pane_op/paper_ops)
      # when a plugin lifecycle gate vetoes a write; the editor renders it in
      # the paper-halt banner and clears it on the next accepted edit. The
      # editor MIRRORS this server truth, it never owns the gate (D5/D6).
      paper_halt: nil,
      # ── Switcher create affordances (Task barkpark-ylrw) ──────────────
      # Which inline "+ New" form the WorkspaceSwitcher shows: "workspace",
      # "project", or nil (both closed). The "＋" buttons toggle this via
      # `toggle-create`; a successful create or a re-click closes it. The
      # affordances themselves are hidden when there is no PRINCIPAL at all —
      # neither a token nor an account-session %User{} (nobody to own a new
      # workspace) — see the layout's `can_create`.
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
  The single authorization predicate for the shares panel — now `caps.admin`
  re-derived fresh (`Caps.admin?/1`): an admin api_token OR an account with the
  workspace `:admin` role. Nil-safe (no principal denies, never raises).
  Re-evaluated in every shares-* handler, not just at mount.
  """
  def shares_admin?(socket), do: Caps.admin?(socket)
end
