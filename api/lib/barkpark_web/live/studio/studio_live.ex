defmodule BarkparkWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor

  ## Structure (post god-module decomposition)

  This module is the LiveView SHELL: `mount/3`, `handle_params/3`, `render/1`,
  and the THIN `handle_event/3` + `handle_info/2` routing heads (Phoenix
  dispatch). Each clause delegates its body to a per-domain handler under
  `StudioLive.Handlers.*`; the state-coupled helpers those handlers share live
  in `StudioLive.Shared`. The pure path/parse helpers stay here as public,
  test-facing delegations to `StudioLive.Path`.

  Handler domains (`StudioLive.Handlers.*`):

  - `Lifecycle` — handle_info/2 + `finish_handle_params/6`
  - `Scope` — pane nav, workspace/project/dataset switch, switcher create
  - `Fields` — new/save/autosave, editor toggles, ArrayField ops
  - `Media` — image picker + upload · `Refs` — reference picker
  - `History` — revision panel + restore + profile · `Delete` · `Discard`
  - `Doc` — publish/unpublish (blast-radius) + duplicate
  - `Shares` — network shares panel · `ItemShare` — per-doc share popover
  - `Schema` — schema-declared modal actions · `Secondary` — read-only 2nd pane
  - `Bulk` — list-pane multi-select publish · `Paper` — in-Studio block editor
  """
  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.Access
  alias Barkpark.Content.CallerContext
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.{Mount, Path, Shared}

  alias BarkparkWeb.Studio.StudioLive.Handlers.{
    AccessPanel,
    Airdrop,
    Bulk,
    Delete,
    Discard,
    Doc,
    Fields,
    History,
    ItemShare,
    Lifecycle,
    Media,
    Paper,
    Refs,
    Schema,
    Scope,
    Secondary,
    Shares
  }

  # The in-Studio paper view + Studio shell function components live in
  # StudioLive.Components; importing it makes the `<.studio_paper_view ...>` /
  # `<.studio_live_shell ...>` call sites in render/1 resolve verbatim. The Beta
  # paper-editor cluster (paper_block_editor, editor_mode_toggle,
  # properties_panel, paper_block_fields) lives in Components.PaperEditor, which
  # Components itself imports — those components are rendered only from inside
  # Components' templates, so StudioLive does not import PaperEditor directly.
  import BarkparkWeb.Studio.StudioLive.Components

  @impl true
  def mount(_params, _session, socket) do
    # Airdrop live toast: subscribe the mounted account to its OWN user topic so
    # a grant minted for it while online lands as a flash (see the
    # {:airdrop_granted} handle_info). Only an authenticated User has a stable
    # id to key the topic; anonymous / token-only sessions skip it.
    if connected?(socket) do
      case socket.assigns[:current_user] do
        %{id: uid} when is_binary(uid) ->
          Phoenix.PubSub.subscribe(Barkpark.PubSub, "user:#{uid}")

        _ ->
          :ok
      end
    end

    # ag-studio-capability-hide: the LOAD-BEARING server-side deny-gate. Attach
    # on EVERY Studio socket (member/anonymous/share/grant) so a forged event
    # for a hidden affordance is server-DENIED (hidden ≠ denied). The gate
    # re-derives caps per event → mid-session grant expiry denies at once.
    socket =
      socket
      |> Mount.init()
      |> Caps.attach()
      |> load_access_grants()
      |> schedule_access_expiry()

    {:ok, socket}
  end

  # ── Access grants + live expiry (airdrop-grants slice 3) ────────────────────

  # The active grants bound to the signed-in account, for the Access panel +
  # the expiry-tick refresh. Empty for token-only / anonymous sockets.
  defp load_access_grants(socket) do
    grants =
      case socket.assigns[:current_user] do
        %{id: uid} when is_binary(uid) -> Access.list_active_grants_for_grantee(uid)
        _ -> []
      end

    Phoenix.Component.assign(socket, :access_grants, grants)
  end

  # Schedule a single server tick at the NEAREST grant expiry so access DROPS at
  # expiry with no reload: the tick reloads grants + re-derives `caps`, so the
  # hidden affordances update and the deny-gate reads live caps. Only when
  # connected and a soonest expiry exists.
  defp schedule_access_expiry(socket) do
    with true <- connected?(socket),
         %DateTime{} = soonest <- soonest_expiry(socket.assigns[:access_grants]) do
      ms = max(DateTime.diff(soonest, DateTime.utc_now(), :millisecond) + 500, 250)
      Process.send_after(self(), :access_expiry_tick, ms)
    end

    socket
  end

  defp soonest_expiry(grants) when is_list(grants) do
    grants
    |> Enum.map(& &1.expires_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.min_by(list, &DateTime.to_unix(&1))
    end
  end

  defp soonest_expiry(_), do: nil

  defp refresh_caps(socket), do: Phoenix.Component.assign(socket, :caps, Caps.derive(socket))

  # Rebuild the grant-derived access state after a grant-set change — the expiry
  # tick OR a revoke broadcast (ag-liveview-read-liveness). WRITES were already
  # closed (the Caps gate re-derives per mutating event), but READS leaked: the
  # row-narrowing `Content.Scope.scope_to_grants` reads `caller_context.grants`,
  # which `ScopeHelpers.scope_opts(socket)` pulls verbatim from the MOUNT-TIME
  # `:caller_context` assign — so an expired/revoked grant kept serving its rows
  # until reconnect. This rebuilds that snapshot from the DB, so the very next
  # read narrows to the caller's CURRENT active grants.
  #
  #   * `load_access_grants` — the `:access_grants` panel list (active-filtered).
  #   * `refresh_caller_context` — the grant-bearing ctx the READ path consumes.
  #   * `refresh_caps` — the affordance map + the deny-gate's cached caps.
  defp refresh_grant_access(socket) do
    socket
    |> load_access_grants()
    |> refresh_caller_context()
    |> refresh_caps()
  end

  # Rebuild the grant-bearing `:caller_context` from the DB so the LIVE read path
  # (scope_opts → CallerContext.from_conn reads `:caller_context` verbatim →
  # scope_to_grants) narrows to CURRENT active grants, not the mount-time
  # snapshot. `from_user/2` re-loads active grants in-query (expired / revoked
  # ones already dropped), so an invalidated grant's rows vanish on the next
  # read. ONLY a grant-scoped socket carries this ctx; a member / anonymous /
  # share socket never routes through scope_to_grants, so it is left untouched.
  defp refresh_caller_context(socket) do
    case {socket.assigns[:grant_scoped_read], socket.assigns[:current_user]} do
      {true, %{id: uid}} when is_binary(uid) ->
        Phoenix.Component.assign(socket, :caller_context, CallerContext.from_user(uid))

      _ ->
        socket
    end
  end

  # Re-run mount-level admission after a grant-set refresh. A grant-SCOPED socket
  # was admitted at mount ONLY because some active grant admitted the mounted
  # desk for :read (LiveScope.grant_read_ctx). If, after the refresh, NO active
  # grant still admits it, the grant that opened this desk is gone (expired or
  # revoked) — and an invalid grant is a DEAD desk, indistinguishable from no
  # grant. So we kill it exactly as `LiveScope.deny/1` would have at mount
  # (redirect to /login). Member / anonymous / share sockets never carry
  # `:grant_scoped_read`, so this is a no-op for them (never an over-deny).
  defp enforce_admission(%{assigns: %{grant_scoped_read: true}} = socket) do
    if grant_admission_holds?(socket) do
      socket
    else
      socket
      |> put_flash(:error, "Your access grant is no longer valid.")
      |> redirect(to: "/login")
    end
  end

  defp enforce_admission(socket), do: socket

  defp grant_admission_holds?(socket) do
    ctx = socket.assigns[:caller_context]
    desk = admission_desk_scope(socket)

    match?(%CallerContext{}, ctx) and is_map(desk) and
      Enum.any?(ctx.grants, &(Access.admits_desk?(&1, :read, desk) == true))
  end

  # The mounted desk (workspace/project/dataset granularity) — mirrors
  # `LiveScope.desk_scope/3`, fed to `Access.admits_desk?/3`. Nil workspace ⇒ nil
  # (no desk to admit ⇒ admission fails closed).
  defp admission_desk_scope(socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]
    dataset = socket.assigns[:dataset]

    if is_map(ws) and is_binary(Map.get(ws, :id)) do
      %{workspace_id: ws.id}
      |> put_scope_level(:project_id, is_map(proj) && Map.get(proj, :id))
      |> put_scope_level(:dataset, dataset)
    end
  end

  defp put_scope_level(scope, key, value) when is_binary(value), do: Map.put(scope, key, value)
  defp put_scope_level(scope, _key, _value), do: scope

  @impl true
  def handle_params(params, uri, socket) do
    dataset = params["dataset"] || default_dataset()
    path = Map.get(params, "path", [])
    desk = params["desk"]

    socket = Shared.ensure_tenancy_scope(socket)

    # Tenant log attribution (both-surfaces parity with the HTTP TenantLogMetadata
    # plug). Logger.metadata is per-process; the connected Studio runs on this
    # long-lived LiveView process, and handle_params re-runs on every navigation /
    # scope switch (push_patch), so a mid-session workspace switch re-stamps.
    BarkparkWeb.Plugs.TenantLogMetadata.stamp(
      socket.assigns[:current_workspace],
      socket.assigns[:current_project],
      dataset
    )

    case Shared.redirect_dataset_leaf(socket, dataset) do
      {:redirect, slug} ->
        {:noreply, push_patch(socket, to: Shared.studio_path(socket, path, slug, desk: desk))}

      :ok ->
        Lifecycle.finish_handle_params(socket, dataset, path, desk, uri, params)
    end
  end

  # ── handle_info/2 routing heads ─────────────────────────────────────────────

  @impl true
  # Airdrop live toast (airdrop-grants): a grantee with an account who is online
  # when a grant is minted for them gets a minimal "you've been granted access"
  # toast on their OWN user topic. The payload carries NO grant details — the
  # authenticated LV fetches them itself; this only nudges them to look.
  def handle_info({:airdrop_granted}, socket) do
    # Reload grants + re-derive caps so a newly-granted affordance UNLOCKS live
    # (hidden → shown) and the deny-gate reads the new caps — then re-arm the
    # expiry tick against the (possibly sooner) new grant.
    socket =
      socket
      |> load_access_grants()
      |> refresh_caps()
      |> schedule_access_expiry()

    {:noreply,
     put_flash(socket, :info, "You've been granted access — check your email to claim it.")}
  end

  # Expiry tick (airdrop-grants / ag-liveview-read-liveness): a grant crossed its
  # expiry. Rebuild the grant-derived access state — grants + the read-path
  # `caller_context` + caps — so both WRITES (caps gate) and READS
  # (scope_to_grants) drop the expired grant with NO reload; re-arm for the
  # next-soonest expiry; then re-run admission so a desk that no longer has ANY
  # covering grant is killed (dead desk = zero rows), not merely narrowed.
  def handle_info(:access_expiry_tick, socket) do
    socket =
      socket
      |> refresh_grant_access()
      |> schedule_access_expiry()
      |> enforce_admission()

    {:noreply, socket}
  end

  # Live revoke (ag-liveview-read-liveness): `Access.revoke/2` broadcast
  # `{:airdrop_revoked}` on this grantee's user topic. Rebuild the grant-derived
  # access state (the revoked grant drops in-query) so the next read narrows,
  # then re-run admission — a revoke that removes the desk's only covering grant
  # kills the socket, exactly like an expiry. There is no re-arm: revoke is
  # event-driven, not time-driven.
  def handle_info({:airdrop_revoked}, socket) do
    {:noreply, socket |> refresh_grant_access() |> enforce_admission()}
  end

  def handle_info({:doc_updated, msg}, socket), do: Lifecycle.doc_updated(msg, socket)
  def handle_info({:paper_block, frame}, socket), do: Lifecycle.paper_block(frame, socket)
  def handle_info({:paper_updated, msg}, socket), do: Lifecycle.paper_updated(msg, socket)
  def handle_info({:sheets_op, payload}, socket), do: Lifecycle.sheets_op(payload, socket)

  def handle_info({:sheets_persisted, payload}, socket),
    do: Lifecycle.sheets_persisted(payload, socket)

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket),
    do: Lifecycle.presence_diff(topic, socket)

  def handle_info({:document_changed, msg}, socket), do: Lifecycle.document_changed(msg, socket)
  def handle_info({:autosave_form, form}, socket), do: Lifecycle.autosave_form(form, socket)
  def handle_info({:paper_op, %{"op" => _} = op}, socket), do: Lifecycle.paper_op(op, socket)

  def handle_info({:tree_codelist_change, msg}, socket),
    do: Lifecycle.tree_codelist_change(msg, socket)

  # Fall-through: a stray PubSub message must not FunctionClauseError-crash the
  # session (mirrors bulldocs_live.ex). Keep LAST among handle_info/2 clauses.
  def handle_info(_other, socket), do: {:noreply, socket}

  # ── handle_event/3 routing heads ────────────────────────────────────────────

  @impl true
  def handle_event("select", params, socket), do: Scope.select(params, socket)
  def handle_event("select-group", params, socket), do: Scope.select_group(params, socket)
  def handle_event("select-desk", params, socket), do: Scope.select_desk(params, socket)
  def handle_event("switch-workspace", params, socket), do: Scope.switch_workspace(params, socket)
  def handle_event("switch-project", params, socket), do: Scope.switch_project(params, socket)
  def handle_event("switch-dataset", params, socket), do: Scope.switch_dataset(params, socket)
  def handle_event("toggle-create", params, socket), do: Scope.toggle_create(params, socket)
  def handle_event("create-workspace", params, socket), do: Scope.create_workspace(params, socket)
  def handle_event("create-project", params, socket), do: Scope.create_project(params, socket)
  def handle_event("expand-pane", params, socket), do: Scope.expand_pane(params, socket)

  def handle_event("new-document", params, socket), do: Fields.new_document(params, socket)
  def handle_event("save", params, socket), do: Fields.save(params, socket)
  def handle_event("reload-remote-doc", _params, socket), do: Fields.reload_remote_doc(socket)
  def handle_event("slug-generate", params, socket), do: Fields.slug_generate(params, socket)
  def handle_event("autosave", params, socket), do: Fields.autosave(params, socket)

  def handle_event("toggle-content-preview", _params, socket),
    do: Fields.toggle_content_preview(socket)

  def handle_event("toggle-diff", _params, socket), do: Fields.toggle_diff(socket)
  def handle_event("editor-set-mode", params, socket), do: Fields.editor_set_mode(params, socket)

  # ── Responsive width bucket (studio-space-priority-desk spd-s2) ──────────────
  # A client-side hook (attached in spd-s4) reports which responsive width band
  # the viewport is in so the space-priority desk knows which pane to collapse
  # first. Pure layout telemetry — no persisted state — classified `:none` in
  # `BarkparkWeb.Studio.Caps` so anonymous / share / grant sockets may report it
  # (an unclassified event would fall to the default-DENY tier and never reach a
  # non-admin socket's handler). INERT this round: no call site passes the hook
  # yet. The guard drops any bucket outside the known set; the fallback head
  # ignores a malformed payload without crashing the session.
  def handle_event("width-bucket", %{"bucket" => bucket}, socket)
      when bucket in ~w(wide standard narrow phone),
      do:
        {:noreply,
         Phoenix.Component.assign(socket,
           width_bucket: bucket,
           focus_pane_idx: nil,
           focus_doc_on_open: false
         )}

  def handle_event("width-bucket", _params, socket), do: {:noreply, socket}

  def handle_event("array_op", params, socket), do: Fields.array_op(params, socket)

  def handle_event("open-image-picker", params, socket),
    do: Media.open_image_picker(params, socket)

  def handle_event("close-image-picker", _params, socket), do: Media.close_image_picker(socket)
  def handle_event("select-media", params, socket), do: Media.select_media(params, socket)
  def handle_event("clear-image", params, socket), do: Media.clear_image(params, socket)
  def handle_event("validate-upload", _params, socket), do: Media.validate_upload(socket)
  def handle_event("upload-image", params, socket), do: Media.upload_image(params, socket)

  def handle_event("open-ref-picker", params, socket), do: Refs.open_ref_picker(params, socket)
  def handle_event("close-ref-picker", _params, socket), do: Refs.close_ref_picker(socket)
  def handle_event("ref-search", params, socket), do: Refs.ref_search(params, socket)
  def handle_event("select-ref", params, socket), do: Refs.select_ref(params, socket)
  def handle_event("clear-ref", params, socket), do: Refs.clear_ref(params, socket)

  def handle_event("show-history", _params, socket), do: History.show_history(socket)
  def handle_event("close-history", _params, socket), do: History.close_history(socket)

  def handle_event("restore-revision", params, socket),
    do: History.restore_revision(params, socket)

  def handle_event("show-profile", _params, socket), do: History.show_profile(socket)
  def handle_event("close-profile", _params, socket), do: History.close_profile(socket)
  def handle_event("preview-profile", params, socket), do: History.preview_profile(params, socket)
  def handle_event("save-profile", params, socket), do: History.save_profile(params, socket)

  def handle_event("delete-doc", _params, socket), do: Delete.delete_doc(socket)
  def handle_event("close-delete", _params, socket), do: Delete.close_delete(socket)
  def handle_event("confirm-delete", params, socket), do: Delete.confirm_delete(params, socket)

  def handle_event("discard-draft", _params, socket), do: Discard.discard_draft(socket)
  def handle_event("close-discard", _params, socket), do: Discard.close_discard(socket)
  def handle_event("confirm-discard", _params, socket), do: Discard.confirm_discard(socket)

  def handle_event("publish", _params, socket), do: Doc.publish(socket)
  def handle_event("unpublish", _params, socket), do: Doc.unpublish(socket)

  def handle_event("close-unpublish-guard", _params, socket),
    do: Doc.close_unpublish_guard(socket)

  def handle_event("confirm-unpublish", params, socket), do: Doc.confirm_unpublish(params, socket)
  def handle_event("duplicate-doc", _params, socket), do: Doc.duplicate_doc(socket)

  def handle_event("shares-open", params, socket), do: Shares.shares_open(params, socket)
  def handle_event("shares-close", _params, socket), do: Shares.shares_close(socket)
  def handle_event("shares-add", params, socket), do: Shares.shares_add(params, socket)
  def handle_event("shares-remove", params, socket), do: Shares.shares_remove(params, socket)

  def handle_event("item-share-open", params, socket),
    do: ItemShare.item_share_open(params, socket)

  def handle_event("item-share-close", _params, socket), do: ItemShare.item_share_close(socket)

  def handle_event("item-share-create", params, socket),
    do: ItemShare.item_share_create(params, socket)

  def handle_event("item-share-revoke", params, socket),
    do: ItemShare.item_share_revoke(params, socket)

  def handle_event("jump-to-user", params, socket), do: ItemShare.jump_to_user(params, socket)

  def handle_event("airdrop-open", params, socket), do: Airdrop.airdrop_open(params, socket)
  def handle_event("airdrop-close", _params, socket), do: Airdrop.airdrop_close(socket)
  def handle_event("airdrop-create", params, socket), do: Airdrop.airdrop_create(params, socket)
  def handle_event("airdrop-suggest", params, socket), do: Airdrop.airdrop_suggest(params, socket)

  # Access panel (airdrop-grants slice 3 UI) — read/revoke sibling of airdrop.
  def handle_event("access-open", _params, socket), do: AccessPanel.access_open(socket)
  def handle_event("access-close", _params, socket), do: AccessPanel.access_close(socket)
  def handle_event("access-revoke", params, socket), do: AccessPanel.access_revoke(params, socket)

  def handle_event("open-secondary-picker", _params, socket),
    do: Secondary.open_secondary_picker(socket)

  def handle_event("view-graph", _params, socket), do: Secondary.view_graph(socket)

  # The graph hook pushes `node-clicked` on EVERY node click, unconditionally,
  # and GraphView mounts it with no phx-target — so it lands here. Without this
  # head the missing clause was a FunctionClauseError that killed the view on
  # the first click (rationale + the fail-closed id resolution: Secondary.node_clicked/2).
  def handle_event("node-clicked", params, socket), do: Secondary.node_clicked(params, socket)

  def handle_event("close-secondary-picker", _params, socket),
    do: Secondary.close_secondary_picker(socket)

  def handle_event("secondary-search", params, socket),
    do: Secondary.secondary_search(params, socket)

  def handle_event("select-secondary", params, socket),
    do: Secondary.select_secondary(params, socket)

  def handle_event("close-secondary", _params, socket), do: Secondary.close_secondary(socket)

  def handle_event("toggle-doc-checkbox", params, socket),
    do: Bulk.toggle_doc_checkbox(params, socket)

  def handle_event("bulk-clear", _params, socket), do: Bulk.bulk_clear(socket)
  def handle_event("bulk-publish", _params, socket), do: Bulk.bulk_publish(socket)
  def handle_event("bulk-unpublish", _params, socket), do: Bulk.bulk_unpublish(socket)

  def handle_event("schema_action", params, socket), do: Schema.schema_action(params, socket)
  def handle_event("close-confirm-modal", _params, socket), do: Schema.close_confirm_modal(socket)

  def handle_event("confirm-modal-dryrun", _params, socket),
    do: Schema.confirm_modal_dryrun(socket)

  def handle_event("confirm-modal-real", _params, socket), do: Schema.confirm_modal_real(socket)

  def handle_event("paper-toggle-edit", _params, socket), do: Paper.paper_toggle_edit(socket)
  def handle_event("paper-edit-block", params, socket), do: Paper.paper_edit_block(params, socket)

  def handle_event("paper-block-autosave", params, socket),
    do: Paper.paper_block_autosave(params, socket)

  # t6 — WordPress-style metadata sidebar (doctrine Rule 4/5). Pure assign flips;
  # none touch body blocks.
  def handle_event("sidebar-toggle-panel", _params, socket),
    do: Paper.sidebar_toggle_panel(socket)

  def handle_event("sidebar-toggle-section", params, socket),
    do: Paper.sidebar_toggle_section(params, socket)

  def handle_event("sidebar-slug-change", params, socket),
    do: Paper.sidebar_slug_change(params, socket)

  # spd-bl-publish-affordance-triple — the hand path's publish affordances:
  # the sidebar description input, the label-add form, and the pane header's
  # Publish control. All three ride the Shared.Paper meta-write guard ladder.
  def handle_event("sidebar-description-change", params, socket),
    do: Paper.sidebar_description_change(params, socket)

  def handle_event("sidebar-label-add", params, socket),
    do: Paper.sidebar_label_add(params, socket)

  def handle_event("paper-publish", _params, socket), do: Paper.paper_publish(socket)

  def handle_event("backlinks-refresh", _params, socket), do: Paper.backlinks_refresh(socket)
  def handle_event("open-backlink", params, socket), do: Paper.open_backlink(params, socket)

  def handle_event("paper-op", %{"op" => _} = op, socket), do: Paper.paper_op(op, socket)
  def handle_event("paper-ops", params, socket), do: Paper.paper_ops(params, socket)

  # t9: live task-block preview — the canvas hook requests fresh resolved rows on
  # mount and ~500ms-debounced after a query edit; we push them on the parallel
  # bp:task-preview channel (display only, never the save baseline — D5).
  def handle_event("task-preview-refresh", _params, socket),
    do: Paper.task_preview_refresh(socket)

  # lvw-t2 (D4): accept-baseline control on a drifted valueref in the paper
  # view — an ifRev-guarded, fallback-only patch on the HOSTING paper.
  def handle_event("valueref-accept-baseline", params, socket),
    do: Paper.valueref_accept_baseline(params, socket)

  def handle_event("paper-add-block", params, socket), do: Paper.paper_add_block(params, socket)

  def handle_event("paper-materialize-slot", params, socket),
    do: Paper.paper_materialize_slot(params, socket)

  def handle_event("paper-slash-insert", params, socket),
    do: Paper.paper_slash_insert(params, socket)

  def handle_event("paper-wikilink-search", %{"query" => q}, socket),
    do: Paper.paper_wikilink_search(q, socket)

  def handle_event("paper-tag-search", %{"query" => q}, socket),
    do: Paper.paper_tag_search(q, socket)

  def handle_event("paper-add-property", params, socket),
    do: Paper.paper_add_property(params, socket)

  def handle_event("paper-unbind-property", params, socket),
    do: Paper.paper_unbind_property(params, socket)

  def handle_event("paper-delete-block", params, socket),
    do: Paper.paper_delete_block(params, socket)

  def handle_event("paper-move-block", params, socket), do: Paper.paper_move_block(params, socket)

  def handle_event("paper-move-block-to", params, socket),
    do: Paper.paper_move_block_to(params, socket)

  def handle_event("paper-callout-fold", params, socket),
    do: Paper.paper_callout_fold(params, socket)

  # ── valueref edit-through (lvw-t10) — inspect / confirm / close ────────────
  def handle_event("paper-valueref-inspect", params, socket),
    do: Paper.valueref_inspect(params, socket)

  def handle_event("valueref-writeback-confirm", params, socket),
    do: Paper.valueref_writeback(params, socket)

  def handle_event("valueref-writeback-close", _params, socket),
    do: Paper.valueref_close(socket)

  # Fall-through: a stale/unknown phx event must not FunctionClauseError-crash
  # the session (user would lose unsaved editor state). Keep LAST among
  # handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("studio: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # ── Public, test-facing path/parse delegations (StudioLive.Path) ────────────

  @doc false
  defdelegate parse_path(path), to: Path

  @doc false
  def find_field_by_path(socket, path) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    Path.field_at(fields, path)
  end

  @doc false
  defdelegate list_value_at(form, path), to: Path

  @doc false
  defdelegate put_value_at(form, path, value), to: Path

  @doc false
  defdelegate empty_for_of(field), to: Path

  # The default dataset for a bare `/studio` mount. Resolved through Content so
  # the literal isn't hardcoded at call sites.
  def default_dataset, do: Barkpark.Content.default_dataset()

  # ── Render ─────────────────────────────────────────────────────────────────
  # The full Studio shell template lives in StudioLive.Components.studio_shell/1
  # (imported above); render/1 stays here as the LiveView callback and hands the
  # assigns straight through.
  @impl true
  def render(assigns), do: studio_live_shell(assigns)
end
