defmodule BarkparkWeb.Plugs.CacheBodyReaderTest do
  @moduledoc """
  The path-scoped raw-body tee. On the GitHub webhook path it accumulates the
  read bytes into `conn.assigns[:raw_body]` (across a chunked body); on every
  other path it is a transparent pass-through that sets no assign.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkWeb.Plugs.CacheBodyReader

  @webhook_path "/v1/plugins/github/webhook"
  @body ~s({"action":"opened","issue":{"number":7}})

  defp json_conn(method, path, body) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
  end

  # Loop CacheBodyReader.read_body/2 to completion, mirroring how Plug.Parsers
  # drains a chunked body, and return the accumulated read plus the final conn.
  defp read_all(conn, opts, acc \\ "") do
    case CacheBodyReader.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_all(conn, opts, acc <> chunk)
    end
  end

  describe "github webhook path" do
    test "caches the full body into assigns.raw_body in one read" do
      conn = json_conn(:post, @webhook_path, @body)
      assert {:ok, read, conn} = CacheBodyReader.read_body(conn, [])
      assert read == @body
      assert conn.assigns[:raw_body] == @body
    end

    test "accumulates raw_body across a chunked body" do
      body = String.duplicate("x", 40)
      conn = json_conn(:post, @webhook_path, body)

      # A small :length forces the adapter to hand back {:more, ...} first, so we
      # exercise the multi-chunk accumulation path (not a single {:ok, ...}).
      assert {:more, _chunk, _} = CacheBodyReader.read_body(conn, length: 8)

      assert {:ok, full, conn} = read_all(conn, length: 8)
      assert full == body
      assert conn.assigns[:raw_body] == body
    end
  end

  describe "every other path" do
    test "reads through with NO raw_body assign (zero buffering)" do
      conn = json_conn(:post, "/v1/data/mutate/production", @body)
      assert {:ok, read, conn} = CacheBodyReader.read_body(conn, [])
      assert read == @body
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "a path that merely prefixes the webhook path does NOT cache" do
      conn = json_conn(:post, "/v1/plugins/github/webhook/extra", @body)
      assert {:ok, _read, conn} = CacheBodyReader.read_body(conn, [])
      refute Map.has_key?(conn.assigns, :raw_body)
    end
  end
end
