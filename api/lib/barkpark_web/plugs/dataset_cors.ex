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
        conn
        |> send_resp(204, "")
        |> halt()

      matched? ->
        register_before_send(conn, &add_cors_headers(&1, origin))

      true ->
        conn
    end
  end

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

  defp allowed_origins({:dataset, ds}) when is_binary(ds) and ds != "" do
    @always_allowed_origins ++ Content.allowed_origins_for_dataset(ds)
  end

  defp allowed_origins(_) do
    @always_allowed_origins ++ Application.get_env(:barkpark, :default_cors_origins, [])
  end

  defp dataset_from_conn(conn) do
    case conn.path_info do
      ["v1", "data", _, ds | _] ->
        {{:dataset, ds}, conn}

      ["v1", "preview", _, ds | _] ->
        {{:dataset, ds}, conn}

      ["v1", "schemas", ds | _] ->
        {{:dataset, ds}, conn}

      ["v1", "webhooks", ds | _] ->
        {{:dataset, ds}, conn}

      ["media" | _] ->
        conn = fetch_query_params(conn)

        case conn.query_params["dataset"] do
          ds when is_binary(ds) and ds != "" -> {{:dataset, ds}, conn}
          _ -> {:no_dataset, conn}
        end

      _ ->
        {:no_dataset, conn}
    end
  end
end
