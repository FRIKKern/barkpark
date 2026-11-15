defmodule BarkparkWeb.Studio.Desk.Fieldsets do
  @moduledoc """
  Schema fieldsets and folding, as the desk draws them.

  A schema's `"fieldsets"` (`[%{"name", "title", "options"}]`) gather the
  fields that name one (`"fieldset" => "size"`) under one title, where the
  first of them stands, as the TanStack Studio's `inFieldsets` and Sanity do.
  A fieldset, or an object field, with `options.collapsible` or
  `options.collapsed` folds: its title is a button.

  FOLDING NEVER TOUCHES WHAT IS SAVED. A folded fieldset keeps every input in
  the page; the desk's sheet only stops drawing them. The form posts the same
  fields folded or open, so a save cannot drop or blank a value because its
  fieldset was shut.

  ONE STATE, ONE PLACE. Open or shut is the title button's `aria-expanded`
  and nothing else; the sheet reads it
  (`fieldset:has(> legend > .object-toggle[aria-expanded="false"])`). The
  button flips it with a LiveView JS command, which LiveView keeps across its
  patches. No event reaches the server.

  IDS. LiveView keeps that state on the element, and matches elements across
  a patch by id. So the fieldset and its button each carry an id of their own
  (`fold_id/2`): without one, a fieldset that stopped being drawn handed its
  state to whichever fieldset took its place. The desk has one live editor
  form in a page, so the document id and the fieldset's name, or an object's
  field path, name one element.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  `fields` in drawing order: `{:field, field}`, or `{:set, fieldset, fields}`
  where the first field naming that fieldset stood. A field naming a fieldset
  the schema does not declare is drawn on its own.
  """
  @spec entries([map()], [map()] | nil) :: [{:field, map()} | {:set, map(), [map()]}]
  def entries(fields, fieldsets) do
    sets = Map.new(List.wrap(fieldsets), &{&1["name"], &1})

    fields
    |> Enum.reduce([], fn field, acc ->
      case Map.get(sets, field["fieldset"]) do
        nil -> [{:field, field} | acc]
        set -> into_set(acc, set, field)
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:set, set, members} -> {:set, set, Enum.reverse(members)}
      entry -> entry
    end)
  end

  defp into_set(acc, set, field) do
    name = set["name"]

    if Enum.any?(acc, &match?({:set, %{"name" => ^name}, _}, &1)) do
      Enum.map(acc, fn
        {:set, %{"name" => ^name} = s, members} -> {:set, s, [field | members]}
        entry -> entry
      end)
    else
      [{:set, set, [field]} | acc]
    end
  end

  @doc "A schema's document-level fieldsets; none outside the desk."
  @spec of(map() | nil, boolean()) :: [map()]
  def of(schema, true) when is_map(schema) do
    case Map.get(schema, :fieldsets) || Map.get(schema, "fieldsets") do
      list when is_list(list) -> Enum.filter(list, &is_binary(&1["name"]))
      _ -> []
    end
  end

  def of(_schema, _desk?), do: []

  @doc "Whether `options` (a fieldset's or an object field's) make it fold."
  @spec folds?(term()) :: boolean()
  def folds?(%{} = options), do: options["collapsible"] == true or options["collapsed"] == true
  def folds?(_options), do: false

  @doc "Whether a folding thing starts open."
  @spec open?(term()) :: boolean()
  def open?(%{"collapsed" => true}), do: false
  def open?(_options), do: true

  @doc "The `options` map of a field, parsed (`raw`) or as the schema has it."
  @spec options(map()) :: map()
  def options(%{raw: %{"options" => %{} = options}}), do: options
  def options(%{"options" => %{} = options}), do: options
  def options(_field), do: %{}

  @doc """
  One entry of `entries/2`. A field is the caller's own markup (the slot). A
  fieldset is a `<fieldset>` around its fields' markup.
  """
  attr :entry, :any, required: true
  # The open document's id: part of a fieldset's id.
  attr :scope, :string, default: "doc"
  slot :inner_block, required: true

  def entry(%{entry: {:field, field}} = assigns) do
    assigns = assign(assigns, :field, field)

    ~H"{render_slot(@inner_block, @field)}"
  end

  def entry(%{entry: {:set, set, fields}} = assigns) do
    options = if is_map(set["options"]), do: set["options"], else: %{}

    assigns =
      assign(assigns,
        name: set["name"],
        id:
          fold_id(
            "bp-set",
            "#{Barkpark.Content.DraftId.published_id(assigns.scope)}-#{set["name"]}"
          ),
        title: set["title"] || set["name"],
        fields: fields,
        folds: folds?(options),
        open: open?(options),
        columns: columns(options)
      )

    ~H"""
    <fieldset
      id={@id}
      class="field object-field fieldset-group"
      data-fieldset={@name}
      data-collapsible={@folds}
    >
      <legend>
        <.toggle :if={@folds} id={@id <> "-toggle"} open={@open} title={@title} />
        <span :if={not @folds}>{@title}</span>
      </legend>
      <div class={["fieldset", @columns && "fieldset-columns"]} style={@columns}>
        <%= for field <- @fields do %>
          {render_slot(@inner_block, field)}
        <% end %>
      </div>
    </fieldset>
    """
  end

  @doc """
  The title of a folding fieldset as a button. It flips its own
  `aria-expanded`, the one place the state lives.
  """
  attr :id, :string, required: true
  attr :open, :boolean, required: true
  attr :title, :string, required: true

  def toggle(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="object-toggle"
      aria-expanded={to_string(@open)}
      phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
    >
      <span class="toggle-arrow" aria-hidden="true">
        <svg xmlns="http://www.w3.org/2000/svg" width="21" height="21" viewBox="0 0 25 25">
          <path
            d="M10.5 16V9L16 12.5L10.5 16Z"
            fill="currentColor"
            stroke="currentColor"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      <span>{@title}</span>
    </button>
    """
  end

  @doc """
  The id of a folding element: `prefix` and `key` (a fieldset's document and
  name, an object's field path), with anything an id should not hold made `_`.
  """
  @spec fold_id(String.t(), String.t()) :: String.t()
  def fold_id(prefix, key),
    do: prefix <> "-" <> String.replace(to_string(key), ~r/[^A-Za-z0-9_.-]/, "_")

  # The column count rides as a custom property; the grid itself is the
  # sheet's, so the sheet's rule for a shut fieldset can win over it.
  defp columns(%{"columns" => n}) when is_integer(n) and n > 1 and n <= 12,
    do: "--bp-columns:#{n}"

  defp columns(_options), do: nil

  @doc "The desk sheet's rules for fieldsets and folding (`Desk.DocStyle`)."
  @spec css() :: String.t()
  def css do
    """
    .dk .dk-edit fieldset.fieldset-group { min-width: 0; margin: 0 0 59px; padding: 0; border: 0; }
    .dk .dk-edit fieldset.fieldset-group > legend { display: flex; align-items: center; margin: 0 0 11px; padding: 0; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-fg); }
    .dk .dk-edit fieldset.fieldset-group > .fieldset { border-left: 1px solid var(--dk-border); padding-left: 12px; }
    .dk .dk-edit fieldset.fieldset-group > .fieldset > .editor-field { margin-bottom: 32px; }
    .dk .dk-edit fieldset.fieldset-group > .fieldset > .editor-field:last-child { margin-bottom: 0; }
    .dk .dk-edit .fieldset-columns { display: grid; grid-template-columns: repeat(var(--bp-columns), minmax(0, 1fr)); column-gap: 20px; row-gap: 32px; }
    .dk .dk-edit fieldset.fieldset-group > .fieldset-columns > .editor-field { margin-bottom: 0; }
    .dk .dk-edit .object-toggle { display: inline-flex; align-items: center; gap: 3px; padding: 2px 4px 2px 0; border: 0; border-radius: 3px; background: none; font: inherit; color: inherit; cursor: pointer; }
    .dk .dk-edit .object-toggle svg { width: 21px; height: 21px; margin: -2px -6px; }
    .dk .dk-edit .object-toggle:focus-visible { outline: 2px solid var(--dk-focus-ring); }
    .dk .dk-edit .toggle-arrow { display: inline-grid; place-items: center; width: 9px; color: var(--dk-muted); transition: transform 100ms; }
    .dk .dk-edit .object-toggle[aria-expanded="true"] .toggle-arrow { transform: rotate(90deg); }
    .dk .dk-edit fieldset[data-collapsible] > legend { display: flex; align-items: center; min-height: 25px; }
    .dk .dk-edit fieldset[data-collapsible]:has(> legend > .object-toggle[aria-expanded="false"]) > legend { margin-bottom: 0; }
    .dk .dk-edit fieldset[data-collapsible]:has(> legend > .object-toggle[aria-expanded="false"]) > :not(legend) { display: none; }
    """
  end
end
