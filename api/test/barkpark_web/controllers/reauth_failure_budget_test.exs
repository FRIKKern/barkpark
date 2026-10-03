defmodule BarkparkWeb.ReauthFailureBudgetTest do
  @moduledoc """
  Owner ruling #34 item 1 (2026-10-03, task-d9e8f02056e39763): one per-user
  password re-check budget, shared by every door that asks a signed-in user for
  the current password — erase, password change, TOTP enrol/verify/disable,
  passkey add and remove, and Studio's erase form.

  Before, only Studio's erase form counted wrong passwords. A session holder
  could guess the account password through `POST /v1/auth/mfa/enroll` (or any
  other JSON re-check) at the general per-IP rate. Now five attempts, refilled
  at one a minute, cover all of them together: past the budget even the right
  password is refused with `429 reauth_rate_limited`, and nothing changes.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Repo

  @password "correct-horse-battery"

  defp user_with_session! do
    email = "reauth-budget-#{System.unique_integer([:positive])}@example.test"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp authed(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp spend_budget_with_wrong_passwords!(token) do
    for n <- 1..5 do
      conn =
        authed(token) |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: "wrong-#{n}"}))

      refute_rate_limited!(conn)
      assert conn.status == 403, "wrong password #{n} answered #{conn.status}: #{conn.resp_body}"
    end
  end

  describe "Accounts.reauthenticate/2" do
    test "the right password passes; a wrong one is :invalid_password" do
      {user, _token} = user_with_session!()

      assert Accounts.reauthenticate(user, @password) == :ok
      assert Accounts.reauthenticate(user, "nope") == {:error, :invalid_password}
      assert Accounts.reauthenticate(user, nil) == {:error, :invalid_password}
      assert Accounts.reauthenticate(user, "") == {:error, :invalid_password}
    end

    test "after five attempts even the right password is refused" do
      {user, _token} = user_with_session!()

      for _ <- 1..5,
          do: assert(Accounts.reauthenticate(user, "nope") == {:error, :invalid_password})

      assert Accounts.reauthenticate(user, @password) == {:error, :reauth_rate_limited}
    end

    test "the budget is per user: one account's guesses do not lock another" do
      {victim, _} = user_with_session!()
      {other, _} = user_with_session!()

      for _ <- 1..5, do: Accounts.reauthenticate(victim, "nope")

      assert Accounts.reauthenticate(other, @password) == :ok
    end
  end

  describe "the budget is shared across every re-check door" do
    test "guesses on mfa/enroll exhaust erase, password change, mfa/disable and passkey doors" do
      {user, token} = user_with_session!()
      spend_budget_with_wrong_passwords!(token)

      doors = [
        {:post, "/v1/auth/erase", %{password: @password}},
        {:patch, "/v1/auth/password",
         %{current_password: @password, password: "a-brand-new-password"}},
        {:post, "/v1/auth/mfa/enroll", %{password: @password}},
        {:post, "/v1/auth/mfa/disable", %{password: @password}},
        {:post, "/v1/auth/webauthn/register/challenge", %{password: @password}},
        {:delete, "/v1/auth/webauthn/credentials/00000000-0000-0000-0000-000000000000",
         %{password: @password}}
      ]

      for {method, path, body} <- doors do
        conn = dispatch(authed(token), @endpoint, method, path, Jason.encode!(body))

        assert conn.status == 429,
               "#{method} #{path} answered #{conn.status} past the budget: #{conn.resp_body}"

        assert %{"error" => %{"code" => "reauth_rate_limited"}} = Jason.decode!(conn.resp_body)
      end

      # Nothing changed: the account is not erased and the password still works.
      reloaded = Repo.get!(User, user.id)
      assert reloaded.email == user.email
      assert User.valid_password?(reloaded, @password)
    end

    test "Studio's erase form draws on the same budget" do
      {user, token} = user_with_session!()
      spend_budget_with_wrong_passwords!(token)

      assert Accounts.reauthenticate(user, @password) == {:error, :reauth_rate_limited}
    end
  end

  describe "the legitimate path still works" do
    test "a typo, then the right password, enrols TOTP" do
      {_user, token} = user_with_session!()

      wrong = authed(token) |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: "typo"}))
      assert wrong.status == 403

      right = authed(token) |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: @password}))
      assert right.status == 200
      assert json_response(right, 200)["otpauth_uri"] =~ "otpauth://"
    end

    test "a password change with the right current password succeeds" do
      {user, token} = user_with_session!()

      conn =
        authed(token)
        |> patch(
          "/v1/auth/password",
          Jason.encode!(%{current_password: @password, password: "a-brand-new-password"})
        )

      assert json_response(conn, 200) == %{"ok" => true}
      assert User.valid_password?(Repo.get!(User, user.id), "a-brand-new-password")
    end
  end
end
