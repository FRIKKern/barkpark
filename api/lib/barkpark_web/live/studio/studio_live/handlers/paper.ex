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
  alias Barkpark.Content.Papers.ValueWriteback
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.{Blocks, Shared}

  def paper_toggle_edit(socket) do
    if socket.assigns[:editor_view] == :paper do
      next_edit_mode = !socket.assigns[:paper_edit_mode]

      socket = assign(socket, paper_edit_mode: next_edit_mode)

      socket =
        if next_edit_mode or not socket.assigns[:paper_block_mode] do
          # t9: entering Edit — refresh the live task-block previews so the
          # boundary widgets paint CURRENT rows, not the rows from paper-open.
          # No-op when the canvas flag is OFF; display-only either way (D5).
          Shared.push_task_previews(socket)
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
      Shared.paper_op(socket, %{"op" => "patch-block", "id" => id, "patch" => patch})

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

  @doc """
  t9 — LIVE TASK-BLOCK PREVIEW refresh. The canvas hook fires this on mount (seed
  the live rows the instant the editor opens) and again ~500ms-debounced after an
  edit that may have changed a task block's `query`. We re-run the resolver under
  the session scope and push fresh id-keyed rows on the `bp:task-preview` channel.

  Read-only: never writes, never touches the save baseline (D5) — a pure display
  refresh. No-op when the canvas flag is OFF (Shared.push_task_previews gates it).
  """
  def task_preview_refresh(socket) do
    {:noreply, Shared.push_task_previews(socket)}
  end

  @doc """
  ACCEPT-BASELINE (lvw-t2, D4 ratified): the walker-emitted control on a
  DRIFTED valueref clicks through to here carrying the node's identity
  (target/field) + its CURRENT pinned fallback. Delegates to
  `Content.accept_valueref_baseline/6` — an ifRev-guarded (`:if_rev` = the
  rev this view rendered at), fallback-ONLY patch-block batch with provenance
  (revision action `valueref-accept-baseline` + this session's user as
  actor). Authorization is write access to the HOSTING paper — the exact same
  path every other Studio paper block op takes; the canonical TARGET is never
  written (edit-through is lvw-t10, not this control).

  A rev race (`:precondition_failed`) surfaces as a RETRY-ABLE flash: the
  refetch re-renders the view at the current rev, so the control (if still
  drifted) is immediately clickable again.
  """
  def valueref_accept_baseline(
        %{"target" => target, "field" => field, "fallback" => fallback},
        socket
      )
      when is_binary(target) and is_binary(field) and is_binary(fallback) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id

    if is_nil(slug) do
      {:noreply, socket}
    else
      opts =
        [
          if_rev: socket.assigns[:paper_rev],
          actor_user_id: socket.assigns[:user_id]
        ] ++ ScopeHelpers.scope_opts(socket)

      case Content.accept_valueref_baseline(
             slug,
             target,
             field,
             fallback,
             socket.assigns.dataset,
             opts
           ) do
        {:ok, _receipt} ->
          {:noreply,
           socket
           |> Shared.refetch_paper()
           |> put_flash(:info, "Baseline accepted — pinned literal updated to the current value")}

        {:error, :precondition_failed} ->
          {:noreply,
           socket
           |> Shared.refetch_paper()
           |> put_flash(:error, "Paper changed since this view — re-rendered, retry the accept")}

        {:error, :not_drifted} ->
          {:noreply,
           socket
           |> Shared.refetch_paper()
           |> put_flash(:info, "Baseline already matches the current value")}

        {:error, :dangling} ->
          {:noreply,
           put_flash(socket, :error, "Value is unresolvable (dangling) — no baseline to accept")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Accept baseline failed")}
      end
    end
  end

  def valueref_accept_baseline(_params, socket), do: {:noreply, socket}

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
    # pdd-t2: a template-locked block can't be deleted. The controls are hidden
    # / disabled, so this only fires from a stale DOM or a crafted event — keep
    # it a calm no-op rather than a server-rejected op + error flash.
    if locked_block_id?(socket, id) do
      {:noreply, socket}
    else
      {:noreply, Shared.paper_op(socket, %{"op" => "remove-block", "id" => id})}
    end
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

    # pdd-t2: template-locked blocks hold their positions under drag-and-drop.
    # A locked block is never dragged (its grip is inert) — a stale/crafted
    # event is a calm no-op. A drop that would land an UNLOCKED block inside
    # the locked prefix (above the title, or between title and featured) CLAMPS
    # to directly below the last locked block — the block lands as close as
    # allowed instead of the move erroring out server-side.
    blocks = Shared.paper_top_level_blocks(socket)
    locked_prefix = Enum.take_while(blocks, &(Map.get(&1, "locked") == true))

    cond do
      locked_block_id?(socket, id) ->
        {:noreply, socket}

      locked_prefix != [] ->
        last_locked_id = locked_prefix |> List.last() |> Map.get("id")
        locked_ids = MapSet.new(locked_prefix, &Map.get(&1, "id"))

        after_id =
          if after_id == nil or
               (MapSet.member?(locked_ids, after_id) and after_id != last_locked_id),
             do: last_locked_id,
             else: after_id

        {:noreply,
         Shared.paper_op(socket, %{"op" => "move-block", "id" => id, "after" => after_id})}

      true ->
        {:noreply,
         Shared.paper_op(socket, %{"op" => "move-block", "id" => id, "after" => after_id})}
    end
  end

  # pdd-t2: whether the top-level block `id` is template-locked.
  defp locked_block_id?(socket, id) do
    socket
    |> Shared.paper_top_level_blocks()
    |> Enum.any?(fn b -> Map.get(b, "id") == id and Map.get(b, "locked") == true end)
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

  # ── valueref edit-through (lvw-t10, writeback v1.5) ────────────────────────

  @doc """
  Open the shared-value inspector for a clicked valueref (view-mode click
  delegated by the `BarkparkValuerefInspect` hook). The SERVER decides the
  affordance: `ValueWriteback.inspect_target/4` authorizes against the TARGET
  canonical doc under the caller's own scope opts — an unauthorized or
  cross-scope target yields `authorized: false` and the panel renders with NO
  write control at all (and `valueref_writeback/2` below re-checks anyway;
  the hidden control is UX, the module is the boundary).
  """
  def valueref_inspect(%{"target" => target, "field" => field}, socket)
      when is_binary(target) and is_binary(field) do
    opts = Shared.hook_opts(socket)
    dataset = socket.assigns.dataset

    panel =
      case ValueWriteback.inspect_target(target, field, dataset, opts) do
        {:ok, info} ->
          info
          |> Map.take([:doc_id, :type, :rev, :title, :current_value, :impact])
          |> Map.merge(%{target: target, field: field, authorized: true, error: nil})

        {:error, _} ->
          %{target: target, field: field, authorized: false, error: nil}
      end

    {:noreply, assign(socket, valueref_panel: panel)}
  end

  def valueref_inspect(_params, socket), do: {:noreply, socket}

  @doc """
  Confirm the edit-through. ONLY the value comes from the client — target,
  field and the CAS rev are the server-held panel state captured at inspect
  time, so a hostile payload cannot smuggle a different target past the
  inspection. `ValueWriteback.writeback/6` re-derives the FULL authorization
  server-side; without an authorized open panel this event is a no-op.
  """
  def valueref_writeback(%{"value" => value}, socket) do
    case socket.assigns[:valueref_panel] do
      %{authorized: true, target: target, field: field, rev: rev} = panel ->
        opts = Shared.hook_opts(socket)
        dataset = socket.assigns.dataset

        case ValueWriteback.writeback(target, field, value, rev, dataset, opts) do
          {:ok, %{impact: impact}} ->
            {:noreply,
             socket
             |> assign(valueref_panel: nil)
             |> refresh_paper_values()
             |> put_flash(
               :info,
               "Canonical value written to #{target} — changes #{impact.count} doc(s)"
             )}

          {:error, {:rev_mismatch, _}} ->
            {:noreply,
             assign(socket,
               valueref_panel:
                 Map.put(
                   panel,
                   :error,
                   "The canonical value changed while you were editing — close and reopen to see the current value."
                 )
             )}

          {:error, :unauthorized} ->
            {:noreply,
             assign(socket, valueref_panel: Map.merge(panel, %{authorized: false, error: nil}))}

          {:error, _} ->
            {:noreply,
             assign(socket, valueref_panel: Map.put(panel, :error, "The write was rejected."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def valueref_writeback(_params, socket), do: {:noreply, socket}

  @doc "Close the shared-value inspector."
  def valueref_close(socket), do: {:noreply, assign(socket, valueref_panel: nil)}

  # Re-stream the view-mode blocks so the freshly written canonical value
  # renders in place of the old one (valuerefs resolve per render, not live).
  defp refresh_paper_values(socket) do
    if socket.assigns[:paper_block_mode] && !socket.assigns[:paper_edit_mode] do
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
    else
      socket
    end
  end
end
