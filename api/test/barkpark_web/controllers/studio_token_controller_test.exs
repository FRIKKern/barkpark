defmodule BarkparkWeb.StudioTokenControllerTest do
  @moduledoc """
  `POST /v1/auth/studio-tokens` (task-7855ed1481992cf6): a workspace owner or
  admin signed in with a login session, or the instance admin token, mints the
  Studio's read token. Anyone else gets 403 and nothing is minted.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Auth, Repo, Sso}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup :reset_rate_limiter!

  setup do
    %{ws: create_workspace!()}
  end

  defp user_with_role(ws, role) do
    user =
      Sso.find_or_create_user("studio-#{role}-#{System.unique_integer([:positive])}@example.com")

    if role, do: {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user, ip_address: "127.0.0.1")
    raw
  end

  defp mint(bearer, body) do
    conn =
      scoped_conn()
      |> put_req_header("content-type", "application/json")

    conn = if bearer, do: put_req_header(conn, "authorization", "Bearer " <> bearer), else: conn
    post(conn, "/v1/auth/studio-tokens", body)
  end

  defp tokens_in(ws_id), do: Repo.all(from(t in ApiToken, where: t.workspace_id == ^ws_id))

  defp assert_studio_token(conn, ws) do
    body = json_response(conn, 201)
    assert body["permissions"] == ["read"]
    assert body["workspace"] == ws.slug

    {:ok, token} = Auth.verify_token(body["token"])
    assert token.workspace_id == ws.id
    assert TenancyAuth.membership_role(token, ws.id) == "member"

    # The Studio's first read: /v1/structure-style scoped reads need a seat.
    assert scoped_conn()
           |> put_req_header("authorization", "Bearer " <> body["token"])
           |> get("/v1/auth/token")
           |> json_response(200)
           |> get_in(["seat", "role"]) == "member"

    body
  end

  test "an owner signed in with a login session mints a read token with a member seat",
       %{ws: ws} do
    conn = mint(user_with_role(ws, "owner"), %{workspace: ws.slug})
    assert_studio_token(conn, ws)
  end

  test "an admin seat is enough", %{ws: ws} do
    conn = mint(user_with_role(ws, "admin"), %{workspace: ws.slug, dataset: "production"})
    assert_studio_token(conn, ws)
  end

  test "a member is refused with the reason and nothing is minted", %{ws: ws} do
    before = tokens_in(ws.id)
    conn = mint(user_with_role(ws, "member"), %{workspace: ws.slug})

    body = json_response(conn, 403)
    assert body["error"]["code"] == "studio_token_forbidden"
    assert body["error"]["message"] =~ "owner or admin"
    assert tokens_in(ws.id) == before
  end

  test "a user with no seat is refused, and an unknown workspace answers the same", %{ws: ws} do
    stranger = user_with_role(ws, nil)
    assert json_response(mint(stranger, %{workspace: ws.slug}), 403)
    assert json_response(mint(stranger, %{workspace: "no-such-ws"}), 403)
    assert tokens_in(ws.id) == []
  end

  test "the instance admin token mints into any workspace", %{ws: ws} do
    raw = "studio-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "admin", "production", ["read", "write", "admin"])
    assert_studio_token(mint(raw, %{workspace: ws.slug}), ws)
  end

  test "an admin token bound to another workspace is refused", %{ws: ws} do
    other = create_workspace!()
    raw = "studio-other-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "other", "production", ["read", "write", "admin"], other.id)
    assert json_response(mint(raw, %{workspace: ws.slug}), 403)
  end

  test "a read token cannot mint another", %{ws: ws} do
    raw = "studio-ro-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "ro", "production", ["read"], ws.id)
    assert json_response(mint(raw, %{workspace: ws.slug}), 403)
  end

  test "no workspace is a 422 and no credential is a 401", %{ws: ws} do
    assert json_response(mint(user_with_role(ws, "owner"), %{}), 422)["error"]["code"] ==
             "workspace_required"

    assert json_response(mint(nil, %{workspace: ws.slug}), 401)
  end
end
