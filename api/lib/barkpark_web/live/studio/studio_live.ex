defmodule BarkparkWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor

  ## Section index (~4,800-line file — navigate by grepping the `# ──` banners)

  Lifecycle: `mount/3` (assigns init, banner-grouped: Network shares P6 ·
  Item share popover P7 · Cross-field validations · Content preview
  side-pane · Document actions · Draft-vs-Published diff · In-Studio live
  paper view · In-Studio paper block editor · Switcher create affordances)
  → `handle_params/3` + `finish_handle_params/5` → `render/1` (at the very
  bottom, under "Render").

  `handle_info/2` clauses: `:doc_updated`, `:paper_block`, `:paper_updated`,
  `presence_diff`, `:document_changed`, `:autosave_form`, `:paper_op`,
  `:tree_codelist_change`.

  `handle_event/3` groups, in file order: pane nav (`select`, `select-group`,
  `select-desk`, `expand-pane`) · Workspace/Project scope switch
  (`switch-workspace`, `switch-project`) · Dataset scope switch
  (`switch-dataset`) · Switcher create affordances (`toggle-create`,
  `create-workspace`, `create-project`) · doc lifecycle (`new-document`,
  `save`, `autosave`, `publish`, `unpublish`) · editor toggles
  (`toggle-content-preview`, `toggle-diff`, `editor-set-mode`) · ArrayField
  (`array_op`) · Image field (`*-image-picker`, `select-media`,
  `upload-image`) · Reference field (`*-ref-picker`, `ref-search`,
  `select-ref`, `clear-ref`) · History (`show-history`, `restore-revision`) ·
  Delete with reference check (`delete-doc`, `confirm-delete`) ·
  Discard draft (`discard-draft`, `close-discard`, `confirm-discard`) · Profile
  edit · Network shares panel (`shares-*`) · Item share popover
  (`item-share-*`, `jump-to-user`) · E1 Duplicate (`duplicate-doc`) ·
  E2 secondary pane (`*-secondary*`) · E3 Bulk publish (`bulk-*`,
  `toggle-doc-checkbox`) · Schema-declared document actions
  (`schema_action`, `confirm-modal-*`) · In-Studio paper block editor
  (`paper-*`).

  Helper sections (private, banner-named): paper editor helpers · EX2
  expectation-aware slash menu · block-patch builders + `default_block/2`
  catalog (rich-text / visual / article-chrome / leaf `field-*` blocks) ·
  Content preview side-pane · Bulk publish helpers · Tenancy scope ·
  Project → Dataset cascade · Schema-action helpers · Doc-actions registry ·
  ArrayField helpers · path-based navigation for nested arrayOf · Pane
  builder · In-Studio live paper view (+ function component) · Classic <->
  Beta toggle · Cross-field validations · Paper block editor (function
  component) · Network shares panel helpers.
  """
  use BarkparkWeb, :live_view

  alias Barkpark.{Content, Media, Structure, Tenancy}
  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Presence
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.{PaneBuilder, PresenceState}
  alias BarkparkWeb.Studio.StudioLive.{Blocks, DocActions, Mount, Path}

  # The in-Studio paper view / Beta editor / per-block-field function
  # components live in StudioLive.Components; import so the `<.studio_paper_view
  # ...>` / `<.paper_block_editor ...>` call sites in render/1 resolve verbatim.
  import BarkparkWeb.Studio.StudioLive.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Mount.init(socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    dataset = params["dataset"] || default_dataset()
    path = Map.get(params, "path", [])
    desk = params["desk"]

    socket = ensure_tenancy_scope(socket)

    # Defense-in-depth (Task barkpark-o7fu): validate the URL dataset leaf
    # against the RESOLVED project before trusting it — mirroring how the
    # `switch-dataset` handler gates a slug via `project_has_dataset?/2`.
    # A direct navigation to `/studio/<arbitrary-dataset>` otherwise takes the
    # leaf verbatim into rebuild_panes/subscribe with no membership/ownership
    # check. This is NOT a cross-tenant leak — content reads are already bounded
    # by `scope_opts` (Content.Scope filters workspace_id/project_id), so a
    # foreign slug yields the member's own (likely empty) data — but it lets the
    # URL claim a dataset the project doesn't own, leaving inconsistent state on
    # the lone scope WHERE-clause. When the leaf isn't one of the project's
    # datasets we push_patch to the project's default dataset instead.
    #
    # The redirect ONLY fires when the project actually has a non-leaf default to
    # fall back to (`default_dataset_for_project/1` is a struct). For a project
    # with NO dataset rows (string-seam-only / not-yet-seeded) `project_has_dataset?`
    # is false for EVERY slug, but there is nothing to redirect TO — the `dataset`
    # string stays authoritative there (same invariant rescope_dataset_for_project
    # holds). The chosen default always satisfies `project_has_dataset?`, so the
    # patched navigation never loops.
    case redirect_dataset_leaf(socket, dataset) do
      {:redirect, slug} ->
        {:noreply, push_patch(socket, to: studio_path(socket, path, slug, desk: desk))}

      :ok ->
        finish_handle_params(socket, dataset, path, desk, uri, params)
    end
  end

  defp finish_handle_params(socket, dataset, path, desk, uri, params) do
    socket =
      socket
      |> ensure_list_subscription(dataset)
      |> ensure_presence_subscription()

    current_path =
      case uri do
        u when is_binary(u) ->
          case URI.parse(u) do
            %URI{path: p} when is_binary(p) -> p
            _ -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(
        dataset: dataset,
        nav_path: path,
        nav_desk: desk,
        current_path: current_path
      )
      |> maybe_open_shares(params)
      |> rebuild_panes()
      |> subscribe_to_doc()
      |> track_presence()

    {:noreply, socket}
  end

  # ?shares=open — the chrome-level Share button on non-Studio surfaces
  # (MediaLive, plugin pages) navigates here with this param so the panel
  # opens on arrival (StudioChrome.nav_to_shares). Admin-gated exactly
  # like the in-page shares-open handler; non-admins just land in Studio.
  defp maybe_open_shares(socket, %{"shares" => "open"}) do
    if Mount.shares_admin?(socket) do
      assign(socket,
        show_shares: true,
        shares_error: nil,
        shares_rows: load_share_rows(),
        shares_scope_prefill: shares_scope_prefill(socket),
        shares_prefill_surfaces: []
      )
    else
      socket
    end
  end

  defp maybe_open_shares(socket, _params), do: socket

  # Doc-specific update — just patch the editor form, no rebuild
  @impl true
  def handle_info({:doc_updated, %{sender: sender, doc: doc_data}}, socket) do
    if sender != self() && socket.assigns[:editor_doc] do
      # Another user edited this doc — update form values live
      schema = socket.assigns[:editor_schema]
      updated_form = Content.doc_to_form(doc_data, schema)

      {:noreply,
       assign(socket, editor_form: updated_form, save_status: "Updated by another user")}
    else
      {:noreply, socket}
    end
  end

  # ── In-Studio live paper deltas (convergence/papers-in-studio) ──────────────
  #
  # A paper open in the editor pane subscribes to its per-doc topic
  # (`doc:<dataset>:paper:<slug>` == Content.paper_topic/2). These frames patch
  # the block stream / HTML in place — NO rebuild_panes, NO remount. Mirrors
  # BulldocsLive's delta handling so the Gate-B streaming property holds inside
  # the Studio. Frames that arrive while no paper is open are ignored.

  @impl true
  def handle_info({:paper_block, frame}, socket) do
    cond do
      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      # First block delta to a view still in HTML-only mode: no stream to
      # append onto — adopt the block list wholesale via a refetch.
      not socket.assigns.paper_block_mode ->
        {:noreply, refetch_paper(socket)}

      # Missed a frame — refetch the whole doc and re-stream from scratch.
      paper_gap?(socket.assigns.paper_rev, frame.rev) ->
        {:noreply, refetch_paper(socket)}

      true ->
        socket = apply_paper_delta(socket, frame)
        # In Edit mode the per-block form reads from `paper_doc.content`, so it
        # must track the new block list too — refresh just the in-memory doc
        # (the stream already advanced via apply_paper_delta). This keeps the
        # editor form correct whether the delta came from THIS pane's own op or
        # from another source (a remote viewer / the ingest endpoint), proving
        # edits-are-ops both ways.
        socket =
          if socket.assigns[:paper_edit_mode] do
            socket
            |> sync_paper_edit_doc()
            # Rich-text editor blocks (paragraph/heading/list) live inside a
            # `phx-update="ignore"` wrapper so LiveView won't clobber the
            # user's caret. That also means the wrapper's data-block attribute
            # never repatches — so a delta from another agent / the ingest
            # endpoint would silently miss the editor until the next remount.
            # Push the fresh block as a `bp:block-update` event; the
            # `BarkparkPaperEditor` hook filters by element id and calls the
            # `<bp-paper-editor>` WC's `block` property setter, which re-mounts
            # its TipTap content in place (the WC already exposes the setter).
            |> push_block_to_wc(frame.block_id)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def handle_info({:paper_updated, %{html: html} = msg}, socket) do
    if socket.assigns[:editor_view] == :paper do
      {:noreply,
       socket
       |> assign(:paper_html, html)
       |> assign(:paper_block_mode, false)
       |> assign(:paper_rev, msg[:rev] || socket.assigns.paper_rev)}
    else
      {:noreply, socket}
    end
  end

  # ── In-Studio sheet grid deltas (Sheets M2) ─────────────────────────────
  # Session deltas for the OPEN sheet forward into the SheetGrid
  # LiveComponent (it owns the grid state and applies them in place — no
  # rebuild_panes, no remount). This pane's own ops and remote edits ride
  # the SAME path: the component never applies an op locally, so a second
  # browser on the same sheet stays live by construction. Frames arriving
  # while no sheet is open are ignored.
  def handle_info({:sheets_op, payload}, socket) do
    if socket.assigns[:editor_view] == :sheet and socket.assigns[:sheet_doc] do
      send_update(BarkparkWeb.Studio.SheetGrid,
        id: "sheet-grid-#{Content.published_id(socket.assigns.sheet_doc.doc_id)}",
        sheets_op: payload
      )
    end

    {:noreply, socket}
  end

  # Presence updates
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    cond do
      # Sheet-grid presence (Sheets M4): diffs on the per-sheet topic
      # refresh the collaborator list the SheetGrid component renders
      # (cursors, selections, editing tags). Keyed by the broadcast topic so
      # the studio in-bar presence below stays untouched.
      topic != nil and topic == socket.assigns[:sheet_presence_topic] ->
        {:noreply, assign(socket, sheet_presences: PresenceState.list(topic))}

      # In-bar studio presence. Diffs only arrive on the subscribed
      # (ws-keyed) topic; a diff racing a workspace flip before
      # ensure_presence_subscription re-keys is read off the OLD topic and
      # immediately superseded by the post-flip track.
      socket.assigns[:presence_topic] != nil ->
        {:noreply,
         assign(socket, presences: PresenceState.list(socket.assigns.presence_topic))}

      true ->
        {:noreply, socket}
    end
  end

  # Global doc change — rebuild if we're viewing this type
  @impl true
  def handle_info({:document_changed, %{type: type}}, socket) do
    # Find which type we're viewing (may be nested under settings)
    viewing_type = socket.assigns[:editor_type] || Enum.at(socket.assigns.nav_path, 0)

    if viewing_type == type do
      {:noreply, rebuild_panes(socket)}
    else
      {:noreply, socket}
    end
  end

  # Autosave triggered programmatically (e.g. after image selection).
  # Indirection lets the picker close immediately (assign + close in the
  # click handler) and runs the save in a separate handle_info turn.
  @impl true
  def handle_info({:autosave_form, form}, socket) do
    {:noreply, do_autosave(socket, form)}
  end

  # A v2 COMPOSITE field block's nested PaperFieldBlock LiveComponent (P2.3)
  # changed its value. It sends the SAME patch-block op the client bridge sends
  # for leaf blocks; route it through the canonical `paper_op/2` pipeline so
  # composites persist + broadcast + re-sync exactly like every other edit.
  def handle_info({:paper_op, %{"op" => _} = op}, socket) do
    {:noreply, paper_op(socket, op)}
  end

  # A nested TreeCodelistField (hosted inside a codelist PaperFieldBlock) had a
  # row selected. A server-driven hidden-input change does NOT fire the
  # surrounding form's phx-change, so the tree notifies this LiveView with the
  # picked code + the dom id of its hosting PaperFieldBlock. Route it back into
  # that component via `send_update/3`; PaperFieldBlock's `%{tree_value: …}`
  # clause then persists it through the canonical patch-block op pipeline.
  def handle_info({:tree_codelist_change, %{id: id, value: code}}, socket) do
    send_update(BarkparkWeb.Studio.PaperFieldBlock, id: id, tree_value: code)
    {:noreply, socket}
  end

  # Bridge the LV server-side paper-block delta into the `<bp-paper-editor>` WC
  # sitting inside a `phx-update="ignore"` wrapper. Called from the
  # `{:paper_block, frame}` handle_info above (and is sole reason it's near the
  # handle_info group). Looks up the freshly-synced block by id in
  # `paper_doc.content`, pushes `bp:block-update` with `{block_id, block}` so
  # the per-block hook can call `wc.block = block`. No-op for unknown block ids
  # (the patch may have removed it; the stream side already handled that).
  defp push_block_to_wc(socket, block_id) when is_binary(block_id) do
    paper = socket.assigns[:paper_doc]

    blocks =
      case paper && Map.get(paper, :content) do
        %{"blocks" => blocks} when is_list(blocks) -> blocks
        _ -> []
      end

    case Enum.find(blocks, fn b -> Map.get(b, "id") == block_id end) do
      nil ->
        socket

      block ->
        push_event(socket, "bp:block-update", %{block_id: block_id, block: block})
    end
  end

  defp push_block_to_wc(socket, _), do: socket

  # Keep the document-list PubSub subscription pointed at the CURRENT scope's
  # topic (barkpark-fe2k). Idempotent: re-subscribes only when the resolved
  # topic differs from the tracked `list_topic` assign — so it fires on a
  # dataset switch (handle_params) AND a same-slug workspace switch (where
  # the dataset is unchanged but the owning workspace flipped). The bare
  # `documents:#{dataset}` topic fans out to ALL co-dataset tenants; the
  # ws-scoped `documents:ws:#{ws}:#{dataset}` topic (broadcast additively by
  # content.ex's tap_broadcast/5 for scoped writes) carries only this tenant's
  # events. nil current_workspace → bare topic (flat/Default back-compat).
  defp ensure_list_subscription(socket, dataset) do
    if connected?(socket) do
      ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
      new_topic = list_topic(dataset, ws_id)
      old_topic = socket.assigns[:list_topic]

      if new_topic == old_topic do
        socket
      else
        if old_topic, do: Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
        Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)
        assign(socket, list_topic: new_topic)
      end
    else
      socket
    end
  end

  # Resolve the document-list PubSub topic (barkpark-fe2k). Workspace-scoped
  # when a workspace is resolved, bare global otherwise (flat/Default).
  defp list_topic(dataset, ws_id) when is_binary(ws_id),
    do: "documents:ws:#{ws_id}:#{dataset}"

  defp list_topic(dataset, _ws_id), do: "documents:#{dataset}"

  # Re-key the presence subscription to the CURRENT workspace's topic
  # (tsk-url-p0 — same diff-and-resubscribe shape as ensure_list_subscription).
  # On a workspace flip the old tracking is explicitly untracked: Presence
  # entries are (topic, key)-scoped, so without the untrack the user's avatar
  # would linger on the OLD workspace's topic until the LV process dies.
  defp ensure_presence_subscription(socket) do
    if connected?(socket) do
      ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
      new_topic = PresenceState.topic(ws_id)
      old_topic = socket.assigns[:presence_topic]

      if new_topic == old_topic do
        socket
      else
        if old_topic do
          Presence.untrack(self(), old_topic, socket.assigns.user_id)
          Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
        end

        Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)
        assign(socket, presence_topic: new_topic)
      end
    else
      socket
    end
  end

  # Subscribe to the specific doc being edited
  defp subscribe_to_doc(socket) do
    old_sub = socket.assigns[:subscribed_doc]

    # Unsubscribe from old doc
    if old_sub do
      Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_sub)
    end

    # Subscribe to new doc if editing
    case socket.assigns do
      %{editor_type: type, editor_doc: %{doc_id: doc_id}} when not is_nil(type) ->
        # Workspace-scope the subscription (barkpark-rwva, P1). The per-doc
        # topic now carries the owning workspace; subscribe with the editor's
        # current workspace so an edit to another tenant's colliding
        # (type, pubid) doc never lands here. nil current_workspace (no Default
        # seeded) normalizes identically on both sides via doc_topic/4.
        ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id

        topic =
          Content.doc_topic(
            Content.published_id(doc_id),
            type,
            ws_id,
            socket.assigns.dataset
          )

        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        assign(socket, subscribed_doc: topic)

      _ ->
        assign(socket, subscribed_doc: nil)
    end
  end

  defp track_presence(socket) do
    if connected?(socket) do
      # Determine what doc we're viewing
      doc_id =
        case socket.assigns do
          %{editor_doc: %{doc_id: did}, editor_type: type} when not is_nil(type) ->
            Content.published_id(did)

          _ ->
            nil
        end

      meta = %{
        doc_id: doc_id,
        type: socket.assigns[:editor_type],
        # Scope stamps (tsk-url-p0): dataset disambiguates same-doc_id
        # presence across datasets (PresenceState.on_doc/3); project_id
        # lets future consumers (jump-to-user across projects) resolve
        # the full location without a lookup.
        dataset: socket.assigns[:dataset],
        project_id: socket.assigns[:current_project] && socket.assigns.current_project.id,
        name: socket.assigns.user_name,
        color: socket.assigns.user_color,
        joined_at: System.system_time(:second)
      }

      # The ws-keyed topic is seeded by ensure_presence_subscription before
      # any track call in the handle_params pipeline; the fallback covers
      # out-of-band callers (save-profile) racing an unconnected socket.
      ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
      topic = socket.assigns[:presence_topic] || PresenceState.topic(ws_id)

      # Use update if already tracked, track if new
      case Presence.get_by_key(topic, socket.assigns.user_id) do
        [] -> Presence.track(self(), topic, socket.assigns.user_id, meta)
        _ -> Presence.update(self(), topic, socket.assigns.user_id, meta)
      end

      assign(socket, presences: PresenceState.list(topic))
    else
      socket
    end
  end

  # Born-valid Studio creates (tsk-dossier-studio-create). The task write
  # path validates content BEFORE any scaffold/initial_values merge
  # (content.ex: validate_task_kind runs ahead of do_create_document's
  # insert-branch scaffold), so a bare {doc_id, title} create for
  # type:task ALWAYS failed — humans could not create tasks in Studio at
  # all. Seed the two required fields here, in the Studio create flow
  # only. Deliberately NOT schema initial_values: validated-before-merge
  # makes those inert for this, and a priority default would deep-merge
  # into every API create that omits priority, silently re-ranking the
  # bd ready queue (see /papers/task-dossier-schema). No priority seeded:
  # a fresh Studio task sorts NULLS-LAST exactly like a fresh bd task.
  defp seed_new_doc_content("task"), do: %{"kind" => "task", "lifecycle_status" => "open"}
  defp seed_new_doc_content(_type), do: %{}

  @impl true
  def handle_event("select", %{"pane" => pane_str, "id" => id}, socket) do
    pane_idx = String.to_integer(pane_str)
    new_path = Enum.take(socket.assigns.nav_path, pane_idx) ++ [id]
    {:noreply, push_patch(socket, to: studio_path(socket, new_path, socket.assigns.dataset))}
  end

  # Schema-driven field-group tabs (Sanity Studio parity). Pure LV state —
  # no URL patch (decided against `?group=` in the task brief to keep the
  # route surface tight; the editor URL still uniquely identifies the doc).
  def handle_event("select-group", %{"group" => name}, socket) do
    {:noreply, assign(socket, nav_group: name)}
  end

  # Schema-declared desk groups (custom column filter chips on the
  # `:document_type_list` pane). The desk lives in the `?desk=…` query
  # param so the view is shareable/bookmarkable — switching desk
  # `push_patch`'s a new URL with the same nav_path. An empty/absent
  # desk drops the chip filter and reverts to the default flat list.
  def handle_event("select-desk", %{"desk" => name}, socket) do
    desk = if name == "" or name == socket.assigns[:nav_desk], do: nil, else: name

    {:noreply,
     push_patch(socket,
       to: studio_path(socket, socket.assigns.nav_path, socket.assigns.dataset, desk: desk)
     )}
  end

  # ── Workspace / Project scope switch (Task barkpark-k86v) ───────────────────
  #
  # The WorkspaceSwitcher component fires these on `<select>` change. On the
  # historical flat mount (`/studio/:dataset`) the workspace/project scope
  # lived on the socket — switching is a pure LiveView event, not a URL
  # navigation. Selecting a workspace re-defaults the project to that
  # workspace's first project (the current project belongs to the OLD
  # workspace, so it can't carry over). After re-assigning the scope we
  # rebuild_panes so the desk/schemas reload for the chosen scope. Re-scoping
  # the URL under `/w/:ws/p/:project` is the sibling task barkpark-4tuu.
  def handle_event("switch-workspace", %{"workspace" => slug}, socket) do
    case Tenancy.get_workspace_by_slug(slug) do
      nil ->
        {:noreply, socket}

      workspace ->
        # Hard tenant boundary: a switch is honoured only when the mounted
        # principal may reach the target workspace (membership), or — for the
        # genuinely-anonymous/dev session that has no principal — when the
        # target IS the workspace already on the socket (the seeded Default).
        # Anything else is a foreign re-scope and is silently dropped.
        cond do
          not can_reach_workspace?(socket, workspace) ->
            {:noreply, socket}

          # Hard scope invariant (barkpark-yxz2): never switch INTO a workspace
          # that has zero projects. `initial_project/1` is non-nil whenever the
          # workspace has any project (it prefers the Default project, else the
          # first), so a nil result here means the workspace is genuinely
          # project-less. Assigning `current_project: nil` and proceeding would
          # let a later scoped write (new-document / do_autosave) build
          # scope_opts with NO :project_id — ScopeHelpers drops the nil key and
          # `resolve_write_scope` falls back to the Default tenant, leaking the
          # doc across the boundary. Refuse the switch and keep the prior scope.
          is_nil(initial_project(workspace)) ->
            {:noreply,
             put_flash(socket, :error, "Workspace has no projects yet — create one first")}

          true ->
            project = initial_project(workspace)

            # Cascade: the new workspace's project carries its OWN datasets — the
            # old dataset slug belongs to the old project and may not exist here.
            # Re-scope the dataset to the new project's default (production-first,
            # else first) and patch the URL leaf so handle_params re-subscribes +
            # rebuilds against the chosen dataset. When the project has no dataset
            # rows we keep the current slug (the string seam stays authoritative).
            {:noreply,
             socket
             |> assign(current_workspace: workspace, current_project: project)
             |> sync_scope_prefix()
             |> rescope_dataset_for_project(project)}
        end
    end
  end

  def handle_event("switch-project", %{"project" => slug}, socket) do
    ws = socket.assigns[:current_workspace]

    # The project lives under the CURRENT workspace; the workspace itself is
    # already membership-gated (mount + switch-workspace). Re-affirm the gate
    # so a forged project switch can never re-scope to a workspace the
    # principal lost access to mid-session.
    with %{} = ws <- ws,
         true <- can_reach_workspace?(socket, ws),
         %{} = project <- Tenancy.get_project(ws.slug, slug) do
      # Cascade (barkpark-dgpf): reload the Dataset select for the new project
      # and auto-select that project's default dataset (a "production" slug if
      # present, else the first), then re-scope to it via push_patch. The
      # Dataset is chosen from the project's datasets, not a free string.
      {:noreply,
       socket
       |> assign(current_project: project)
       |> sync_scope_prefix()
       |> rescope_dataset_for_project(project)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Dataset scope switch (Task barkpark-dgpf) ───────────────────────────────
  #
  # The Dataset is the FAR-RIGHT control of the Workspace · Project · Dataset
  # trio and IS the `/studio/:dataset` URL leaf. Its options are the CURRENT
  # project's datasets (`Tenancy.list_datasets/1`), so a switch is honoured only
  # when the chosen slug actually belongs to the current project — a forged slug
  # for another project's dataset is silently dropped. On a valid pick we
  # push_patch to `/studio/:slug`; handle_params re-subscribes the documents
  # topic and rebuilds the panes against the new dataset. The workspace/project
  # scope on the socket is untouched (the dataset is the project's leaf).
  def handle_event("switch-dataset", %{"dataset" => slug}, socket) do
    project = socket.assigns[:current_project]

    cond do
      not is_binary(slug) or slug == "" ->
        {:noreply, socket}

      slug == socket.assigns[:dataset] ->
        {:noreply, socket}

      project_has_dataset?(project, slug) ->
        {:noreply, push_patch(socket, to: studio_path(socket, [], slug))}

      true ->
        {:noreply, socket}
    end
  end

  # ── Switcher create affordances (Task barkpark-ylrw) ────────────────────────
  #
  # The WorkspaceSwitcher's "＋" buttons toggle a tiny inline name form on the
  # Workspace / Project control. Creation reuses the just-merged atomic context
  # (`Tenancy.create_workspace_with_owner/2` + `create_project_with_dataset/2`)
  # — workspace creation needs a principal to own the Membership, so all three
  # handlers no-op when `api_token` is nil (the affordance is also hidden in the
  # layout's `can_create`, but the handler re-guards against a forged event).

  # Open/close one inline form. Re-clicking the open target closes it; a
  # different target swaps. Pure assign flip — no DB, no navigation.
  def handle_event("toggle-create", %{"target" => target}, socket)
      when target in ["workspace", "project"] do
    next = if socket.assigns[:create_open] == target, do: nil, else: target
    {:noreply, assign(socket, create_open: next)}
  end

  def handle_event("toggle-create", _params, socket), do: {:noreply, socket}

  # Create a workspace + its owner Membership + Default project + production
  # dataset (one atomic context call), then switch the whole scope to it:
  # current_workspace = the new ws, current_project = its Default project,
  # dataset = the project's production dataset (push_patch re-subscribes +
  # rebuilds). On success the form closes; on error it stays open with a flash.
  def handle_event("create-workspace", %{"name" => name}, socket) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case Tenancy.create_workspace_with_owner(%{name: name}, token) do
          {:ok, workspace} ->
            # Re-derive the project from the DB (default-first resolver) instead
            # of trusting `workspace.projects` — the transaction returns a
            # %Project{} with NO :datasets assoc loaded, so the optimistic
            # `current_project` assign could diverge from the membership-joined
            # switcher list (`Tenancy.list_projects/1`) for one render cycle
            # (cosmetic, self-corrects on the next handle_params). `initial_project/1`
            # is the same DB-backed resolver mount + switch-workspace already use,
            # so the assign matches the rendered list immediately (barkpark-6z0e).
            project = initial_project(workspace)

            {:noreply,
             socket
             |> assign(create_open: nil, current_workspace: workspace, current_project: project)
             # Same prefix sync the switch handlers got in P2 — without it
             # the rescope push_patch is built from the STALE prefix and
             # LiveScope's reauthorize hook silently reverts the switch
             # into the just-created workspace (caught by the P3 test fleet).
             |> sync_scope_prefix()
             |> put_flash(:info, "Workspace created")
             |> rescope_dataset_for_project(project)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, create_error(changeset, "workspace"))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Sign in to create a workspace")}
    end
  end

  def handle_event("create-workspace", _params, socket), do: {:noreply, socket}

  # Create a project (+ its production dataset) under the CURRENT workspace,
  # then switch to it (current_project + the new dataset). The workspace stays;
  # the dataset cascade re-scopes via push_patch. Same token gate + error
  # surfacing as create-workspace. No-op when there is no current workspace.
  def handle_event("create-project", %{"name" => name}, socket) do
    ws = socket.assigns[:current_workspace]

    cond do
      not match?(%Barkpark.Auth.ApiToken{}, socket.assigns[:api_token]) ->
        {:noreply, put_flash(socket, :error, "Sign in to create a project")}

      is_nil(ws) ->
        {:noreply, socket}

      true ->
        case Tenancy.create_project_with_dataset(ws, %{name: name}) do
          {:ok, created} ->
            # Re-fetch the just-created project from the DB rather than trusting
            # the transaction's %Project{} (no :datasets assoc loaded) — same
            # divergence as create-workspace (barkpark-6z0e). Unlike a workspace
            # create, the target is the NEW project (not the workspace default),
            # so re-derive by id, not via initial_project/1. The DB-backed struct
            # matches the membership-joined switcher list, so the optimistic
            # current_project assign can't diverge for a render cycle.
            project = Tenancy.get_project_by_id(created.id) || created

            {:noreply,
             socket
             |> assign(create_open: nil, current_project: project)
             # P2 prefix sync — see the create-workspace handler above.
             |> sync_scope_prefix()
             |> put_flash(:info, "Project created")
             |> rescope_dataset_for_project(project)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, create_error(changeset, "project"))}
        end
    end
  end

  def handle_event("create-project", _params, socket), do: {:noreply, socket}

  def handle_event("expand-pane", %{"idx" => idx_str}, socket) do
    # "Expand" a collapsed pane = truncate the nav path so this pane
    # becomes the active focus. Deeper drill-down (and the editor) drop
    # away, matching Sanity's breadcrumb-jump behavior.
    idx = String.to_integer(idx_str)
    new_path = Enum.take(socket.assigns.nav_path, idx)
    {:noreply, push_patch(socket, to: studio_path(socket, new_path, socket.assigns.dataset))}
  end

  def handle_event("new-document", %{"type" => type}, socket) do
    id = "#{type}-#{:rand.uniform(999_999)}"

    case Content.create_document(
           type,
           %{"doc_id" => id, "title" => "Untitled", "content" => seed_new_doc_content(type)},
           socket.assigns.dataset,
           hook_opts(socket)
         ) do
      {:ok, doc} ->
        # The + button lives on the doc-list pane (a :document_type_list
        # node that carries type_name). We just append the new doc's
        # published id to the current nav path — this keeps any parent
        # filter view (e.g. "post/post-all") intact so walk_path can
        # resolve the editor. The old take_while logic dropped the
        # filter segment and produced a dead /post/<id> URL.
        pub_id = Content.published_id(doc.doc_id)
        new_path = socket.assigns.nav_path ++ [pub_id]
        {:noreply, push_patch(socket, to: studio_path(socket, new_path, socket.assigns.dataset))}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Create cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  def handle_event("save", %{"doc" => params}, socket) do
    socket = do_autosave(socket, params)

    case socket.assigns[:save_status] do
      "Saved" -> {:noreply, socket |> put_flash(:info, "Saved") |> rebuild_panes()}
      _ -> {:noreply, socket}
    end
  end

  # Slug-field Generate button (FieldInputs slug clause): derive the slug
  # from the document's current title — the live form value when the user
  # has typed one, else the stored doc title — and write it through the
  # normal autosave path, so it persists + lands in editor_form like a
  # typed value. No title → no-op (nothing to derive from).
  def handle_event("slug-generate", %{"field" => field}, socket) do
    title =
      case Map.get(socket.assigns[:editor_form] || %{}, "title") do
        t when is_binary(t) and t != "" -> t
        _ -> socket.assigns[:editor_doc] && socket.assigns.editor_doc.title
      end

    case title do
      t when is_binary(t) and t != "" ->
        {:noreply, do_autosave(socket, %{field => Barkpark.Tenancy.slugify(t)})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("autosave", %{"doc" => params}, socket) do
    {:noreply, do_autosave(socket, params)}
  end

  # Toggle the content preview side-pane (Goal barkpark-G1, task s3).
  # Doc-type-agnostic — the button itself only renders when a plugin
  # contributed iodata for the open doc, so a stray event just flips a
  # hidden assign.
  def handle_event("toggle-content-preview", _, socket) do
    {:noreply, assign(socket, content_preview_visible: !socket.assigns.content_preview_visible)}
  end

  # Toggle the draft-vs-published diff view (Task barkpark-uix). The
  # button itself is rendered only when both a draft AND a published
  # twin exist (see studio_components.studio_editor_shell), so a stray
  # event when nothing is loaded just flips a hidden assign.
  def handle_event("toggle-diff", _, socket) do
    {:noreply, assign(socket, diff_visible: !socket.assigns.diff_visible)}
  end

  # Per-document Classic <-> Beta toggle (Exp-P3.2). Pure assign flip over the
  # SAME content["blocks"] both views read — Classic renders the schema form,
  # Beta renders the premium block editor. Flipping NEVER mutates the block
  # list (no conversion); it just re-projects through the current view. The
  # `mode` param ("classic"|"beta") is explicit so the two buttons are idempotent
  # (clicking Classic while already Classic is a no-op). Gated on a Beta-eligible
  # document; a stray event when ineligible just keeps Classic.
  def handle_event("editor-set-mode", %{"mode" => mode}, socket) do
    next =
      case mode do
        "beta" -> if beta_editable?(socket), do: :beta, else: :classic
        _ -> :classic
      end

    # Entering Beta reads the freshest block list off the editor doc so an edit
    # made via the Classic form before the flip is reflected. The blocks already
    # live on editor_blocks (kept fresh by rebuild_panes); resync defensively in
    # case the form path mutated content without a rebuild.
    socket =
      if next == :beta, do: sync_editor_blocks(socket), else: socket

    {:noreply, assign(socket, editor_mode: next)}
  end

  def handle_event("autosave", _params, socket) do
    {:noreply, socket}
  end

  # ── ArrayField reorder / add / remove events ───────────────────────────────
  #
  # ArrayField buttons (`+ Add`, `▲`, `▼`, `×`) all fire phx-click="array_op"
  # with phx-value-action ∈ {add_row, remove_row, move_up, move_down},
  # phx-value-field, and (for non-add ops) phx-value-index. This handler is
  # the bridge from those clicks into the public list helpers in
  # `BarkparkWeb.Components.Fields.ArrayField`, then autosaves the document
  # so the new structure lands in the DB.
  def handle_event("array_op", %{"action" => action} = params, socket) do
    path = parse_path(params["path"] || "")

    # path = [] means either path missing or path was just "doc[...]" with no
    # inner — fall back to flat field-name lookup so the original top-level
    # array op contract still works.
    {field, key_path} =
      case path do
        [] ->
          case params["field"] do
            name when is_binary(name) -> {find_field(socket, name), [name]}
            _ -> {nil, []}
          end

        _ ->
          {find_field_by_path(socket, path), path}
      end

    if is_nil(field) or key_path == [] do
      {:noreply, socket}
    else
      idx = parse_idx(params["index"])
      form = socket.assigns[:editor_form] || %{}
      current = list_value_at(form, key_path)

      new_list =
        case action do
          "add_row" -> ArrayField.add_row(current, empty_for_of(field))
          "remove_row" -> ArrayField.remove_row(current, idx)
          "move_up" -> ArrayField.move_up(current, idx)
          "move_down" -> ArrayField.move_down(current, idx)
          _ -> current
        end

      new_form = put_value_at(form, key_path, new_list)
      # Persist via the same path as autosave so panes + DB + validation all
      # stay in sync. do_autosave/2 assigns editor_form: new_form, so we
      # don't need a separate assign call.
      {:noreply, do_autosave(socket, new_form)}
    end
  end

  # ── Image field events ──────────────────────────────────────────────────────

  def handle_event("open-image-picker", %{"field" => field_name}, socket) do
    files =
      Media.list_files(
        socket.assigns.dataset,
        [mime_type: "image/"] ++ ScopeHelpers.scope_opts(socket)
      )

    {:noreply, assign(socket, image_picker_field: field_name, media_files: files)}
  end

  def handle_event("close-image-picker", _, socket) do
    {:noreply, assign(socket, image_picker_field: nil, media_files: [])}
  end

  def handle_event("select-media", %{"url" => url, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, url)
    socket = assign(socket, editor_form: form, image_picker_field: nil, media_files: [])
    # Trigger autosave with updated form
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def handle_event("clear-image", %{"field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, "")
    socket = assign(socket, editor_form: form)
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def handle_event("validate-upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload-image", %{"field" => field_name}, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        plug_upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        # Scope stamp (tsk-url-p0): without scope_opts the blob row landed
        # with NULL workspace/project — invisible to every scoped read.
        case Media.upload(plug_upload, socket.assigns.dataset, ScopeHelpers.scope_opts(socket)) do
          {:ok, file} -> {:ok, "/media/files/#{file.path}"}
          {:error, _} -> {:error, "upload failed"}
        end
      end)

    case uploaded_files do
      [url | _] ->
        form = Map.put(socket.assigns.editor_form, field_name, url)
        socket = assign(socket, editor_form: form, image_picker_field: nil, media_files: [])
        send(self(), {:autosave_form, form})
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Reference field events ─────────────────────────────────────────────────

  def handle_event("open-ref-picker", %{"field" => field_name, "ref-type" => ref_type}, socket) do
    docs =
      Content.list_documents(
        ref_type,
        socket.assigns.dataset,
        [perspective: :drafts] ++ ScopeHelpers.scope_opts(socket)
      )

    candidates =
      Enum.map(docs, fn doc ->
        %{id: Content.published_id(doc.doc_id), title: doc.title || "Untitled"}
      end)

    {:noreply,
     assign(socket, ref_picker_field: field_name, ref_candidates: candidates, ref_search: "")}
  end

  def handle_event("close-ref-picker", _, socket) do
    {:noreply, assign(socket, ref_picker_field: nil, ref_candidates: [], ref_search: "")}
  end

  def handle_event("ref-search", %{"value" => query}, socket) do
    {:noreply, assign(socket, ref_search: query)}
  end

  def handle_event("select-ref", %{"id" => ref_id, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, ref_id)

    socket =
      assign(socket, editor_form: form, ref_picker_field: nil, ref_candidates: [], ref_search: "")

    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  # ── History events ──────────────────────────────────────────────────────────

  def handle_event("show-history", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      revisions =
        Content.list_revisions(
          doc.doc_id,
          type,
          socket.assigns.dataset,
          [limit: 30] ++ ScopeHelpers.scope_opts(socket)
        )

      {:noreply, assign(socket, show_history: true, revisions: revisions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-history", _, socket) do
    {:noreply, assign(socket, show_history: false, revisions: [])}
  end

  # ── Delete with reference check ─────────────────────────────────────────────

  def handle_event("delete-doc", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      refs =
        Content.find_referencing_docs(
          doc.doc_id,
          socket.assigns.dataset,
          ScopeHelpers.scope_opts(socket)
        )

      {:noreply, assign(socket, show_delete: true, delete_refs: refs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-delete", _, socket) do
    {:noreply, assign(socket, show_delete: false, delete_refs: [])}
  end

  def handle_event("confirm-delete", params, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      if params["disconnect"] == "true" do
        Content.disconnect_references(
          doc.doc_id,
          socket.assigns.dataset,
          ScopeHelpers.scope_opts(socket)
        )
      end

      case Content.delete_document(doc.doc_id, type, socket.assigns.dataset, hook_opts(socket)) do
        {:error, {:halted, reason}} ->
          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> put_flash(:error, "Delete cancelled: #{reason}")}

        _ ->
          new_path = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)

          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> push_patch(to: studio_path(socket, new_path, socket.assigns.dataset))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Discard draft ────────────────────────────────────────────────────────────
  # Visible ONLY when the editor is on a draft that has a published twin.
  # `discard-draft`  → opens the confirmation modal.
  # `close-discard`  → cancels without change.
  # `confirm-discard` → calls Content.discard_draft/3, then navigates to the
  #                    published doc so the editor stays open and useful.

  def handle_event("discard-draft", _, socket) do
    doc = socket.assigns[:editor_doc]
    is_draft = socket.assigns[:editor_is_draft] == true
    has_published = socket.assigns[:editor_has_published] == true

    if doc && is_draft && has_published do
      {:noreply, assign(socket, show_discard: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-discard", _, socket) do
    {:noreply, assign(socket, show_discard: false)}
  end

  def handle_event("confirm-discard", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    is_draft = socket.assigns[:editor_is_draft] == true
    has_published = socket.assigns[:editor_has_published] == true

    if doc && type && is_draft && has_published do
      pub_id = Content.published_id(doc.doc_id)

      case Content.discard_draft(pub_id, type, socket.assigns.dataset, hook_opts(socket)) do
        {:ok, _} ->
          # Navigate to the published twin so the editor stays open.
          base = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          new_path = base ++ [pub_id]

          {:noreply,
           socket
           |> assign(show_discard: false)
           |> put_flash(:info, "Draft discarded")
           |> push_patch(to: studio_path(socket, new_path, socket.assigns.dataset))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(show_discard: false)
           |> put_flash(:error, "Failed to discard draft")}
      end
    else
      {:noreply, assign(socket, show_discard: false)}
    end
  end

  # ── Profile edit events ──────────────────────────────────────────────────────

  def handle_event("show-profile", _, socket) do
    {:noreply, assign(socket, show_profile: true)}
  end

  def handle_event("close-profile", _, socket) do
    {:noreply, assign(socket, show_profile: false)}
  end

  # ── Network shares panel (scoped-sharing P6) ─────────────────────────────
  # Every mutate handler RE-CHECKS admin server-side via shares_admin?/1.
  # StudioLive mounts in :studio_public (token may be nil / non-admin), and the
  # panel calls Barkpark.Sharing.* in-process — bypassing the /v1/shares
  # :require_admin gate — so this is the real authorization boundary, not the
  # hidden top-bar button.

  def handle_event("shares-open", params, socket) do
    if socket.assigns[:shares_admin?] do
      surfaces = List.wrap(params["surface"]) |> Enum.filter(&(&1 in ~w(papers docs media)))

      {:noreply,
       socket
       |> assign(
         show_shares: true,
         shares_error: nil,
         shares_rows: load_share_rows(),
         shares_scope_prefill: shares_scope_prefill(socket),
         shares_prefill_surfaces: surfaces
       )}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  def handle_event("shares-close", _params, socket) do
    {:noreply, assign(socket, show_shares: false, shares_error: nil)}
  end

  def handle_event("shares-add", params, socket) do
    if socket.assigns[:shares_admin?] do
      scope = params["scope"] |> to_string() |> String.trim()
      surfaces = params["surfaces"] |> List.wrap() |> Enum.join(",")

      cond do
        scope == "" ->
          {:noreply, assign(socket, shares_error: "Scope is required.")}

        surfaces == "" ->
          {:noreply, assign(socket, shares_error: "Pick at least one surface.")}

        true ->
          # access is pinned to read until the edit path (P5) lands.
          case Barkpark.Sharing.add_share("#{scope}:#{surfaces}:read") do
            {:ok, _share} ->
              {:noreply,
               socket
               |> assign(shares_rows: load_share_rows(), shares_error: nil)
               |> put_flash(:info, "Shared #{scope}.")}

            {:error, _reason} ->
              {:noreply,
               assign(socket,
                 shares_error: "Invalid share — check the scope and surfaces."
               )}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  def handle_event("shares-remove", %{"scope" => scope}, socket) do
    if socket.assigns[:shares_admin?] do
      case Barkpark.Sharing.scope_triple(scope) do
        {:ok, {ws, proj, dataset}} ->
          {:ok, _count} = Barkpark.Sharing.remove_share(ws, proj, dataset)

          {:noreply,
           socket
           |> assign(shares_rows: load_share_rows(), shares_error: nil)
           |> put_flash(:info, "Stopped sharing #{ws}/#{proj}/#{dataset}.")}

        {:error, _} ->
          {:noreply, assign(socket, shares_error: "Could not parse that scope.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Admin access required to manage shares.")}
    end
  end

  # ── Item (per-document) share popover (P7) ───────────────────────────────
  # Google-Docs-style direct links to ONE open paper/doc, minted via
  # Barkpark.Sharing.Links. Same admin gate as the section panel — re-checked
  # in every handler, never trusting the (hidden-for-non-admins) button.

  def handle_event("item-share-open", %{"kind" => kind} = params, socket) do
    if socket.assigns[:shares_admin?] do
      # phx-value-ref-type / phx-value-ref-id arrive DASH-keyed — Phoenix keeps
      # the attribute suffix verbatim (the existing "doc-id" handler is the same).
      ref_id = params["ref-id"] |> to_string() |> String.replace_prefix("drafts.", "")

      item = %{
        kind: kind,
        ref_type: params["ref-type"],
        # read links resolve the PUBLISHED id — strip a drafts. prefix.
        ref_id: ref_id,
        title: params["title"] || ref_id
      }

      {:noreply,
       assign(socket,
         item_share_open: true,
         item_share: item,
         item_share_error: nil,
         item_share_links: load_item_links(socket, item)
       )}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to share items.")}
    end
  end

  def handle_event("item-share-close", _params, socket) do
    {:noreply, assign(socket, item_share_open: false, item_share_error: nil)}
  end

  def handle_event("item-share-create", %{"access" => access}, socket) do
    item = socket.assigns[:item_share]

    cond do
      not socket.assigns[:shares_admin?] ->
        {:noreply, put_flash(socket, :error, "Admin access required to share items.")}

      is_nil(item) or is_nil(socket.assigns[:current_workspace]) ->
        {:noreply, assign(socket, item_share_error: "No item / workspace in context.")}

      true ->
        case Barkpark.Sharing.Links.create(item_link_attrs(socket, item, access)) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               item_share_links: load_item_links(socket, item),
               item_share_error: nil
             )}

          {:error, _} ->
            {:noreply, assign(socket, item_share_error: "Could not create the link.")}
        end
    end
  end

  def handle_event("item-share-revoke", %{"id" => id}, socket) do
    if socket.assigns[:shares_admin?] do
      Barkpark.Sharing.Links.revoke(id)

      {:noreply,
       assign(socket, item_share_links: load_item_links(socket, socket.assigns[:item_share]))}
    else
      {:noreply, put_flash(socket, :error, "Admin access required to share items.")}
    end
  end

  def handle_event("jump-to-user", %{"type" => type, "doc-id" => doc_id}, socket) do
    # Build the path to that document — need to find it in the structure
    structure = Structure.build(socket.assigns.dataset)
    path = PaneBuilder.find_doc_path(structure, type, doc_id)
    {:noreply, push_patch(socket, to: studio_path(socket, path, socket.assigns.dataset))}
  end

  def handle_event("preview-profile", %{"name" => name, "color" => color}, socket) do
    {:noreply, assign(socket, user_name: name, user_color: color)}
  end

  def handle_event("save-profile", %{"name" => name, "color" => color}, socket) do
    socket = assign(socket, user_name: name, user_color: color, show_profile: false)
    # Save to client localStorage via JS hook
    socket = push_event(socket, "save-identity", %{name: name, color: color})
    # Update presence with new identity
    {:noreply, track_presence(socket)}
  end

  def handle_event("restore-revision", %{"id" => rev_id}, socket) do
    type = socket.assigns[:editor_type]

    case Content.restore_revision(rev_id, type, socket.assigns.dataset, hook_opts(socket)) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> assign(show_history: false, revisions: [])
         |> put_flash(:info, "Restored from history")
         |> rebuild_panes()}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Restore cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore")}
    end
  end

  def handle_event("clear-ref", %{"field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, "")
    socket = assign(socket, editor_form: form)
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def handle_event("publish", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      content = Content.build_content(socket.assigns.editor_form, socket.assigns[:editor_schema])
      title = Map.get(socket.assigns.editor_form, "title", doc.title)

      case Content.validate_document(type, title, content, socket.assigns.dataset) do
        {:error, errs} ->
          {:noreply,
           socket
           |> assign(validation_errors: errs)
           |> put_flash(:error, "Fix validation errors before publishing")}

        _ ->
          opts = hook_opts(socket)

          do_action(
            socket,
            fn d, t ->
              Content.publish_document(
                Content.published_id(d.doc_id),
                t,
                socket.assigns.dataset,
                opts
              )
            end,
            "Published"
          )
      end
    else
      {:noreply, socket}
    end
  end

  # ── Unpublish with blast-radius guard (gap #5) ──────────────────────────────
  #
  # Unpublishing a published doc removes it from the published graph — every
  # doc that references it would then dangle. The PROBE phase queries
  # `Content.Graph.reverse_referencers/2` (the arrayOf-aware inbound-edge query
  # over `content_edges`, materialised in Phase 2) — NOT the scalar-only
  # `Content.find_referencing_docs/3`, which UNDERCOUNTS arrayOf references like
  # `task.attachments` (the exact blast-radius bug this feature targets). When
  # there are referencers, the modal lists them and the real unpublish is
  # deferred to `confirm-unpublish`; with none, the unpublish proceeds inline.
  #
  # Mirrors the delete guard at handle_event("delete-doc"/"confirm-delete").
  def handle_event("unpublish", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      published_id = Content.published_id(doc.doc_id)

      refs =
        Content.Graph.reverse_referencers(
          published_id,
          [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)
        )

      if refs == [] do
        do_unpublish(socket)
      else
        {:noreply, assign(socket, show_unpublish_guard: true, unpublish_refs: refs)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-unpublish-guard", _, socket) do
    {:noreply, assign(socket, show_unpublish_guard: false, unpublish_refs: [])}
  end

  # The confirm phase — the editor acknowledged the blast radius. Optionally
  # disconnect the inbound references first (mirroring confirm-delete's
  # `disconnect` branch), then run the real Content.unpublish_document.
  def handle_event("confirm-unpublish", params, socket) do
    doc = socket.assigns[:editor_doc]

    if doc && socket.assigns[:editor_type] do
      socket =
        if params["disconnect"] == "true" do
          Content.disconnect_references(
            doc.doc_id,
            socket.assigns.dataset,
            ScopeHelpers.scope_opts(socket)
          )

          socket
        else
          socket
        end

      socket
      |> assign(show_unpublish_guard: false, unpublish_refs: [])
      |> do_unpublish()
    else
      {:noreply, assign(socket, show_unpublish_guard: false, unpublish_refs: [])}
    end
  end

  # ── E1. Duplicate ──────────────────────────────────────────────────────────
  # Clone the editor's currently-loaded doc into a fresh draft and patch
  # the nav path to land on it. The duplicate's published id replaces
  # the tail of nav_path so the editor pane reuses the same list pane.
  def handle_event("duplicate-doc", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.clone_document(doc, type, socket.assigns.dataset, hook_opts(socket)) do
        {:ok, new_doc} ->
          pub_id = Content.published_id(new_doc.doc_id)
          base = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          new_path = base ++ [pub_id]

          {:noreply,
           socket
           |> put_flash(:info, "Duplicated as #{pub_id}")
           |> push_patch(to: studio_path(socket, new_path, socket.assigns.dataset))}

        {:error, {:halted, reason}} ->
          {:noreply, put_flash(socket, :error, "Duplicate cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to duplicate")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── E2. Open in new pane (read-only secondary editor) ──────────────────────
  # Picker opens a doc-search modal scoped to the editor_type. Selecting
  # an entry assigns secondary_doc and renders a read-only card next to
  # the primary editor. v1 is read-only — primary autosave still wins;
  # simultaneous-edit is a deliberate follow-up.
  def handle_event("open-secondary-picker", _, socket) do
    type = socket.assigns[:editor_type]

    candidates =
      if type do
        type
        |> Content.list_documents(
          socket.assigns.dataset,
          [perspective: :drafts] ++ ScopeHelpers.scope_opts(socket)
        )
        |> Enum.map(fn d ->
          pub = Content.published_id(d.doc_id)
          %{id: pub, title: d.title || "Untitled", type: type}
        end)
        |> Enum.reject(fn c ->
          socket.assigns[:editor_doc] &&
            c.id == Content.published_id(socket.assigns.editor_doc.doc_id)
        end)
      else
        []
      end

    {:noreply,
     assign(socket,
       show_secondary_picker: true,
       secondary_search: "",
       secondary_candidates: candidates
     )}
  end

  # 'View blast radius' — open the Cytoscape graph pane for the currently-open
  # doc (Goal ges/graph-edge-seam, FIX 2). push_patch to the reserved
  # `graph/<doc_id>` nav segment, which PaneBuilder resolves (type-agnostically)
  # into a `view: :graph` editor. Published id so the path is publish-stable.
  # No-op when no doc is open (the action only renders with an editor_doc).
  def handle_event("view-graph", _, socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: doc_id} when is_binary(doc_id) ->
        pub_id = Content.published_id(doc_id)
        path = ["graph", pub_id]
        {:noreply, push_patch(socket, to: studio_path(socket, path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close-secondary-picker", _, socket) do
    {:noreply, assign(socket, show_secondary_picker: false, secondary_search: "")}
  end

  def handle_event("secondary-search", %{"value" => q}, socket) do
    {:noreply, assign(socket, secondary_search: q)}
  end

  def handle_event("select-secondary", %{"id" => doc_id}, socket) do
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.fetch_doc_with_draft(type, doc_id, dataset, ScopeHelpers.scope_opts(socket)) do
      {nil, _, _} ->
        {:noreply, put_flash(socket, :error, "Document not found")}

      {doc, _, _} ->
        schema =
          case Content.get_schema(type, dataset) do
            {:ok, s} -> s
            _ -> nil
          end

        {:noreply,
         assign(socket,
           secondary_doc: doc,
           secondary_schema: schema,
           secondary_type: type,
           show_secondary_picker: false,
           secondary_search: ""
         )}
    end
  end

  def handle_event("close-secondary", _, socket) do
    {:noreply, assign(socket, secondary_doc: nil, secondary_schema: nil, secondary_type: nil)}
  end

  # ── E3. Bulk publish (list pane multi-select) ──────────────────────────────
  # Checkboxes on each :doc list item toggle a MapSet of published ids.
  # The floating action bar appears when the set is non-empty and runs
  # the action over every selected id. Cross-pane selection isn't
  # gated — the active list pane is the only one rendering :doc rows.
  def handle_event("toggle-doc-checkbox", %{"id" => id}, socket) do
    current = socket.assigns.selected_doc_ids

    new =
      if MapSet.member?(current, id),
        do: MapSet.delete(current, id),
        else: MapSet.put(current, id)

    {:noreply, assign(socket, selected_doc_ids: new)}
  end

  def handle_event("bulk-clear", _, socket) do
    {:noreply, assign(socket, selected_doc_ids: MapSet.new())}
  end

  def handle_event("bulk-publish", _, socket) do
    {:noreply, bulk_action(socket, :publish)}
  end

  # GAP (Phase 5, documented loudly per the brief): bulk-unpublish is NOT
  # blast-radius-guarded. The single-doc unpublish above probes
  # Content.Graph.reverse_referencers/2 before unpublishing; bulk-unpublish
  # runs straight through bulk_action/2 with NO reverse-reference probe. A
  # bulk unpublish can therefore silently strand arrayOf referencers (e.g.
  # task.attachments) — the exact bug the single-doc guard targets. Guarding
  # bulk requires running reverse_referencers/2 per selected id and surfacing
  # an aggregate modal; deferred as a follow-up. Do NOT assume bulk is safe
  # because single is guarded.
  def handle_event("bulk-unpublish", _, socket) do
    {:noreply, bulk_action(socket, :unpublish)}
  end

  # ── Schema-declared document actions (Task #16 — action registry) ──────────
  #
  # Schemas advertise document-level actions via the `:actions` array on the
  # SchemaDefinition row. The editor pane renders a button per action; clicking
  # a `kind: "modal"` action lands here. The generic ConfirmModal opens with
  # the action's metadata; dry-run and real confirmations route through
  # `confirm-modal-dryrun` / `confirm-modal-real` below, each of which
  # dispatches into the plugin-owned action handler resolved via
  # `Plugins.Registry.collect_action_handlers/1`. `kind: "link"`
  # actions never hit this handler — they're rendered as anchor tags by
  # `StudioComponents.doc_action_button/1`, so a click is a plain HTTP
  # navigation.
  def handle_event("schema_action", %{"name" => name}, socket) do
    # Resolve the post-plugin doc-actions list and look the action up there
    # — a plugin's `resolve_doc_actions/2` may have rewritten or dropped it
    # since the button was rendered. If the action no longer exists in the
    # resolved list (e.g. a plugin filtered it out between render and click),
    # fall back to a no-op flash.
    action = DocActions.find_resolved_doc_action(socket, name)

    case action do
      %{"kind" => "modal"} = a ->
        {:noreply,
         assign(socket,
           confirm_modal: %{
             action: a,
             stage: "initial",
             doc_id: DocActions.doc_id_for_action(socket),
             dataset: socket.assigns[:dataset],
             preview: nil
           }
         )}

      _ ->
        {:noreply, put_flash(socket, :info, "Action #{name} not yet wired")}
    end
  end

  def handle_event("close-confirm-modal", _, socket) do
    {:noreply, assign(socket, confirm_modal: nil)}
  end

  # Dry-run confirmation — dispatch to the plugin action with `:dryrun`,
  # surface the preview in the modal without closing it. Errors are
  # rendered as a preview slice tagged `:error` so the user can fix and
  # retry without leaving the modal.
  def handle_event("confirm-modal-dryrun", _, socket) do
    case socket.assigns[:confirm_modal] do
      %{action: %{"name" => name}, doc_id: doc_id, dataset: dataset} = modal
      when is_binary(doc_id) and is_binary(dataset) ->
        result = DocActions.dispatch_action(socket, name, doc_id, dataset, :dryrun)
        preview = DocActions.preview_from_result(result)

        {:noreply,
         assign(socket, confirm_modal: Map.merge(modal, %{stage: "dryrun", preview: preview}))}

      _ ->
        {:noreply, socket}
    end
  end

  # Real confirmation — dispatch with `:real`, close the modal, flash the
  # outcome. On success we also rebuild panes so any pill / status that
  # reads from the document picks up the freshly-written `pending` marker.
  def handle_event("confirm-modal-real", _, socket) do
    case socket.assigns[:confirm_modal] do
      %{action: %{"name" => name}, doc_id: doc_id, dataset: dataset}
      when is_binary(doc_id) and is_binary(dataset) ->
        case DocActions.dispatch_action(socket, name, doc_id, dataset, :real) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:info, "#{name} enqueued")
             |> rebuild_panes()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:error, "#{name} failed: #{DocActions.format_action_error(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── In-Studio paper block editor events (convergence/studio-paper-editor) ───
  #
  # Every editing event below maps a form/button action to exactly ONE
  # DocPatchOp and routes it through `Content.apply_paper_block_op/3`. The op
  # pipeline renders the fragment, persists blocks + body_html, bumps the
  # streaming rev, and broadcasts a `{:paper_block,…}` delta — which the
  # existing stream handler applies with no remount. We NEVER write the DB
  # directly here and NEVER rebuild_panes (that would remount the view).
  #
  # patch.ex / render.ex are untouched; only the op maps we build vary.

  # View ⇄ Edit toggle. View is the read-only live stream; Edit renders the
  # per-block controls. Pure assign flip — no remount.
  #
  # Entering Edit tears the streamed `<article phx-update="stream">` container
  # out of the DOM (the editor branch renders instead). A LiveView stream is a
  # write-only changelog with no server-side snapshot, so once that container
  # is destroyed there is nothing to re-emit when it returns. Flipping the
  # assign back alone would re-render an EMPTY stream container — the View pane
  # would show zero blocks. So on the View transition we re-populate
  # `:paper_blocks` from the current `paper_doc` blocks (the source of truth,
  # kept fresh by `sync_paper_edit_doc/1` after every edit), reusing the same
  # `paper_stream_items/1` path the initial mount uses. `reset: true` discards
  # any stale client state so the View shows exactly the current blocks,
  # including edits made while in Edit mode. Still a pure stream/assign update
  # — no remount, no rebuild_panes.
  def handle_event("paper-toggle-edit", _params, socket) do
    if socket.assigns[:editor_view] == :paper do
      next_edit_mode = !socket.assigns[:paper_edit_mode]

      socket = assign(socket, paper_edit_mode: next_edit_mode)

      socket =
        if next_edit_mode or not socket.assigns[:paper_block_mode] do
          socket
        else
          # Switching back to View on a block-backed paper: rehydrate the stream.
          stream(
            socket,
            :paper_blocks,
            paper_stream_items(
              paper_top_level_blocks(socket),
              socket.assigns.dataset,
              ScopeHelpers.scope_opts(socket)
            ),
            reset: true
          )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Edit a block's textual field(s) → patch-block with only the changed
  # field(s). Inline content (paragraph/callout) is plain text in the MVP:
  # the textarea value is wrapped as a single text inline node, which DROPS
  # any pre-existing inline marks (bold/italic/link) on that block — an
  # accepted MVP tradeoff (marks/slash-menu/drag-drop are deferred).
  def handle_event("paper-edit-block", %{"block_id" => id} = params, socket) do
    block = paper_block_by_id(socket, id)
    patch = Blocks.build_block_patch(block, params)
    {:noreply, paper_op(socket, %{"op" => "patch-block", "id" => id, "patch" => patch})}
  end

  # Continuous (debounced) autosave for the form-based per-block editors
  # (callout/code/eyebrow/byline/ingress/pullquote/section/diagram). The shared
  # `<form>` carries `phx-change="paper-block-autosave"` + `phx-debounce="500"`,
  # so every keystroke (after the 500ms idle) persists WITHOUT the explicit Save
  # button — the Save button (`paper-edit-block`) stays as a no-harm fallback.
  #
  # This mirrors `paper-edit-block`'s apply: resolve the block, build the same
  # patch, route the same `patch-block` op through the SAME `paper_op/2`
  # pipeline. The ONLY difference is the affordance — autosave is QUIET: it sets
  # the "✓ Auto-saved" status and never raises the "Saved" flash nor the
  # save-cancelled/failed semantics of the explicit path. An unknown/missing
  # block resolves to nil → `build_block_patch(nil, …)` yields `%{}` (no-op
  # patch) → never crashes.
  def handle_event("paper-block-autosave", %{"block_id" => id} = params, socket) do
    block = paper_block_by_id(socket, id)
    patch = Blocks.build_block_patch(block, params)

    socket =
      socket
      |> paper_op(%{"op" => "patch-block", "id" => id, "patch" => patch})
      |> assign(save_status: "Auto-saved")

    {:noreply, socket}
  end

  # Guard: a change event without a block_id (shouldn't happen — the hidden
  # input always rides along — but defends against a stale/partial form) → no-op.
  def handle_event("paper-block-autosave", _params, socket), do: {:noreply, socket}

  # Op forwarded by the <bp-paper-editor> Web Component via the
  # BarkparkPaperEditor JS hook. The WC owns the editing UX (debounced rich
  # text) and emits a portable-doc op verbatim; we route it through the same
  # canonical `paper_op/2` pipeline the form-based handlers use. The op arrives
  # JSON-decoded with string keys: %{"op"=>"patch-block","id"=>_,"patch"=>%{}}.
  # The server owns the model — `paper_op/2` applies, persists, broadcasts the
  # `{:paper_block,…}` delta, and re-syncs `paper_doc`. No echo to the WC.
  def handle_event("paper-op", %{"op" => _} = op, socket) do
    {:noreply, paper_op(socket, op)}
  end

  # Add a block. Default `insert-after` the focused block; `append-block` when
  # no anchor (empty doc or top-level add). A fresh immutable id is generated.
  def handle_event("paper-add-block", %{"block-type" => type} = params, socket) do
    new = Blocks.default_block(type, Blocks.new_block_id())

    op =
      case params["after-id"] do
        after_id when is_binary(after_id) and after_id != "" ->
          %{"op" => "insert-after", "afterId" => after_id, "block" => new}

        _ ->
          %{"op" => "append-block", "block" => new}
      end

    {:noreply, paper_op(socket, op)}
  end

  # Slash-menu insert (P3.3 + EX2). The <bp-paper-editor> WC emits a
  # `bp-slash-insert` CustomEvent {type, afterId} — and, for an EXPECTED-group
  # pick, {type, fieldName, afterId} — when the user chooses from the "/" popup;
  # the BarkparkPaperEditor hook forwards it here. We build the block with the
  # SAME default_block/2 + new_block_id/0 the add-block path uses and apply an
  # `insert-after` op through the SAME paper_op/2 pipeline — no duplicated
  # block-creation logic. A blank/empty afterId falls back to append-block.
  #
  # When a `fieldName` is present (an EXPECTED-group pick) the new block is
  # BOUND: `default_block/2` plus `"fieldName" => fname`. Before inserting, the
  # hard cap is enforced server-side as a safety net — `expected_field_blocked?/3`
  # defends against a stale menu / a race where a capped+enforced field gets
  # offered. A blocked insert is a no-op with a gentle flash. Generic picks
  # (no fieldName) behave exactly as before.
  def handle_event(
        "paper-slash-insert",
        %{"type" => type, "fieldName" => fname} = params,
        socket
      )
      when is_binary(fname) and fname != "" do
    if expected_field_blocked?(socket, fname) do
      {:noreply, put_flash(socket, :error, "That field is already at its limit.")}
    else
      new = Map.put(Blocks.default_block(type, Blocks.new_block_id()), "fieldName", fname)
      {:noreply, paper_op(socket, slash_insert_op(params["afterId"], new))}
    end
  end

  def handle_event("paper-slash-insert", %{"type" => type} = params, socket) do
    new = Blocks.default_block(type, Blocks.new_block_id())
    {:noreply, paper_op(socket, slash_insert_op(params["afterId"], new))}
  end

  # Delete a block → remove-block by id.
  def handle_event("paper-delete-block", %{"id" => id}, socket) do
    {:noreply, paper_op(socket, %{"op" => "remove-block", "id" => id})}
  end

  # Reorder a top-level block one slot up/down. Maps to ONE `move-block` op —
  # a pure permutation, one DB write, one broadcast, one stream delta. The
  # block keeps its id + content; only its position changes.
  def handle_event("paper-move-block", %{"id" => id, "dir" => dir}, socket) do
    blocks = paper_top_level_blocks(socket)
    idx = Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)

    {:noreply, paper_reorder(socket, blocks, idx, dir)}
  end

  # Drag-handle reorder (enhancement). The BarkparkPaperSortable JS hook fires
  # this on drop with the dragged block id and the id it was dropped after
  # (`after-id` empty ⇒ dropped at the head). It resolves to the SAME
  # `move-block` op the up/down buttons use — one atomic reorder.
  def handle_event("paper-move-block-to", %{"id" => id} = params, socket) do
    after_id =
      case params["after-id"] do
        a when is_binary(a) and a != "" -> a
        _ -> nil
      end

    {:noreply, paper_op(socket, %{"op" => "move-block", "id" => id, "after" => after_id})}
  end

  # ── paper editor helpers ────────────────────────────────────────────────────

  # Apply one op via the canonical pipeline, then refresh the in-memory
  # `paper_doc` so the edit form reflects the new block list. The op's own
  # `{:paper_block}` broadcast already advanced the read-only stream (and any
  # remote viewer); this just keeps THIS pane's edit controls in sync.
  defp paper_op(socket, op) do
    cond do
      # Beta block editor over a non-paper DOCUMENT (Exp-P3.2). The same
      # block editor + the same `paper-*` events drive a post's editing in
      # Beta mode; route the op through the generalized document block-op
      # path so it applies to content["blocks"], re-projects
      # content[fieldName]/content["body"], and persists + broadcasts via
      # upsert_document. No paper_doc / no stream — the form re-reads the
      # refetched blocks.
      socket.assigns[:editor_view] == :form and socket.assigns[:editor_mode] == :beta and
          socket.assigns[:editor_doc] != nil ->
        document_op(socket, op)

      true ->
        paper_pane_op(socket, op)
    end
  end

  # The paper-pane op path (unchanged): applies to the open paper's blocks,
  # streams the delta, re-syncs the in-memory paper_doc.
  defp paper_pane_op(socket, op) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      is_nil(slug) ->
        socket

      true ->
        case Content.apply_paper_block_op(slug, op, dataset) do
          {:ok, _result} ->
            sync_paper_edit_doc(socket)

          {:error, _reason} ->
            put_flash(socket, :error, "Edit failed")
        end
    end
  end

  # The document (post) Beta op path: one DocPatchOp → content["blocks"] →
  # re-project → persist via Content.apply_document_block_op/5, then refetch the
  # doc so editor_doc/editor_blocks/editor_form reflect the persisted state.
  defp document_op(socket, op) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.apply_document_block_op(doc.doc_id, type, op, dataset, hook_opts(socket)) do
      {:ok, _result} ->
        sync_editor_blocks(socket)

      {:error, _reason} ->
        put_flash(socket, :error, "Edit failed")
    end
  end

  # Refetch the open document into editor_doc/editor_blocks/editor_form so all
  # three reflect the latest persisted state after a Beta op (or before entering
  # Beta). Reads the draft-first row, re-derives the Classic form via
  # doc_to_form, and re-resolves the block list — keeping Classic and Beta over
  # the ONE block list. No rebuild_panes (no remount).
  defp sync_editor_blocks(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    with %{doc_id: doc_id} <- doc,
         {:ok, fresh} <-
           Content.get_document(doc_id, type, dataset, ScopeHelpers.scope_opts(socket)) do
      {blocks, synth?} = Content.resolve_blocks_for_edit(fresh, type, dataset)

      assign(socket,
        editor_doc: fresh,
        editor_blocks: blocks,
        editor_blocks_synth?: synth?,
        editor_form: Content.doc_to_form(fresh, socket.assigns[:editor_schema])
      )
    else
      _ -> socket
    end
  end

  # Reorder one slot in the target direction via a single `move-block` op.
  # No-ops at the boundaries (no block / already at head moving up / already at
  # tail moving down).
  defp paper_reorder(socket, _blocks, nil, _dir), do: socket

  # Up: land `moved` directly after the block two slots above it (the block
  # before its current predecessor), or at the head (after: nil) when the
  # predecessor is the head block.
  defp paper_reorder(socket, blocks, idx, "up") when idx > 0 do
    moved = Enum.at(blocks, idx)
    after_id = if idx >= 2, do: Map.get(Enum.at(blocks, idx - 2), "id"), else: nil
    paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => after_id})
  end

  # Down: land `moved` directly after the block currently below it.
  defp paper_reorder(socket, blocks, idx, "down") when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    anchor_id = Map.get(Enum.at(blocks, idx + 1), "id")
    paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => anchor_id})
  end

  defp paper_reorder(socket, _blocks, _idx, _dir), do: socket

  # Re-read the paper from the DB into `paper_doc` (block list = source of
  # truth). Used after a local op and on any delta while in edit mode.
  defp sync_paper_edit_doc(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id

    case slug && Content.get_paper(slug, socket.assigns.dataset) do
      %{} = fresh -> assign(socket, paper_doc: fresh)
      _ -> socket
    end
  end

  # Top-level blocks of the surface the block editor is currently driving — the
  # open paper's blocks in the paper pane, or the open document's resolved
  # `editor_blocks` when the block editor is the document Beta view (Exp-P3.2).
  # The op handlers (paper-edit-block / paper-move-block / …) read through this
  # so the SAME controls drive either surface against the right block list.
  defp paper_top_level_blocks(socket) do
    cond do
      socket.assigns[:editor_view] == :form and socket.assigns[:editor_mode] == :beta and
          is_list(socket.assigns[:editor_blocks]) ->
        socket.assigns[:editor_blocks]

      true ->
        case socket.assigns[:paper_doc] do
          %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
          _ -> []
        end
    end
  end

  # ── EX2 — expectation-aware slash menu (barkpark-0uq8) ──────────────────────

  # An `insert-after` op anchored to a non-blank id, else `append-block`.
  defp slash_insert_op(after_id, block) when is_binary(after_id) and after_id != "",
    do: %{"op" => "insert-after", "afterId" => after_id, "block" => block}

  defp slash_insert_op(_after_id, block),
    do: %{"op" => "append-block", "block" => block}

  # Hard-cap guard for a bound expected-field insert: resolve the active doc's
  # current block list + Expectation and ask Content whether `field_name` is at
  # an ENFORCED cap. Returns false (allow) for any non-Expectation context (no
  # schema in scope ⇒ no enforced caps ⇒ never blocked).
  defp expected_field_blocked?(socket, field_name) do
    case slash_expectation(socket) do
      %{layout: _} = expectation ->
        Content.expected_field_blocked?(
          paper_top_level_blocks(socket),
          expectation,
          field_name
        )

      _ ->
        false
    end
  end

  # The resolved Expectation for the surface the slash menu is driving — the
  # open document's schema in the Beta document view, else nil (the paper pane
  # has no Expectation). Mirrors paper_top_level_blocks/1's surface gate so the
  # block list and the Expectation always describe the SAME document.
  defp slash_expectation(socket) do
    case socket.assigns[:editor_schema] do
      %Barkpark.Content.SchemaDefinition{} = schema -> Content.resolve_expectation(schema)
      _ -> nil
    end
  end

  # The expected fields STILL recommendable for the current Beta block list,
  # rendered into `data-expected-fields` for the slash menu's EXPECTED group.
  # Returns [] when there is no schema/Expectation (no group shown).
  defp beta_expected_fields(%Barkpark.Content.SchemaDefinition{} = schema, blocks)
       when is_list(blocks) do
    Content.available_expected_fields(blocks, Content.resolve_expectation(schema), schema)
  end

  defp beta_expected_fields(_schema, _blocks), do: []

  # Find a block by id anywhere in the tree (recurses sections), so a control
  # nested inside a section still resolves its block.
  defp paper_block_by_id(socket, id) do
    Blocks.find_paper_block(paper_top_level_blocks(socket), id)
  end

  # Single autosave path consumed by handle_event "autosave",
  # handle_event "save", and handle_info :autosave_form. Delegates to
  # Content.upsert_draft/5 (validation + upsert + errors map) and
  # mutates pane titles in-memory to avoid an N+1 DB rebuild on every
  # keystroke.
  defp do_autosave(socket, params) do
    doc = socket.assigns[:editor_doc]
    schema = socket.assigns[:editor_schema]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.upsert_draft(
             doc,
             type,
             schema,
             params,
             socket.assigns.dataset,
             hook_opts(socket)
           ) do
        {:ok, saved_doc, errs} ->
          new_title = Map.get(params, "title", doc.title)

          panes =
            PaneBuilder.update_title(
              socket.assigns.panes,
              Content.published_id(saved_doc.doc_id),
              new_title
            )

          assign(socket,
            panes: panes,
            editor_doc: saved_doc,
            editor_is_draft: Content.draft?(saved_doc.doc_id),
            # Merge over the previous form state instead of replacing it:
            # fields the form does not render an input for (v1
            # "array"/"object" — read-only in FieldInputs) are absent from
            # params, and a plain replace would blank their display until
            # the next full doc_to_form rebuild.
            editor_form: Map.merge(socket.assigns[:editor_form] || %{}, params),
            save_status: "Saved",
            validation_errors: errs,
            cross_violations: compute_cross_violations(schema, params)
          )
          |> maybe_refresh_content_preview()

        {:error, {:halted, reason}} ->
          # `before_save` hook vetoed the autosave (per plan §0 Q4). The
          # editor's form state is untouched; surface the reason in the
          # save_status indicator AND a flash so it can't be missed.
          socket
          |> assign(save_status: "Save cancelled")
          |> put_flash(:error, "Save cancelled: #{reason}")

        {:error, _} ->
          assign(socket, save_status: "Save failed")
      end
    else
      socket
    end
  end

  # Build the keyword list of lifecycle-hook context (`:source`,
  # `:user_id`) that every Content write call site in StudioLive passes
  # through. Centralised so the recursion guard (plan §0 Q5) is set
  # consistently — every Studio-originated write tags itself
  # `source: :studio` and threads the socket's user_id when present.
  defp hook_opts(socket) do
    [source: :studio, user_id: socket.assigns[:user_id]] ++ ScopeHelpers.scope_opts(socket)
  end

  # ── Content preview side-pane (Goal barkpark-G1, task s3) ──────────
  # Doc-type-agnostic recompute. Runs at the end of `do_autosave/2`'s
  # success branch, and again from `rebuild_panes/1` so the preview
  # lands on first-mount (before any input event has fired).
  #
  # First-wins resolver: walks registered plugins via
  # `Plugins.Registry.collect_content_renderer/3` and uses the first
  # `{:ok, iodata}` it gets. When every plugin returns `:skip` (or
  # plugins=[]), `:none` ⇒ assign nil ⇒ pane is absent from the layout.
  # This is the host-side of the s3 refactor — Barkpark itself knows
  # nothing about `"book"` documents or ONIX XML; OnixEdit's plugin
  # module contributes the renderer.
  defp maybe_refresh_content_preview(socket) do
    doc_type = socket.assigns[:editor_type]

    case doc_type do
      type when is_binary(type) and type != "" ->
        content = socket.assigns[:editor_form] || %{}

        ctx = %{
          current_user: socket.assigns[:current_user],
          user_id: socket.assigns[:user_id],
          dataset: socket.assigns[:dataset],
          perspective: socket.assigns[:perspective]
        }

        case Barkpark.Plugins.Registry.collect_content_renderer(type, content, ctx) do
          {:ok, rendered} ->
            assign(socket, content_preview_rendered: rendered)

          :none ->
            assign(socket, content_preview_rendered: nil)
        end

      _ ->
        # No doc / no doc_type → clear any stale preview from a
        # previously-open doc so the pane closes cleanly.
        assign(socket, content_preview_rendered: nil)
    end
  end

  # The shared real-unpublish path used by BOTH the no-referencers fast path and
  # the post-confirm-guard path. Reuses do_action/3's flash + pane-rebuild
  # discipline (Phase 5, gap #5).
  defp do_unpublish(socket) do
    opts = hook_opts(socket)

    do_action(
      socket,
      fn doc, type ->
        Content.unpublish_document(
          Content.published_id(doc.doc_id),
          type,
          socket.assigns.dataset,
          opts
        )
      end,
      "Unpublished"
    )
  end

  defp do_action(socket, action, msg) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case action.(doc, type) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, msg) |> rebuild_panes()}

        {:error, {:halted, reason}} ->
          # Lifecycle-hook veto (per plan §0 Q4). Surface as a red flash
          # banner so the editor sees why the action was cancelled.
          {:noreply, put_flash(socket, :error, "#{msg} cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Action failed")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Bulk publish helpers (Task barkpark-3yq) ─────────────────────────────
  #
  # `bulk_action/2` iterates `selected_doc_ids`, dispatches the per-doc
  # publish/unpublish call, aggregates {ok, err} counts and surfaces a
  # single flash. `list_pane_type/1` finds the rightmost pane carrying a
  # `:type_name` — that's the document-list pane (PaneBuilder only puts
  # `:type_name` on `:document_type_list` panes), and is the implicit
  # scope of the selection set.
  defp bulk_action(socket, kind) do
    ids = MapSet.to_list(socket.assigns.selected_doc_ids)
    type = list_pane_type(socket)
    dataset = socket.assigns.dataset
    opts = hook_opts(socket)

    if type == nil or ids == [] do
      assign(socket, selected_doc_ids: MapSet.new())
    else
      # Aggregate three buckets: successful writes, halts (lifecycle-hook
      # vetoes — per plan §0 Q4 these are NOT errors, they're plugin
      # policy enforcement) and other failures. Surfacing the halt count
      # separately in the flash makes it obvious to the editor that the
      # cancelled rows weren't broken — a plugin chose to refuse them.
      {ok, halted, err} =
        Enum.reduce(ids, {0, 0, 0}, fn id, {ok, halted, err} ->
          result =
            case kind do
              :publish -> Content.publish_document(id, type, dataset, opts)
              :unpublish -> Content.unpublish_document(id, type, dataset, opts)
            end

          case result do
            {:ok, _} -> {ok + 1, halted, err}
            {:error, {:halted, _}} -> {ok, halted + 1, err}
            _ -> {ok, halted, err + 1}
          end
        end)

      verb = if kind == :publish, do: "Published", else: "Unpublished"

      flash =
        cond do
          halted > 0 and err == 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{halted} cancelled by plugin rules."

          halted > 0 and err > 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{halted} cancelled by plugin rules (#{err} failed)."

          err == 0 ->
            "#{verb} #{ok} of #{length(ids)}"

          true ->
            "#{verb} #{ok} of #{length(ids)} (#{err} failed)"
        end

      socket
      |> assign(selected_doc_ids: MapSet.new())
      |> put_flash(:info, flash)
      |> rebuild_panes()
    end
  end

  defp list_pane_type(socket) do
    socket.assigns
    |> Map.get(:panes, [])
    |> Enum.reverse()
    |> Enum.find_value(fn pane -> Map.get(pane, :type_name) end)
  end

  # ── Tenancy scope (Task barkpark-k86v) ──────────────────────────────────────
  #
  # The dataset still lives in the URL (`/studio/:dataset`); the workspace /
  # project scope lives on the socket. `ensure_tenancy_scope/1` seeds the
  # scope to the seeded Default workspace/project the first time handle_params
  # runs (and leaves it untouched once a switch event has set it), so the
  # switcher always renders with a current selection rather than a bare
  # "production" literal. When the tenancy backfill hasn't run (no Default
  # workspace) the scope stays nil and the layout simply omits the switcher.
  defp ensure_tenancy_scope(socket) do
    if socket.assigns[:current_workspace] do
      socket
    else
      workspace = initial_workspace(socket)
      project = initial_project(workspace)

      assign(socket, current_workspace: workspace, current_project: project)
    end
  end

  # Resolve the initial project for the mounted workspace. The Default project
  # is only meaningful UNDER the Default workspace — for any other (member)
  # workspace the project MUST come from that workspace's own list, never the
  # Default project of a different tenant. Falls back to the workspace's first
  # project otherwise.
  defp initial_project(%{id: ws_id}) do
    default_under_workspace =
      case Tenancy.get_default_project() do
        %{workspace_id: ^ws_id} = proj -> proj
        _ -> nil
      end

    default_under_workspace || List.first(Tenancy.list_projects(ws_id))
  end

  defp initial_project(_), do: nil

  # ── Project → Dataset cascade (Task barkpark-dgpf) ──────────────────────────
  #
  # After a workspace/project switch, the Dataset select must reload for the
  # new project AND auto-select that project's default dataset. The default is
  # the "production" slug when the project has one, else the first dataset
  # (slug-ordered by `Tenancy.list_datasets/1`). Re-scoping is a push_patch to
  # the new dataset's URL leaf so handle_params re-subscribes the documents
  # topic and rebuilds the panes — same path a manual Dataset switch takes.
  #
  # When the project has NO dataset rows (string-seam-only / not yet seeded) we
  # keep the current `dataset` string and just rebuild_panes so the scope still
  # reloads — the `dataset` string stays authoritative per Content.Scope.
  #
  # Stale-scope guard (barkpark-nce1 / barkpark-5svq / barkpark-zok1): when a doc
  # is open, `nav_path` holds the OLD project's doc ids. Carrying it across a
  # switch makes `PaneBuilder.walk_path` resolve those ids against the NEW
  # project's structure — the editor pane then shows a stale/empty doc, and the
  # open `editor_doc` belongs to the old project. A subsequent autosave/publish
  # would `upsert_draft` the old doc_id under the new project's dataset (wrong
  # scope, possible duplicate row). So BEFORE rebuilding we reset the open-doc
  # nav_path to the root and clear the open-doc/autosave state via
  # `reset_nav_for_switch/1` — synchronously, so no save can fire against the
  # stale doc in the window before handle_params runs. (A purely structural
  # nav_path with no doc open is kept — see reset_nav_for_switch.)
  defp rescope_dataset_for_project(socket, %{} = project) do
    socket = reset_nav_for_switch(socket)

    case default_dataset_for_project(project) do
      %{slug: slug} when is_binary(slug) and slug != "" ->
        cond do
          slug == socket.assigns[:dataset] and (socket.assigns[:scope_prefix] || "") != "" ->
            # Scoped surface (tsk-url-p1): the ws/proj flip changed the
            # CANONICAL URL even though the dataset slug didn't — patch to it
            # (sync_scope_prefix already updated the prefix) so the address
            # bar tells the truth and LiveScope's handle_params hook
            # re-authorizes the new scope. handle_params then re-subscribes
            # list + presence and rebuilds — no in-place shortcut.
            push_patch(socket, to: studio_path(socket, [], slug))

          slug == socket.assigns[:dataset] ->
            # Flat surface, same dataset slug — handle_params won't fire (no
            # URL change), so the reset above is what rebuilds from the new
            # scope. The owning workspace may have flipped though, so re-point
            # the list subscription at the new scope's topic (barkpark-fe2k)
            # before rebuilding — otherwise live updates would still arrive on
            # the OLD workspace's topic (or not at all). Presence re-keys +
            # re-tracks for the same reason (tsk-url-p0).
            socket
            |> ensure_list_subscription(slug)
            |> ensure_presence_subscription()
            |> track_presence()
            |> rebuild_panes()

          true ->
            # Different slug — push_patch runs handle_params, re-asserting
            # nav_path from the new URL. The synchronous clear above still
            # matters: it nils editor_doc before the round-trip so an
            # in-flight save can't target the old project's doc.
            push_patch(socket, to: studio_path(socket, [], slug))
        end

      _ ->
        # Project has no dataset rows — the current slug stays authoritative,
        # but the workspace may have flipped. Scoped surface: the canonical
        # URL changed with the prefix — patch to it (handle_params + LiveScope
        # re-auth do the rest). Flat surface: re-point the list subscription
        # at the new scope's topic before rebuilding (barkpark-fe2k); presence
        # re-keys + re-tracks alongside (tsk-url-p0).
        if (socket.assigns[:scope_prefix] || "") != "" do
          push_patch(socket, to: studio_path(socket, [], socket.assigns[:dataset]))
        else
          socket
          |> ensure_list_subscription(socket.assigns[:dataset])
          |> ensure_presence_subscription()
          |> track_presence()
          |> rebuild_panes()
        end
    end
  end

  defp rescope_dataset_for_project(socket, _) do
    socket = reset_nav_for_switch(socket)

    if (socket.assigns[:scope_prefix] || "") != "" do
      push_patch(socket, to: studio_path(socket, [], socket.assigns[:dataset]))
    else
      socket
      |> ensure_list_subscription(socket.assigns[:dataset])
      |> ensure_presence_subscription()
      |> track_presence()
      |> rebuild_panes()
    end
  end

  # Reset navigation + open-document state for a workspace/project switch.
  #
  # The stale-scope vector is the open DOCUMENT: nav_path's trailing doc-id
  # segments pin a doc from the OLD project that `PaneBuilder.walk_path` then
  # mis-resolves against the NEW project's structure (stale/empty editor +
  # wrong-scope save). So when an editor doc is open we drop nav_path to the
  # root — panes rebuild from the new project's root rather than the old doc
  # ids. When NO doc is open the nav_path is purely structural (schema type /
  # desk segments, which are project-agnostic), so we leave it intact and let
  # rebuild_panes reload that list under the new scope — preserving a desk drill
  # across the switch (StudioLiveDeskScopeLeakTest).
  #
  # Either way we nil every assign that pins an open document
  # (editor_doc/type/schema/form/blocks/mode) plus the diff/preview flags derived
  # from it — clearing them here closes the window where a queued autosave could
  # still see the old doc. Clearing when nothing is open is a harmless no-op.
  defp reset_nav_for_switch(socket) do
    nav_path = if socket.assigns[:editor_doc], do: [], else: socket.assigns[:nav_path] || []

    assign(socket,
      nav_path: nav_path,
      editor_doc: nil,
      editor_type: nil,
      editor_schema: nil,
      editor_view: :form,
      editor_form: %{},
      editor_blocks: [],
      editor_blocks_synth?: false,
      editor_mode: :classic,
      editor_is_draft: false,
      editor_has_published: false,
      published_doc: nil,
      diff_visible: false,
      # Clear the graph pane too (the verified 3-site reset gotcha) — a stale
      # `:graph` view + payload must not leak across a nav switch.
      graph_doc: nil,
      graph_data: %{nodes: [], edges: []}
    )
  end

  # The project's default dataset row: prefer the canonical "production" slug,
  # else the first (slug-ordered) dataset. nil when the project has none.
  defp default_dataset_for_project(%{} = project) do
    datasets = Tenancy.list_datasets(project)
    Enum.find(datasets, &(&1.slug == Content.default_dataset())) || List.first(datasets)
  end

  defp default_dataset_for_project(_), do: nil

  # Flash text for a failed create. Surfaces the first changeset error (e.g. a
  # blank name → "name can't be blank", or a slug collision) so the user sees
  # WHY; falls back to a generic message when no field error is extractable.
  defp create_error(%Ecto.Changeset{} = changeset, what) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    case errors |> Map.to_list() |> List.first() do
      {field, [msg | _]} -> "Could not create #{what}: #{field} #{msg}"
      _ -> "Could not create #{what}"
    end
  end

  defp create_error(_, what), do: "Could not create #{what}"

  # True iff `slug` names a dataset under the given project — the membership
  # gate for a Dataset switch (the switch-dataset handler refuses any slug not
  # in the current project's dataset rows).
  defp project_has_dataset?(%{} = project, slug) when is_binary(slug) do
    project
    |> Tenancy.list_datasets()
    |> Enum.any?(&(&1.slug == slug))
  end

  defp project_has_dataset?(_, _), do: false

  # Defense-in-depth gate for the `/studio/:dataset` URL leaf (Task barkpark-o7fu).
  # Returns `{:redirect, default_slug}` when the resolved current project does NOT
  # own the requested `dataset` AND has a default dataset to fall back to; `:ok`
  # otherwise (leaf is valid, OR the project has no dataset rows to redirect to,
  # OR no project is resolved — in those cases the `dataset` string stays
  # authoritative, matching rescope_dataset_for_project's string-seam invariant).
  defp redirect_dataset_leaf(socket, dataset) do
    project = socket.assigns[:current_project]

    cond do
      project_has_dataset?(project, dataset) ->
        :ok

      true ->
        case default_dataset_for_project(project) do
          %{slug: slug} when is_binary(slug) and slug != "" and slug != dataset ->
            {:redirect, slug}

          _ ->
            :ok
        end
    end
  end

  # Mount-scope derivation (Task barkpark-g4a7). With an authenticated
  # principal, the initial workspace is the FIRST workspace it is a member of
  # (`list_workspaces_for/1`, slug-ordered) — never a foreign or Default
  # workspace it has no membership in. Only the genuinely-anonymous /
  # single-tenant dev session (no principal, or a principal with zero
  # memberships) falls back to the seeded Default, preserving the local-dev
  # experience without ever exposing another tenant's workspace.
  defp initial_workspace(socket) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case List.first(Tenancy.list_workspaces_for(token)) do
          %{} = ws -> ws
          _ -> Tenancy.get_default_workspace()
        end

      _ ->
        Tenancy.get_default_workspace()
    end
  end

  # Membership gate shared by the switch handlers (switch-workspace /
  # switch-project). With a principal: defer to the canonical
  # `Tenancy.Auth.member?/2`. Without one (anonymous / single-tenant dev):
  # the only reachable workspace is the one already on the socket — the
  # seeded Default — so the dev experience never regresses while no foreign
  # workspace is reachable.
  defp can_reach_workspace?(socket, %{id: ws_id} = _workspace) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        Barkpark.Tenancy.Auth.member?(token, ws_id)

      _ ->
        match?(%{id: ^ws_id}, socket.assigns[:current_workspace])
    end
  end

  # Keep the URL prefix in lockstep with the socket scope on the SCOPED
  # surface (tsk-url-p1): after a switch handler reassigns
  # current_workspace/current_project, the prefix must follow so the very
  # next studio_path/push_patch addresses the NEW tenant — a stale prefix
  # would patch back into the old workspace and LiveScope would silently
  # revert the switch. Flat surface (prefix "") stays flat: its switchers
  # remain socket-state-only until the P3 cutover.
  defp sync_scope_prefix(socket) do
    with prefix when is_binary(prefix) and prefix != "" <- socket.assigns[:scope_prefix],
         %{slug: ws_slug} when is_binary(ws_slug) <- socket.assigns[:current_workspace],
         %{slug: proj_slug} when is_binary(proj_slug) <- socket.assigns[:current_project] do
      assign(socket, :scope_prefix, "/w/#{ws_slug}/p/#{proj_slug}")
    else
      _ -> socket
    end
  end

  # The default dataset for a bare `/studio` mount. The `dataset` string stays
  # the leaf discriminator and is ORTHOGONAL to workspace/project (per
  # Content.Scope) — the Default-tenancy backfill assigned the seeded Default
  # workspace/project to ALL pre-tenancy rows regardless of their dataset, and
  # those rows live under the "production" dataset. So the Default scope's
  # content is the "production" dataset; we resolve it through Content rather
  # than hardcode the literal at the call sites. `list_datasets/0` always
  # includes "production", so this is stable on a fresh DB.
  def default_dataset, do: Content.default_dataset()

  # Socket-aware URL builder — THE single choke point for every push_patch
  # and chip href. On the scoped mount (tsk-url-p1) LiveScope assigns
  # `scope_prefix: "/w/<ws>/p/<proj>"`; `studio_path_for` contributes the
  # `/d/:dataset/studio[/...]` suffix, composing the canonical
  # `/w/<ws>/p/<proj>/d/<ds>/studio[/...]` shape.
  defp studio_path(socket, path, dataset, opts \\ []) do
    (socket.assigns[:scope_prefix] || "") <> studio_path_for(path, dataset, opts)
  end

  defp studio_path_for([], dataset, opts),
    do: append_desk_query("/d/#{dataset}/studio", opts)

  defp studio_path_for(segments, dataset, opts),
    do:
      append_desk_query(
        "/d/#{dataset}/studio/" <> Enum.join(segments, "/"),
        opts
      )

  defp append_desk_query(path, opts) do
    case Keyword.get(opts, :desk) do
      nil -> path
      "" -> path
      desk -> path <> "?desk=" <> URI.encode_www_form(to_string(desk))
    end
  end

  # Render-side helper — the chip href shows the URL the user would
  # land on if they clicked. (The actual navigation goes through
  # `phx-click="select-desk"` → `push_patch`, so JS isn't required;
  # the href makes the chip bookmarkable + middle-clickable.)
  defp desk_chip_href(scope_prefix, nav_path, dataset, desk) do
    (scope_prefix || "") <> studio_path_for(nav_path, dataset, desk: desk)
  end

  # Render-side scoping for `:plugin_link` hrefs. Structure/PaneBuilder emit
  # them in the legacy FLAT shape `/studio/<ds>[/...]` — Structure has no
  # scope knowledge, so the rewrite happens here, where `@scope_prefix` is
  # in hand. On the scoped surface the flat shape would ride the
  # flat→scoped 302 funnel, which re-resolves the workspace from the
  # SESSION and can teleport the user out of the workspace they're on, so
  # rewrite to the /d/ canonical instead. Empty prefix (flat surfaces, e.g.
  # the /studio/:dataset/_plugins admin LV) keeps the flat path — mirrors
  # the branch in StudioComponents.default_top_menu_entries/2.
  defp scoped_plugin_href("", href), do: href

  defp scoped_plugin_href(scope_prefix, "/studio/" <> rest) when is_binary(scope_prefix) do
    case String.split(rest, "/", parts: 2) do
      [ds, suffix] -> "#{scope_prefix}/d/#{ds}/studio/#{suffix}"
      [ds] -> "#{scope_prefix}/d/#{ds}/studio"
    end
  end

  defp scoped_plugin_href(_scope_prefix, href), do: href

  # ── ArrayField helpers (Studio reorder/add/remove wiring) ───────────────────
  #
  # `editor_schema.fields` is `{:array, :map}` — string-keyed raw maps as
  # stored on disk (SchemaDefinition). We never see %Field{} structs here.

  defp find_field(socket, field_name) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    Enum.find(fields, fn f -> Map.get(f, "name") == field_name end)
  end

  defp parse_idx(idx) when is_integer(idx), do: idx

  defp parse_idx(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_idx(_), do: 0

  # ── Path-based navigation (delegates to StudioLive.Path) ───────────────────
  # The pure parsing/get/put helpers live in StudioLive.Path; these public
  # entry points keep the test-facing API on StudioLive and bind the socket's
  # editor_schema to the schema-side descent.
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

  # ── Pane builder ───────────────────────────────────────────────────────────

  defp rebuild_panes(socket) do
    {panes, editor} =
      PaneBuilder.build(socket.assigns.dataset, socket.assigns.nav_path,
        desk: socket.assigns[:nav_desk],
        scope: ScopeHelpers.scope_opts(socket)
      )

    new_schema = editor && editor[:schema]
    old_schema = socket.assigns[:editor_schema]
    nav_group = resolve_nav_group(socket.assigns[:nav_group], old_schema, new_schema)

    new_form = (editor && editor[:form]) || %{}

    editor_doc = editor && editor[:doc]
    editor_type = editor && editor[:type]
    is_draft = (editor && editor[:is_draft]) || false
    has_published = (editor && editor[:has_published]) || false

    # Resolve the block list backing a Beta view of the open document (the
    # stored content["blocks"] or an in-memory synthesis when absent). Whether
    # the editor is currently showing Classic or Beta, we keep this fresh so a
    # toggle into Beta renders the up-to-date blocks without a refetch.
    # `editor_mode` resets to :classic whenever the open document changes (a
    # different doc_id) — a Beta session is per-document, not sticky across docs.
    {editor_blocks, editor_blocks_synth?} =
      Content.resolve_blocks_for_edit(editor_doc, editor_type, socket.assigns.dataset)

    editor_mode =
      if same_editor_doc?(socket.assigns[:editor_doc], editor_doc),
        do: socket.assigns[:editor_mode] || :classic,
        else: :classic

    socket =
      assign(socket,
        panes: panes,
        editor_doc: editor_doc,
        editor_schema: new_schema,
        editor_type: editor_type,
        editor_is_draft: is_draft,
        editor_has_published: has_published,
        editor_form: new_form,
        editor_mode: editor_mode,
        editor_blocks: editor_blocks,
        editor_blocks_synth?: editor_blocks_synth?,
        save_status: socket.assigns[:save_status] || "",
        nav_group: nav_group,
        cross_violations: compute_cross_violations(new_schema, new_form),
        published_doc:
          fetch_published_twin(
            editor_doc,
            editor_type,
            socket.assigns.dataset,
            is_draft,
            has_published,
            ScopeHelpers.scope_opts(socket)
          ),
        diff_visible:
          socket.assigns[:diff_visible] &&
            editor_doc != nil && is_draft && has_published
      )
      |> maybe_refresh_content_preview()

    # When the pane builder resolved a `view: :paper` editor (a paper opened
    # in the editor pane), set up the live block view: stream the blocks (or
    # adopt the HTML-only fallback) and remember the streaming rev so deltas
    # apply in order. This is the only place the paper stream is (re)set — the
    # `{:paper_block,…}` delta path NEVER rebuilds panes, so it never remounts.
    case editor && editor[:view] do
      :paper ->
        socket
        |> clear_sheet_view()
        |> clear_graph_view()
        |> setup_paper_view(editor[:doc])

      :sheet ->
        socket
        |> clear_paper_view()
        |> clear_graph_view()
        |> setup_sheet_view(editor[:doc])

      :graph ->
        socket
        |> clear_paper_view()
        |> clear_sheet_view()
        |> setup_graph_view(editor[:doc], editor[:graph])

      :media_explorer ->
        socket
        |> clear_paper_view()
        |> clear_sheet_view()
        |> clear_graph_view()
        |> assign(
          editor_view: :media_explorer,
          media_kind_filter: editor[:kind_filter] || "all"
        )

      _ ->
        socket
        |> clear_paper_view()
        |> clear_sheet_view()
        |> clear_graph_view()
        |> assign(editor_view: :form, media_kind_filter: "all")
    end
  end

  # ── In-Studio sheet grid editor (Sheets M2) ──────────────────────────────
  #
  # A `view: :sheet` editor (a sheet opened in the editor pane) renders the
  # SheetGrid LiveComponent and subscribes this LiveView to the sheet
  # session's delta topic. The component owns all grid state; the
  # `{:sheets_op,…}` handle_info above just forwards frames via send_update.

  defp setup_sheet_view(socket, %{} = doc) do
    socket
    |> ensure_sheet_subscription(doc)
    |> assign(editor_view: :sheet, sheet_doc: doc)
  end

  defp setup_sheet_view(socket, _doc), do: clear_sheet_view(socket)

  defp clear_sheet_view(socket) do
    socket
    |> ensure_sheet_subscription(nil)
    |> assign(sheet_doc: nil)
  end

  # ── In-Studio blast-radius graph pane (Phase 5) ───────────────────────────
  #
  # A `view: :graph` editor renders the GraphView LiveComponent over the
  # node/edge payload PaneBuilder already traversed (Content.Graph.traverse/2).
  # No subscription: the graph is a snapshot rebuilt on navigation — the
  # GraphView component diffs via its stable-id Cytoscape hook, never remounts.
  # `clear_graph_view/1` runs at every other reset arm so a stale `:graph` view
  # never leaks across nav switches (the verified 3-site gotcha).

  defp setup_graph_view(socket, %{} = doc, graph) when is_map(graph) do
    # Pass the FULL graph map through verbatim — PaneBuilder threads `:root`
    # (the navigated-to doc id) alongside `:nodes`/`:edges`, and the GraphView
    # component reads `Map.get(graph, :root)` in update/2 to emit `data-root=`.
    # Rebuilding the map with only nodes/edges (the prior bug) dropped `:root`,
    # so root-sun centering fell back to the highest-degree node. Merge defaults
    # UNDER the original so `:root` survives and nodes/edges stay non-nil.
    assign(socket,
      editor_view: :graph,
      graph_doc: doc,
      graph_data: Map.merge(%{nodes: [], edges: []}, graph)
    )
  end

  defp setup_graph_view(socket, _doc, _graph), do: clear_graph_view(socket)

  defp clear_graph_view(socket) do
    if socket.assigns[:editor_view] == :graph do
      assign(socket, editor_view: :form, graph_doc: nil, graph_data: %{nodes: [], edges: []})
    else
      assign(socket, graph_doc: nil, graph_data: %{nodes: [], edges: []})
    end
  end

  # Diff-and-resubscribe, same shape as ensure_list_subscription: idempotent
  # across rebuilds of the same open sheet, unsubscribes on navigation away.
  # The topics are keyed with the DOC's owning workspace — exactly what the
  # session broadcasts with — not the viewer's current workspace.
  defp ensure_sheet_subscription(socket, doc) do
    {new_topic, new_presence_topic} =
      if doc != nil and connected?(socket) do
        {Barkpark.Plugins.Sheets.Session.topic(doc.doc_id, socket.assigns.dataset, doc.workspace_id),
         Barkpark.Plugins.Sheets.Session.presence_topic(
           doc.doc_id,
           socket.assigns.dataset,
           doc.workspace_id
         )}
      else
        {nil, nil}
      end

    socket
    |> resub_sheet_deltas(new_topic)
    |> resub_sheet_presence(new_presence_topic)
  end

  defp resub_sheet_deltas(socket, new_topic) do
    old_topic = socket.assigns[:sheet_topic]

    if new_topic == old_topic do
      socket
    else
      if old_topic, do: Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
      if new_topic, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)
      assign(socket, sheet_topic: new_topic)
    end
  end

  # Per-sheet grid presence (Sheets M4). Track/untrack mirror the in-bar
  # presence lifecycle: entries are (topic, key)-scoped, so navigating away
  # without the untrack would leave a ghost cursor until this LV dies. The
  # seeded meta matches the SheetGrid component's initial state — cursor on
  # A1 of tab 0, nothing selected, not editing; every later update is the
  # component's (the hook's throttled `presence-meta` frames + the
  # edit-start/commit/cancel editing lifecycle), riding the SAME pid since
  # LiveComponents run in this LV process.
  defp resub_sheet_presence(socket, new_topic) do
    old_topic = socket.assigns[:sheet_presence_topic]

    if new_topic == old_topic do
      socket
    else
      if old_topic do
        Presence.untrack(self(), old_topic, socket.assigns.user_id)
        Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
      end

      presences =
        if new_topic do
          Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)

          Presence.track(self(), new_topic, socket.assigns.user_id, %{
            name: socket.assigns.user_name,
            color: socket.assigns.user_color,
            tab: 0,
            active: "A1",
            selection: nil,
            editing: nil,
            joined_at: System.system_time(:second)
          })

          PresenceState.list(new_topic)
        else
          []
        end

      assign(socket, sheet_presence_topic: new_topic, sheet_presences: presences)
    end
  end

  # ── In-Studio live paper view (convergence/papers-in-studio) ────────────────
  #
  # The editor pane renders a paper's blocks LIVE, reusing BulldocsLive's render +
  # delta logic. A block-backed paper streams each top-level block as a keyed
  # stream item; an HTML-only (legacy) paper falls back to a raw-HTML re-assign.
  # `{:paper_block,…}` / `{:paper_updated,…}` frames (handle_info below) patch
  # the stream / HTML in place — no rebuild_panes, no remount.

  defp setup_paper_view(socket, %{content: content} = paper) when is_map(content) do
    blocks = Map.get(content, "blocks")
    rev = Map.get(content, "rev") || 0
    html = Map.get(content, "body_html") || ""

    if is_list(blocks) do
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: true,
        # Opening (or jumping to) a paper always lands in read-only View mode.
        paper_edit_mode: false
      )
      |> stream(
        :paper_blocks,
        paper_stream_items(blocks, socket.assigns.dataset, ScopeHelpers.scope_opts(socket)),
        reset: true
      )
    else
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: false,
        paper_edit_mode: false
      )
      |> stream(:paper_blocks, [], reset: true)
    end
  end

  defp setup_paper_view(socket, _paper), do: clear_paper_view(socket)

  defp clear_paper_view(socket) do
    if socket.assigns[:editor_view] == :paper do
      assign(socket,
        editor_view: :form,
        paper_doc: nil,
        paper_rev: 0,
        paper_html: "",
        paper_block_mode: false,
        paper_edit_mode: false
      )
    else
      assign(socket, editor_view: :form)
    end
  end

  # ── Per-document Classic <-> Beta toggle (Exp-P3.2, barkpark-g2ql) ───────────

  # Same open document across a rebuild? Compared by published id so a draft
  # save (drafts.<id>) that re-resolves the editor doesn't read as a doc switch
  # and snap the user back to Classic mid-Beta-session.
  defp same_editor_doc?(%{doc_id: a}, %{doc_id: b}),
    do: Content.published_id(a) == Content.published_id(b)

  defp same_editor_doc?(_, _), do: false

  # Beta is offered only for an Expectation-bearing document — one that already
  # has stored blocks OR a non-empty synthesized block list. A doc whose schema
  # carries no layout synthesizes to []; offering Beta there would show an empty
  # block editor, so we gate it out and the Classic form is the only view.
  defp beta_editable?(socket) do
    socket.assigns[:editor_doc] != nil and socket.assigns[:editor_blocks] != []
  end

  # Each stream item carries a stable id (the block id) and its rendered
  # fragment. Top-level blocks stream individually; a `section` renders as one
  # fragment (its children live inside it). Mirrors BulldocsLive.to_stream_items/1.
  defp paper_stream_items(blocks, dataset, scope) do
    resolver = fn value, ref_type -> Content.reference_title(value, ref_type, dataset, scope) end

    codelist_resolver = fn plugin, codelist_id, code ->
      Content.codelist_label(plugin, codelist_id, code)
    end

    # Render in article style so headings become real `<h1>`/`<h2>` (not the
    # email-mode `<span style="font-weight:bold">` default). The Edit pane's
    # `.bp-paper-surface h1, h2, h3` CSS rules (root.html.heex ~:2064) only
    # match real heading elements; with email-style spans the styles never
    # applied and the View pane in the desk read as a flat bold list instead
    # of typeset prose. Mirrors BulldocsLive.render_opts(true) at bulldocs_live.ex
    # ~:476 — same surface contract on both LiveViews.
    opts = %{ref_resolver: resolver, codelist_resolver: codelist_resolver, style: :article}

    # R2 fix (Option B): id-less blocks need a UNIQUE positional stream id, else
    # they collapse to the constant `paper_blocks-` DOM id and the stream
    # dedupes all but the last. Mirrors BulldocsLive.stream_block_id/2.
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{id: paper_stream_block_id(block, index), html: Render.render_block(block, opts)}
    end)
  end

  defp paper_stream_block_id(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "block-#{index}"
    end
  end

  # Stream dom ids are namespaced by the stream name (`:paper_blocks` →
  # `"paper_blocks-<id>"`, per Phoenix.LiveView.LiveStream.default_id/2), so a
  # remove-block delete-by-id must mirror that exact prefix — the UNDERSCORE in
  # `paper_blocks` matters; a hyphen here would silently never match.
  defp paper_block_dom_id(id), do: "paper_blocks-#{id}"

  # A gap is any received rev that is not exactly the next one we expect. The
  # first delta on a paper mounted at rev 0 (never-streamed) also refetches —
  # correct: there is nothing to append onto. Mirrors BulldocsLive.gap?/2.
  defp paper_gap?(last_rev, incoming_rev)
       when is_integer(last_rev) and is_integer(incoming_rev) do
    incoming_rev != last_rev + 1
  end

  defp paper_gap?(_last, _incoming), do: true

  defp apply_paper_delta(socket, %{op_kind: "remove-block", block_id: id} = frame) do
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp apply_paper_delta(
         socket,
         %{op_kind: kind, block_id: id, fragment_html: html, position: pos} = frame
       )
       when kind in ["append-block", "insert-after"] and is_integer(pos) do
    # A NEW block enters the stream at its known top-level index so a
    # mid-document insert-after lands in order — not appended to the end.
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp apply_paper_delta(
         socket,
         %{op_kind: "move-block", block_id: id, fragment_html: html, position: pos} = frame
       )
       when is_integer(pos) do
    # A reorder: the moved block kept its id + content, only its position
    # changed. A LiveView stream cannot relocate an existing item by id, so we
    # delete it then re-insert at its new top-level index — the View order now
    # matches the Edit order. (Same id throughout: content is preserved.)
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp apply_paper_delta(socket, %{block_id: id, fragment_html: html} = frame) do
    # patch-block / replace-block (and any new block whose top-level position is
    # unknown, e.g. one nested in a section): upsert by id, in place (no `at:`)
    # so editing a block never reorders it. The rev-gap path repairs residual
    # ordering on the next full refetch.
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html})
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp refetch_paper(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    case slug && Content.get_paper(slug, dataset) do
      nil ->
        socket

      paper ->
        content = paper.content || %{}

        case Map.get(content, "blocks") do
          blocks when is_list(blocks) ->
            socket
            |> stream(
              :paper_blocks,
              paper_stream_items(blocks, dataset, ScopeHelpers.scope_opts(socket)),
              reset: true
            )
            |> assign(:paper_doc, paper)
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, true)

          _ ->
            socket
            |> assign(:paper_doc, paper)
            |> assign(:paper_html, Map.get(content, "body_html") || "")
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, false)
        end
    end
  end

  # Fetch the published twin of the currently-open draft, if any. Returns
  # nil when the editor is closed, the open doc is not a draft, or no
  # published version exists (the toggle button is gated on these same
  # flags so the diff view never opens without both sides).
  #
  # Called from `rebuild_panes/1` so the data is ready on first render —
  # we deliberately don't refresh `published_doc` on autosave: the
  # published twin doesn't change while the user types, so refetching on
  # every keystroke would just burn DB round-trips.
  defp fetch_published_twin(nil, _type, _dataset, _is_draft, _has_published, _scope_opts), do: nil
  defp fetch_published_twin(_doc, nil, _dataset, _is_draft, _has_published, _scope_opts), do: nil
  defp fetch_published_twin(_doc, _type, _dataset, false, _has_published, _scope_opts), do: nil
  defp fetch_published_twin(_doc, _type, _dataset, _is_draft, false, _scope_opts), do: nil

  defp fetch_published_twin(doc, type, dataset, true, true, scope_opts) do
    case Content.get_document(Content.published_id(doc.doc_id), type, dataset, scope_opts) do
      {:ok, pub} -> pub
      _ -> nil
    end
  end

  # ── Cross-field validations (Task barkpark-cgn) ─────────────────────────────
  # Computes the list of unsatisfied cross-validations against the current
  # editor form using `Barkpark.Content.CrossValidator`. The form may be `nil`
  # or empty when no document is in scope — the validator already short-circuits
  # on `validate(_, doc)` non-map docs, but we hard-gate `nil` here to keep
  # the assign always a list (LiveView templates rely on enumeration).
  defp compute_cross_violations(nil, _), do: []
  defp compute_cross_violations(_, form) when not is_map(form), do: []

  defp compute_cross_violations(schema, form) do
    Barkpark.Content.CrossValidator.violations(schema, form)
  end

  # Pick the active tab when the editor pane re-renders. Sanity-Studio
  # default-tab semantics: when the schema changes (or first loads), reset
  # to the schema's first declared group; when the schema is unchanged,
  # keep whatever tab the user was on so autosave round-trips don't
  # snap them back to "Core" mid-edit. Schemas with no `groups:` get
  # `nil` here — that's the legacy/no-tab-bar path, and visible_fields/2
  # turns it into "show all fields" for back-compat.
  defp resolve_nav_group(_current, _old, nil), do: nil

  defp resolve_nav_group(current, old, new_schema) do
    cond do
      schema_id(new_schema) == schema_id(old) and current != nil -> current
      true -> first_group_name(new_schema)
    end
  end

  defp schema_id(nil), do: nil
  defp schema_id(schema), do: Map.get(schema, :name) || Map.get(schema, "name")

  defp first_group_name(schema) do
    case BarkparkWeb.StudioComponents.schema_groups(schema) do
      [%{"name" => name} | _] -> name
      _ -> nil
    end
  end

  # ── Network shares panel helpers (scoped-sharing P6) ─────────────────────


  # The live shares — env baseline + persisted — flattened to presentation rows.
  defp load_share_rows do
    env = Enum.map(Barkpark.Sharing.shares_env(), &share_row(&1, "env"))
    stored = Enum.map(Barkpark.Sharing.list_stored(), &share_row(&1, "stored"))
    urls = share_url_index()

    Enum.map(env ++ stored, fn row -> %{row | url: Map.get(urls, row.scope)} end)
  end

  defp share_row(%Barkpark.Sharing.Share{} = s, source) do
    %{
      scope: "#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}",
      surfaces: Enum.map_join(s.surfaces, ", ", &Atom.to_string/1),
      access: Atom.to_string(s.access),
      source: source,
      url: nil
    }
  end

  # scope -> LAN reader URL, only for shares that expose :papers (the only
  # surface with a human-facing page). Empty when no LAN IP is detectable.
  defp share_url_index do
    Barkpark.Sharing.share_urls()
    |> Map.new(fn {s, url} -> {"#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}", url} end)
  end

  # The scope string the add form pre-fills: the Studio's current scope. Falls
  # back to the canonical defaults when a slug is absent (flat /studio).
  defp shares_scope_prefill(socket) do
    ws = scope_slug(socket.assigns[:current_workspace], "default")
    proj = scope_slug(socket.assigns[:current_project], "default")
    dataset = socket.assigns[:dataset] || "production"
    "#{ws}/#{proj}/#{dataset}"
  end

  defp scope_slug(%{slug: slug}, _default) when is_binary(slug), do: slug
  defp scope_slug(_, default), do: default

  # The open item's links, flattened to {id, access, url} for the popover. The
  # url advertises a SHAREABLE host (LAN IP / configured domain), never the
  # localhost the operator happens to be on — that link works for nobody else.
  defp load_item_links(socket, %{kind: kind, ref_type: ref_type, ref_id: ref_id}) do
    case socket.assigns[:current_workspace] do
      %{id: ws_id} ->
        base = Barkpark.Sharing.share_link_base()

        Barkpark.Sharing.Links.list_for(ws_id, kind, ref_type, ref_id)
        |> Enum.map(fn l ->
          %{id: l.id, access: l.access, url: l.token && link_url(base, l.token)}
        end)

      _ ->
        []
    end
  end

  defp load_item_links(_socket, _), do: []

  # Absolute when a shareable base is known; relative otherwise (the popover's
  # Copy then prepends the browser origin as a last resort).
  defp link_url(nil, token), do: "/s/#{token}"
  defp link_url(base, token), do: "#{base}/s/#{token}"

  defp item_link_attrs(socket, item, access) do
    %{
      workspace_id: socket.assigns.current_workspace.id,
      project_id: socket.assigns[:current_project] && socket.assigns.current_project.id,
      dataset: socket.assigns[:dataset] || "production",
      kind: item.kind,
      ref_type: item.ref_type,
      ref_id: item.ref_id,
      access: access
    }
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
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
                  href={desk_chip_href(@scope_prefix, @nav_path, @dataset, gname)}
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
                    href={scoped_plugin_href(@scope_prefix || "", item.href)}
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
end
