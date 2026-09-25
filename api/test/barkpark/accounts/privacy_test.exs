defmodule Barkpark.Accounts.PrivacyTest do
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  # TOTP codes come from the window-stable helper ONLY — a code minted inline
  # can expire in the gap before the server validates it (honest-gates S1).
  import Barkpark.TotpTestHelper

  alias Barkpark.Accounts
  alias Barkpark.Accounts.{Privacy, User, UserSession, UserEmailToken}
  alias Barkpark.Audit
  alias Barkpark.Audit.Event
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Accounts.WebauthnCredential
  alias Barkpark.Sso.SocialIdentity
  alias Barkpark.Access
  alias Barkpark.Access.{ClaimFlow, Grant}
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Repo
  import Ecto.Query

  @password "correct-horse-battery"

  defp subject(email \\ "subject@example.com") do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # A token row inserted directly, so expiry and ownership can be set freely.
  defp token_row!(attrs) do
    raw = "priv-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{token_hash: ApiToken.hash_token(raw), label: "t", permissions: ["read"]},
          attrs
        )
      )
      |> Repo.insert()

    {raw, token}
  end

  # An api-token grantor seated as admin in `ws`, and a grant it mints to `email`.
  defp grant_to!(ws, email) do
    {:ok, grantor} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("g-" <> Ecto.UUID.generate()),
        label: "grantor",
        permissions: ["read"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, grantor.id, "admin", "api_token")

    {:ok, %{grant: grant, token: raw}} =
      Access.mint(grantor, %{grantee_email: email, workspace_id: ws.id, capabilities: ["read"]})

    {grant, raw}
  end

  describe "export_subject/1" do
    test "lists passkeys and social identities with non-secret fields only" do
      user = subject("export-creds@example.com")

      pk =
        Repo.insert!(%WebauthnCredential{
          user_id: user.id,
          credential_id: :crypto.strong_rand_bytes(16),
          cose_key: :erlang.term_to_binary(%{-2 => "x", -3 => "y"}),
          nickname: "yubikey"
        })

      si =
        Repo.insert!(%SocialIdentity{user_id: user.id, provider: "github", external_id: "gh-77"})

      # another user's rows stay out of this export
      other = subject("export-creds-other@example.com")

      Repo.insert!(%WebauthnCredential{
        user_id: other.id,
        credential_id: :crypto.strong_rand_bytes(16),
        cose_key: :erlang.term_to_binary(%{}),
        nickname: "theirs"
      })

      export = Privacy.export_subject(user)

      assert [p] = export.passkeys
      assert Map.keys(p) |> Enum.sort() == [:created_at, :id, :last_used_at, :nickname]
      assert p.id == pk.id
      assert p.nickname == "yubikey"

      assert [i] = export.social_identities
      assert Map.keys(i) |> Enum.sort() == [:created_at, :external_id, :id, :provider]
      assert i.id == si.id
      assert i.provider == "github"

      # the export is JSON-encodable (the HTTP surface renders it) and carries
      # no authenticator material
      encoded = Jason.encode!(export)
      refute encoded =~ Base.encode64(pk.credential_id)
      refute encoded =~ Base.encode64(pk.cose_key)
    end

    test "lists the subject's own API tokens by id and name only — no hash or secret" do
      user = subject("export-tokens@example.com")

      {:ok, {raw, pat}} =
        Auth.create_personal_access_token("laptop", ["read"],
          owner_user_id: user.id,
          created_by: user.email
        )

      # someone else's token is not in this subject's export
      other = subject("export-other@example.com")

      {:ok, {_, _}} =
        Auth.create_personal_access_token("theirs", ["read"], owner_user_id: other.id)

      export = Privacy.export_subject(user)

      assert [row] = export.api_tokens
      assert row.id == pat.id
      assert row.name == "laptop"
      assert Map.keys(row) |> Enum.sort() == [:created_at, :expires_at, :id, :name, :revoked_at]

      encoded = Jason.encode!(export)
      refute encoded =~ raw
      refute encoded =~ pat.token_hash
    end

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
        Accounts.enable_totp(user, secret, totp_code_stable!(secret))

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

    test "revokes every API token the subject owns, in the audited revoke path" do
      user = subject("erase-tokens@example.com")

      {:ok, {raw_pat, pat}} =
        Auth.create_personal_access_token("cli", ["read"],
          owner_user_id: user.id,
          created_by: user.email
        )

      # an owned token already past its expiry: revoked too, so the record is final
      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      {_raw_old, old} = token_row!(%{owner_user_id: user.id, expires_at: past})

      # a machine token the subject minted for a workspace: not theirs to lose,
      # but it must stop naming them
      {raw_machine, machine} = token_row!(%{created_by: user.email})

      # another user's token is untouched
      other = subject("erase-bystander@example.com")

      {:ok, {raw_other, _}} =
        Auth.create_personal_access_token("x", ["read"], owner_user_id: other.id)

      assert {:ok, %ApiToken{}} = Auth.verify_token(raw_pat)

      assert {:ok, summary} = Privacy.erase_subject(user)
      assert summary.api_tokens_revoked == 2
      refute Map.has_key?(summary, :revoked_token_ids)

      assert {:error, :unauthorized} = Auth.verify_token(raw_pat)
      assert %DateTime{} = Repo.get!(ApiToken, pat.id).revoked_at
      assert %DateTime{} = Repo.get!(ApiToken, old.id).revoked_at

      assert {:ok, _} = Auth.verify_token(raw_machine)
      assert Repo.get!(ApiToken, machine.id).created_by == "erased-#{user.id}@erased.invalid"
      assert Repo.get!(ApiToken, pat.id).created_by == "erased-#{user.id}@erased.invalid"
      assert {:ok, _} = Auth.verify_token(raw_other)

      # one token_revoked audit row per revoked token, from the shared primitive
      revoked_subjects =
        Repo.all(from e in Event, where: e.action == "token_revoked", select: e.subject)

      assert pat.id in revoked_subjects
      assert old.id in revoked_subjects

      # the erasure event counts them and carries no token material
      ev =
        Repo.one(from e in Event, where: e.action == "subject_erased" and e.actor_id == ^user.id)

      assert ev.metadata["api_tokens_revoked"] == 2
      metadata = Jason.encode!(ev.metadata)
      refute metadata =~ raw_pat
      refute metadata =~ pat.token_hash
      refute metadata =~ pat.id
      assert :ok == Audit.verify_chain(nil)
    end

    test "deletes passkeys and social-login links, which log in without a password" do
      user = subject("erase-creds@example.com")

      Repo.insert!(%WebauthnCredential{
        user_id: user.id,
        credential_id: :crypto.strong_rand_bytes(16),
        cose_key: :erlang.term_to_binary(%{}),
        nickname: "yubikey"
      })

      Repo.insert!(%SocialIdentity{user_id: user.id, provider: "google", external_id: "g-erase"})

      assert {:ok, summary} = Privacy.erase_subject(user)
      assert summary.passkeys_deleted == 1
      assert summary.social_identities_deleted == 1

      assert Repo.aggregate(from(c in WebauthnCredential, where: c.user_id == ^user.id), :count) ==
               0

      assert Repo.aggregate(from(i in SocialIdentity, where: i.user_id == ^user.id), :count) == 0
    end

    test "grants addressed to the subject lose the email and cannot be claimed by a new account at it" do
      ws = create_workspace!()
      user = subject("grant-me@example.com")
      user = Accounts.confirm_provisioned_user(user)

      # a pending grant, addressed with different casing (not normalised at mint)
      {pending, pending_raw} = grant_to!(ws, "Grant-Me@Example.com")
      # a grant the subject already claimed
      {claimed, claimed_raw} = grant_to!(ws, "grant-me@example.com")
      assert {:ok, _} = ClaimFlow.resolve(claimed_raw, user)
      # a bystander's grant is untouched
      {bystander, _} = grant_to!(ws, "someone-else@example.com")

      assert {:ok, summary} = Privacy.erase_subject(user)

      # Whoever registers the old address next must not inherit the invitation.
      {:ok, newcomer} =
        Accounts.register_user(%{email: "grant-me@example.com", password: @password})

      newcomer = Accounts.confirm_provisioned_user(newcomer)
      assert :invalid == ClaimFlow.resolve(pending_raw, newcomer)
      assert is_nil(Repo.get!(Grant, pending.id).claimed_at)

      assert Repo.aggregate(
               from(g in Grant,
                 where: fragment("lower(?)", g.grantee_email) == "grant-me@example.com"
               ),
               :count
             ) == 0

      erased = "erased-#{user.id}@erased.invalid"
      assert Repo.get!(Grant, pending.id).grantee_email == erased
      assert Repo.get!(Grant, claimed.id).grantee_email == erased
      assert Repo.get!(Grant, bystander.id).grantee_email == "someone-else@example.com"
      assert summary.grants_pseudonymised == 2

      ev =
        Repo.one(from e in Event, where: e.action == "subject_erased" and e.actor_id == ^user.id)

      assert ev.metadata["grants_pseudonymised"] == 2
    end
  end
end
