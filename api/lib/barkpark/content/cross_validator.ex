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
    schema_or_rules
    |> validate(doc)
    |> Enum.reject(& &1["satisfied"])
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
