defmodule Barkpark.Accounts.Privacy do
  @moduledoc """
  GDPR data-subject rights for a User: a machine-readable **data export**
  (right of access) and **right-to-erasure**.

  Erasure is **pseudonymisation, not row-deletion**: the subject's PII is
  scrubbed (email anonymised; password, TOTP secret and recovery codes cleared;
  confirmation dropped) and all access is revoked — sessions, email tokens,
  passkeys, social-login links and workspace memberships deleted, and every
  API token the subject owns (`owner_user_id`) revoked through
  `Barkpark.Auth.revoke_token/1` — but the user row is retained so the
  append-only, tamper-evident audit trail (`Barkpark.Audit`) stays intact — the
  balance GDPR strikes between erasure of personal data and the integrity of a
  security log. Every erasure emits an audit event.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Audit
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Accounts.{User, UserSession, UserEmailToken, WebauthnCredential}
  alias Barkpark.Sso.SocialIdentity
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Audit.Event

  @erased_domain "erased.invalid"

  @doc """
  Assemble the subject's complete, machine-readable data bundle. Deliberately
  omits secret material (no password hash, session/token hashes, or TOTP secret)
  — it is the subject's *data*, not their credentials.
  """
  @spec export_subject(User.t()) :: map()
  def export_subject(%User{} = user) do
    %{
      exported_at: DateTime.utc_now(),
      account: %{
        id: user.id,
        email: user.email,
        confirmed_at: user.confirmed_at,
        mfa_enabled: user.totp_enabled,
        created_at: user.inserted_at,
        updated_at: user.updated_at
      },
      sessions:
        Repo.all(from s in UserSession, where: s.user_id == ^user.id)
        |> Enum.map(fn s ->
          %{
            id: s.id,
            context: s.context,
            created_at: s.inserted_at,
            last_used_at: s.last_used_at,
            expires_at: s.expires_at,
            revoked_at: s.revoked_at,
            ip_address: s.ip_address,
            # Stored alongside the address, so exported too: a subject-access
            # export that omits a column we hold is an incomplete export, and
            # without it `ip_address` is ambiguous between a derived client
            # address and the raw peer. NULL on rows minted before the trust
            # boundary existed.
            ip_source: s.ip_source,
            user_agent: s.user_agent
          }
        end),
      email_tokens:
        Repo.all(from t in UserEmailToken, where: t.user_id == ^user.id)
        |> Enum.map(fn t ->
          %{
            context: t.context,
            sent_to: t.sent_to,
            expires_at: t.expires_at,
            created_at: t.inserted_at
          }
        end),
      # Tokens the subject OWNS. Ids and names only, plus lifecycle dates: the
      # hash is credential material, and `label`/`created_by` are internal
      # breadcrumbs, not the subject's data.
      api_tokens:
        Repo.all(
          from t in ApiToken, where: t.owner_user_id == ^user.id, order_by: [asc: t.inserted_at]
        )
        |> Enum.map(fn t ->
          %{
            id: t.id,
            name: t.name,
            created_at: t.inserted_at,
            expires_at: t.expires_at,
            revoked_at: t.revoked_at
          }
        end),
      memberships:
        Repo.all(
          from m in Membership,
            where: m.principal_type == "user" and m.principal_id == ^user.id
        )
        |> Enum.map(fn m ->
          %{workspace_id: m.workspace_id, role: m.role, created_at: m.inserted_at}
        end),
      audit_events:
        Repo.all(from e in Event, where: e.actor_id == ^user.id, order_by: [asc: e.id])
        |> Enum.map(fn e ->
          %{
            category: e.category,
            action: e.action,
            subject: e.subject,
            workspace_id: e.workspace_id,
            occurred_at: e.occurred_at,
            metadata: e.metadata
          }
        end)
    }
  end

  @doc """
  Erase the subject: revoke all access, scrub PII (pseudonymise), and emit an
  audit event, in ONE transaction. Returns `{:ok, %{sessions_deleted,
  email_tokens_deleted, api_tokens_revoked, passkeys_deleted,
  social_identities_deleted, memberships_deleted}}`.

  Access that outlives a password and a session, and so must go here too:

    * **API tokens the subject owns** (`owner_user_id`) — revoked, not deleted,
      through `Auth.revoke_token/1`, so each gets its `token_revoked` audit row
      and its open sockets are told to disconnect. `verify_token/1` reads the
      row on every request (there is no verify cache), so the next request
      with such a token is a 401. Expired and in-rotation-grace tokens are
      included: revoking them makes the record final.
    * **Passkeys** — `/v1/auth/webauthn/login` resolves a credential to its
      user with no password, so a surviving passkey is a full login.
    * **Social-login links** — a known `(provider, external_id)` re-logs the
      linked account with no email check, so it would log straight back in.

  `api_tokens.created_by` holds the email of whoever minted the token; rows
  naming the subject are rewritten to the pseudonym. Machine tokens the subject
  minted for a workspace (no `owner_user_id`) are the workspace's credentials
  and are not revoked.
  """
  @spec erase_subject(User.t()) :: {:ok, map()} | {:error, term()}
  def erase_subject(%User{} = user) do
    result = Repo.transaction(fn -> do_erase(user) end)

    # `revoke_token/1` broadcasts the socket teardown inside the transaction,
    # before the revoke is visible to other connections. A socket that connects
    # in that gap verifies a still-live row and would stay up, so the teardown
    # is sent again once the revoke is committed.
    with {:ok, %{revoked_token_ids: ids}} <- result do
      Enum.each(ids, &Auth.broadcast_socket_teardown(%ApiToken{id: &1}))
    end

    case result do
      {:ok, summary} -> {:ok, Map.delete(summary, :revoked_token_ids)}
      other -> other
    end
  end

  defp do_erase(%User{} = user) do
    {sessions, _} =
      Repo.delete_all(from s in UserSession, where: s.user_id == ^user.id)

    {tokens, _} =
      Repo.delete_all(from t in UserEmailToken, where: t.user_id == ^user.id)

    revoked_token_ids = revoke_owned_tokens!(user)

    {passkeys, _} =
      Repo.delete_all(from c in WebauthnCredential, where: c.user_id == ^user.id)

    {social_identities, _} =
      Repo.delete_all(from i in SocialIdentity, where: i.user_id == ^user.id)

    erased_email = "erased-#{user.id}@#{@erased_domain}"

    Repo.update_all(from(t in ApiToken, where: t.created_by == ^user.email),
      set: [created_by: erased_email]
    )

    {memberships, _} =
      Repo.delete_all(
        from m in Membership,
          where: m.principal_type == "user" and m.principal_id == ^user.id
      )

    _erased =
      user
      |> Ecto.Changeset.change(%{
        email: erased_email,
        # An unknowable Argon2 hash — no password can ever verify against it.
        hashed_password: Argon2.hash_pwd_salt(Base.encode16(:crypto.strong_rand_bytes(32))),
        totp_secret: nil,
        totp_enabled: false,
        recovery_codes_hashed: [],
        last_totp_at: nil,
        confirmed_at: nil
      })
      |> Repo.update!()

    Audit.emit(%{
      category: "auth",
      action: "subject_erased",
      subject: user.id,
      actor_type: "user",
      actor_id: user.id,
      # Counts only — never a token value, hash or id list.
      metadata: %{
        "pseudonymised" => true,
        "sessions_deleted" => sessions,
        "api_tokens_revoked" => length(revoked_token_ids),
        "passkeys_deleted" => passkeys,
        "social_identities_deleted" => social_identities,
        "memberships_deleted" => memberships
      }
    })

    %{
      sessions_deleted: sessions,
      email_tokens_deleted: tokens,
      api_tokens_revoked: length(revoked_token_ids),
      passkeys_deleted: passkeys,
      social_identities_deleted: social_identities,
      memberships_deleted: memberships,
      revoked_token_ids: revoked_token_ids
    }
  end

  # Every not-yet-revoked token the subject owns, any kind, through the one
  # audited revoke primitive. A failed revoke rolls the whole erasure back: a
  # half-erased subject with a live token is the defect this exists to close.
  defp revoke_owned_tokens!(%User{id: user_id}) do
    from(t in ApiToken, where: t.owner_user_id == ^user_id and is_nil(t.revoked_at))
    |> Repo.all()
    |> Enum.map(fn token ->
      case Auth.revoke_token(token) do
        {:ok, revoked} -> revoked.id
        {:error, reason} -> Repo.rollback({:token_revoke_failed, token.id, reason})
      end
    end)
  end
end
