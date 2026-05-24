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
        case Ecto.UUID.cast(String.trim(id)) do
          {:ok, uuid} -> uuid
          _ -> nil
        end

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
  def parse_period_start(nil), do: nil

  def parse_period_start(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
