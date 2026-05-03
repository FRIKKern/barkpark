defmodule BarkparkWeb.Plugs.OptionalTokenTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.OptionalToken

  @raw_token "optional-token-test-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Auth.create_token(@raw_token, "optional-token-test", "production", ["read"])
    :ok
  end

  defp build_conn() do
    Plug.Test.conn(:get, "/v1/data/query/production/anything")
  end

  test "no Authorization header → conn passes through, no :api_token assign" do
    conn = build_conn() |> OptionalToken.call(OptionalToken.init([]))
    refute conn.halted
    refute Map.has_key?(conn.assigns, :api_token)
  end

  test "valid Bearer token → assigns :api_token" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @raw_token)
      |> OptionalToken.call(OptionalToken.init([]))

    refute conn.halted
    assert %Barkpark.Auth.ApiToken{} = conn.assigns[:api_token]
  end

  test "invalid Bearer token → passes through, no assign, never halts" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer not-a-real-token")
      |> OptionalToken.call(OptionalToken.init([]))

    refute conn.halted
    refute Map.has_key?(conn.assigns, :api_token)
  end

  test "non-Bearer Authorization header is ignored" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Preview some-jwt")
      |> OptionalToken.call(OptionalToken.init([]))

    refute conn.halted
    refute Map.has_key?(conn.assigns, :api_token)
  end
end
