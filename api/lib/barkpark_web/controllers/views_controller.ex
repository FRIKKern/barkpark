defmodule BarkparkWeb.ViewsController do
  @moduledoc """
  `POST /w/:workspace_slug/p/:project_slug/v1/data/views/:dataset` records
  views of documents (`Barkpark.Search.Views`, guide `docs/search/VIEWS.md`).

  The body or query string names the documents: `id` (one document id) or
  `ids` (up to 50). A token caller may add `visitor`, an opaque value that
  identifies one visitor of its site for the day, such as a hash of its own
  session id; the server hashes it again with a daily salt. Without a token,
  `visitor` is ignored and the client IP and user agent stand in for it, so a
  browser cannot pick a fresh visitor per request to beat the dedupe.

  The answer is `202` with `{"ok": true, "accepted": n, "duplicates": d}`.
  `accepted` counts the views buffered; a view of an id that is not a
  published document of the dataset is dropped later, at flush, and is not
  reported back.
  """
  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.WriteScope
  alias Barkpark.RateLimiter
  alias Barkpark.Search.Views

  action_fallback(BarkparkWeb.FallbackController)

  @max_visitor_bytes 256

  def record(conn, %{"dataset" => dataset} = params) do
    with {:ok, ids} <- ids(params),
         dataset_id when is_binary(dataset_id) <-
           WriteScope.resolve_read_dataset_id(dataset, scope_opts(conn)) || {:error, :not_found},
         {:ok, result} <- Views.record(dataset_id, ids, visitor(conn, params)) do
      conn
      |> put_status(:accepted)
      |> json(%{ok: true, accepted: result.accepted, duplicates: result.duplicates})
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> invalid(reason)
    end
  end

  defp ids(%{"ids" => ids}) when is_list(ids) do
    if length(ids) > Views.max_ids_per_request(), do: {:error, :too_many_ids}, else: {:ok, ids}
  end

  defp ids(%{"ids" => ids}) when is_binary(ids), do: {:ok, String.split(ids, ",", trim: true)}
  defp ids(%{"id" => id}) when is_binary(id), do: {:ok, [id]}
  defp ids(_params), do: {:error, :no_ids}

  # A token caller's own visitor value, else the request's IP and user agent.
  # Neither is stored: `Views.Buffer.visitor_key/2` hashes it with the day's
  # in-memory salt.
  defp visitor(conn, params) do
    case {conn.assigns[:api_token], params["visitor"]} do
      {token, v} when not is_nil(token) and is_binary(v) and v != "" ->
        "v:" <> binary_part(v, 0, min(byte_size(v), @max_visitor_bytes))

      _ ->
        ua = conn |> get_req_header("user-agent") |> List.first() || ""
        "ip:" <> RateLimiter.client_ip(conn) <> "|" <> ua
    end
  end

  defp invalid(:too_many_ids) do
    {:error,
     {:validation_failed, "request body",
      %{"ids" => ["at most #{Views.max_ids_per_request()} ids per request"]},
      "Send at most #{Views.max_ids_per_request()} ids, or split them over several requests."}}
  end

  defp invalid(_reason) do
    {:error,
     {:validation_failed, "request body",
      %{"id" => ["name a document id with id, or a list with ids"]},
      "Send {\"id\": \"<document id>\"} or {\"ids\": [\"<id>\", ...]}."}}
  end
end
