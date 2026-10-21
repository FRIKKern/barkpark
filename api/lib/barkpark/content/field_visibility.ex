defmodule Barkpark.Content.FieldVisibility do
  @moduledoc """
  The sealed, single source of truth for `visibleWhen` predicate evaluation.

  Schema fields declare `visibleWhen` as a structured map; this module returns
  `true`/`false`. Missing or nil `visibleWhen` → always visible (back-compat).
  It is pure (maps in, boolean out) with no web/assigns dependency, so both the
  Studio field renderer (`BarkparkWeb.Components.Fields.Visibility`, which
  delegates here) and `Barkpark.Content.CrossValidator` share ONE predicate —
  the operator semantics can never drift between the editor and validation.

  Schema declaration shape (book.json):

      {
        "name": "audienceRanges",
        "type": "arrayOf",
        ...,
        "visibleWhen": {
          "field": "audienceCodes",
          "operator": "non_empty"
        }
      }

  Supported operators: `eq`, `neq`, `in`, `empty`, `non_empty`, `starts_with`,
  and the count family `count_eq`, `count_neq`, `count_gt`, `count_lt` (Gyldendal
  parity E1.5 — Sanity's `hidden: ({parent}) => parent.banners?.length !== 2`
  becomes `{"field": "banners", "operator": "count_neq", "value": 2}` read as
  "visible when …"; a list counts its rows, a map its keys, nil/"" count 0).
  Field references support dotted paths (`"foo.bar.baz"` walks the doc map).

  `"scope"` picks where the path starts (task-9905a69475b1ff3b):
  `"document"` (the default) walks from the document root; `"parent"` walks
  from the enclosing object or array item, Sanity's `hidden: ({parent}) => …`.
  `{"field": "kind", "operator": "eq", "value": "url", "scope": "parent"}`
  inside a `links` item is "visible when THIS link's kind is url". The schema
  validator refuses `"parent"` on a top-level field of a document schema,
  which has no parent. A `kind: "object"` schema's own fields always sit inside
  the object where it is used, so there `"parent"` reads that object.
  When the path traverses a list, the walk flat-maps the rest of the path
  across every row — useful for `subjects.subject.subjectCode`-style refs.

  `"hidden": true` on a field hides it whatever `visibleWhen` says: the field
  keeps its stored value, the Studio form does not draw it, and the save path
  merges the posted fields into the stored content, so the value survives.

  `{"all": [...]}` and `{"any": [...]}` combine predicates, the shape
  `cross_validations` rules use, and may nest. Sanity's
  `hidden: ({document}) => document.a != "x" || document.b == "y"` is
  `{"all": [{"field": "a", "operator": "eq", "value": "x"},
  {"field": "b", "operator": "neq", "value": "y"}]}`. Each leaf carries its own
  `"scope"`.

  Field input flavours handled transparently:

    * Raw string-keyed maps (the studio_field_renderer path — fields come
      straight from `@editor_schema.fields`).
    * `%Barkpark.Content.SchemaDefinition.Field{}` structs (the composite /
      arrayOf path — `visibleWhen` lives on `field.raw["visibleWhen"]`).
  """

  @doc """
  Returns `true` when `field` should render given the current document
  state, `false` otherwise. Unknown operator → defaults to visible.
  """
  def visible?(field, doc), do: visible?(field, doc, nil)

  @doc """
  As `visible?/2`, with the enclosing object or array item a `"scope": "parent"`
  predicate reads. With no parent (a top-level field) it reads the document.
  """
  def visible?(field, doc, parent) when is_map(doc) do
    if hidden?(field) do
      false
    else
      case extract_visible_when(field) do
        nil -> true
        %{} = cond -> holds?(cond, doc, parent)
        _ -> true
      end
    end
  end

  def visible?(field, _doc, _parent), do: not hidden?(field)

  @doc """
  `true` when the field declares `hidden: true`: Sanity's literal `hidden`, a
  field kept in the stored document that no editor sees (task-7d4c026f3749ebee).
  It wins over `visibleWhen`. Only the literal `true` hides; any other value,
  including a string, leaves the field to `visibleWhen`.
  """
  def hidden?(field) when is_map(field) do
    cond do
      Map.get(field, "hidden") == true -> true
      Map.get(field, :hidden) == true -> true
      is_map(Map.get(field, :raw)) -> Map.get(field.raw, "hidden") == true
      true -> false
    end
  end

  def hidden?(_), do: false

  @doc "The map a predicate's path starts from: the parent for `\"scope\": \"parent\"`."
  def scope_root(cond, doc, parent) do
    case Map.get(cond, "scope", Map.get(cond, :scope)) do
      scope when scope in ["parent", :parent] and is_map(parent) -> parent
      _ -> doc
    end
  end

  # `all` / `any` combine predicates, as `cross_validations` rules do. Each leaf
  # picks its own scope, so one list can mix the document and the parent. An
  # empty list holds, the same vacuous truth as an unknown operator.
  defp holds?(%{"all" => preds}, doc, parent) when is_list(preds),
    do: Enum.all?(preds, &holds?(&1, doc, parent))

  defp holds?(%{all: preds}, doc, parent) when is_list(preds),
    do: Enum.all?(preds, &holds?(&1, doc, parent))

  defp holds?(%{"any" => [_ | _] = preds}, doc, parent),
    do: Enum.any?(preds, &holds?(&1, doc, parent))

  defp holds?(%{any: [_ | _] = preds}, doc, parent),
    do: Enum.any?(preds, &holds?(&1, doc, parent))

  defp holds?(%{} = cond, doc, parent), do: evaluate(cond, scope_root(cond, doc, parent))
  defp holds?(_, _, _), do: true

  # Pull the visibleWhen predicate off the field regardless of shape.
  # Order of precedence:
  #
  #   1. string-keyed top-level (raw map from schema JSON)
  #   2. atom-keyed top-level (atom-keyed map fallback)
  #   3. inside `:raw` on a parsed `%Field{}` struct
  defp extract_visible_when(field) when is_map(field) do
    cond do
      Map.get(field, "visibleWhen") != nil ->
        Map.get(field, "visibleWhen")

      Map.get(field, :visibleWhen) != nil ->
        Map.get(field, :visibleWhen)

      is_map(Map.get(field, :raw)) ->
        raw = Map.get(field, :raw)
        Map.get(raw, "visibleWhen") || Map.get(raw, :visibleWhen)

      true ->
        nil
    end
  end

  defp extract_visible_when(_), do: nil

  defp evaluate(%{"field" => field_ref, "operator" => op} = cond, doc) do
    value = walk_path(doc, String.split(field_ref, "."))
    expected = Map.get(cond, "value")
    apply_op(op, value, expected)
  end

  defp evaluate(%{field: field_ref, operator: op} = cond, doc) do
    value = walk_path(doc, String.split(to_string(field_ref), "."))
    expected = Map.get(cond, :value)
    apply_op(to_string(op), value, expected)
  end

  defp evaluate(_, _), do: true

  defp walk_path(value, []), do: value

  defp walk_path(value, [head | rest]) when is_map(value) do
    case Map.get(value, head, Map.get(value, safe_atom(head))) do
      nil -> nil
      next -> walk_path(next, rest)
    end
  end

  # Walk through a list: flat-map the remaining path across every row.
  # Result is a list of leaf values (so `non_empty` and `in` work
  # intuitively on `subjects.subject.subjectCode`-style refs).
  defp walk_path(value, [_ | _] = path) when is_list(value) do
    value
    |> Enum.flat_map(fn item ->
      case walk_path(item, path) do
        nil -> []
        list when is_list(list) -> list
        x -> [x]
      end
    end)
  end

  defp walk_path(_, _), do: nil

  defp apply_op("eq", value, expected), do: value == expected
  defp apply_op("count_eq", value, n) when is_integer(n), do: count_of(value) == n
  defp apply_op("count_neq", value, n) when is_integer(n), do: count_of(value) != n
  defp apply_op("count_gt", value, n) when is_integer(n), do: count_of(value) > n
  defp apply_op("count_lt", value, n) when is_integer(n), do: count_of(value) < n
  defp apply_op("neq", value, expected), do: value != expected
  defp apply_op("in", value, list) when is_list(list), do: value in list
  defp apply_op("in", _, _), do: false
  defp apply_op("empty", nil, _), do: true
  defp apply_op("empty", "", _), do: true
  defp apply_op("empty", [], _), do: true
  defp apply_op("empty", %{} = m, _), do: map_size(m) == 0
  defp apply_op("empty", _, _), do: false
  defp apply_op("non_empty", v, e), do: not apply_op("empty", v, e)

  defp apply_op("starts_with", v, prefix)
       when is_binary(v) and is_binary(prefix),
       do: String.starts_with?(v, prefix)

  defp apply_op("starts_with", _, _), do: false

  # Unknown operator → default visible (back-compat with future operators
  # that ship in schema before the renderer learns them).
  defp apply_op(_, _, _), do: true

  # Map.get with a string key falls back to an atom key when one exists —
  # but never create new atoms (so untrusted user input can't bloat the
  # atom table).
  defp safe_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_atom(_), do: nil

  # Row count for the `count_*` operators. The editor form keeps an arrayOf as a
  # list; a map-shaped array (index-keyed params) counts its keys; scalars 0.
  defp count_of(list) when is_list(list), do: length(list)
  defp count_of(%{} = m), do: map_size(m)
  defp count_of(_), do: 0
end
