defmodule BarkparkWeb.SearchIntel do
  @moduledoc """
  Shared request metadata for search intelligence across API surfaces.
  """

  @doc """
  The identity a search event is filed under, and the key its owner's `recent`
  suggestions are read back by.

  THE ORDERING IS THE SECURITY PROPERTY. `x-bp-search-client` used to be
  consulted FIRST, so the actor was attacker-CHOSEN: any caller — authenticated
  or not — who knew another browser's id could send it as that header and read
  that browser's `recent` bucket verbatim (queries, filters, result counts,
  timestamps). Worse, the header OUTRANKED the token, so a token holder's own
  recents lived in a `client:<id>` bucket that a TOKENLESS caller could enter
  with one header. The header can no longer SELECT an actor; it only
  SUBDIVIDES the one the request already proved:

    * api_token present -> `token:<id>`, and the header is namespaced UNDER it
      (`token:<id>:<client>`) so a browser still gets its own recents without
      ever leaving its token's namespace. No header can reach into a token
      namespace, and no header can leave one.
    * no token, header present -> `client:<workspace>:<client>`, namespaced by
      the workspace the SERVER resolved from the route/token
      (`:current_workspace`, which the caller cannot pick), so one id under two
      tenants is two buckets.
    * neither -> `"anon"`, the shared bucket that
      `Barkpark.Search.Intelligence.recent_queries/6` deliberately answers with
      `[]`.

  What the header IS: a per-browser BEARER id — `crypto.randomUUID()` persisted
  in `localStorage["bp-search-client"]` (`templates/search-starter/lib/search-session.ts`,
  mirrored by the JS SDK's `sessionKey` option in `js/packages/core/src/search.ts`).
  Token-first ordering closes the impersonation half outright. The anonymous
  half is then bounded by that id's entropy: a random v4 UUID is not guessable,
  so an anonymous bucket is reachable only by a caller who was GIVEN the id.
  That is a bearer credential, not an authorization check — never put anything
  behind it that a leaked id must not reach.
  """
  def actor_key(conn) do
    case {conn.assigns[:api_token], client_id(conn)} do
      {%{id: id}, nil} -> "token:" <> id
      {%{id: id}, client} -> "token:" <> id <> ":" <> client
      {_, nil} -> "anon"
      {_, client} -> "client:" <> workspace_segment(conn) <> ":" <> client
    end
  end

  # The raw per-browser bearer id, capped. `nil` when absent or empty.
  defp client_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-client") do
      [client | _] when is_binary(client) and client != "" -> String.slice(client, 0, 64)
      _ -> nil
    end
  end

  # The server-resolved tenant, same source as the controllers' `workspace_id/1`
  # (`:current_workspace`, assigned by the pipeline — never a request param), so
  # the record path and the suggestions read path derive the SAME segment.
  # `"global"` is the pre-tenancy/no-workspace bucket.
  defp workspace_segment(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} when is_binary(id) -> id
      _ -> "global"
    end
  end

  @doc """
  The raw per-browser id, unchanged.

  Semantics deliberately UNTOUCHED by the actor_key hardening: `session_key` is
  a COUNTING key (distinct sessions accepting a correction — the anti-gaming
  gate on synonym auto-promotion), never a read selector, so it cannot be used
  to select another actor's data and does not share `actor_key/1`'s flaw.
  """
  def session_key(conn), do: client_id(conn)

  @doc false
  def parent_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-parent") do
      [id | _] when is_binary(id) and id != "" ->
        Barkpark.Repo.uuid_or_nil(String.trim(id))

      _ ->
        nil
    end
  end

  @doc false
  def source(conn, default \\ "api") do
    case Plug.Conn.get_req_header(conn, "x-bp-search-source") do
      [source | _] when is_binary(source) and source != "" ->
        String.slice(source, 0, 32)

      _ ->
        default
    end
  end

  @doc false
  def recording_disabled?(conn) do
    header_disabled? =
      case Plug.Conn.get_req_header(conn, "x-bp-search-disable") do
        [value | _] -> value in ["1", "true", "yes"]
        _ -> false
      end

    param_disabled? =
      case conn.params do
        %{"disableSearchIntel" => value} when value in ["1", "true", "yes"] -> true
        _ -> false
      end

    header_disabled? or param_disabled?
  end

  @doc false
  def tentative?(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-tentative") do
      [value | _] -> value in ["1", "true", "yes"]
      _ -> false
    end
  end

  @doc false
  def should_record?(conn) do
    cond do
      recording_disabled?(conn) -> false
      tentative?(conn) -> false
      client_tracked?(conn) -> record_committed?(conn)
      true -> true
    end
  end

  @doc false
  def tags(conn) do
    header_tags =
      case Plug.Conn.get_req_header(conn, "x-bp-search-tags") do
        [raw | _] -> parse_tags(raw)
        _ -> []
      end

    param_tags =
      case conn.params do
        %{"searchTags" => raw} when is_binary(raw) -> parse_tags(raw)
        %{"searchTags" => raw} when is_list(raw) -> normalize_tag_list(raw)
        _ -> []
      end

    (header_tags ++ param_tags)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp client_tracked?(conn), do: client_id(conn) != nil

  defp record_committed?(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-record") do
      [value | _] -> value in ["1", "true", "yes"]
      _ -> false
    end
  end

  defp parse_tags(raw) when is_binary(raw) do
    raw
    |> String.split(~r/[,;\s]+/u, trim: true)
    |> normalize_tag_list()
  end

  defp normalize_tag_list(tags) do
    tags
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.slice(&1, 0, 32))
  end

  @doc false
  def parse_period_start(nil), do: nil

  def parse_period_start(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # Phoenix parses `?periodStart[]=x` into a list and `?periodStart[k]=v` into a
  # map — neither matched a clause, so an anonymous request 500'd
  # (FunctionClauseError). Fail soft to nil (→ the default period window),
  # matching the fail-open idiom used across the search param parsers.
  def parse_period_start(_), do: nil
end
