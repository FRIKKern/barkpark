defmodule BarkparkWeb.Plugs.PublicRead do
  @moduledoc """
  Deny-by-default enforcement for the `public-read` permission.

  The plug inspects `conn.assigns[:api_token]` (the existing token pipeline
  assigns under that key — `RequireToken` / `RequireAdmin` both read it).
  Three outcomes:

    * no token → pass-through (anonymous handling applies downstream)
    * token whose permissions list is anything *other than* exactly
      `["public-read"]` → pass-through (read/write/admin unaffected)
    * token whose permissions list is exactly `["public-read"]` → strict
      enforcement:

        - allow `GET /v1/data/query/:dataset/:type`
        - allow `GET /v1/data/doc/:dataset/:type/:doc_id`
        - reject `?perspective` not in `[nil, "", "published"]` with
          `403 {"error": "perspective not allowed"}`
        - reject types whose schema visibility is not `"public"` with
          `404 {"error": "not found"}`
        - reject every other route/method with
          `403 {"error": "forbidden"}`

  Default posture is DENY on ambiguity.
  """

  import Plug.Conn
  alias Barkpark.Content

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:api_token] do
      %{permissions: ["public-read"]} -> enforce(conn)
      _ -> conn
    end
  end

  defp enforce(conn) do
    conn = fetch_query_params(conn)

    cond do
      not allowed_route?(conn) -> halt_json(conn, 403, "forbidden")
      not allowed_perspective?(conn) -> halt_json(conn, 403, "perspective not allowed")
      not schema_public?(conn) -> halt_json(conn, 404, "not found")
      true -> conn
    end
  end

  defp allowed_route?(%{method: "GET", path_info: ["v1", "data", "query", _ds, _type]}), do: true

  defp allowed_route?(%{method: "GET", path_info: ["v1", "data", "doc", _ds, _type, _id]}),
    do: true

  defp allowed_route?(_), do: false

  defp allowed_perspective?(conn) do
    conn.params["perspective"] in [nil, "", "published"]
  end

  defp schema_public?(%{path_info: path}) do
    {dataset, type} = extract_ds_type(path)
    Content.schema_public?(type, dataset)
  end

  defp extract_ds_type(["v1", "data", "query", ds, type]), do: {ds, type}
  defp extract_ds_type(["v1", "data", "doc", ds, type, _id]), do: {ds, type}

  defp halt_json(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
