defmodule BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle do
  @moduledoc """
  handle_info/2 bodies + handle_params finishing for StudioLive.

  Thin routing heads stay on StudioLive (Phoenix dispatch); the bodies — which
  thread `socket` through `Shared` — live here. Behaviour-preserving.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PresenceState
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper
  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, Shared}

  # `current_path` is NOT set here — `BarkparkWeb.StudioChrome`'s
  # `:handle_params` hook is the single producer (it runs before this
  # callback, deriving current_path from `uri` for every studio-layout
  # surface), so `uri` is unused in this body now.
  def finish_handle_params(socket, dataset, path, desk, _uri, params) do
    socket =
      socket
      |> Shared.ensure_list_subscription(dataset)
      |> Shared.ensure_presence_subscription()

    socket =
      socket
      |> assign(
        dataset: dataset,
        nav_path: path,
        nav_desk: desk
      )
      |> Shared.maybe_open_shares(params)
      |> Shared.rebuild_panes()
      |> Shared.assign_page_title()
      |> Shared.subscribe_to_doc()
      |> Shared.track_presence()
      # Navigating (re)loads the editor from the DB, so the buffer is clean:
      # clear the dirty flag, any stale concurrent-edit banner, and the
      # touched-path set (`Handlers.Fields`) — a path touched on the previous
      # document must not license folding an empty value on the next one.
      |> assign(
        editor_dirty: false,
        editor_unsaved_keys: MapSet.new(),
        doc_conflict: false,
        editor_touched_paths: MapSet.new(),
        object_dialog: nil
      )

    # E3.5 (Gyldendal friction 67): a deep link whose head was a dead display
    # group (`/studio/content-types/<type>/<id>` on a declared desk) opened its
    # document through the alias in `PaneBuilder.build/3`; rewrite the address
    # bar to the canonical path ONCE so bookmarks and row clicks agree. The
    # canonical path never aliases again, so the patch converges.
    case socket.assigns[:editor_canonical_path] do
      canonical when is_list(canonical) and canonical != path ->
        {:noreply,
         push_patch(socket, to: Shared.studio_path(socket, canonical, dataset, desk: desk))}

      _ ->
        {:noreply, socket}
    end
  end

  # A remote save of the open document arrived (another editor/session — the
  # `sender != self()` guard skips our own writes).
  #
  # With NO unsaved local edits, auto-refresh the form in place (unchanged
  # behaviour; `editor_dirty` clears when an autosave lands, see
  # `Handlers.Fields.settle_dirty/2`). The browser keeps the value of the input
  # that has the focus, so typing that has not been posted yet survives, and
  # `editor_doc` stays this tab's base, so a post of a value this tab never
  # changed keeps the remote one (`Forms.upsert_draft/6`).
  #
  # With unsaved local edits (`editor_dirty`), raise the `doc_conflict` banner.
  # The fields named in `editor_unsaved_keys` keep their local value and the
  # other fields take the remote save (task-6f5426c4b04de74b); with none named
  # (an array op, a slug derive) the whole buffer is kept, as before.
  #
  # A SIBLING PROJECT's save is ignored (r4a realtime authz sweep). The doc
  # topic is keyed by id + type + workspace + dataset NAME, which a same-id
  # document in another project of the workspace shares; replacing the form
  # with it streamed an unshared project's content to a share viewer, and could
  # autosave it into this project's document for a member.
  def doc_updated(%{sender: sender, doc: doc_data} = msg, socket) do
    cond do
      sender == self() or is_nil(socket.assigns[:editor_doc]) ->
        {:noreply, socket}

      other_project?(msg, socket) ->
        {:noreply, socket}

      socket.assigns[:editor_dirty] ->
        {:noreply,
         socket
         |> keep_unsaved_fields(doc_data)
         |> assign(doc_conflict: true, save_status: "Updated by another user")}

      true ->
        schema = socket.assigns[:editor_schema]
        updated_form = Content.doc_to_form(doc_data, schema)

        # [server-replaced-widget-values] (Shared): the rich text / reference /
        # image widgets ignore re-renders, so a changed value must remount them.
        changed? =
          Shared.widget_values_changed?(schema, socket.assigns[:editor_form], updated_form)

        {:noreply,
         socket
         |> push_remote_values(socket.assigns[:editor_form] || %{}, updated_form)
         |> assign(
           editor_form: updated_form,
           editor_form_gen: Shared.next_form_gen(socket, changed?),
           doc_conflict: false,
           save_status: "Updated by another user"
         )}
    end
  end

  # task-e6ef964ac2e41d5a: a LiveView patch leaves the FOCUSED input as it is,
  # so a person resting in a field kept the old text after another's save, and
  # the next keystroke there posted it back over their words. The page gets
  # each changed text field's new value and the one it showed before
  # (`bp:form-remote-values`); bp-array-focus.js sets the focused input when it
  # still shows exactly the old one, so nothing typed and unsent is lost.
  defp push_remote_values(socket, old_form, new_form) do
    values =
      for {key, new} <- new_form,
          is_binary(key) and is_binary(new),
          old = Map.get(old_form, key),
          is_binary(old) and old != new,
          into: %{},
          do: {"doc[#{key}]", %{value: new, was: old}}

    if values == %{},
      do: socket,
      else: push_event(socket, "bp:form-remote-values", %{values: values})
  end

  defp keep_unsaved_fields(socket, doc_data) do
    keys = socket.assigns[:editor_unsaved_keys] || MapSet.new()

    if MapSet.size(keys) == 0 do
      socket
    else
      schema = socket.assigns[:editor_schema]
      local = socket.assigns[:editor_form] || %{}

      form =
        doc_data
        |> Content.doc_to_form(schema)
        |> Map.merge(Map.take(local, MapSet.to_list(keys)))

      changed? = Shared.widget_values_changed?(schema, local, form)
      assign(socket, editor_form: form, editor_form_gen: Shared.next_form_gen(socket, changed?))
    end
  end

  defp other_project?(msg, socket) do
    case {Map.get(msg, :project_id), socket.assigns[:current_project]} do
      {msg_proj, %{id: mounted}} when is_binary(msg_proj) and is_binary(mounted) ->
        msg_proj != mounted

      _ ->
        false
    end
  end

  def paper_block(frame, socket) do
    cond do
      # Our OWN paper write echoing back — the handle_event that applied it
      # already re-read the confirmed state (`paper_ops/2`), so a broadcast-driven
      # `refetch_paper` is redundant AND, in tests, a DB reload that outlives the
      # event and races sandbox teardown (`client exited`). Mirrors `doc_updated/2`.
      frame[:sender] == self() ->
        {:noreply, socket}

      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      not socket.assigns.paper_block_mode ->
        {:noreply, Shared.refetch_paper(socket)}

      # task-e175d91d93291b10 — a delta frame carries a block's html rendered in
      # the WRITER's process, under the WRITER's scope and resolvers, and
      # `apply_paper_delta/2` paints it straight into the viewer's stream. For a
      # write-denied viewer that is the same unclamped feed one frame at a time,
      # so the frame is advisory here too: re-read, and let
      # `reader_paper_blocks/2` decide what they see. (Reachable on the
      # canvas-OFF View arm, which is where the stream is the surface.)
      Shared.write_denied?(socket) ->
        {:noreply, Shared.refetch_paper(socket)}

      Shared.paper_gap?(socket.assigns.paper_rev, frame.rev) ->
        {:noreply, Shared.refetch_paper(socket)}

      true ->
        socket = Shared.apply_paper_delta(socket, frame)

        # Rule 5 (pdd-t12b): with the canvas the mainline default there is no
        # Edit mode — the always-editable editor is live whenever the flag is
        # on, so an external delta must re-sync `paper_doc` (the sidebar, the
        # display pushes, and the next preview/paint all read it) and push the
        # block to the per-block WCs, exactly as legacy Edit mode did. The
        # flag-OFF opt-out keeps the old shape: only Edit mode syncs; the
        # read-only View rides `apply_paper_delta` alone.
        #
        # The canvas runs are phx-update="ignore": the re-rendered
        # data-canvas-blocks never reaches the editor, so they get the confirmed
        # runs as a `bp:canvas-update` with no request id (an external echo).
        # Without it the table echo advanced this tab's confirmed revision while
        # its canvas kept the old text, and the tab's next canvas save overwrote
        # the other tab's edit without a conflict.
        socket =
          cond do
            PaperCanvas.paper_canvas_enabled?() ->
              socket
              |> Shared.sync_paper_edit_doc()
              |> Shared.push_block_to_wc(frame.block_id)
              |> Paper.push_canvas_echo()

            socket.assigns[:paper_edit_mode] ->
              socket
              |> Shared.sync_paper_edit_doc()
              |> Shared.push_block_to_wc(frame.block_id)

            true ->
              socket
          end

        {:noreply, socket}
    end
  end

  def paper_updated(%{sender: sender}, socket) when sender == self() do
    # Our own whole-paper write echoing back — no self-refresh (see paper_block/2).
    {:noreply, socket}
  end

  def paper_updated(%{html: html} = msg, socket) do
    cond do
      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      # THE THIRD `:paper_html` FEED (task-fa27740cb3162dbd). The two mount-side
      # reads are clamped in `Shared.Paper.reader_paper_html/2`; this one
      # re-assigns AFTER mount, so an unclamped arm here would hand the raw
      # cache back to the same anonymous `:docs`-share viewer one broadcast
      # later. For a write-denied (non-editing) socket the frame is ADVISORY —
      # exactly what `BulldocsLive` already does with it: re-read the store and
      # let the reader clamp decide, rather than painting bytes off the wire.
      # A stale `paper_doc` cannot be sanitized into the fresh body, so the
      # refetch (not the frame's html) is what keeps the view both current and
      # safe; `refetch_paper/1` carries the store's own rev, which is the truth
      # the frame's `rev` was only advertising.
      Shared.write_denied?(socket) ->
        {:noreply, Shared.refetch_paper(socket)}

      true ->
        # The write-capable arm of the third feed. `write_denied?` above decides
        # WHICH SOURCE this socket is served; it does not decide whether the
        # bytes are safe to `raw/1` — so this html gets the same scrub the two
        # mount-side feeds now take, via the one copy in `Paper`. A frame is
        # off-the-wire markup that lands straight in `raw(@paper_html)`, so
        # leaving it unscrubbed would re-open on the broadcast exactly what the
        # mount-side clamp closes.
        {:noreply,
         socket
         |> assign(:paper_html, Shared.editor_body_html(html))
         |> assign(:paper_block_mode, false)
         |> assign(:paper_rev, msg[:rev] || socket.assigns.paper_rev)}
    end
  end

  def sheets_op(payload, socket) do
    if socket.assigns[:editor_view] == :sheet and socket.assigns[:sheet_doc] do
      send_update(BarkparkWeb.Studio.SheetGrid,
        id: "sheet-grid-#{Content.published_id(socket.assigns.sheet_doc.doc_id)}",
        sheets_op: payload
      )
    end

    {:noreply, socket}
  end

  # The session's persist-outcome frame (both success and failure branches of
  # `Session.persist_result/1`). Mirrors `sheets_op/2` — relay it to the same
  # SheetGrid component, which drives the toolbar save-status indicator.
  def sheets_persisted(payload, socket) do
    if socket.assigns[:editor_view] == :sheet and socket.assigns[:sheet_doc] do
      send_update(BarkparkWeb.Studio.SheetGrid,
        id: "sheet-grid-#{Content.published_id(socket.assigns.sheet_doc.doc_id)}",
        sheets_persisted: payload
      )
    end

    {:noreply, socket}
  end

  def presence_diff(topic, socket) do
    cond do
      topic != nil and topic == socket.assigns[:sheet_presence_topic] ->
        {:noreply, assign(socket, sheet_presences: PresenceState.list(topic))}

      socket.assigns[:presence_topic] != nil ->
        {:noreply,
         socket
         |> assign(presences: PresenceState.list(socket.assigns.presence_topic))
         |> Shared.push_remote_selections()}

      true ->
        {:noreply, socket}
    end
  end

  def document_changed(%{type: type} = msg, socket) do
    viewing_type = socket.assigns[:editor_type] || Enum.at(socket.assigns.nav_path, 0)
    ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id

    cond do
      # task-be3b3aa6da5df3a2 (instance 6, the half that is in reach) — THE
      # CONSUMER-SIDE FENCE on the GLOBAL document stream. `Shared.list_topic/2`
      # already prefers `documents:ws:<id>:<dataset>` when a workspace is
      # resolved, but its fallback clause rides `documents:<dataset>`, which
      # `Content.Broadcast` fires UNCONDITIONALLY for every tenant (the
      # workspace-keyed twin is conditional on `doc.workspace_id`). The payload
      # already carries `:workspace_id`, so this socket can refuse a foreign
      # tenant's frame without any change to the producer.
      not Shared.own_tenant?(msg, ws_id) ->
        {:noreply, socket}

      # Our OWN write — the handle_event that performed it already refreshed our
      # state, so a broadcast-driven `rebuild_panes` (a fresh DB reload) is both
      # redundant AND, in tests, an in-flight query that outlives the test that
      # spawned it: when the LiveView is torn down mid-reload the shared Ecto
      # sandbox connection reports `client exited`, poisoning the pool for
      # unrelated tests' setup. Mirrors the `sender == self()` guard in
      # `doc_updated/2` (the sibling broadcast on the same mutation).
      msg[:sender] == self() ->
        {:noreply, socket}

      viewing_type != type ->
        {:noreply, socket}

      # An open paper repaints from its own paper topic (`{:paper_updated}` /
      # `{:paper_block}`). Paper writes reach this list topic too since owner
      # ruling #40 (they now emit change events for listen/sync/webhooks); a
      # pane rebuild on top of the paper frame would discard the HTML it just
      # painted.
      type == "paper" and socket.assigns[:editor_view] == :paper ->
        {:noreply, socket}

      # A rebuild reloads the open doc's form from the DB — with unsaved local
      # edits that would clobber the buffer just like `doc_updated`. Skip the
      # refresh; `doc_updated` (same broadcast) raises the reload banner.
      socket.assigns[:editor_dirty] ->
        {:noreply, socket}

      # The rebuild may reach the form before `doc_updated` does; whichever
      # reloads it tells the page what changed.
      true ->
        old_form = socket.assigns[:editor_form] || %{}
        rebuilt = Shared.rebuild_panes(socket)
        {:noreply, push_remote_values(rebuilt, old_form, rebuilt.assigns[:editor_form] || %{})}
    end
  end

  def autosave_form(form, socket) do
    {:noreply, Shared.do_autosave(socket, form, :autosave_form)}
  end

  def paper_op(%{"op" => _} = op, socket) do
    {:noreply, Shared.paper_op(socket, op)}
  end

  # pds-w42-bl-tree-codelist-readonly-guard-inert — THE GUARD, ARMED WHERE THE
  # PRINCIPAL IS.
  #
  # `TreeCodelistField.handle_event("tree_node_select", …)` carries a
  # `readonly` guard, but on the Studio path that guard is INERT by
  # construction: `PaperFieldBlock` mounts the component without a `readonly`
  # assign, so `CodelistField`'s `attr :readonly, default: false` hands it
  # `false` for every principal. The one callsite that DOES pass `readonly`
  # (codelist_field.ex) passes no `notify_id`, so `maybe_notify_select/2`
  # short-circuits there and that path cannot write at all. Guard and danger
  # were disjoint.
  #
  # The component cannot be the place to fix it: a LiveComponent has no
  # principal. Nor can a `:handle_event` hook see this hop —
  # `maybe_notify_select/2` does `send(self(), {:tree_codelist_change, …})`,
  # a handle_INFO, exactly the blindness `Shared.Paper.write_denied?/1`
  # documents for `{:paper_op, …}`. So the question is asked HERE, on the
  # parent socket, which is the first place that holds the principal.
  #
  # ONE PREDICATE, NOT A FORK: `Shared.Paper.write_denied?/1` and
  # `grant_target_denied?/3` are the SAME copies the chokepoint asks, in the
  # same order, with the same refusals.
  #
  # WHAT THIS DOES NOT CLOSE, SAID PLAINLY. `TreeCodelistField` still assigns
  # its own `:selected` in `handle_event("tree_node_select", …)` before the
  # notify, and LiveView does not re-invoke a component whose assigns did not
  # change — so a denied principal's PICKER still paints the clicked row until
  # something else moves the block's value. Closing that needs the `readonly`
  # prop to actually reach the component, i.e. a capability attr plumbed
  # through `PaperEditor.paper_block_fields/1` (14 callsites) to the
  # `codelist`+`variant: "tree"` render head in `PaperFieldBlock`. It is a UI
  # AFFORDANCE, exactly like `SheetGrid`'s snapshot prop: a stale-TRUE one
  # costs a denied write at this seam, never a persisted one.
  #
  # DEFENCE IN DEPTH, NOT THE ONLY WALL. The chokepoint already refuses the
  # resulting `{:paper_op, …}`, so persisted state was safe. What was NOT safe
  # is what a refusal at the chokepoint leaves behind: `send_update` runs
  # `PaperFieldBlock.update(%{tree_value: code}, …)`, which moves the
  # component's OWN `:value` and sets `pending_value?`, so a denied principal's
  # editor renders the forged code back as if it had been accepted, and that
  # pending value survives the parent's echo. Stopping the hop stops that too.
  def tree_codelist_change(%{id: id, value: code}, socket) do
    doc = socket.assigns[:editor_doc] || socket.assigns[:paper_doc]
    type = doc_field(doc, :type) || socket.assigns[:editor_type]

    cond do
      Paper.write_denied?(socket) ->
        {:noreply, Paper.refuse_write_denied(socket)}

      Paper.grant_target_denied?(socket, type, doc_field(doc, :doc_id)) ->
        {:noreply, Paper.refuse_outside_grant(socket)}

      true ->
        send_update(BarkparkWeb.Studio.PaperFieldBlock, id: id, tree_value: code)
        {:noreply, socket}
    end
  end

  # Read a pane doc's field TOTALLY — the live path carries a
  # `%Content.Document{}` while unit fixtures carry a bare map, and `doc.type`
  # would raise a KeyError on the latter. Mirrors `Shared.Paper.doc_field/2`.
  defp doc_field(doc, key) when is_map(doc), do: Map.get(doc, key)
  defp doc_field(_doc, _key), do: nil
end
