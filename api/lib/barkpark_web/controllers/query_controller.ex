defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Envelope

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
        perspective: to_string(perspective),
        documents: Envelope.render_many(documents),
        count: length(documents)
      })
    end
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id}) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      with {:ok, doc} <- Content.get_document(doc_id, type, dataset) do
        json(conn, Envelope.render(doc))
      end
    end
  end

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published
end
