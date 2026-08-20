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
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp call(method, path) do
    Router.call(conn(method, path), @opts)
  end

  defp post_json(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp location(conn), do: get_resp_header(conn, "location") |> List.first()

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Walk the callback all the way to a redeemable exchange code.
  defp callback_code(provider) do
    state = OAuth.mint_state(provider)
    conn = call(:get, "/v1/auth/oauth/#{provider}/callback?code=abc&state=#{state}")
    assert conn.status == 302
    code_from(location(conn))
  end

  # Redeem a code the way the SPA does, and hand back the session token.
  defp exchange!(code) do
    conn = post_json("/v1/auth/oauth/exchange", %{code: code})
    assert conn.status == 200
    json_body(conn)["token"]
  end

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
    # cch-w10 — THE HEADER LEAK. This test used to assert the OPPOSITE of what it
    # asserts now, and the inversion is the whole slice.
    #
    # WHAT IT DOES NOT PROVE: this is a Plug-level capture (get_resp_header/2 on
    # the conn Router.call/2 returns), NOT a raw-wire capture of the 302 as it
    # leaves a socket. `cloud/test` has no raw-socket client harness — `:gen_tcp`
    # appears only in a port probe and a mock upstream server — so a "raw wire"
    # claim here would be manufactured evidence. What IS proven is the property
    # that matters: the value put into the `location` response header is not a
    # credential, with a POSITIVE CONTROL so "not a credential" cannot pass
    # vacuously.
    test "the 302's `location` header carries a ONE-TIME CODE, never a live session token" do
      state = OAuth.mint_state("github")
      conn = call(:get, "/v1/auth/oauth/github/callback?code=abc&state=#{state}")

      assert conn.status == 302

      # The capture, stated plainly: the exact bytes of the response header.
      assert [loc] = get_resp_header(conn, "location")
      assert [_, frag] = String.split(loc, "#", parts: 2)
      assert %{"oauth_code" => code, "team" => team_id} = URI.decode_query(frag)
      assert is_binary(code) and code != ""

      # THE NEGATIVE: the thing in the header is REJECTED by the session verifier.
      # Before cch-w10 this same expression returned a live 30-day %User{}.
      refute Accounts.verify_user_session_token(code)

      # And the OLD key is gone from the header entirely — a client that still
      # reads `oauth=` finds nothing rather than a token. (`"#oauth="` is NOT a
      # substring of `"#oauth_code="`, so this is a real assertion.)
      refute URI.decode_query(frag)["oauth"]
      refute loc =~ "#oauth="

      # THE POSITIVE CONTROL: the very same function DOES accept what the exchange
      # hands back, so the negative above is about the VALUE, not about a broken
      # verifier or a broken sign-in.
      token = exchange!(code)
      assert %User{} = user = Accounts.verify_user_session_token(token)
      refute token == code

      # GitHub's stub primary email is the user's email.
      assert user.email == "octocat@example.com"
      # The team on the fragment is the user's primary team.
      assert Accounts.primary_team(user).id == team_id

      assert json_body(post_json("/v1/auth/oauth/exchange", %{code: code}))["error"] ==
               "invalid_code"
    end

    test "the code is hashed at rest and carries the provider for the session's origin" do
      code = callback_code("github")

      assert [%UserToken{context: "oauth_exchange"} = row] =
               Repo.all(from(t in UserToken, where: t.context == "oauth_exchange"))

      # Only a SHA-256 hash is stored — the plaintext is unrecoverable from a DB
      # dump, exactly like every other credential on this table.
      assert row.token_hash == UserToken.hash_token(code)
      refute row.token_hash == code
      assert row.revoked_at == nil

      # `sent_to` is how "which provider authenticated this human" survives the
      # mint moving off the callback. The session the exchange mints must still
      # carry the honest per-provider origin, not a generic "oauth".
      assert row.sent_to == "oauth:github"

      token = exchange!(code)
      user = Accounts.verify_user_session_token(token)

      assert [%UserToken{origin: "oauth:github"}] =
               Repo.all(
                 from(t in UserToken, where: t.user_id == ^user.id and t.context == "session")
               )
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
      assert location(c1) =~ "#oauth_code="

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
      t1 = c1 |> location() |> code_from() |> exchange!()
      u1 = Accounts.verify_user_session_token(t1)

      s2 = OAuth.mint_state("github")
      c2 = call(:get, "/v1/auth/oauth/github/callback?code=b&state=#{s2}")
      t2 = c2 |> location() |> code_from() |> exchange!()
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
      assert loc =~ "#oauth_code="
      refute loc =~ "oauth_error"
      # Availability, end to end: the code the legitimate GET got still redeems.
      assert %User{} = Accounts.verify_user_session_token(exchange!(code_from(loc)))
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

  # cch-w10 — the exchange leg. The callback's `location` header is the ONE place
  # a live credential used to be observable off-wire; these pin that what replaced
  # it is worth nothing twice, nothing late, and nothing to a HEAD prober.
  describe "POST /v1/auth/oauth/exchange" do
    test "trades the one-time code for a session token bound to the SPA's own request" do
      code = callback_code("github")

      conn =
        conn(:post, "/v1/auth/oauth/exchange", Jason.encode!(%{code: code}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("user-agent", "SpaBrowser/1.0")
        |> Router.call(@opts)

      assert conn.status == 200
      body = json_body(conn)
      assert %User{} = user = Accounts.verify_user_session_token(body["token"])
      assert body["team_id"] == Accounts.primary_team(user).id

      # BEHAVIOUR CHANGE, pinned so it is a decision rather than a drift: the
      # session's device metadata is now the BROWSER's own request, not the IdP
      # redirect hop's. The sessions security panel gets the more useful of the two.
      assert [%UserToken{user_agent: "SpaBrowser/1.0"}] =
               Repo.all(
                 from(t in UserToken, where: t.user_id == ^user.id and t.context == "session")
               )
    end

    test "is SINGLE-USE: a replayed code is 401 and mints nothing" do
      code = callback_code("github")
      token = exchange!(code)
      user = Accounts.verify_user_session_token(token)
      sessions_after_first = session_count(user)

      replay = post_json("/v1/auth/oauth/exchange", %{code: code})
      assert replay.status == 401
      assert json_body(replay)["error"] == "invalid_code"

      # The burn is the point: no second session off the same code.
      assert session_count(user) == sessions_after_first
    end

    test "an EXPIRED code is 401 and mints nothing" do
      code = callback_code("github")

      # Backdate past the 120s TTL. No grace window — consume's own guard is
      # `expires_at > now`, so this row is already unredeemable.
      {1, _} =
        Repo.update_all(
          from(t in UserToken,
            where: t.context == "oauth_exchange" and t.token_hash == ^UserToken.hash_token(code)
          ),
          set: [
            expires_at:
              DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
          ]
        )

      conn = post_json("/v1/auth/oauth/exchange", %{code: code})
      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_code"
      assert Repo.aggregate(from(t in UserToken, where: t.context == "session"), :count) == 0
    end

    test "unknown / malformed / missing codes all collapse to the SAME generic 401" do
      # A prober must not be able to tell "no such code" from "burned" from
      # "expired" — the exchange mirrors the callback's single generic failure.
      for body <- [%{code: "not-a-real-code"}, %{code: ""}, %{code: 42}, %{}] do
        conn = post_json("/v1/auth/oauth/exchange", body)
        assert conn.status == 401
        assert json_body(conn)["error"] == "invalid_code"
      end
    end

    test "a code minted for one provider still yields THAT provider's origin" do
      # google, not github: the origin must follow `sent_to`, not a hardcoded
      # default that happens to be right for the provider the other tests use.
      code = callback_code("google")
      user = Accounts.verify_user_session_token(exchange!(code))

      assert [%UserToken{origin: "oauth:google"}] =
               Repo.all(
                 from(t in UserToken, where: t.user_id == ^user.id and t.context == "session")
               )
    end

    test "burning one code does not touch a SIBLING code of the same user" do
      # MATCHED-ROW-ONLY. Every revoke_*_tokens/2 helper in Accounts is scoped by
      # user_id + context with NO token_hash — reusing one here would kill the
      # user's other in-flight sign-in (two windows, two "Continue with GitHub").
      c1 = callback_code("github")
      c2 = callback_code("github")
      refute c1 == c2

      assert %User{} = Accounts.verify_user_session_token(exchange!(c1))
      # The sibling is untouched and still redeems.
      assert %User{} = Accounts.verify_user_session_token(exchange!(c2))
    end
  end

  # THE ROUTE SHAPE. `plug(Plug.Head)` rewrites HEAD→GET unconditionally BEFORE
  # matching, so HEAD-ness is destroyed by the time any route runs and a POST-only
  # path can only refuse a HEAD prober by having no GET clause that reaches its
  # handler. (Measured counterexample elsewhere in this router: HEAD /v1/tokens
  # answers 401, not 404, precisely because a `get "/v1/tokens"` lives beside its
  # `post`.) The invariant is the PATH, not the verb.
  describe "the exchange path has no GET handler" do
    test "GET and HEAD both answer 404 — never 401, and never a mint" do
      code = callback_code("github")

      # 404, not 401: a 401 would mean SOME clause matched and only an auth check
      # refused it — which is exactly how HEAD /v1/tokens reaches the LIST handler.
      #
      # HONEST READING OF THIS 404: `get "/v1/auth/oauth/:provider"` has the same
      # segment arity and DOES pattern-match this path. It answers 404
      # `provider_not_enabled` because OAuth.authorize_url/1 resolves the provider
      # BEFORE mint_state/1 runs, so "exchange" fails closed with no row written
      # and no handler reached. The prober's outcome is what the invariant is
      # about; the route it fell through is named here so nobody reads `== 404` as
      # proof of a route that is not there.
      assert call(:get, "/v1/auth/oauth/exchange").status == 404
      head = call(:head, "/v1/auth/oauth/exchange")
      assert head.status == 404

      # NOT 405: the cch-w2 side-effecting-GET fence must NOT claim `allow: GET`
      # for a path whose only handler is a POST. That would be a lie of exactly
      # the shape this epic exists to remove.
      assert get_resp_header(head, "allow") == []

      # And a prober's HEAD wrote nothing: no oauth_states row, no session, and
      # the pending exchange code is still there for its rightful owner.
      assert Repo.aggregate(from(t in UserToken, where: t.context == "session"), :count) == 0
      assert %User{} = Accounts.verify_user_session_token(exchange!(code))
    end
  end

  describe "Accounts.reap_oauth_exchange_codes/0" do
    test "deletes burned and expired codes, keeps live ones, and is idempotent" do
      burned = callback_code("github")
      expired = callback_code("github")
      live = callback_code("github")

      _ = exchange!(burned)

      {1, _} =
        Repo.update_all(
          from(t in UserToken,
            where:
              t.context == "oauth_exchange" and t.token_hash == ^UserToken.hash_token(expired)
          ),
          set: [
            expires_at:
              DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
          ]
        )

      assert %{reaped: 2} = Accounts.reap_oauth_exchange_codes()

      assert [%UserToken{token_hash: kept}] =
               Repo.all(from(t in UserToken, where: t.context == "oauth_exchange"))

      assert kept == UserToken.hash_token(live)

      # A sweep that finds nothing is a no-op, never a raise.
      assert %{reaped: 0} = Accounts.reap_oauth_exchange_codes()
      # …and the survivor is still redeemable: the reaper is hygiene, never a
      # second expiry policy.
      assert %User{} = Accounts.verify_user_session_token(exchange!(live))
    end

    test "is STRICTLY context-scoped — it never touches a session tombstone" do
      # user_tokens is polymorphic and a revoked "session" row is the evidence the
      # active-sessions UI renders. Widening the reaper's `where` by one context
      # would delete other people's history; this is the tripwire for that.
      token = exchange!(callback_code("github"))
      user = Accounts.verify_user_session_token(token)
      assert Accounts.revoke_user_session_token(token)

      sessions_before = session_count(user)
      assert sessions_before > 0

      # Every "oauth_exchange" row is burned by now, so the sweep has work to do
      # and a context-blind version would take the tombstone with it.
      assert %{reaped: n} = Accounts.reap_oauth_exchange_codes()
      assert n >= 1
      assert session_count(user) == sessions_before
    end

    test "the worker calls it and is idempotent on an empty table" do
      assert {:ok, %{reaped: 0}} =
               BarkparkCloud.Workers.OAuthExchangeReaper.perform(%Oban.Job{})
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

  # cch-w10: was `token_from/1`, reading `oauth=`. The fragment no longer carries a
  # session token to read — it carries the one-time code, and the token only comes
  # back from POST /v1/auth/oauth/exchange.
  defp session_count(%User{id: id}) do
    Repo.aggregate(
      from(t in UserToken, where: t.user_id == ^id and t.context == "session"),
      :count
    )
  end

  defp code_from(location) do
    [_, frag] = String.split(location, "#", parts: 2)
    URI.decode_query(frag)["oauth_code"]
  end
end
