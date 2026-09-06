defmodule BarkparkWeb.BulldocsLive.Edit do
  @moduledoc """
  Edit mode for the paper reader (`BarkparkWeb.BulldocsLive`) — slice 2 of the
  "Edit on the link" epic (task-633d25cac4262afc, epic task-a19eeb215f653529).

  Slice 1 taught the reader WHO is viewing (`BarkparkWeb.PaperViewer` assigns
  `:viewer` and `:can_edit?`). This module is WHAT they may do: when
  `@can_edit?` is true the reader offers an Edit toggle that mounts the EXISTING
  Studio Beta block editor
  (`BarkparkWeb.Studio.StudioLive.Components.PaperEditor.paper_block_editor/1`)
  over the same paper surface, and every edit routes through the ONE op path
  (`Content.apply_paper_block_op/4` / `apply_paper_block_ops/4`). No second
  write path, no new storage.

  ## The gate

  `attach_gate/1` attaches a `:handle_event` lifecycle hook that HALTS every
  event in `@edit_events` unless `socket.assigns[:can_edit?] == true`, flashing
  the same refusal for all of them. The reader's own events (`paper-action`,
  `simplify-*`, `rail-select`, `open-diff`, `close-diff`) are not in that list
  and pass through untouched.

  The gate is keyed on `:can_edit?` and NOTHING ELSE. In particular it does not
  reuse `BarkparkWeb.Studio.Caps.write_capable?/2`: that predicate deliberately
  lets a principal-LESS socket through for Studio's public-demo posture, which
  on a public reader is precisely the anonymous visitor we must refuse.
  `:can_edit?` is `PaperViewer.can_edit?/2` — `Tenancy.Auth.authorize/3` with
  action `:write` on the paper's OWN workspace — and it is fail-closed.

  Because the hook halts BEFORE `handle_event/3`, no `paper-*` clause in
  `BulldocsLive` is reachable by a denied socket. The write functions here
  re-check `can_edit?` anyway (`writable?/1`), so a future caller that reaches
  them without the hook still cannot write.

  ## Canvas contract

  The reader carries the fetched paper as `:paper_doc`, allowing it to reuse
  Studio's continuous-canvas echo, task-preview, and server-rendered block paint
  helpers without a second protocol. It wires slash insertion, optional-slot
  materialization, callout folding, and scoped wikilink/tag autocomplete in
  addition to the core op events. Item-share editors receive empty autocomplete
  results because their grant binds one paper and does not grant dataset-wide
  discovery. Events that require Studio-only pane/schema state remain gated and
  fall through as calm no-ops for a permitted reader.

  ## State

  `:editing?`, `:edit_blocks` (the paper's TOP-LEVEL block list), `:paper_rev`,
  `:save_status`, `:paper_halt`, `:task_previews`. `sync/1` re-derives the
  blocks from storage after every accepted op; `BulldocsLive.refetch/1` calls
  `sync/2` so a broadcast-driven reload keeps the editor buffer honest.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, connected?: 1]

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.PaperAccess
  alias BarkparkWeb.PaperActor
  alias BarkparkWeb.PaperPresence
  alias BarkparkWeb.PaperViewer
  alias BarkparkWeb.Presence
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.{Blocks, Shared}
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: SharedPaper

  @server_minted_block :__server_minted_block__

  # The `action` string stamped on the revision every reader edit now writes.
  # Free-form by contract (`:revision_action` already carries
  # "valueref-accept-baseline" / "valueref-writeback"), and deliberately NOT
  # "update": history should be able to say that this change arrived through
  # the shared link rather than through Studio, because that is exactly the
  # distinction slice 4 exists to make visible.
  @revision_action "edit-on-link"

  # Every `paper-*` event Studio wires. Membership here means "an edit event":
  # refused for a socket without `:can_edit?`, whether or not the reader wires
  # a handler for it. Keep in sync with studio_live.ex's paper-* clauses.
  @edit_events ~w(
    paper-toggle-edit
    paper-op
    paper-ops
    paper-edit-block
    paper-block-autosave
    paper-add-block
    paper-delete-block
    paper-move-block
    paper-move-block-to
    task-preview-refresh
    paper-materialize-slot
    paper-slash-insert
    paper-wikilink-search
    paper-tag-search
    paper-add-property
    paper-unbind-property
    paper-callout-fold
    paper-valueref-inspect
    paper-publish
  )

  # One vocabulary for every refusal, whichever event asked.
  @denial "You don't have access to do that."

  @doc "The event names the gate refuses without `:can_edit?`."
  @spec edit_events() :: [String.t()]
  def edit_events, do: @edit_events

  @doc "The refusal copy every denied edit event gets."
  @spec denial() :: String.t()
  def denial, do: @denial

  @doc """
  Seed the edit-mode assigns from the mounted paper. Always called, for every
  viewer: the anonymous render never reads them, but a nil assign would crash a
  later `@editing?` check.
  """
  def defaults(socket, paper) do
    socket
    |> assign(:editing?, false)
    |> assign(:edit_blocks, blocks_of(paper))
    |> assign(:paper_doc, paper)
    |> assign(:paper_rev, rev_of(paper))
    |> assign(:paper_link_details, paper_link_details(socket, paper))
    |> assign(:save_status, "")
    |> assign(:last_save_ok?, true)
    |> assign(:paper_halt, nil)
    |> assign(:task_previews, %{})
  end

  @doc """
  Attach the edit-event gate. Halts every `@edit_events` member for a socket
  whose `:can_edit?` is not exactly `true`; passes everything else through.
  """
  def attach_gate(socket) do
    attach_hook(socket, :paper_edit_gate, :handle_event, &gate/3)
  end

  defp gate(event, _params, socket) when is_binary(event) do
    if event in @edit_events and socket.assigns[:can_edit?] != true do
      {:halt, put_flash(socket, :error, @denial)}
    else
      {:cont, socket}
    end
  end

  defp gate(_event, _params, socket), do: {:cont, socket}

  # ── toggle ──────────────────────────────────────────────────────────────────

  @doc """
  Flip in/out of edit mode. Entering re-reads the paper so the editor opens on
  the stored blocks, not on a buffer that a broadcast may have left behind.
  """
  def toggle(socket) do
    cond do
      not writable?(socket) ->
        refuse(socket)

      socket.assigns[:editing?] == true and
          (is_binary(socket.assigns[:paper_halt]) or socket.assigns[:last_save_ok?] == false) ->
        socket

      true ->
        editing? = socket.assigns[:editing?] != true

        socket =
          socket
          |> assign(:editing?, editing?)
          # Slice 4: tell the room. The presence meta's `editing?` is what puts
          # the dot next to a name in `#paper-presence`, so it must flip on the
          # SAME event that flips the mode — not on the first op, which may never
          # come.
          |> update_presence_editing(editing?)

        if editing?, do: socket |> sync() |> refresh_canvas(), else: socket
    end
  end

  # ── the ONE op path ─────────────────────────────────────────────────────────

  @doc """
  Apply ONE `DocPatchOp` with the socket's tenant scope. Request-identified
  writes use the exact-once batch facade with one op; the unidentified legacy
  seam retains the single-op primitive. Result mapping matches the Studio pane
  (`Studio.StudioLive.Shared.Paper.paper_pane_op/2`).
  """
  def apply_op(socket, %{"op" => _} = op) do
    request_id = op["request_id"]
    socket = failed_save(socket, request_id)

    if is_binary(request_id) do
      apply_op_once(socket, op, request_id)
    else
      apply_unidentified_op(socket, op)
    end
  end

  def apply_op(socket, op), do: failed_save(socket, is_map(op) && op["request_id"])

  defp apply_op_once(socket, op, request_id) do
    op = stable_request_op(op, request_id)

    case apply_ops(
           socket,
           [Map.drop(op, ["if_rev", "request_id"])],
           request_id,
           op["if_rev"]
         ) do
      {:ok, socket, receipt, outcome} ->
        assign(socket, :last_save_result, %{
          saved: true,
          request_id: request_id,
          replayed: outcome == :replayed,
          rev: receipt.rev
        })

      {:error, socket} ->
        socket
    end
  end

  defp apply_unidentified_op(socket, op) do
    cond do
      not writable?(socket) ->
        refuse_save(socket, nil)

      not is_binary(socket.assigns[:slug]) ->
        socket

      revision(op["if_rev"]) == :error ->
        socket

      true ->
        {:ok, if_rev} = revision(op["if_rev"])

        socket.assigns.slug
        |> Content.apply_paper_block_op(
          Map.drop(op, ["if_rev", "request_id", @server_minted_block]),
          socket.assigns[:dataset],
          write_opts(socket) ++ [if_rev: if_rev]
        )
        |> handle_result(socket, nil)
    end
  end

  @doc """
  Apply an ORDERED batch of ops atomically through
  `Content.apply_paper_block_ops/4`. A non-list or empty batch is a quiet
  no-op, exactly as the Studio batch seam guards it.
  """
  def apply_ops(socket, ops) when is_list(ops) and ops != [] do
    cond do
      not writable?(socket) ->
        refuse(socket)

      not is_binary(socket.assigns[:slug]) ->
        socket

      true ->
        socket.assigns.slug
        |> Content.apply_paper_block_ops(
          ops,
          socket.assigns[:dataset],
          write_opts(socket)
        )
        |> handle_result(socket)
    end
  end

  def apply_ops(socket, _ops) do
    socket
    |> assign(:save_status, "Save failed")
    |> assign(:last_save_ok?, false)
  end

  @doc "Apply one request-identified canvas batch exactly once."
  def apply_ops(socket, ops, request_id, supplied_rev) do
    apply_ops(socket, ops, request_id, supplied_rev, {:ok, nil})
  end

  def apply_ops(socket, ops, request_id, supplied_rev, context_result) do
    paper = socket.assigns[:paper_doc]
    workspace_id = doc_field(paper, :workspace_id)
    slug = socket.assigns[:slug]
    assigns = fresh_authorization_assigns(socket.assigns)

    cond do
      not PaperViewer.can_edit?(assigns, workspace_id, slug) ->
        {:error, refuse_save(socket, request_id)}

      not (is_binary(slug) and is_list(ops) and ops != []) ->
        {:error, failed_save(socket, request_id)}

      revision(supplied_rev) == :error ->
        {:error, failed_save(socket, request_id)}

      not match?({:ok, _context}, context_result) ->
        {:error, failed_save(socket, request_id)}

      true ->
        {:ok, if_rev} = revision(supplied_rev)
        {:ok, context} = context_result

        opts =
          write_opts(socket) ++
            [if_rev: if_rev] ++ if(context, do: [canvas_run_context: context], else: [])

        # Slice 4: the exactly-once seam is the one the SHIPPED editor drives —
        # `bp-paper-editor-hooks.js` stamps a `request_id` on every mutation — so
        # the attribution opts belong here, not only on the unidentified legacy
        # seam below. `write_opts/1` is `ScopeHelpers.scope_opts/1` plus the
        # three things a reader edit owes history (`:caller_context`,
        # `:revision_action`, `:actor_user_id`); dropping to the bare scope here
        # would leave every real reader edit unattributed while the tests that
        # drive the legacy seam stayed green.
        case Content.apply_paper_block_ops_once(
               slug,
               ops,
               socket.assigns[:dataset],
               request_id,
               replay_principal_key(assigns),
               opts
             ) do
          {:ok, receipt, outcome} ->
            # One access row per ACCEPTED op, exactly as the legacy seam records
            # it in `handle_result/3`. A REPLAY changed nothing about the paper —
            # it is an acknowledgement of a write that already happened and
            # already has its row — so it does not write a second one.
            if outcome != :replayed, do: record_edit(socket)

            socket =
              socket
              |> sync()
              |> reconcile_canvas(request_id)
              |> assign(:save_status, "Auto-saved")
              |> assign(:last_save_ok?, true)
              |> assign(:paper_halt, nil)

            {:ok, socket, receipt, outcome}

          {:error, reason} ->
            {:error, handle_result({:error, reason}, socket, request_id)}
        end
    end
  end

  # ── the MVP editor events, each mapping to exactly ONE op ───────────────────

  @doc "Form submit / autosave on one block → a `patch-block` op."
  def edit_block(socket, %{"block_id" => id} = params) when is_binary(id) do
    case Blocks.validate_block_patch(block_by_id(socket, id), params) do
      {:ok, patch} ->
        apply_op(
          socket,
          write_meta(%{"op" => "patch-block", "id" => id, "patch" => patch}, params)
        )

      {:error, _reason} ->
        failed_save(socket, params["request_id"], :validation)
    end
  end

  def edit_block(socket, params), do: failed_save(socket, is_map(params) && params["request_id"])

  @doc "The `+ Add block` form → `insert-after` when anchored, else `append-block`."
  def add_block(socket, %{"block-type" => type} = params) when is_binary(type) do
    new = Blocks.default_block(type, Blocks.new_block_id())

    op =
      case params["after-id"] do
        after_id when is_binary(after_id) and after_id != "" ->
          %{"op" => "insert-after", "afterId" => after_id, "block" => new}

        _ ->
          %{"op" => "append-block", "block" => new}
      end

    apply_op(socket, write_meta(server_minted_block(op), params))
  end

  def add_block(socket, params), do: failed_save(socket, is_map(params) && params["request_id"])

  @doc """
  Delete one block → a `remove-block` op. A template-locked block is a calm
  no-op (its control is hidden; only a stale DOM or a crafted event gets here),
  mirroring the Studio handler rather than emitting a server-rejected op.
  """
  def delete_block(socket, %{"id" => id} = params) when is_binary(id) do
    if locked_block_id?(socket, id) do
      failed_save(socket, params["request_id"])
    else
      apply_op(socket, write_meta(%{"op" => "remove-block", "id" => id}, params))
    end
  end

  def delete_block(socket, params),
    do: failed_save(socket, is_map(params) && params["request_id"])

  @doc "The ▲/▼ controls → a top-level `move-block` op."
  def move_block(socket, %{"id" => id, "dir" => dir} = params) when is_binary(id) do
    blocks = socket.assigns[:edit_blocks] || []
    idx = Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)

    reorder(socket, blocks, idx, dir, params)
  end

  def move_block(socket, params), do: failed_save(socket, is_map(params) && params["request_id"])

  @doc """
  Drag-and-drop → the same `move-block` op the ▲/▼ buttons emit. A locked block
  never moves.
  """
  def move_block_to(socket, %{"id" => id} = params) when is_binary(id) do
    after_id =
      case params["after-id"] do
        a when is_binary(a) and a != "" -> a
        _ -> nil
      end

    if locked_block_id?(socket, id) do
      failed_save(socket, params["request_id"])
    else
      apply_op(
        socket,
        write_meta(%{"op" => "move-block", "id" => id, "after" => after_id}, params)
      )
    end
  end

  def move_block_to(socket, params),
    do: failed_save(socket, is_map(params) && params["request_id"])

  @doc "Refresh the canvas' display-only task previews and server-rendered block HTML."
  def refresh_canvas(socket) do
    if writable?(socket) do
      socket
      |> Shared.push_task_previews()
      |> Shared.push_block_renders()
      |> then(fn refreshed ->
        assign(refreshed, :task_previews, socket_task_previews(refreshed))
      end)
    else
      refuse(socket)
    end
  end

  @doc "Echo confirmed blocks and repaint display-only canvas content after a refetch."
  def reconcile_canvas(socket, request_id \\ nil) do
    if writable?(socket) and socket.assigns[:editing?] == true do
      socket
      |> SharedPaper.push_canvas_echo(request_id)
      |> refresh_canvas()
    else
      socket
    end
  end

  @doc "Materialize one supported optional template slot through the canonical op path."
  def materialize_slot(socket, %{"kind" => kind} = params) do
    case materialize_slot_block(kind) do
      nil ->
        failed_save(socket, params["request_id"])

      block ->
        op =
          case params["after"] do
            after_id when is_binary(after_id) and after_id != "" ->
              %{"op" => "insert-after", "afterId" => after_id, "block" => block}

            _ ->
              %{"op" => "append-block", "block" => block}
          end

        apply_op(socket, write_meta(server_minted_block(op), params))
    end
  end

  def materialize_slot(socket, params),
    do: failed_save(socket, is_map(params) && params["request_id"])

  @doc "Insert a slash-menu block after its anchor, or append it for a blank anchor."
  def slash_insert(socket, %{"type" => type} = params) when is_binary(type) do
    id = Blocks.new_block_id()

    block =
      type
      |> Blocks.default_block(id)
      |> maybe_put_field_name(params)
      |> maybe_merge_callout_shortcut(type, params)

    apply_op(
      socket,
      write_meta(server_minted_block(Shared.slash_insert_op(params["afterId"], block)), params)
    )
  end

  def slash_insert(socket, params),
    do: failed_save(socket, is_map(params) && params["request_id"])

  @doc "Persist a callout's native details fold state through one patch-block op."
  def callout_fold(socket, %{"block_id" => id} = params) when is_binary(id) do
    apply_op(
      socket,
      write_meta(
        %{
          "op" => "patch-block",
          "id" => id,
          "patch" => %{"collapsed" => Map.get(params, "collapsed") == true}
        },
        params
      )
    )
  end

  def callout_fold(socket, params),
    do: failed_save(socket, is_map(params) && params["request_id"])

  # ── buffer derivation ───────────────────────────────────────────────────────

  @doc """
  Re-read the paper through the reader's own scoped fetch and re-derive the
  editor buffer. Called after every accepted op.
  """
  def sync(socket) do
    paper =
      BarkparkWeb.BulldocsLive.fetch_paper(
        socket.assigns[:slug],
        socket.assigns[:reader_scope],
        socket.assigns[:dataset]
      )

    sync(socket, paper)
  end

  @doc "Re-derive the editor buffer from an already-loaded paper document."
  def sync(socket, paper) do
    socket
    |> assign(:edit_blocks, blocks_of(paper))
    |> assign(:paper_doc, paper)
    |> assign(:paper_rev, rev_of(paper))
    |> assign(:paper_link_details, paper_link_details(socket, paper))
  end

  @doc "Find a block by id anywhere in the editor buffer (recurses sections)."
  def block_by_id(socket, id) do
    Blocks.find_paper_block(socket.assigns[:edit_blocks] || [], id)
  end

  defp paper_link_details(socket, paper) do
    reader_scope = socket.assigns[:reader_scope] || []

    # Flat /papers routes have no URL scope. Preserve the same tenant boundary
    # as the reader after a save, using the freshly fetched Paper as authority.
    workspace_id =
      (paper && paper.workspace_id) || Keyword.get(reader_scope, :workspace_id) ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    scope = [
      workspace_id: workspace_id,
      project_id: (paper && paper.project_id) || Keyword.get(reader_scope, :project_id),
      published_only: true
    ]

    Content.Papers.resolve_paper_link_details(
      blocks_of(paper),
      socket.assigns[:dataset] || Content.paper_default_dataset(),
      scope
    )
  end

  # ── internals ───────────────────────────────────────────────────────────────

  @doc """
  The opts every reader write carries — edit-on-the-link slice 4
  (task-e99a8e946f80f52c).

  Three things on top of the tenant scope, and nothing else:

    * `:caller_context` — the one `ScopeHelpers.scope_opts/1` already produced,
      upgraded to the account principal when the socket has one, and stamped
      with the attribution actor. `PaperActor.caller_context/2` never
      downgrades and the actor never widens access; see its docs.
    * `:revision_action` — the OPT-IN that makes the op path write a version
      row at all. Block ops are keystroke-grade, so `Papers.BlockOps` writes
      history only for a caller that asks; the reader asks, because an edit
      arriving on a shared link is precisely the act that must be attributable.
    * `:actor_user_id` — the legacy single-column actor, kept in step with the
      new triple so `revisions.actor_user_id` does not go quiet for user edits.

  Public so a test can assert the shape without driving a whole LiveView.
  """
  def write_opts(socket) do
    scope = ScopeHelpers.scope_opts(socket)
    ctx = PaperActor.caller_context(scope, socket.assigns)

    scope
    |> Keyword.put(:caller_context, ctx)
    |> Keyword.put(:revision_action, @revision_action)
    |> Keyword.put(:actor_user_id, ctx.user_id)
  end

  # The ONLY write predicate. See the moduledoc: never Caps.write_capable?/2.
  defp writable?(socket), do: socket.assigns[:can_edit?] == true

  defp refuse(socket), do: put_flash(socket, :error, @denial)

  defp refuse_save(socket, request_id), do: socket |> refuse() |> failed_save(request_id)

  defp failed_save(socket, request_id, rejection \\ nil) do
    result = %{saved: false, request_id: request_id}

    result =
      if rejection == :validation,
        do: Map.merge(result, %{rejected: "validation", current_rev: socket.assigns[:paper_rev]}),
        else: result

    socket
    |> assign(:save_status, "Save failed")
    |> assign(:last_save_ok?, false)
    |> assign(:last_save_result, result)
  end

  # Connected item-share readers retain the signed mount session in the
  # PluginScopeSession liveness assign. Resolve its raw link again for EVERY
  # write so revocation/expiry is checked before an idempotency receipt lookup.
  defp fresh_authorization_assigns(assigns) do
    assigns
    |> refresh_api_token()
    |> refresh_item_share()
  end

  defp refresh_api_token(%{api_token: %{id: _}} = assigns) do
    case Map.get(assigns, :api_token_raw) do
      raw when is_binary(raw) and raw != "" ->
        case Auth.verify_token(raw) do
          {:ok, token} -> Map.put(assigns, :api_token, token)
          _ -> Map.put(assigns, :api_token, nil)
        end

      _ ->
        Map.put(assigns, :api_token, nil)
    end
  end

  defp refresh_api_token(assigns), do: assigns

  defp refresh_item_share(assigns) do
    case {Map.get(assigns, :paper_share_grant),
          get_in(assigns, [:__plugin_scope_session_share_liveness__, :session])} do
      {%{grant: :item}, session} when is_map(session) ->
        Map.put(assigns, :paper_share_grant, PaperViewer.resolve_share_grant(session))

      _ ->
        assigns
    end
  end

  defp replay_principal_key(%{current_user: %{id: id}}) when is_binary(id), do: "user:" <> id
  defp replay_principal_key(%{api_token: %{id: id}}) when is_binary(id), do: "token:" <> id

  defp replay_principal_key(%{paper_share_grant: %{id: id}}) when is_binary(id),
    do: "share:" <> id

  defp replay_principal_key(_assigns), do: nil

  defp doc_field(doc, field) when is_map(doc), do: Map.get(doc, field)
  defp doc_field(_doc, _field), do: nil

  defp handle_result(result, socket), do: handle_result(result, socket, nil)

  defp handle_result({:ok, result}, socket, request_id) do
    # Slice 4: one access row per ACCEPTED op. Rejected ops (a constraint veto,
    # a lifecycle halt, a stale rev) write nothing — the trail records what
    # happened to the paper, not what was attempted against it. Best-effort by
    # construction: `PaperAccess.record/1` always returns `:ok`, so a log the
    # database cannot take never costs the author her edit.
    record_edit(socket)

    socket
    |> sync()
    |> reconcile_canvas(request_id)
    |> assign(:save_status, "Auto-saved")
    |> assign(:last_save_ok?, true)
    |> assign(:last_save_result, %{saved: true, request_id: request_id, rev: result.rev})
    # A prior halt cleared: the next accepted edit dismisses the banner.
    |> assign(:paper_halt, nil)
  end

  # A constraint veto (pdd-t20) carries a human-readable reason — surface it so
  # a calmly-rejected edit explains itself.
  defp handle_result({:error, :precondition_failed}, socket, request_id) do
    socket = socket |> sync() |> reconcile_canvas(request_id)

    socket
    |> assign(:save_status, "Save failed")
    |> assign(:last_save_ok?, false)
    |> assign(:last_save_result, %{
      saved: false,
      request_id: request_id,
      conflict: true,
      current_rev: socket.assigns[:paper_rev]
    })
  end

  defp handle_result({:error, {:constraint, message, _op}}, socket, request_id) do
    socket
    |> put_flash(:error, constraint_flash(message))
    |> assign(:save_status, "Save failed")
    |> assign(:last_save_ok?, false)
    |> assign(:last_save_result, %{saved: false, request_id: request_id})
  end

  # A lifecycle-hook HALT. MIRROR the server truth verbatim; the reader authors
  # no copy of its own (the same D5/D6 stance the Studio editor holds).
  defp handle_result({:error, {:halted, reason}}, socket, request_id) do
    message = halt_reason(reason)

    socket
    |> assign(:paper_halt, message)
    |> put_flash(:error, message)
    |> assign(:save_status, "Save failed")
    |> assign(:last_save_ok?, false)
    |> assign(:last_save_result, %{saved: false, request_id: request_id})
  end

  defp handle_result({:error, _reason}, socket, request_id) do
    socket
    |> put_flash(:error, "Edit failed")
    |> assign(:save_status, "Save failed")
    |> assign(:last_save_ok?, false)
    |> assign(:last_save_result, %{saved: false, request_id: request_id})
  end

  defp revision(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp revision(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp revision(_), do: :error

  defp write_meta(op, params) do
    op
    |> Map.put("if_rev", params["if_rev"])
    |> Map.put("request_id", params["request_id"])
  end

  # Structural handlers mint block ids before they reach this seam. A lost
  # acknowledgement rebuilds that op on retry, so bind the minted id to the
  # stable request id before the exact-once facade fingerprints the payload.
  defp stable_request_op(%{@server_minted_block => true, "block" => %{} = block} = op, request_id) do
    op
    |> Map.delete(@server_minted_block)
    |> Map.put("block", Map.put(block, "id", request_block_id(request_id)))
  end

  defp stable_request_op(op, _request_id), do: Map.delete(op, @server_minted_block)

  defp server_minted_block(op), do: Map.put(op, @server_minted_block, true)

  defp request_block_id(request_id) do
    suffix =
      request_id
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 9)
      |> Base.url_encode64(padding: false)

    "b-" <> suffix
  end

  # ── slice 4 internals ───────────────────────────────────────────────────────

  # Flip this viewer's presence meta and re-materialise our own strip.
  #
  # `Presence.update/4` broadcasts a diff to the room, which every OTHER viewer
  # picks up in `BulldocsLive`'s `presence_diff` clause. We refresh our own
  # assign directly rather than wait for that diff to come back around, so the
  # editor sees her own dot immediately.
  defp update_presence_editing(socket, editing?) do
    topic = socket.assigns[:presence_topic]
    actor = socket.assigns[:paper_actor]

    if connected?(socket) and is_binary(topic) and is_map(actor) do
      Presence.update(self(), topic, PaperPresence.key(actor), fn meta ->
        Map.put(meta, :editing?, editing?)
      end)

      BarkparkWeb.BulldocsLive.refresh_paper_presence(socket)
    else
      socket
    end
  end

  # One `paper_access_log` row for an accepted edit, carrying the SAME actor the
  # revision was stamped with — the two surfaces cannot disagree about who did
  # it, because both read `socket.assigns.paper_actor`.
  defp record_edit(socket) do
    PaperAccess.record(
      PaperAccess.entry(
        socket.assigns[:slug],
        socket.assigns[:dataset],
        socket.assigns[:paper_workspace_id],
        "edit",
        socket.assigns[:paper_actor] || PaperActor.anonymous()
      )
    )
  end

  defp constraint_flash(message) when is_binary(message),
    do: "Edit rejected — " <> String.replace_prefix(message, "constraint: ", "")

  defp constraint_flash(_), do: "Edit failed"

  defp halt_reason(reason) when is_binary(reason) and reason != "", do: reason

  defp halt_reason(reason),
    do: "mutation vetoed by a plugin lifecycle hook: #{inspect(reason)}"

  # Reorder by swap, expressed as ONE move-block op — the Studio
  # `paper_reorder/4` shape, minus the pane assigns it reads.
  defp reorder(socket, _blocks, nil, _dir, params), do: failed_save(socket, params["request_id"])

  defp reorder(socket, blocks, idx, "up", params) when idx > 0 do
    moved = Enum.at(blocks, idx)
    displaced = Enum.at(blocks, idx - 1)

    if locked_block?(moved) or locked_block?(displaced) do
      failed_save(socket, params["request_id"])
    else
      after_id = if idx >= 2, do: Map.get(Enum.at(blocks, idx - 2), "id"), else: nil

      apply_op(
        socket,
        write_meta(
          %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => after_id},
          params
        )
      )
    end
  end

  defp reorder(socket, blocks, idx, "down", params) when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    displaced = Enum.at(blocks, idx + 1)

    if locked_block?(moved) or locked_block?(displaced) do
      failed_save(socket, params["request_id"])
    else
      apply_op(
        socket,
        write_meta(
          %{
            "op" => "move-block",
            "id" => Map.get(moved, "id"),
            "after" => Map.get(displaced, "id")
          },
          params
        )
      )
    end
  end

  defp reorder(socket, _blocks, _idx, _dir, params),
    do: failed_save(socket, params["request_id"])

  defp locked_block?(block), do: is_map(block) and Map.get(block, "locked") == true

  defp locked_block_id?(socket, id), do: socket |> block_by_id(id) |> locked_block?()

  defp socket_task_previews(socket), do: socket.assigns[:paper_task_previews] || %{}

  defp materialize_slot_block("featured") do
    %{
      "id" => Blocks.new_block_id(),
      "type" => "image",
      "role" => "featured",
      "locked" => true
    }
  end

  defp materialize_slot_block("ingress") do
    %{
      "id" => Blocks.new_block_id(),
      "type" => "paragraph",
      "role" => "ingress",
      "content" => []
    }
  end

  defp materialize_slot_block(_kind), do: nil

  defp maybe_put_field_name(block, %{"fieldName" => name})
       when is_binary(name) and name != "",
       do: Map.put(block, "fieldName", name)

  defp maybe_put_field_name(block, _params), do: block

  defp maybe_merge_callout_shortcut(block, "callout", params),
    do: Map.merge(block, Map.take(params, ["tone", "collapsible", "collapsed"]))

  defp maybe_merge_callout_shortcut(block, _type, _params), do: block

  defp blocks_of(%{content: %{"blocks" => blocks}}) when is_list(blocks), do: blocks
  defp blocks_of(_paper), do: []

  defp rev_of(%{content: content}) when is_map(content), do: Map.get(content, "rev") || 0
  defp rev_of(_paper), do: 0
end
