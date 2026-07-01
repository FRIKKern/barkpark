defmodule BarkparkWeb.Studio.StudioLive.Handlers.Paper do
  @moduledoc """
  In-Studio paper block editor events (toggle/edit/autosave/add/delete/move) +
  the expectation-aware slash insert. Every editing event maps a form/button
  action to exactly ONE DocPatchOp through `Shared.paper_op/2`.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
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

  # Persist a callout's native <details> fold state. The JS hook
  # (BarkparkCalloutFold) sends the post-toggle `collapsed` bool keyed by
  # `block_id`. Emits exactly ONE patch-block op via Shared.paper_op/2 so the
  # View pane re-streams with the new `open`. compose.ex threads `collapsed`
  # in :article only (maybe_put_true drops false → an expanded callout stays
  # byte-identical), so writing collapsed:false equals absent (expanded).
  def paper_callout_fold(%{"block_id" => id} = params, socket) do
    collapsed = Map.get(params, "collapsed") == true

    {:noreply,
     Shared.paper_op(socket, %{
       "op" => "patch-block",
       "id" => id,
       "patch" => %{"collapsed" => collapsed}
     })}
  end

  @doc """
  Collapse / expand the backlinks panel. Pure assign flip — no re-query (the
  list was loaded once in `Shared.setup_paper_view/2`).
  """
  def backlinks_toggle(socket) do
    {:noreply, assign(socket, backlinks_open: !socket.assigns[:backlinks_open])}
  end

  @doc """
  Re-run the inbound-reference load for the currently-open paper. Read-only;
  no-ops (preserving the existing lists) when no paper is open.
  """
  def backlinks_refresh(socket) do
    case socket.assigns[:paper_doc] do
      %{} = paper ->
        {used_by, linked, unlinked} = Shared.load_backlinks(socket, paper)

        {:noreply,
         assign(socket,
           backlinks_used_by: used_by,
           backlinks_linked: linked,
           backlinks_unlinked: unlinked
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Open a backlink source in-pane via the reserved ["open", type, id] nav path
  (PaneBuilder.walk_path resolves it with no structure lookup; handle_params
  rebuilds the editor, no remount). Blank/nil slug or type is a no-op.
  """
  def open_backlink(%{"slug" => slug, "type" => type}, socket)
      when is_binary(slug) and slug != "" and is_binary(type) and type != "" do
    {:noreply,
     push_patch(socket,
       to: Shared.studio_path(socket, ["open", type, slug], socket.assigns.dataset)
     )}
  end

  def open_backlink(_params, socket), do: {:noreply, socket}

  def paper_op(%{"op" => _} = op, socket) do
    {:noreply, Shared.paper_op(socket, op)}
  end

  # Phase-4 S2: a <bp-paper-canvas> run emits an ORDERED op array (bp-canvas-ops);
  # the BarkparkPaperCanvas hook forwards it as `paper-ops` {ops:[…]}. Fold the
  # whole batch through the SAME Patch.apply_patches + persist path the per-block
  # paper-op uses (Shared.paper_ops → Content.apply_paper_block_ops). A non-list
  # or empty `ops` is a quiet no-op (guarded in Shared.paper_ops/2).
  def paper_ops(%{"ops" => ops}, socket) do
    {:noreply, Shared.paper_ops(socket, ops)}
  end

  def paper_ops(_params, socket), do: {:noreply, socket}

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

  # Shorthand-inserted callout carries tone + collapsible/collapsed from the
  # `> [!type]` gesture; merge them onto the seeded default block. Ordered ABOVE
  # the generic clause (a more specific head must match first).
  def paper_slash_insert(%{"type" => "callout"} = params, socket) do
    id = Blocks.new_block_id()

    new =
      "callout"
      |> Blocks.default_block(id)
      |> Map.merge(Map.take(params, ["tone", "collapsible", "collapsed"]))

    {:noreply, Shared.paper_op(socket, Shared.slash_insert_op(params["afterId"], new))}
  end

  def paper_slash_insert(%{"type" => type} = params, socket) do
    new = Blocks.default_block(type, Blocks.new_block_id())
    {:noreply, Shared.paper_op(socket, Shared.slash_insert_op(params["afterId"], new))}
  end

  def paper_delete_block(%{"id" => id}, socket) do
    {:noreply, Shared.paper_op(socket, %{"op" => "remove-block", "id" => id})}
  end

  @doc """
  Bind an as-yet-unbound expected field: create a default block of the field's
  type, stamp its fieldName + label, and append — ONE op via Shared.paper_op
  (the paper_slash_insert pattern). projection.ex then re-projects content[name].
  """
  def paper_add_property(%{"fieldName" => fname} = _params, socket)
      when is_binary(fname) and fname != "" do
    cond do
      Shared.expected_field_blocked?(socket, fname) ->
        {:noreply, put_flash(socket, :error, "That field is already at its limit.")}

      true ->
        case Enum.find(Shared.paper_all_descriptors(socket), fn d -> d.name == fname end) do
          %{type: type, label: label} ->
            new =
              Blocks.default_block(type, Blocks.new_block_id())
              |> Map.put("fieldName", fname)
              |> Map.put("label", label)

            {:noreply, Shared.paper_op(socket, Shared.slash_insert_op(nil, new))}

          _ ->
            {:noreply, put_flash(socket, :error, "Unknown property.")}
        end
    end
  end

  def paper_add_property(_params, socket), do: {:noreply, socket}

  @doc """
  Unbind a property: patch-block clearing fieldName so the block becomes FREE
  (joins content["body"]). project/4 then drops the orphaned content[fieldName].
  """
  def paper_unbind_property(%{"id" => id}, socket) when is_binary(id) and id != "" do
    {:noreply,
     Shared.paper_op(socket, %{
       "op" => "patch-block",
       "id" => id,
       "patch" => %{"fieldName" => nil}
     })}
  end

  def paper_unbind_property(_params, socket), do: {:noreply, socket}

  def paper_move_block(%{"id" => id, "dir" => dir}, socket) do
    # Match the displayed body order: the Properties panel renders FREE-only
    # blocks when it is active (Beta with expected fields); otherwise the body
    # shows ALL blocks (paper pane). Gate the same way so move-index never drifts.
    blocks =
      if Shared.paper_all_descriptors(socket) == [],
        do: Shared.paper_top_level_blocks(socket),
        else: Shared.paper_top_level_free(socket)

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

  @doc """
  Typeahead candidate search for the [[ wikilink autocomplete popup.

  Blank query or query exceeding 100 chars → empty result (short-circuit
  before hitting the DB). Otherwise delegates to `Content.search_papers/3`
  (which is already capped at 20 results) using the same dataset + scope
  that every other paper handler reads from socket assigns.

  Returns `{:reply, %{results: [%{title, id, type}]}, socket}` — LiveView
  forwards the map to the client's pushEvent callback, which resolves the
  Promise exposed on `el.wikilinkSource`.
  """
  def paper_wikilink_search(q, socket)
      when not is_binary(q) or byte_size(q) == 0 or byte_size(q) > 100 do
    {:reply, %{results: []}, socket}
  end

  def paper_wikilink_search(q, socket) do
    dataset = socket.assigns.dataset
    opts = ScopeHelpers.scope_opts(socket)

    results =
      Content.search_papers(q, dataset, opts)
      |> Enum.map(fn %{id: id, title: title} ->
        %{title: title, id: to_string(id), type: "paper"}
      end)

    {:reply, %{results: results}, socket}
  end

  @doc """
  Typeahead candidate search for the `#tag` autocomplete popup — the tag-name
  sibling of `paper_wikilink_search/2`.

  Blank query or query exceeding 100 chars → empty result (short-circuit
  before hitting the DB). The `#tag` trigger (parseOpenTag) only fires once the
  query contains a letter, so a blank `q` never arrives from the editor — this
  guard is defensive for malformed input, NOT the "top distinct tags" discovery
  path that `Content.search_tags/3` itself offers on a blank query. Otherwise
  delegates to `Content.search_tags/3` (DISTINCT tag names, capped at 20) using
  the same dataset + scope that every other paper handler reads from socket
  assigns.

  Returns `{:reply, %{results: ["design", "obsidian", …]}, socket}` — plain
  strings, which the client's pushEvent callback resolves onto the Promise
  exposed by `el.tagSource`.
  """
  def paper_tag_search(q, socket)
      when not is_binary(q) or byte_size(q) == 0 or byte_size(q) > 100 do
    {:reply, %{results: []}, socket}
  end

  def paper_tag_search(q, socket) do
    dataset = socket.assigns.dataset
    opts = ScopeHelpers.scope_opts(socket)

    results = Content.search_tags(q, dataset, opts)

    {:reply, %{results: results}, socket}
  end
end
