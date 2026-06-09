defmodule Barkpark.Content.Expand do
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  @type spec :: :all | [String.t()]

  @spec expand([map()], spec(), String.t(), keyword()) :: [map()]
  def expand(docs, spec, dataset, opts \\ [])
  def expand([], _spec, _dataset, _opts), do: []
  def expand(docs, [], _dataset, _opts), do: docs

  def expand(docs, spec, dataset, opts) do
    # `published_only` (default false) hardens reference expansion for read-only
    # public shares: when true, an unresolvable PUBLISHED target is left
    # UNexpanded instead of falling back to its `drafts.` twin — so a read
    # share can never leak draft content through `?expand=`. When false the
    # behaviour is byte-identical to before.
    published_only = Keyword.get(opts, :published_only, false)

    docs_by_type = Enum.group_by(docs, & &1["_type"])
    # Thread the caller's scope (in `opts`) into schema resolution so reference
    # fields are detected with the SAME tenant scope as the document reads.
    # get_schema/3 resolves workspace-or-global, so this still finds a global
    # schema (legacy / authed callers) AND a scoped one (e.g. an anonymous
    # read-share query whose type schema lives in the shared workspace).
    schemas = load_schemas(Map.keys(docs_by_type), dataset, opts)

    Enum.map(docs, fn doc ->
      type = doc["_type"]
      schema = Map.get(schemas, type)

      case ref_fields_for(schema, spec) do
        [] ->
          doc

        fields ->
          Enum.reduce(fields, doc, fn %{"name" => field_name, "refType" => ref_type}, acc ->
            case Map.get(acc, field_name) do
              ref_id when is_binary(ref_id) and ref_id != "" ->
                case resolve_ref(ref_id, ref_type, dataset, opts, published_only) do
                  nil -> acc
                  resolved -> Map.put(acc, field_name, resolved)
                end

              _ ->
                acc
            end
          end)
      end
    end)
  end

  defp load_schemas(types, dataset, opts) do
    types
    |> Enum.map(fn type ->
      case Content.get_schema(type, dataset, opts) do
        {:ok, schema} ->
          {type, schema}

        _ ->
          # Fall back to a GLOBAL (tenant-less) schema. The schema only drives
          # reference-FIELD detection (which fields are references) — it is
          # content-type structure, not tenant data — so a global lookup is
          # safe. The referenced DOCUMENT reads (resolve_ref) stay scoped via
          # `opts`, so this never widens cross-tenant document access. This keeps
          # BOTH a scoped schema (anonymous read-share query) AND a legacy global
          # schema (existing scoped-reads-with-global-schema callers) working.
          case Content.get_schema(type, dataset) do
            {:ok, schema} -> {type, schema}
            _ -> {type, nil}
          end
      end
    end)
    |> Map.new()
  end

  defp ref_fields_for(nil, _spec), do: []

  defp ref_fields_for(schema, :all) do
    schema.fields
    |> Enum.filter(&(&1["type"] == "reference" && &1["refType"]))
  end

  defp ref_fields_for(schema, fields) when is_list(fields) do
    schema.fields
    |> Enum.filter(fn f ->
      f["type"] == "reference" && f["refType"] && f["name"] in fields
    end)
  end

  defp resolve_ref(ref_id, ref_type, dataset, opts, published_only) do
    case Content.get_document(ref_id, ref_type, dataset, opts) do
      {:ok, doc} ->
        Envelope.render(doc)

      _ when published_only ->
        # Read-share path: the published target is absent. Do NOT fetch or
        # render the `drafts.` twin — leave the reference unexpanded (the same
        # null/omitted outcome as any unresolvable ref), never leaking a draft.
        nil

      _ ->
        case Content.get_document("drafts." <> ref_id, ref_type, dataset, opts) do
          {:ok, doc} -> Envelope.render(doc)
          _ -> nil
        end
    end
  end
end
