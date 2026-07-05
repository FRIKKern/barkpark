defmodule Barkpark.Accounts.PrivacyTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.{Privacy, User, UserSession, UserEmailToken}
  alias Barkpark.Audit
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Repo
  import Ecto.Query

  @password "correct-horse-battery"

  defp subject(email \\ "subject@example.com") do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  describe "export_subject/1" do
    test "returns the account + related data, without secret material" do
      user = subject()
      {:ok, _token} = Accounts.create_user_session_token(user)
      {:ok, ws} = Tenancy.create_workspace(%{slug: "priv-ws", name: "WS"})
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      export = Privacy.export_subject(user)

      assert export.account.id == user.id
      assert export.account.email == "subject@example.com"
      assert length(export.sessions) == 1
      assert [%{workspace_id: _, role: "member"}] = export.memberships
      # never leak credentials
      refute Map.has_key?(export.account, :hashed_password)
      assert Enum.all?(export.sessions, &(not Map.has_key?(&1, :token_hash)))
    end
  end

  describe "erase_subject/1" do
    test "scrubs PII, revokes access, retains the row, and audits" do
      user = subject("erase-me@example.com")
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.build_email_token(user, "reset")
      {:ok, ws} = Tenancy.create_workspace(%{slug: "erase-ws", name: "WS"})
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
      # arm MFA so we can prove it's cleared
      secret = Accounts.totp_secret()

      {:ok, _user, _codes} =
        Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      user = Accounts.get_user(user.id)
      assert {:ok, summary} = Privacy.erase_subject(user)

      assert summary.sessions_deleted == 1
      assert summary.memberships_deleted == 1
      assert summary.email_tokens_deleted == 1

      # access revoked
      assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 0
      assert Repo.aggregate(from(t in UserEmailToken, where: t.user_id == ^user.id), :count) == 0

      assert Repo.aggregate(
               from(m in Membership,
                 where: m.principal_type == "user" and m.principal_id == ^user.id
               ),
               :count
             ) == 0

      # PII scrubbed, row retained
      erased = Accounts.get_user(user.id)
      assert erased != nil
      assert erased.email == "erased-#{user.id}@erased.invalid"
      assert erased.totp_enabled == false
      assert is_nil(erased.confirmed_at)
      refute User.valid_password?(erased, @password)

      # audited on the tamper-evident trail
      ev =
        Repo.one(from e in Event, where: e.action == "subject_erased" and e.actor_id == ^user.id)

      assert ev.category == "auth"
      assert ev.metadata["pseudonymised"] == true
      assert :ok == Audit.verify_chain(nil)
    end
  end
end
