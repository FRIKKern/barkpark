defmodule BarkparkWeb.Studio.Desk.Discarded do
  @moduledoc """
  The draft open in the desk's editor was discarded by someone else, and the
  published version stays (live.spec:48).

  The discard's `{:doc_updated, …}` frame carries the draft it removed. The
  Studio's `doc_updated` put that in the form as the new state, so the form
  showed the dead draft, and the next keystroke's autosave wrote it back.
  Here the frame is read as what it is: the form reloads from the store (the
  published version), the pane says so, and a save the browser sent from the
  old form is dropped.

  Which saves are from the old form is the browser's to say: `bp-desk.js`
  answers `desk:discarded` with `desk-discard-seen` once the new form is on
  the page (a LiveView event is dispatched after its patch). The socket
  carries events in order, so a save that arrives before the answer was sent
  from the old form. The focused field is the one a patch does not change
  (LiveView keeps what is typed in it); the browser sets it from `values`.

  A dropped save is not silent: the pane's line then says the typing was not
  saved, and one warning is logged with the document id. Keys typed in the
  focused field and not yet sent (its debounce) never arrive as a save: the
  event also carries the old form's values (`was`), and the browser answers
  `lost: true` when the focused field no longer matches them, which counts
  as a dropped save. The answer also carries what the field held (`text`):
  the line offers it back, to read and copy, while the field takes the
  published value (so the dead draft is never written back). That offer
  stays after the next save clears the line's sentence, until another
  discard or a reload. A reconnect mounts a
  new LiveView process, whose assigns have no `desk_discarded`, so a browser
  that never answered is not stuck past it.

  Owns the `desk_discarded` assign:
  `%{doc: {type, id}, seen: boolean, dropped: boolean, lost_text: nil | String.t(),
  cleared: boolean}`, or nil.
  """

  use BarkparkWeb, :html

  import Phoenix.LiveView, only: [push_event: 3]

  require Logger

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Shared

  @doc "Whether `msg` is another session's discard of the draft open in the editor."
  def frame?(%{mutation: "discardDraft", type: type, doc_id: doc_id} = msg, assigns) do
    msg[:sender] != self() and
      match?({_dataset, ^type, _id}, assigns[:editing]) and
      elem(assigns.editing, 2) == Content.published_id(doc_id)
  end

  def frame?(_msg, _assigns), do: false

  @doc """
  The form reloads from the store and the browser is asked for the new
  form's answer. A document with nothing published left is gone: the page's
  own notice (`LiveRefresh`) says so, and writes wait for the answer all the
  same.
  """
  def reload(%{assigns: %{editing: {_dataset, type, id}}} = socket) do
    was = values(socket.assigns[:editor_form] || %{})

    socket =
      socket
      |> assign(editor_dirty: false, doc_conflict: false)
      |> Shared.rebuild_panes()

    socket
    |> assign(:desk_discarded, %{
      doc: {type, id},
      seen: false,
      dropped: false,
      lost_text: nil,
      cleared: false
    })
    |> push_event("desk:discarded", %{
      values: values(socket.assigns[:editor_form] || %{}),
      was: was
    })
  end

  @doc "A form write that must not land: it was sent from the old form."
  def drop?(assigns) do
    match?(%{seen: false}, assigns[:desk_discarded]) and open?(assigns)
  end

  # What the line offers back is the user's typing in one field: kept whole
  # up to this many characters.
  @lost_text_max 20_000

  @doc """
  A save from the old form was dropped: the line says so, logged once.
  `text`, when the browser sent it, is what the focused field held: the line
  offers it back.
  """
  def drop(socket, text \\ nil) do
    case socket.assigns[:desk_discarded] do
      %{doc: {type, id}} = d ->
        if not d.dropped,
          do:
            Logger.warning(
              "desk: a save from a discarded draft's form was dropped (#{type} #{id})"
            )

        d = %{d | dropped: true}

        d =
          if is_binary(text) and text != "",
            do: %{d | lost_text: String.slice(text, 0, @lost_text_max)},
            else: d

        assign(socket, :desk_discarded, d)

      _ ->
        socket
    end
  end

  @doc "Whether a save from the old form was dropped."
  def dropped?(assigns), do: match?(%{dropped: true}, assigns[:desk_discarded])

  @doc "The browser has the new form: what it sends now is the editor's."
  def seen(socket) do
    case socket.assigns[:desk_discarded] do
      %{} = d -> assign(socket, :desk_discarded, %{d | seen: true})
      _ -> socket
    end
  end

  @doc """
  A save from the new form landed: the pane's line goes. Lost text stays
  offered (`cleared`), so typing on does not take it away.
  """
  def clear(socket) do
    case socket.assigns[:desk_discarded] do
      %{lost_text: text} = d when is_binary(text) ->
        assign(socket, :desk_discarded, %{d | cleared: true})

      %{} ->
        assign(socket, :desk_discarded, nil)

      _ ->
        socket
    end
  end

  @doc "The lost text the line offers back, or nil."
  def lost_text(assigns) do
    case assigns[:desk_discarded] do
      %{lost_text: text} when is_binary(text) -> text
      _ -> nil
    end
  end

  @doc "Whether the line's sentence is gone (a save landed) and only the offer stays."
  def cleared?(assigns), do: match?(%{cleared: true}, assigns[:desk_discarded])

  @doc "Whether the pane says the draft was discarded (the document still open, still there)."
  def note?(assigns), do: open?(assigns) and is_map(assigns[:editor_doc])

  defp open?(%{desk_discarded: %{doc: {type, id}}, editing: {_dataset, type, id}}), do: true
  defp open?(_assigns), do: false

  @doc """
  The pane's line, shown with the published version, and what was typed and
  lost, offered back to read and copy (the pane's toast says it was copied).
  """
  attr :dropped, :boolean, default: false
  attr :lost_text, :string, default: nil
  attr :cleared, :boolean, default: false

  def note(assigns) do
    ~H"""
    <p :if={!@cleared} class="dk-note" role="status" data-desk-discarded>
      {if @dropped,
        do:
          gettext(
            "The draft was discarded elsewhere, so what you typed in it was not saved. This is the published version."
          ),
        else: gettext("The draft was discarded elsewhere. This is the published version.")}
    </p>
    <%!-- Ignored by patches once drawn: a patch would take away the `open`
          the person gave it. Its id follows the text, so new lost text
          draws anew. --%>
    <details
      :if={@lost_text}
      id={"desk-lost-#{:erlang.phash2(@lost_text)}"}
      class="dk-note dk-lost"
      data-desk-lost
      phx-update="ignore"
    >
      <summary>{gettext("What you typed before the discard")}</summary>
      <blockquote class="dk-lost-text">{@lost_text}</blockquote>
      <button
        type="button"
        class="dk-lost-copy"
        data-desk-copy={@lost_text}
        data-desk-copied={gettext("Copied")}
        data-desk-copy-failed={gettext("Could not copy to the clipboard")}
      >
        {gettext("Copy")}
      </button>
    </details>
    """
  end

  # The form's scalar values by input name (`doc[cta][url]`), for the one
  # field the patch leaves as typed.
  defp values(form) do
    form
    |> flatten("doc")
    |> Map.new()
  end

  defp flatten(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {k, v} -> flatten(v, "#{prefix}[#{k}]") end)
  end

  defp flatten(list, prefix) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> flatten(v, "#{prefix}[#{i}]") end)
  end

  defp flatten(v, name) when is_binary(v) or is_number(v) or is_boolean(v),
    do: [{name, to_string(v)}]

  defp flatten(nil, name), do: [{name, ""}]
  defp flatten(_other, _name), do: []
end
