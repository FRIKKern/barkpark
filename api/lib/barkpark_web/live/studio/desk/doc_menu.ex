defmodule BarkparkWeb.Studio.Desk.DocMenu do
  @moduledoc """
  The edit pane's "…" menu, Sanity's document actions: Publish or Unpublish,
  History, Discard draft (Sanity's "Discard changes": a draft over a
  published document), Duplicate and Delete, as the Studio offers them for
  the open document (`DocActions.resolved_doc_actions/1`, so a singleton has
  no Unpublish, Duplicate or Delete, and a plugin's resolver applies). Discard
  asks first: the Studio's own dialog, with the published version kept. Each item
  sends the Studio's own event to the page, which hands it to the editor
  (`EditorHost`): nothing here writes.

  The desk hides the Studio's toolbar row (`Desk.Style`), as the TanStack
  Studio has none. Every action that row drew and the desk has no place for
  is here too, in the Studio's order: Preview, Show or Hide preview, Diff,
  Open another, Close reference, View blast radius, a schema's own actions (a
  link, or a dialog for an admin, as the toolbar drew them) and the switch to
  the Beta editor.

  The menu is an HTML popover, as the list's "List options" is: Enter or a
  click opens it, Escape or a click outside closes it and the focus goes back
  to the button. `bp-desk.js` focuses the first item on open, keeps
  `aria-expanded` on the button and moves the focus with the arrow keys.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.PreviewLocations
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.DocActions

  @typedoc "One menu item: what it is called, and what it sends or opens."
  @type item :: %{
          required(:label) => String.t(),
          required(:name) => String.t(),
          required(:event) => String.t() | nil,
          optional(:values) => map(),
          optional(:href) => String.t(),
          optional(:target) => String.t() | nil,
          optional(:rel) => String.t() | nil
        }

  @doc "The open document's menu items, in the Studio's order; none without a document."
  @spec items(map()) :: [item()]
  def items(%{editor_doc: %{}} = assigns) do
    actions = DocActions.resolved_doc_actions(with_twin(assigns))
    admin? = Caps.admin_affordance?(assigns[:caps])
    for(action <- actions, item = item(action, assigns, admin?), do: item) ++ mode_items(assigns)
  end

  def items(_assigns), do: []

  # As the toolbar's `doc_action_button/1`: a link opens its address, a
  # dialog (`schema_action`, admin-tier in `Caps`) is offered to an admin
  # only, anything else sends its event.
  defp item(%{"kind" => "link"} = action, assigns, _admin?) do
    opts = action["opts"] || %{}

    %{
      label: action["label"],
      name: action["name"],
      event: nil,
      href: href(opts["href"] || action["href"], assigns),
      target: opts["target"],
      rel: opts["rel"]
    }
  end

  defp item(%{"kind" => "modal"} = action, _assigns, true),
    do: %{
      label: action["label"],
      name: action["name"],
      event: "schema_action",
      values: %{"name" => action["name"]}
    }

  defp item(%{"kind" => "modal"}, _assigns, false), do: nil

  defp item(action, _assigns, _admin?) do
    event =
      case action["opts"] do
        %{"event" => ev} when is_binary(ev) -> ev
        _ -> action["name"]
      end

    %{label: action["label"], name: action["name"], event: event}
  end

  defp href(href, assigns) when is_binary(href) do
    PreviewLocations.interpolate(
      href,
      assigns.editor_doc,
      assigns[:dataset],
      slug(assigns[:current_workspace]),
      slug(assigns[:current_project])
    )
  end

  defp href(_href, _assigns), do: "#"

  defp slug(%{slug: slug}) when is_binary(slug), do: slug
  defp slug(_scope), do: ""

  # The toolbar's Classic | Beta switch, offered where the Studio offers it
  # (a document with blocks), under the toolbar's own word for it. In Beta the Studio draws its own header, which
  # the desk leaves alone, with the way back to Classic in it.
  defp mode_items(%{editor_blocks: [_ | _]} = assigns) do
    if Map.get(assigns, :editor_mode, :classic) == :classic,
      do: [
        %{
          label: gettext("Beta"),
          name: "editor-set-mode",
          event: "editor-set-mode",
          values: %{"mode" => "beta"}
        }
      ],
      else: []
  end

  defp mode_items(_assigns), do: []

  # The Studio offers Discard draft when it holds the published twin
  # (`published_doc`), which it reads only when the document opens: a draft
  # made by typing in a published document has a twin and no `published_doc`
  # until it is opened again. The Discard handler's own guard reads
  # `editor_is_draft` and `editor_has_published`, which the save keeps; so
  # does the menu. `published_doc` is read here for being there, nothing else
  # (the plugins' context does not carry it).
  defp with_twin(%{published_doc: nil, editor_is_draft: true, editor_has_published: true} = a),
    do: Map.put(a, :published_doc, a.editor_doc)

  defp with_twin(assigns), do: assigns

  # Two places draw it, with Sanity's two names: the header's "Show document
  # actions" (DocHeaderMenu) and the footer's "Open document actions"
  # (DocumentPane). `icon-btn` and `data-tip` are the names Sanity's specs
  # count header icon buttons by (previews-tips J57), so only the header's
  # carries `icon-btn`; no style rides it here. One edit pane is open at a
  # time, so one anchor name per place will do; a pane id
  # (`desk-pane-2-doc:post;x`) is not a CSS name. The footer's menu opens
  # upwards.
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :place, :atom, default: :header, values: [:header, :footer]

  @doc "The \"…\" button and its menu."
  def menu(assigns) do
    assigns = assign(assigns, place(assigns.place))

    ~H"""
    <div :if={@items != []} class="dk-doc-menu">
      <button
        type="button"
        id={"#{@id}-button"}
        class={@button_class}
        popovertarget={@id}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={@label}
        data-tip={@label}
        style={"anchor-name: #{@anchor}"}
      >
        <span aria-hidden="true">…</span>
      </button>
      <div
        id={@id}
        popover
        role="menu"
        aria-labelledby={"#{@id}-button"}
        class="dk-doc-menu-list"
        style={"position-anchor: #{@anchor}; inset: auto; #{@at}; right: anchor(right); #{@margin}"}
      >
        <%= for item <- @items do %>
          <a
            :if={item[:href]}
            role="menuitem"
            tabindex="-1"
            href={item.href}
            target={item[:target]}
            rel={item[:rel]}
            data-desk-doc-action={item.name}
          >
            {item.label}
          </a>
          <button
            :if={!item[:href]}
            type="button"
            role="menuitem"
            tabindex="-1"
            popovertarget={@id}
            popovertargetaction="hide"
            phx-click={item.event}
            data-desk-doc-action={item.name}
            {values(item)}
          >
            {item.label}
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp values(item), do: for({k, v} <- item[:values] || %{}, do: {"phx-value-#{k}", v})

  defp place(:header),
    do: %{
      label: gettext("Show document actions"),
      button_class: "dk-doc-menu-button icon-btn",
      anchor: "--dk-doc-menu",
      at: "top: anchor(bottom)",
      margin: "margin: 4px 0 0"
    }

  defp place(:footer),
    do: %{
      label: gettext("Open document actions"),
      button_class: "dk-doc-menu-button",
      anchor: "--dk-doc-menu-footer",
      at: "bottom: anchor(top)",
      margin: "margin: 0 0 4px"
    }
end
