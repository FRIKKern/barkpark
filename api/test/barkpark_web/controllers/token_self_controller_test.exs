defmodule BarkparkWeb.TokenSelfControllerTest do
  @moduledoc """
  `GET /v1/auth/token` — a token reads what it may do, without an admin token
  (task-bc2541aca8541ff1). `/v1/auth/me` needs a login session, so an API or app
  token had no way to learn its own permissions, dataset or seat; a Studio
  listed every app token with an admin token to find out.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  defp get_self(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get("/v1/auth/token")
  end

  test "a member token reads its permissions, dataset, workspace and seat" do
    ws_id = TenancyFixtures.default_workspace_id!()
    raw = "token-self-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "editor app", "production", ["read", "write"], ws_id)
    assert TenancyAuth.membership_role(token, ws_id)

    body = raw |> get_self() |> json_response(200)

    assert body["id"] == token.id
    assert body["permissions"] == ["read", "write"]
    assert body["dataset"] == "production"
    assert body["tier"] == "write"
    assert body["workspace"]["id"] == ws_id
    assert body["seat"]["role"] == TenancyAuth.membership_role(token, ws_id)

    assert body["seat"]["can"] == %{
             "read" => true,
             "write" => true,
             "publish" => true,
             "admin" => false
           }

    refute Map.has_key?(body, "token_hash")
  end

  test "a read-only token reads it is read-only" do
    ws_id = TenancyFixtures.default_workspace_id!()
    raw = "token-self-ro-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "viewer", "production", ["read"], ws_id)

    body = raw |> get_self() |> json_response(200)
    assert body["tier"] == "read"
    assert body["seat"]["can"]["write"] == false
  end

  test "no token is a 401" do
    assert scoped_conn() |> get("/v1/auth/token") |> json_response(401)
  end
end
