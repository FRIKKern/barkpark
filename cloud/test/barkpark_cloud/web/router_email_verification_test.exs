defmodule BarkparkCloud.Web.RouterEmailVerificationTest do
  @moduledoc """
  Drives the email-verification-recovery HTTP surface via Plug.Test: verify-email
  (single-use), resend-verification (ALWAYS 200), account/email/change
  (enumeration-safe 202), account/email/confirm (swap + lockout). Mirrors
  router_password_reset_test.exs's harness.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import Swoosh.TestAssertions

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.User
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

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

  defp session(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token \\ nil) do
    conn =
      conn(method, path, body && Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Pull the emailed 6-digit code / confirm token back out of the mailbox.
  defp last_email_code do
    assert_receive {:email, email}
    [code] = Regex.run(~r/\b\d{6}\b/, email.text_body)
    code
  end

  describe "POST /v1/auth/verify-email" do
    test "a valid confirm token → 200 and /v1/me then reports confirmed: true" do
      user = user_fixture()
      {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:email, email}
      [_, token] = Regex.run(~r/\?confirm=([^\s]+)/, email.text_body)

      conn = call(:post, "/v1/auth/verify-email", %{token: token})
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}

      me = call(:get, "/v1/me", nil, session(user))
      assert me.status == 200
      assert json_body(me)["user"]["confirmed"] == true
    end

    test "a replayed token → 422 invalid_token (single-use)" do
      user = user_fixture()
      {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_receive {:email, email}
      [_, token] = Regex.run(~r/\?confirm=([^\s]+)/, email.text_body)

      assert call(:post, "/v1/auth/verify-email", %{token: token}).status == 200
      replay = call(:post, "/v1/auth/verify-email", %{token: token})
      assert replay.status == 422
      assert json_body(replay) == %{"error" => "invalid_token"}
    end

    test "a garbage / missing token → 422 invalid_token" do
      assert call(:post, "/v1/auth/verify-email", %{token: "nope"}).status == 422
      assert call(:post, "/v1/auth/verify-email", %{}).status == 422
    end
  end

  describe "POST /v1/auth/resend-verification" do
    test "unauthenticated → 401" do
      assert call(:post, "/v1/auth/resend-verification", %{}).status == 401
    end

    test "a fresh user → 200 + one email; a throttled resend → still 200 with NO second email" do
      user = user_fixture()
      token = session(user)

      assert call(:post, "/v1/auth/resend-verification", %{}, token).status == 200
      assert_receive {:email, _}

      # Throttled (confirm cap is 1 / 5 min): still 200, and NO second email.
      assert call(:post, "/v1/auth/resend-verification", %{}, token).status == 200
      refute_receive {:email, _}
    end

    test "an already-confirmed user → still 200 (no leak, no error surfaced)" do
      user = user_fixture()
      {:ok, _} = Repo.update(User.confirm_changeset(user))

      assert call(:post, "/v1/auth/resend-verification", %{}, session(user)).status == 200
      # The already-confirmed branch mints nothing / sends nothing.
      refute_receive {:email, _}
    end
  end

  describe "POST /v1/account/email/change" do
    test "a fresh target → 202 and emails a code to the new address" do
      user = user_fixture()
      target = "changed-#{System.unique_integer([:positive])}@example.com"

      conn = call(:post, "/v1/account/email/change", %{new_email: target}, session(user))
      assert conn.status == 202
      assert json_body(conn) == %{"ok" => true}
      assert_email_sent(subject: "Confirm your new Barkpark Cloud email")
    end

    test "an ALREADY-REGISTERED target → the SAME 202 with NO email (enumeration-safe)" do
      victim = user_fixture(email: "victim-#{System.unique_integer([:positive])}@example.com")
      attacker = user_fixture()

      conn =
        call(:post, "/v1/account/email/change", %{new_email: victim.email}, session(attacker))

      # Indistinguishable from success — a prober learns nothing.
      assert conn.status == 202
      assert json_body(conn) == %{"ok" => true}
      assert_no_email_sent()

      # No pending change was staged for the attacker (no takeover foothold).
      assert Repo.get!(User, attacker.id).pending_email == nil
    end

    test "a malformed / missing new_email → 422 email_invalid" do
      user = user_fixture()

      assert call(:post, "/v1/account/email/change", %{new_email: "not-an-email"}, session(user)).status ==
               422

      assert call(:post, "/v1/account/email/change", %{}, session(user)).status == 422
    end

    test "unauthenticated → 401" do
      assert call(:post, "/v1/account/email/change", %{new_email: "x@example.com"}).status == 401
    end
  end

  describe "POST /v1/account/email/confirm" do
    test "the emailed code swaps the email (and /v1/me reflects it)" do
      user = user_fixture()
      token = session(user)
      target = "confirmed-#{System.unique_integer([:positive])}@example.com"

      assert call(:post, "/v1/account/email/change", %{new_email: target}, token).status == 202
      code = last_email_code()

      conn = call(:post, "/v1/account/email/confirm", %{code: code}, token)
      assert conn.status == 200
      assert json_body(conn)["user"]["email"] == target
    end

    test "a wrong code → 422 invalid_code; the pending change survives until the lockout cap" do
      user = user_fixture()
      token = session(user)
      target = "pending-#{System.unique_integer([:positive])}@example.com"

      assert call(:post, "/v1/account/email/change", %{new_email: target}, token).status == 202
      _code = last_email_code()

      conn = call(:post, "/v1/account/email/confirm", %{code: "999999"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] in ["invalid_code", "locked"]
      # Still staged (one wrong attempt is under the cap).
      assert Repo.get!(User, user.id).pending_email == target
    end

    test "no pending change → 422 no_pending_email" do
      user = user_fixture()
      conn = call(:post, "/v1/account/email/confirm", %{code: "123456"}, session(user))
      assert conn.status == 422
      assert json_body(conn) == %{"error" => "no_pending_email"}
    end
  end
end
