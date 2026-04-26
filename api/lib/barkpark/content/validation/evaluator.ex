defmodule Barkpark.Content.Validation.Evaluator do
  @moduledoc """
  Apply compiled cross-field rules to a document.

  ## Output contract

      Barkpark.Content.Validation.Evaluator.run(doc, schema_id, tag) ::
        %{errors: [violation], warnings: [violation], infos: [violation]}

      violation :: %{
        severity: :error | :warning | :info,
        code:     String.t(),
        message:  String.t(),
        rule_name: String.t(),
        path:     String.t()
      }

  `path` is concrete (wildcards already substituted with array indices),
  matching what WI2's error envelope serializer needs.

  ## Downstream WI handshake

    * **WI2** reads `errors / warnings / infos` and folds each violation
      into the v2 error envelope.
    * **WI3** registers a `codelist_ref` checker into
      `Barkpark.Validation.Registry`. Rules then use
      `op: "matches:codelist_ref"` and the args via the `value` field.
      No change to this evaluator is required.
    * **WI4** benchmarks `run/3` on a 200-field doc + 100 rules. The
      cache lookup (`Rules.for_schema/1`) is the only side effect on the
      hot path; the rest is pure interpretation of the AST.

  ## Tag filtering

    * `tag` is `:live`, `:mutate`, or `:export`.
    * A rule with no `tags` (empty `MapSet`) fires for every tag.
    * A rule with a non-empty `tags` set only fires when `tag ∈ tags`.

  ## Memoisation

  A per-pass cache keyed by `{rule_name, then_path, then_value}` short-
  circuits repeat checker invocations on identical arguments — important
  for WI3's `:codelist_ref` op which lookups can otherwise dominate the
  hot path on `arrayOf` documents with hundreds of children.
  """

  alias Barkpark.Content.Validation.Rule
  alias Barkpark.Content.Validation.Path, as: VPath
  alias Barkpark.Content.Validation.Ops
  alias Barkpark.Content.Validation.Rules

  @valid_tags [:live, :mutate, :export]

  @type tag :: :live | :mutate | :export
  @type violation :: %{
          severity: :error | :warning | :info,
          code: String.t(),
          message: String.t(),
          rule_name: String.t(),
          path: String.t()
        }
  @type result :: %{errors: [violation], warnings: [violation], infos: [violation]}

  @doc """
  Run every rule registered for `schema_id` filtered by `tag`. See module
  doc for the full output contract.
  """
  @spec run(map() | nil, any(), tag()) :: result()
  def run(doc, schema_id, tag) when tag in @valid_tags do
    rules = Rules.for_schema(schema_id)
    run_rules(doc, rules, tag)
  end

  @doc """
  Run an explicit list of rules. Useful for tests and for WI4's perf
  benchmark which seeds rules without touching the cache.
  """
  @spec run_rules(map() | nil, [Rule.t()], tag()) :: result()
  def run_rules(doc, rules, tag) when is_list(rules) and tag in @valid_tags do
    {violations, _cache} =
      rules
      |> Enum.filter(&applies_to_tag?(&1, tag))
      |> Enum.reduce({[], %{}}, fn rule, {acc, cache} ->
        {new_violations, cache2} = apply_rule(rule, doc, cache)
        {new_violations ++ acc, cache2}
      end)

    bucket(Enum.reverse(violations))
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp applies_to_tag?(%Rule{tags: nil}, _tag), do: true

  defp applies_to_tag?(%Rule{tags: tags}, tag) do
    MapSet.size(tags) == 0 or MapSet.member?(tags, tag)
  end

  defp apply_rule(%Rule{} = rule, doc, cache) do
    when_resolutions = VPath.resolve(rule.when.path, doc)

    when_fires? =
      Enum.any?(when_resolutions, fn {_p, v} ->
        Ops.eval(rule.when.op, v, rule.when.value)
      end)

    if when_fires? do
      then_resolutions = VPath.resolve(rule.then.path, doc)

      Enum.reduce(then_resolutions, {[], cache}, fn {path, value}, {acc, cache0} ->
        {ok?, cache1} = eval_then_with_cache(rule, value, cache0)

        if ok? do
          {acc, cache1}
        else
          {[build_violation(rule, path) | acc], cache1}
        end
      end)
    else
      {[], cache}
    end
  end

  defp eval_then_with_cache(%Rule{then: then}, value, cache) do
    key = {then.op, value, then.value}

    case Map.fetch(cache, key) do
      {:ok, cached} ->
        {cached, cache}

      :error ->
        result = Ops.eval(then.op, value, then.value)
        {result, Map.put(cache, key, result)}
    end
  end

  defp build_violation(%Rule{} = rule, path) do
    %{
      severity: rule.severity,
      code: Ops.code(rule.then.op),
      message: rule.message || default_message(rule),
      rule_name: rule.name,
      path: path
    }
  end

  defp default_message(%Rule{name: name, then: then}) do
    "Rule #{name} failed at #{then.path} (#{Ops.code(then.op)})"
  end

  defp bucket(violations) do
    Enum.reduce(violations, %{errors: [], warnings: [], infos: []}, fn v, acc ->
      case v.severity do
        :error -> %{acc | errors: [v | acc.errors]}
        :warning -> %{acc | warnings: [v | acc.warnings]}
        :info -> %{acc | infos: [v | acc.infos]}
      end
    end)
    |> Map.update!(:errors, &Enum.reverse/1)
    |> Map.update!(:warnings, &Enum.reverse/1)
    |> Map.update!(:infos, &Enum.reverse/1)
  end
end
