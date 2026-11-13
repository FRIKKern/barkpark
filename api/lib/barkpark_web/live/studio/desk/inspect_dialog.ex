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

  A modal `<dialog>`: `bp-desk.js` opens it when it is mounted. Its content
  is what the document was when it opened (`phx-update="ignore"`, which also
  keeps the browser's `open` on it).
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
    assigns = assign(assigns, entries: entries(envelope))

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
        <h2 id={"#{@id}-title"}>{gettext("Inspecting %{title}", title: @title)}</h2>
        <form method="dialog">
          <button type="submit" class="dk-inspect-close" aria-label={gettext("Close")}>
            <span aria-hidden="true">×</span>
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
          <.tree entries={@entries} />
        </div>
        <div id={"#{@id}-raw"} role="tabpanel" aria-labelledby={"#{@id}-tab-raw"} class="dk-inspect-panel" hidden>
          <pre><code>{Jason.encode!(ordered(@entries), pretty: true)}</code></pre>
        </div>
      </div>
    </dialog>
    """
  end

  attr :entries, :list, required: true

  # An object or an array: a key per line, nested ones folded until opened.
  defp tree(assigns) do
    ~H"""
    <ul class="dk-inspect-tree">
      <li :for={{key, value} <- @entries}>
        <%= if is_map(value) or is_list(value) do %>
          <details>
            <summary>
              <span class="dk-inspect-key">{key}</span>
              <span class="dk-inspect-count">{count(value)}</span>
            </summary>
            <.tree entries={entries(value)} />
          </details>
        <% else %>
          <span class="dk-inspect-key">{key}</span>
          <code class="dk-inspect-value">{Jason.encode!(value)}</code>
        <% end %>
      </li>
    </ul>
    """
  end

  defp entries(map) when is_map(map) do
    {system, fields} = Enum.split_with(map, fn {key, _} -> key in @system end)

    Enum.sort_by(system, fn {key, _} -> Enum.find_index(@system, &(&1 == key)) end) ++
      Enum.sort(fields)
  end

  defp entries(list) when is_list(list), do: Enum.with_index(list, fn value, i -> {i, value} end)

  defp count(map) when is_map(map), do: "{#{map_size(map)}}"
  defp count(list), do: "[#{length(list)}]"

  # JSON in the tree's order, nested objects too.
  defp ordered(entries) when is_list(entries) do
    Jason.OrderedObject.new(Enum.map(entries, fn {key, value} -> {key, ordered_value(value)} end))
  end

  defp ordered_value(map) when is_map(map), do: ordered(entries(map))
  defp ordered_value(list) when is_list(list), do: Enum.map(list, &ordered_value/1)
  defp ordered_value(value), do: value
end
