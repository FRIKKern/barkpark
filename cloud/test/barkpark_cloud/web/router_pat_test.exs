defmodule BarkparkCloud.Web.RouterPatTest do
  @moduledoc """
  Drives the Personal-Access-Token surface of the cloud-12a JSON API via
  Plug.Test: the session-only management routes (`GET/POST/DELETE /v1/tokens`)
  and PAT-authed access to selected `/v1/*` routes through the
  `require_user_or_pat` + `require_ability` pair. Mirrors RouterTest's
  DataCase + Plug.Test setup.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # A user who belongs to a fresh team + a live session token. Returns
  # {user, team, session_token}.
  defp logged_in do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, team, session}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Site #{n}", slug: "site-#{n}"})
    site
  end

  ## Request helper

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  ## Management routes (session-only)

  describe "POST /v1/tokens" do
    test "mints a PAT, returns the plaintext once, never the hash" do
      {_user, _team, session} = logged_in()

      conn = call(:post, "/v1/tokens", %{name: "ci-key", abilities: ["read"]}, session)
      assert conn.status == 201
      body = decode(conn)

      assert String.starts_with?(body["token"], "bpc_pat_")
      assert body["pat"]["name"] == "ci-key"
      assert body["pat"]["abilities"] == ["read"]
      refute Map.has_key?(body["pat"], "token_hash")
      # The plaintext is not echoed inside the pat object.
      refute body["pat"]["token"]
    end

    test "403 no_team when the user has no team — the gate shape, not a 422" do
      user = user_fixture()
      {:ok, session} = Accounts.create_user_session_token(user)

      # cch-w40-bl: minting a PAT resolves its team inline (bare require_user),
      # and its refusal used to be `422 {"error":"no_team"}` — the status that
      # says "your body was unprocessable" handed to a caller whose body was
      # fine and who simply holds no grant. It now speaks the same shape
      # Auth.gate_role/4 has emitted since cch-w38-s2.
      conn = call(:post, "/v1/tokens", %{name: "ci-key"}, session)
      assert conn.status == 403

      assert decode(conn) == %{
               "error" => "forbidden",
               "reason" => "no_team",
               "scope" => "team"
             }
    end

    test "422 invalid for a too-short name" do
      {_u, _t, session} = logged_in()
      conn = call(:post, "/v1/tokens", %{name: "ab"}, session)
      assert conn.status == 422
      assert decode(conn)["error"] == "invalid"
    end

    test "401 when authenticated with a PAT (management is session-only)" do
      {user, team, _session} = logged_in()

      {:ok, pat_plaintext, _pat} =
        Accounts.create_personal_access_token(user, team, %{name: "self", abilities: ["root"]})

      conn = call(:post, "/v1/tokens", %{name: "escalate", abilities: ["root"]}, pat_plaintext)
      assert conn.status == 401
    end

    test "M8: a plain member may mint a read PAT but NOT a deploy/root one" do
      {_owner, team, _} = logged_in()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, member_session} = Accounts.create_user_session_token(member)

      # read → 201
      ok = call(:post, "/v1/tokens", %{name: "ro-key", abilities: ["read"]}, member_session)
      assert ok.status == 201

      # deploy → 403
      assert call(:post, "/v1/tokens", %{name: "dep-key", abilities: ["deploy"]}, member_session).status ==
               403

      # root → 403 forbidden
      denied = call(:post, "/v1/tokens", %{name: "root-key", abilities: ["root"]}, member_session)
      assert denied.status == 403
      assert decode(denied)["error"] == "forbidden"
    end
  end

  describe "GET /v1/tokens" do
    test "lists the caller's PATs newest-first, never the hash" do
      {user, team, session} = logged_in()
      {:ok, _p, _a} = Accounts.create_personal_access_token(user, team, %{name: "alpha"})
      {:ok, _p2, _b} = Accounts.create_personal_access_token(user, team, %{name: "beta"})

      conn = call(:get, "/v1/tokens", nil, session)
      assert conn.status == 200
      tokens = decode(conn)["tokens"]
      assert length(tokens) == 2
      assert hd(tokens)["name"] == "beta"
      refute Map.has_key?(hd(tokens), "token_hash")
    end
  end

  describe "DELETE /v1/tokens/:id" do
    test "revokes the caller's own token" do
      {user, team, session} = logged_in()
      {:ok, _p, pat} = Accounts.create_personal_access_token(user, team, %{name: "doomed"})

      conn = call(:delete, "/v1/tokens/#{pat.id}", nil, session)
      assert conn.status == 200
      assert decode(conn)["ok"] == true
    end

    test "404 for another user's token (no existence leak)" do
      {_owner, team, _s} = logged_in()

      {:ok, _p, pat} =
        Accounts.create_personal_access_token(user_fixture(), team, %{name: "theirs"})

      {_other, _team2, other_session} = logged_in()
      conn = call(:delete, "/v1/tokens/#{pat.id}", nil, other_session)
      assert conn.status == 404
    end

    test "404 for a non-UUID token id (not a 500 CastError)" do
      {_user, _team, session} = logged_in()
      conn = call(:delete, "/v1/tokens/not-a-uuid", nil, session)
      assert conn.status == 404
    end
  end

  ## PAT-authed access via require_ability

  describe "ability gating on /v1/* routes" do
    test "a read PAT can GET /v1/barkparks" do
      {user, team, _session} = logged_in()

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ro-key", abilities: ["read"]})

      conn = call(:get, "/v1/barkparks", nil, read_token)
      assert conn.status == 200
      assert is_list(decode(conn)["barkparks"])
    end

    test "a write PAT can deploy a site; a read PAT is 403'd" do
      {user, team, _session} = logged_in()
      site = site_fixture(team)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "rw-key", abilities: ["write"]})

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ro-key", abilities: ["read"]})

      ok =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{artifact_url: "file:///tmp/a.tar.gz"},
          write_token
        )

      assert ok.status == 201

      denied = call(:post, "/v1/sites/#{site.id}/deploy", %{}, read_token)
      assert denied.status == 403
      assert decode(denied)["error"] == "forbidden"
    end

    test "a root PAT passes every ability gate" do
      {user, team, _session} = logged_in()
      site = site_fixture(team)

      {:ok, root_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "root", abilities: ["root"]})

      assert call(:get, "/v1/barkparks", nil, root_token).status == 200

      assert call(
               :post,
               "/v1/sites/#{site.id}/deploy",
               %{artifact_url: "file:///tmp/a.tar.gz"},
               root_token
             ).status == 201
    end

    test "a session token still works on the PAT-opted read routes" do
      {_u, _t, session} = logged_in()
      conn = call(:get, "/v1/me", nil, session)
      assert conn.status == 200
    end

    test "a revoked PAT no longer authenticates" do
      {user, team, _session} = logged_in()

      {:ok, token, pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "soon-dead",
          abilities: ["read"]
        })

      assert call(:get, "/v1/barkparks", nil, token).status == 200
      {:ok, _} = Accounts.revoke_personal_access_token(user, pat.id)
      assert call(:get, "/v1/barkparks", nil, token).status == 401
    end

    test "B2: a deploy PAT can go-live, but a read PAT is 403'd" do
      {user, team, _session} = logged_in()
      {:ok, _sub} = BarkparkCloud.Billing.subscribe(team, "supporter")

      {:ok, deploy_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "deploy-key",
          abilities: ["deploy"]
        })

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "read-key",
          abilities: ["read"]
        })

      assert call(:post, "/v1/go-live", %{name: "PAT Box"}, deploy_token).status == 201

      denied = call(:post, "/v1/go-live", %{name: "Nope Box"}, read_token)
      assert denied.status == 403
      assert decode(denied)["error"] == "forbidden"
    end

    test "B4: sign-out-everywhere does NOT revoke the user's PATs" do
      {user, team, session} = logged_in()

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "survivor-key",
          abilities: ["read"]
        })

      # The PAT works before the session kill-switch.
      assert call(:get, "/v1/barkparks", nil, read_token).status == 200

      # Sign out everywhere.
      assert call(:delete, "/v1/account/sessions", nil, session).status == 200

      # The PAT still authenticates — sessions died, the PAT did not.
      assert call(:get, "/v1/barkparks", nil, read_token).status == 200
    end
  end

  ## Membership changes end the team-scoped credential (cch-w30-s6)

  describe "membership changes and team-scoped PATs" do
    # An owner + a second user holding `role` on the same team, with a session
    # for the owner and a main Barkpark to hang supports off.
    # Returns {owner_session, team, other_user, main_barkpark}.
    defp team_with_second_member(role) do
      {_owner, team, owner_session} = logged_in()
      other = user_fixture()
      {:ok, _} = Accounts.add_member(team, other, role)

      {:ok, main} =
        Registry.register_barkpark(team, %{
          name: "Main",
          slug: "main-#{System.unique_integer([:positive])}"
        })

      {owner_session, team, other, main}
    end

    defp register_support(token, main) do
      call(
        :post,
        "/v1/fleet/supports",
        %{name: "Support #{System.unique_integer([:positive])}", parent_id: main.id},
        token
      )
    end

    test "REMOVAL kills the ex-member's team PAT on read AND write routes" do
      {owner_session, team, other, main} = team_with_second_member("admin")

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(other, team, %{name: "ro-key", abilities: ["read"]})

      {:ok, deploy_token, _} =
        Accounts.create_personal_access_token(other, team, %{
          name: "deploy-key",
          abilities: ["deploy"]
        })

      # Both credentials work while the membership stands.
      assert call(:get, "/v1/barkparks", nil, read_token).status == 200
      assert register_support(deploy_token, main).status == 201

      removed =
        call(:delete, "/v1/teams/#{team.id}/members/#{other.id}", nil, owner_session)

      assert removed.status == 200
      assert Accounts.team_role(other, team) == nil

      # The modal's promise — "Ends <email>'s access to the team immediately" —
      # is now true of the programmatic surface too. 401, not 403: the
      # credential itself is revoked, not merely under-powered.
      assert call(:get, "/v1/barkparks", nil, read_token).status == 401
      assert register_support(deploy_token, main).status == 401
    end

    test "DEMOTION kills the elevated PAT but KEEPS the read PAT a member may still hold" do
      {owner_session, team, other, main} = team_with_second_member("admin")

      {:ok, deploy_token, _} =
        Accounts.create_personal_access_token(other, team, %{
          name: "deploy-key",
          abilities: ["deploy"]
        })

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(other, team, %{name: "ro-key", abilities: ["read"]})

      assert register_support(deploy_token, main).status == 201
      assert call(:get, "/v1/barkparks", nil, read_token).status == 200

      demoted =
        call(
          :patch,
          "/v1/teams/#{team.id}/members/#{other.id}",
          %{role: "member"},
          owner_session
        )

      assert demoted.status == 200
      assert decode(demoted)["member"]["role"] == "member"

      # The grant they could no longer MINT is gone…
      assert {:error, :forbidden} =
               Accounts.create_personal_access_token(other, team, %{
                 name: "re-mint",
                 abilities: ["deploy"]
               })

      assert register_support(deploy_token, main).status == 401

      # …and the read PAT a plain member IS entitled to hold still works.
      # Over-revocation here would be a new defect, not a stricter fix.
      assert call(:get, "/v1/barkparks", nil, read_token).status == 200
    end

    test "the revoke is TEAM-SCOPED: a PAT on another team survives the removal" do
      {owner_session, team, other, main} = team_with_second_member("admin")

      other_team = team_fixture()
      {:ok, _} = Accounts.add_member(other_team, other, "admin")

      {:ok, elsewhere_main} =
        Registry.register_barkpark(other_team, %{
          name: "Elsewhere",
          slug: "elsewhere-#{System.unique_integer([:positive])}"
        })

      {:ok, here_token, _} =
        Accounts.create_personal_access_token(other, team, %{
          name: "here",
          abilities: ["deploy"]
        })

      {:ok, elsewhere_token, _} =
        Accounts.create_personal_access_token(other, other_team, %{
          name: "elsewhere",
          abilities: ["deploy"]
        })

      assert call(:delete, "/v1/teams/#{team.id}/members/#{other.id}", nil, owner_session).status ==
               200

      # The team they left is closed…
      assert register_support(here_token, main).status == 401

      # …the team they still belong to is untouched. Dropping the `team_id`
      # clause from the revoke turns this 201 into a 401 — cross-tenant blast
      # radius, the defect this scoping exists to avoid.
      assert register_support(elsewhere_token, elsewhere_main).status == 201
    end
  end
end
