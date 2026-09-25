defmodule Barkpark.AuditBestEffortCallersTest do
  @moduledoc """
  Locks the caller-visible behaviour of every BEST-EFFORT audit emit site
  (era-bl-audit-swallow-unify): when `Barkpark.Audit.emit/1` RAISES, the flow it
  accompanies must still return exactly what it returns on the happy path and
  land exactly the same state change. The law: an audit-emit failure never
  breaks an auth, session, account or webhook flow.

  The fault is real, not mocked: a `BEFORE INSERT` trigger on `audit_events`
  raises for ONE named action, so the emit under test raises a `Postgrex.Error`
  from inside its own `Repo.transaction` while every OTHER emit on the same
  path (several are deliberately NOT best-effort) still succeeds. Each test
  also asserts that no row for the faulted action was written — the
  precondition that the fault actually fired.

  The emit-ERROR (`{:error, _}`) arm is not reachable from these callers: every
  one of them passes a hard-coded, valid category and action, and a DB-level
  error raises rather than returning. That arm, plus throw and exit, is locked
  at the shared helper in `Barkpark.AuditBestEffortTest`.

  `async: false`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on
  `audit_events`, which every emitting test in the suite writes to. The DDL is
  transactional, so the sandbox rollback removes the trigger.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Barkpark.{Accounts, Repo, Webhooks}
  alias Barkpark.Accounts.User
  alias Barkpark.Audit.Event
  alias Barkpark.Webhooks.Webhook

  @password "correct-horse-battery"

  # From here on, an INSERT into audit_events whose action is `action` raises
  # on this connection. Other actions are untouched.
  defp fail_audit_action!(action) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION bp_test_fail_audit_action() RETURNS trigger AS $fn$
    BEGIN
      IF NEW.action = '#{action}' THEN
        RAISE EXCEPTION 'bp_test: audit emit fault for %', NEW.action;
      END IF;
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER bp_test_fail_audit_action_trg
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION bp_test_fail_audit_action()
    """)

    :ok
  end

  defp events(action), do: Repo.all(from(e in Event, where: e.action == ^action))

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp authed(token), do: scoped_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp login!(email) do
    scoped_conn()
    |> json_conn()
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  describe "Accounts (emit_audit/1)" do
    test "account_locked: the lockout still trips and the login still fails closed" do
      user = register!("lock-audit@example.com")
      max = Accounts.max_failed_logins()

      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^user.id),
          set: [failed_login_count: max - 1]
        )

      fail_audit_action!("account_locked")

      assert Accounts.get_user_by_email_and_password("lock-audit@example.com", "wrong") == nil

      reloaded = Repo.get!(User, user.id)
      assert reloaded.failed_login_count == max
      assert reloaded.locked_until
      assert events("account_locked") == []
    end

    test "recovery_code_used: the code is still consumed and {:ok, user} returned" do
      user = register!("recovery-audit@example.com")
      code = "bp-test-recovery-code"
      hash = :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^user.id),
          set: [recovery_codes_hashed: [hash, "other"]]
        )

      user = Repo.get!(User, user.id)
      fail_audit_action!("recovery_code_used")

      assert {:ok, %User{recovery_codes_hashed: ["other"]}} =
               Accounts.consume_recovery_code(user, code)

      assert Repo.get!(User, user.id).recovery_codes_hashed == ["other"]
      assert events("recovery_code_used") == []
    end
  end

  describe "AuthController (audit/1)" do
    test "login_failed: a bad password is still the generic 401" do
      register!("login-failed-audit@example.com")
      fail_audit_action!("login_failed")

      body =
        scoped_conn()
        |> json_conn()
        |> post(
          "/v1/auth/login",
          Jason.encode!(%{email: "login-failed-audit@example.com", password: "nope"})
        )
        |> json_response(401)

      assert body["error"]["code"] == "invalid_credentials"
      assert events("login_failed") == []
    end

    test "logout: still 200s and the session is still revoked" do
      register!("logout-audit@example.com")
      token = login!("logout-audit@example.com")
      fail_audit_action!("logout")

      body = authed(token) |> delete("/v1/auth/logout") |> json_response(200)
      assert body["ok"] == true
      assert body["revoked"] == 1
      assert authed(token) |> get("/v1/auth/me") |> json_response(401)
      assert events("logout") == []
    end

    test "password_changed: the password still changes and the session dies" do
      register!("pwchange-audit@example.com")
      token = login!("pwchange-audit@example.com")
      fail_audit_action!("password_changed")

      assert %{"ok" => true} =
               authed(token)
               |> json_conn()
               |> patch(
                 "/v1/auth/password",
                 Jason.encode!(%{current_password: @password, password: "brand-new-password-1"})
               )
               |> json_response(200)

      assert authed(token) |> get("/v1/auth/me") |> json_response(401)

      assert Accounts.get_user_by_email_and_password(
               "pwchange-audit@example.com",
               "brand-new-password-1"
             )

      assert events("password_changed") == []
    end

    test "password_reset: the reset still lands and reports its revoke count" do
      user = register!("pwreset-audit@example.com")
      _token = login!("pwreset-audit@example.com")
      {:ok, raw} = Accounts.build_email_token(user, "reset")
      fail_audit_action!("password_reset")

      body =
        scoped_conn()
        |> json_conn()
        |> post("/v1/auth/reset", Jason.encode!(%{token: raw, password: "reset-password-1"}))
        |> json_response(200)

      assert body == %{"ok" => true, "sessionsRevoked" => 1}

      assert Accounts.get_user_by_email_and_password(
               "pwreset-audit@example.com",
               "reset-password-1"
             )

      assert events("password_reset") == []
    end
  end

  describe "SessionIssuer (audit_session_mint/2)" do
    test "session_minted: login still 201s with a bearer that authenticates" do
      register!("mint-audit@example.com")
      fail_audit_action!("session_minted")

      token = login!("mint-audit@example.com")

      me = authed(token) |> get("/v1/auth/me") |> json_response(200)
      assert me["user"]["email"] == "mint-audit@example.com"
      assert events("session_minted") == []
    end
  end

  describe "Webhooks (audit_webhook/2, emit_latch_event/3)" do
    defp hook do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "AuditFault",
          "url" => "http://example.com/hook",
          "dataset" => "auditfaultds",
          "events" => [],
          "types" => []
        })

      wh
    end

    test "webhook_created: create still returns {:ok, webhook} and persists it" do
      fail_audit_action!("webhook_created")
      wh = hook()
      assert %Webhook{name: "AuditFault"} = Repo.get!(Webhook, wh.id)
      assert events("webhook_created") == []
    end

    test "webhook_updated: update still returns the SAME {:ok, webhook} it persisted" do
      wh = hook()
      fail_audit_action!("webhook_updated")

      assert {:ok, %Webhook{name: "Renamed"} = updated} =
               Webhooks.update_webhook(wh, %{"name" => "Renamed"})

      assert Repo.get!(Webhook, wh.id).name == "Renamed"
      assert updated.id == wh.id
      assert events("webhook_updated") == []
    end

    test "webhook_deleted: delete still returns {:ok, webhook} and the row is gone" do
      wh = hook()
      fail_audit_action!("webhook_deleted")

      assert {:ok, %Webhook{id: id}} = Webhooks.delete_webhook(wh)
      assert id == wh.id
      refute Repo.get(Webhook, wh.id)
      assert events("webhook_deleted") == []
    end

    test "webhook_auto_disabled / _reenabled: the latch still flips both ways" do
      prev = Application.get_env(:barkpark, :webhook_auto_disable_threshold)
      Application.put_env(:barkpark, :webhook_auto_disable_threshold, 2)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:barkpark, :webhook_auto_disable_threshold),
          else: Application.put_env(:barkpark, :webhook_auto_disable_threshold, prev)
      end)

      wh = hook()
      fail_audit_action!("webhook_auto_disabled")

      capture_log(fn ->
        assert {:ok, 1} = Webhooks.record_endpoint_failure(wh.id, "http 500")
        assert {:ok, 2} = Webhooks.record_endpoint_failure(wh.id, "http 500")
      end)

      disabled = Repo.get!(Webhook, wh.id)
      assert disabled.active == false
      assert disabled.auto_disabled_at
      assert events("webhook_auto_disabled") == []

      Repo.query!("DROP TRIGGER bp_test_fail_audit_action_trg ON audit_events")
      fail_audit_action!("webhook_auto_reenabled")

      capture_log(fn ->
        # The recovery flip already zeroed the streak, so the reset proper
        # matches no row — the same {0, nil} the happy path returns.
        assert {0, nil} = Webhooks.reset_endpoint_failures(wh.id)
      end)

      reenabled = Repo.get!(Webhook, wh.id)
      assert reenabled.active == true
      assert reenabled.auto_disabled_at == nil
      assert events("webhook_auto_reenabled") == []
    end
  end
end
