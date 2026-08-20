defmodule BarkparkCloud.DeviceAuthTest do
  @moduledoc """
  Unit tests for the device-authorization context (bp-login-ux): the two-secret
  start/inspect/approve/deny/poll lifecycle, single-use + replay discipline,
  in-band expiry, the session mint envelope, the generic rate limiter, and the
  reaper's sweep. Oban test mode is :manual, so the reaper's `reap_expired/0` is
  exercised directly (not via the queue).
  """
  use BarkparkCloud.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.DeviceAuth
  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.DeviceAuth.Request
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @router_opts Router.init([])

  setup do
    RateLimiter.reset()
    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "dev-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # Force a request's expiry into the past without going through the API.
  defp expire!(user_code) do
    hash = UserToken.hash_token(String.replace(String.upcase(user_code), ~r/[^0-9A-Z]/, ""))
    past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    {1, _} =
      from(r in Request, where: r.user_code_hash == ^hash)
      |> Repo.update_all(set: [expires_at: past])

    :ok
  end

  describe "start/1" do
    test "mints two distinct codes, a XXXX-XXXX user_code, and a pending row" do
      assert {:ok, %{device_code: dc, user_code: uc, interval: 5, expires_in: 600}} =
               DeviceAuth.start(%{
                 client_name: "bp on laptop",
                 ip_address: "1.2.3.4",
                 user_agent: "bp/1"
               })

      assert is_binary(dc) and byte_size(dc) > 20
      assert uc =~ ~r/^[23456789ABCDEFGHJKMNPQRSTVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTVWXYZ]{4}$/

      row = Repo.one(Request)
      assert row.status == "pending"
      assert row.client_name == "bp on laptop"
      assert row.ip_address == "1.2.3.4"
      assert row.user_agent == "bp/1"
      assert is_nil(row.user_id)
      # Only hashes at rest — never the plaintext.
      assert row.device_code_hash == UserToken.hash_token(dc)
      refute row.device_code_hash == dc
    end

    test "two starts mint different codes" do
      {:ok, a} = DeviceAuth.start(%{})
      {:ok, b} = DeviceAuth.start(%{})
      assert a.device_code != b.device_code
      assert a.user_code != b.user_code
    end

    test "blank client_name is stored as nil" do
      {:ok, %{}} = DeviceAuth.start(%{client_name: "   "})
      assert Repo.one(Request).client_name == nil
    end
  end

  describe "inspect/1" do
    test "returns the requesting metadata for a pending code" do
      {:ok, %{user_code: uc}} =
        DeviceAuth.start(%{client_name: "bp", ip_address: "9.9.9.9", user_agent: "bp/2"})

      assert {:ok, row} = DeviceAuth.inspect(uc)
      assert row.client_name == "bp"
      assert row.ip_address == "9.9.9.9"
      assert row.user_agent == "bp/2"
    end

    test "accepts the dash-stripped / lower-cased form" do
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})
      dashless = uc |> String.replace("-", "") |> String.downcase()
      assert {:ok, _} = DeviceAuth.inspect(dashless)
    end

    test "unknown / expired code is expired_or_invalid" do
      assert {:error, :expired_or_invalid} = DeviceAuth.inspect("ABCD-EFGH")

      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})
      expire!(uc)
      assert {:error, :expired_or_invalid} = DeviceAuth.inspect(uc)
    end
  end

  describe "approve/2 (CAS, single-use)" do
    test "flips pending→approved and stamps user_id" do
      user = user_fixture()
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})

      assert :ok = DeviceAuth.approve(uc, user.id)

      row = Repo.one(Request)
      assert row.status == "approved"
      assert row.user_id == user.id
    end

    test "a second approve fails (single-use CAS)" do
      user = user_fixture()
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})

      assert :ok = DeviceAuth.approve(uc, user.id)
      assert {:error, :expired_or_invalid} = DeviceAuth.approve(uc, user.id)
    end

    test "approving an expired code fails" do
      user = user_fixture()
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})
      expire!(uc)
      assert {:error, :expired_or_invalid} = DeviceAuth.approve(uc, user.id)
    end

    test "approving an unknown code fails" do
      user = user_fixture()
      assert {:error, :expired_or_invalid} = DeviceAuth.approve("ZZZZ-ZZZZ", user.id)
    end
  end

  describe "deny/1" do
    test "deletes the row and makes a later poll fail closed" do
      {:ok, %{user_code: uc, device_code: dc}} = DeviceAuth.start(%{})
      assert :ok = DeviceAuth.deny(uc)
      assert Repo.aggregate(Request, :count) == 0
      assert {:error, :expired_or_invalid} = DeviceAuth.poll(dc)
    end

    test "is idempotent on an unknown code" do
      assert :ok = DeviceAuth.deny("ABCD-EFGH")
    end
  end

  describe "poll/1" do
    test "pending before approval" do
      {:ok, %{device_code: dc}} = DeviceAuth.start(%{})
      assert {:pending} = DeviceAuth.poll(dc)
    end

    test "after approval, consumes the row and mints the session with captured IP/UA" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")

      {:ok, %{device_code: dc, user_code: uc}} =
        DeviceAuth.start(%{client_name: "bp", ip_address: "5.6.7.8", user_agent: "bp/agent"})

      :ok = DeviceAuth.approve(uc, user.id)

      assert {:ok, token, minted_team} = DeviceAuth.poll(dc)
      assert is_binary(token)
      assert minted_team.id == team.id

      # The minted session is a real, verifiable session for this user...
      assert Accounts.verify_user_session_token(token).id == user.id

      # ...carrying the CLI's captured IP + UA, not the approving browser's.
      session = Repo.get_by(UserToken, token_hash: UserToken.hash_token(token))
      assert session.ip_address == "5.6.7.8"
      assert session.user_agent == "bp/agent"

      # ...and saying so: the ONE mint site outside the router stamps its own
      # origin, so the sessions list can honestly show "via device link" for a
      # session nobody typed a password into this browser for
      # (gr-p5-session-provenance). Read off the COLUMN, not just the struct —
      # a struct default would satisfy the field read alone.
      assert session.origin == "device_link"

      assert %Postgrex.Result{rows: [["device_link"]]} =
               Repo.query!("SELECT origin FROM user_tokens WHERE token_hash = $1", [
                 UserToken.hash_token(token)
               ])

      # The request row is consumed.
      assert Repo.aggregate(Request, :count) == 0
    end

    test "team_id is nil when the user is in no team" do
      user = user_fixture()
      {:ok, %{device_code: dc, user_code: uc}} = DeviceAuth.start(%{})
      :ok = DeviceAuth.approve(uc, user.id)

      assert {:ok, _token, nil} = DeviceAuth.poll(dc)
    end

    test "a replayed poll after a successful consume fails closed" do
      user = user_fixture()
      {:ok, %{device_code: dc, user_code: uc}} = DeviceAuth.start(%{})
      :ok = DeviceAuth.approve(uc, user.id)

      assert {:ok, _token, _team} = DeviceAuth.poll(dc)
      # Second poll of the same device_code — the row is gone.
      assert {:error, :expired_or_invalid} = DeviceAuth.poll(dc)
    end

    test "expired approved request cannot be polled" do
      user = user_fixture()
      {:ok, %{device_code: dc, user_code: uc}} = DeviceAuth.start(%{})
      :ok = DeviceAuth.approve(uc, user.id)
      expire!(uc)

      assert {:error, :expired_or_invalid} = DeviceAuth.poll(dc)
      # And no session leaked.
      assert Repo.aggregate(UserToken, :count) == 0
    end

    test "unknown / blank device_code fails closed" do
      assert {:error, :expired_or_invalid} = DeviceAuth.poll("nope")
      assert {:error, :expired_or_invalid} = DeviceAuth.poll("")
    end
  end

  describe "reap_expired/0" do
    test "deletes only expired rows" do
      {:ok, %{user_code: dead}} = DeviceAuth.start(%{})
      {:ok, %{device_code: live_dc}} = DeviceAuth.start(%{})
      expire!(dead)

      assert %{reaped: 1} = DeviceAuth.reap_expired()
      # The live one still polls.
      assert {:pending} = DeviceAuth.poll(live_dc)
    end

    test "is a no-op when nothing is expired" do
      {:ok, _} = DeviceAuth.start(%{})
      assert %{reaped: 0} = DeviceAuth.reap_expired()
    end
  end

  describe "RateLimiter.check/1" do
    test "poll allows 20/window then trips slow_down" do
      key = "poll:#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
      for _ <- 1..20, do: assert(:ok = RateLimiter.check(key))
      assert {:error, :rate_limited} = RateLimiter.check(key)
    end

    test "start allows 10/window then trips" do
      key = "start:1.2.3.4"
      for _ <- 1..10, do: assert(:ok = RateLimiter.check(key))
      assert {:error, :rate_limited} = RateLimiter.check(key)
    end

    test "approve allows 10/window then trips" do
      key = "approve:#{Ecto.UUID.generate()}"
      for _ <- 1..10, do: assert(:ok = RateLimiter.check(key))
      assert {:error, :rate_limited} = RateLimiter.check(key)
    end

    test "distinct keys have independent budgets" do
      for _ <- 1..10, do: RateLimiter.check("start:a")
      assert {:error, :rate_limited} = RateLimiter.check("start:a")
      assert :ok = RateLimiter.check("start:b")
    end

    test "an unknown prefix falls back to the default limit" do
      for _ <- 1..10, do: assert(:ok = RateLimiter.check("mystery:x"))
      assert {:error, :rate_limited} = RateLimiter.check("mystery:x")
    end
  end

  ## HTTP surface — drive the five routes through the real router (Plug.Test), the
  ## end-to-end proof of the auth gating + JSON envelopes S2/S3 build against.

  defp call(method, path, body, token \\ nil) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @router_opts)
  end

  defp jbody(conn), do: Jason.decode!(conn.resp_body)

  describe "HTTP: full start → approve → poll handshake" do
    test "start, browser approve, then poll mints a session (byte-identical to /login)" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {:ok, session} = Accounts.create_user_session_token(user)

      # 1. CLI starts the device flow (unauthenticated).
      start = call(:post, "/v1/auth/device/start", %{client_name: "bp on laptop"})
      assert start.status == 200
      s = jbody(start)
      assert String.ends_with?(s["verification_uri"], "/activate")
      assert s["verification_uri_complete"] == s["verification_uri"] <> "?code=" <> s["user_code"]
      assert s["interval"] == 5 and s["expires_in"] == 600

      # 2. CLI polls: still pending.
      poll1 = call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]})
      assert poll1.status == 200 and jbody(poll1) == %{"status" => "pending"}

      # 3. Browser inspects + approves (authenticated).
      insp = call(:post, "/v1/auth/device/inspect", %{user_code: s["user_code"]}, session)
      assert insp.status == 200 and jbody(insp)["client_name"] == "bp on laptop"

      approve = call(:post, "/v1/auth/device/approve", %{user_code: s["user_code"]}, session)
      assert approve.status == 200 and jbody(approve) == %{"ok" => true}

      # 4. CLI polls again: gets exactly {token, team_id}.
      poll2 = call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]})
      assert poll2.status == 200
      body = jbody(poll2)
      assert Map.keys(body) |> Enum.sort() == ["team_id", "token"]
      assert body["team_id"] == team.id
      assert Accounts.verify_user_session_token(body["token"]).id == user.id

      # 5. Replay of the successful poll fails closed.
      assert call(:post, "/v1/auth/device/poll", %{device_code: s["device_code"]}).status == 404
    end
  end

  describe "HTTP: verification_uri host split (dashboard boxing)" do
    # :dashboard_url is https://barkpark.cloud in every env. A request arriving on
    # the dashboard host or a subdomain of it (prod: api.barkpark.cloud) boxes the
    # canonical dashboard origin so the browser rides its existing session; any
    # other host (local dev) keeps its own origin so a localhost CLI never points
    # at barkpark.cloud's DB.
    test "a request on api.<dashboard-host> canonicalizes onto the dashboard host" do
      start =
        call(:post, "https://api.barkpark.cloud/v1/auth/device/start", %{client_name: "bp"})

      assert start.status == 200
      s = jbody(start)
      assert s["verification_uri"] == "https://barkpark.cloud/activate"

      assert s["verification_uri_complete"] ==
               "https://barkpark.cloud/activate?code=" <> s["user_code"]

      assert String.ends_with?(s["verification_uri"], "/activate")
    end

    test "a local (non-dashboard) host keeps its own origin — no barkpark.cloud boxing" do
      start =
        call(:post, "http://localhost:4100/v1/auth/device/start", %{client_name: "bp"})

      assert start.status == 200
      s = jbody(start)
      assert s["verification_uri"] == "http://localhost:4100/activate"
      refute String.contains?(s["verification_uri"], "barkpark.cloud")
      assert s["verification_uri_complete"] == s["verification_uri"] <> "?code=" <> s["user_code"]
    end

    test "a lookalike host (evilbarkpark.cloud) is NOT boxed — the subdomain match needs the dot" do
      start =
        call(:post, "https://evilbarkpark.cloud/v1/auth/device/start", %{client_name: "bp"})

      assert start.status == 200
      s = jbody(start)
      assert s["verification_uri"] == "https://evilbarkpark.cloud/activate"
    end
  end

  describe "HTTP: auth gating (the 2FA guarantee)" do
    test "inspect / approve / deny reject an unauthenticated caller with 401" do
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})

      for path <- ["inspect", "approve", "deny"] do
        conn = call(:post, "/v1/auth/device/#{path}", %{user_code: uc})
        assert conn.status == 401, "#{path} must 401 without a Bearer session"
      end
    end

    test "an unknown device_code poll is 404 expired_or_invalid" do
      conn = call(:post, "/v1/auth/device/poll", %{device_code: "made-up"})
      assert conn.status == 404
      assert jbody(conn) == %{"error" => "expired_or_invalid"}
    end
  end

  describe "HTTP: inspect shares the approve budget (no unmetered user_code oracle)" do
    test "the 11th inspect in a window is 429 rate_limited" do
      user = user_fixture()
      {:ok, session} = Accounts.create_user_session_token(user)
      {:ok, %{user_code: uc}} = DeviceAuth.start(%{})

      for _ <- 1..10 do
        assert call(:post, "/v1/auth/device/inspect", %{user_code: uc}, session).status == 200
      end

      throttled = call(:post, "/v1/auth/device/inspect", %{user_code: uc}, session)
      assert throttled.status == 429
      assert jbody(throttled) == %{"error" => "rate_limited"}
    end
  end

  describe "HTTP: poll rate limit → slow_down" do
    test "the 21st poll in a window is 429 slow_down" do
      {:ok, %{device_code: dc}} = DeviceAuth.start(%{})

      for _ <- 1..20 do
        assert call(:post, "/v1/auth/device/poll", %{device_code: dc}).status == 200
      end

      throttled = call(:post, "/v1/auth/device/poll", %{device_code: dc})
      assert throttled.status == 429
      assert jbody(throttled) == %{"error" => "slow_down"}
    end
  end

  # FK-abort containment (Felix W18). `device_auth_requests.user_id` is a real
  # Postgres FK (migration 20260709140000, default name
  # `device_auth_requests_user_id_fkey`). `Request.changeset/2` declares
  # `assoc_constraint(:user)`, so a changeset-path insert carrying a phantom
  # user_id returns {:error, changeset} instead of raising Ecto.ConstraintError.
  #
  # NOTE: the hot approve path — `DeviceAuth.approve/2` — stamps user_id via
  # `Repo.update_all`, which BYPASSES changesets by construction; that path is
  # unchanged and only ever writes a user_id resolved from a live session.
  describe "Request.changeset/2 FK-abort containment" do
    defp request_attrs(overrides) do
      suffix = System.unique_integer([:positive])

      Map.merge(
        %{
          device_code_hash: "dc-#{suffix}",
          user_code_hash: "uc-#{suffix}",
          status: "approved",
          expires_at:
            DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:microsecond)
        },
        overrides
      )
    end

    test "a phantom user_id returns {:error, changeset} via the changeset path, never a raise" do
      assert {:error, %Ecto.Changeset{} = cs} =
               %Request{}
               |> Request.changeset(request_attrs(%{user_id: Ecto.UUID.generate()}))
               |> Repo.insert()

      assert {"does not exist", _} = cs.errors[:user]
    end

    test "a live user_id still inserts" do
      user = user_fixture()

      assert {:ok, %Request{} = row} =
               %Request{}
               |> Request.changeset(request_attrs(%{user_id: user.id}))
               |> Repo.insert()

      assert row.user_id == user.id
    end
  end
end
