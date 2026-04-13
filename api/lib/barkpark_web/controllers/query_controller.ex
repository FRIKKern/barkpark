defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  action_fallback BarkparkWeb.FallbackController

  @doc """
  List documents. Public API defaults to `perspective=published`.

  Query params:
    - `perspective` — "published" (default), "drafts", "raw"
    - `limit`       — max results (default 100, max 1000, min 1)
    - `offset`      — rows to skip (default 0)
    - `order`       — "_updatedAt:desc" (default), "_updatedAt:asc",
                      "_createdAt:desc", "_createdAt:asc"
    - `filter[field]=value` — structured field filter (Phoenix parses automatically)
  """
  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    unless Content.schema_public?(type, dataset) do
      {:error, :not_found}
    else
      perspective = parse_perspective(Map.get(params, "perspective", "published"))
      limit = parse_int(params["limit"], 100)
      offset = parse_int(params["offset"], 0)
      order = parse_order(params["order"])
      filter_map = Map.get(params, "filter") || %{}

      docs =
        Content.list_documents(type, dataset,
          perspective: perspective,
          filter_map: filter_map,
          limit: limit,
          offset: offset,
          order: order
        )

      json(conn, %{
        perspective: to_string(perspective),
        documents: Envelope.render_many(docs),
        count: length(docs),
        limit: limit,
        offset: offset
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

  defp parse_int(nil, d), do: d
  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> d
    end
  end
  defp parse_int(n, _) when is_integer(n), do: n

  defp parse_order("_updatedAt:asc"), do: :updated_at_asc
  defp parse_order("_updatedAt:desc"), do: :updated_at_desc
  defp parse_order("_createdAt:asc"), do: :created_at_asc
  defp parse_order("_createdAt:desc"), do: :created_at_desc
  defp parse_order(_), do: :updated_at_desc

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published
end
