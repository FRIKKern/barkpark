defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  action_fallback BarkparkWeb.FallbackController

  @doc """
  List documents. Public API defaults to `perspective=published`.

  Query params:
    - `perspective` — "published" (default), "drafts", "raw"
    - `filter` — "field=value"
    - `expand` — "true" to resolve reference fields (default: true)
  """
  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      perspective = parse_perspective(Map.get(params, "perspective", "published"))
      filter = Map.get(params, "filter")
      expand? = Map.get(params, "expand", "true") != "false"
      documents = Content.list_documents(type, dataset, perspective: perspective, filter: filter)

      ref_fields = if expand?, do: get_ref_fields(type, dataset), else: []

      json(conn, %{
        type: type,
        perspective: to_string(perspective),
        documents: Enum.map(documents, &render_doc(&1, ref_fields, dataset)),
        count: length(documents)
      })
    end
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      expand? = Map.get(params, "expand", "true") != "false"
      ref_fields = if expand?, do: get_ref_fields(type, dataset), else: []

      with {:ok, doc} <- Content.get_document(doc_id, type, dataset) do
        json(conn, render_doc(doc, ref_fields, dataset))
      end
    end
  end

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  defp render_doc(doc, ref_fields, dataset) do
    content = expand_refs(doc.content || %{}, ref_fields, dataset)

    %{
      _id: doc.doc_id,
      _type: doc.type,
      _draft: Content.draft?(doc.doc_id),
      _publishedId: Content.published_id(doc.doc_id),
      title: doc.title,
      status: doc.status,
      content: content,
      _createdAt: doc.inserted_at,
      _updatedAt: doc.updated_at
    }
  end

  # Get reference field definitions from the schema
  defp get_ref_fields(type, dataset) do
    case Content.get_schema(type, dataset) do
      {:ok, schema} ->
        schema.fields
        |> Enum.filter(fn f -> f["type"] == "reference" && f["refType"] end)
        |> Enum.map(fn f -> {f["name"], f["refType"]} end)
      _ ->
        []
    end
  end

  # Expand reference fields in content from raw IDs to objects
  defp expand_refs(content, [], _dataset), do: content
  defp expand_refs(content, ref_fields, dataset) do
    Enum.reduce(ref_fields, content, fn {field_name, ref_type}, acc ->
      case Map.get(acc, field_name) do
        nil -> acc
        "" -> acc
        ref_id when is_binary(ref_id) ->
          resolved = resolve_ref(ref_id, ref_type, dataset)
          Map.put(acc, field_name, resolved)
        _ -> acc
      end
    end)
  end

  # Resolve a single reference ID to an expanded object
  defp resolve_ref(ref_id, ref_type, dataset) do
    # Try published first, then draft
    doc = case Content.get_document(ref_id, ref_type, dataset) do
      {:ok, d} -> d
      _ ->
        case Content.get_document("drafts.#{ref_id}", ref_type, dataset) do
          {:ok, d} -> d
          _ -> nil
        end
    end

    if doc do
      %{
        "_ref" => Content.published_id(doc.doc_id),
        "_type" => ref_type,
        "title" => doc.title,
        "status" => doc.status
      }
    else
      # Return raw ref if doc not found
      %{"_ref" => ref_id, "_type" => ref_type}
    end
  end
end
