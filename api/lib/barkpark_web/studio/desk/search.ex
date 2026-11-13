defmodule BarkparkWeb.Studio.Desk.Search do
  @moduledoc """
  The desk slice's search box. The search itself is the Studio's own
  (`StudioLive.Handlers.DeskSearch`, reached through the events `DeskLive`
  passes on): same read, same tenant, owner and grant guards. This draws
  the box and its hits, each a link that opens the document as panes.

  The box is a combobox over its hits, as the TanStack Studio's: the focus
  stays in the box, the hits are options in a listbox, one is lit
  (`aria-activedescendant`). Each new set of hits is drawn with the first
  lit; ArrowDown and ArrowUp move the light in the browser (`bp-desk.js`),
  with nothing sent, and Enter sends the lit index (`lit`) to open that hit.
  """

  use BarkparkWeb, :html

  alias BarkparkWeb.Studio.Desk.Tree

  attr :query, :string, default: ""
  attr :hits, :list, default: []
  attr :root, :any, required: true
  attr :base, :string, required: true

  def box(assigns) do
    ~H"""
    <div class="dk-search" role="search">
      <form phx-change="desk-search" phx-submit="desk-search-open" id="desk-search-form">
        <label for="desk-search-input" class="sr-only">{gettext("Search documents")}</label>
        <input
          id="desk-search-input"
          type="search"
          name="value"
          value={@query}
          class="form-input"
          placeholder={gettext("Search documents")}
          autocomplete="off"
          phx-debounce="150"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded={to_string(@hits != [])}
          aria-controls="desk-search-options"
          aria-activedescendant={@hits != [] && option_id(0)}
        />
        <input type="hidden" id="desk-search-lit" name="lit" value="0" />
      </form>
      <div :if={String.trim(@query) != ""} class="dk-search-hits" id="desk-search-hits">
        <p :if={String.length(String.trim(@query)) < 2} class="dk-note">
          {gettext("Type at least 2 characters")}
        </p>
        <p :if={String.length(String.trim(@query)) >= 2 and @hits == []} class="dk-note" role="status">
          {gettext("No documents match “%{query}”", query: String.trim(@query))}
        </p>
        <div :if={@hits != []} id="desk-search-options" role="listbox" aria-label={gettext("Search documents")}>
          <.link
            :for={{hit, i} <- Enum.with_index(@hits)}
            patch={href(@base, @root, hit)}
            id={option_id(i)}
            class="pane-item"
            role="option"
            aria-selected={to_string(i == 0)}
            data-desk-hit
          >
            <%!-- The title is an element of its own: a spec finds a hit by it. --%>
            <span class="pane-item-label">
              <span class="dk-row-title">{hit.title}</span>
              <span class="dk-row-sub">{hit.type_title}</span>
            </span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @doc "The element id of hit `i`, the one `aria-activedescendant` names when it is lit."
  @spec option_id(non_neg_integer()) :: String.t()
  def option_id(i), do: "desk-search-hit-#{i}"

  @doc "The desk URL that opens a hit: the desk's own path to its type, then the document."
  @spec href(String.t(), struct(), map()) :: String.t()
  def href(base, root, %{type: type, id: id}) do
    segments = Tree.doc_path(root, type, id)

    base <>
      "/" <> Enum.map_join(segments, ";", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
