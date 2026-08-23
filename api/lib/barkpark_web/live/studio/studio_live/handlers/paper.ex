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
  alias BarkparkWeb.Studio.StudioLive.{Blocks, PaperCanvas, Shared}

  def paper_toggle_edit(socket) do
    if socket.assigns[:editor_view] == :paper do
      next_edit_mode = !socket.assigns[:paper_edit_mode]

      socket = assign(socket, paper_edit_mode: next_edit_mode)

      socket =
        if next_edit_mode or not socket.assigns[:paper_block_mode] do
          # t9: entering Edit — refresh the live task-block previews so the
          # boundary widgets paint CURRENT rows, not the rows from paper-open.
          # No-op when the canvas flag is OFF; display-only either way (D5).
          # pdd-t8: the fleet-in-canvas paint (bp:block-html) rides the same
          # refresh — every push site pairs the two channels.
          socket |> Shared.push_task_previews() |> Shared.push_block_renders()
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

  # ── t6: WordPress-style metadata sidebar (doctrine Rule 4/5) ────────────────
  #
  # All three are PURE assign flips — none call `Shared.paper_op/2` or the block
  # stream, so a sidebar interaction can never emit a body block op. Nothing in
  # the sidebar persists yet BY DESIGN: the slug change is validate-only
  # (uniqueness/rename mutates doc_id — t5's migrate concern), and publish state
  # is read-only display (papers publish in place; the twin-row doc publish/
  # unpublish path would fail or strand the paper — see the Publish section
  # comment in `Components.paper_metadata_sidebar/1`). When a sidebar field DOES
  # persist, it rides `PaperCanvas.sidebar_meta_op/2`'s `{:doc_field, …}` shape,
  # NEVER the block pipeline.

  @doc """
  Collapse / expand the whole metadata sidebar. Pure assign flip, plus the
  explicit-open marker the bucket-aware first-paint default reads (charter D91).

  Two assigns move together and mean different things. `sidebar_open` is what
  the SERVER holds. `sidebar_user_opened` is whether the user asked for it —
  the one input the server can supply without knowing the viewport, and the one
  the `html:not([data-width-bucket="wide"]) … :not([data-user-opened])` rule in
  root.html.heex yields to. Below `wide` the desk PAINTS the inspector closed
  while `sidebar_open` still says true; that gap is deliberate and is precisely
  what keeps D12's ~400ms flash from ever opening.

  Which leaves one thing the flip has to get right: in that painted-closed
  state the panel the user is looking at is CLOSED, so a click means OPEN, not
  "toggle the assign". Resolving it reads `width_bucket` — the socket assign the
  WidthBucket hook reconciles after connect. That is safe here and nowhere else
  in this feature: a click happens long after connect, and it paints nothing
  before the user acts, so consulting it costs no first-paint correctness. It
  defaults to `wide` (mount's seed), which is also the conservative answer —
  an unknown bucket behaves exactly as this handler always has.
  """
  # ── D179 — THE DISMISS IS NOT NAVIGATION, AND THAT IS RULED, NOT DEFAULTED ──
  #
  # At `narrow` and `phone` a user-summoned inspector paints as a FULL-SCREEN
  # DESTINATION (the wave-10 geometry: `position:absolute; inset:0` over an
  # opaque surface), and #5014 gave it the vocabulary of one — an arrow-left,
  # a header that names the document, and a crumb trail whose last segment is
  # the inspector itself. This handler is nonetheless a PURE ASSIGN: no
  # `push_patch`, no `push_navigate`, no pushState anywhere in the chain. So
  # browser Back from that destination does not close the inspector — it
  # leaves the Studio entirely.
  #
  # The asymmetry is sharpest against the SIBLING control rendered beside it:
  # a pane crumb fires `expand-pane`, which DOES `push_patch`
  # (Handlers.Scope.expand_pane/2, scope.ex:175-178). Two adjacent controls in
  # one trail, one history-bearing and one not.
  #
  # RULED (b) — keep the affordance, keep the click non-navigational, record
  # why here, and lock it. The alternatives were refused with reasons, not
  # forgotten:
  #
  #   (a) a URL-borne sidebar param. The URL grammar carries only
  #       dataset / path / desk, and `append_desk_query/2`
  #       (studio_live/paths.ex:86) is the ONLY query writer — so a sidebar
  #       param has to be designed against `?desk=` preservation AND against
  #       `expand-pane`'s own push_patch, which knows nothing about
  #       `sidebar_user_opened` and would silently drop the param on every
  #       crumb click. That is a design task, not a line change.
  #   (c) drop the destination vocabulary. That unwinds #5014's merged, tested
  #       Tier-3 exit; a full-screen state with no way out is the worse lie.
  #
  # Locked in `studio_live_navigational_truth_test.exs`: dismissing at Tier 3
  # emits NO patch and NO navigate, with the `expand-pane` crumb standing as
  # the contrast control that proves the refutation is able to fail.
  #
  # SCOPE: measured on a 2-segment paper path only (see the same caveat on
  # `PaneBuilder.display_state/5`); deeper nav depth is filed separately.
  def sidebar_toggle_panel(socket) do
    open? = socket.assigns[:sidebar_open] == true
    asked? = socket.assigns[:sidebar_user_opened] == true
    wide? = socket.assigns[:width_bucket] in [nil, "wide"]

    painted_closed? = open? and not asked? and not wide?
    next_open? = if painted_closed?, do: true, else: not open?

    {:noreply, assign(socket, sidebar_open: next_open?, sidebar_user_opened: next_open?)}
  end

  @doc """
  Collapse / expand ONE sidebar section, toggling its key in the
  `sidebar_collapsed` MapSet. Pure assign — the canvas body is never touched.
  """
  def sidebar_toggle_section(%{"section" => key}, socket) when is_binary(key) do
    next = PaperCanvas.toggle_section(socket.assigns[:sidebar_collapsed], key)
    {:noreply, assign(socket, sidebar_collapsed: next)}
  end

  def sidebar_toggle_section(_params, socket), do: {:noreply, socket}

  @doc """
  Live slug format validation on every keystroke. Assigns the draft value + a
  `{tone, message}` verdict from `PaperCanvas.slug_feedback/1` — a PURE, DB-free
  format check. It emits NO block op (Rule 4: a sidebar edit must not touch
  blocks); persisting a rename is deliberately out of this validate-only path.
  """
  def sidebar_slug_change(%{"value" => value}, socket) when is_binary(value) do
    {:noreply,
     assign(socket,
       sidebar_slug_draft: value,
       sidebar_slug_feedback: PaperCanvas.slug_feedback(value)
     )}
  end

  def sidebar_slug_change(_params, socket), do: {:noreply, socket}

  @doc """
  spd-bl-publish-affordance-triple — the sidebar's description field. Persists
  `content["description"]` on the DRAFT row through the shared meta-write guard
  ladder in `Shared.Paper.paper_meta_write/2` (draft-only, rev-fenced).
  """
  def sidebar_description_change(%{"value" => value}, socket) when is_binary(value),
    do: {:noreply, Shared.sidebar_description_change(socket, value)}

  def sidebar_description_change(_params, socket), do: {:noreply, socket}

  @doc """
  spd-bl-publish-affordance-triple — the Labels section's add form. Appends one
  complete weighted-tag entry (tag, strength 1–100, rationale) to
  `content["tags"]`; field floors mirror the publish wall's own entry rules.
  """
  def sidebar_label_add(params, socket), do: {:noreply, Shared.sidebar_label_add(socket, params)}

  @doc """
  spd-bl-publish-affordance-triple — the paper pane's Publish control. Drives
  the untouched publish wall (`Content.publish_document/4`) and surfaces each
  refusal in plain language.
  """
  def paper_publish(socket), do: {:noreply, Shared.paper_publish(socket)}

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
    # pdd-t8: the SAME mount/debounce trigger also (re)paints the fleet-in-canvas
    # blocks (bp:block-html) so a query edit re-resolves the board AND its canvas
    # paint in one round-trip. Both are display-only, D5-safe.
    {:noreply, socket |> Shared.push_task_previews() |> Shared.push_block_renders()}
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

  @doc """
  pdd-t20c: MATERIALIZE an optional ghost slot. The editor offers each absent
  optional declaration (featured / ingress) as a calm ghost in its enforced place;
  a click sends `paper-materialize-slot` with the slot `kind` + the `after` anchor
  block id (the locked title). We mint the real block for that kind and insert it
  DIRECTLY AFTER the anchor via the ONE op path — so it lands in its enforced
  position and rides the client veto's programmatic-apply exemption. The ghost is
  only offered when this insert is save-safe (`ghost_slots/1` gates on
  non-displacement), so the server ACCEPTS it — never a save error (rule 5). An
  unknown kind / missing anchor is a calm no-op.
  """
  def paper_materialize_slot(%{"kind" => kind} = params, socket) do
    case materialize_slot_block(kind) do
      nil ->
        {:noreply, socket}

      block ->
        op =
          case params["after"] do
            after_id when is_binary(after_id) and after_id != "" ->
              %{"op" => "insert-after", "afterId" => after_id, "block" => block}

            _ ->
              %{"op" => "append-block", "block" => block}
          end

        {:noreply, Shared.paper_op(socket, op)}
    end
  end

  def paper_materialize_slot(_params, socket), do: {:noreply, socket}

  # The block a ghost slot materializes. Featured is a locked role:featured image
  # (the seeded featured block, now birthed on demand); ingress is an unlocked
  # role:ingress paragraph. Both carry the role the reader + template validate key
  # on. Unknown kinds mint nothing.
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

  defp materialize_slot_block(_), do: nil

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

          # The canonical-value writeback publishes the owning doc; a publish-wall
          # rejection (authoring-excellence D14/D23) must RENDER its field/rule/fix,
          # not degrade to the content-free "The write was rejected." Unwrap the
          # walled reason so `format_wall_details` renders the documentation-grade
          # detail (a `{:label_spine, details}` tuple carries the details one level
          # in); anything else falls through its generic inspect fallback.
          {:error, {:publish_failed, reason}} ->
            {:noreply,
             assign(socket,
               valueref_panel:
                 Map.put(
                   panel,
                   :error,
                   "Publish blocked — " <> Shared.format_wall_details(wall_reason(reason))
                 )
             )}

          {:error, _} ->
            {:noreply,
             assign(socket, valueref_panel: Map.put(panel, :error, "The write was rejected."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def valueref_writeback(_params, socket), do: {:noreply, socket}

  # Unwrap a wrapped wall reason (`{:label_spine, details}`, `{:unknown_tag,
  # payload}`, …) to the inner detail so `Shared.format_wall_details/1` renders
  # its documentation-grade field/rule/fix line. Any OTHER 2-tuple (e.g. a
  # non-wall `{:rev_mismatch, detail}`) unwraps too — harmless: its detail
  # lands in `format_wall_details`' generic inspect fallback. A bare
  # (non-tuple) reason passes straight through to the same fallback.
  defp wall_reason({_code, detail}), do: detail
  defp wall_reason(other), do: other

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
