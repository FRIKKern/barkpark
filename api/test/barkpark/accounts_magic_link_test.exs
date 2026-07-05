defmodule Barkpark.AccountsMagicLinkTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.UserEmailToken
  alias Barkpark.Repo
  import Ecto.Query

  @password "correct-horse-battery"

  defp user(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  describe "build_login_token/1" do
    test "returns {:ok, plaintext, user} for a known email and stores only the hash" do
      u = user("magic@example.com")
      assert {:ok, plaintext, got} = Accounts.build_login_token("magic@example.com")
      assert got.id == u.id
      assert is_binary(plaintext)

      row = Repo.one(from t in UserEmailToken, where: t.context == "login")
      assert row.token_hash == UserEmailToken.hash_token(plaintext)
      assert row.token_hash != plaintext
      assert row.sent_to == "magic@example.com"
    end

    test "returns :no_user for an unknown email (no token written)" do
      assert :no_user = Accounts.build_login_token("nobody@example.com")
      assert Repo.aggregate(from(t in UserEmailToken, where: t.context == "login"), :count) == 0
    end

    test "is case-insensitive on the email (matches registration lower-casing)" do
      user("Case@Example.com")
      assert {:ok, _pt, _u} = Accounts.build_login_token("case@example.com")
    end
  end

  describe "consume_login_token/1" do
    test "consumes a valid token once and returns the user" do
      u = user("consume@example.com")
      {:ok, plaintext, _} = Accounts.build_login_token("consume@example.com")

      assert {:ok, got} = Accounts.consume_login_token(plaintext)
      assert got.id == u.id
      # single-use: the row is gone, a second consume fails indistinguishably
      assert :error = Accounts.consume_login_token(plaintext)
    end

    test "unknown, malformed, and expired tokens are all :error (no oracle)" do
      assert :error = Accounts.consume_login_token("never-issued")
      assert :error = Accounts.consume_login_token(["not", "a", "string"])

      u = user("expired@example.com")
      {:ok, plaintext, _} = Accounts.build_login_token("expired@example.com")
      # Force expiry.
      Repo.update_all(
        from(t in UserEmailToken, where: t.context == "login" and t.user_id == ^u.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert :error = Accounts.consume_login_token(plaintext)
    end

    test "a login token cannot drive a reset, and a reset token cannot drive a login" do
      u = user("cross@example.com")
      {:ok, login_pt, _} = Accounts.build_login_token("cross@example.com")
      {:ok, reset_pt} = Accounts.build_email_token(u, "reset")

      # login token is not a reset token
      assert :error = Accounts.reset_user_password(login_pt, %{password: "another-good-pass"})
      # reset token is not a login token
      assert :error = Accounts.consume_login_token(reset_pt)
    end
  end
end
