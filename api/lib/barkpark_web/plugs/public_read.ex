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

  ## Both route shapes

  The clamp rides BOTH the flat read scope (`:api_grant_read`, paths like
  `/v1/data/query/:dataset/:type`) AND the tenancy-scoped mirror
  (`:shared_docs_api`, paths like `/w/:ws/p/:project/v1/data/query/...`). The
  scoped prefix `["w", ws, "p", project]` is stripped before matching so a
  public-read token minted for a workspace (the site-spawner BUILD token) is
  clamped on the SCOPED route it fetches over — the scoped route already gates
  workspace membership (necessary) but does NOT pin published-vs-draft within
  the workspace (not sufficient); this plug is the missing clamp.

  ## Scope-accurate visibility

  Mounted at the TAIL of each read pipeline, after `ResolveWorkspace` /
  `ResolveProject` (scoped path) or `AssignDefaultScope` (flat path) have set
  `:current_workspace` / `:current_project`. The schema-visibility check threads
  that resolved scope into `schema_public?/3` so a private type in THIS
  workspace is denied even when a same-named public type exists in another
  workspace or the shared/global layer. Absent scope assigns (e.g. the unit
  test's hand-built conn) fall back to dataset-string resolution — nil-safe.
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

  defp allowed_route?(%{method: "GET", path_info: path}) do
    case data_path(path) do
      ["v1", "data", "query", _ds, _type] -> true
      ["v1", "data", "doc", _ds, _type, _id] -> true
      _ -> false
    end
  end

  defp allowed_route?(_), do: false

  defp allowed_perspective?(conn) do
    conn.params["perspective"] in [nil, "", "published"]
  end

  defp schema_public?(%{path_info: path} = conn) do
    {dataset, type} = extract_ds_type(data_path(path))
    Content.schema_public?(type, dataset, scope_opts(conn))
  end

  # Strip the tenancy-scoped `/w/:ws/p/:project` prefix so the flat and scoped
  # route shapes match the same clause. A flat path passes through untouched.
  defp data_path(["w", _ws, "p", _proj | rest]), do: rest
  defp data_path(path), do: path

  defp extract_ds_type(["v1", "data", "query", ds, type]), do: {ds, type}
  defp extract_ds_type(["v1", "data", "doc", ds, type, _id]), do: {ds, type}

  # Tenancy opts from the resolved scope assigns (nil-safe): a private type in
  # THIS workspace stays denied even if a same-named public type lives in
  # another workspace or the shared/global layer. Absent assigns → [] → the
  # dataset-string fallback (matches the isolated unit test's bare conn).
  defp scope_opts(%{assigns: assigns}) do
    []
    |> put_scope(:workspace_id, Map.get(assigns, :current_workspace))
    |> put_scope(:project_id, Map.get(assigns, :current_project))
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope(opts, _key, _other), do: opts

  defp halt_json(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
