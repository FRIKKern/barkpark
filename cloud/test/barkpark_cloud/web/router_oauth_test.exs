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

  # cch-w2 — the side-effecting-GET fence (router.ex `refuse_head_on_side_effecting_gets`).
  #
  # Before the fence, `plug(Plug.Head)` rewrote HEAD→GET for the whole router, so
  # a HEAD ran the callback's ENTIRE with-chain: consume the nonce, fetch the
  # identity, create the user, mint a session token, and hand that live token
  # back in the `location` header. Measured over a real Bandit socket, not
  # inferred — the adapter suppresses the BODY on HEAD, never the headers. Any
  # unfurler, link-preview service, AV link scanner or TLS-terminating proxy that
  # touched a callback URL both TOOK the session and BURNED the nonce, so the
  # legitimate user's own click then failed to /#oauth_error=oauth_failed.
  #
  # These tests are written so each FAILS against the pre-fix router: without the
  # plug the callback answers 302 (not 405) with `#oauth=<token>` in `location`,
  # the initiator inserts its oauth_states row, and the nonce is gone by the time
  # the real GET arrives.
  describe "HEAD is refused on the side-effecting OAuth GETs" do
    test "HEAD /callback is 405 + `allow: GET` with NO location header and NO token" do
      state = OAuth.mint_state("github")
      conn = call(:head, "/v1/auth/oauth/github/callback?code=abc&state=#{state}")

      assert conn.status == 405
      # The adapter drops the body on HEAD (that is the whole point of HEAD), so
      # the JSON error shape is unobservable here by design — the STATUS and the
      # `allow` header are the entire answer a prober gets.
      assert conn.resp_body == ""

      # 405 + allow, never 404 (D12): the path exists, the METHOD is refused.
      # 404 is the exact lie plug(Plug.Head) was landed to remove.
      assert get_resp_header(conn, "allow") == ["GET"]

      # The leak itself: no redirect at all, so nothing to carry a token.
      assert get_resp_header(conn, "location") == []
      refute conn.resp_body =~ "oauth="

      # And nothing was minted behind it.
      assert Repo.aggregate(User, :count) == 0
    end

    test "HEAD on the initiator is refused and writes NO oauth_states row" do
      before = Repo.aggregate(OAuth.State, :count)

      conn = call(:head, "/v1/auth/oauth/github")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET"]
      assert get_resp_header(conn, "location") == []

      # The initiator Repo.insert!s one row per hit on an UNAUTHENTICATED route
      # (mint_state, one call deep in OAuth.authorize_url) — that is the growth
      # vector, and a refused HEAD must not feed it.
      assert Repo.aggregate(OAuth.State, :count) == before

      # Control: the GET this fence deliberately leaves alone DOES write one.
      assert call(:get, "/v1/auth/oauth/github").status == 302
      assert Repo.aggregate(OAuth.State, :count) == before + 1
    end

    test "a refused HEAD does NOT consume the nonce — the legitimate GET still works" do
      # The availability half. verify_state/2 consumes the nonce with an atomic
      # delete_all, so pre-fix an unfurler's HEAD burned the user's own state.
      state = OAuth.mint_state("github")

      assert call(:head, "/v1/auth/oauth/github/callback?code=abc&state=#{state}").status == 405

      conn = call(:get, "/v1/auth/oauth/github/callback?code=abc&state=#{state}")
      assert conn.status == 302
      loc = location(conn)
      assert loc =~ "#oauth="
      refute loc =~ "oauth_error"
      assert %User{} = Accounts.verify_user_session_token(token_from(loc))
    end

    test "the fence is HEAD-only — GET on both routes is untouched" do
      # Guards the obvious vacuous-green inversion: a plug that 405'd everything
      # would pass every assertion above while breaking sign-in entirely.
      assert call(:get, "/v1/auth/oauth/github").status == 302

      state = OAuth.mint_state("github")
      assert call(:get, "/v1/auth/oauth/github/callback?code=abc&state=#{state}").status == 302
    end

    test "HEAD /v1/auth/oauth/providers still mirrors its GET (the D14 trap)" do
      # `providers` has the SAME segment arity as the initiator and is matched by
      # `get "/v1/auth/oauth/:provider"`'s pattern — but it is declared first and
      # is a pure READ. A segment-list guard that forgot to exclude it, or any
      # String.starts_with?("/v1/auth/oauth") prefix guard, would 405 this.
      get = call(:get, "/v1/auth/oauth/providers")
      head = call(:head, "/v1/auth/oauth/providers")

      assert get.status == 200
      assert head.status == 200
      assert head.resp_body == ""
      assert get_resp_header(head, "allow") == []
    end
  end

  describe "OAuth.reap_expired_states/0" do
    test "deletes lapsed rows, keeps live ones, and is idempotent" do
      OAuth.mint_state("github")
      OAuth.mint_state("google")

      # Backdate ONE row past its TTL. No grace window: consume_state's own guard
      # is `expires_at > now`, so this row is already unredeemable — the reaper
      # deletes exactly what the redemption path has already written off.
      lapsed = Repo.one!(from(s in OAuth.State, where: s.provider == "github"))

      Repo.update_all(
        from(s in OAuth.State, where: s.id == ^lapsed.id),
        set: [
          expires_at:
            DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
        ]
      )

      assert %{reaped: 1} = OAuth.reap_expired_states()
      assert Repo.aggregate(OAuth.State, :count) == 1
      assert Repo.one!(OAuth.State).provider == "google"

      # A sweep that finds nothing is a no-op, never a raise.
      assert %{reaped: 0} = OAuth.reap_expired_states()
      assert Repo.aggregate(OAuth.State, :count) == 1
    end
  end

  defp token_from(location) do
    [_, frag] = String.split(location, "#", parts: 2)
    URI.decode_query(frag)["oauth"]
  end
end
