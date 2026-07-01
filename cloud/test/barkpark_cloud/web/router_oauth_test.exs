defmodule BarkparkCloud.Web.RouterOAuthTest do
  @moduledoc """
  Route-level tests for the OAuth/SSO endpoints (oauth-sso), driven directly via
  Plug.Test (no live socket), mirroring router_test.exs. The token-exchange +
  userinfo legs run through BarkparkCloud.OAuthStub — hermetic, €0.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, OAuth}
  alias BarkparkCloud.Accounts.User
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp call(method, path) do
    Router.call(conn(method, path), @opts)
  end

  defp location(conn), do: get_resp_header(conn, "location") |> List.first()

  describe "GET /v1/auth/oauth/providers" do
    test "lists the enabled providers for the SPA" do
      conn = call(:get, "/v1/auth/oauth/providers")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"providers" => ["github", "google"]}
    end
  end

  describe "GET /v1/auth/oauth/:provider" do
    test "302s to the GitHub authorize URL carrying a state" do
      conn = call(:get, "/v1/auth/oauth/github")
      assert conn.status == 302
      loc = location(conn)
      assert String.starts_with?(loc, "https://github.com/login/oauth/authorize?")
      assert loc =~ "state="
      assert loc =~ "client_id=gh_test_client_id"
    end

    test "an unknown / disabled provider is a 404" do
      conn = call(:get, "/v1/auth/oauth/gitlab")
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "provider_not_enabled"
    end
  end

  describe "GET /v1/auth/oauth/:provider/callback" do
    test "a valid code + state mints a session and 302s with the token on the FRAGMENT" do
      state = OAuth.mint_state("github")
      conn = call(:get, "/v1/auth/oauth/github/callback?code=abc&state=#{state}")

      assert conn.status == 302
      loc = location(conn)
      # Token rides the fragment (#oauth=…), never the query string.
      assert [_, frag] = String.split(loc, "#", parts: 2)
      assert %{"oauth" => token, "team" => team_id} = URI.decode_query(frag)
      assert is_binary(token) and token != ""

      # The token actually authenticates the just-created user.
      assert %User{} = user = Accounts.verify_user_session_token(token)
      # GitHub's stub primary email is the user's email.
      assert user.email == "octocat@example.com"
      # The team on the fragment is the user's primary team.
      assert Accounts.primary_team(user).id == team_id
    end

    test "a bad/expired state 302s to the generic error and creates NO user or token" do
      before = Repo.aggregate(User, :count)
      conn = call(:get, "/v1/auth/oauth/github/callback?code=abc&state=tampered.deadbeef")

      assert conn.status == 302
      assert location(conn) == "/#oauth_error=oauth_failed"
      # Nothing was created on the failure path.
      assert Repo.aggregate(User, :count) == before
    end

    test "a missing code 302s to the generic error" do
      state = OAuth.mint_state("github")
      conn = call(:get, "/v1/auth/oauth/github/callback?state=#{state}")
      assert conn.status == 302
      assert location(conn) == "/#oauth_error=oauth_failed"
    end

    test "a callback for a disabled provider 302s to the generic error (no leak)" do
      conn = call(:get, "/v1/auth/oauth/gitlab/callback?code=abc&state=whatever")
      assert conn.status == 302
      assert location(conn) == "/#oauth_error=oauth_failed"
    end

    test "a REPLAYED state (same state string used twice) is rejected on the second callback" do
      state = OAuth.mint_state("github")

      # First redemption succeeds and lands a session on the fragment.
      c1 = call(:get, "/v1/auth/oauth/github/callback?code=a&state=#{state}")
      assert c1.status == 302
      assert location(c1) =~ "#oauth="

      users_after_first = Repo.aggregate(User, :count)

      # Replaying the EXACT same state must be rejected (single-use ledger
      # consumed the nonce) — no second session, no second/duplicate user.
      c2 = call(:get, "/v1/auth/oauth/github/callback?code=b&state=#{state}")
      assert c2.status == 302
      assert location(c2) == "/#oauth_error=oauth_failed"
      assert Repo.aggregate(User, :count) == users_after_first
    end

    test "an IdP ?error=access_denied 302s to the generic error, no crash, no user" do
      before = Repo.aggregate(User, :count)
      conn = call(:get, "/v1/auth/oauth/github/callback?error=access_denied")
      assert conn.status == 302
      assert location(conn) == "/#oauth_error=oauth_failed"
      assert Repo.aggregate(User, :count) == before
    end

    test "a token-exchange failure 302s to the generic error and creates NO user" do
      # The stub returns a token body with NO access_token → exchange fails.
      BarkparkCloud.OAuthStub.put_response(:github_token, %{})
      before = Repo.aggregate(User, :count)

      state = OAuth.mint_state("github")
      conn = call(:get, "/v1/auth/oauth/github/callback?code=abc&state=#{state}")
      assert conn.status == 302
      assert location(conn) == "/#oauth_error=oauth_failed"
      assert Repo.aggregate(User, :count) == before
    end

    test "the same identity through the callback twice returns the same user (idempotent sign-in)" do
      s1 = OAuth.mint_state("github")
      c1 = call(:get, "/v1/auth/oauth/github/callback?code=a&state=#{s1}")
      t1 = c1 |> location() |> token_from()
      u1 = Accounts.verify_user_session_token(t1)

      s2 = OAuth.mint_state("github")
      c2 = call(:get, "/v1/auth/oauth/github/callback?code=b&state=#{s2}")
      t2 = c2 |> location() |> token_from()
      u2 = Accounts.verify_user_session_token(t2)

      assert u1.id == u2.id
      assert Repo.aggregate(User, :count) == 1
    end
  end

  defp token_from(location) do
    [_, frag] = String.split(location, "#", parts: 2)
    URI.decode_query(frag)["oauth"]
  end
end
