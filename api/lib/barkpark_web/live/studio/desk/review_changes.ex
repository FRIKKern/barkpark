defmodule BarkparkWeb.Studio.Desk.ReviewChanges do
  @moduledoc """
  Sanity's Review changes for the document in the desk's edit pane, as the
  TanStack Studio has it (`ReviewChanges.tsx`, `Fields.tsx` `ChangeBar`):
  the History inspector's second tab lists every field the draft changed
  since the document was last published, the change itself (`ReviewDiff`)
  and a Revert for each; with more than one change, Revert all. Each asks
  first, with Sanity's words.

  - **What is compared** (`compare/2`). With a draft: the published
    version, then the draft. With none, right after a publish: what that
    publish changed, the publish before it, then it. Otherwise nothing,
    and the tab says "There are no changes". The range is named as
    Sanity names it ("Published: …", "Edited: …"). The From and To
    pickers show the range; picking another one is not drawn yet.
  - **The change bar** (`bar/2`). Beside each top-level field the draft
    changed since publish, a thin line that opens Review changes. None on
    a document never published, nor over an old revision.
  - **Revert** (`revert/2`, the event `desk-field-revert`) writes the
    compared value of one field, or of every changed field, back into the
    draft: one write per field, each the Studio's own autosave of that
    field (`EditorHost.write_built/2`), with the guards a typed change
    gets. The event names its document (`PostIdentity`); one pressed in
    another document, or none, writes nothing. What is written is read
    again when it is pressed, not taken from the page: the browser names
    a field, never a value. A field the form does not let this editor
    change is not written. Nothing is written while a revision is shown
    in the form's place (`RevisionView`).

  Reads. The published version is read once for each draft (one scoped
  read when the editor first holds a draft of a published document, kept
  in `desk_published`), not per field and not per keystroke. The timeline
  is the History inspector's own read (`HistoryPanel`). Referenced
  documents' titles are one read for all of a diff's references.

  `EditorHost` calls `follow/1` after every answer of the editor and every
  URL change; it owns the `desk_published`, `desk_changes` and
  `desk_review` assigns.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.Desk.FieldDiff
  alias BarkparkWeb.Studio.Desk.FieldLock
  alias BarkparkWeb.Studio.Desk.HistoryPanel
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.RevisionView
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias Phoenix.LiveView.JS

  # The snapshots read to credit authors (TanStack's SNAPSHOTS).
  @snapshots 12
  # The revisions a revert reads to find the publish before the last one.
  @limit 100
  # Inputs LiveView does not patch: a new value remounts them.
  @widget_types ~w(richText reference image)

  @doc """
  The editor answered or the URL changed: the published version (read once
  per draft), the fields the draft changed, and the Review changes tab
  while it is open.
  """
  def follow(socket) do
    socket |> published() |> changes() |> review()
  end

  defp published(%{assigns: assigns} = socket) do
    key = published_key(assigns)

    case assigns[:desk_published] do
      %{key: ^key} -> socket
      _ when key == nil -> assign(socket, :desk_published, nil)
      _ -> assign(socket, :desk_published, %{key: key, doc: read_published(socket)})
    end
  end

  # Which published version the open draft is compared with: none for a
  # document that is not a draft, or that was never published.
  defp published_key(%{editing: {dataset, type, id}, editor_doc: %{}} = assigns) do
    if assigns[:editor_is_draft] == true and assigns[:editor_has_published] == true,
      do: {dataset, type, Content.published_id(id)}
  end

  defp published_key(_assigns), do: nil

  defp read_published(%{assigns: %{editing: {dataset, type, id}}} = socket) do
    case Content.get_document(
           Content.published_id(id),
           type,
           dataset,
           ScopeHelpers.scope_opts(socket)
         ) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  # The change bars: the top-level fields the draft changed since publish,
  # and where a bar takes you.
  defp changes(%{assigns: assigns} = socket) do
    case {assigns[:desk_published], assigns[:editor_doc]} do
      {%{doc: %{} = pub}, %{} = doc} ->
        names =
          assigns[:editor_schema]
          |> FieldDiff.fields()
          |> FieldDiff.changes(FieldDiff.values(pub), FieldDiff.values(doc))
          |> MapSet.new(& &1.name)

        assign(socket, :desk_changes, %{fields: names, href: href(assigns)})

      _ ->
        assign(socket, :desk_changes, nil)
    end
  end

  @doc "The URL that opens Review changes on the edited pane."
  def href(%{chain: [_ | _] = chain, base: base} = assigns) do
    perspective = Panes.perspective(assigns[:desk_uri])
    HistoryPanel.path(chain, length(chain) - 1, base, perspective, %{inspect: "review", rev: nil})
  end

  @doc """
  Where the change bar of field `name` leads, for `FieldSlots`: Review
  changes when the draft changed the field, else nil (no bar).
  """
  def bar(assigns, name) do
    case assigns[:desk_changes] do
      %{fields: fields, href: href} when is_binary(name) ->
        if MapSet.member?(fields, name), do: href

      _ ->
        nil
    end
  end

  # ── The tab ───────────────────────────────────────────────────────────────

  defp review(%{assigns: assigns} = socket) do
    pane = List.last(assigns[:chain] || [])

    if is_map(assigns[:editor_doc]) and HistoryPanel.open?(pane || %{}) and
         HistoryPanel.tab(pane) == :review do
      revisions = (assigns[:desk_history] && assigns.desk_history[:revisions]) || []
      published = assigns[:desk_published] && assigns.desk_published.doc
      shown = compare(assigns, published, revisions)
      assign(socket, :desk_review, Map.put(shown, :titles, titles(socket, shown.changes)))
    else
      assign(socket, :desk_review, nil)
    end
  end

  @doc """
  What Review changes shows: the two ends of the range, as Sanity names
  them, and the changed fields with who changed each. `published` is the
  published version (for a draft), `revisions` the timeline, newest first.
  """
  def compare(assigns, published, revisions) do
    doc = assigns.editor_doc
    fields = FieldDiff.fields(assigns[:editor_schema])
    draft? = assigns[:editor_is_draft] == true
    {drafts, publish} = since_last_publish(revisions)
    publishes = Enum.filter(revisions, &(&1.action == "publish"))

    {before, after_, snaps, from, to} =
      cond do
        draft? ->
          from =
            cond do
              publish -> published_at(publish)
              drafts != [] -> named(List.last(drafts))
              published -> gettext("Published")
              true -> gettext("Not published")
            end

          to = if drafts != [], do: named(hd(drafts)), else: gettext("Current draft")
          base = if published, do: FieldDiff.values(published), else: %{}

          {base, FieldDiff.values(doc), Enum.take(drafts, @snapshots) ++ List.wrap(publish), from,
           to}

        match?([_, _ | _], publishes) ->
          [last, prev | _] = publishes

          between =
            Enum.drop_while(revisions, &(&1.id != last.id))
            |> Enum.take_while(&(&1.id != prev.id))

          {FieldDiff.values(prev), FieldDiff.values(last),
           Enum.take(between, @snapshots) ++ [prev], published_at(prev), published_at(last)}

        true ->
          from = if publish, do: published_at(publish), else: gettext("Published")
          values = FieldDiff.values(doc)
          {values, values, [], from, gettext("Current draft")}
      end

    authors =
      snaps |> Enum.map(&{HistoryPanel.who(&1), FieldDiff.values(&1)}) |> FieldDiff.authors()

    changes =
      for c <- FieldDiff.changes(fields, before, after_),
          do: Map.put(c, :author, List.first(authors[c.name] || []))

    %{from: from, to: to, changes: changes}
  end

  defp since_last_publish(revisions) do
    case Enum.split_while(revisions, &(&1.action != "publish")) do
      {drafts, [publish | _]} -> {drafts, publish}
      {drafts, []} -> {drafts, nil}
    end
  end

  defp published_at(rev), do: "#{gettext("Published")}: #{range_date(rev.inserted_at)}"

  defp named(rev) do
    label = Gettext.gettext(BarkparkWeb.Gettext, HistoryPanel.label(rev))
    "#{label}: #{range_date(rev.inserted_at)}"
  end

  # TanStack's `rangeDate`: "Nov 18, 2026, 3:15 AM" (the server's clock, UTC).
  defp range_date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y, %-I:%M %p")
  defp range_date(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y, %-I:%M %p")
  defp range_date(_at), do: "…"

  # The titles of every document the changes' references point at: one read.
  defp titles(socket, changes) do
    ids =
      changes
      |> Enum.flat_map(&[&1.before, &1.after])
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.flat_map(fn
        %{"_ref" => id} when is_binary(id) and id != "" -> [Content.published_id(id)]
        _ -> []
      end)
      |> Enum.uniq()

    case socket.assigns[:desk_review] do
      %{titles: %{} = known} when map_size(known) > 0 or ids == [] ->
        if Enum.all?(ids, &is_map_key(known, &1)), do: known, else: read_titles(socket, ids)

      _ ->
        read_titles(socket, ids)
    end
  end

  defp read_titles(_socket, []), do: %{}

  defp read_titles(%{assigns: assigns}, ids),
    do: Refs.titles(ids, assigns.dataset, assigns[:scope] || [])

  # ── Revert ──────────────────────────────────────────────────────────────

  @doc """
  `desk-field-revert`: the field `field` (or, with `all`, every changed
  field) written back to its compared value, one autosave per field.
  """
  def revert(params, socket) do
    with true <- PostIdentity.ours?(params, socket),
         false <- RevisionView.shown?(socket.assigns),
         false <- BarkparkWeb.Studio.Desk.PublishedView.active?(socket.assigns),
         %{} <- socket.assigns[:editor_doc],
         [_ | _] = changes <- targets(socket, params) do
      {:noreply, Enum.reduce(changes, socket, &write/2)}
    else
      _ -> {:noreply, socket}
    end
  end

  # The changes the press asks for, compared again now from what is stored:
  # the published version (or the publish before the last one) read fresh.
  defp targets(socket, params) do
    assigns = socket.assigns
    revisions = if assigns[:editor_is_draft] == true, do: [], else: read_revisions(socket)
    published = if published_key(assigns), do: read_published(socket)
    form = assigns[:editor_form] || %{}

    assigns
    |> compare(published, revisions)
    |> Map.fetch!(:changes)
    |> Enum.filter(fn c -> params["all"] in [true, "true"] or c.name == params["field"] end)
    |> Enum.filter(&FieldActions.paste?(FieldLock.resolve(&1.field, form, true), assigns[:caps]))
  end

  defp read_revisions(%{assigns: %{editing: {dataset, type, id}}} = socket),
    do:
      Content.list_revisions(
        id,
        type,
        dataset,
        [limit: @limit] ++ ScopeHelpers.scope_opts(socket)
      )

  defp read_revisions(_socket), do: []

  # One field, as its input would have posted it: the stored value itself
  # (an object, a list, an image as the save path keeps them), or nothing.
  defp write(%{name: name, field: field, before: value}, socket) do
    params = %{"doc" => %{name => posted(field, value)}, "_target" => ["doc", name]}
    {:noreply, saved} = EditorHost.write_built(params, socket)

    if field["type"] in @widget_types,
      do:
        saved
        |> assign(:editor_form_gen, Shared.next_form_gen(saved, true))
        |> BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed.redrawn(saved),
      else: saved
  end

  defp posted(field, value) do
    cond do
      FieldDiff.empty?(value) -> empty(field)
      # A yes/no as its input posts it.
      is_boolean(value) -> to_string(value)
      true -> value
    end
  end

  defp empty(%{"type" => type}) when type in ~w(string text url email slug number date datetime),
    do: ""

  defp empty(_field), do: nil

  # ── Drawing ─────────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :review, :map, default: nil, doc: "`desk_review`"

  @doc "The Review changes tab's content."
  def panel(assigns) do
    ~H"""
    <div :if={@review} id={@id} class="review" data-desk-review>
      <dl class="review-range">
        <div>
          <dt>{gettext("From")}</dt>
          <dd><.pick label={gettext("From")} text={@review.from} /></dd>
        </div>
        <div>
          <dt>{gettext("To")}</dt>
          <dd><.pick label={gettext("To")} text={@review.to} /></dd>
        </div>
      </dl>
      <%= if @review.changes == [] do %>
        <div class="review-empty">
          <h3>{gettext("There are no changes")}</h3>
          <p class="muted">
            {gettext("Edit the document or select an older version in the timeline to see a list of changes appear in this panel.")}
          </p>
        </div>
      <% else %>
        <ul class="review-list">
          <li :for={c <- @review.changes} data-field={c.name}>
            <div class="review-head">
              <span class="review-field">{c.field["title"] || c.name}</span>
            </div>
            <div class="review-body">
              <BarkparkWeb.Studio.Desk.ReviewDiff.change change={c} titles={@review.titles} />
              <button
                type="button"
                id={"#{@id}-revert-#{c.name}"}
                class="revert-one"
                aria-label={gettext("Revert changes to %{field}", field: c.field["title"] || c.name)}
                title={gettext("Revert change")}
                popovertarget={"#{@id}-confirm-one"}
                style={"anchor-name: --#{anchor(@id, c.name)}"}
                phx-click={ask(@id, c.name)}
              >
                <BarkparkWeb.Icons.desk_icon name="undo" size={21} />
              </button>
            </div>
          </li>
        </ul>
        <.confirm id={"#{@id}-confirm-one"} question={gettext("Are you sure you want to revert the change?")} action={gettext("Revert change")} />
        <%= if length(@review.changes) > 1 do %>
          <span class="menu-wrap">
            <button
              type="button"
              id={"#{@id}-revert-all"}
              class="revert-all"
              aria-label={gettext("Revert all")}
              popovertarget={"#{@id}-confirm-all"}
              style={"anchor-name: --#{anchor(@id, "all")}"}
            >
              <BarkparkWeb.Icons.desk_icon name="undo" size={17} />
              <span>{gettext("Revert all")}</span>
            </button>
          </span>
          <.confirm
            id={"#{@id}-confirm-all"}
            anchor={anchor(@id, "all")}
            question={gettext("Are you sure you want to revert all %{count} changes?", count: length(@review.changes))}
            action={gettext("Revert all")}
            all
          />
        <% end %>
      <% end %>
      <BarkparkWeb.Studio.Desk.ReviewDiff.sheet />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :text, :string, required: true

  # Sanity's From / To: the end of the range as text. Picking another end
  # is not drawn yet, so the picker is shown off.
  defp pick(assigns) do
    ~H"""
    <span class="menu-wrap">
      <button type="button" class="review-pick" aria-label={"#{@label}: #{@text}"} disabled>
        <span>{@text}</span>
        <BarkparkWeb.Icons.desk_icon name="chevron-down" size={21} />
      </button>
    </span>
    """
  end

  # A field's revert opens the one confirm the list has, named for it: the
  # confirm's button reverts that field, and the confirm sits under it.
  defp ask(id, name) do
    confirm = ~s([id="#{id}-confirm-one"])

    JS.set_attribute({"phx-value-field", name}, to: confirm <> " [data-desk-review-revert]")
    |> JS.set_attribute({"style", anchored(anchor(id, name))}, to: confirm)
  end

  # A pane's id carries the document's (with a colon), which is not a CSS
  # name: the anchor's name keeps letters, digits, - and _ only.
  defp anchor(id, name),
    do: String.replace("#{id}-revert-#{name}", ~r/[^A-Za-z0-9_-]/, "-")

  # Under the button, its right edge on the button's (the field's revert
  # sits at the panel's right); flipped where the window has no room.
  defp anchored(anchor),
    do:
      "position-anchor: --#{anchor}; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0; position-try-fallbacks: flip-inline, flip-block"

  attr :id, :string, required: true
  attr :question, :string, required: true
  attr :action, :string, required: true
  attr :anchor, :string, default: nil
  attr :all, :boolean, default: false

  # The confirm, with Sanity's words: one for a field's revert, one for
  # Revert all. Drawn once, so its question is in the page once.
  defp confirm(assigns) do
    ~H"""
    <div
      id={@id}
      popover
      role="dialog"
      aria-label={@question}
      class="dk-confirm dk-menu"
      style={@anchor && anchored(@anchor)}
    >
      <p>{@question}</p>
      <div class="confirm-actions">
        <button type="button" class="btn" popovertarget={@id} popovertargetaction="hide" autofocus>
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          class="btn danger"
          phx-click="desk-field-revert"
          phx-value-all={@all && "true"}
          popovertarget={@id}
          popovertargetaction="hide"
          data-desk-review-revert
        >
          {@action}
        </button>
      </div>
    </div>
    """
  end
end
