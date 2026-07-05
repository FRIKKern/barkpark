defmodule BarkparkWeb.ScimUsersControllerTest do
  @moduledoc "SCIM 2.0 /scim/v2/Users — provision + instant deprovision (era-w4-scim-users)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.Membership
  import Ecto.Query

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    %{org: org, ws: ws, token: token}
  end

  defp scim(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp provision(token, email),
    do: scim(token) |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))

  describe "POST /scim/v2/Users — provision" do
    test "provisions a confirmed user who can then log in (via magic-link)" do
      %{token: token, ws: ws} = org_with_ws("acme")

      resp = provision(token, "alice@acme.com") |> json_response(201)
      assert resp["userName"] == "alice@acme.com"
      assert resp["active"] == true

      user = Accounts.get_user_by_email("alice@acme.com")
      assert user
      refute is_nil(user.confirmed_at)
      # member of the org's workspace
      assert Repo.exists?(
               from m in Membership,
                 where:
                   m.principal_type == "user" and m.principal_id == ^user.id and
                     m.workspace_id == ^ws.id
             )

      # "can then log in": the passwordless path mints a session
      {:ok, plaintext, _} = Accounts.build_login_token("alice@acme.com")
      assert {:ok, logged_in} = Accounts.consume_login_token(plaintext)
      assert logged_in.id == user.id
    end

    test "emits a user_provisioned audit event" do
      %{token: token, org: org} = org_with_ws("audit-prov")
      provision(token, "b@audit-prov.com") |> json_response(201)

      ev = Repo.one(from e in Event, where: e.action == "user_provisioned")
      assert ev.category == "membership"
      assert ev.metadata["organization_id"] == org.id
    end

    test "400 when userName is missing" do
      %{token: token} = org_with_ws("badreq")
      assert scim(token) |> post("/scim/v2/Users", Jason.encode!(%{})) |> json_response(400)
    end
  end

  describe "instant deprovision (the enterprise hard-req)" do
    test "DELETE revokes ALL sessions + membership + audits" do
      %{token: token, ws: ws} = org_with_ws("deprov")
      provision(token, "gone@deprov.com") |> json_response(201)
      user = Accounts.get_user_by_email("gone@deprov.com")
      {:ok, session} = Accounts.create_user_session_token(user)
      id = user.id

      assert scim(token) |> delete("/scim/v2/Users/#{id}") |> response(204)

      # session dead
      assert is_nil(Accounts.verify_user_session_token(session))
      # membership gone
      refute Repo.exists?(
               from m in Membership,
                 where: m.principal_id == ^id and m.workspace_id == ^ws.id
             )

      # audited
      assert Repo.exists?(from e in Event, where: e.action == "user_deprovisioned")
    end

    test "PATCH active:false deprovisions (soft: revokes access, keeps the row)" do
      %{token: token, ws: ws} = org_with_ws("softdeprov")
      provision(token, "soft@softdeprov.com") |> json_response(201)
      user = Accounts.get_user_by_email("soft@softdeprov.com")
      {:ok, session} = Accounts.create_user_session_token(user)

      body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
        })

      resp = scim(token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(200)
      assert resp["active"] == false

      assert is_nil(Accounts.verify_user_session_token(session))

      refute Repo.exists?(
               from m in Membership,
                 where: m.principal_id == ^user.id and m.workspace_id == ^ws.id
             )

      # soft: the user row survives
      assert Accounts.get_user(user.id)
    end
  end

  describe "organization isolation" do
    test "a token for org B cannot see or deprovision org A's user" do
      %{token: token_a} = org_with_ws("org-a")
      %{token: token_b} = org_with_ws("org-b")
      provision(token_a, "insidea@org-a.com") |> json_response(201)
      user = Accounts.get_user_by_email("insidea@org-a.com")

      # B cannot GET A's user
      assert scim(token_b) |> get("/scim/v2/Users/#{user.id}") |> json_response(404)
      # B cannot DELETE A's user
      assert scim(token_b) |> delete("/scim/v2/Users/#{user.id}") |> json_response(404)
      # A still can
      assert scim(token_a) |> get("/scim/v2/Users/#{user.id}") |> json_response(200)
    end
  end

  describe "auth + listing" do
    test "401 without a valid SCIM token" do
      assert build_conn() |> get("/scim/v2/Users") |> json_response(401)

      assert build_conn()
             |> put_req_header("authorization", "Bearer not-a-real-token")
             |> get("/scim/v2/Users")
             |> json_response(401)
    end

    test "GET /Users?filter=userName eq lists the matching provisioned user" do
      %{token: token} = org_with_ws("listco")
      provision(token, "list@listco.com") |> json_response(201)

      resp =
        scim(token)
        |> get(~s(/scim/v2/Users?filter=userName eq "list@listco.com"))
        |> json_response(200)

      assert resp["totalResults"] == 1
      assert [%{"userName" => "list@listco.com"}] = resp["Resources"]
    end
  end
end
