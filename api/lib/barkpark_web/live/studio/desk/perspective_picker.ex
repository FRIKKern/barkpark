defmodule BarkparkWeb.Studio.Desk.PerspectivePicker do
  @moduledoc """
  The desk navbar's perspective picker, as the TanStack Studio's (`Navbar.tsx`
  `PerspectivePicker`, Sanity's, J63): a pill that reads "Drafts" or
  "Published" and opens a menu of the two, each a radio.

  The perspective is the page's URL (`?perspective=published`), the one
  state the edit pane's Draft and Published pills already switch
  (`Panes.perspective/1`, `DocStatus`, `PublishedView`). Picking one is a
  patch to the same page with the query changed, as TanStack's `pick`:
  Published sets `perspective=published` and keeps the rest of the query;
  Drafts drops it (drafts is the default, so it leaves the URL). The pill
  and the pane's pills read the same URL, so they never disagree.

  The menu is a popover, opened by its button; `bp-desk-navbar.js` closes
  it when an item is picked. Sanity's Releases entry under the rule is left
  out: the desk has no Releases tool.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.Panes

  attr :uri, :string, default: nil, doc: "the page's URL (`desk_uri`)"

  @doc "The pill and its menu."
  def picker(assigns) do
    published? = Panes.perspective(assigns.uri) == :published

    assigns =
      assign(assigns,
        published?: published?,
        published_href: href(assigns.uri, :published),
        drafts_href: href(assigns.uri, :drafts)
      )

    ~H"""
    <div class="menu-wrap perspective dk" data-perspective={@published? && "published"}>
      <button
        id="dk-perspective"
        type="button"
        class="perspective-picker"
        popovertarget="dk-perspective-menu"
        aria-label={gettext("Perspective")}
        aria-haspopup="menu"
        style="anchor-name: --dk-perspective"
      >
        <span class={["dot", if(@published?, do: "published", else: "draft-ring")]} aria-hidden="true"></span>
        <span class="perspective-label">{if @published?, do: gettext("Published"), else: gettext("Drafts")}</span>
        <BarkparkWeb.Icons.desk_icon name="chevron-down" size={21} />
      </button>
      <div
        id="dk-perspective-menu"
        popover
        role="menu"
        aria-labelledby="dk-perspective"
        class="dk-menu perspective-menu"
        style="position-anchor: --dk-perspective; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
      >
        <.link
          :if={@published_href}
          patch={@published_href}
          role="menuitemradio"
          aria-checked={to_string(@published?)}
          tabindex="-1"
          class="dk-menu-item"
          data-desk-perspective="published"
        ><span class="dot published" aria-hidden="true"></span>{gettext("Published")}</.link>
        <.link
          :if={@drafts_href}
          patch={@drafts_href}
          role="menuitemradio"
          aria-checked={to_string(!@published?)}
          tabindex="-1"
          class="dk-menu-item"
          data-desk-perspective="drafts"
        ><span class="dot draft-ring" aria-hidden="true"></span>{gettext("Drafts")}</.link>
      </div>
    </div>
    """
  end

  @doc """
  The page's own path and query with the perspective set to `to`: Published
  sets `perspective=published`, Drafts removes the key. nil without a URL.
  """
  @spec href(String.t() | nil, :published | :drafts) :: String.t() | nil
  def href(uri, to) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{path: path, query: query}} when is_binary(path) ->
        params =
          query
          |> decode()
          |> Enum.reject(fn {key, _value} -> key == "perspective" end)
          |> then(&if(to == :published, do: &1 ++ [{"perspective", "published"}], else: &1))

        if params == [], do: path, else: path <> "?" <> URI.encode_query(params)

      _ ->
        nil
    end
  end

  def href(_uri, _to), do: nil

  # The query's pairs in order; a query `URI.decode_query/1` refuses keeps none.
  defp decode(nil), do: []

  defp decode(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {URI.decode_www_form(key), URI.decode_www_form(value)}
        [key] -> {URI.decode_www_form(key), ""}
      end
    end)
  rescue
    ArgumentError -> []
  end
end
