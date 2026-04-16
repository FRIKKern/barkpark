defmodule BarkparkWeb.SearchController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  def search(conn, %{"dataset" => dataset} = params) do
    case params["q"] do
      nil ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "malformed", message: "missing required parameter: q"}})

      "" ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "malformed", message: "missing required parameter: q"}})

      query ->
        opts = [
          type: params["type"],
          perspective: parse_perspective(params["perspective"]),
          limit: parse_int(params["limit"], 50),
          offset: parse_int(params["offset"], 0)
        ]

        {docs, count} = Content.search_documents(query, dataset, opts)

        json(conn, %{
          documents: Envelope.render_many(docs),
          count: count,
          query: query
        })
    end
  end

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 0)
      :error -> default
    end
  end
  defp parse_int(_, default), do: default
end
