defmodule BarkparkWeb.Studio.Desk.NewDocMenu do
  @moduledoc """
  The desk's Create new (J18, J37), the TanStack Studio's two "+"s: a list's
  (`NewInList` in `app/src/components/Structure.tsx`) and the navbar's
  (`components/NewDocMenu.tsx`). Each offers the ways to start a type
  (`Desk.NewDoc.choices/1`): its own, then its templates.

  A list's "+" with one way to start is one button; with more it opens a menu
  of them, Sanity's multi-action "+". The navbar's lists every way to start
  every type a new document can be made of, A to Z. Each choice sends the
  page's `new-document` with its type and `template` (the navbar's with
  `at=root`), and the page opens it (`EditorHost`).

  Both are HTML popovers: their buttons open them before the page's script
  runs, Escape and a click outside close them, and a choice closes its own.
  """
  use BarkparkWeb, :html

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.Menu
  alias BarkparkWeb.Studio.Desk.NewDoc
  alias BarkparkWeb.Studio.PaneBuilder

  @picker "dk-new-doc"

  @doc """
  The ways to start each type a new document can be made of, by type, read
  once with the desk tree: no singleton, no object type, none its authors do
  not create.
  """
  @spec all(String.t(), keyword()) :: %{String.t() => [NewDoc.choice()]}
  def all(dataset, scope) do
    for schema <- Content.list_schemas(dataset, scope),
        (schema.kind || "document") == "document",
        schema.singleton != true,
        PaneBuilder.author_creatable?(schema),
        into: %{},
        do: {schema.name, NewDoc.choices(schema)}
  end

  @doc "The navbar's list: every choice of every type, A to Z by title."
  @spec picks(%{String.t() => [NewDoc.choice()]}) :: [NewDoc.choice()]
  def picks(all) do
    all |> Map.values() |> List.flatten() |> Enum.sort_by(&{String.downcase(&1.title), &1.id})
  end

  attr :id, :string, required: true, doc: "the pane's id"
  attr :index, :integer, required: true
  attr :type, :string, required: true
  attr :label, :string, required: true, doc: "\"Create new <type>\""
  attr :choices, :list, default: [], doc: "the type's ways to start"
  attr :creatable, :boolean, required: true, doc: "whether the list's read allows it"

  @doc """
  A list's "+". It is in the header from the first render, hidden until the
  read says the type can be created: a button that arrived with the read made
  the browser move "List options" and its menu, which closed an open menu and
  dropped the focus.
  """
  def button(%{choices: [_, _ | _]} = assigns) do
    assigns = assign(assigns, :menu_id, assigns.id <> "-new-menu")

    ~H"""
    <button
      type="button"
      class="dk-create-new dk-doc-menu-button icon-btn"
      hidden={!@creatable}
      disabled={!@creatable}
      aria-label={@creatable && @label}
      data-tip={@creatable && gettext("Create new document")}
      aria-haspopup="menu"
      popovertarget={@menu_id}
      id={"#{@menu_id}-button"}
      style={"anchor-name: --dk-new-menu-#{@index}"}
    >
      <BarkparkWeb.Studio.Desk.Glyph.glyph name="add" />
    </button>
    <div
      :if={@creatable}
      id={@menu_id}
      popover
      role="menu"
      aria-label={@label}
      class="dk-new-menu dk-menu"
      style={"position-anchor: --dk-new-menu-#{@index}; inset: auto; top: anchor(bottom); left: anchor(center); translate: -50% 0; margin: 4px 0 0"}
    >
      <Menu.item
        :for={choice <- @choices}
        role="menuitem"
        class="menu-item"
        icon="add"
        phx-click="new-document"
        phx-value-type={@type}
        phx-value-template={choice.id}
        phx-value-desk-pane={@index}
        popovertarget={@menu_id}
        popovertargetaction="hide"
      >{choice.title}</Menu.item>
    </div>
    """
  end

  def button(assigns) do
    ~H"""
    <button
      type="button"
      class="dk-create-new dk-doc-menu-button icon-btn"
      hidden={!@creatable}
      disabled={!@creatable}
      phx-click={@creatable && "new-document"}
      phx-value-type={@creatable && @type}
      phx-value-template={@creatable && @type}
      phx-value-desk-pane={@creatable && @index}
      aria-label={@creatable && @label}
      data-tip={@creatable && gettext("Create new document")}
    >
      <BarkparkWeb.Studio.Desk.Glyph.glyph name="add" />
    </button>
    """
  end

  @doc "The navbar's \"+\": it opens `picker/1`. Drawn by the layout, on the desk only."
  def open(assigns) do
    assigns = assign(assigns, :picker, @picker)

    ~H"""
    <button
      type="button"
      class="btn btn-ghost btn-sm dk-new-doc-open"
      popovertarget={@picker}
      aria-haspopup="dialog"
      aria-label={gettext("Create new document")}
      title={gettext("Create new document")}
      style="anchor-name: --dk-new-doc"
    >
      <BarkparkWeb.Studio.Desk.Glyph.glyph name="add" />
    </button>
    """
  end

  attr :picks, :list, required: true

  @doc "The navbar's list of ways to start, each an option that opens a new document."
  def picker(assigns) do
    assigns = assign(assigns, :picker, @picker)

    ~H"""
    <div
      id={@picker}
      popover
      role="dialog"
      aria-labelledby={"#{@picker}-title"}
      class="dk-menu dk-new-doc"
      style="position-anchor: --dk-new-doc; inset: auto; top: anchor(bottom); left: anchor(left); margin: 4px 0 0"
    >
      <header class="dk-new-doc-head">
        <h2 id={"#{@picker}-title"}>{gettext("Create new document")}</h2>
        <button
          type="button"
          class="icon-btn"
          aria-label={gettext("Close dialog")}
          popovertarget={@picker}
          popovertargetaction="hide"
        >
          <span aria-hidden="true">×</span>
        </button>
      </header>
      <div role="listbox" aria-label={gettext("New document")} class="dk-new-doc-list">
        <button
          :for={pick <- @picks}
          type="button"
          role="option"
          aria-selected="false"
          class="dk-menu-item menu-item"
          phx-click="new-document"
          phx-value-type={pick.type}
          phx-value-template={pick.id}
          phx-value-at="root"
          popovertarget={@picker}
          popovertargetaction="hide"
        >{pick.title}</button>
      </div>
    </div>
    """
  end
end
