defmodule BarkparkCloud.Web.RouterSiteEnvWriteAdminTest do
  @moduledoc """
  task-49f9a3dbb16823ce, under the owner ruling on task-9dfa4854b5e22e94:

      POST   /v1/sites/:id/env   admin   — replace the encrypted env blob

  The blob this route replaces IS the secret set injected into the site's build
  (`GET /v1/builder/sites/:id/env`) and into its running container
  (`GET /v1/agent/sites/:id/env`), and the write is a whole-blob REPLACE — so
  before the ruling a plain team MEMBER, holding nothing but membership, could
  erase every secret of every site the team owned in one call.

  What this file pins, and nothing wider:

  * a plain MEMBER session → 403 in the `Auth.forbidden` shape
    (`required: "admin"`, `scope: "team"`) AND the stored blob is byte-identical
    afterwards — the status alone would still pass if the write had landed
    before the guard;
  * a team ADMIN session → 200 and the blob actually changes.

  It does NOT re-adjudicate REPLACE-vs-merge: `{"env": {}}` still wipes, and the
  admin arm below asserts exactly that, because the ruling gates WHO may call
  the route, not what the call does.

  Mutation-proved: with the route body reverted to the 2-arity
  `with_team_site(conn, fn conn, site -> …)` (the `:session` arm) the member
  tests below red.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  @env %{"DATABASE_URL" => "postgres://u:p@h/db", "STRIPE_KEY" => "sk-live-secret"}

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    user
  end

  defp token(user) do
    {:ok, t} = Accounts.create_user_session_token(user)
    t
  end

  defp post_env(site, user, env) do
    conn(:post, "/v1/sites/#{site.id}/env", Jason.encode!(%{env: env}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token(user)}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp stored_env(site) do
    {:ok, env} = site.id |> reload_site() |> Registry.reveal_site_env()
    env
  end

  defp reload_site(site_id), do: BarkparkCloud.Repo.get!(Registry.Site, site_id)

  setup do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    {:ok, _} = Registry.set_site_env(site, @env)

    %{
      team: team,
      site: site,
      member: member_of(team, "member"),
      admin: member_of(team, "admin"),
      owner: member_of(team, "owner")
    }
  end

  describe "POST /v1/sites/:id/env" do
    test "a plain MEMBER is refused, the missing authority is named, and the blob is untouched",
         %{site: site, member: member} do
      conn = post_env(site, member, %{"DATABASE_URL" => "postgres://attacker/db"})

      assert conn.status == 403
      assert %{"error" => "forbidden", "required" => "admin", "scope" => "team"} = body(conn)

      # The load-bearing half: a 403 that arrives AFTER the write would still
      # satisfy the status assertion above.
      assert stored_env(site) == @env
    end

    test "a plain MEMBER cannot WIPE the blob either ({\"env\": {}} is the destructive call)",
         %{site: site, member: member} do
      conn = post_env(site, member, %{})

      assert conn.status == 403
      assert stored_env(site) == @env
    end

    test "a team ADMIN still writes, and the blob changes", %{site: site, admin: admin} do
      new_env = %{"DATABASE_URL" => "postgres://u:p@h/db2", "NEW_KEY" => "v"}

      conn = post_env(site, admin, new_env)

      assert conn.status == 200
      assert body(conn) == %{"ok" => true}
      assert stored_env(site) == new_env
    end

    test "a team OWNER writes too (the tier is admin-OR-owner, not admin-only)",
         %{site: site, owner: owner} do
      conn = post_env(site, owner, %{"OWNER_KEY" => "v"})

      assert conn.status == 200
      assert stored_env(site) == %{"OWNER_KEY" => "v"}
    end

    test "REPLACE semantics are UNCHANGED by the tier: an admin sending {} still wipes",
         %{site: site, admin: admin} do
      conn = post_env(site, admin, %{})

      assert conn.status == 200
      assert stored_env(site) == %{}
    end
  end
end
