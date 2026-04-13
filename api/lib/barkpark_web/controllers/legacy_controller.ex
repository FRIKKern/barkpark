defmodule BarkparkWeb.LegacyController do
  @moduledoc "Backward-compatible API matching the Go TUI's original endpoints."

  use BarkparkWeb, :controller

  alias Barkpark.Content

  action_fallback BarkparkWeb.FallbackController

  @dataset "production"

  def index(conn, %{"type" => type} = params) do
    filter_map = parse_legacy_filter(Map.get(params, "filter"))
    documents = Content.list_documents(type, @dataset, filter_map: filter_map, limit: 10_000)

    json(conn, %{
      type: type,
      documents: Enum.map(documents, &render_legacy_doc/1),
      count: length(documents)
    })
  end

  def show(conn, %{"type" => type, "id" => doc_id}) do
    with {:ok, doc} <- Content.get_document(doc_id, type, @dataset) do
      json(conn, render_legacy_doc(doc))
    end
  end

  def create(conn, %{"type" => type} = params) do
    attrs = Map.drop(params, ["type"])

    # Map legacy format to internal format
    doc_id = Map.get(attrs, "id") || Map.get(attrs, "doc_id")
    internal_attrs = %{
      "doc_id" => doc_id,
      "title" => Map.get(attrs, "title"),
      "status" => Map.get(attrs, "status", "draft"),
      "content" => Map.drop(attrs, ["id", "doc_id", "title", "status", "updatedAt"])
    }

    case Content.upsert_document(type, internal_attrs, @dataset) do
      {:ok, doc} ->
        conn
        |> put_status(:created)
        |> json(render_legacy_doc(doc))

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete(conn, %{"type" => type, "id" => doc_id}) do
    with {:ok, _} <- Content.delete_document(doc_id, type, @dataset) do
      json(conn, %{deleted: doc_id})
    end
  end

  def schemas(conn, _params) do
    schemas = Content.list_schemas(@dataset)

    json(conn, Enum.map(schemas, fn s ->
      %{
        name: s.name,
        title: s.title,
        icon: s.icon,
        fields: s.fields
      }
    end))
  end

  # Parse legacy "field=value" filter string into a map for list_documents/3.
  defp parse_legacy_filter(nil), do: %{}
  defp parse_legacy_filter(""), do: %{}
  defp parse_legacy_filter(s) do
    case String.split(s, "=", parts: 2) do
      [field, value] -> %{field => value}
      _ -> %{}
    end
  end

  defp render_legacy_doc(doc) do
    base = %{
      id: doc.doc_id,
      title: doc.title,
      status: doc.status,
      updatedAt: doc.updated_at
    }

    # Merge content values at top level for legacy compat
    case doc.content do
      content when is_map(content) and map_size(content) > 0 ->
        Map.put(base, :values, content)

      _ ->
        base
    end
  end
end
