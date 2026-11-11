defmodule BarkparkWeb.Studio.Desk.ListMenu do
  @moduledoc """
  A desk list's "…" menu (J25, J55), the TanStack Studio's `ListMenu`
  (`app/src/components/Structure.tsx`): "List options" opens the sorts, the
  type's own orderings first (or its title field), then Last Edited,
  Created and Default sort. A pick reads the list again in that order.

  The pick sticks per type and per editor in the same place the TanStack
  Studio keeps it, `Barkpark.UserPrefs` key `"studio.lists"`
  (`%{type => %{"sort" => sort}}`), so a sort chosen in either studio opens
  the list that way in both. A sign-in with no editor behind it (a token
  with no owner) keeps the pick for the visit only.

  The menu is an HTML popover: the button opens it before the page's
  script runs, Escape and a click outside close it, and nothing is drawn
  on the server for it.
  """

  use BarkparkWeb, :html

  alias Barkpark.Content
  alias Barkpark.UserPrefs
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.ScopeHelpers

  @pref "studio.lists"

  attr :id, :string, required: true
  attr :index, :integer, required: true
  attr :sort, :string, default: nil
  attr :orderings, :list, default: []
  attr :named, :list, default: [], doc: "the type's `desk.sortOrderings` (`%{name, title}`)"
  attr :myself, :any, required: true

  def menu(assigns) do
    assigns = assign(assigns, :menu_id, assigns.id <> "-menu")

    ~H"""
    <button
      type="button"
      class="dk-list-options"
      aria-label={gettext("List options")}
      title={gettext("Show more")}
      aria-haspopup="menu"
      popovertarget={@menu_id}
      style={"anchor-name: --dk-list-menu-#{@index}"}
    >
      <span aria-hidden="true">…</span>
    </button>
    <div
      id={@menu_id}
      popover
      role="menu"
      aria-label={gettext("List options")}
      class="dk-list-menu"
      style={"position-anchor: --dk-list-menu-#{@index}; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"}
    >
      <div class="menu-label">{gettext("Actions")}</div>
      <.item
        :for={choice <- choices(@orderings, @named)}
        label={choice.label}
        sort={choice.sort}
        checked={choice.sort == @sort}
        menu_id={@menu_id}
        myself={@myself}
      />
      <.item label={gettext("Default sort")} sort="" checked={false} menu_id={@menu_id} myself={@myself} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :sort, :string, required: true
  attr :checked, :boolean, required: true
  attr :menu_id, :string, required: true
  attr :myself, :any, required: true

  defp item(assigns) do
    ~H"""
    <button
      type="button"
      role="menuitemradio"
      aria-checked={to_string(@checked)}
      class="menu-item"
      style="display: block; width: 100%; text-align: start"
      phx-click="sort"
      phx-value-sort={@sort}
      phx-target={@myself}
      popovertarget={@menu_id}
      popovertargetaction="hide"
    >
      {@label}
    </button>
    """
  end

  @doc "The menu's sorts in the TanStack Studio's order, each `%{label, sort}`."
  @spec choices([map()], [map()]) :: [%{label: String.t(), sort: String.t()}]
  def choices(orderings, named) do
    sort_by = fn title -> gettext("Sort by %{field}", field: title) end

    Enum.map(orderings, &%{label: sort_by.(&1.title), sort: &1.sort}) ++
      Enum.map(named, &%{label: sort_by.(&1.title), sort: &1.name}) ++
      [
        %{label: gettext("Sort by Last Edited"), sort: "updated"},
        %{label: gettext("Sort by Created"), sort: "created"}
      ]
  end

  @doc """
  Each type's own sorts for its list menu (`Rows.orderings/1`), read once
  with the desk tree, as the TanStack Studio holds its schemas: a list's
  read pays nothing for its menu.
  """
  @spec orderings(String.t(), keyword()) :: %{String.t() => [map()]}
  def orderings(dataset, scope) do
    for schema <- Content.list_schemas(dataset, scope), into: %{} do
      {schema.name, Rows.orderings(schema)}
    end
  end

  @doc "The sorts this editor keeps for `dataset`'s lists: `%{type => sort}`."
  @spec prefs(Phoenix.LiveView.Socket.t(), String.t()) :: %{String.t() => String.t()}
  def prefs(socket, dataset) do
    with {user, ws} <- editor(socket),
         %{} = value <- UserPrefs.get(user, ws, dataset, @pref) do
      for {type, %{"sort" => sort}} when is_binary(sort) <- value, into: %{}, do: {type, sort}
    else
      _ -> %{}
    end
  end

  @doc "Keeps `sort` (nil: the default) for `type`, beside what else is kept for it."
  @spec remember(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def remember(socket, dataset, type, sort) do
    with {user, ws} <- editor(socket) do
      value = UserPrefs.get(user, ws, dataset, @pref) || %{}
      entry = if is_map(value[type]), do: value[type], else: %{}
      entry = if sort, do: Map.put(entry, "sort", sort), else: Map.delete(entry, "sort")
      value = if entry == %{}, do: Map.delete(value, type), else: Map.put(value, type, entry)
      _ = UserPrefs.put(user, ws, dataset, @pref, value)
    end

    :ok
  end

  # The editor a pref is kept for, as the prefs API finds one: the account,
  # else the owner of the token. None, no pref.
  defp editor(socket) do
    user =
      case socket.assigns do
        %{current_user: %{id: id}} when is_binary(id) -> id
        %{api_token: %{owner_user_id: id}} when is_binary(id) -> id
        _ -> nil
      end

    ws = socket |> ScopeHelpers.scope_opts() |> Keyword.get(:workspace_id)
    if is_binary(user) and is_binary(ws), do: {user, ws}
  end
end
