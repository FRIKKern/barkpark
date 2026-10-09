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

  ## The security-log exemption

  `audit_events` is append-only and its hash chain covers `metadata`, so a row
  cannot be rewritten or redacted at read without breaking external
  verification. Since owner ruling #32 item 2 (2026-10-03) no emitter writes a
  raw email into `metadata` — users are named by id (`grant.minted`,
  SCIM `user_provisioned`, `app_token_minted`). Rows written BEFORE that may
  still hold the subject's email; they are kept as written, under this
  exemption, as the integrity record of a security log.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Access.Grant
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
  Resolve the `actor_label` of `"user"` rows from the account, at READ time.

  Since owner ruling #32 item 1 (2026-10-03) a signed-in user's writes and paper
  views stamp `revisions` / `paper_access_log` with the user id only — no email
  at rest. Rows written before that still hold the email they were stamped
  with, and both tables are append-only (the history trail; the 90-day access
  trail), so erasure cannot rewrite them. Every read that serves those rows
  maps them through here: a `"user"` actor is shown under its account's
  CURRENT email — the pseudonymised one once the account is erased, so an old
  stamp never stays readable. Any other row (a token, a share, an anonymous
  reader) and a user row whose account no longer exists are returned unchanged.

  Takes and returns a list of maps/structs carrying `:actor_kind`, `:actor_id`,
  `:actor_label`. One query, however many rows.

  Prefers the account's `display_name` (task-cfb6ca3f5ffaf099, #22161) over
  its email — the same J15/J16 attribution preference Studio's own account
  settings exist to let a person set. An account with no display name (the
  pre-#22161 default, and `display_name_changeset/2`'s own trimmed-blank-to-
  nil normalization) falls back to email exactly as this function always
  resolved before #22161 existed.
  """
  #
  # An `"api_token"` row is named the same way through the token's owner
  # (`owner_user_id`): a member's app token writes history as that member
  # (task-d0c6a847e2a4658e). A token with no owner (a service token) stays
  # unlabelled.
  @spec redact_actor_labels([map()]) :: [map()]
  def redact_actor_labels(rows) when is_list(rows) do
    token_owners = token_owner_ids(actor_ids(rows, "api_token"))
    user_ids = Enum.uniq(actor_ids(rows, "user") ++ Map.values(token_owners))

    labels =
      case user_ids do
        [] ->
          %{}

        ids ->
          from(u in User, where: u.id in ^ids, select: {u.id, {u.display_name, u.email}})
          |> Repo.all()
          |> Map.new(fn {id, {display_name, email}} ->
            {id, preferred_label(display_name, email)}
          end)
      end

    if labels == %{} do
      rows
    else
      Enum.map(rows, fn row ->
        case label_owner(row, token_owners) do
          id when is_binary(id) ->
            case Map.fetch(labels, id) do
              {:ok, label} -> Map.put(row, :actor_label, label)
              :error -> row
            end

          _ ->
            row
        end
      end)
    end
  end

  defp preferred_label(display_name, email) when is_binary(display_name) do
    case String.trim(display_name) do
      "" -> email
      trimmed -> trimmed
    end
  end

  defp preferred_label(_display_name, email), do: email

  defp actor_ids(rows, kind) do
    rows
    |> Enum.flat_map(fn row ->
      case {Map.get(row, :actor_kind), Map.get(row, :actor_id)} do
        {^kind, id} when is_binary(id) -> List.wrap(Repo.uuid_or_nil(id))
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp token_owner_ids([]), do: %{}

  defp token_owner_ids(token_ids) do
    from(t in ApiToken,
      where: t.id in ^token_ids and not is_nil(t.owner_user_id),
      select: {t.id, t.owner_user_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The account whose email names this row: the user itself, or the owner of the
  # token it was written with.
  defp label_owner(%{actor_kind: "user", actor_id: id}, _owners) when is_binary(id), do: id

  defp label_owner(%{actor_kind: "api_token", actor_id: id}, owners) when is_binary(id),
    do: Map.get(owners, id)

  defp label_owner(_row, _owners), do: nil

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
      # Passkeys: the label and dates only. `credential_id`, `cose_key` and
      # `sign_count` are authenticator material, not the subject's data, and
      # are left out for the same reason a token hash is.
      passkeys:
        Repo.all(
          from c in WebauthnCredential,
            where: c.user_id == ^user.id,
            order_by: [asc: c.inserted_at]
        )
        |> Enum.map(fn c ->
          %{
            id: c.id,
            nickname: c.nickname,
            created_at: c.inserted_at,
            last_used_at: c.last_used_at
          }
        end),
      # Social-login links. `external_id` is the provider's id for the subject:
      # personal data we hold, and not a secret, since logging in with it still
      # takes authenticating at the provider. No provider tokens are stored.
      social_identities:
        Repo.all(
          from i in SocialIdentity,
            where: i.user_id == ^user.id,
            order_by: [asc: i.inserted_at]
        )
        |> Enum.map(fn i ->
          %{id: i.id, provider: i.provider, external_id: i.external_id, created_at: i.inserted_at}
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
        end),
      # Owner ruling #32 item 7 (2026-10-03): three more kinds of row that name
      # the subject. METADATA ONLY — what, where and when. A revision snapshot's
      # content is the workspace's data, not the subject's, and a grant's link
      # token hash is credential material.
      revisions: export_revisions(user),
      access_grants: export_grants(user),
      paper_access: export_paper_access(user)
    }
  end

  # Revisions the subject authored: stamped `actor_kind "user"` + their id, or
  # (history written before the kind/id columns) the legacy `actor_user_id`.
  defp export_revisions(%User{id: id}) do
    from(r in Barkpark.Content.Revision,
      where: (r.actor_kind == "user" and r.actor_id == ^id) or r.actor_user_id == ^id,
      order_by: [asc: r.inserted_at],
      select: %{
        id: r.id,
        workspace_id: r.workspace_id,
        project_id: r.project_id,
        dataset: r.dataset,
        type: r.type,
        doc_id: r.doc_id,
        action: r.action,
        rev: r.rev,
        created_at: r.inserted_at
      }
    )
    |> Repo.all()
  end

  # Grants made TO the subject — claimed (grantee_user_id) or addressed to their
  # email and not yet claimed.
  defp export_grants(%User{id: id, email: email}) do
    from(g in Grant,
      where: g.grantee_user_id == ^id or g.grantee_email == ^email,
      order_by: [asc: g.inserted_at],
      select: %{
        id: g.id,
        workspace_id: g.workspace_id,
        project_id: g.project_id,
        dataset: g.dataset,
        type: g.type,
        doc_id: g.doc_id,
        capabilities: g.capabilities,
        created_at: g.inserted_at,
        expires_at: g.expires_at,
        claimed_at: g.claimed_at,
        revoked_at: g.revoked_at
      }
    )
    |> Repo.all()
  end

  # The subject's entries in the 90-day paper access trail.
  defp export_paper_access(%User{id: id}) do
    from(a in Barkpark.Content.PaperAccessLog,
      where: a.actor_kind == "user" and a.actor_id == ^id,
      order_by: [asc: a.inserted_at],
      select: %{
        workspace_id: a.workspace_id,
        dataset: a.dataset,
        slug: a.slug,
        action: a.action,
        at: a.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Erase the subject: revoke all access, scrub PII (pseudonymise), and emit an
  audit event, in ONE transaction. Returns `{:ok, %{sessions_deleted,
  email_tokens_deleted, api_tokens_revoked, passkeys_deleted,
  social_identities_deleted, grants_pseudonymised, memberships_deleted}}`.

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
  naming the subject are rewritten to the pseudonym, and so are app-token labels
  (`app:<email>`). An app token minted FOR the subject carries their
  `owner_user_id` and is revoked; one minted before the mint stamped the owner
  is recognised by its `app:<email>` label (owner ruling #32 item 3). Machine
  tokens the subject minted for a workspace (no `owner_user_id`) are the
  workspace's credentials and are not revoked.
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

    # The app-token mint's default label carries the email; the revoked rows
    # keep their history under the pseudonym instead.
    Repo.update_all(from(t in ApiToken, where: t.label == ^("app:" <> user.email)),
      set: [label: "app:" <> erased_email]
    )

    grants_pseudonymised = pseudonymise_grants(user, erased_email)

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
        confirmed_at: nil,
        # task-cfb6ca3f5ffaf099/#22161 postdates this function: a display
        # name is free-text a person sets (often their real name), and
        # `redact_actor_labels/1` now PREFERS it over email. Leaving it
        # standing here would un-pseudonymise exactly the row this function
        # exists to pseudonymise — erasure clears it the same way it already
        # clears every other re-identifying field.
        display_name: nil
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
        "grants_pseudonymised" => grants_pseudonymised,
        "memberships_deleted" => memberships
      }
    })

    %{
      sessions_deleted: sessions,
      email_tokens_deleted: tokens,
      api_tokens_revoked: length(revoked_token_ids),
      passkeys_deleted: passkeys,
      social_identities_deleted: social_identities,
      grants_pseudonymised: grants_pseudonymised,
      memberships_deleted: memberships,
      revoked_token_ids: revoked_token_ids
    }
  end

  # Access grants addressed to the subject: `grantee_email` is rewritten to the
  # pseudonym, and the row is kept.
  #
  # Kept, not deleted: the grant is the GRANTOR's record of what they shared,
  # and the `grant.*` audit events name it by id. Pseudonymising is also what
  # closes a PENDING grant. Claiming requires the claimant's email to equal
  # `grantee_email` and a confirmed account (`Access.ClaimFlow`). Left alone,
  # the invitation would stay open to whoever registers that address next, and
  # access the grantor gave the erased subject would pass to that new account.
  # After the rewrite the only matching account is the erased row, which has no
  # credential and no `confirmed_at`, so the grant can never be claimed. The
  # grantor sees it addressed to an erased account and can revoke it.
  #
  # Matched on the email case-insensitively (it is not normalised at mint, and
  # `ClaimFlow.grantee?/2` compares downcased) and on `grantee_user_id`, which
  # covers a claimed grant whose address differs from the current email.
  defp pseudonymise_grants(%User{id: user_id, email: email}, erased_email) do
    email = String.downcase(email)

    {n, _} =
      Repo.update_all(
        from(g in Grant,
          where: fragment("lower(?)", g.grantee_email) == ^email or g.grantee_user_id == ^user_id
        ),
        set: [grantee_email: erased_email]
      )

    n
  end

  # Every not-yet-revoked token the subject owns, any kind, through the one
  # audited revoke primitive. A failed revoke rolls the whole erasure back: a
  # half-erased subject with a live token is the defect this exists to close.
  @doc """
  Hand an UNCONFIRMED account to the person who just proved they own its email
  (a provider-verified social login, or an org SSO login for a verified
  domain), stripping every credential the PRIOR holder could have set
  (task-0abbf88fd420360d).

  Registration does not require confirming the email before password login,
  so anyone can register `victim@example.com`, set a password, and add a
  passkey or token. Adopting that account for the real owner must not leave
  the squatter in control. Mirrors the cloud fix (task-b3eb09e83fbb7cbc):
  the password becomes unknowable, sessions, pending email tokens, passkeys,
  prior social links and owned API tokens are removed or revoked, TOTP is
  cleared, and the account is confirmed. Memberships are kept. A CONFIRMED
  account is returned untouched.
  """
  @spec reclaim_unconfirmed(User.t()) :: {:ok, User.t()} | {:error, term()}
  def reclaim_unconfirmed(%User{confirmed_at: %{}} = user), do: {:ok, user}

  def reclaim_unconfirmed(%User{} = user) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(from s in UserSession, where: s.user_id == ^user.id)
        Repo.delete_all(from t in UserEmailToken, where: t.user_id == ^user.id)
        Repo.delete_all(from c in WebauthnCredential, where: c.user_id == ^user.id)
        Repo.delete_all(from i in SocialIdentity, where: i.user_id == ^user.id)
        revoked = revoke_owned_tokens!(user)

        reclaimed =
          user
          |> Ecto.Changeset.change(%{
            hashed_password: Argon2.hash_pwd_salt(Base.encode16(:crypto.strong_rand_bytes(32))),
            totp_secret: nil,
            totp_enabled: false,
            recovery_codes_hashed: [],
            last_totp_at: nil,
            confirmed_at: DateTime.utc_now()
          })
          |> Repo.update!()

        Audit.emit(%{
          category: "auth",
          action: "unconfirmed_account_reclaimed",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"api_tokens_revoked" => length(revoked)}
        })

        {reclaimed, revoked}
      end)

    case result do
      {:ok, {reclaimed, revoked_ids}} ->
        Enum.each(revoked_ids, &Auth.broadcast_socket_teardown(%ApiToken{id: &1}))
        {:ok, reclaimed}

      other ->
        other
    end
  end

  @doc """
  Remove the credentials a session thief could have ADDED to an account:
  every passkey, every social login link, and every live personal API token
  the user owns (`kind: "api"`, `owner_user_id` = the user). Runs inside the
  caller's transaction; a failed token revoke rolls it back. Returns the
  revoked token ids so the caller can tear their sockets down AFTER commit
  (`Auth.broadcast_socket_teardown/1`).

  Owner ruling #13 (task-f4cfc3e2ab4bd6b8): a forgot-password reset calls this,
  so a passkey or personal token an attacker added with a stolen session does
  not survive the owner's recovery. Tokens nobody owns (machine tokens, the
  credential Barkpark Cloud holds for the instance) are never touched, and
  ticket keys stay with the outsiders they were issued to.
  """
  @spec strip_added_credentials!(User.t()) :: %{
          passkeys: non_neg_integer(),
          social_links: non_neg_integer(),
          revoked_token_ids: [binary()]
        }
  def strip_added_credentials!(%User{id: user_id} = user) do
    {passkeys, _} = Repo.delete_all(from c in WebauthnCredential, where: c.user_id == ^user_id)
    {links, _} = Repo.delete_all(from i in SocialIdentity, where: i.user_id == ^user_id)

    %{
      passkeys: passkeys,
      social_links: links,
      revoked_token_ids: revoke_owned_tokens!(user, kind: "api")
    }
  end

  # The subject's credentials: tokens they own, plus LEGACY app tokens minted
  # for them before the mint stamped `owner_user_id` (owner ruling #32 item 3,
  # 2026-10-03) — recognised by the mint's own default label, `app:<email>`,
  # with no owner. A custom-labelled legacy token cannot be told apart from a
  # workspace credential and is left alone. `kind:` narrows the set (the reset
  # path of ruling #13 revokes personal `api` tokens only).
  defp revoke_owned_tokens!(user, opts \\ [])

  defp revoke_owned_tokens!(%User{id: user_id, email: email}, opts) do
    app_label = "app:" <> email

    base =
      from(t in ApiToken,
        where:
          is_nil(t.revoked_at) and
            (t.owner_user_id == ^user_id or (is_nil(t.owner_user_id) and t.label == ^app_label))
      )

    query =
      case Keyword.get(opts, :kind) do
        nil -> base
        kind -> from(t in base, where: t.kind == ^kind)
      end

    query
    |> Repo.all()
    |> Enum.map(fn token ->
      case Auth.revoke_token(token) do
        {:ok, revoked} -> revoked.id
        {:error, reason} -> Repo.rollback({:token_revoke_failed, token.id, reason})
      end
    end)
  end
end
