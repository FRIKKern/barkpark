defmodule BarkparkWeb.SearchIntel do
  @moduledoc """
  Shared request metadata for search intelligence across API surfaces.
  """

  @doc false
  def actor_key(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-client") do
      [client | _] when is_binary(client) and client != "" ->
        "client:" <> String.slice(client, 0, 64)

      _ ->
        case conn.assigns[:api_token] do
          %{id: id} -> "token:" <> id
          _ -> "anon"
        end
    end
  end

  @doc false
  def session_key(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-client") do
      [client | _] when is_binary(client) and client != "" ->
        String.slice(client, 0, 64)

      _ ->
        nil
    end
  end

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

  defp client_tracked?(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-client") do
      [client | _] when is_binary(client) and client != "" -> true
      _ -> false
    end
  end

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
