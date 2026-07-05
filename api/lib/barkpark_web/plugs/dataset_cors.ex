defmodule BarkparkWeb.Plugs.DatasetCors do
  @moduledoc """
  Per-dataset CORS reflection plug.

  Runs at the endpoint layer (not router pipelines) so it can handle preflight
  OPTIONS requests before routing. The request's `Origin` header is matched
  against the dataset's `cors_origins` allow-list (inferred from `path_info`).
  For routes without a dataset segment, falls back to
  `:default_cors_origins` application config.

  Matching origins are reflected in `access-control-allow-origin`; mismatches
  never emit ACAO. Never wildcards — fail-closed.
  """

  @behaviour Plug

  import Plug.Conn

  alias Barkpark.Content

  @allow_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"

  # Union of the required minimum for task #17 and the original Corsica
  # allow_headers list at origin/main:api/lib/barkpark_web/endpoint.ex.
  # Preserving the Corsica set prevents preflight regressions for existing
  # browser-based SDK/Studio flows that rely on `accept`, `if-match`, etc.
  @allow_headers_list ~w(
    authorization
    content-type
    x-requested-with
    x-barkpark-preview-token
    accept
    if-match
    if-none-match
    idempotency-key
    x-barkpark-api-version
    last-event-id
  )
  @allow_headers Enum.join(@allow_headers_list, ", ")

  # Union of pagination headers (task #17 minimum) and the original Corsica
  # expose_headers list. Dropping any of these would break SDKs that read
  # ETag / x-request-id / x-barkpark-* cross-origin.
  @expose_headers_list ~w(
    x-total-count
    x-page
    x-per-page
    etag
    x-request-id
    retry-after
    x-barkpark-signature
    x-barkpark-timestamp
    x-barkpark-event-id
  )
  @expose_headers Enum.join(@expose_headers_list, ", ")

  @max_age "600"

  # Production frontend origins — always unioned with per-dataset cors_origins
  # and the :default_cors_origins app config. The Vercel apex is the canonical
  # public site; the wildcard covers preview deployments. Patterns containing
  # `*` match host segments only (no scheme/path globbing).
  # cross-link: docs/ops/studio-nav-bug-2026-04-19.md (these origins are load-bearing for Vercel apex)
  @always_allowed_origins [
    "https://barkpark.cloud",
    "https://www.barkpark.cloud",
    "https://*.vercel.app"
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] -> conn
      [origin | _] -> handle(conn, origin)
    end
  end

  defp handle(conn, origin) do
    {dataset_key, conn} = dataset_from_conn(conn)
    allowed = allowed_origins(dataset_key)
    matched? = origin_match?(origin, allowed)

    cond do
      preflight?(conn) and matched? ->
        send_preflight(conn, origin)

      preflight?(conn) ->
        # Fail-closed for the dataset/credentialed surfaces — EXCEPT plugin
        # paths: router-level plugin buckets (e.g. `:public_api` + PublicCors,
        # the anonymous Pulse surface) own their own CORS story, so their
        # preflights must reach the router. Non-CORS-owning plugin routes have
        # no OPTIONS route and 404 — browser-equivalent to the bare 204.
        if plugin_path?(conn) do
          conn
        else
          conn
          |> send_resp(204, "")
          |> halt()
        end

      matched? ->
        register_before_send(conn, &add_cors_headers(&1, origin))

      true ->
        conn
    end
  end

  defp plugin_path?(%Plug.Conn{path_info: ["v1", "plugins" | _]}), do: true
  defp plugin_path?(_conn), do: false

  defp preflight?(conn) do
    conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method") != []
  end

  defp send_preflight(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-allow-headers", @allow_headers)
    |> put_resp_header("access-control-max-age", @max_age)
    |> put_resp_header("vary", "Origin")
    |> send_resp(204, "")
    |> halt()
  end

  defp add_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-expose-headers", @expose_headers)
    |> put_resp_header("vary", "Origin")
  end

  defp origin_match?(origin, allowed) do
    normalized = strip_trailing_slash(origin)

    Enum.any?(allowed, fn a ->
      pattern = strip_trailing_slash(a)

      cond do
        not is_binary(pattern) -> false
        String.contains?(pattern, "*") -> wildcard_match?(pattern, normalized)
        true -> pattern == normalized
      end
    end)
  end

  # Subdomain wildcard match: `https://*.vercel.app` matches
  # `https://foo.vercel.app` and `https://foo-bar.vercel.app` but NOT
  # `https://vercel.app` or `https://evil.com/x.vercel.app`. Anchored on both
  # ends so path-injected origins cannot slip through.
  defp wildcard_match?(pattern, origin) do
    regex_source =
      pattern
      |> String.split("*")
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("[^./]+")

    case Regex.compile("\\A" <> regex_source <> "\\z") do
      {:ok, re} -> Regex.match?(re, origin)
      _ -> false
    end
  end

  defp strip_trailing_slash(s) when is_binary(s) do
    if String.ends_with?(s, "/") do
      binary_part(s, 0, byte_size(s) - 1)
    else
      s
    end
  end

  defp strip_trailing_slash(other), do: other

  defp allowed_origins({:dataset, ds, tenancy}) when is_binary(ds) and ds != "" do
    # Datasets are PROJECT-owned, so the same `dataset` STRING (e.g. "production")
    # names DIFFERENT datasets across projects. Resolve the project from the
    # request's `/w/:ws/p/:project` prefix (when present) so the cors_origins
    # union is read from the CALLER's dataset, not conflated across every project
    # sharing that slug. Flat routes (no prefix) resolve via the seeded Default
    # project inside allowed_origins_for_dataset/2.
    @always_allowed_origins ++ Content.allowed_origins_for_dataset(ds, cors_scope(tenancy))
  end

  defp allowed_origins(_) do
    @always_allowed_origins ++ Application.get_env(:barkpark, :default_cors_origins, [])
  end

  # Resolve a `[project_id: ...]` scope from the stripped tenancy slugs. Returns
  # `[]` (Default-project fallback) when the route is flat or the slugs don't
  # resolve to a real project — preserves the prior flat-route behaviour.
  defp cors_scope({ws_slug, project_slug})
       when is_binary(ws_slug) and is_binary(project_slug) do
    case Barkpark.Tenancy.get_project(ws_slug, project_slug) do
      %{id: id} -> [project_id: id]
      _ -> []
    end
  end

  defp cors_scope(_), do: []

  # Path-based tenancy (Wave 1) prefixes content routes with
  # `/w/:workspace_slug/p/:project_slug`, shifting every positional index. We
  # take that prefix off first, then match the SAME shapes against the remainder —
  # so both the flat (`/v1/data/...`) and the prefixed
  # (`/w/_/p/_/v1/data/...`) forms resolve the dataset identically. The
  # workspace/project slugs are now RETAINED (not discarded): the cors_origins
  # union is per-DATASET, and datasets are project-owned, so the slugs pick the
  # owning project. Flat-path behavior is unchanged — `take_tenancy_prefix/1`
  # returns `{nil, path_info}` for any path lacking the prefix (Default project).
  defp dataset_from_conn(conn) do
    # Keep the tenancy slugs (when the route carries the `/w/:ws/p/:project`
    # prefix) so allowed_origins/1 can resolve the project that OWNS the dataset
    # — the `dataset` STRING is unique only within a project. `tenancy` is nil on
    # flat routes, which fall back to the Default project downstream.
    {tenancy, rest} = take_tenancy_prefix(conn.path_info)

    case rest do
      ["v1", "data", _, ds | _] ->
        {{:dataset, ds, tenancy}, conn}

      ["v1", "preview", _, ds | _] ->
        {{:dataset, ds, tenancy}, conn}

      ["v1", "schemas", ds | _] ->
        {{:dataset, ds, tenancy}, conn}

      ["v1", "webhooks", ds | _] ->
        {{:dataset, ds, tenancy}, conn}

      ["media" | _] ->
        conn = fetch_query_params(conn)

        case conn.query_params["dataset"] do
          ds when is_binary(ds) and ds != "" -> {{:dataset, ds, tenancy}, conn}
          _ -> {:no_dataset, conn}
        end

      _ ->
        {:no_dataset, conn}
    end
  end

  # Split off a leading ["w", workspace_slug, "p", project_slug] tenancy prefix
  # when present, returning `{{ws_slug, project_slug}, rest}`; otherwise
  # `{nil, path_info}` (identity → flat paths keep their exact prior resolution).
  defp take_tenancy_prefix(["w", ws, "p", proj | rest]), do: {{ws, proj}, rest}
  defp take_tenancy_prefix(path_info), do: {nil, path_info}
end
