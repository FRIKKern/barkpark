defmodule Barkpark.Accounts.Privacy do
  @moduledoc """
  GDPR data-subject rights for a User: a machine-readable **data export**
  (right of access) and **right-to-erasure**.

  Erasure is **pseudonymisation, not row-deletion**: the subject's PII is
  scrubbed (email anonymised; password, TOTP secret and recovery codes cleared;
  confirmation dropped) and all access is revoked (sessions, email tokens, and
  workspace memberships deleted), but the user row is retained so the
  append-only, tamper-evident audit trail (`Barkpark.Audit`) stays intact — the
  balance GDPR strikes between erasure of personal data and the integrity of a
  security log. Every erasure emits an audit event.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Audit
  alias Barkpark.Repo
  alias Barkpark.Accounts.{User, UserSession, UserEmailToken}
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
  audit event. Returns `{:ok, %{sessions_deleted, email_tokens_deleted,
  memberships_deleted}}`.
  """
  @spec erase_subject(User.t()) :: {:ok, map()} | {:error, term()}
  def erase_subject(%User{} = user) do
    Repo.transaction(fn ->
      {sessions, _} =
        Repo.delete_all(from s in UserSession, where: s.user_id == ^user.id)

      {tokens, _} =
        Repo.delete_all(from t in UserEmailToken, where: t.user_id == ^user.id)

      {memberships, _} =
        Repo.delete_all(
          from m in Membership,
            where: m.principal_type == "user" and m.principal_id == ^user.id
        )

      _erased =
        user
        |> Ecto.Changeset.change(%{
          email: "erased-#{user.id}@#{@erased_domain}",
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
        metadata: %{
          "pseudonymised" => true,
          "sessions_deleted" => sessions,
          "memberships_deleted" => memberships
        }
      })

      %{
        sessions_deleted: sessions,
        email_tokens_deleted: tokens,
        memberships_deleted: memberships
      }
    end)
  end
end
