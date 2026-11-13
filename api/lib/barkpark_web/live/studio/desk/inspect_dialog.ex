defmodule BarkparkWeb.Studio.Desk.InspectDialog do
  @moduledoc """
  Sanity's Inspect dialog: the open document as the API gives it, as a tree
  ("Parsed") and as JSON ("Raw JSON"). Ctrl+Alt+I while a document is open
  opens it and Escape closes it (`bp-desk.js`). Whether it is open is in the
  URL, as Sanity's: `inspect=on` on the last document (`:desk_inspect` follows
  it), so Back after closing opens it again and a navigation away closes it.

  It reads nothing: it renders the document the editor already holds
  (`editor_doc`) through `Content.Envelope.render/3`, with the page's own
  caller, so a field this caller may not read is not shown here either.

  A `<dialog>` in the edit pane, where TanStack's is (`.inspect-backdrop`):
  it dims that pane's form only, under the pane's header and over its
  footer, the card 12 px in, so the navbar and the other panes stay as they
  are (`EditorHost` draws it in the pane body's `.dk-inspect-layer`).
  `bp-desk.js` opens it when it is mounted, not as a modal, which would lift
  it over the whole page. It keeps a modal's keys itself, as TanStack's
  `DialogBox`: the focus starts on its close button, Tab stays inside it,
  and Escape or a press on the dim area closes it and gives the focus back
  to where it was. Its content is what the document was when it opened
  (`phx-update="ignore"`, which also keeps the browser's `open` on it).

  It looks as the TanStack Studio's (barkpark-studio `InspectDialog`,
  `JsonTree`; LOOKS C3): a card, the title in italics, and Parsed as its
  JSON tree in a monospace, each key and value in its syntax colour, every
  object and array open, each saying what it holds ("{…} 21 properties",
  "[…] 3 items").

  Over the tree is TanStack's search box: a node stays while its key, its
  value or anything under it holds the words (any case), every branch that
  holds a match opens, and each count says how many of its keys it shows
  ("{…} 2 properties"). `bp-desk.js` filters the tree as one types: the
  dialog is `phx-update="ignore"`, so the page does not draw it again.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.Envelope
  alias Phoenix.LiveView.JS

  # Sanity's order: the system keys first, then the fields by name.
  @system ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :doc, :map, required: true, doc: "the open document (`editor_doc`)"
  attr :schema, :any, default: nil
  attr :caller, :any, default: nil

  @doc "The dialog, open."
  def dialog(assigns) do
    envelope = Envelope.render(assigns.doc, assigns.schema, assigns.caller)
    assigns = assign(assigns, entries: entries(envelope), envelope: envelope)

    ~H"""
    <dialog
      id={@id}
      class="dk-inspect"
      aria-labelledby={"#{@id}-title"}
      data-desk-inspect
      phx-update="ignore"
      phx-mounted={JS.dispatch("desk:show-modal")}
    >
      <div class="dk-inspect-head">
        <h2 id={"#{@id}-title"}><.titled title={@title} /></h2>
        <form method="dialog">
          <button type="submit" class="dk-inspect-close" aria-label={gettext("Close")}>
            <BarkparkWeb.Icons.desk_icon name="close" size={21} />
          </button>
        </form>
      </div>
      <div role="tablist" class="dk-inspect-tabs" aria-label={gettext("Inspect views")}>
        <button
          type="button"
          role="tab"
          id={"#{@id}-tab-parsed"}
          aria-controls={"#{@id}-parsed"}
          aria-selected="true"
          data-desk-inspect-tab
        >
          {gettext("Parsed")}
        </button>
        <button
          type="button"
          role="tab"
          id={"#{@id}-tab-raw"}
          aria-controls={"#{@id}-raw"}
          aria-selected="false"
          tabindex="-1"
          data-desk-inspect-tab
        >
          {gettext("Raw JSON")}
        </button>
      </div>
      <%!-- The one scroller (focus:165): the dialog fits the window, the body scrolls. --%>
      <div class="dk-inspect-body inspect-body">
        <div id={"#{@id}-parsed"} role="tabpanel" aria-labelledby={"#{@id}-tab-parsed"} class="dk-inspect-panel">
          <label class="dk-inspect-search">
            <BarkparkWeb.Studio.Desk.Glyph.glyph name="search" />
            <input
              type="text"
              class="dk-inspect-search-input"
              placeholder={gettext("Search")}
              aria-label={gettext("Search")}
              autocomplete="off"
              spellcheck="false"
              data-desk-inspect-search
            />
          </label>
          <ul class="dk-inspect-tree">
            <li>
              <details open>
                <summary><.held value={@envelope} /></summary>
                <.tree entries={@entries} />
              </details>
            </li>
          </ul>
        </div>
        <div id={"#{@id}-raw"} role="tabpanel" aria-labelledby={"#{@id}-tab-raw"} class="dk-inspect-panel" hidden>
          <pre><code>{Jason.encode!(ordered(@entries), pretty: true)}</code></pre>
        </div>
      </div>
    </dialog>
    """
  end

  attr :entries, :list, required: true

  # An object or an array: a key per line, every one open, as TanStack's
  # Inspect; its caret folds it.
  defp tree(assigns) do
    ~H"""
    <ul class="dk-inspect-tree">
      <li :for={{key, value} <- @entries}>
        <%= if is_map(value) or is_list(value) do %>
          <details open>
            <summary><span class="dk-inspect-key">{key}:</span><.held value={value} /></summary>
            <.tree entries={entries(value)} />
          </details>
        <% else %>
          <span class="dk-inspect-key">{key}:</span><span class="dk-inspect-value" data-type={type(value)}>{shown(value)}</span>
        <% end %>
      </li>
    </ul>
    """
  end

  attr :value, :any, required: true
  # A count no document holds, printed in the words for many and then
  # replaced by `{n}`: the translation keeps its own order around the number.
  attr :sentinel, :integer, default: 9_999_991

  # What an object or an array holds, TanStack's: "{…} 21 properties", "[…] 3 items".
  # The words for one and for many ride along, so the search can say how many
  # it shows (`{n}` is the count).
  defp held(assigns) do
    %{value: value, sentinel: sentinel} = assigns
    many = count(value, sentinel) |> String.replace(Integer.to_string(sentinel), "{n}")

    assigns =
      assign(assigns, :words, %{
        "data-brace" => brace(value),
        "data-one" => count(value, 1),
        "data-other" => many
      })

    ~H"""
    <span class="dk-inspect-count" {@words}>{brace(@value)} {count(@value)}</span>
    """
  end

  attr :title, :string, required: true

  # "Inspecting <em>title</em>": the words around the title are the
  # translation's, wherever it puts the title.
  defp titled(assigns) do
    marker = "\u0000"

    [before, after_title] =
      case String.split(gettext("Inspecting %{title}", title: marker), marker, parts: 2) do
        [b, a] -> [b, a]
        [b] -> [b, ""]
      end

    assigns = assign(assigns, before: before, after_title: after_title)

    ~H"""
    {@before}<em>{@title}</em>{@after_title}
    """
  end

  defp brace(map) when is_map(map), do: if(map_size(map) == 0, do: "{}", else: "{…}")
  defp brace(list), do: if(list == [], do: "[]", else: "[…]")

  defp count(map) when is_map(map), do: count(map, map_size(map))
  defp count(list), do: count(list, length(list))

  defp count(map, n) when is_map(map), do: ngettext("1 property", "%{count} properties", n)
  defp count(_list, n), do: ngettext("1 item", "%{count} items", n)

  # A string as it reads, unquoted, as TanStack's; anything else as JSON.
  defp shown(value) when is_binary(value), do: value
  defp shown(value), do: Jason.encode!(value)

  defp type(value) when is_binary(value), do: "string"
  defp type(value) when is_number(value), do: "number"
  defp type(value) when is_boolean(value), do: "boolean"
  defp type(nil), do: "null"
  defp type(_value), do: "other"

  defp entries(map) when is_map(map) do
    {system, fields} = Enum.split_with(map, fn {key, _} -> key in @system end)

    Enum.sort_by(system, fn {key, _} -> Enum.find_index(@system, &(&1 == key)) end) ++
      Enum.sort(fields)
  end

  defp entries(list) when is_list(list), do: Enum.with_index(list, fn value, i -> {i, value} end)

  # JSON in the tree's order, nested objects too.
  defp ordered(entries) when is_list(entries) do
    Jason.OrderedObject.new(Enum.map(entries, fn {key, value} -> {key, ordered_value(value)} end))
  end

  defp ordered_value(map) when is_map(map), do: ordered(entries(map))
  defp ordered_value(list) when is_list(list), do: Enum.map(list, &ordered_value/1)
  defp ordered_value(value), do: value
end
