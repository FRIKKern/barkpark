defmodule BarkparkWeb.Studio.StudioLive.Handlers.Fields do
  @moduledoc """
  Document lifecycle (new/save/autosave) + editor toggles + ArrayField ops.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias Barkpark.Content.Forms
  alias Barkpark.Content.Forms.CodelistShape
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Handlers.ArrayItems
  alias BarkparkWeb.Studio.StudioLive.Handlers.HeldFields
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.SaveTells
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextRejoin
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextUnderLock
  alias BarkparkWeb.Studio.StudioLive.Handlers.UnsavedBases
  alias BarkparkWeb.Studio.StudioLive.KeptCodes
  alias BarkparkWeb.Studio.StudioLive.KeptPicks
  alias BarkparkWeb.Studio.StudioLive.KeptRows
  alias BarkparkWeb.Studio.StudioLive.PostedEdits
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.Studio.StudioLive.RefusedSave
  alias BarkparkWeb.Studio.StudioLive.Shared

  # [untitled-is-a-fallback-not-a-seed] A new document is born WITHOUT a
  # title, on purpose. A paper showed it first: `Papers.Template.template_blocks/1`
  # copies the attrs title verbatim into the locked `tpl-title` heading's
  # `"text"`, so seeding "Untitled" did not write chrome — it wrote CONTENT,
  # into the one block the author is about to type in, and the caret landing
  # after it made the first keystroke APPEND ("UntitledHand walk…"). Every
  # display site already renders `doc.title || "Untitled"` (pane_builder,
  # components, secondary, refs, editor_fields, modals), so a nil title still
  # reads "Untitled" on the desk, the breadcrumb and the tab — while the title
  # input or block itself starts empty. `derive_title/2` (papers) and
  # `TitleDerivation.maybe_derive` (titleless types) then fill the row title
  # the moment the author types, which is the single-truth contract the
  # literal was quietly pre-empting.

  # How long a create press stays "the press you just made". PUSH_TIMEOUT in
  # phoenix_live_view.js is 30_000ms — after that the client itself has given
  # up on the reply, so a press beyond this window is a NEW intent, never a
  # retry of the old one.
  @create_retry_window_ms 30_000

  def new_document(%{"type" => type} = params, socket) do
    # A type whose desk block says `authorCreatable: false` shows no "+"; a
    # hand-pushed event is refused here too (task-631d6ea85517e668). A type
    # this dataset does not have is refused as well: a hand-pushed name made a
    # document of a type nothing declares (#25897 review).
    case Content.resolve_schema(type, socket.assigns.dataset, Shared.hook_opts(socket)) do
      {:ok, schema} ->
        if BarkparkWeb.Studio.PaneBuilder.author_creatable?(schema),
          do: author_new_document(type, params, socket),
          else: {:noreply, put_flash(socket, :error, not_creatable(schema, type))}

      _ ->
        {:noreply, put_flash(socket, :error, no_such_type(type))}
    end
  end

  defp no_such_type(type) do
    gettext("“%{type}” is not a document type in this dataset, so no document was made.",
      type: type
    )
  end

  defp not_creatable(schema, type) do
    gettext(
      "“%{type}” cannot be made here: its documents come in from somewhere else, such as a form.",
      type: Map.get(schema, :title) || type
    )
  end

  defp author_new_document(type, params, socket) do
    preset = pane_preset(params, socket)

    case retry_of_recent_create(socket, type, preset) do
      {:ok, %{path: path}} ->
        # [plus-press-retry-coalesce] THE SECOND PRESS OF "+". spd-w18 measured
        # the "+" navigating in 6.4s on one build and NEVER within 20s across
        # three presses on the next — and the desk list still grew "Untitled"
        # rows, because every one of those presses DID create a document. The
        # navigation is what went missing, client-side (D242/D265: a push_patch
        # reply that is dropped in the browser leaves the server believing it
        # navigated), so no server-side pending assign can be shown for it and
        # the human, staring at an unmoved screen, presses again.
        #
        # So the second press is answered instead of obeyed: re-navigate to the
        # draft the FIRST press already made, and SAY so. The human ends up
        # with one Untitled draft and a sentence explaining where it went,
        # rather than two drafts and silence.
        #
        # It cannot eat a genuine second create: `retry_of_recent_create/2`
        # matches only a document of the SAME type, made by THIS socket, inside
        # the 30s window, that still exists and whose `rev` has not moved since
        # birth. Type a single character into it (or come back a minute later)
        # and this branch is gone.
        #
        # THE TRADE, stated rather than hidden: a human who deliberately wants
        # TWO untouched blank drafts of one type inside 30 seconds gets the
        # second press answered instead, and has to type in the first one (or
        # wait) to get another — which is why the sentence below names that
        # way out rather than only reporting what happened. The marker is NOT
        # released by answering, so three presses still leave ONE draft; the
        # alternative (release after one answer) would have turned the
        # measured three-press run into two orphans instead of none. Two blank
        # untouched drafts of the same type, seconds apart, is a shape where
        # one of them is always the orphan.
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "That “+” already created an untitled %{type} — opening it instead of making a second draft. Type in it, or wait a moment, to start another.",
             type:
               BarkparkWeb.Studio.PaneBuilder.type_word_for(
                 type,
                 socket.assigns.dataset,
                 BarkparkWeb.ScopeHelpers.scope_opts(socket)
               )
           )
         )
         |> push_patch(to: Shared.studio_path(socket, path, socket.assigns.dataset))
         |> focus_new_doc(List.last(path))}

      :none ->
        create_new_document(type, pane_prefix(params, socket), preset, socket)
    end
  end

  # A declared desk list's `initialValues` (task-dc9b751450c2c2c4): its "+"
  # starts the document with those fields set, so a page made from
  # «Landingssider» is a landing page and shows in that list at once. Read from
  # the pressed pane, never from the client.
  defp pane_preset(%{"pane" => pane}, socket) when is_binary(pane) do
    with {idx, ""} when idx >= 0 <- Integer.parse(pane),
         %{initial_values: %{} = preset} <- Enum.at(socket.assigns[:panes] || [], idx) do
      preset
    else
      _ -> %{}
    end
  end

  defp pane_preset(_params, _socket), do: %{}

  # The pressed pane's own address, the prefix `Handlers.Scope.select/2` uses
  # for a row click (#35b). `nav_path ++ [id]` appended the new id after the
  # OPEN document whenever one was open, so the walker kept the old document in
  # the editor and the new one sat orphaned in the list
  # (task-c06799c87b8d4964). A press with no pane index (none today) keeps the
  # old formula.
  defp pane_prefix(%{"pane" => pane}, socket) when is_binary(pane) do
    with {idx, ""} when idx >= 0 <- Integer.parse(pane),
         %{path: path} when is_list(path) <- Enum.at(socket.assigns[:panes] || [], idx) do
      path
    else
      _ -> socket.assigns.nav_path
    end
  end

  defp pane_prefix(_params, socket), do: socket.assigns.nav_path

  defp create_new_document(type, prefix, preset, socket) do
    # No hand-rolled `doc_id`: the old `"#{type}-#{:rand.uniform(999_999)}"`
    # drew from a 1M-value space, so on a populated dataset a collision landed
    # in the writer's UPDATE branch and SILENTLY overwrote an unrelated doc (or
    # failed as an opaque "Failed to create"). Omitting `"doc_id"` lets
    # `Content.create_document` mint one via the canonical `generate_id/1`
    # (`<type>-<64 bits of strong entropy>`) — same readable shape, negligible
    # collision odds. See [doc-id-collision-overwrite] in content/writer.ex.
    case Content.create_document(
           type,
           type |> new_document_attrs() |> Map.update!("content", &Map.merge(&1, preset)),
           socket.assigns.dataset,
           Shared.hook_opts(socket)
         ) do
      {:ok, doc} ->
        pub_id = Content.published_id(doc.doc_id)
        new_path = prefix ++ [pub_id]

        {:noreply,
         socket
         |> assign(
           recent_create: %{
             type: type,
             preset: preset,
             doc_id: doc.doc_id,
             rev: doc.rev,
             path: new_path,
             at: System.monotonic_time(:millisecond)
           }
         )
         |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))
         |> focus_new_doc(pub_id)}

      {:error, {:halted, reason}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Create cancelled: %{reason}", reason: reason))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create"))}
    end
  end

  # A create the user just made opens with the caret in its first field
  # (task-92e2615cf6ec27e6). Without this, focus stayed on the "+", and a
  # keyboard user tabbed through every list row to reach the form. The client
  # half (`phx:bp:focus-new-doc` in root.html.heex) waits for this id's editor
  # to render, since the push_patch above has not rendered it yet.
  defp focus_new_doc(socket, id), do: push_event(socket, "bp:focus-new-doc", %{id: id})

  # See [plus-press-retry-coalesce] above. `{:ok, marker}` means: this press is
  # indistinguishable from a re-press of one whose answer never reached the
  # screen, and the document it made is still exactly as it was born.
  #
  # `rev` is the untouched test rather than the title or the content, because
  # both differ per type (a paper is born with a template and NO stored title,
  # a task with a seeded content map) while `rev` moves on any write of any
  # type — one predicate, no per-type list to fall out of date.
  # A press in a list with other presets is a different "+", never a retry.
  defp retry_of_recent_create(socket, type, preset) do
    with %{type: ^type, doc_id: doc_id, rev: rev} = marker <-
           socket.assigns[:recent_create],
         true <- Map.get(marker, :preset, %{}) == preset,
         true <- System.monotonic_time(:millisecond) - marker.at <= @create_retry_window_ms,
         {:ok, %{rev: ^rev}} <-
           Content.get_document(doc_id, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
      {:ok, marker}
    else
      _ -> :none
    end
  end

  # See [untitled-is-a-fallback-not-a-seed] above (task-79e28148d9925097). For
  # a field-titled type the stored "Untitled" opened in the title input as
  # text the editor had to delete, and it SATISFIED a required title, so +
  # then Publish shipped "Untitled". For a titleless type (author:
  # `list_preview.title = name`) it blocked `TitleDerivation.maybe_derive`,
  # which fills only a BLANK title, so the name never reached the title column
  # and the header kept saying Untitled.
  #
  # A task alone keeps the seed: the Tasks plugin's authoring quality gate
  # (`Plugins.Tasks` `gate_title/2`) refuses a task with a blank title, so a
  # titleless + would answer "Create cancelled".
  defp new_document_attrs("task" = type),
    do: %{"content" => Shared.seed_new_doc_content(type), "title" => "Untitled"}

  defp new_document_attrs(type), do: %{"content" => Shared.seed_new_doc_content(type)}

  # A post built for another document than the editor holds is not written
  # (`PostIdentity`).
  def save(params, socket) when is_map(params) do
    if PostIdentity.ours?(params, socket),
      do: KeptPicks.through(params, socket, &save_open/2),
      else: {:noreply, socket}
  end

  def save(_params, socket), do: {:noreply, socket}

  # The fold's re-targeted row leaves, `[{input name, path, value}]`.
  @moved "_bp_rt_moved"

  defp save_open(params, socket) do
    params = PostIdentity.no_marks(params)
    socket = track_touched(socket, params)

    case params
         |> fold_dot_paths(socket)
         |> KeptRows.only_stored(base_form(socket))
         |> KeptCodes.only_touched(base_form(socket), socket.assigns[:editor_schema]) do
      %{"doc" => posted} = folded ->
        # As an autosave: a rich text in an object written over another
        # editor's change is not written over it (#28349 r2 review, V1),
        # and is read again under the lock (`RichTextRemote.UnderLock`,
        # task-8f15f5c9c15ce748).
        {doc, held} = RichTextRemote.split(socket, posted, params["_bp_rt_seen"])

        rich =
          Map.merge(
            RichTextRemote.UnderLock.values(
              socket,
              params["_bp_rt_seen"],
              posted,
              params["_bp_rt_owner"]
            ),
            RichTextRemote.UnderLock.top(socket, posted)
          )

        {doc, not_codes} = CodelistShape.split(doc, socket.assigns[:editor_schema])
        # A Save from a page that rejoined a new socket is read as its
        # autosave is (`TextRejoin`, #28830 r1 review, B2).
        units = RemoteValues.text_units(socket.assigns[:editor_schema], doc)
        {doc, typed} = TextRejoin.split(socket, units, params["_bp_seen"], doc)
        {socket, text} = text_bases(socket, doc, params["_bp_seen"])

        socket =
          socket
          |> assign(editor_rt_under_lock: rich)
          |> RichTextRemote.UnderLock.posted(
            params["_bp_rt_seen"],
            posted,
            params["_bp_rt_owner"]
          )

        {saved, held} = do_save(doc, not_codes, socket, text, {held, rich, posted, typed})

        {:noreply,
         saved
         |> TextConfirmed.confirm(units, posted)
         |> RichTextRemote.hold(held)
         |> TextConfirmed.paused(rich)
         |> row_draws()
         |> moved_rows(folded, params)}

      _ ->
        {:noreply, socket}
    end
  end

  defp moved_rows(socket, folded, params),
    do:
      RichTextRemote.MovedRows.hold(
        socket,
        Map.get(folded, @moved, []),
        params["_bp_rt_owner"]
      )

  # As an autosave: each free-text field of the Save is merged onto the
  # store from the base the page reports, and read again under the lock
  # (`TextUnderLock`) (task-998551f010da1d5e). The Save skipped both, so a
  # save landing under it was written over as sent, with no banner.
  defp text_bases(socket, doc, seen) do
    keys = RemoteValues.text_units(socket.assigns[:editor_schema], doc)
    based = RemoteValues.put_bases(socket, keys, seen)
    text = TextUnderLock.values(based, keys, seen, nil)
    {assign(based, editor_text_under_lock: text), text}
  end

  # `{held, rich, posted, typed}`: the rich text acts `split/3` gave, the
  # values read under the lock, the post as the page sent it, and the fields
  # `TextRejoin.split/5` held or put back as stale. The write's
  # outcome is read before the reload drops it (`:saved_over`).
  defp do_save(params, not_codes, socket, text, {held, rich, posted, typed}) do
    before = socket.assigns[:editor_form] || %{}
    written = Shared.do_autosave(socket, params, :save)
    text_held = TextUnderLock.held(written, text, params)
    {written, held} = RichTextRemote.UnderLock.acts(written, held, rich, {params, posted})
    # A rich text still held from before (`:still`) is not saved either: no
    # "Saved" beside its banner (#28832 review, N1).
    rich_held =
      for({:held, name, _, _} <- held, do: name) ++ for({:still, name, _} <- held, do: name)

    socket =
      written
      |> assign(editor_field_bases: %{}, editor_text_under_lock: nil, editor_rt_under_lock: nil)
      |> RefusedSave.not_codes(not_codes)

    {:noreply, saved} = do_saved(socket, text_held, {rich_held, typed != []}, params)

    # The page is told what landed during the Save; a field held here
    # (under the lock, or by `TextRejoin`) is left out: its hold draws it.
    saved =
      SaveTells.tell(
        saved,
        socket.assigns[:save_status] == "Saved",
        {before, params},
        {held, text_held ++ Enum.map(typed, &elem(&1, 0))}
      )

    {TextRejoin.hold(saved, typed, :save), held}
  end

  # `{rich_held, typed?}`: the rich texts the Save holds, and whether
  # `TextRejoin` held a field.
  defp do_saved(socket, text_held, {rich_held, typed?}, params) do
    case socket.assigns[:save_status] do
      "Saved" when text_held != [] or rich_held != [] or typed? ->
        # The store kept another editor's words over a field of the Save:
        # the rest is saved; that field holds A's words, unsaved, with the
        # banner, as an autosave holds it. A rich text held here is left
        # out of the redraw's digests: the page keeps A's words there.
        {:noreply,
         socket
         |> Shared.rebuild_panes()
         |> TextConfirmed.redrawn(socket, rich_held)
         |> assign(editor_dirty: false, doc_conflict: false, editor_unsaved_keys: MapSet.new())
         |> HeldFields.drop_paths()
         |> Shared.assign_page_title()
         |> clear_touched()
         |> TextUnderLock.hold(text_held, params)}

      "Saved" ->
        # An explicit save reloads the editor from the just-persisted row —
        # the local buffer is now clean, so drop the dirty flag and any
        # stale concurrent-edit banner. A field it left out (a refused clear,
        # a value that is not a code) is still not saved (`RefusedSave`), and
        # the page says so, not "Saved".
        socket =
          socket
          |> saved_flash()
          |> Shared.rebuild_panes()
          |> TextConfirmed.redrawn(socket)
          |> assign(editor_dirty: false, doc_conflict: false, editor_unsaved_keys: MapSet.new())
          |> HeldFields.drop_paths()
          |> Shared.assign_page_title()
          |> clear_touched()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  defp saved_flash(socket) do
    if RefusedSave.token(socket.assigns) == "Saved",
      do: put_flash(socket, :info, gettext("Saved")),
      else: socket
  end

  # Reload the open doc from the DB after a concurrent edit by another user,
  # discarding the local buffer. Clears the conflict banner + dirty flag.
  # Each string field the reload changed is pushed to the page with its
  # numbers, as rich text is repainted (task-2e9aaa937cfc3da1): a patch
  # leaves a focused input alone, so it kept A's held words, and A's next
  # key wrote them over B's with no banner. The reload drops the numbers the
  # socket sent, so the stored values are sent again under numbers of their
  # own first (`RemoteValues.born/1`): a key from a page that has not drawn
  # the push yet reads as a rejoin post (`TextRejoin`), never as sent.
  def reload_remote_doc(socket) do
    was = socket.assigns[:editor_form]

    socket =
      socket
      |> Shared.rebuild_panes()
      |> RichTextRemote.repaint(was)
      |> assign(editor_text_born: false)
      |> RemoteValues.born()
      |> then(&RemoteValues.push(&1, was || %{}, &1.assigns[:editor_form] || %{}))
      |> assign(
        editor_dirty: false,
        doc_conflict: false,
        editor_text_paused: [],
        editor_unsaved_keys: MapSet.new(),
        editor_refused_clears: nil
      )
      |> TextConfirmed.loaded()
      |> Shared.assign_page_title()
      |> clear_touched()

    {:noreply, socket}
  end

  # Generate derives the slug from the field's declared SOURCE — Sanity's
  # `options.source` (Gyldendal parity E1.6, task-cd8e10ca44ccb932 criterion
  # 2): the twin's author slug comes from `name`, everything else from
  # `title`. Before this the source was hard-coded to `title`, so Generate on
  # an author did nothing. The form buffer is read first (the value the
  # author sees), then the stored document (title column for `title`, content
  # otherwise).
  def slug_generate(%{"field" => field}, socket) do
    source = BarkparkWeb.Components.FieldInputs.slug_source(socket.assigns[:editor_schema], field)
    form = socket.assigns[:editor_form] || %{}
    doc = socket.assigns[:editor_doc]

    value =
      case Map.get(form, source) do
        t when is_binary(t) and t != "" ->
          t

        _ ->
          cond do
            is_nil(doc) -> nil
            source == "title" -> doc.title
            true -> get_in(doc.content || %{}, [source])
          end
      end

    case value do
      t when is_binary(t) and t != "" ->
        posted = %{field => document_slug(t)}
        {posted, held} = HeldFields.stored(socket, posted, [field])
        saved = Shared.do_autosave(socket, posted, :slug_derive)

        {:noreply,
         saved
         |> keep_unsaved_values(posted, [field])
         |> settle_dirty([field])
         |> HeldFields.restore(held)}

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  A pick in a tree codelist of the document editor saves like any other field
  change (task-0f806691db0e06dd). `TreeCodelistField` sends the input name
  (`doc[subject]`, or a nested `doc[a][0].b`) and the code: the re-rendered
  hidden input alone fires no `phx-change`. The code goes into the editor
  buffer at that path and the buffer is saved; `Shared.do_autosave/3` asks
  the write questions.

  `press` is the pressed row's params: the pick is written only into the
  document it was pressed in (`PostIdentity.pressed/3`). A message without
  them writes nothing.
  """
  def tree_codelist_pick(%{name: name, value: code} = msg, socket)
      when is_binary(name) and is_binary(code) do
    PostIdentity.pressed(Map.get(msg, :press), socket, fn _params, socket ->
      case {socket.assigns[:editor_doc], StudioLive.parse_path(name)} do
        {%{}, [_ | _] = path} ->
          form = picked_form(socket, path, code)
          socket = socket |> PostedEdits.put(form) |> RefusedSave.target(Enum.take(path, 1), path)
          {form, held} = HeldFields.stored(socket, form, Enum.take(path, 1))
          saved = Shared.do_autosave(socket, form, :tree_codelist_pick)
          {:noreply, saved |> settle_dirty(Enum.take(path, 1)) |> HeldFields.restore(held)}

        _ ->
          {:noreply, socket}
      end
    end)
  end

  def tree_codelist_pick(_msg, socket), do: {:noreply, socket}

  # In the desk a Remove unsets the code, nested too, as TanStack does, by
  # the same rule as a cleared language (`unset_at/2`); the old Studio stores
  # "" at a nested path, as it did.
  defp picked_form(%{assigns: %{desk_base: base}} = socket, path, "") when is_binary(base),
    do: unset_at(base_form(socket), path)

  defp picked_form(socket, path, code),
    do: StudioLive.Path.put_value_at(base_form(socket), path, code)

  @doc """
  The slug Generate derives from a title: Latin letters with accents or
  ligatures TRANSLITERATED before `Tenancy.slugify/1` keeps only `[a-z0-9]`.

  Stranger walk (2026-09-30): "Blåbær & Søt! Æøå" generated `bl-b-r-s-t` — every
  non-ASCII letter became a hyphen, so a Norwegian (or French, German, Polish…)
  title produced a slug that names nothing. Accented letters fold to their base
  (NFD, combining marks dropped: å→a, é→e, ü→u); letters NFD cannot split get
  their conventional spelling (æ→ae, ø→o, ß→ss, œ→oe, þ→th, ð→d, đ→d, ł→l).
  Workspace/project slugs keep `Tenancy.slugify/1` byte-identically — only the
  document-field Generate button reads through here.
  """
  @spec document_slug(String.t()) :: String.t()
  def document_slug(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(["æ", "ø", "ß", "œ", "þ", "ð", "đ", "ł"], fn
      "æ" -> "ae"
      "ø" -> "o"
      "ß" -> "ss"
      "œ" -> "oe"
      "þ" -> "th"
      "ð" -> "d"
      "đ" -> "d"
      "ł" -> "l"
    end)
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> Barkpark.Tenancy.slugify()
  end

  # A change from an input with no name is not a field edit. LiveView posts the
  # whole form for it with `_target` "undefined": typing in a reference
  # picker's search box did that once per keystroke, and each post wrote a
  # draft of an untouched document (task-32d983d47299e137).
  def autosave(%{"_target" => ["undefined"]}, socket), do: {:noreply, socket}

  def autosave(params, socket) when is_map(params) do
    if PostIdentity.ours?(params, socket),
      do: KeptPicks.through(params, socket, &autosave_open(&1, &2, :page)),
      else: {:noreply, socket}
  end

  def autosave(_params, socket) do
    {:noreply, socket}
  end

  @doc """
  A change the server built itself for the document the socket holds (the
  desk's Paste field): not a browser post, so it carries no name and none is
  asked (`PostIdentity`). Never call it with params that came from the page.

  The params may carry, under the atom key `:bases`, the value each free-text
  field was computed from (the desk's undo, `Desk.DocUndo`): the save merges
  it onto what the store holds by then, as it does a typed post from the base
  the page reports. A field whose base is `:whole` is written exactly as
  posted (an undo of a value, `Desk.DocUndoValues.post/2`). A page's params
  never carry an atom key.
  """
  def autosave_built(params, socket) when is_map(params) do
    {bases, params} = Map.pop(params, :bases, %{})
    # A field held under the banner keeps its hold through the write, as
    # it does through a write of the whole form (`HeldFields`,
    # task-25de1fd76bf1f6d8): the save's "Saved" cleared the banner.
    {doc, held} =
      HeldFields.stored(
        socket,
        params["doc"] || %{},
        target_key(params, socket.assigns[:editor_schema])
      )

    params = if Map.has_key?(params, "doc"), do: Map.put(params, "doc", doc), else: params
    {:noreply, saved} = autosave_open(params, socket, {:built, bases})
    {:noreply, HeldFields.restore(saved, held)}
  end

  # `origin` is `:page` for a browser post, `{:built, bases}` for a change the
  # server built. Only a browser post is read for codelist shape
  # (`CodelistShape`): a built one writes a stored value back as it is.
  defp autosave_open(params, socket, origin) do
    params = PostIdentity.no_marks(params)
    socket = socket |> track_touched(params) |> assign(editor_write_landed: nil)

    case params
         |> fold_dot_paths(socket)
         |> KeptRows.only_stored(base_form(socket))
         |> KeptCodes.only_touched(base_form(socket), socket.assigns[:editor_schema]) do
      %{"doc" => posted} = folded ->
        # A rich text in an object written over another editor's change is
        # not written over it (`RichTextRemote`, task-47be2cdf59d0acd5).
        {doc, held} = RichTextRemote.split(socket, posted, params["_bp_rt_seen"])
        # Read again under the document's lock: the store may have moved
        # since (`RichTextRemote.UnderLock`, task-00c56c6a88ed0b8f).
        rich =
          Map.merge(
            RichTextRemote.UnderLock.values(
              socket,
              params["_bp_rt_seen"],
              posted,
              params["_bp_rt_owner"]
            ),
            RichTextRemote.UnderLock.top(socket, posted, params["_bp_seen"])
          )

        # A free-text field's post is merged onto the stored value from the
        # base the page reports (`RemoteValues`, task-35956a566dd2c862).
        keys = target_key(params, socket.assigns[:editor_schema])
        path = target_path(params, keys)
        {doc, not_codes, built_bases} = page_codes(doc, socket, origin)
        # A page that rejoined a new socket, typed on a value it never took
        # (`TextRejoin`, task-4fc7383b936f606a).
        {targets, units} = TextRejoin.units(socket.assigns[:editor_schema], keys, path, doc)

        {doc, typed} =
          TextRejoin.split(socket, units, params["_bp_seen"], doc, targets, :autosave)

        based =
          socket
          |> RemoteValues.put_bases(keys, params["_bp_seen"], path)
          |> RemoteValues.add_bases(built_bases)

        # So is a free-text field (`TextUnderLock`, task-5b8f13c40a052514),
        # read against what the page showed (task-eeecd067e3fb1b1f).
        text = TextUnderLock.values(based, keys, params["_bp_seen"], path)

        based =
          based
          |> assign(editor_rt_under_lock: rich, editor_text_under_lock: text)
          |> RichTextRemote.UnderLock.posted(
            params["_bp_rt_seen"],
            posted,
            params["_bp_rt_owner"]
          )

        written =
          based
          |> RefusedSave.target(keys, path)
          |> Shared.do_autosave(doc, :change)

        text_held = TextUnderLock.held(written, text, doc)

        saved =
          written
          |> assign(editor_text_held: text_held)
          |> RemoteValues.settle(socket, keys, doc, path)

        bases = based.assigns[:editor_field_bases] || %{}

        saved =
          saved
          |> assign(editor_rt_under_lock: nil, editor_text_under_lock: nil, editor_text_held: nil)
          |> keep_unsaved_values(doc, keys)
          |> UnsavedBases.record(socket, keys, bases, params["_bp_seen"], path)
          |> RefusedSave.not_codes(not_codes)
          |> settle_dirty(keys)
          |> TextUnderLock.hold(text_held, doc)
          |> TextRejoin.hold(typed)
          |> TextConfirmed.confirm(targets, posted)

        {saved, held} = RichTextRemote.UnderLock.acts(saved, held, rich, {doc, posted})

        {:noreply,
         saved
         |> RichTextRemote.hold(held)
         |> TextConfirmed.paused(rich)
         |> row_draws()
         |> moved_rows(folded, params)}

      _ ->
        {:noreply, socket}
    end
  end

  # Each row rich text the form now holds is a draw the page may show once a
  # remount reaches it: A's own array press (a duplicate's new key, a move)
  # and A's own save (a merged value) remount rows too (#29040 r2 review).
  defp row_draws(socket),
    do: RichTextRemote.RowDraws.record_form(socket, socket.assigns[:editor_form])

  defp page_codes(doc, socket, :page) do
    {doc, not_codes} = CodelistShape.split(doc, socket.assigns[:editor_schema])
    {doc, not_codes, %{}}
  end

  defp page_codes(doc, _socket, {:built, bases}), do: {doc, [], bases}

  # ── The dot-path fold (S9 crit 3, task-6d80c6cc7d97b1d1) ────────────────────
  #
  # `LocalizedTextField` renders its per-language inputs with a BRACKET
  # envelope followed by a DOT segment — `name="doc[altText].nob"` — and the
  # nested composite / array renderers compose the same shape.
  # `Plug.Conn.Query.decode/1`, which Phoenix applies to the serialized form,
  # only nests BRACKET segments: a trailing `.nob` is not one, so that input
  # arrives as a FLAT top-level key `"doc[altText].nob"` and never lands inside
  # the `"doc"` map `Shared.do_autosave/2` writes from.
  #
  # The value was therefore DISCARDED on every save. That is why an editor
  # still could not write alt text once the asset panel opened: the field
  # rendered, took the keystrokes, and dropped them.
  #
  # `StudioLive.parse_path/1` already understands exactly this shape — it is
  # what `array_op/2` parses its `phx-value-path` with, and it strips the
  # `doc[` envelope itself. Folding here reuses that parser rather than adding
  # a second reading of the same syntax, and it changes NOTHING that is
  # rendered: the input names stay as they are, so the paper-canvas and ONIX
  # surfaces that also emit them keep their markup and simply start persisting.
  #
  # Fold only when there is something to fold: an untouched params map must
  # come back byte-identical, or a payload with no `"doc"` key at all would
  # gain an empty one and save a blank document over a real one.
  #
  # ── Which EMPTY values fold (task-bf3c7b7af0071f0d) ────────────────────────
  #
  # A composite field renders EVERY subfield on every render, so a task form
  # posts `doc[purpose].importance.score=""` and eighteen siblings whether or
  # not the author touched them. Folding all of those in as `""` submits empty
  # strings into typed composite slots and the write is REFUSED — two
  # task-editor saves regressed to "Save failed" when this fold was
  # unconditional, which is why #16066 skipped every empty value.
  #
  # Skipping ALL empties has its own cost, and it is the defect this function
  # now closes: an author who CLEARS a localized value (alt text, caption) back
  # to empty had the clear dropped on the floor and the OLD value survived the
  # save.
  #
  # The distinction the two cases actually turn on is not the VALUE — both are
  # `""` — it is whether the author TOUCHED that input. LiveView already
  # carries that: `phx-change` sends `_target`, the name of the input that
  # fired the change, and `Phoenix.LiveView.Channel.decode_merge_target/1`
  # hands it to `handle_event/3` as a list. A dotted field name does not end in
  # `]`, so `Plug.Conn.Query.decode/1` leaves it whole and `_target` arrives as
  # `["doc[altText].nob"]` — the exact params key being folded, no re-parsing.
  #
  # `track_touched/2` accumulates those keys in `editor_touched_paths` as the
  # autosaves arrive (a `phx-submit` carries no `_target`, so the set must
  # OUTLIVE the change event that cleared the field), and the fold admits an
  # empty value only for a key in that set. An untouched empty subfield the
  # renderer posted is still dropped exactly as before, so the composite saves
  # are unaffected; a cleared field the author actually typed in now persists
  # as cleared. The set is emptied wherever the buffer becomes clean again —
  # explicit save, remote reload, navigation (`Lifecycle.finish_handle_params`)
  # — so a touched path can never leak onto the NEXT document opened.
  defp fold_dot_paths(params, socket) do
    names = StudioLive.Path.field_names(socket.assigns[:editor_schema])
    params = StudioLive.Path.unmangle_params(params, names)
    touched = touched_paths(socket)
    base_form = base_form(socket)
    targets = params |> Map.get("_target") |> List.wrap()
    row_keys = params |> Enum.filter(fn {k, _} -> doc_key?(k) end) |> posted_row_keys()

    {dotted, rest} =
      Enum.split_with(params, fn {k, v} ->
        doc_key?(k) and foldable?(k, v, touched) and
          not kept_value?(k, v, targets, {row_keys, base_form})
      end)

    if dotted == [] do
      params
    else
      rest = Map.new(rest)
      doc = Map.get(rest, "doc", %{})

      {doc, moved, written} =
        Enum.reduce(dotted, {doc, [], MapSet.new()}, fn {key, value}, {acc, moved, written} ->
          case leaf_path(key, row_keys, base_form) do
            {:ok, path} ->
              {acc |> seed_root(path, base_form) |> write_leaf(socket, path, value), moved,
               MapSet.put(written, path)}

            {:moved, path} ->
              {acc, [{key, path, value} | moved], written}

            _ ->
              {acc, moved, written}
          end
        end)

      # A row found under another parent is never written: its rich texts
      # A typed in are held there (`RichTextRemote.MovedRows`). A held row
      # rich text the post did not carry keeps the stored value, not the
      # view the seeded root took from the form.
      rest
      |> Map.put("doc", RichTextRemote.MovedRows.stored_at_holds(doc, socket, written))
      |> then(&if(moved == [], do: &1, else: Map.put(&1, @moved, Enum.reverse(moved))))
    end
  end

  # ── A row's leaves go to the row of its posted `_key` (task-406358090c6137e7)
  #
  # The fold writes by index into the editor's own rows (`seed_root/3`). A post
  # sent before the page took a change to the rows (another editor took a row
  # out, so the next one moved up) names its rows by the old indexes: its
  # `rows[0]` was the row taken out, and its leaves were written over the row
  # now at 0, `_key` and all. Each row the post names a `_key` for is written
  # at the index that row has now. A row found under another parent
  # (`moved/3`) is held there, not written; a row the editor no longer holds
  # is dropped, never written into another. A row posted with no `_key` is
  # written by index, as before.
  defp posted_row_keys(dotted) do
    for {name, key} <- dotted,
        is_binary(key),
        path = StudioLive.parse_path(name),
        match?([_, _ | _], path),
        List.last(path) == "_key",
        prefix = Enum.drop(path, -1),
        is_integer(List.last(prefix)),
        into: %{},
        do: {prefix, key}
  end

  defp row_path(path, keys, form) when map_size(keys) == 0 or not is_map(form), do: {:ok, path}
  defp row_path(path, keys, form), do: row_path(path, [], [], {keys, form})

  defp row_path([], _posted, now, _ctx), do: {:ok, Enum.reverse(now)}

  defp row_path([i | rest], posted, now, {keys, form} = ctx) when is_integer(i) do
    posted = [i | posted]

    with {:ok, key} <- Map.fetch(keys, Enum.reverse(posted)),
         rows when is_list(rows) <- form_at(form, Enum.reverse(now)) do
      case row_index(rows, key, i) do
        nil ->
          case moved(form, Enum.reverse(posted), key) do
            {:ok, at} -> moved_path(row_path(rest, posted, Enum.reverse(at), ctx))
            :error -> :drop
          end

        j ->
          row_path(rest, posted, [j | now], ctx)
      end
    else
      _ -> row_path(rest, posted, [i | now], ctx)
    end
  end

  defp row_path([seg | rest], posted, now, ctx),
    do: row_path(rest, [seg | posted], [seg | now], ctx)

  # The row at `i` still has the key: `i`. Else the one row that has it
  # now; none: dropped. Two rows of one key (written past the API's own
  # checks): by index, as before, never matched to the first for both.
  defp row_index(rows, key, i) do
    if match?(%{"_key" => ^key}, Enum.at(rows, i)) do
      i
    else
      case for({%{"_key" => ^key}, j} <- Enum.with_index(rows), do: j) do
        [] -> nil
        [j] -> j
        _ -> i
      end
    end
  end

  defp leaf_path(key, row_keys, base_form) do
    case StudioLive.parse_path(key) do
      [_ | _] = path -> row_path(path, row_keys, base_form)
      _ -> :error
    end
  end

  defp moved_path({:ok, path}), do: {:moved, path}
  defp moved_path(other), do: other

  # A row whose list no longer holds its `_key`: another editor moved it
  # under another parent (task-3422ba9e403f8b75), or Duplicate copied it
  # with its `_key` and the original is gone (#29180 review, P1b): the post
  # cannot tell. Its leaves name the one row of that field shape (the posted
  # path, any indexes) that holds the key, `{:moved, path}`, and are never
  # written there: A's typed rich texts are held in it. None, or two:
  # dropped.
  defp moved(form, posted, key) do
    shape = Enum.map(posted, &if(is_integer(&1), do: :row, else: &1))

    case for({at, %{"_key" => ^key}} <- rows_of(form, shape, []), do: at) do
      [at] -> {:ok, at}
      _ -> :error
    end
  end

  defp rows_of(value, [], at), do: [{Enum.reverse(at), value}]

  defp rows_of(rows, [:row | rest], at) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, i} -> rows_of(row, rest, [i | at]) end)
  end

  defp rows_of(%{} = value, [seg | rest], at) when is_binary(seg),
    do: rows_of(Map.get(value, seg), rest, [seg | at])

  defp rows_of(_value, _shape, _at), do: []

  defp form_at(form, path) do
    Enum.reduce_while(path, form, fn
      seg, %{} = acc when is_binary(seg) -> {:cont, Map.get(acc, seg)}
      i, acc when is_integer(i) and is_list(acc) -> {:cont, Enum.at(acc, i)}
      _, _ -> {:halt, nil}
    end)
  end

  # ── Seed the CONTAINER before writing into it (this task) ──────────────────
  #
  # `Plug.Conn.Query.decode/1` gives back only what the dotted names carry, so
  # the fold's `doc` starts with NO value at the path's root — for
  # `doc[acceptance_criteria][0].criterion` there is no
  # `doc["acceptance_criteria"]` at all. `put_value_at/3` refuses to invent an
  # intermediate: descending an integer segment into a fresh `%{}` matches no
  # clause and falls through to the no-op, so the folded value came out as
  # `%{"acceptance_criteria" => %{}}` — the keystrokes gone AND the array
  # replaced by an empty map. On `task` the kind validator refused the write
  # ("Save failed"), which is the only reason the criteria survived at all; on
  # any other type with an `arrayOf`-of-`composite` field the empty map SAVES
  # and the whole list is destroyed.
  #
  # Seeding the root from the editor's own buffer is what makes the write a
  # PATCH instead of a reconstruction: the existing rows are already there, so
  # `put_value_at/3` replaces exactly the one leaf the name addresses. That is
  # also what preserves keys no input renders — a criterion's `merge_gate` is
  # not in the schema's composite (`criterion`/`met`/`evidence` only), so
  # nothing posts it back and only the seeded row can carry it through.
  #
  # Only the ROOT is seeded, and only when the decoded `doc` has nothing there:
  # every dotted sibling in the same payload still writes its own leaf on top,
  # so a value the author changed always wins over the seeded one.
  defp seed_root(doc, [root | _rest], base_form) when is_binary(root) and is_map(doc) do
    cond do
      Map.has_key?(doc, root) -> doc
      not is_map(base_form) -> doc
      not Map.has_key?(base_form, root) -> doc
      true -> Map.put(doc, root, Map.get(base_form, root))
    end
  end

  defp seed_root(doc, _path, _base_form), do: doc

  # ── An emptied language is removed (B06) ────────────────────────────────────
  #
  # A localizedText language the author emptied is unset, as the TanStack
  # Studio unsets it: `{"nob" => "", "eng" => "…"}` is stored as
  # `{"eng" => "…"}`, and a field left with no text is removed
  # (`unset_language/3`). Only a
  # TOUCHED empty value reaches here (`foldable?/3`), so a language the author
  # never typed in is kept as stored. Only in the desk (the one host with a
  # `:desk_base`): the old Studio stores the emptied language as "", as it
  # always has.
  defp write_leaf(doc, %{assigns: %{desk_base: base}} = socket, path, "") when is_binary(base) do
    parent = Enum.drop(path, -1)

    case Shared.find_field_by_path(socket, parent) do
      %{"type" => "localizedText"} -> unset_language(doc, parent, List.last(path))
      _ -> StudioLive.put_value_at(doc, path, coerce_leaf(socket, path, ""))
    end
  end

  defp write_leaf(doc, socket, path, value),
    do: StudioLive.put_value_at(doc, path, coerce_leaf(socket, path, value))

  # The language's key goes. When nothing left in the field holds text (every
  # other language "" or none), the field itself is unset, and so on outward:
  # an object left with only blanks is unset in turn, as TanStack's `write()`
  # (`edits.ts`) does, so no `{}` shell is stored that `defined()` reads as
  # set. A top-level field is unset by writing "" (the save takes the key
  # off). Inside an array row nothing is unset outward, as TanStack's: the
  # language only loses its key, and an object left empty stays `{}`.
  defp unset_language(doc, parent, lang) do
    case value_at(doc, parent) do
      %{} = map when not is_struct(map) ->
        left = Map.delete(map, lang)

        if blank_map?(left) and not in_row?(parent),
          do: unset_at(doc, parent),
          else: put_at(doc, parent, left)

      _ ->
        doc
    end
  end

  # Also a desk Remove in a tree codelist (`picked_form/3`).
  defp unset_at(doc, [root]), do: Map.put(doc, root, "")

  # A key in an object is written as `Forms.unset/0`, which the save reads
  # as unset: a key left out would be kept as stored, and a nil is a stored
  # null the form drew back.
  defp unset_at(doc, path) do
    {parent, [key]} = Enum.split(path, -1)

    case value_at(doc, parent) do
      %{} = map when not is_struct(map) ->
        left = Map.put(map, key, Forms.unset())

        if blank_map?(left) and not in_row?(parent),
          do: unset_at(doc, parent),
          else: put_at(doc, parent, left)

      _ ->
        doc
    end
  end

  defp put_at(doc, [root], value), do: Map.put(doc, root, value)
  defp put_at(doc, path, value), do: StudioLive.put_value_at(doc, path, value)

  # Blank as TanStack's `write()` reads it: "" or none; `_type` alone does
  # not make an object set.
  defp blank_map?(map),
    do: Enum.all?(map, fn {key, value} -> key == "_type" or value in [nil, "", Forms.unset()] end)

  # The path is the document's top, or lies inside an array row (any step
  # is an index): TanStack's `write()` unsets no parent there.
  defp in_row?([]), do: true
  defp in_row?(path), do: Enum.any?(path, &is_integer/1)

  defp value_at(value, []), do: value
  defp value_at(%{} = map, [key | rest]), do: value_at(Map.get(map, key), rest)

  defp value_at(list, [index | rest]) when is_list(list) and is_integer(index),
    do: value_at(Enum.at(list, index), rest)

  defp value_at(_value, _path), do: nil

  defp base_form(socket), do: socket.assigns[:editor_form] || %{}

  # ── Coerce the leaf the way `build_content/2` coerces a TOP-LEVEL field ────
  #
  # A form posts every value as a string. `Forms.build_content/2` already turns
  # a top-level `boolean` field's "true"/"false" into a real boolean and a
  # `number` field's digits into an integer — the JSONB type flip found live on
  # 2026-06-12. Nothing did that for a value arriving through a dotted name,
  # because until this fold those values never reached storage at all: the
  # moment a criterion row starts persisting, `met` would land as the STRING
  # "false" under a `met == true` reader.
  #
  # `Shared.find_field_by_path/2` resolves the schema field at the path
  # (descending composites and arrayOf, skipping row indices), so the leaf is
  # coerced by its DECLARED type, not by guessing from the value. An
  # unresolvable path or any other type keeps the string as-is, which is what
  # the schema validator wants to see and reject.
  defp coerce_leaf(socket, path, value) when is_binary(value) do
    case Shared.find_field_by_path(socket, path) do
      %{"type" => "boolean"} -> coerce_boolean(value)
      %{"type" => "number"} -> coerce_number(value)
      _ -> value
    end
  end

  defp coerce_leaf(_socket, _path, value), do: value

  defp coerce_boolean("true"), do: true
  defp coerce_boolean("false"), do: false
  defp coerce_boolean(other), do: other

  defp coerce_number(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  # A "" posted at a dotted path whose stored value is not a string (a number,
  # an object or a list an import wrote into a codelist) is what a kept field
  # posts (`CompositeField`, "Not a code"): the input cannot show the value.
  # It is written only when THIS post is a change of that input (`_target`),
  # the rule `KeptCodes.only_touched/3` keeps for a top-level codelist. The
  # session's touched set is not enough: a path picked earlier, then given a
  # number by another editor, posts "" with every later change of the form.
  #
  # The stored value is read at the row the post is for: by its posted `_key`,
  # where the row is now (`row_path/3`), never at the posted index, which
  # after another editor moved the rows holds another row (task-9dc943bf59b530fa).
  defp kept_value?(key, "", targets, {row_keys, form}) do
    key not in targets and
      with [_ | _] = path <- StudioLive.parse_path(key),
           {:ok, path} <- row_path(path, row_keys, form) do
        stored_at(form, path) |> then(&(not is_nil(&1) and not is_binary(&1)))
      else
        _ -> false
      end
  end

  defp kept_value?(_key, _value, _targets, _form), do: false

  defp doc_key?(key), do: is_binary(key) and String.starts_with?(key, "doc[")

  defp stored_at(value, []), do: value

  defp stored_at(%{} = map, [key | rest]) when is_binary(key),
    do: stored_at(Map.get(map, key), rest)

  defp stored_at(list, [idx | rest]) when is_list(list) and is_integer(idx),
    do: stored_at(Enum.at(list, idx), rest)

  defp stored_at(_value, _path), do: nil

  defp foldable?(_key, value, _touched) when is_nil(value), do: false
  defp foldable?(key, "", touched), do: MapSet.member?(touched, key)
  defp foldable?(_key, _value, _touched), do: true

  # `_target` names the ONE input that fired this change. Only dotted `doc[...]`
  # keys are tracked, and only when the key is actually present in this payload
  # — a `_target` for a plain bracket name decodes to segments (`["doc",
  # "title"]`) that are not params keys at all, and those fields never needed
  # the fold.
  defp track_touched(socket, params) do
    targets =
      params
      |> Map.get("_target")
      |> List.wrap()
      |> Enum.filter(fn t ->
        is_binary(t) and String.starts_with?(t, "doc[") and Map.has_key?(params, t)
      end)

    if targets == [] do
      socket
    else
      assign(socket,
        editor_touched_paths: MapSet.union(touched_paths(socket), MapSet.new(targets))
      )
    end
  end

  defp touched_paths(socket), do: socket.assigns[:editor_touched_paths] || MapSet.new()

  defp clear_touched(socket), do: assign(socket, editor_touched_paths: MapSet.new())

  def toggle_content_preview(socket) do
    {:noreply, assign(socket, content_preview_visible: !socket.assigns.content_preview_visible)}
  end

  def toggle_diff(socket) do
    {:noreply, assign(socket, diff_visible: !socket.assigns.diff_visible)}
  end

  def editor_set_mode(%{"mode" => mode}, socket) do
    # Eligibility must come from the refreshed identity-checked baseline, not
    # the previous document state (which may now contain ambiguous block IDs).
    socket = if mode == "beta", do: Shared.sync_editor_blocks(socket), else: socket

    next =
      case mode do
        "beta" -> if Shared.beta_editable?(socket), do: :beta, else: :classic
        _ -> :classic
      end

    {:noreply, assign(socket, editor_mode: next)}
  end

  # A tags field's Enter and × (`TagsField`, `Handlers.Tags`).
  def array_op(%{"action" => action} = params, socket) when action in ~w(add_tag remove_tag),
    do: BarkparkWeb.Studio.StudioLive.Handlers.Tags.array_op(params, socket)

  def array_op(%{"action" => action} = params, socket) do
    path = StudioLive.parse_path(params["path"] || "")

    {field, key_path} =
      case path do
        [] ->
          case params["field"] do
            name when is_binary(name) -> {Shared.find_field(socket, name), [name]}
            _ -> {nil, []}
          end

        _ ->
          {Shared.find_field_by_path(socket, path), path}
      end

    if is_nil(field) or key_path == [] do
      {:noreply, socket}
    else
      idx = Shared.parse_idx(params["index"])
      form = socket.assigns[:editor_form] || %{}
      current = StudioLive.list_value_at(form, key_path)

      new_list =
        case action do
          "add_row" ->
            add_row(current, field, params["member"], keyed_parent?(form, key_path))

          "remove_row" ->
            ArrayField.remove_row(current, idx)

          "move_up" ->
            ArrayField.move_up(current, idx)

          "move_down" ->
            ArrayField.move_down(current, idx)

          other ->
            ArrayItems.apply_op(other, current, idx, field, params, keyed_parent?(form, key_path))
        end

      new_form = StudioLive.put_value_at(form, key_path, new_list)
      # A refused array change is held under its own field (`RefusedSave`).
      keys = Enum.take(key_path, 1)
      {new_form, held} = HeldFields.stored(socket, new_form, keys)
      saved = socket |> RefusedSave.target(keys) |> Shared.do_autosave(new_form, :array_op)
      {:noreply, saved |> settle_dirty(keys) |> row_draws() |> HeldFields.restore(held)}
    end
  end

  @doc false
  # A new row. In a several-member array (`of` is a list) it is the member the
  # editor chose, with `_type` and a fresh `_key`; with no chosen member,
  # nothing is added. In a single-`of` array whose rows carry Sanity's `_key`
  # (and `_type`), the new row gets them too, so the list keeps one shape
  # (task-e24e33a2a1a4fe10).
  #
  # `keyed_parent?` says the list sits inside an object that carries a `_key`
  # (a page-builder item, a custom block): Sanity's shape, where every object
  # in an array has a `_key`. A first row of an empty list there gets one too.
  def add_row(current, field, member, keyed_parent? \\ false)

  def add_row(current, %{"of" => members} = field, member, _keyed_parent?)
      when is_list(members) do
    case BarkparkWeb.Studio.StudioLive.Path.empty_for_of(field, member) do
      %{} = row -> ArrayField.add_row(current, row)
      _ -> current
    end
  end

  def add_row(current, field, _member, keyed_parent?) do
    row = StudioLive.empty_for_of(field)

    keyed? =
      if current == [],
        do: keyed_parent?,
        else: Enum.all?(current, &match?(%{"_key" => _}, &1))

    row =
      if is_map(row) and keyed? do
        row
        |> Map.put("_key", BarkparkWeb.Studio.StudioLive.Path.new_key())
        |> maybe_put_type(field, current)
      else
        row
      end

    ArrayField.add_row(current, row)
  end

  defp maybe_put_type(row, %{"of" => %{"namedType" => t}}, current) when is_binary(t) do
    if Enum.all?(current, &match?(%{"_type" => _}, &1)), do: Map.put(row, "_type", t), else: row
  end

  defp maybe_put_type(row, _field, _current), do: row

  @doc false
  # True when an object on the way to the list at `path` carries a `_key`.
  def keyed_parent?(value, path) do
    path
    |> Enum.drop(-1)
    |> Enum.reduce_while({value, false}, fn seg, {v, _} ->
      next =
        cond do
          is_integer(seg) and is_list(v) -> Enum.at(v, seg)
          is_binary(seg) and is_map(v) -> Map.get(v, seg)
          true -> nil
        end

      cond do
        is_map(next) and is_map_key(next, "_key") -> {:halt, {next, true}}
        is_nil(next) -> {:halt, {nil, false}}
        true -> {:cont, {next, false}}
      end
    end)
    |> elem(1)
  end

  # `editor_dirty` gates the concurrent-edit guard in
  # `Handlers.Lifecycle.doc_updated/2` + `document_changed/2`: while it is set,
  # a remote save does not replace the buffer. It means "the buffer holds an
  # edit the store does not have", so a save that LANDED clears it
  # (task-6f5426c4b04de74b): the form then equals the store, and a later remote
  # save refreshes it. Before, the first keystroke set it for the rest of the
  # session, every remote save after it read as a conflict, B's form kept A's
  # old values, and B's next keystroke in that field wrote them back over A's.
  # A save that did not land keeps the buffer dirty and remembers the field
  # typed in (`editor_unsaved_keys`), so a remote save keeps that field and
  # takes the others. Also reset on navigation, explicit save and Reload.
  #
  # A landed save also takes down the "Updated by another user" banner: what
  # it said was kept is now saved (#25880 review).
  @doc false
  def settle_dirty(socket, keys) do
    # The header names a title held unsaved, and the stored one once it lands.
    socket |> settled_dirty(keys) |> Shared.assign_page_title()
  end

  defp settled_dirty(socket, keys) do
    if socket.assigns[:save_status] == "Saved" do
      # A field the store refused earlier is still not saved (`RefusedSave`).
      held = MapSet.new(RefusedSave.keys(socket))
      dirty? = MapSet.size(held) > 0

      assign(socket,
        editor_dirty: dirty?,
        editor_unsaved_keys: held,
        editor_unsaved_bases: UnsavedBases.only(UnsavedBases.all(socket), held),
        doc_conflict: false
      )
    else
      settle_unsaved(socket, keys -- RefusedSave.clears(socket))
    end
  end

  # A refused clear is not kept (`RefusedSave`): the field is as stored.
  defp settle_unsaved(socket, []), do: socket

  defp settle_unsaved(socket, keys) do
    unsaved = socket.assigns[:editor_unsaved_keys] || MapSet.new()

    assign(socket,
      editor_dirty: true,
      editor_unsaved_keys: MapSet.union(unsaved, MapSet.new(keys))
    )
  end

  # A save that did not land leaves the typed field's posted value in the form
  # buffer, so a remote save that keeps the unsaved field keeps the typing, not
  # the value from before it (#25880 review). Only `keys`, the field typed in:
  # every other posted value is what the browser showed, which can be older
  # than what the server already took from the other editor (#25946 review).
  # Same shape as a landed save's buffer (`Forms.coerce_params/2`). A refused
  # clear is left out: the field stays as stored (`RefusedSave`).
  defp keep_unsaved_values(socket, posted, keys) do
    if socket.assigns[:save_status] in ["Save failed", "Save cancelled"] do
      posted =
        posted
        |> Barkpark.Content.Forms.coerce_params(socket.assigns[:editor_schema])
        |> Map.take(keys -- RefusedSave.clears(socket))

      PostedEdits.put(socket, posted)
    else
      socket
    end
  end

  # The top-level field a `phx-change` typed in, from its `_target`:
  # `["doc", "title"]` for a bracket name, `["doc[altText].nob"]` for a dotted one.
  # A checkbox list in an object or a row names its whole path in one
  # bracket, dotted (`doc[obj.tags][]`): its field is the first part, unless
  # the key is a top-level field's own name (`Path.target_field/2`).
  defp target_key(%{"_target" => ["doc", key | _]}, schema) when is_binary(key),
    do: [StudioLive.Path.target_field(key, StudioLive.Path.field_names(schema))]

  defp target_key(%{"_target" => [name]}, _schema) when is_binary(name) do
    case StudioLive.parse_path(name) do
      [key | _] when is_binary(key) -> [key]
      _ -> []
    end
  end

  defp target_key(_params, _schema), do: []

  # The changed input's path under its top-level field: `doc[meta].code`
  # is `["meta", "code"]`. nil when it is not under the one target field.
  defp target_path(params, [key]) do
    path =
      case params do
        %{"_target" => ["doc", _ | rest]} -> [key | rest]
        %{"_target" => [name]} when is_binary(name) -> StudioLive.parse_path(name)
        _ -> []
      end

    if match?([^key | _], path), do: path
  end

  defp target_path(_params, _keys), do: nil
end
