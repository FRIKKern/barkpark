defmodule BarkparkWeb.ScimResponse do
  @moduledoc """
  Shared SCIM 2.0 response helpers (era-w8-scim-conformance).

  One owner for the wire shapes an IdP (Okta / Azure AD) actually parses:
  Error envelopes (with `scimType`), ListResponse paging (`startIndex` /
  `itemsPerPage` / `totalResults`), resource `meta` (created / lastModified /
  version) and the `ETag` header + `If-Match` precondition that drive optimistic
  concurrency. Both `ScimUsersController` and `ScimGroupsController` render
  through here so the shapes never drift.
  """
  import Plug.Conn, only: [put_status: 2, put_resp_header: 3, get_req_header: 2]
  import Phoenix.Controller, only: [json: 2]

  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  # RFC 7644 §3.4.2.4 — the server's filter/paging ceiling. An IdP reads this off
  # ServiceProviderConfig; we clamp `count` to it so a runaway page can't scan.
  @max_page 200

  # The ceiling on `startIndex`, expressed in max-size pages: a client walking in
  # `@max_page`-sized pages can address 5_000 full pages before the bound binds.
  #
  # RFC 7644 §3.4.2.4 Table 6 bounds `startIndex` only BELOW — "A value less than
  # 1 SHALL be interpreted as 1" — and says nothing at all about an upper bound,
  # so the ceiling is the service provider's to pick. Two things follow, and they
  # are the whole argument for this constant:
  #
  #   * The RFC's own remedy for an out-of-domain `startIndex` is REINTERPRETATION
  #     ("SHALL be interpreted as 1"), not a 4xx. Clamping above is the symmetric
  #     treatment and the one an IdP is least surprised by; a 400 for a
  #     syntactically valid integer would be this server inventing a refusal the
  #     spec never asks for. (Contrast `GET /v1/secrets/:name/audit`, which DOES
  #     answer 400 on an over-large offset — there a silent clamp would have
  #     broken the caller's termination condition, because that endpoint has no
  #     `totalResults` for the caller to terminate on. SCIM does.)
  #   * A `startIndex` past the end is NOT an error condition: §3.4.2.4 Table 7
  #     defines `totalResults` as the full match count independent of the page,
  #     so a page past the end is a well-formed answer — empty `Resources`,
  #     `itemsPerPage` 0, `totalResults` intact. Clamping preserves exactly that
  #     answer for every input above the corpus.
  #
  # THE INVARIANT (not a copied expression — SCIM's `startIndex` is 1-BASED while
  # the document routes' `offset` is 0-BASED, so a clamp lifted from those routes
  # is off by one at BOTH ends):
  #
  #     1 <= effective startIndex <= @max_start_index
  #
  # and therefore, since `Barkpark.Scim.paginate/2` issues `offset: start_index - 1`:
  #
  #     0 <= OFFSET <= @max_start_index - 1
  #
  # The lower end is the RFC's floor (offset 0, the first row), NOT a 0-based
  # floor of 0 applied to a 1-based number; the upper end admits 999_999 as an
  # offset, not 1_000_000.
  @max_start_index @max_page * 5_000

  # ── Errors (RFC 7644 §3.12) ───────────────────────────────────────────────

  @doc """
  Render a SCIM Error. `scim_type` is the RFC 7644 §3.12 detail keyword
  (`invalidValue`, `uniqueness`, `invalidSyntax`, …) — omitted when nil so a
  bare status-only error (404 / 412) stays clean.
  """
  def error(conn, status, detail, scim_type \\ nil) do
    body =
      %{"schemas" => [@error_schema], "status" => to_string(status), "detail" => detail}
      |> maybe_put("scimType", scim_type)

    conn |> put_status(status) |> json(body)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Paging (RFC 7644 §3.4.2.4) ────────────────────────────────────────────

  @doc """
  Parse `startIndex` (1-based, clamped 1..#{@max_start_index}) and `count`
  (clamped 0..#{@max_page}) off query params. `count` nil ⇒ no client-supplied
  limit (server returns the full page). Returns `{start_index, count}` as
  `[start_index:, count:]`-ready integers.

  BOTH ends of `startIndex` are bounded. Unbounded, it reached Postgres as a raw
  `OFFSET` bind: `?startIndex=99999999999999999999999999` left the int8 domain
  and raised `DBConnection.EncodeError` — a caller-chosen 500 on a credentialed
  read path — while smaller-but-huge values echoed a nonsense `startIndex` back
  in the ListResponse.
  """
  def paging(params) do
    start_index = params |> Map.get("startIndex") |> to_int() |> clamp_start()

    count =
      case Map.get(params, "count") do
        nil -> nil
        raw -> raw |> to_int() |> clamp_count()
      end

    {start_index, count}
  end

  @doc "The server's advertised max page size (mirrors ServiceProviderConfig)."
  def max_page, do: @max_page

  @doc """
  The ceiling on `startIndex`. Exposed so a route-driven test can name the bound
  instead of hard-coding a magic number — the bound itself is only ever observed
  through `paging/1`.
  """
  def max_start_index, do: @max_start_index

  defp to_int(nil), do: nil
  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  defp clamp_start(n) when is_integer(n) and n >= 1, do: min(n, @max_start_index)
  defp clamp_start(_), do: 1

  defp clamp_count(nil), do: nil
  defp clamp_count(n) when is_integer(n) and n < 0, do: 0
  defp clamp_count(n) when is_integer(n), do: min(n, @max_page)

  @doc """
  Wrap `resources` (already-rendered maps) in a SCIM ListResponse. `total` is the
  full match count (independent of the returned page); `itemsPerPage` is the size
  of THIS page. `start_index` echoes the effective 1-based offset.
  """
  def list_response(resources, total, start_index) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total,
      "startIndex" => start_index,
      "itemsPerPage" => length(resources),
      "Resources" => resources
    }
  end

  # ── meta + version / ETag (RFC 7643 §3.1, RFC 7644 §3.14) ─────────────────

  @doc """
  Build a resource `meta` object: resourceType, created, lastModified, location
  and a weak `version` ETag derived from `updated_at`.
  """
  def meta(resource_type, location, inserted_at, updated_at) do
    %{
      "resourceType" => resource_type,
      "created" => iso(inserted_at),
      "lastModified" => iso(updated_at),
      "location" => location,
      "version" => version(updated_at)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc """
  A weak ETag for `updated_at` — monotonic in the row's last write, so a stale
  `If-Match` deterministically fails. Nil timestamp ⇒ no version.
  """
  def version(nil), do: nil
  def version(%DateTime{} = dt), do: ~s(W/"#{DateTime.to_unix(dt, :microsecond)}")

  @doc "Stamp the `ETag` response header from a version string (no-op when nil)."
  def with_etag(conn, nil), do: conn
  def with_etag(conn, version), do: put_resp_header(conn, "etag", version)

  @doc """
  Evaluate the `If-Match` precondition (RFC 7644 §3.14). Returns `:ok` when the
  header is absent OR any supplied entity-tag matches `current_version`;
  `:precondition_failed` when present and none match. `*` matches any existent
  version — fail-closed: a nil current version never satisfies a concrete tag.
  """
  def if_match(conn, current_version) do
    case get_req_header(conn, "if-match") do
      [] ->
        :ok

      values ->
        tags = values |> Enum.flat_map(&String.split(&1, ",")) |> Enum.map(&String.trim/1)

        cond do
          "*" in tags and not is_nil(current_version) -> :ok
          current_version && current_version in tags -> :ok
          true -> :precondition_failed
        end
    end
  end

  # ── location ──────────────────────────────────────────────────────────────

  @doc "Absolute URL of a SCIM resource, e.g. `https://host/scim/v2/Users/<id>`."
  def location(conn, collection, id) do
    "#{conn.scheme}://#{host_with_port(conn)}/scim/v2/#{collection}/#{id}"
  end

  defp host_with_port(%{scheme: :http, port: 80} = conn), do: conn.host
  defp host_with_port(%{scheme: :https, port: 443} = conn), do: conn.host
  defp host_with_port(conn), do: "#{conn.host}:#{conn.port}"
end
