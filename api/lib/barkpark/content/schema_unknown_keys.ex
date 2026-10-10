defmodule Barkpark.Content.SchemaUnknownKeys do
  @moduledoc """
  The keys a schema apply carries that Barkpark never reads (task-415c5c02fad8a3c7).

  `POST /v1/schemas/:dataset` accepted a misspelled key without a word: a field
  key `requred: true` was stored and never read, a rule key
  `validation: {requird: true}` never ran, a schema key `singelton: true` was
  dropped by cast. `unknown/1` names each such key by its JSON-pointer path so
  the controller can answer the write with an advisory per key.

  ADVISORY ONLY. Whether an unknown key should refuse the write is an open
  owner decision ("schema typo strictness"); nothing here refuses anything.

  The vocabularies are the keys the schema changeset casts, the keys
  docs/contracts/schema-reference.md lists, and the keys shipped plugin
  schemas declare (`schema_unknown_keys_test.exs` walks every plugin's
  `register_schemas/1` and fails if one would be flagged).
  """

  # The changeset's cast list, plus `validations` (read by parse/2, not stored
  # — still flagged below as dropped) and the echo keys a pulled schema carries
  # back (`id`, `schemaHash`), so a pull → apply round trip stays quiet.
  @schema_keys ~w(name title icon visibility owner_scoped singleton kind fields dataset
                  cors_origins actions groups desk_groups desk list_preview initial_values
                  cross_validations layout prefill workspace_id project_id dataset_id
                  id schemaHash)

  # The SDK echo spells these camelCase; the changeset casts snake_case only.
  @camel_echo %{
    "deskGroups" => "desk_groups",
    "listPreview" => "list_preview",
    "initialValues" => "initial_values",
    "crossValidations" => "cross_validations",
    "ownerScoped" => "owner_scoped"
  }

  @field_keys ~w(name type title description validation visibleWhen readOnly group surface
                 encrypted private visibility readable_by options onix fields of
                 rows layout source refType to refTypes refTypeTolerant hotspot alt
                 editor blocks ordered codelistId version issue_version languages format
                 fallbackChain groups default required?)

  @rule_keys ~w(required min max pattern unique message level)

  @type advisory :: %{path: String.t(), key: String.t(), message: String.t()}

  @doc """
  Every key in `attrs` (a schema apply body, path params already dropped) that
  Barkpark does not read, in document order. `[]` when there is none.
  """
  @spec unknown(map()) :: [advisory()]
  def unknown(attrs) when is_map(attrs) do
    top =
      for {k, _} <- attrs, k = to_string(k), k not in @schema_keys do
        advise("/" <> k, k, top_message(k))
      end

    top ++ fields(Map.get(attrs, "fields") || Map.get(attrs, :fields), "/fields")
  end

  def unknown(_), do: []

  defp top_message("validations"),
    do: "top-level `validations` is not stored; use `cross_validations`"

  defp top_message(k) do
    case @camel_echo do
      %{^k => snake} -> "schema key `#{k}` is not stored; send `#{snake}`"
      _ -> "schema key `#{k}` is not a schema key Barkpark reads; it was dropped"
    end
  end

  defp fields(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {f, i} -> field(f, "#{path}/#{i}") end)
  end

  defp fields(_, _), do: []

  defp field(f, path) when is_map(f) do
    f = Map.new(f, fn {k, v} -> {to_string(k), v} end)

    own =
      for {k, _} <- f, k not in @field_keys do
        advise("#{path}/#{k}", k, "field key `#{k}` is not a key Barkpark reads; it is ignored")
      end

    own ++
      rules(f["validation"], path <> "/validation") ++
      fields(f["fields"], path <> "/fields") ++
      of(f["of"], path <> "/of") ++
      blocks(f["blocks"], path <> "/blocks/of")
  end

  defp field(_, _), do: []

  # `of` is one field shape (arrayOf) or a list of member types / v1 entries;
  # a bare string entry (`of: ["string"]`) has no keys to check.
  defp of(m, path) when is_map(m), do: field(m, path)
  defp of(list, path) when is_list(list), do: fields(list, path)
  defp of(_, _), do: []

  defp blocks(%{} = b, path), do: fields(b["of"] || b[:of], path)
  defp blocks(_, _), do: []

  defp rules(m, path) when is_map(m), do: rule_map(m, path)

  defp rules(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {m, i} when is_map(m) -> rule_map(m, "#{path}/#{i}")
      _ -> []
    end)
  end

  defp rules(_, _), do: []

  defp rule_map(m, path) do
    for {k, _} <- m, k = to_string(k), k not in @rule_keys do
      advise(
        "#{path}/#{k}",
        k,
        "validation rule `#{k}` is not a rule Barkpark runs; it is ignored"
      )
    end
  end

  defp advise(path, key, message), do: %{path: path, key: key, message: "#{path}: #{message}"}
end
