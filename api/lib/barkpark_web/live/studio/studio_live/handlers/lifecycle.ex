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
  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, PostedEdits, PostPath, Shared}

  alias BarkparkWeb.Studio.StudioLive.Handlers.{
    RemoteValues,
    RichTextRemote,
    UnsavedBases,
    UnsavedObjects
  }

  # `current_path` is NOT set here — `BarkparkWeb.StudioChrome`'s
  # `:handle_params` hook is the single producer (it runs before this
  # callback, deriving current_path from `uri` for every studio-layout
  # surface), so `uri` is unused in this body now.
  def finish_handle_params(socket, dataset, path, desk, _uri, params) do
    shown = BarkparkWeb.Studio.StudioLive.PostIdentity.of(socket)

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
      |> Shared.subscribe_to_doc()
      |> Shared.track_presence()
      # Navigating (re)loads the editor from the DB, so the buffer is clean:
      # clear the dirty flag, any stale concurrent-edit banner, and the
      # touched-path set (`Handlers.Fields`) — a path touched on the previous
      # document must not license folding an empty value on the next one.
      |> assign(
        editor_dirty: false,
        editor_unsaved_keys: MapSet.new(),
        editor_refused_clears: nil,
        doc_conflict: false,
        editor_store_doc: nil,
        editor_touched_paths: MapSet.new(),
        object_dialog: nil,
        editor_rt_held: %{},
        editor_rt_clash: %{}
      )
      |> RichTextRemote.forget()
      # Named after the reset: another editor's last frame is older than the
      # row just read, and may be of a draft that is gone (a Discard), so
      # it must not name the page (#28322 review, round 2).
      |> Shared.assign_page_title()
      # A dialog a document action opened goes with its document.
      |> BarkparkWeb.Studio.StudioLive.PostIdentity.leave(shown)
      |> BarkparkWeb.Studio.StudioLive.DocSwap.start(shown)

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
  # changed keeps the remote one (`Forms.upsert_draft/6`). `RemoteValues`
  # tells the focused input of the new value (task-e6ef964ac2e41d5a).
  #
  # With unsaved local edits (`editor_dirty`), the fields named in
  # `editor_unsaved_keys` keep their local value and the other fields take
  # the remote save (task-6f5426c4b04de74b). It is a conflict, the
  # `doc_conflict` banner and "Updated by another user", only where the
  # remote save rewrote one of those fields as TanStack's `rebase` and
  # `clash` (barkpark-studio edit-bases.ts, edits.ts) read it
  # (task-65543203e7b71c80): a field whose stored value did not move from
  # its base stays ours; a text field both changed merges (`TextRebase.
  # merge3_clash/3`, TanStack's `merge3`), and only a merge that cannot keep
  # both changes clashes; any other value stays ours. A save that rewrote
  # none of them is taken in quietly. A text field's base is the stored
  # value its words were typed on (`UnsavedBases`); with none known it
  # merges nothing and both changed is a conflict. Any other field's base is
  # the newest stored version this tab saw (`base_doc/1`). With none named (an array op, a slug
  # derive) the whole buffer is kept and it is a conflict, as before.
  #
  # A SIBLING PROJECT's save is ignored (r4a realtime authz sweep). The doc
  # topic is keyed by id + type + workspace + dataset NAME, which a same-id
  # document in another project of the workspace shares; replacing the form
  # with it streamed an unshared project's content to a share viewer, and could
  # autosave it into this project's document for a member.
  #
  # A frame older than this tab's own last save is read as that save
  # (`fresher/2`): the save was written over it, so the store already holds
  # what it carried.
  def doc_updated(%{sender: sender, doc: doc_data} = msg, socket) do
    doc_data = fresher(doc_data, socket.assigns[:editor_doc])

    cond do
      sender == self() or is_nil(socket.assigns[:editor_doc]) ->
        {:noreply, socket}

      other_project?(msg, socket) ->
        {:noreply, socket}

      socket.assigns[:editor_dirty] ->
        {socket, clashed} = keep_unsaved_fields(socket, doc_data)

        # The fields it rewrote are named in the save region, as TanStack's
        # `clash` says them (`RefusedSave.status/1`); the whole buffer kept
        # names none.
        socket =
          case clashed do
            [] ->
              socket

            keys ->
              assign(socket,
                doc_conflict: true,
                save_status: "Updated by another user",
                editor_clash_fields: if(keys == :all, do: [], else: keys)
              )
          end

        {:noreply, socket |> took_frame(doc_data) |> named_as_seen()}

      true ->
        schema = socket.assigns[:editor_schema]
        updated_form = Content.doc_to_form(doc_data, schema)

        # [server-replaced-widget-values] (Shared): the rich text / reference /
        # image widgets ignore re-renders, so a changed value must remount them.
        changed? =
          Shared.widget_values_changed?(schema, socket.assigns[:editor_form], updated_form)

        {:noreply,
         socket
         |> RemoteValues.push(socket.assigns[:editor_form] || %{}, updated_form)
         |> RichTextRemote.push(socket.assigns[:editor_form] || %{}, updated_form)
         |> PostedEdits.remote(socket.assigns[:editor_form] || %{}, updated_form)
         |> took_frame(doc_data)
         |> assign(
           editor_form: updated_form,
           editor_form_gen: Shared.next_form_gen(socket, changed?),
           doc_conflict: false,
           save_status: "Updated by another user"
         )
         |> named_as_seen()}
    end
  end

  # Another editor's frame, and the row of this tab's it arrived over
  # (`base_doc/1`).
  defp took_frame(socket, frame),
    do:
      assign(socket,
        editor_store_doc: frame,
        editor_store_over: row_key(socket.assigns[:editor_doc])
      )

  defp row_key(%{doc_id: id} = doc), do: {id, Map.get(doc, :updated_at), Map.get(doc, :rev)}
  defp row_key(_doc), do: nil

  # The pane header and the tab name the newest stored version this tab has
  # seen, as the title field and the list row do: `editor_doc` stays this
  # tab's own row (`post_base/1`), so naming it kept the old title after
  # another editor renamed the document (task-42a6f063263338f6). TanStack's
  # DocumentPane names the document it holds, which moves on every frame.
  defp named_as_seen(socket), do: Shared.assign_page_title(socket)

  # Two people save one field at once: B's save lands, then this tab's save
  # is written over it, and only then does B's frame reach this process (it
  # was busy saving). The frame still carries B's text alone; put in the form
  # and told to the page, it replaced the text both saves left with B's post
  # until the next change (task-e7088bb3b4139db7). `editor_doc` is this tab's
  # last save, so a frame stamped before it is stale and that save stands.
  defp fresher(%{updated_at: %DateTime{} = sent} = frame, %{updated_at: %DateTime{} = own} = doc),
    do: if(DateTime.compare(sent, own) == :lt, do: doc, else: frame)

  defp fresher(frame, _doc), do: frame

  # The remote save taken into the form, and the unsaved fields it rewrote
  # so both changes cannot stand (`clash/4`); `:all` when the whole buffer
  # is kept.
  defp keep_unsaved_fields(socket, doc_data) do
    keys = socket.assigns[:editor_unsaved_keys] || MapSet.new()

    if MapSet.size(keys) == 0 do
      {socket, :all}
    else
      schema = socket.assigns[:editor_schema]
      local = socket.assigns[:editor_form] || %{}
      base = Content.doc_to_form(base_doc(socket), schema)
      theirs = Content.doc_to_form(doc_data, schema)

      # Each field's base is the stored value its words were typed on
      # (`UnsavedBases`), which can be older than `base_doc/1`.
      typed = Map.new(keys, fn key -> {key, UnsavedBases.fetch(socket, key)} end)

      {mine, clashed, kept} =
        Enum.reduce(keys, {%{}, [], UnsavedBases.all(socket)}, fn key, {mine, clashed, kept} ->
          theirs_value = Map.get(theirs, key)
          {b, m} = {Map.get(base, key), Map.get(local, key)}

          case UnsavedObjects.subfields(schema, key, b, m, theirs_value) do
            nil ->
              field_clash(typed[key], b, m, theirs_value, schema, key, {mine, clashed, kept})

            # An object: subfield by subfield, a text subfield by its path
            # (task-71ff11d4e7374985).
            subs ->
              {value, clashed?, kept} =
                UnsavedObjects.merge(socket, subs, [key], b, m, theirs_value, kept, &clash/6)

              {Map.put(mine, key, value), if(clashed?, do: [key | clashed], else: clashed), kept}
          end
        end)

      form = Map.merge(theirs, Map.filter(mine, fn {key, _} -> Map.has_key?(local, key) end))
      changed? = Shared.widget_values_changed?(schema, local, form)
      # The page's next post of an unsaved field is made on the stored value
      # its words were typed on (it kept typing) or on theirs (it took the
      # merge), never on its own unsaved words.
      bases =
        Map.new(keys, fn key ->
          was_base =
            case typed[key] do
              {:ok, typed_on} -> typed_on
              :error -> Map.get(base, key)
            end

          {key, {was_base, Map.get(theirs, key)}}
        end)
        |> Map.merge(UnsavedObjects.push_bases(socket, MapSet.to_list(keys), base, theirs))

      socket =
        socket
        |> RemoteValues.push(local, form, bases)
        |> RichTextRemote.push(local, form)
        |> PostedEdits.remote(local, form)
        |> assign(
          editor_form: form,
          editor_form_gen: Shared.next_form_gen(socket, changed?),
          editor_unsaved_bases: kept
        )
        |> RichTextRemote.push_held(base, theirs)

      {socket, clashed}
    end
  end

  defp field_clash(typed, base, mine_value, theirs_value, schema, key, {mine, clashed, kept}) do
    case clash(typed, base, mine_value, theirs_value, schema, key) do
      {:ours, value} ->
        {Map.put(mine, key, value), clashed, kept}

      {:took, value} ->
        {Map.put(mine, key, value), clashed, took(kept, schema, key, theirs_value, value)}

      :clash ->
        {Map.put(mine, key, mine_value), [key | clashed], kept}
    end
  end

  # A text field that took theirs (or a merge onto it) is typed on theirs.
  defp took(kept, schema, key, theirs, value) do
    if RemoteValues.free_text?(schema, key),
      do: UnsavedBases.put(kept, key, theirs, value),
      else: kept
  end

  # One unsaved field under a remote save, as TanStack's `rebase` and
  # `merge3`, from the base its words were typed on (`{:ok, base}`): theirs
  # did not move from the base, ours stands (`:ours`); ours did not (or is
  # theirs), theirs stands (`:took`). A string both changed: free text
  # merges (`TextRebase.merge3_clash/3`, the splice merge a post gets, where
  # TanStack's patch places mine too), and a merge that cannot keep both is
  # a clash; any other string (a choice, a
  # date) cannot keep both, so it clashes. A list or an object both changed
  # clashes too: TanStack's `mergeList3` keeps theirs only where it can place
  # mine, and an unplaced one kept ours unseen. Any other value (a number, a
  # switch) stays ours ("else ours wins").
  #
  # Free text with no known base (`:error`) merges nothing: theirs that did
  # not move from the stored value leaves ours, and theirs that differs from
  # ours is a clash. A field that is not free text reads the stored value as
  # its base.
  defp clash(:error, stored, mine, theirs, schema, key) do
    if RemoteValues.free_text?(schema, key) do
      cond do
        theirs == stored -> {:ours, mine}
        mine == theirs -> {:took, theirs}
        true -> :clash
      end
    else
      clash({:ok, stored}, stored, mine, theirs, schema, key)
    end
  end

  defp clash({:ok, base}, _stored, mine, theirs, schema, key) do
    strings? = is_binary(base) and is_binary(mine) and is_binary(theirs)

    cond do
      theirs == base ->
        {:ours, mine}

      mine == base or mine == theirs ->
        {:took, theirs}

      strings? and RemoteValues.free_text?(schema, key) ->
        case Barkpark.Content.TextRebase.merge3_clash(base, mine, theirs) do
          nil -> :clash
          merged -> {:took, merged}
        end

      strings? ->
        :clash

      is_list(mine) or is_map(mine) or is_list(theirs) or is_map(theirs) ->
        :clash

      true ->
        {:ours, mine}
    end
  end

  @doc """
  The row a post is read against (`Shared.autosave_write`): this tab's own
  last save (`editor_doc`), with the field the post is a change of
  (`editor_post_target`) as the newest stored version this tab saw.

  So a choice set back to this tab's earlier value after another editor's
  save is an edit, as TanStack sends the field typed in
  (task-1f6d4ed8c24a821b). Every other field is still read against this
  tab's own row: a post that left the page before another editor's save
  carries that editor's fields at their old values, and they stay dropped
  (`PostedEdits`, task-a4ded0be5c8ec3cb). The rev and `updated_at` stay
  this tab's own.

  Inside an object only the subfield changed (`editor_post_path`,
  `meta.code`) is taken from the newest version (`PostPath`): its siblings
  are read against this tab's own row, as other fields are
  (task-04e50efa8405b956).
  """
  def post_base(socket) do
    own = socket.assigns[:editor_doc]
    seen = base_doc(socket)
    path = {socket.assigns[:editor_post_path], PostPath.shapes(socket)}

    case List.wrap(socket.assigns[:editor_post_target]) do
      [_ | _] = keys when is_map(own) and is_map(seen) and seen != own ->
        Enum.reduce(keys, own, &take_seen(&2, seen, &1, path))

      _ ->
        own
    end
  end

  defp take_seen(doc, seen, key, {[key, sub | _] = path, shapes})
       when is_binary(sub) and key not in ["title", "status"] do
    own = doc.content || %{}
    theirs = seen.content || %{}

    case PostPath.unit(path, shapes, own, theirs) do
      [_, _ | _] = at -> %{doc | content: PostPath.put(own, theirs, at)}
      _ -> take_seen(doc, seen, key)
    end
  end

  defp take_seen(doc, seen, key, _path), do: take_seen(doc, seen, key)

  defp take_seen(doc, seen, key) when key in ["title", "status"] do
    atom = String.to_existing_atom(key)
    Map.put(doc, atom, Map.get(seen, atom))
  end

  defp take_seen(doc, seen, key) do
    own = doc.content || %{}

    content =
      case Map.fetch(seen.content || %{}, key) do
        {:ok, value} -> Map.put(own, key, value)
        :error -> Map.delete(own, key)
      end

    %{doc | content: content}
  end

  # The newest stored version of the open document this tab saw: its own
  # last save (`editor_doc`), or a remote save taken in since. TanStack moves
  # a field's base to theirs on every frame.
  @doc """
  The newest stored version of the open document this tab has seen: the
  fresher of another editor's last frame (`editor_store_doc`) and this tab's
  own row (`editor_doc`).

  A frame counts only over the row it arrived on (`editor_store_over`): any
  change of `editor_doc` since is a read or a write of this tab's that is
  newer than the frame, or a row of another variant (a Discard drops the
  draft the frame was of, a Publish or Unpublish swaps the row). Comparing
  times alone named a discarded draft (#28322 review, round 2): another tab
  discards the draft it renamed, and this tab's Reload reads the published
  row, older than that draft's frame (task-e82f6c625819d4f5, pinned in
  `desk_remote_title_header_test.exs`).
  """
  def base_doc(socket) do
    own = socket.assigns[:editor_doc]

    case socket.assigns[:editor_store_doc] do
      %{doc_id: id} = seen when is_map(own) ->
        if Content.published_id(id) == Content.published_id(own.doc_id) and
             socket.assigns[:editor_store_over] == row_key(own),
           do: fresher(seen, own),
           else: own

      _ ->
        own
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
        #
        # `paper_doc` is re-read with the painted words, as the delta arm does:
        # history's Restore names its rev (`History.seen_rev/1`), and a stale
        # one refused the first press after another writer's save
        # (task-5b74471e6a2d6de8). `paper_rev` stays the frame's.
        {:noreply,
         socket
         |> Shared.sync_paper_edit_doc()
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
        rebuilt = socket |> Shared.rebuild_panes() |> RemoteValues.keep_history(socket)
        new_form = rebuilt.assigns[:editor_form] || %{}

        {:noreply,
         rebuilt
         |> RemoteValues.push(old_form, new_form)
         |> RichTextRemote.push(old_form, new_form)}
    end
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
