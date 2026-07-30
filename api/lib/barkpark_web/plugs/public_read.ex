defmodule BarkparkWeb.Plugs.PublicRead do
  @moduledoc """
  Deny-by-default enforcement for the `public-read` permission.

  The plug inspects `conn.assigns[:api_token]` (the existing token pipeline
  assigns under that key — `RequireToken` / `RequireAdmin` both read it).
  Three outcomes:

    * no token → pass-through (anonymous handling applies downstream)
    * token whose permissions do NOT carry `"public-read"` → pass-through
      (read/write/admin unaffected)
    * token whose permissions CARRY `"public-read"` → strict enforcement:

        - allow `GET /v1/data/query/:dataset/:type`
        - allow `GET /v1/data/doc/:dataset/:type/:doc_id`
        - reject `?perspective` not in `[nil, "", "published"]` with
          `403 forbidden` / "perspective not allowed"
        - reject types whose schema visibility is not `"public"` with
          `404 not_found`
        - reject every other route/method with `403 forbidden`

  Default posture is DENY on ambiguity.

  ## MEMBERSHIP, never list equality

  The gate is `"public-read" in permissions`, mirroring
  `BarkparkWeb.AnonPerspective.anon_pinned?/1` — NOT `== ["public-read"]`.
  `BarkparkWeb.TokenController` mints from the allowlist `~w(public-read read)`
  over a PUBLIC route, so a caller can ask for `["public-read", "read"]` and a
  list-equality gate would let that token walk straight past the clamp on every
  pipeline. Equality was the bypass; membership closes it.

  ## Error envelope

  Denials go through `BarkparkWeb.ErrorResponse.emit/3`, i.e. the canonical
  `%{"error" => %{"code", "message", "hint"?, "request_id"?}}` body every other
  auth plug emits. The plug used to hand-build a FLAT `%{"error" => "forbidden"}`
  string, which was survivable while it governed two read routes and is not now
  that it governs the whole `:require_token` surface — a client keying on
  `error.code` would have seen a shape change per route.

  ## Every pipeline a token can reach

  The clamp rides the flat read scope (`:api_grant_read`, paths like
  `/v1/data/query/:dataset/:type`), the tenancy-scoped mirror
  (`:shared_docs_api`, paths like `/w/:ws/p/:project/v1/data/query/...`) AND
  `:require_token` — the two-plug pipeline behind every bearer-gated route,
  flat (`[:api, :require_token]`) and scoped (`[:scoped_api, :require_token]`)
  alike. Mounting it there is what closed the live leak: a freshly minted
  public-read token read `GET /v1/data/export/production` (52,208,330 bytes,
  2,500 documents, 129 drafts), `analytics`, `history`, `revision/:dataset/:id`
  and held an open `text/event-stream` on `listen` — none of which is a
  PublicRead-allowed route, all of which rode `:require_token` where the plug
  was absent. Because `allowed_route?/1` whitelists only the two GET data
  routes, and because a non-public-read token no-ops out of `call/2` before any
  of this, the mount denies exactly the public-read tier and leaves every other
  principal byte-identical.

  The scoped prefix `["w", ws, "p", project]` is stripped before matching so a
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
  alias BarkparkWeb.ErrorResponse

  def init(opts), do: opts

  def call(conn, _opts) do
    if public_read_token?(conn), do: enforce(conn), else: conn
  end

  # MEMBERSHIP, mirroring AnonPerspective.anon_pinned?/1 — a token minted
  # `["public-read", "read"]` by TokenController is still the public tier. The
  # map pattern requires the `:permissions` key and a list value: a token struct
  # without it is NOT clamped (absence of the key is not evidence of the tier).
  defp public_read_token?(conn) do
    case conn.assigns[:api_token] do
      %{permissions: perms} when is_list(perms) -> "public-read" in perms
      _ -> false
    end
  end

  defp enforce(conn) do
    conn = fetch_query_params(conn)

    cond do
      not allowed_route?(conn) ->
        deny(
          conn,
          {:error, :forbidden},
          "public-read tokens may only read published public documents"
        )

      not allowed_perspective?(conn) ->
        deny(conn, {:error, :forbidden}, "perspective not allowed")

      not schema_public?(conn) ->
        deny(conn, {:error, :not_found}, "not found")

      true ->
        conn
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

  # The repo's ONE envelope emitter (`@canonical capability:error-response-emit`)
  # — canonical code/status from Content.Errors, hint + request_id stamped, halt
  # included. Never hand-build the body here.
  defp deny(conn, reason, message), do: ErrorResponse.emit(conn, reason, message)
end
