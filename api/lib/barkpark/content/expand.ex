defmodule Barkpark.Content.Expand do
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  @type spec :: :all | [String.t()]

  @spec expand([map()], spec(), String.t()) :: [map()]
  def expand([], _spec, _dataset), do: []
  def expand(docs, [], _dataset), do: docs

  def expand(docs, spec, dataset) do
    docs_by_type = Enum.group_by(docs, & &1["_type"])
    schemas = load_schemas(Map.keys(docs_by_type), dataset)

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
                case resolve_ref(ref_id, ref_type, dataset) do
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

  defp load_schemas(types, dataset) do
    types
    |> Enum.map(fn type ->
      case Content.get_schema(type, dataset) do
        {:ok, schema} -> {type, schema}
        _ -> {type, nil}
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

  defp resolve_ref(ref_id, ref_type, dataset) do
    case Content.get_document(ref_id, ref_type, dataset) do
      {:ok, doc} ->
        Envelope.render(doc)

      _ ->
        case Content.get_document("drafts." <> ref_id, ref_type, dataset) do
          {:ok, doc} -> Envelope.render(doc)
          _ -> nil
        end
    end
  end
end
