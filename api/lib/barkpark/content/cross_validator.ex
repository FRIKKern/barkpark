defmodule Barkpark.Content.CrossValidator do
  @moduledoc """
  Evaluates the `cross_validations` declared on a `%SchemaDefinition{}` (or any
  shape that exposes the same key — a plain map, a `Parsed` struct, or just the
  list of rules itself) against a document map.

  Each rule shape, read straight from schema JSON:

      {
        "name": "isbn_xor_gtin",
        "title": "At least one product identifier required",
        "rule": { "any": [
          { "field": "productIdentifiers", "operator": "non_empty" }
        ]},
        "level": "error",
        "fields": ["productIdentifiers"]
      }

  Predicates compose with `all` / `any` and bottom out at single-field maps
  with `field` + `operator` (+ optional `value`). The leaf predicate is
  evaluated by `Barkpark.Content.FieldVisibility` — the sealed, single source
  of truth also used by the Studio field renderer — so the same operator set
  as field visibility (`eq`, `neq`, `in`, `empty`, `non_empty`, `starts_with`)
  and the same dotted-path / list-flatten walker.

  Returns each rule annotated with `"satisfied" => true | false` so callers
  can render mixed satisfied/violating UIs; `violations/2` is the convenience
  filter for the banner case.

  ## Item rules (task-5bb338ffd4621865)

  `"each": "meny"` runs the rule once per item of that list; `"type":
  "sakerFraKnagg"` keeps only items whose `_type` is that. `each` is a dotted
  path (`"meny.under"`) that fans out over the lists on its way, as a
  condition's path does; the items are the objects in the list it ends at
  (scalars and nested lists are not items). Inside an item rule a leaf reads
  the ITEM: no `scope`, or `"parent"`, is the item, exactly the enclosing
  object a `visibleWhen` with `"scope": "parent"` reads from a field inside
  it; `"scope": "document"` reads the document root. `fields` name the
  item's fields. Each violated item is its own violation (carrying `"item"`,
  its path) and its own finding, at `/meny/1` (+ `/<first field>`), the same
  JSON-pointer form as every other finding. A list that is missing or not a
  list has no items, so the rule holds. Only the first #{50} broken items of a
  rule are named (`item_cap/0`); the rest are ONE violation at the list's path
  (`/meny`, `/meny/under`) saying how many more break it, at the rule's level,
  so a write with many broken items stays cheap to check and to refuse.
  """

  @item_cap 50

  @doc "How many broken items one item rule names; the rest are one summary violation."
  def item_cap, do: @item_cap

  alias Barkpark.Content.FieldVisibility

  @doc """
  Evaluate every cross-validation rule against `doc`. Returns the rules as a
  list of string-keyed maps with an added `"satisfied"` key.

  Accepts a `%SchemaDefinition{}`, a plain map (string- or atom-keyed
  `cross_validations`), the raw list of rules, or `nil` / `[]` (no rules,
  returns `[]`).
  """
  @spec validate(any(), map()) :: [map()]
  def validate(schema_or_rules, doc) when is_map(doc) do
    rules = extract_rules(schema_or_rules)

    Enum.map(rules, fn rule ->
      rule_str = stringify_top(rule)
      Map.put(rule_str, "satisfied", broken_at(rule_str, doc) == [])
    end)
  end

  def validate(_, _), do: []

  @doc """
  Same as `validate/2` but filters down to the unsatisfied rules — the set
  the editor banner surfaces.
  """
  @spec violations(any(), map()) :: [map()]
  def violations(schema_or_rules, doc) do
    {rules, _unevaluable} = partition(schema_or_rules)

    Enum.flat_map(rules, fn rule ->
      rule_str = Map.put(stringify_top(rule), "satisfied", false)

      Enum.map(broken_at(rule_str, doc), fn
        :document -> rule_str
        {:more, list_path, n} -> rule_str |> Map.put("item", list_path) |> Map.put("more", n)
        item_path -> Map.put(rule_str, "item", item_path)
      end)
    end)
  end

  # Where a rule breaks: [:document] or [] for a plain rule; for an item rule
  # the first @item_cap violated items' paths, then {:more, list_path, n} for
  # the rest: one pass, counting past the cap without a path or a list.
  defp broken_at(%{"each" => each} = rule, doc) when is_binary(each) do
    type = rule["type"]
    body = item_scoped(rule["rule"] || %{})
    segs = String.split(each, ".")

    {kept, count} =
      fold_items(doc, segs, [], {[], 0}, fn item, idxs, {kept, count} = acc ->
        cond do
          type != nil and item["_type"] != type -> acc
          evaluate(body, doc, item) -> acc
          count < @item_cap -> {[pointer(segs, idxs) | kept], count + 1}
          true -> {kept, count + 1}
        end
      end)

    more = count - @item_cap

    Enum.reverse(kept) ++ if(more > 0, do: [{:more, "/" <> Enum.join(segs, "/"), more}], else: [])
  end

  defp broken_at(rule, doc),
    do: if(evaluate(rule["rule"] || %{}, doc, nil), do: [], else: [:document])

  # Folds `fun.(item, idxs, acc)` over the objects in the list `segs` ends at,
  # in order, without building a list of them: `idxs` holds (reversed) each
  # list step's index, nil for an object step, so a path is only made for an
  # item that needs one (`pointer/2`). Memory stays flat however long the list.
  defp fold_items(node, [seg | rest], idxs, acc, fun) when is_map(node) do
    case {Map.get(node, seg), rest} do
      {list, []} when is_list(list) ->
        fold_list(list, 0, acc, fn item, i, acc ->
          if is_map(item), do: fun.(item, [i | idxs], acc), else: acc
        end)

      {list, _} when is_list(list) ->
        fold_list(list, 0, acc, fn item, i, acc ->
          fold_items(item, rest, [i | idxs], acc, fun)
        end)

      {%{} = obj, [_ | _]} ->
        fold_items(obj, rest, [nil | idxs], acc, fun)

      _ ->
        acc
    end
  end

  defp fold_items(_, _, _, acc, _), do: acc

  defp fold_list([], _i, acc, _fun), do: acc
  defp fold_list([h | t], i, acc, fun), do: fold_list(t, i + 1, fun.(h, i, acc), fun)

  # The item's JSON pointer: "/meny/1", "/meny/0/under/2", "/innstillinger/meny/1".
  defp pointer(segs, idxs) do
    segs
    |> Enum.zip(Enum.reverse(idxs))
    |> Enum.map_join(fn
      {seg, nil} -> "/" <> seg
      {seg, i} -> "/#{seg}/#{i}"
    end)
  end

  # Inside an item rule a leaf reads the item unless it says "document".
  defp item_scoped(%{} = pred) do
    case Enum.find(["all", "any", "one", :all, :any, :one], &is_list(Map.get(pred, &1))) do
      nil ->
        if Map.get(pred, "scope", Map.get(pred, :scope)) in ["document", :document],
          do: pred,
          else: Map.put(pred, "scope", "parent")

      key ->
        Map.update!(pred, key, fn preds -> Enum.map(preds, &item_scoped/1) end)
    end
  end

  defp item_scoped(pred), do: pred

  @operators ~w(eq neq in empty non_empty starts_with count_eq count_neq count_gt count_lt gt gte lt lte)

  @doc """
  The rules split into `{evaluable, unevaluable}` (task-9754deb160e95a80).
  A rule is UNEVALUABLE when it is not a map, has no `rule` body, has a leaf
  with no string `field`/`operator`, names an operator outside
  #{inspect(@operators)}, or (given a schema with `fields`) names a field the
  schema does not declare. Each unevaluable entry is `{rule, reason}`.

  `violations/2` reads only the evaluable half, and so does `findings/2`, so
  the Studio banner and the write door can never disagree about a rule.
  An unevaluable rule is never a violation: it cannot fail a write.
  """
  @spec partition(any()) :: {[map()], [{any(), String.t()}]}
  def partition(schema_or_rules) do
    names = field_names(schema_or_rules)

    schema_or_rules
    |> extract_rules()
    |> Enum.reduce({[], []}, fn rule, {ok, bad} ->
      case unevaluable_reason(rule, names) do
        nil -> {[rule | ok], bad}
        reason -> {ok, [{rule, reason} | bad]}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
  end

  @doc """
  The violated rules as validation findings, split by level, in the shape
  `Barkpark.Content.Validation.finding()` uses. Built from `violations/2`
  itself, so a finding exists exactly when the Studio banner shows the rule.
  `"warning"`/`"info"` rules are warnings and never refuse; any other level is
  an error, as for field rules. The path is the rule's first `fields` entry
  (`/_document` when it names none); the message is the banner's own text,
  the rule's `title`, else its `name`.
  """
  @spec findings(any(), map()) :: %{errors: [map()], warnings: [map()]}
  def findings(schema_or_rules, doc) when is_map(doc) do
    {warnings, errors} =
      schema_or_rules
      |> violations(doc)
      |> Enum.map(&to_finding/1)
      |> Enum.split_with(&(&1.params.level in ["warning", "info"]))

    %{errors: errors, warnings: warnings}
  end

  def findings(_, _), do: %{errors: [], warnings: []}

  defp to_finding(v) do
    fields = if is_list(v["fields"]), do: Enum.filter(v["fields"], &is_binary/1), else: []
    first = List.first(fields)

    # A title that is not text (a per-language map) or is empty reads as absent, as does such a name.
    title = v["title"] || if(text?(v["name"]), do: v["name"]) || "cross-field rule"

    {path, message} =
      case v do
        %{"more" => n} ->
          {v["item"], "#{title} (#{n} more #{if n == 1, do: "item", else: "items"})"}

        %{"item" => item} when is_binary(item) ->
          {if(first, do: item <> "/" <> first, else: item), title}

        _ ->
          {"/" <> (first || "_document"), title}
      end

    %{
      path: path,
      message: message,
      code: :cross_validation,
      params: %{name: v["name"], fields: fields, level: v["level"] || "error"}
    }
  end

  defp unevaluable_reason(rule, names) when is_map(rule) do
    each = Map.get(rule, "each", Map.get(rule, :each))
    type = Map.get(rule, "type", Map.get(rule, :type))

    cond do
      each != nil and
          (not is_binary(each) or
             Enum.any?(String.split(each, "."), &(&1 == "" or &1 =~ ~r/^\d+$/))) ->
        "each is not a field path"

      is_list(names) and is_binary(each) and hd(String.split(each, ".")) not in names ->
        "no field #{inspect(each)} (each)"

      type != nil and each == nil ->
        "type needs each"

      type != nil and (not is_binary(type) or type == "") ->
        "type is not a type name"

      true ->
        case Map.get(rule, "rule", Map.get(rule, :rule)) do
          body when is_map(body) and map_size(body) > 0 -> body_reason(body, names, each != nil)
          _ -> "no rule body"
        end
    end
  end

  defp unevaluable_reason(_rule, _names), do: "not a map"

  # In an item rule (`item?`) a leaf names the ITEM's fields, which the
  # schema's top-level names cannot check; one with "scope": "document" names
  # the document's and is checked.
  defp body_reason(body, names, item?) do
    case Map.get(body, "all", Map.get(body, :all)) || Map.get(body, "any", Map.get(body, :any)) ||
           Map.get(body, "one", Map.get(body, :one)) do
      preds when is_list(preds) and preds != [] ->
        Enum.find_value(preds, fn
          p when is_map(p) -> body_reason(p, names, item?)
          _ -> "a predicate is not a map"
        end)

      nil ->
        scope = Map.get(body, "scope", Map.get(body, :scope))

        leaf_reason(
          body,
          if(item? and scope not in ["document", :document], do: nil, else: names)
        )

      _ ->
        "an all/any/one list is empty or not a list"
    end
  end

  defp leaf_reason(leaf, names) do
    field = Map.get(leaf, "field", Map.get(leaf, :field))
    op = Map.get(leaf, "operator", Map.get(leaf, :operator))
    other = Map.get(leaf, "valueField", Map.get(leaf, :valueField))

    cond do
      not is_binary(field) or field == "" ->
        "a predicate has no field"

      not is_binary(op) ->
        "a predicate has no operator"

      op not in @operators ->
        "unknown operator #{inspect(op)}"

      is_list(names) and hd(String.split(field, ".")) not in names ->
        "no field #{inspect(field)}"

      other != nil and (not is_binary(other) or other == "") ->
        "valueField is not a field name"

      is_list(names) and is_binary(other) and hd(String.split(other, ".")) not in names ->
        "no field #{inspect(other)} (valueField)"

      true ->
        nil
    end
  end

  # The top-level names a rule's `field` may start with, or nil when only a
  # rule list was given (no schema to check against). `title` lives on the
  # row, not in `fields`, and is always readable.
  defp field_names(%{fields: fields}) when is_list(fields), do: names_of(fields)
  defp field_names(%{"fields" => fields}) when is_list(fields), do: names_of(fields)
  defp field_names(_), do: nil

  defp names_of(fields) do
    ["title" | for(%{} = f <- fields, n = f["name"] || f[:name], is_binary(n), do: n)]
  end

  # ── rule extraction ────────────────────────────────────────────────────────

  defp extract_rules(%{cross_validations: rules}) when is_list(rules), do: rules
  defp extract_rules(%{"cross_validations" => rules}) when is_list(rules), do: rules
  defp extract_rules(rules) when is_list(rules), do: rules
  defp extract_rules(_), do: []

  # ── predicate evaluation ───────────────────────────────────────────────────

  defp evaluate(%{"all" => preds}, doc, parent) when is_list(preds),
    do: Enum.all?(preds, &eval_leaf(&1, doc, parent))

  defp evaluate(%{all: preds}, doc, parent) when is_list(preds),
    do: Enum.all?(preds, &eval_leaf(&1, doc, parent))

  defp evaluate(%{"any" => preds}, doc, parent) when is_list(preds),
    do: Enum.any?(preds, &eval_leaf(&1, doc, parent))

  defp evaluate(%{any: preds}, doc, parent) when is_list(preds),
    do: Enum.any?(preds, &eval_leaf(&1, doc, parent))

  # Exactly one of its predicates holds (task-606283a5dedc2403).
  defp evaluate(%{"one" => preds}, doc, parent) when is_list(preds),
    do: Enum.count(preds, &eval_leaf(&1, doc, parent)) == 1

  defp evaluate(%{one: preds}, doc, parent) when is_list(preds),
    do: Enum.count(preds, &eval_leaf(&1, doc, parent)) == 1

  defp evaluate(pred, doc, parent) when is_map(pred) and map_size(pred) > 0,
    do: eval_leaf(pred, doc, parent)

  # No rule body → treat as satisfied (vacuously true). Matches the
  # visibility default — never fail a doc on a malformed schema rule.
  defp evaluate(_, _, _), do: true

  # A leaf predicate may itself be a composed `all` / `any` / `one` (nested
  # rules), so recurse through evaluate/3 first. Otherwise feed to
  # FieldVisibility, the single source of truth for operator semantics; the
  # parent is the item of an item rule (nil for a plain rule: the document).
  defp eval_leaf(%{"all" => _} = pred, doc, parent), do: evaluate(pred, doc, parent)
  defp eval_leaf(%{all: _} = pred, doc, parent), do: evaluate(pred, doc, parent)
  defp eval_leaf(%{"any" => _} = pred, doc, parent), do: evaluate(pred, doc, parent)
  defp eval_leaf(%{any: _} = pred, doc, parent), do: evaluate(pred, doc, parent)
  defp eval_leaf(%{"one" => _} = pred, doc, parent), do: evaluate(pred, doc, parent)
  defp eval_leaf(%{one: _} = pred, doc, parent), do: evaluate(pred, doc, parent)

  defp eval_leaf(pred, doc, parent) when is_map(pred),
    do: FieldVisibility.visible?(%{"visibleWhen" => pred}, doc, parent)

  defp eval_leaf(_, _, _), do: true

  # ── helpers ────────────────────────────────────────────────────────────────

  # Normalise the rule's TOP-LEVEL keys (name / title / rule / level / fields)
  # to strings so callers / templates can rely on the same shape regardless
  # of whether the rule came from JSON (string-keyed) or was hand-built in
  # Elixir (atom-keyed).
  #
  # A `title` that is not text (a per-language map, a number) or is empty is
  # dropped: the rule still applies and reads as having no title, so every
  # reader (findings, the summary line, the banner) falls back to its name
  # (task-57d0947d4a29a073). The Studio reads a title the same way.
  defp stringify_top(map) when is_map(map) do
    map
    |> Map.new(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
    |> then(fn rule -> if text?(rule["title"]), do: rule, else: Map.delete(rule, "title") end)
  end

  defp text?(s), do: is_binary(s) and s != ""
end
