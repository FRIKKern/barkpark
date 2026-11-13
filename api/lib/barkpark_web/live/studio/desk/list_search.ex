defmodule BarkparkWeb.Studio.Desk.ListSearch do
  @moduledoc """
  A desk list pane's own search box (J24), as the TanStack Studio's ListPane
  draws it: a combobox named "Search list" over the pane's rows. Typing
  narrows the rows; the first result is lit (`aria-activedescendant`),
  ArrowDown / ArrowUp move the light, Enter opens the lit document; "Clear
  search" empties the box and gives it the focus back.

  The search text is the pane's own state, like its `limit` and `sort`, never
  the URL's. A search is read on the server, over the whole list, not over the
  rows on screen: `Content.search_documents/3` (the read behind
  `/v1/data/search`, which the TanStack Studio's list search calls), limited to
  the list's type and to the list's own filter, with the pane's scope opts, so
  the tenant, owner, grant and visibility guards are that read's own. While a
  search is read, the rows on screen stay.

  `BarkparkWeb.Studio.Desk.PaneComponent` wires it in: it draws `box/1`, hands
  the events named `list-search*` to `handle/4` and a landed read to
  `landed/1`, and puts `:search` on the pane it reads.
  """

  use BarkparkWeb, :html

  alias Barkpark.Content
  alias Barkpark.Content.TitleDerivation
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.Desk.Text
  alias Phoenix.LiveView.JS

  @doc "A list pane's starting state: no search, the first result lit."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    socket
    |> Phoenix.Component.assign_new(:q, fn -> "" end)
    |> Phoenix.Component.assign_new(:lit, fn -> 0 end)
    |> Phoenix.Component.assign_new(:open_when_drawn, fn -> false end)
    |> Phoenix.Component.assign_new(:search_due, fn -> 0 end)
    |> Phoenix.Component.assign_new(:reading, fn -> nil end)
  end

  # How long typing must pause before the pane reads the search, as the
  # TanStack Studio waits before it asks the server.
  @pause_ms 150

  @doc """
  The search a pane's read is asked for: the trimmed text, or nil for none.
  A value the database refuses as text (a NUL; bytes that are not UTF-8) is
  no search.
  """
  @spec term(String.t() | nil) :: String.t() | nil
  def term(q) when is_binary(q),
    do: if(String.trim(q) == "" or not Text.text?(q), do: nil, else: String.trim(q))

  def term(_q), do: nil

  @doc "The id of row `i` of a pane (0-based): what `aria-activedescendant` names."
  @spec item_id(String.t(), non_neg_integer()) :: String.t()
  def item_id(pane_id, i), do: "#{pane_id}-item-#{i}"

  @doc "The id of a pane's rows: what the box `aria-controls`."
  @spec rows_id(String.t()) :: String.t()
  def rows_id(pane_id), do: pane_id <> "-rows"

  @doc """
  Whether the rows on screen are a search's results with at least one row:
  only then is a row lit. Read from what is drawn, not from the box, so the
  light never names a row of an older answer.
  """
  @spec searching?(map()) :: boolean()
  def searching?(%{data: %{ok?: true, result: %{searched: s, entries: [_ | _]}}})
      when is_binary(s),
      do: true

  def searching?(_assigns), do: false

  @doc "Whether row `i` is the lit one."
  @spec lit?(map(), non_neg_integer()) :: boolean()
  def lit?(assigns, i), do: searching?(assigns) and assigns[:lit] == i

  attr :id, :string, required: true, doc: "the pane's id"
  attr :q, :string, required: true
  attr :lit, :integer, required: true
  attr :searching, :boolean, required: true
  attr :myself, :any, required: true

  @doc """
  The box. Every key goes to the pane (`phx-target`) at once, with no
  `phx-debounce`: LiveView debounces an element's events in ONE cycle, so a
  debounced box drops the text typed just before an ArrowDown. The pane waits
  for a pause in typing itself (`due/3`).
  """
  def box(assigns) do
    assigns = assign(assigns, :input, assigns.id <> "-q")

    ~H"""
    <div class="search dk-list-search">
      <span class="search-icon" aria-hidden="true">
        <BarkparkWeb.Studio.Desk.Glyph.glyph name="search" />
      </span>
      <form
        id={@id <> "-search"}
        phx-change="list-search"
        phx-submit="list-search-open"
        phx-target={@myself}
      >
        <input
          id={@input}
          type="search"
          name="q"
          value={@q}
          class="form-input"
          aria-label={gettext("Search list")}
          placeholder={gettext("Search list")}
          autocomplete="off"
          spellcheck="false"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded={to_string(@searching)}
          aria-controls={rows_id(@id)}
          aria-activedescendant={@searching && item_id(@id, @lit)}
          phx-keydown="list-search-key"
          phx-target={@myself}
        />
        <%!-- A reset button: the browser empties the box itself (a focused
             input keeps its value through a patch), and LiveView sends the
             emptied form as a change. The value attribute is set first so the
             reset lands on "", and the push tells the pane without waiting. --%>
        <button
          :if={@q != ""}
          type="reset"
          class="icon-btn search-clear"
          aria-label={gettext("Clear search")}
          phx-click={
            JS.set_attribute({"value", ""}, to: by_id(@input))
            |> JS.push("list-search-clear", target: @myself)
            |> JS.focus(to: by_id(@input))
          }
        >
          <span aria-hidden="true">×</span>
        </button>
      </form>
    </div>
    """
  end

  @doc """
  A selector for the element with this id. A pane's id holds a `:` (its pane
  key, `list:post`), which a `#id` selector cannot spell.
  """
  @spec by_id(String.t()) :: String.t()
  def by_id(id), do: ~s([id="#{String.replace(id, ~S("), ~S(\"))}"])

  @doc """
  The box's events. `reload` is the pane's own read (`load/1`), run when the
  search changes.
  """
  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t(), (term() -> term())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  # Typing: the text is the pane's at once (Enter reads it), the search is
  # read once typing pauses.
  def handle("list-search", %{"q" => q}, socket, _reload) when is_binary(q) do
    if term(q) == term(socket.assigns.q) do
      {:noreply, assign(socket, q: q, open_when_drawn: false)}
    else
      due = socket.assigns.search_due + 1

      Phoenix.LiveView.send_update_after(
        socket.assigns.myself,
        %{list_search_due: due},
        @pause_ms
      )

      {:noreply, assign(socket, q: q, lit: 0, open_when_drawn: false, search_due: due)}
    end
  end

  def handle("list-search-clear", _params, socket, reload),
    do: {:noreply, put_query(socket, "", false, reload)}

  # Enter. The rows on screen answer this text: open the lit row. They answer
  # an older text (the last key is still on its way): open once they land.
  def handle("list-search-open", %{"q" => q}, socket, reload) when is_binary(q) do
    if term(q) == drawn(socket) and !socket.assigns.data.loading,
      do: {:noreply, open_lit(socket)},
      else: {:noreply, put_query(socket, q, true, reload)}
  end

  def handle("list-search-key", %{"key" => key}, socket, _reload)
      when key in ["ArrowDown", "ArrowUp"] do
    if searching?(socket.assigns) do
      last = length(rows(socket)) - 1
      step = if key == "ArrowDown", do: 1, else: -1
      {:noreply, assign(socket, :lit, (socket.assigns.lit + step) |> max(0) |> min(last))}
    else
      {:noreply, socket}
    end
  end

  def handle(_event, _params, socket, _reload), do: {:noreply, socket}

  @doc """
  Typing paused (`send_update_after/3` from a `list-search` change): read the
  search, unless a later key or Enter or Clear came since.
  """
  @spec due(Phoenix.LiveView.Socket.t(), non_neg_integer(), (term() -> term())) ::
          Phoenix.LiveView.Socket.t()
  def due(socket, due, reload) do
    if due == socket.assigns.search_due and term(socket.assigns.q) != searched(socket),
      do: reload.(socket),
      else: socket
  end

  @doc "A read landed: keep the light on a row, and open it if Enter asked for that."
  @spec landed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def landed(socket) do
    socket = assign(socket, :lit, min(socket.assigns.lit, max(length(rows(socket)) - 1, 0)))

    if socket.assigns.open_when_drawn and drawn(socket) == term(socket.assigns.q),
      do: socket |> assign(:open_when_drawn, false) |> open_lit(),
      else: socket
  end

  # Enter or Clear: read now. A search typed but not yet read (its pause has
  # not come) is read too; a later `due/3` for it finds it read.
  defp put_query(socket, q, open?, reload) do
    socket =
      assign(socket, q: q, open_when_drawn: open?, search_due: socket.assigns.search_due + 1)

    cond do
      term(q) == searched(socket) and open? -> landed(socket)
      term(q) == searched(socket) -> socket
      true -> socket |> assign(:lit, 0) |> reload.()
    end
  end

  # The search the pane's last read asked for (in flight or landed).
  defp searched(socket), do: socket.assigns[:reading]

  defp open_lit(socket) do
    %{panes: panes, index: index, base: base, lit: lit} = socket.assigns

    case searching?(socket.assigns) && Enum.at(rows(socket), lit) do
      %{next: %{} = next} ->
        Phoenix.LiveView.push_patch(socket, to: Panes.open_after(panes, index, next, base))

      _ ->
        socket
    end
  end

  defp drawn(%{assigns: %{data: %{ok?: true, result: result}}}), do: result[:searched]
  defp drawn(_socket), do: nil

  defp rows(%{assigns: %{data: %{ok?: true, result: %{entries: entries}}}}),
    do: Enum.filter(entries, &is_map/1)

  defp rows(_socket), do: []

  # ── the read ───────────────────────────────────────────────────────────────

  @doc """
  The rows of the `type` list whose documents match `q`, best title matches
  first. Read in the pane's own task, as its other reads are.
  """
  @spec read(String.t(), String.t(), struct() | nil, String.t(), keyword(), String.t()) :: map()
  def read(type, q, node, dataset, scope, provisional) do
    case Content.resolve_schema(type, dataset, scope) do
      {:ok, schema} ->
        opts =
          [
            type: type,
            perspective: :drafts,
            limit: Rows.page(),
            engine: "postgres",
            suggest: true,
            # The list's own filter: a filtered list finds only its own rows.
            filter_map: Structure.parse_filter(node && node.filter)
          ] ++ scope

        {docs, _total, _meta} = Content.search_documents(q, dataset, opts)
        entries = docs |> Enum.map(&entry(&1, schema)) |> rank(q)

        %{
          title: if(node, do: provisional, else: schema.title || type),
          entries: entries,
          searched: q,
          note: if(entries == [], do: gettext("No results found"))
        }

      _ ->
        note = gettext("There is no document type named “%{type}” here.", type: type)
        %{title: provisional, note: note, searched: q}
    end
  rescue
    # A desk filter the query layer refuses is this pane's to state.
    e in Barkpark.Content.InvalidFilterError ->
      %{title: provisional, entries: [], note: Exception.message(e), searched: q}
  end

  @doc """
  Hits in the TanStack Studio's order: the more search words a title word
  starts with, the higher; then the newest edit first.
  """
  @spec rank([map()], String.t()) :: [map()]
  def rank(entries, q) do
    terms = q |> String.downcase() |> String.split(~r/\s+/u, trim: true)

    entries
    |> Enum.sort_by(& &1.updated, {:desc, DateTime})
    |> Enum.sort_by(&(-score(&1.title, terms)))
    |> Enum.map(&Map.delete(&1, :updated))
  end

  defp score(title, terms) do
    words = title |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    Enum.count(terms, fn t -> Enum.any?(words, &String.starts_with?(&1, t)) end)
  end

  defp entry(doc, schema) do
    id = Content.published_id(doc.doc_id)

    %{
      title: text(doc.title) || TitleDerivation.preview_title(doc, schema) || id,
      sub: nil,
      draft: String.starts_with?(doc.doc_id, "drafts."),
      updated: doc.updated_at || ~U[1970-01-01 00:00:00Z],
      next: %{kind: :doc, id: id, type: schema.name}
    }
  end

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(_value), do: nil
end
