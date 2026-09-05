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

  ## Refused for now

  The gate covers the full Studio `paper-*` roster, but the reader WIRES only
  the MVP set: `paper-toggle-edit`, `paper-op`, `paper-ops`, `paper-edit-block`,
  `paper-block-autosave`, `paper-add-block`, `paper-delete-block`,
  `paper-move-block`, `paper-move-block-to`. The rest
  (`paper-materialize-slot`, `paper-slash-insert`, `paper-wikilink-search`,
  `paper-tag-search`, `paper-add-property`, `paper-unbind-property`,
  `paper-callout-fold`, `paper-valueref-inspect`, `paper-publish`) are listed
  so a denied socket is refused identically, and fall into the reader's calm
  unhandled-event log for a permitted one — they read Studio pane assigns
  (`:paper_doc`, `:editor_view`, an Expectation) the reader does not carry.

  ## State

  `:editing?`, `:edit_blocks` (the paper's TOP-LEVEL block list), `:paper_rev`,
  `:save_status`, `:paper_halt`, `:task_previews`. `sync/1` re-derives the
  blocks from storage after every accepted op; `BulldocsLive.refetch/1` calls
  `sync/2` so a broadcast-driven reload keeps the editor buffer honest.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Blocks

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
    |> assign(:paper_rev, rev_of(paper))
    |> assign(:save_status, "")
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
    if writable?(socket) do
      editing? = socket.assigns[:editing?] != true

      socket = assign(socket, :editing?, editing?)

      if editing?, do: sync(socket), else: socket
    else
      refuse(socket)
    end
  end

  # ── the ONE op path ─────────────────────────────────────────────────────────

  @doc """
  Apply ONE `DocPatchOp` through `Content.apply_paper_block_op/4`, with the
  socket's tenant scope. Same primitive, same result mapping as the Studio pane
  (`Studio.StudioLive.Shared.Paper.paper_pane_op/2`).
  """
  def apply_op(socket, %{"op" => _} = op) do
    cond do
      not writable?(socket) ->
        refuse(socket)

      not is_binary(socket.assigns[:slug]) ->
        socket

      true ->
        socket.assigns.slug
        |> Content.apply_paper_block_op(
          op,
          socket.assigns[:dataset],
          ScopeHelpers.scope_opts(socket)
        )
        |> handle_result(socket)
    end
  end

  def apply_op(socket, _op), do: socket

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
          ScopeHelpers.scope_opts(socket)
        )
        |> handle_result(socket)
    end
  end

  def apply_ops(socket, _ops), do: socket

  # ── the MVP editor events, each mapping to exactly ONE op ───────────────────

  @doc "Form submit / autosave on one block → a `patch-block` op."
  def edit_block(socket, %{"block_id" => id} = params) when is_binary(id) do
    patch = Blocks.build_block_patch(block_by_id(socket, id), params)

    apply_op(socket, %{"op" => "patch-block", "id" => id, "patch" => patch})
  end

  def edit_block(socket, _params), do: socket

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

    apply_op(socket, op)
  end

  def add_block(socket, _params), do: socket

  @doc """
  Delete one block → a `remove-block` op. A template-locked block is a calm
  no-op (its control is hidden; only a stale DOM or a crafted event gets here),
  mirroring the Studio handler rather than emitting a server-rejected op.
  """
  def delete_block(socket, %{"id" => id}) when is_binary(id) do
    if locked_block_id?(socket, id) do
      socket
    else
      apply_op(socket, %{"op" => "remove-block", "id" => id})
    end
  end

  def delete_block(socket, _params), do: socket

  @doc "The ▲/▼ controls → a top-level `move-block` op."
  def move_block(socket, %{"id" => id, "dir" => dir}) when is_binary(id) do
    blocks = socket.assigns[:edit_blocks] || []
    idx = Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)

    reorder(socket, blocks, idx, dir)
  end

  def move_block(socket, _params), do: socket

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
      socket
    else
      apply_op(socket, %{"op" => "move-block", "id" => id, "after" => after_id})
    end
  end

  def move_block_to(socket, _params), do: socket

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
    |> assign(:paper_rev, rev_of(paper))
  end

  @doc "Find a block by id anywhere in the editor buffer (recurses sections)."
  def block_by_id(socket, id) do
    Blocks.find_paper_block(socket.assigns[:edit_blocks] || [], id)
  end

  # ── internals ───────────────────────────────────────────────────────────────

  # The ONLY write predicate. See the moduledoc: never Caps.write_capable?/2.
  defp writable?(socket), do: socket.assigns[:can_edit?] == true

  defp refuse(socket), do: put_flash(socket, :error, @denial)

  defp handle_result({:ok, _result}, socket) do
    socket
    |> sync()
    |> assign(:save_status, "Auto-saved")
    # A prior halt cleared: the next accepted edit dismisses the banner.
    |> assign(:paper_halt, nil)
  end

  # A constraint veto (pdd-t20) carries a human-readable reason — surface it so
  # a calmly-rejected edit explains itself.
  defp handle_result({:error, {:constraint, message, _op}}, socket) do
    socket
    |> put_flash(:error, constraint_flash(message))
    |> assign(:save_status, "Save failed")
  end

  # A lifecycle-hook HALT. MIRROR the server truth verbatim; the reader authors
  # no copy of its own (the same D5/D6 stance the Studio editor holds).
  defp handle_result({:error, {:halted, reason}}, socket) do
    message = halt_reason(reason)

    socket
    |> assign(:paper_halt, message)
    |> put_flash(:error, message)
    |> assign(:save_status, "Save failed")
  end

  defp handle_result({:error, _reason}, socket) do
    socket
    |> put_flash(:error, "Edit failed")
    |> assign(:save_status, "Save failed")
  end

  defp constraint_flash(message) when is_binary(message),
    do: "Edit rejected — " <> String.replace_prefix(message, "constraint: ", "")

  defp constraint_flash(_), do: "Edit failed"

  defp halt_reason(reason) when is_binary(reason) and reason != "", do: reason

  defp halt_reason(reason),
    do: "mutation vetoed by a plugin lifecycle hook: #{inspect(reason)}"

  # Reorder by swap, expressed as ONE move-block op — the Studio
  # `paper_reorder/4` shape, minus the pane assigns it reads.
  defp reorder(socket, _blocks, nil, _dir), do: socket

  defp reorder(socket, blocks, idx, "up") when idx > 0 do
    moved = Enum.at(blocks, idx)
    displaced = Enum.at(blocks, idx - 1)

    if locked_block?(moved) or locked_block?(displaced) do
      socket
    else
      after_id = if idx >= 2, do: Map.get(Enum.at(blocks, idx - 2), "id"), else: nil

      apply_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => after_id})
    end
  end

  defp reorder(socket, blocks, idx, "down") when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    displaced = Enum.at(blocks, idx + 1)

    if locked_block?(moved) or locked_block?(displaced) do
      socket
    else
      apply_op(socket, %{
        "op" => "move-block",
        "id" => Map.get(moved, "id"),
        "after" => Map.get(displaced, "id")
      })
    end
  end

  defp reorder(socket, _blocks, _idx, _dir), do: socket

  defp locked_block?(block), do: is_map(block) and Map.get(block, "locked") == true

  defp locked_block_id?(socket, id), do: socket |> block_by_id(id) |> locked_block?()

  defp blocks_of(%{content: %{"blocks" => blocks}}) when is_list(blocks), do: blocks
  defp blocks_of(_paper), do: []

  defp rev_of(%{content: content}) when is_map(content), do: Map.get(content, "rev") || 0
  defp rev_of(_paper), do: 0
end
