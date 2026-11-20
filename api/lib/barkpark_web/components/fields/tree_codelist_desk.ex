defmodule BarkparkWeb.Components.Fields.TreeCodelistDesk do
  @moduledoc """
  The desk's tree codelist (B05, codelist.spec:6): `TreeCodelistField`
  drawn as the TanStack Studio's `TreePicker` (barkpark-studio
  `app/src/components/CodelistInput.tsx`). The LiveComponent keeps the
  state (the tree, what is open, the search); this module draws it.

    * `.codelist-current`: the picked code, its label path from the root
      (`Fiction › Modern fiction`), or "Not in the list", or "Not a code
      (kept as stored)" over a value that is no code, and a × ("Remove
      code") that takes the value off the document.
    * `.codelist-search`: a search box named by the field's title. It posts
      itself on input (`phx-change`, 200 ms), so a value set without keys
      searches too. ArrowDown moves into the tree; Enter submits nothing.
      "Clear" empties it and gives the focus back to the box.
    * `ul.codelist-tree[role=tree]`, named by the codelist: one treeitem per
      visible code with its level, `aria-expanded` on a branch and
      `aria-selected`. One row is in the Tab order (WAI-ARIA tree). A click
      on a row picks its code; a click on a branch's ▶ opens it (in a search
      every match is open, and the ▶ picks like the row).
    * The keys are `bp-desk-codelist.js`'s: Up and Down, Home and End move;
      Right opens a branch or moves into it; Left closes it or moves to the
      parent; Enter and Space pick.

  A pick is the row's own `tree_node_select` press, named for the document
  by `bp-array-focus.js` as every press that writes (`PostIdentity`).

  The hidden input posts the stored code back with every change to another
  field, so the code stays. A stored value that is not a string (`kept`)
  has no input: the post then leaves it as it is stored. Its line says "Not
  a code (kept as stored)" and offers Remove, whose own press writes "" for
  the field; no other post touches the value.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc "The rows the tree shows, in order, from the component's assigns."
  def rows(%{nodes_by_code: nodes, roots: roots} = assigns) do
    searching? = not is_nil(assigns[:matched])

    open? =
      if searching?,
        do: fn _code -> true end,
        else: &MapSet.member?(assigns.expanded, &1)

    shown? = if searching?, do: &MapSet.member?(assigns.matched, &1), else: fn _ -> true end
    walk(roots, nodes, nil, 1, open?, shown?)
  end

  defp walk(codes, nodes, parent, level, open?, shown?) do
    Enum.flat_map(codes, fn code ->
      case Map.get(nodes, code) do
        %{children: children, label: label} = _node ->
          if shown?.(code) do
            branch? = children != []
            open = branch? and open?.(code)

            row = %{
              code: code,
              label: label,
              parent: parent,
              level: level,
              branch?: branch?,
              open?: open
            }

            [row | if(open, do: walk(children, nodes, code, level + 1, open?, shown?), else: [])]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :title, :string, default: nil
  attr :list_name, :string, default: nil
  attr :input_name, :string, default: ""
  attr :kept, :boolean, default: false
  attr :selected, :any, default: nil
  attr :current, :map, default: nil
  attr :readonly, :boolean, default: false
  attr :search_query, :string, default: ""
  attr :searching, :boolean, default: false
  attr :hit_count, :integer, default: 0
  attr :search_limit, :integer, default: 200
  attr :rows, :list, default: []

  def tree(assigns) do
    assigns = assign(assigns, :search_id, assigns.id <> "-search")

    ~H"""
      <input :if={not @kept} type="hidden" name={@input_name} value={@selected || ""} data-tree-selected="true" />
      <div :if={@current} class="codelist-current" data-codelist-kept={@kept && "true"}>
        <span :if={@current.code} class="mono">{@current.code}</span>
        <span class={["codelist-label", @current.label == nil && "invalid"]}>{current_label(@current, @kept)}</span>
        <button
          :if={not @readonly}
          type="button"
          class="icon-btn"
          aria-label={gettext("Remove code")}
          data-test-id="tree-codelist-remove"
          phx-click={JS.push("tree_node_clear", target: @myself) |> JS.focus(to: "#" <> @search_id)}
        >×</button>
      </div>
      <div class="codelist-search">
        <input
          id={@search_id}
          class="input form-input"
          type="search"
          name={"codelist_search[" <> @id <> "]"}
          autocomplete="off"
          aria-label={@title}
          aria-controls={@search_id <> "-tree"}
          placeholder={gettext("Search codes or labels…")}
          value={@search_query}
          phx-change="tree_search_input"
          phx-debounce="200"
          phx-target={@myself}
        />
        <button
          :if={@search_query != ""}
          type="button"
          class="btn"
          phx-click={JS.push("tree_search_clear", target: @myself) |> JS.focus(to: "#" <> @search_id)}
        >{gettext("Clear")}</button>
      </div>
      <p :if={@rows == []} class="muted codelist-empty">
        <%= if @searching do %>
          <%= gettext("No matches for \"%{query}\".", query: @search_query) %>
        <% else %>
          <%= gettext("No entries.") %>
        <% end %>
      </p>
      <ul :if={@rows != []} id={@search_id <> "-tree"} class="codelist-tree" role="tree" aria-label={@list_name}>
        <li
          :for={{row, i} <- Enum.with_index(@rows)}
          id={@id <> "-i-" <> row.code}
          role="treeitem"
          aria-level={row.level}
          aria-expanded={if row.branch?, do: to_string(row.open?)}
          aria-selected={to_string(row.code == @selected)}
          tabindex={if i == 0, do: "0", else: "-1"}
          style={"padding-left: #{4 + (row.level - 1) * 16}px"}
          data-code={row.code}
          data-parent={row.parent}
          phx-click={if not @readonly, do: "tree_node_select"}
          phx-value-code={row.code}
          phx-target={@myself}
        >
          <span
            class="codelist-toggle"
            aria-hidden="true"
            phx-click={if row.branch? and not @searching, do: "tree_node_toggle"}
            phx-value-code={row.code}
            phx-target={@myself}
          >{toggle_glyph(row)}</span>
          <span class="mono">{row.code}</span> <span>{row.label}</span>
        </li>
      </ul>
      <p :if={@searching and @hit_count >= @search_limit} class="muted codelist-empty">
        {gettext("The first 200 matches. Type more to narrow them.")}
      </p>
    """
  end

  defp current_label(_current, true), do: gettext("Not a code (kept as stored)")
  defp current_label(%{label: nil}, _kept), do: gettext("Not in the list")
  defp current_label(%{label: label}, _kept), do: label

  defp toggle_glyph(%{branch?: false}), do: ""
  defp toggle_glyph(%{open?: true}), do: "▼"
  defp toggle_glyph(_row), do: "▶"
end
