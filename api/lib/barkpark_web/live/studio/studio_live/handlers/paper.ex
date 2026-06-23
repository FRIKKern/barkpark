defmodule BarkparkWeb.Studio.StudioLive.Handlers.Paper do
  @moduledoc """
  In-Studio paper block editor events (toggle/edit/autosave/add/delete/move) +
  the expectation-aware slash insert. Every editing event maps a form/button
  action to exactly ONE DocPatchOp through `Shared.paper_op/2`.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.{Blocks, Shared}

  def paper_toggle_edit(socket) do
    if socket.assigns[:editor_view] == :paper do
      next_edit_mode = !socket.assigns[:paper_edit_mode]

      socket = assign(socket, paper_edit_mode: next_edit_mode)

      socket =
        if next_edit_mode or not socket.assigns[:paper_block_mode] do
          socket
        else
          stream(
            socket,
            :paper_blocks,
            Shared.paper_stream_items(
              Shared.paper_top_level_blocks(socket),
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

  def paper_edit_block(%{"block_id" => id} = params, socket) do
    block = Shared.paper_block_by_id(socket, id)
    patch = Blocks.build_block_patch(block, params)
    {:noreply, Shared.paper_op(socket, %{"op" => "patch-block", "id" => id, "patch" => patch})}
  end

  def paper_block_autosave(%{"block_id" => id} = params, socket) do
    block = Shared.paper_block_by_id(socket, id)
    patch = Blocks.build_block_patch(block, params)

    socket =
      socket
      |> Shared.paper_op(%{"op" => "patch-block", "id" => id, "patch" => patch})
      |> assign(save_status: "Auto-saved")

    {:noreply, socket}
  end

  def paper_block_autosave(_params, socket), do: {:noreply, socket}

  def paper_op(%{"op" => _} = op, socket) do
    {:noreply, Shared.paper_op(socket, op)}
  end

  def paper_add_block(%{"block-type" => type} = params, socket) do
    new = Blocks.default_block(type, Blocks.new_block_id())

    op =
      case params["after-id"] do
        after_id when is_binary(after_id) and after_id != "" ->
          %{"op" => "insert-after", "afterId" => after_id, "block" => new}

        _ ->
          %{"op" => "append-block", "block" => new}
      end

    {:noreply, Shared.paper_op(socket, op)}
  end

  def paper_slash_insert(%{"type" => type, "fieldName" => fname} = params, socket)
      when is_binary(fname) and fname != "" do
    if Shared.expected_field_blocked?(socket, fname) do
      {:noreply, put_flash(socket, :error, "That field is already at its limit.")}
    else
      new = Map.put(Blocks.default_block(type, Blocks.new_block_id()), "fieldName", fname)
      {:noreply, Shared.paper_op(socket, Shared.slash_insert_op(params["afterId"], new))}
    end
  end

  def paper_slash_insert(%{"type" => type} = params, socket) do
    new = Blocks.default_block(type, Blocks.new_block_id())
    {:noreply, Shared.paper_op(socket, Shared.slash_insert_op(params["afterId"], new))}
  end

  def paper_delete_block(%{"id" => id}, socket) do
    {:noreply, Shared.paper_op(socket, %{"op" => "remove-block", "id" => id})}
  end

  def paper_move_block(%{"id" => id, "dir" => dir}, socket) do
    blocks = Shared.paper_top_level_blocks(socket)
    idx = Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)

    {:noreply, Shared.paper_reorder(socket, blocks, idx, dir)}
  end

  def paper_move_block_to(%{"id" => id} = params, socket) do
    after_id =
      case params["after-id"] do
        a when is_binary(a) and a != "" -> a
        _ -> nil
      end

    {:noreply, Shared.paper_op(socket, %{"op" => "move-block", "id" => id, "after" => after_id})}
  end
end
