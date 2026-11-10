defmodule BarkparkWeb.Studio.Desk.Search do
  @moduledoc """
  The desk slice's search box. The search itself is the Studio's own
  (`StudioLive.Handlers.DeskSearch`, reached through the events `DeskLive`
  passes on): same read, same tenant, owner and grant guards. This draws
  the box and its hits, each a link that opens the document as panes.
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
      <form phx-change="desk-search" phx-submit="desk-search" id="desk-search-form">
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
        />
      </form>
      <div :if={String.trim(@query) != ""} class="dk-search-hits" id="desk-search-hits">
        <p :if={String.length(String.trim(@query)) < 2} class="dk-note">
          {gettext("Type at least 2 characters")}
        </p>
        <p :if={String.length(String.trim(@query)) >= 2 and @hits == []} class="dk-note" role="status">
          {gettext("No documents match “%{query}”", query: String.trim(@query))}
        </p>
        <.link
          :for={hit <- @hits}
          patch={href(@base, @root, hit)}
          class="pane-item"
          data-desk-hit
        >
          <span class="pane-item-label">
            {hit.title}
            <span class="dk-row-sub">{hit.type_title}</span>
          </span>
        </.link>
      </div>
    </div>
    """
  end

  @doc "The desk URL that opens a hit: the desk's own path to its type, then the document."
  @spec href(String.t(), struct(), map()) :: String.t()
  def href(base, root, %{type: type, id: id}) do
    segments = Tree.path_to_type(root, type) ++ [id]

    base <>
      "/" <> Enum.map_join(segments, ";", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
