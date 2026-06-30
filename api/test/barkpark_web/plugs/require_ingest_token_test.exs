defmodule BarkparkWeb.Plugs.RequireIngestTokenTest do
  @moduledoc """
  Unit tests for the ingest-tier auth plug. Verifies the two accept paths
  (shared secret + valid admin api_token) and the 401 reject shape.
  """
  use Barkpark.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkWeb.Plugs.RequireIngestToken
  alias Barkpark.Auth
  alias Barkpark.Secrets

  # config/test.exs sets this fixed value.
  @ingest_secret "barkpark-test-ingest-token"
  @admin_token "barkpark-test-ingest-admin"
  @junior_token "barkpark-test-ingest-junior"

  defp call(bearer) do
    conn(:post, "/v1/paperflow/papers")
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> RequireIngestToken.call(RequireIngestToken.init([]))
  end

  describe "shared-secret path" do
    test "the correct env ingest secret passes" do
      conn = call(@ingest_secret)
      refute conn.halted
    end

    test "a rotated DB ingest secret passes (and overrides env)" do
      assert {:ok, _} = Secrets.put("ingest_token", "rotated-secret")
      refute call("rotated-secret").halted
      # the old env secret no longer matches once the DB row exists
      assert call(@ingest_secret).halted
    end
  end

  describe "admin api_token path" do
    test "a valid admin token passes" do
      {:ok, _} =
        Auth.create_token(@admin_token, "ingest-admin", "test", ["read", "write", "admin"])

      refute call(@admin_token).halted
    end

    test "a valid non-admin token is rejected" do
      {:ok, _} = Auth.create_token(@junior_token, "ingest-junior", "test", ["read", "write"])
      conn = call(@junior_token)
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "reject shape" do
    test "garbage bearer returns the 401 envelope" do
      conn = call("totally-bogus-token")
      assert conn.halted
      assert conn.status == 401
      assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(conn.resp_body)
    end
  end
end
