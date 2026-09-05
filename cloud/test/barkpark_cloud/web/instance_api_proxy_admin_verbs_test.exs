defmodule BarkparkCloud.Web.InstanceApiProxyAdminVerbsTest do
  @moduledoc """
  task-a0f4f8757ba28e76, ruled ARM B: of the nine instance-webhook proxy routes,
  exactly TWO are credential verbs and gate at team admin — `rotate` (mints a
  new signing secret) and `deliveries` (returns payload bodies). The other
  seven stay member-tier beside site CRUD.

  One driven test per gated route, from a plain MEMBER (403 naming the missing
  authority, ZERO upstream calls) and from an ADMIN (relayed exactly as before).
  Plus the two invariants the change must not disturb: cross-team is still 404
  for an admin (object authz, cch-idor-s2), and a member still reaches the list
  verb (the seven are untouched).

  async: false — shares the fake HTTP client's process-wide programme.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext-A0F4"
  @instance_url "https://prod.barkpark.cloud"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    user
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp token(user) do
    {:ok, t} = Accounts.create_user_session_token(user)
    t
  end

  defp call(method, path, user) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token(user)}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  setup do
    team = team_fixture()
    bp = live_barkpark(team)
    %{team: team, bp: bp, member: member_of(team, "member"), admin: member_of(team, "admin")}
  end

  describe "POST …/webhooks/:webhook_id/rotate — a credential verb" do
    test "a plain MEMBER is refused with the missing authority named, and nothing reaches the instance",
         %{bp: bp, member: member} do
      Fake.program([])
      conn = call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", member)

      assert conn.status == 403
      assert %{"error" => "forbidden", "required" => "admin", "scope" => "team"} = body(conn)
      assert Fake.requests() == []
    end

    test "a team ADMIN still rotates through the relay", %{bp: bp, admin: admin} do
      Fake.program([{:ok, %{status: 200, body: ~s({"secret":"whsec_new"})}}])
      conn = call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", admin)

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9/rotate"
    end
  end

  describe "GET …/webhooks/:webhook_id/deliveries — payload bodies" do
    test "a plain MEMBER is refused with the missing authority named, and nothing reaches the instance",
         %{bp: bp, member: member} do
      Fake.program([])
      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries", member)

      assert conn.status == 403
      assert %{"error" => "forbidden", "required" => "admin", "scope" => "team"} = body(conn)
      assert Fake.requests() == []
    end

    test "a team ADMIN still reads the delivery log through the relay", %{bp: bp, admin: admin} do
      Fake.program([{:ok, %{status: 200, body: ~s({"deliveries":[]})}}])
      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries", admin)

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9/deliveries"
    end
  end

  describe "what the ruling does NOT change" do
    test "cross-team is still 404 for an ADMIN of another team (object authz stays first-class)",
         %{bp: bp} do
      other_admin = member_of(team_fixture(), "admin")
      Fake.program([])
      conn = call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", other_admin)

      assert conn.status == 404
      assert Fake.requests() == []
    end

    test "a plain MEMBER still reaches the list verb — the seven CRUD verbs stay member-tier",
         %{bp: bp, member: member} do
      Fake.program([{:ok, %{status: 200, body: ~s({"webhooks":[]})}}])
      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", member)

      assert conn.status == 200
      assert [_req] = Fake.requests()
    end
  end
end
