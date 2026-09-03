defmodule BarkparkCloud.Web.RouterSessionTouchTest do
  @moduledoc """
  `last_used_at` is a LIVENESS claim the sessions card renders as "Active just
  now" — so it must only be written for a request the platform actually served.

  THE DEFECT (measured at router level before this fix). Authentication runs
  BEFORE authorization: `Auth.require_platform_operator/2` calls `require_user/2`
  first, which calls `Accounts.verify_user_session_token/1`, which stamped
  `last_used_at` UNCONDITIONALLY — and only THEN evaluated the allowlist and
  answered `forbidden(conn)`. A device idle for an hour could fire ONE request,
  be REFUSED 403 `{"error":"forbidden"}`, and the console would still print an
  11ms-old stamp for it. Six distinct `forbidden(conn)` sites in `auth.ex` sit
  downstream of that write, so no throttle AT the write site could ever reach
  this case: an idle device SATISFIES a throttle's staleness guard. The placement
  was the bug, not the frequency.

  THE FIX, and why it is the only placement that works: the stamp is DEFERRED to
  `Plug.Conn.register_before_send/2` and gated on `conn.status < 400` — the first
  point in the request where the response decision is known. That single move
  pays both halves: authorization-awareness (this file) and the write
  amplification the throttle was aimed at (the 60s window, pinned below).

  SSE (`require_user_sse`, router.ex) is deliberately NOT deferred — see
  `Accounts.verify_user_session_token/2`'s `:touch` option and
  `router_sse_ticket_head_burn_test.exs`, which pins that path's eager stamp.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures

  defp user_with_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    user
  end

  defp session_row(user) do
    Repo.one(from(t in UserToken, where: t.user_id == ^user.id and t.context == "session"))
  end

  # Backdate the row to a KNOWN instant and hand it back. The assertion is then
  # "still exactly that instant", which no clock resolution can fake.
  defp backdate!(user, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user.id and t.context == "session"),
        set: [last_used_at: at]
      )

    at
  end

  defp call(method, path, token) do
    method
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  ## The instance — a denied request must not claim activity

  describe "a REFUSED request and last_used_at" do
    test "a 403 from the operator gate does NOT advance the stamp" do
      user = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")

      # Somebody ELSE is the operator, so this session authenticates and is then
      # refused — the exact shape the console lied about.
      Application.put_env(:barkpark_cloud, :platform_admin_emails, ["someone-else@example.com"])

      # Idle for an hour: 60x any throttle window, so a throttle at the write
      # site would happily fire here. Only the status gate can hold this.
      idle_since = backdate!(user, 3600)

      conn = call(:get, "/v1/operator/fleet", token)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "forbidden"

      assert %UserToken{last_used_at: ^idle_since} = session_row(user), """
      a DENIED request advanced last_used_at — the sessions card would print \
      "Active just now" for a device the platform just refused.
      """
    end
  end

  ## The positive direction — an allowed request MUST still claim activity

  describe "an ALLOWED request and last_used_at" do
    test "a 200 DOES advance the stamp" do
      user = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      idle_since = backdate!(user, 3600)

      conn = call(:get, "/v1/me", token)
      assert conn.status == 200

      %UserToken{last_used_at: after_call} = session_row(user)

      assert DateTime.compare(after_call, idle_since) == :gt,
             "an allowed request left the stamp cold — liveness is now under-reported"
    end

    test "two allowed requests inside the 60s window produce exactly ONE write" do
      user = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      backdate!(user, 3600)

      assert call(:get, "/v1/me", token).status == 200
      %UserToken{last_used_at: first} = session_row(user)

      assert call(:get, "/v1/me", token).status == 200
      %UserToken{last_used_at: second} = session_row(user)

      assert DateTime.compare(first, second) == :eq, """
      the second request inside the throttle window wrote again — every read of \
      the console amplifies to an UPDATE.
      """
    end
  end

  ## The stamp must never be able to FAIL the request it is stamping

  describe "a DB failure inside the deferred stamp" do
    # A BEFORE UPDATE trigger on user_tokens: the verify SELECT still succeeds,
    # and ONLY the stamp's `update_all` raises. That is the real fault shape —
    # a transient write failure (pool timeout, dropped connection, deadlock)
    # hitting a statement that runs inside `register_before_send/2`, AFTER the
    # response has already been decided. It lives inside the sandbox
    # transaction, so it rolls back with the test.
    defp poison_token_writes! do
      Repo.query!("""
      CREATE OR REPLACE FUNCTION pg_temp.bp_touch_boom() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'db down'; END;
      $$ LANGUAGE plpgsql;
      """)

      Repo.query!("""
      CREATE TRIGGER bp_touch_boom BEFORE UPDATE ON user_tokens
      FOR EACH ROW EXECUTE FUNCTION pg_temp.bp_touch_boom();
      """)

      :ok
    end

    test "the request still returns its REAL status — a failed stamp is not a 500" do
      user = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      backdate!(user, 3600)
      poison_token_writes!()

      # RED before the fix: an exception raised inside a before_send callback
      # ESCAPES `send_resp`, so this raised Postgrex.Error out of `Router.call`
      # and the platform answered 500 for a request it had already SERVED.
      conn = call(:get, "/v1/me", token)

      assert conn.status == 200, """
      a transient DB failure while stamping "last seen" changed the answer the \
      person received — the request was served, then reported as failed.
      """
    end

    test "a failed stamp is OBSERVABLE — it logs, as the PAT path does" do
      user = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
      backdate!(user, 3600)
      poison_token_writes!()

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert call(:get, "/v1/me", token).status == 200 end)

      assert log =~ "touch_session_last_used failed", """
      the stamp failed SILENTLY — swallowing the error without a log makes a \
      degraded liveness column indistinguishable from an idle fleet.
      """
    end
  end
end
