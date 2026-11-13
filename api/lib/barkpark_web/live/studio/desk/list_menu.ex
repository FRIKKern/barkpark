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

  It is drawn in the desk's one menu look (`Desk.Menu`). The menu is an HTML popover: the button opens it before the page's
  script runs, Escape and a click outside close it, and nothing is drawn
  on the server for it.
  """

  use BarkparkWeb, :html

  alias Barkpark.Content
  alias Barkpark.Content.TitleDerivation
  alias Barkpark.UserPrefs
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.Desk.Menu
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.ScopeHelpers

  @pref "studio.lists"

  attr(:id, :string, required: true)
  attr(:index, :integer, required: true)
  attr(:sort, :string, default: nil)

  attr(:default, :string,
    default: "updated",
    doc: "the sort the list reads in with no pick (`default/2`)"
  )

  attr(:orderings, :list, default: [])
  attr(:named, :list, default: [], doc: "the type's `desk.sortOrderings` (`%{name, title}`)")
  attr(:myself, :any, required: true)

  def menu(assigns) do
    # No pick reads in the default order: its item carries the check, and
    # "Default sort" says it is already in use, as the TanStack Studio's.
    assigns =
      assign(assigns,
        menu_id: assigns.id <> "-menu",
        current: assigns.sort || assigns.default,
        at_default?: is_nil(assigns.sort) or assigns.sort == assigns.default
      )

    ~H"""
    <button
      type="button"
      class="dk-list-options dk-doc-menu-button icon-btn"
      aria-label={gettext("List options")}
      data-tip={gettext("Show more")}
      aria-haspopup="menu"
      popovertarget={@menu_id}
      id={"#{@menu_id}-button"}
      aria-expanded="false"
      style={"anchor-name: --dk-list-menu-#{@index}"}
    >
      <span aria-hidden="true">…</span>
    </button>
    <div
      id={@menu_id}
      popover
      role="menu"
      aria-label={gettext("List options")}
      class="dk-list-menu dk-menu"
      style={"position-anchor: --dk-list-menu-#{@index}; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"}
    >
      <Menu.label>{gettext("Actions")}</Menu.label>
      <.item
        :for={choice <- choices(@orderings, @named)}
        label={choice.label}
        sort={choice.sort}
        checked={choice.sort == @current}
        icon="sort"
        menu_id={@menu_id}
        myself={@myself}
      />
      <.item
        label={gettext("Default sort")}
        sort=""
        checked={false}
        disabled={@at_default? && gettext("Already using the default sort order")}
        menu_id={@menu_id}
        myself={@myself}
      />
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:sort, :string, required: true)
  attr(:checked, :boolean, required: true)

  attr(:disabled, :any,
    default: false,
    doc: "false, or why the choice is already in use: it stays hoverable for that tip"
  )

  attr(:icon, :string,
    default: nil,
    doc: "TanStack's: each sort with its sort glyph, Default sort with none"
  )

  attr(:menu_id, :string, required: true)
  attr(:myself, :any, required: true)

  defp item(assigns) do
    ~H"""
    <Menu.item
      role="menuitemradio"
      aria-checked={to_string(@checked)}
      aria-disabled={@disabled && "true"}
      data-tip={@disabled || nil}
      class="menu-item"
      icon={@icon}
      phx-click={!@disabled && "sort"}
      phx-value-sort={@sort}
      phx-target={@myself}
      popovertarget={!@disabled && @menu_id}
      popovertargetaction={!@disabled && "hide"}
    >{@label}</Menu.item>
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
  Each type's list menu, read once with the desk tree, as the TanStack
  Studio holds its schemas: a list's read pays nothing for its menu.
  `orderings` are the type's own (`Rows.orderings/1`); `sorts` every sort a
  pick or a kept pref may name for the type (`pick/2`).
  """
  @spec menus(String.t(), keyword()) :: %{
          String.t() => %{orderings: [map()], sorts: [String.t()], default: String.t()}
        }
  def menus(dataset, scope) do
    for schema <- Content.list_schemas(dataset, scope), into: %{} do
      orderings = Rows.orderings(schema)
      title = TitleDerivation.preview_title_field(schema) || "title"

      sorts =
        Enum.map(orderings, & &1.sort) ++
          Enum.map(PaneBuilder.sort_options(schema), & &1.name) ++
          ["#{title}:asc", "#{title}:desc", "updated", "created"]

      default = first_sort(PaneBuilder.desk_order(nil, schema))
      {schema.name, %{orderings: orderings, sorts: Enum.uniq(sorts), default: default}}
    end
  end

  @doc """
  The sort a list reads in with no pick, as a menu sort: the first ordering
  PaneBuilder reads it in (`PaneBuilder.desk_order/3`), the list's own desk
  node's when it declares them, else its type's (`type_default`, from
  `menus/2`). None declared, it reads by last edit, as the TanStack Studio's
  default (`"updated"`). The declared case is ruling (c); REQUESTS.md parks
  the switch to "updated" for every type for the owner.
  """
  @spec default(String.t(), map() | nil) :: String.t()
  def default(type_default, node) do
    case node && Map.get(node, :orderings) do
      orderings when is_list(orderings) -> first_sort(PaneBuilder.desk_order(nil, nil, orderings))
      _ -> type_default
    end
  end

  defp first_sort([{:field, field, dir} | _]), do: "#{field}:#{dir}"
  defp first_sort(_order), do: "updated"

  @doc """
  `sort` when the type offers it (`menus/2`'s `sorts`), else nil: the
  default order. A pick comes from the page and a pref is data the editor
  can write, so neither reaches the query unless it is one of these
  (ruling R20).
  """
  @spec pick(String.t() | nil, [String.t()]) :: String.t() | nil
  def pick(sort, sorts) when is_binary(sort) and is_list(sorts),
    do: if(sort in sorts, do: sort)

  def pick(_sort, _sorts), do: nil

  @doc """
  The sort a `type` list reads in: the one this editor keeps for it (`prefs/2`),
  when the type offers it (`desk.menus`), else nil, the default (R20). Every
  reader of a list asks this: the pane, a hover's read and the first render's.
  """
  @spec kept(%{String.t() => String.t()}, map(), String.t() | nil) :: String.t() | nil
  def kept(sorts, menus, type),
    do: pick(sorts[type], (menus[type] || %{sorts: []}).sorts)

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
