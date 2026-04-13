defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  action_fallback BarkparkWeb.FallbackController

  @doc """
  List documents. Public API defaults to `perspective=published`.

  Query params:
    - `perspective` — "published" (default), "drafts", "raw"
    - `filter` — "field=value"
  """
  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      perspective = parse_perspective(Map.get(params, "perspective", "published"))
      filter = Map.get(params, "filter")
      documents = Content.list_documents(type, dataset, perspective: perspective, filter: filter)

      json(conn, %{
        type: type,
        perspective: to_string(perspective),
        documents: Enum.map(documents, &render_doc/1),
        count: length(documents)
      })
    end
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id}) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      with {:ok, doc} <- Content.get_document(doc_id, type, dataset) do
        json(conn, render_doc(doc))
      end
    end
  end

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  defp render_doc(doc) do
    %{
      _id: doc.doc_id,
      _type: doc.type,
      _draft: Content.draft?(doc.doc_id),
      _publishedId: Content.published_id(doc.doc_id),
      title: doc.title,
      status: doc.status,
      content: doc.content,
      _createdAt: doc.inserted_at,
      _updatedAt: doc.updated_at
    }
  end
end
