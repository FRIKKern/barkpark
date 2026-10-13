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
  """

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
      satisfied = evaluate(Map.get(rule_str, "rule") || %{}, doc)
      Map.put(rule_str, "satisfied", satisfied)
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

    rules
    |> validate(doc)
    |> Enum.reject(& &1["satisfied"])
  end

  @operators ~w(eq neq in empty non_empty starts_with count_eq count_neq count_gt count_lt)

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

    %{
      path: "/" <> (first || "_document"),
      message: v["title"] || v["name"] || "cross-field rule",
      code: :cross_validation,
      params: %{name: v["name"], fields: fields, level: v["level"] || "error"}
    }
  end

  defp unevaluable_reason(rule, names) when is_map(rule) do
    case Map.get(rule, "rule", Map.get(rule, :rule)) do
      body when is_map(body) and map_size(body) > 0 -> body_reason(body, names)
      _ -> "no rule body"
    end
  end

  defp unevaluable_reason(_rule, _names), do: "not a map"

  defp body_reason(body, names) do
    case Map.get(body, "all", Map.get(body, :all)) || Map.get(body, "any", Map.get(body, :any)) do
      preds when is_list(preds) and preds != [] ->
        Enum.find_value(preds, fn
          p when is_map(p) -> body_reason(p, names)
          _ -> "a predicate is not a map"
        end)

      nil ->
        leaf_reason(body, names)

      _ ->
        "an all/any list is empty or not a list"
    end
  end

  defp leaf_reason(leaf, names) do
    field = Map.get(leaf, "field", Map.get(leaf, :field))
    op = Map.get(leaf, "operator", Map.get(leaf, :operator))

    cond do
      not is_binary(field) or field == "" -> "a predicate has no field"
      not is_binary(op) -> "a predicate has no operator"
      op not in @operators -> "unknown operator #{inspect(op)}"
      is_list(names) and hd(String.split(field, ".")) not in names -> "no field #{inspect(field)}"
      true -> nil
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

  defp evaluate(%{"all" => preds}, doc) when is_list(preds) do
    Enum.all?(preds, &eval_leaf(&1, doc))
  end

  defp evaluate(%{all: preds}, doc) when is_list(preds) do
    Enum.all?(preds, &eval_leaf(&1, doc))
  end

  defp evaluate(%{"any" => preds}, doc) when is_list(preds) do
    Enum.any?(preds, &eval_leaf(&1, doc))
  end

  defp evaluate(%{any: preds}, doc) when is_list(preds) do
    Enum.any?(preds, &eval_leaf(&1, doc))
  end

  defp evaluate(pred, doc) when is_map(pred) and map_size(pred) > 0 do
    eval_leaf(pred, doc)
  end

  # No rule body → treat as satisfied (vacuously true). Matches the
  # visibility default — never fail a doc on a malformed schema rule.
  defp evaluate(_, _), do: true

  # A leaf predicate may itself be a composed `all` / `any` (nested rules),
  # so recurse through evaluate/2 first. Otherwise feed to FieldVisibility,
  # which is the single source of truth for operator semantics.
  defp eval_leaf(%{"all" => _} = pred, doc), do: evaluate(pred, doc)
  defp eval_leaf(%{all: _} = pred, doc), do: evaluate(pred, doc)
  defp eval_leaf(%{"any" => _} = pred, doc), do: evaluate(pred, doc)
  defp eval_leaf(%{any: _} = pred, doc), do: evaluate(pred, doc)

  defp eval_leaf(pred, doc) when is_map(pred) do
    FieldVisibility.visible?(%{"visibleWhen" => pred}, doc)
  end

  defp eval_leaf(_, _), do: true

  # ── helpers ────────────────────────────────────────────────────────────────

  # Normalise the rule's TOP-LEVEL keys (name / title / rule / level / fields)
  # to strings so callers / templates can rely on the same shape regardless
  # of whether the rule came from JSON (string-keyed) or was hand-built in
  # Elixir (atom-keyed).
  defp stringify_top(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
