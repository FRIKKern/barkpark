defmodule BarkparkCloud.Accounts do
  @moduledoc """
  The Cloud identity context — Users, Teams, and the membership binding
  between them, plus email+password authentication.

  This is what makes "one login for all your Barkparks" real: a single User
  authenticates here, and Team memberships fan that identity out across the
  control plane. Scope is deliberately narrow (YAGNI):

    * email + password — no OAuth yet. A single-use, enumeration-safe
      password-reset flow lives here (`request_password_reset/1` +
      `reset_password_by_token/2`), alongside the session-token and PAT lifecycles
      below.

  Authentication entry points:

    * `register_user/1` — create a User from attrs (hashes the password).
    * `get_user_by_email_and_password/2` — verify a login, timing-safe.
    * `get_or_create_user_from_oauth/1` — resolve (or birth) a User from a
      VERIFIED external identity (oauth-sso), keyed on `(provider, provider_uid)`
      — never email — so a second IdP can never take over an account by asserting
      its email (Coolify's `OauthController.php` footgun). A birthed OAuth user
      gets the SAME entitlement chain as a password signup: team + owner
      membership + a self-serve trial + notification settings, in one transaction.

  Account lifecycle (email-verification-recovery), all riding the polymorphic
  `user_tokens.context`:

    * confirm — `deliver_user_confirmation_instructions/1`, `confirm_user/1`
      (single-use `"confirm"` token, 7-day validity).
    * verified email change — `deliver_user_update_email_instructions/2` (a
      6-digit code to the NEW address, enumeration-safe) and `update_user_email/2`
      (proves the code, swaps the email, fail-soft billing sync). A hard per-user
      wrong-code lockout (`failed_attempts`) backs the short code.

  Session lifecycle (cloud account-sessions): sessions are revocable tokens.
  `create_user_session_token/2` mints (capturing device metadata),
  `verify_user_session_token/1` resolves a live one, and the kill switches —
  `revoke_user_session_token/1` (one device), `revoke_user_session/2` (one row),
  `revoke_all_user_sessions/2` ("sign out everywhere") — stamp `revoked_at`.
  `update_user_password/4` re-uses the bulk revoke so a password change signs the
  user out of every other device (Coolify's `DeletesUserSessions`).
  """
  import Ecto.Query, warn: false
  require Logger

  alias BarkparkCloud.{Billing, Notifications, Registry, Repo}

  alias BarkparkCloud.Accounts.{
    AuditEvent,
    Authz,
    ExternalIdentity,
    Team,
    TeamInvitation,
    TeamMembership,
    TwoFactor,
    User,
    UserToken
  }

  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry.AgentEvent
  alias Ecto.Multi

  # How long a 2fa-pending challenge token stays valid: just long enough to read
  # the code off an authenticator and type it. After this the user logs in again.
  @two_factor_pending_minutes 5

  # How long a freshly minted invitation stays acceptable. A module attribute
  # mirroring `UserToken.@default_validity_days`; promote to config only if ops
  # needs to tune it.
  @invite_validity_days 7

  # How long a password-reset link stays usable. Short — it is a single-use
  # credential that CHANGES a password without the current one, so the window to
  # replay a leaked link (forwarded email, shared inbox) is deliberately small.
  @reset_validity_minutes 60

  # email-verification-recovery mint-rate throttles, `{max, window_seconds}`: a
  # confirm resend of 1 / 5 min and an email-change of 3 / hour. A DB-count of
  # LIVE tokens minted in the window — the coarse anti-spam guard on the DELIVER
  # side. The email-change wrong-CODE brute force is guarded separately by the
  # per-token `failed_attempts` lockout (a hard cap, not a rate limiter). A
  # fronting proxy/WAF is the IP-level backstop, the same stance /register takes.
  @confirm_throttle {1, 300}
  @change_email_throttle {3, 3600}

  ## Users

  @doc """
  Register a new user from `attrs` (`:email`, `:password`).

  Hashes the password via `Bcrypt.hash_pwd_salt` (the plaintext never reaches
  the DB) and enforces email format + case-insensitive uniqueness. Returns
  `{:ok, %User{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  ## OAuth / SSO (oauth-sso)

  @doc """
  Resolve a Cloud User from a VERIFIED OAuth identity, birthing one (with its own
  team + owner membership + a self-serve trial + notification settings, in ONE
  transaction) on first sight.

  Linking precedence — the SAFE order that defeats Coolify's email-only takeover:

    1. `(provider, provider_uid)` match → that exact User. The durable key is the
       IdP's stable subject id, never the email.
    2. else, when the IdP asserts a VERIFIED `email` that matches an existing
       User → LINK a new identity to it (so "I signed up with email, now I click
       GitHub" CONVERGES instead of forking a second account), WITHOUT touching
       that account's password, teams, or memberships. The email is only ever
       present here when the provider verified it (`OAuth.*.parse_identity` drops
       unverified emails to nil).
    3. else, brand-new: birth user → team → owner membership → trial →
       notification settings, all in one transaction, so a half-made account
       never strands.

  Returns `{:ok, %User{}}` or `{:error, term}`. A concurrent double-callback that
  races to link the same identity is reconciled to the now-linked user rather
  than surfacing a 500.
  """
  @spec get_or_create_user_from_oauth(%{
          provider: String.t(),
          provider_uid: String.t(),
          email: String.t() | nil
        }) :: {:ok, User.t()} | {:error, term()}
  def get_or_create_user_from_oauth(%{provider: provider, provider_uid: uid} = identity)
      when is_binary(provider) and is_binary(uid) do
    email = Map.get(identity, :email)

    case get_user_by_external_identity(provider, uid) do
      %User{} = user -> {:ok, user}
      nil -> birth_or_link_oauth(provider, uid, email)
    end
  end

  @doc """
  Insert an `ExternalIdentity` linking `user` to `(provider, provider_uid)`.
  `email` (display/audit only) is optional. A unique violation on
  `(provider, provider_uid)` returns `{:error, changeset}`.
  """
  @spec link_external_identity(User.t(), map()) ::
          {:ok, ExternalIdentity.t()} | {:error, Ecto.Changeset.t()}
  def link_external_identity(%User{id: user_id}, attrs) when is_map(attrs) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Fetch the User linked to `(provider, provider_uid)`, or nil. A single join on
  the composite-unique external_identities row — the durable identity lookup.
  """
  @spec get_user_by_external_identity(String.t(), String.t()) :: User.t() | nil
  def get_user_by_external_identity(provider, uid) when is_binary(provider) and is_binary(uid) do
    from(u in User,
      join: i in ExternalIdentity,
      on: i.user_id == u.id,
      where: i.provider == ^provider and i.provider_uid == ^uid,
      select: u
    )
    |> Repo.one()
  end

  @doc "Fetch a user by id, or nil (a non-UUID id is nil, not a 500)."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get_by_uuid(User, id)

  @doc "Fetch a user by email (case-insensitive via citext), or nil."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Authenticate by email + password.

  Returns the `%User{}` on a correct password, `nil` otherwise. When no user
  matches the email it still runs `Bcrypt.no_user_verify/0` so the response
  time does not leak whether the email is registered (timing-attack defense).
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    cond do
      user && Bcrypt.verify_pass(password, user.hashed_password) ->
        user

      true ->
        # No matching user (or wrong password): burn a hash so the timing of
        # the failure path matches the success path — never reveal which.
        Bcrypt.no_user_verify()
        nil
    end
  end

  ## Teams

  @doc "Create a Team from `attrs` (`:name`, `:slug`)."
  @spec create_team(map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def create_team(attrs) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a team by id, or nil (a non-UUID id is nil, not a 500)."
  @spec get_team(binary()) :: Team.t() | nil
  def get_team(id), do: Repo.get_by_uuid(Team, id)

  @doc "Fetch a team by slug, or nil."
  @spec get_team_by_slug(String.t()) :: Team.t() | nil
  def get_team_by_slug(slug) when is_binary(slug), do: Repo.get_by(Team, slug: slug)

  ## Memberships

  @doc """
  Add `user` to `team` with `role` (defaults to `member` — the role is the
  grant, mirroring the api/ tenancy rule).

  Accepts structs or raw binary ids for both. Returns `{:ok, %TeamMembership{}}`
  or `{:error, %Ecto.Changeset{}}` (e.g. the (user, team) pair already exists,
  or an invalid role).
  """
  @spec add_member(Team.t() | binary(), User.t() | binary(), String.t()) ::
          {:ok, TeamMembership.t()} | {:error, Ecto.Changeset.t()}
  def add_member(team, user, role \\ TeamMembership.default_role())

  def add_member(%Team{id: team_id}, user, role), do: add_member(team_id, user, role)
  def add_member(team_id, %User{id: user_id}, role), do: add_member(team_id, user_id, role)

  def add_member(team_id, user_id, role)
      when is_binary(team_id) and is_binary(user_id) and is_binary(role) do
    %TeamMembership{}
    |> TeamMembership.changeset(%{team_id: team_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  @doc """
  Add `user` to `team` as `role`, AUTHORIZED by `actor`.

  The escalation-safe sibling of `add_member/3`: it refuses unless `actor` is a
  team admin who OUTRANKS the granted role (anti-escalation, delegated to
  `Authz.can_grant?/3`). This closes the privilege-escalation hole at the
  context, so even a route that forgets to gate cannot mint a higher role than
  the caller holds. The raw `add_member/3` stays for the signup transaction,
  which legitimately grants `"owner"` with no acting user.

  Returns `{:ok, membership} | {:error, :forbidden} | {:error, changeset}`.
  """
  @spec add_member_as(
          User.t() | binary(),
          Team.t() | binary(),
          User.t() | binary(),
          String.t()
        ) ::
          {:ok, TeamMembership.t()} | {:error, :forbidden} | {:error, Ecto.Changeset.t()}
  def add_member_as(actor, team, user, role \\ TeamMembership.default_role()) do
    case Authz.can_grant?(actor, team, role) do
      :ok -> add_member(team, user, role)
      {:error, :forbidden} = err -> err
    end
  end

  @doc "Fetch the membership for `user` in `team`, or nil."
  @spec get_membership(Team.t() | binary(), User.t() | binary()) :: TeamMembership.t() | nil
  def get_membership(%Team{id: team_id}, user), do: get_membership(team_id, user)
  def get_membership(team_id, %User{id: user_id}), do: get_membership(team_id, user_id)

  def get_membership(team_id, user_id) when is_binary(team_id) and is_binary(user_id) do
    Repo.get_by(TeamMembership, team_id: team_id, user_id: user_id)
  end

  @doc """
  All Teams `user` belongs to, oldest membership first. The membership order is
  stable, so `List.first/1` of this is a deterministic "primary" team.
  """
  @spec list_user_teams(User.t() | binary()) :: [Team.t()]
  def list_user_teams(user) do
    uid = user_id(user)

    from(t in Team,
      join: m in TeamMembership,
      on: m.team_id == t.id,
      where: m.user_id == ^uid,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: t
    )
    |> Repo.all()
  end

  @doc """
  Every member email of `team`, ordered by membership age (oldest first). The
  recipient list `BarkparkCloud.Notifications.dispatch_event/3` fans an alert out
  over — kept here so the membership→user join stays in the identity context, and
  so the team-members-ONLY exfiltration guard is a single, testable query.
  """
  @spec list_team_member_emails(Team.t() | binary()) :: [String.t()]
  def list_team_member_emails(team) do
    tid = team_id(team)

    from(u in User,
      join: m in TeamMembership,
      on: m.user_id == u.id,
      where: m.team_id == ^tid,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: u.email
    )
    |> Repo.all()
  end

  @doc """
  The Team `user` acts within by default — the first team they joined, or `nil`
  if they belong to none. A logged-in User acts within ONE team at a time; a
  team-switcher is a later concern (YAGNI), so the primary team is the API's
  current-team for now.
  """
  @spec primary_team(User.t() | binary()) :: Team.t() | nil
  def primary_team(user), do: user |> list_user_teams() |> List.first()

  ## Audit trail
  ##
  ## An append-only record of WHO did WHAT to a team. The write side
  ## (`record_audit/1` + the `audit/3` transactional wrapper) records a fact
  ## ATOMIC with the mutation it describes; the read side (`list_audit_events/2`)
  ## is the keyset-paginated, actor-preloaded surface that every existing
  ## Barkpark audit fragment (`agent_events`, `plugin_settings_audit`) lacks.

  @doc """
  Append one audit event. `attrs` carries `:team_id` (required), `:action`
  (required, one of `AuditEvent.actions/0`), and optionally `:actor_user_id`,
  `:target_type`, `:target_id`, `:metadata`. Returns `{:ok, %AuditEvent{}}` or
  `{:error, %Ecto.Changeset{}}`.

  Call this INSIDE the mutation's own `Repo.transaction` (see `audit/3`) so the
  event and the change it records commit or roll back together — never a
  recorded action that didn't happen, never an action with no record.
  """
  @spec record_audit(map()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_audit(attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Run `fun` (the mutation) and stamp an audit event in ONE transaction.

  `fun` is a 0-arity closure returning `{:ok, result}` | `{:error, reason}`. On
  `{:ok, result}` the audit row is inserted — its attrs are `base_attrs` merged
  with `target_fun.(result)` (so a `target_id` known only after the mutation,
  e.g. a freshly-created site's id, is resolved from the result) — and the whole
  thing commits. Any error rolls the transaction back: a `fun` error surfaces as
  `{:error, reason}` with NO audit row, and an audit-changeset error rolls back
  the mutation too (never a mutation without its record).

  This is the atomic-with-mutation discipline copied from
  `Barkpark.Plugins.Settings.log_audit/3` (api/lib/barkpark/plugins/settings.ex).
  The shared `BarkparkCloud.Repo` means the mutation and the audit insert sit in
  the same transaction even when the mutation lives in `Registry`/`Billing` — so
  those contexts never have to depend on `Accounts`. A `fun` that itself opens a
  `Repo.transaction` (e.g. `remove_member_as/3`) nests as a savepoint, so its
  inner rollback still aborts the whole audited unit.
  """
  @spec audit(map(), (-> {:ok, any()} | {:error, any()}), (any() -> map())) ::
          {:ok, any()} | {:error, any()}
  def audit(base_attrs, fun, target_fun \\ fn _ -> %{} end)
      when is_map(base_attrs) and is_function(fun, 0) and is_function(target_fun, 1) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} ->
          attrs = Map.merge(base_attrs, target_fun.(result))

          case record_audit(attrs) do
            {:ok, _event} -> result
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Most-recent audit events for `team`, newest first. `opts`:

    * `:limit`       — page size (default 50, hard-capped 200, floored 1)
    * `:before`      — a `DateTime` cursor; only events strictly older are
                       returned (keyset pagination on `inserted_at`)
    * `:target_type` + `:target_id` — narrow to one resource's history

  Preloads `:actor_user` so the read renders "alice@x invited a member" without
  an N+1. Strictly team-scoped — never crosses teams.
  """
  @spec list_audit_events(Team.t() | binary(), keyword()) :: [AuditEvent.t()]
  def list_audit_events(team, opts \\ []) do
    tid = team_id(team)
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)

    AuditEvent
    |> where([e], e.team_id == ^tid)
    |> maybe_audit_before(opts[:before])
    |> maybe_audit_target(opts[:target_type], opts[:target_id])
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> preload(:actor_user)
    |> Repo.all()
  end

  defp maybe_audit_before(query, nil), do: query
  defp maybe_audit_before(query, %DateTime{} = ts), do: where(query, [e], e.inserted_at < ^ts)

  defp maybe_audit_target(query, type, id) when is_binary(type) and is_binary(id),
    do: where(query, [e], e.target_type == ^type and e.target_id == ^id)

  defp maybe_audit_target(query, _type, _id), do: query

  @doc """
  How many days a team's audit events are retained before a retention sweeper may
  prune them. Read at call time (so runtime.exs's env override wins); defaults to
  90. Never a magic literal — the sweeper (a follow-up) reads this.
  """
  @spec audit_retention_days() :: pos_integer()
  def audit_retention_days do
    Application.get_env(:barkpark_cloud, :audit_retention_days, 90)
  end

  ## Session tokens

  @doc """
  Mint a USER session token for `user`. Returns the PLAINTEXT exactly once — only
  its SHA-256 hash is stored, so the credential is unrecoverable after this call
  (mirrors `Registry.mint_agent_token/3`).

  The token is valid for `UserToken.default_validity_days/0` from now. `opts`
  carries optional device metadata captured at the web layer (default `[]`, so
  every existing caller keeps compiling unchanged):

    * `:ip_address` — the caller's peer IP (string), for the sessions list.
    * `:user_agent` — the `User-Agent` header, for the "Device" column.

  `last_used_at` is stamped to now at mint so a fresh token sorts to the top of
  the active-sessions list before its first authenticated request.
  """
  @spec create_user_session_token(User.t(), keyword()) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_user_session_token(%User{} = user, opts \\ []) do
    plaintext = generate_token()
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    expires_at = DateTime.add(now, UserToken.default_validity_days() * 24 * 3600, :second)

    %UserToken{}
    |> UserToken.changeset(%{
      user_id: user.id,
      context: "session",
      token_hash: UserToken.hash_token(plaintext),
      expires_at: expires_at,
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent),
      last_used_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a presented session-token `plaintext`. Returns the owning `%User{}` when
  the token exists, is a `"session"` row, is NOT revoked, and is not past
  `expires_at`; otherwise `nil`. Lookup is by hash — the plaintext is never
  stored to compare against.

  The `context == "session"` clause keeps this path from ever resolving a PAT
  row (a PAT is for the API, never the browser session). The `is_nil(revoked_at)`
  clause is the kill switch (mirrors `Registry.verify_agent_token/1`) and the
  shared win the PAT migration unlocked: a logged-out / removed member's session
  row, once `revoked_at` is stamped, now fails verify (closing the `bp-auth-login`
  logout gap and the `bp-teams` member-removal gap). A successful verify refreshes
  `last_used_at` best-effort so the sessions list shows real activity.
  """
  @spec verify_user_session_token(binary()) :: User.t() | nil
  def verify_user_session_token(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from(t in UserToken,
        where: t.token_hash == ^hash,
        where: t.context == "session",
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now
      )

    case Repo.one(query) do
      %UserToken{user_id: user_id} ->
        touch_last_used(hash, now)
        Repo.get(User, user_id)

      nil ->
        nil
    end
  end

  def verify_user_session_token(_), do: nil

  # Best-effort "last seen" refresh keyed by hash. update_all never raises on a
  # zero-row match, so a token revoked between the verify SELECT and this UPDATE
  # is a harmless no-op — the return contract (User | nil) is unaffected.
  defp touch_last_used(hash, now) do
    from(t in UserToken, where: t.token_hash == ^hash)
    |> Repo.update_all(set: [last_used_at: DateTime.truncate(now, :microsecond)])
  end

  @doc """
  Revoke a single session token by its `plaintext` (idempotent — a second revoke
  of an already-revoked token still returns `{:ok, _}`). The single-device logout
  kill switch. Mirrors `Registry.revoke_agent_token/1`. Returns
  `{:ok, %UserToken{}}` or `{:error, :not_found}` when no row matches the hash.
  """
  @spec revoke_user_session_token(binary()) ::
          {:ok, UserToken.t()} | {:error, :not_found}
  def revoke_user_session_token(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)

    case Repo.get_by(UserToken, token_hash: hash) do
      %UserToken{} = t -> stamp_revoked(t)
      nil -> {:error, :not_found}
    end
  end

  def revoke_user_session_token(_), do: {:error, :not_found}

  @doc """
  Revoke one of `user`'s sessions by its row `id` — ownership-scoped. A row id
  belonging to a different user is `{:error, :not_found}` (no existence leak: a
  cross-user id is indistinguishable from a missing one). Returns
  `{:ok, %UserToken{}}` on success.
  """
  @spec revoke_user_session(User.t() | binary(), binary()) ::
          {:ok, UserToken.t()} | {:error, :not_found}
  def revoke_user_session(user, token_id) when is_binary(token_id) do
    uid = user_id(user)

    # A non-UUID token_id would make the Repo.get_by cast raise → 500; guard it
    # to the {:error, :not_found} (404) branch, indistinguishable from a miss.
    with token_id when not is_nil(token_id) <- Repo.uuid_or_nil(token_id),
         # context: "session" keeps the per-row Revoke button from killing a PAT by id.
         %UserToken{} = t <-
           Repo.get_by(UserToken, id: token_id, user_id: uid, context: "session") do
      stamp_revoked(t)
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke_user_session(_user, _token_id), do: {:error, :not_found}

  @doc """
  Revoke ALL of `user`'s live session tokens — the "sign out everywhere" /
  Coolify `DeletesUserSessions` analog (DeletesUserSessions.php:13). Done as an
  explicit context step, not a model hook, so the kill is visible at the call
  site.

  `opts[:except]` keeps ONE token alive (by plaintext) so a password-change
  caller is not logged out of their own in-flight tab. Returns `{:ok, count}` —
  the number of rows stamped revoked.
  """
  @spec revoke_all_user_sessions(User.t() | binary(), keyword()) :: {:ok, non_neg_integer()}
  def revoke_all_user_sessions(user, opts \\ []) do
    uid = user_id(user)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    # context == "session" ONLY: "sign out everywhere" / a password change must
    # never silently revoke the user's live PATs (programmatic credentials).
    base =
      from t in UserToken,
        where: t.user_id == ^uid,
        where: t.context == "session",
        where: is_nil(t.revoked_at)

    query =
      case Keyword.get(opts, :except) do
        nil -> base
        plaintext -> from t in base, where: t.token_hash != ^UserToken.hash_token(plaintext)
      end

    {count, _} = Repo.update_all(query, set: [revoked_at: now])
    {:ok, count}
  end

  @doc """
  All of `user`'s LIVE sessions (unrevoked, unexpired), newest activity first —
  backs the active-sessions list UI. The serializer at the web layer flags the
  caller's own row; this context call stays principal-agnostic.
  """
  @spec list_user_sessions(User.t() | binary()) :: [UserToken.t()]
  def list_user_sessions(user) do
    uid = user_id(user)
    now = DateTime.utc_now()

    # context == "session" ONLY — the sessions list must never surface PAT rows
    # (they carry null ip/user_agent and are managed via /v1/tokens, not here).
    from(t in UserToken,
      where: t.user_id == ^uid,
      where: t.context == "session",
      where: is_nil(t.revoked_at),
      where: is_nil(t.expires_at) or t.expires_at > ^now,
      order_by: [desc: t.last_used_at, desc: t.inserted_at]
    )
    |> Repo.all()
  end

  ## Personal access tokens
  ##
  ## A PAT is a `context = "pat"` row in the SAME user_tokens table (see
  ## UserToken's moduledoc). It mirrors the session-token mint/verify shape and
  ## the Registry.mint/verify/revoke_agent_token shape so the three credential
  ## kinds never drift. Adapted from Coolify's PersonalAccessToken model +
  ## Security/ApiTokens Livewire component.

  # Once-per-minute is enough resolution for "is this token dead?"; below this
  # threshold the stamp is skipped so a chatty token doesn't trigger a write per
  # request.
  @last_used_throttle_seconds 60

  @doc """
  Mint a Personal Access Token for `user` bound to `team`, carrying `abilities`
  (a subset of `UserToken.abilities/0`) and an optional bounded expiry.

  `attrs` keys:
    * `:name` — required, 3..255 chars (the user-facing label).
    * `:abilities` — list; defaults to `["read"]`. Server-normalized
      (`root`/`deploy` exclusivity) in `UserToken.pat_changeset/2`.
    * `:expires_in_days` — integer or `nil`. Defaults to
      `UserToken.pat_default_validity_days/0`; `nil` = never expires.

  Returns the PLAINTEXT exactly once — only its SHA-256 hash is stored, so the
  credential is unrecoverable after this call. The plaintext carries the
  `bpc_pat_` prefix (a leak-scanner / GitHub-push-protection recognisability
  marker, lifted from Coolify's `config('sanctum.token_prefix')`).

  ROLE-GATED (mirrors api/'s `authorize_pat_permissions`): a plain `member` (or a
  non-member) may mint a `read`-only token; only an `owner`/`admin` may mint an
  elevated PAT (`write`/`deploy`/`root`). This closes the escalation where a
  member mints a `root`/`deploy` PAT and bypasses the session-only admin gates
  (e.g. go-live). Over-reach returns `{:error, :forbidden}` BEFORE the changeset.
  """
  @spec create_personal_access_token(User.t(), Team.t() | binary(), map()) ::
          {:ok, binary(), UserToken.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def create_personal_access_token(%User{} = user, team, attrs) do
    requested = Map.get(attrs, :abilities) || ["read"]

    if pat_abilities_allowed?(Authz.role(user, team), requested) do
      do_create_personal_access_token(user, team, attrs)
    else
      {:error, :forbidden}
    end
  end

  # An owner/admin may mint any ability; everyone else is capped at `read` only.
  defp pat_abilities_allowed?(role, _requested) when role in ~w(owner admin), do: true

  defp pat_abilities_allowed?(_role, requested) when is_list(requested),
    do: Enum.all?(requested, &(&1 == "read"))

  defp pat_abilities_allowed?(_role, _requested), do: false

  defp do_create_personal_access_token(%User{} = user, team, attrs) do
    plaintext = "bpc_pat_" <> generate_token()

    expires_at =
      case Map.get(attrs, :expires_in_days, UserToken.pat_default_validity_days()) do
        nil ->
          nil

        days when is_integer(days) ->
          DateTime.utc_now()
          |> DateTime.add(days * 24 * 3600, :second)
          |> DateTime.truncate(:microsecond)
      end

    %UserToken{}
    |> UserToken.pat_changeset(%{
      user_id: user.id,
      team_id: team_id(team),
      name: Map.get(attrs, :name),
      abilities: Map.get(attrs, :abilities, ["read"]),
      token_hash: UserToken.hash_token(plaintext),
      expires_at: expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, token} -> {:ok, plaintext, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  All of `user`'s PATs, newest first. Includes revoked rows (the management UI
  shows them as a "revoked" tombstone for audit). Never crosses users.
  """
  @spec list_personal_access_tokens(User.t() | binary()) :: [UserToken.t()]
  def list_personal_access_tokens(user) do
    uid = user_id(user)

    from(t in UserToken,
      where: t.user_id == ^uid and t.context == "pat",
      order_by: [desc: t.inserted_at, desc: t.id]
    )
    |> Repo.all()
  end

  @doc """
  Delete ALL of `user`'s SESSION tokens — an immediate logout everywhere. The
  Cloud analogue of Coolify's `RevokeUserTeamTokens` (it deletes session rows
  rather than flag a `revoked_at` column we don't have).

  SCOPED to `context == "session"`: a member removal / demotion (the callers)
  must log the user out without incidentally HARD-DELETING their PATs — a
  programmatic credential is destroyed only by a deliberate `/v1/tokens` revoke,
  never as a side effect of a role change.

  NOTE: Cloud session tokens are GLOBAL, not per-team (unlike Coolify's
  team-scoped tokens). In the single-team beta, removing a user from their team
  logs them out entirely — acceptable and even desirable. When multi-team lands,
  narrow this to the team the action targeted (add a `team_id` to user_tokens, or
  scope by team). Returns `{:ok, count}`.
  """
  @spec delete_user_session_tokens(User.t() | binary()) :: {:ok, non_neg_integer()}
  def delete_user_session_tokens(user) do
    uid = user_id(user)

    {count, _} =
      from(t in UserToken, where: t.user_id == ^uid and t.context == "session")
      |> Repo.delete_all()

    {:ok, count}
  end

  ## Roles — the inert team_memberships.role column put to work.

  @doc "The role `user` holds in `team`, or nil when they are not a member."
  @spec team_role(User.t() | binary(), Team.t() | binary()) :: String.t() | nil
  def team_role(user, team) do
    case get_membership(team, user) do
      %TeamMembership{role: role} -> role
      nil -> nil
    end
  end

  @doc "True when `user` is owner|admin of `team` (a member or non-member is false)."
  @spec team_admin?(User.t() | binary(), Team.t() | binary()) :: boolean()
  def team_admin?(user, team) do
    case team_role(user, team) do
      nil -> false
      role -> TeamMembership.admin?(role)
    end
  end

  ## Invitations

  @doc """
  Invite `email` to `team` at `role`, attributed to `invited_by`. Returns
  `{:ok, %{invitation: inv, token: raw}}` — `token` is the PLAINTEXT accept
  secret, returned ONCE (only its hash is stored).

  Guards (Coolify's invite rules, enforced in the context not the route):

    * `:invalid_role`  — `role` is not one of owner|admin|member.
    * `:role_too_high` — `invited_by` may not mint a grant they don't outrank
      (an admin cannot invite an owner; an owner may invite anyone).
    * `:already_member` — a user with that email is already on the team.

  A duplicate LIVE invite surfaces the partial-unique violation as
  `{:error, %Ecto.Changeset{}}`, which the caller maps to 409.
  """
  @spec invite_member(Team.t(), String.t(), String.t(), User.t()) ::
          {:ok, %{invitation: TeamInvitation.t(), token: binary()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def invite_member(%Team{} = team, email, role, %User{} = invited_by)
      when is_binary(email) and is_binary(role) do
    actor_role = team_role(invited_by, team)
    norm = String.downcase(email)

    cond do
      role not in TeamInvitation.roles() ->
        {:error, :invalid_role}

      not can_grant?(actor_role, role) ->
        {:error, :role_too_high}

      member_with_email?(team, norm) ->
        {:error, :already_member}

      true ->
        raw = generate_token()
        now = DateTime.truncate(DateTime.utc_now(), :microsecond)
        expires_at = DateTime.add(now, @invite_validity_days * 24 * 3600, :second)

        attrs = %{
          team_id: team.id,
          email: norm,
          role: role,
          invited_by_id: invited_by.id,
          token_hash: TeamInvitation.hash_token(raw),
          expires_at: expires_at
        }

        # One txn: first reap any EXPIRED, still-unaccepted invite for this
        # (team,email) — the partial unique index keys only on `accepted_at IS
        # NULL`, so a lapsed invite would otherwise permanently 409 a re-invite
        # (the inviter sees nothing in the pending list yet cannot re-send). A
        # still-LIVE duplicate is NOT reaped → it collides on insert → 409 (guard
        # preserved). The insert rides an Ecto savepoint, so the unique violation
        # returns a changeset rather than poisoning the txn.
        Repo.transaction(fn ->
          from(i in TeamInvitation,
            where:
              i.team_id == ^team.id and i.email == ^norm and is_nil(i.accepted_at) and
                i.expires_at <= ^now
          )
          |> Repo.delete_all()

          case %TeamInvitation{} |> TeamInvitation.changeset(attrs) |> Repo.insert() do
            {:ok, inv} -> %{invitation: inv, token: raw}
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
    end
  end

  # An owner may grant any role; an admin may grant member/admin but NOT owner;
  # anyone lower (or a non-member) may grant nothing.
  defp can_grant?("owner", _role), do: true
  defp can_grant?("admin", role), do: role != "owner"
  defp can_grant?(_actor_role, _role), do: false

  defp member_with_email?(team, norm_email) do
    case get_user_by_email(norm_email) do
      nil -> false
      user -> not is_nil(get_membership(team, user))
    end
  end

  @doc """
  Look up a LIVE invitation by its raw token: not accepted, not expired. Returns
  the invitation with its team preloaded, or nil. Used by the unauthenticated
  accept page to show "You've been invited to <team>" before login/register.
  """
  @spec get_live_invitation(binary()) :: TeamInvitation.t() | nil
  def get_live_invitation(raw) when is_binary(raw) do
    hash = TeamInvitation.hash_token(raw)
    now = DateTime.utc_now()

    from(i in TeamInvitation,
      where: i.token_hash == ^hash and is_nil(i.accepted_at) and i.expires_at > ^now,
      preload: [:team]
    )
    |> Repo.one()
  end

  def get_live_invitation(_), do: nil

  @doc """
  Accept `raw_token` as `user`. One transaction: re-load the live invitation FOR
  UPDATE, assert the logged-in user's email matches the invited email (Coolify's
  wrong-user guard), add the membership at the invited role, stamp `accepted_at`.

  Returns `{:ok, %TeamMembership{}}` or `{:error, reason}`:

    * `:invalid_token`  — no matching unexpired/unaccepted row (covers replay of
      an already-accepted token and an expired one).
    * `:email_mismatch` — the logged-in user's email is not the invited email.

  An already-member invitee (raced a prior accept / manual add) is treated as
  success: the existing membership is returned and the invite is still stamped.
  """
  @spec accept_invitation(binary(), User.t()) ::
          {:ok, TeamMembership.t()} | {:error, atom()}
  def accept_invitation(raw_token, %User{} = user) when is_binary(raw_token) do
    hash = TeamInvitation.hash_token(raw_token)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      inv =
        from(i in TeamInvitation,
          where: i.token_hash == ^hash and is_nil(i.accepted_at) and i.expires_at > ^now,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(inv) ->
          Repo.rollback(:invalid_token)

        String.downcase(user.email) != inv.email ->
          Repo.rollback(:email_mismatch)

        true ->
          membership =
            case add_member(inv.team_id, user.id, inv.role) do
              {:ok, m} ->
                m

              # Already a member (raced a prior accept / manual add): treat as
              # success — return the existing membership.
              {:error, %Ecto.Changeset{}} ->
                get_membership(inv.team_id, user.id)
            end

          inv
          |> Ecto.Changeset.change(accepted_at: DateTime.truncate(now, :microsecond))
          |> Repo.update!()

          membership
      end
    end)
  end

  def accept_invitation(_, _), do: {:error, :invalid_token}

  @doc "Pending (unaccepted, unexpired) invitations for a team, newest first."
  @spec list_invitations(Team.t()) :: [TeamInvitation.t()]
  def list_invitations(%Team{} = team) do
    now = DateTime.utc_now()

    from(i in TeamInvitation,
      where: i.team_id == ^team.id and is_nil(i.accepted_at) and i.expires_at > ^now,
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  # Stamp revoked_at = now on a UserToken (idempotent). The verbatim twin of
  # Registry.revoke_agent_token/1's struct clause.
  defp stamp_revoked(%UserToken{} = t) do
    t
    |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
    |> Repo.update()
  end

  @doc """
  Change `user`'s password after verifying `current_password` (timing-safe via
  the same Bcrypt path as login). On success, in ONE transaction: writes the new
  hash AND revokes every OTHER session + every agent token the user can reach —
  the "change password ⇒ sign out everywhere" guarantee (Coolify's
  DeletesUserSessions, DeletesUserSessions.php:31-37, done as an explicit context
  step rather than a model `updated` hook).

  `opts[:keep]` is the acting browser's plaintext token — kept alive through the
  bulk revoke so the in-flight request never invalidates its own auth mid-call.
  Returns `{:ok, %User{}}`, `{:error, :invalid_current_password}`, or
  `{:error, %Ecto.Changeset{}}` (a weak new password).
  """
  @spec update_user_password(User.t(), String.t(), String.t(), keyword()) ::
          {:ok, User.t()} | {:error, :invalid_current_password | Ecto.Changeset.t()}
  def update_user_password(%User{} = user, current_password, new_password, opts \\ [])
      when is_binary(current_password) and is_binary(new_password) do
    if Bcrypt.verify_pass(current_password, user.hashed_password) do
      Repo.transaction(fn ->
        with {:ok, updated} <-
               user |> User.password_changeset(%{password: new_password}) |> Repo.update(),
             {:ok, _n} <- revoke_all_user_sessions(user, except: opts[:keep]),
             :ok <- BarkparkCloud.Registry.revoke_all_agent_tokens_for_user(user) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      # Burn a hash so the wrong-current-password path matches the success path's
      # timing — never reveal whether the current password was close.
      Bcrypt.no_user_verify()
      {:error, :invalid_current_password}
    end
  end

  @doc """
  Begin a password reset for `email` — the "forgot password" entry point.

  ENUMERATION-SAFE by design: returns `{:ok, nil}` when no user matches that
  email (so the route answers an identical 200 either way and a prober can never
  discover which addresses have accounts), and `{:ok, {user, raw_token}}` when one
  does. `raw_token` is the PLAINTEXT reset secret, returned EXACTLY ONCE for the
  caller to email — only its SHA-256 hash is stored (same discipline as session
  tokens / invites), so it is unrecoverable from the DB.

  Any earlier outstanding reset links for the user are revoked first, so a
  re-request SUPERSEDES rather than accumulating live links. The token is a
  `context = "reset"` `UserToken` valid for `#{@reset_validity_minutes}` minutes.
  """
  @spec request_password_reset(String.t()) ::
          {:ok, {User.t(), binary()} | nil} | {:error, Ecto.Changeset.t()}
  def request_password_reset(email) when is_binary(email) do
    case get_user_by_email(email) do
      nil ->
        {:ok, nil}

      %User{} = user ->
        plaintext = generate_token()
        now = DateTime.truncate(DateTime.utc_now(), :microsecond)
        expires_at = DateTime.add(now, @reset_validity_minutes * 60, :second)

        Repo.transaction(fn ->
          # Supersede the user's earlier live reset links before minting a new one.
          revoke_reset_tokens(user.id, now)

          attrs = %{
            user_id: user.id,
            context: "reset",
            token_hash: UserToken.hash_token(plaintext),
            expires_at: expires_at
          }

          case %UserToken{} |> UserToken.changeset(attrs) |> Repo.insert() do
            {:ok, _token} -> {user, plaintext}
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
    end
  end

  def request_password_reset(_), do: {:ok, nil}

  @doc """
  Complete a password reset: verify `raw_token` (a live, single-use `reset`
  token), set `new_password`, and — in ONE transaction — CONSUME every reset link
  the user holds AND revoke every session + agent token (a credential reset signs
  the user out everywhere, exactly like `update_user_password/4`).

  The token row is locked `FOR UPDATE` then stamped revoked, so a double-submit or
  a replay of the same link finds it already consumed and fails closed. Unlike
  `update_user_password/4` this does NOT require the current password — proving
  control of the reset link IS the authentication.

  Returns `{:ok, %User{}}`, `{:error, :invalid_token}` (no live token matches —
  also the replay / expired / unknown-user case, never revealing which), or
  `{:error, %Ecto.Changeset{}}` (the new password failed validation).
  """
  @spec reset_password_by_token(binary(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_token | Ecto.Changeset.t()}
  def reset_password_by_token(raw_token, new_password)
      when is_binary(raw_token) and is_binary(new_password) do
    hash = UserToken.hash_token(raw_token)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      token =
        from(t in UserToken,
          where: t.token_hash == ^hash and t.context == "reset",
          where: is_nil(t.revoked_at),
          where: is_nil(t.expires_at) or t.expires_at > ^now,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      with %UserToken{user_id: uid} <- token || Repo.rollback(:invalid_token),
           %User{} = user <- Repo.get(User, uid) || Repo.rollback(:invalid_token),
           {:ok, updated} <-
             user |> User.password_changeset(%{password: new_password}) |> Repo.update(),
           # Single-use: consume THIS link and any sibling links for the user, so
           # a second outstanding reset email cannot be replayed afterwards.
           _ <- revoke_reset_tokens(uid, DateTime.truncate(now, :microsecond)),
           {:ok, _n} <- revoke_all_user_sessions(user),
           :ok <- BarkparkCloud.Registry.revoke_all_agent_tokens_for_user(user) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def reset_password_by_token(_, _), do: {:error, :invalid_token}

  # Revoke (stamp revoked_at) every live `reset` token for a user. Used both when
  # a fresh reset is requested (supersede older links) and when one is consumed
  # (single-use + kill any sibling link). A no-op on zero matches.
  defp revoke_reset_tokens(user_id, now) do
    from(t in UserToken,
      where: t.user_id == ^user_id and t.context == "reset" and is_nil(t.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  ## Account lifecycle — email confirmation (email-verification-recovery)

  @doc """
  Email a confirmation link to `user`. Mints a single-use `"confirm"` token
  (7-day validity), builds the `<dashboard>/?confirm=<token>` link, and delivers
  it over the PLATFORM transport (`Notifications.deliver_email_verification/2`).
  Returns `{:error, :already_confirmed}` for a verified user, `{:error,
  :throttled}` past the resend cap, otherwise the fail-soft notifier result
  (a down mailer is `{:error, _}`, never a crash).
  """
  @spec deliver_user_confirmation_instructions(User.t()) :: {:ok, term} | {:error, term}
  def deliver_user_confirmation_instructions(%User{} = user) do
    cond do
      not is_nil(user.confirmed_at) ->
        {:error, :already_confirmed}

      throttled?(user, "confirm", @confirm_throttle) ->
        {:error, :throttled}

      true ->
        plaintext = mint_lifecycle_token(user, "confirm", user.email, :confirm)
        Notifications.deliver_email_verification(user.email, confirm_url(plaintext))
    end
  end

  @doc """
  Confirm an account from a `"confirm"` token plaintext. Sets `confirmed_at` and
  revokes every live confirm token for the user in ONE transaction (single-use).
  Returns `{:ok, %User{}}`, or `:error` for an unknown / expired / already-spent
  token — so confirming twice, or after a revoke, fails closed.
  """
  @spec confirm_user(binary()) :: {:ok, User.t()} | :error
  def confirm_user(token) when is_binary(token) do
    case user_by_valid_lifecycle_token(token, "confirm") do
      %User{} = user ->
        {:ok, %{user: user}} =
          Multi.new()
          |> Multi.update(:user, User.confirm_changeset(user))
          |> Multi.update_all(:tokens, live_lifecycle_tokens(user, ["confirm"]),
            set: [revoked_at: lifecycle_now()]
          )
          |> Repo.transaction()

        {:ok, user}

      _ ->
        :error
    end
  end

  def confirm_user(_), do: :error

  ## Account lifecycle — verified email change (email-verification-recovery)

  @doc """
  Begin a verified email change: stage `new_email` on `user.pending_email`, mint
  a `"change_email"` token holding a 6-digit code (10-min validity, `sent_to` =
  the pending address), and email that code to the NEW address.

  ENUMERATION-SAFE: when `new_email` already belongs to a user (including the
  caller), NOTHING is staged and NO code is sent — the caller answers the SAME
  202 as success, so a prober can't discover which addresses have accounts, and
  a code can never be minted toward an address the requester doesn't control
  (no takeover). A malformed address is `{:error, %Ecto.Changeset{}}` (a syntax
  fact, not an existence one). Throttled and fail-soft otherwise.
  """
  @spec deliver_user_update_email_instructions(User.t(), String.t()) ::
          {:ok, term} | {:error, term}
  def deliver_user_update_email_instructions(%User{} = user, new_email)
      when is_binary(new_email) do
    cond do
      throttled?(user, "change_email", @change_email_throttle) ->
        {:error, :throttled}

      get_user_by_email(new_email) ->
        # Address already in use (or is the caller's own): no stage, no code,
        # no leak. Same success shape as a real send.
        {:ok, :noop}

      true ->
        case Repo.update(User.email_change_changeset(user, %{pending_email: new_email})) do
          {:ok, staged} ->
            {code, hash} = UserToken.generate_email_change_code()
            {seconds, :second} = UserToken.validity(:change_email)

            # Supersede any earlier live change code so only the latest one works.
            Repo.update_all(live_lifecycle_tokens(staged, ["change_email"]),
              set: [revoked_at: lifecycle_now()]
            )

            with {:ok, _token} <-
                   insert_lifecycle_token(
                     staged,
                     "change_email",
                     hash,
                     staged.pending_email,
                     seconds
                   ) do
              Notifications.deliver_email_change_code(staged.pending_email, code)
            end

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Finish a verified email change: prove the 6-digit `code` against the user's
  staged `pending_email`, swap `email := pending_email`, clear pending, revoke the
  change token, and sync the billing customer email (fail-soft). Returns
  `{:ok, %User{}}`, `{:error, :invalid_code}`, `{:error, :locked}` (too many wrong
  codes — the pending change is dropped and must be restarted), or
  `{:error, :no_pending_email}` when nothing is staged.

  The 6-digit code is only 10^6 wide, so a mint-rate throttle is NOT enough: each
  wrong code increments the token's `failed_attempts`, and at
  `UserToken.max_code_attempts/0` the token is revoked and `pending_email`
  dropped — a hard per-user lockout. The lookup is bound to `sent_to == pending`,
  so a code minted for one target can never confirm a change to a different one.
  """
  @spec update_user_email(User.t(), binary()) ::
          {:ok, User.t()}
          | {:error, :invalid_code | :locked | :no_pending_email | Ecto.Changeset.t()}
  def update_user_email(%User{pending_email: pending} = user, code)
      when is_binary(pending) and is_binary(code) do
    n = lifecycle_now()

    # Serialize concurrent confirmations on the change token: the wrong-code path
    # is a read-modify-write of `failed_attempts`, and N parallel guesses reading
    # the same baseline would each write baseline+1, so the counter never reaches
    # max_code_attempts and the per-user brute-force lockout never trips. Lock the
    # row `FOR UPDATE` inside one transaction (mirrors reset_password_by_token) so
    # the increment — and the lockout it feeds — can't be raced. sync_billing_email
    # runs AFTER commit so the external billing call never rides inside the DB txn.
    result =
      Repo.transaction(fn ->
        token =
          Repo.one(
            from t in UserToken,
              where: t.user_id == ^user.id and t.context == "change_email",
              where: t.sent_to == ^pending,
              where: is_nil(t.revoked_at) and (is_nil(t.expires_at) or t.expires_at > ^n),
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(token) ->
            {:error, :invalid_code}

          token.token_hash == UserToken.hash_token(code) ->
            with {:ok, updated} <- Repo.update(User.apply_email_change_changeset(user)),
                 {:ok, _tok} <- Repo.update(UserToken.changeset(token, %{revoked_at: n})) do
              {:ok, updated}
            else
              # pending_email got taken between stage and confirm → unique_constraint
              # fires; roll back so nothing commits (no takeover), surfaced as a
              # changeset error.
              {:error, changeset} -> Repo.rollback(changeset)
            end

          true ->
            attempts = (token.failed_attempts || 0) + 1

            if attempts >= UserToken.max_code_attempts() do
              # LOCKOUT: burn the token AND drop the pending change. Both commit
              # with the transaction (do NOT roll back — the lockout must persist).
              {:ok, _} =
                Repo.update(
                  UserToken.changeset(token, %{revoked_at: n, failed_attempts: attempts})
                )

              {:ok, _} = Repo.update(Ecto.Changeset.change(user, pending_email: nil))
              {:error, :locked}
            else
              {:ok, _} = Repo.update(UserToken.changeset(token, %{failed_attempts: attempts}))
              {:error, :invalid_code}
            end
        end
      end)

    case result do
      {:ok, {:ok, updated}} ->
        sync_billing_email(updated)
        {:ok, updated}

      {:ok, {:error, reason}} ->
        {:error, reason}

      # Repo.rollback(changeset) from the unique-constraint race.
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_user_email(%User{}, _code), do: {:error, :no_pending_email}

  ## Account-lifecycle privates (email-verification-recovery)

  # Mint a hashed, context-scoped lifecycle token. Returns the plaintext (or the
  # code) shown exactly once; only the hash is persisted (UserToken.hash_token/1).
  defp mint_lifecycle_token(user, context, sent_to, validity_atom) do
    plaintext = generate_token()
    {seconds, :second} = UserToken.validity(validity_atom)

    {:ok, _} =
      insert_lifecycle_token(user, context, UserToken.hash_token(plaintext), sent_to, seconds)

    plaintext
  end

  defp insert_lifecycle_token(user, context, hash, sent_to, seconds) do
    expires_at = DateTime.add(lifecycle_now(), seconds, :second)

    %UserToken{}
    |> UserToken.changeset(%{
      user_id: user.id,
      context: context,
      token_hash: hash,
      sent_to: sent_to,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  # Resolve the owning user for a live (not revoked, not expired) token in a
  # given context. Lookup by hash — the plaintext is never stored.
  defp user_by_valid_lifecycle_token(token, context) do
    hash = UserToken.hash_token(token)
    n = lifecycle_now()

    Repo.one(
      from t in UserToken,
        join: u in User,
        on: u.id == t.user_id,
        where: t.token_hash == ^hash and t.context == ^context,
        where: is_nil(t.revoked_at) and (is_nil(t.expires_at) or t.expires_at > ^n),
        select: u
    )
  end

  # A user's LIVE tokens in the given contexts, as an updatable query — backs the
  # supersede / single-use revoke sweeps.
  defp live_lifecycle_tokens(%User{id: uid}, contexts) do
    from t in UserToken,
      where: t.user_id == ^uid and t.context in ^contexts and is_nil(t.revoked_at)
  end

  # DB-count MINT throttle: true when the user already minted `max` live tokens of
  # this context within the last `window` seconds. Anti-spam on the deliver side
  # only — the wrong-code brute force is guarded by the failed_attempts lockout.
  defp throttled?(%User{id: uid}, context, {max, window}) do
    since = DateTime.add(lifecycle_now(), -window, :second)

    count =
      UserToken
      |> where([t], t.user_id == ^uid and t.context == ^context)
      |> where([t], is_nil(t.revoked_at) and t.inserted_at >= ^since)
      |> Repo.aggregate(:count)

    count >= max
  end

  # Inline, fail-soft billing customer email sync. A sync hiccup must NOT roll
  # back a COMMITTED email change — log and move on. The Cloud customer is
  # team-scoped, so sync each team the user is in that has an active subscription.
  defp sync_billing_email(%User{} = user) do
    for team <- list_user_teams(user),
        %Subscription{gateway_customer_id: cid} when is_binary(cid) <-
          [Billing.active_subscription(team)] do
      case Billing.gateway().update_customer(cid, %{email: user.email}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("stripe email sync failed for customer #{cid}: #{inspect(reason)}")
      end
    end

    :ok
  end

  # The emailed confirm link points at the hash-routed dashboard SPA, which reads
  # ?confirm= and POSTs the token to the JSON API. :dashboard_url is the single
  # source (env-fed in prod).
  defp confirm_url(token), do: dashboard_url("/?confirm=" <> token)

  defp dashboard_url(path) do
    base = Application.get_env(:barkpark_cloud, :dashboard_url) || "https://barkpark.cloud"
    String.trim_trailing(base, "/") <> path
  end

  defp lifecycle_now, do: DateTime.truncate(DateTime.utc_now(), :microsecond)

  @doc "Revoke a pending invitation by id, team-scoped. `{:ok, inv}` | `{:error, :not_found}`."
  @spec revoke_invitation(Team.t(), binary()) ::
          {:ok, TeamInvitation.t()} | {:error, :not_found}
  def revoke_invitation(%Team{id: tid}, inv_id) when is_binary(inv_id) do
    # A non-UUID inv_id would make the Repo.get_by cast raise → 500; guard it to
    # the not_found (404) branch the API documents for an absent id.
    case Repo.uuid_or_nil(inv_id) && Repo.get_by(TeamInvitation, id: inv_id, team_id: tid) do
      nil ->
        {:error, :not_found}

      %TeamInvitation{} = inv ->
        {:ok, _} = Repo.delete(inv)
        {:ok, inv}
    end
  end

  def revoke_invitation(_, _), do: {:error, :not_found}

  ## Members

  @doc """
  Members of `team` as `[%{user: %User{}, role: role, joined_at: inserted_at}]`,
  oldest membership first (stable, like `list_user_teams/1`).
  """
  @spec list_team_members(Team.t()) :: [map()]
  def list_team_members(%Team{} = team) do
    from(m in TeamMembership,
      join: u in User,
      on: u.id == m.user_id,
      where: m.team_id == ^team.id,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: %{user: u, role: m.role, joined_at: m.inserted_at}
    )
    |> Repo.all()
  end

  @doc """
  Remove `target` from `team`, AUTHORIZED by an actor holding `actor_role`. The
  anti-escalation sibling of `remove_member/2`: an OWNER may remove any peer
  (including another owner, while `owner_count > 1`); an ADMIN may remove only
  someone they strictly OUTRANK (i.e. a member, never an admin/owner). An
  authority miss is `{:error, :forbidden}`. Last-owner + not-found are preserved
  (delegated to `remove_member/2`). The route threads `current_team_role` here.
  """
  @spec remove_member_as(String.t(), Team.t(), User.t()) ::
          {:ok, :removed} | {:error, :forbidden | :not_found | :last_owner}
  def remove_member_as(actor_role, %Team{} = team, %User{} = target)
      when is_binary(actor_role) do
    case get_membership(team, target) do
      nil ->
        {:error, :not_found}

      %TeamMembership{role: target_role} ->
        if actor_role == "owner" or TeamMembership.outranks?(actor_role, target_role) do
          remove_member(team, target)
        else
          {:error, :forbidden}
        end
    end
  end

  @doc """
  Remove `user` from `team` and evict their live sessions (Coolify's
  `RevokeUserTeamTokens` analogue). Guards the last-owner invariant: the sole
  owner cannot be removed. `{:ok, :removed}` | `{:error, :not_found | :last_owner}`.

  The UNAUTHORIZED primitive — the member-management route calls the actor-aware
  `remove_member_as/3`; this stays for signup/teardown flows with no acting user.
  """
  @spec remove_member(Team.t(), User.t()) ::
          {:ok, :removed} | {:error, :not_found | :last_owner}
  def remove_member(%Team{} = team, %User{} = user) do
    case get_membership(team, user) do
      nil -> {:error, :not_found}
      %TeamMembership{} = m -> do_remove(team, m, user)
    end
  end

  defp do_remove(team, %TeamMembership{role: role} = membership, user) do
    Repo.transaction(fn ->
      # Last-owner guard UNDER A LOCK (TOCTOU): two concurrent removals on a
      # 2-owner team must not both observe count=2 and both commit. Lock the owner
      # row-set FOR UPDATE, then re-count inside the txn before deleting.
      if role == "owner" and locked_owner_count(team) <= 1 do
        Repo.rollback(:last_owner)
      end

      Repo.delete!(membership)
      # Immediate logout — the removed user's session tokens stop working now.
      {:ok, _} = delete_user_session_tokens(user)
      :removed
    end)
  end

  @doc """
  Change `target`'s role in `team` to `new_role`, AUTHORIZED by `actor`. The
  anti-escalation sibling of `update_member_role/3`:

    * `actor` must be able to GRANT `new_role` (`Authz.can_grant?/3` — an admin
      cannot mint an owner, which blocks an admin self-promoting to owner), AND
    * unless acting on THEMSELVES, `actor` must strictly OUTRANK the target's
      CURRENT role (an admin cannot demote an owner or a peer admin). A self
      role-change is governed by `can_grant?` alone, so the sole owner demoting
      themselves still falls through to the last-owner guard (409, not 403).

  `{:error, :forbidden}` on an authority miss; `:invalid_role` / `:not_found` /
  `:last_owner` are preserved (delegated to `update_member_role/3`).
  """
  @spec update_member_role_as(User.t(), Team.t(), User.t(), String.t()) ::
          {:ok, TeamMembership.t()}
          | {:error, :forbidden | :invalid_role | :not_found | :last_owner}
  def update_member_role_as(%User{} = actor, %Team{} = team, %User{} = target, new_role) do
    cond do
      new_role not in TeamMembership.roles() ->
        {:error, :invalid_role}

      true ->
        case get_membership(team, target) do
          nil ->
            {:error, :not_found}

          %TeamMembership{role: current_role} ->
            self? = user_id(actor) == user_id(target)

            cond do
              Authz.can_grant?(actor, team, new_role) != :ok ->
                {:error, :forbidden}

              not self? and not TeamMembership.outranks?(team_role(actor, team), current_role) ->
                {:error, :forbidden}

              true ->
                update_member_role(team, target, new_role)
            end
        end
    end
  end

  @doc """
  Change `user`'s role in `team` to `new_role`, guarding the last-owner
  invariant on a downgrade away from owner. On a downgrade from an admin/owner
  grant to `member`, the user's sessions are also evicted so a demoted user
  loses elevated access immediately (mirrors Coolify revoking tokens on a role
  change). `{:ok, %TeamMembership{}}` | `{:error, :invalid_role | :not_found | :last_owner}`.

  The UNAUTHORIZED primitive — the member-management route calls the actor-aware
  `update_member_role_as/4`.
  """
  @spec update_member_role(Team.t(), User.t(), String.t()) ::
          {:ok, TeamMembership.t()} | {:error, :invalid_role | :not_found | :last_owner}
  def update_member_role(%Team{} = team, %User{} = user, new_role) do
    cond do
      new_role not in TeamMembership.roles() ->
        {:error, :invalid_role}

      true ->
        case get_membership(team, user) do
          nil -> {:error, :not_found}
          %TeamMembership{} = m -> do_update_role(team, m, user, new_role)
        end
    end
  end

  defp do_update_role(team, %TeamMembership{role: current_role} = membership, user, new_role) do
    was_elevated = TeamMembership.admin?(current_role)

    Repo.transaction(fn ->
      # Demoting the last owner: last-owner guard UNDER A LOCK (TOCTOU). Lock the
      # owner row-set FOR UPDATE, then re-count inside the txn before mutating.
      if current_role == "owner" and new_role != "owner" and locked_owner_count(team) <= 1 do
        Repo.rollback(:last_owner)
      end

      updated =
        membership
        |> TeamMembership.changeset(%{role: new_role})
        |> Repo.update!()

      # A downgrade out of an elevated grant evicts the user's sessions.
      if was_elevated and new_role == "member" do
        {:ok, _} = delete_user_session_tokens(user)
      end

      updated
    end)
  end

  # Lock the team's owner ROW-SET FOR UPDATE and count it under the lock. PG
  # rejects `count(*) ... FOR UPDATE`, so SELECT the locked rows and `length/1`
  # them — the lock serializes concurrent removals/demotions through the
  # last-owner gate so a 2-owner team can never be drained to zero owners.
  defp locked_owner_count(team) do
    tid = team_id(team)

    from(m in TeamMembership,
      where: m.team_id == ^tid and m.role == "owner",
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> length()
  end

  @doc """
  Revoke a PAT the `user` owns (idempotent — sets `revoked_at`). Returns
  `{:error, :not_found}` (a 404 shape, no existence leak) when the id is not
  this user's PAT.
  """
  @spec revoke_personal_access_token(User.t() | binary(), binary()) ::
          {:ok, UserToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_personal_access_token(user, token_id) when is_binary(token_id) do
    uid = user_id(user)

    # A non-UUID token_id would make the Repo.get_by cast raise → 500; guard it
    # to the not_found (404) branch the API documents for an absent id.
    case Repo.uuid_or_nil(token_id) &&
           Repo.get_by(UserToken, id: token_id, user_id: uid, context: "pat") do
      nil ->
        {:error, :not_found}

      %UserToken{revoked_at: nil} = token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
        |> Repo.update()

      %UserToken{} = token ->
        # Already revoked — idempotent.
        {:ok, token}
    end
  end

  def revoke_personal_access_token(_user, _token_id), do: {:error, :not_found}

  @doc """
  Verify a presented PAT `plaintext`. Returns `{user, token}` when the row
  exists, is `context = "pat"`, unrevoked, and unexpired; otherwise `nil`.

  Best-effort stamps `last_used_at` (throttled to once / minute) so operators
  can spot dead tokens. A stamp failure is swallowed — never block auth on it.
  """
  @spec verify_personal_access_token(binary()) :: {User.t(), UserToken.t()} | nil
  def verify_personal_access_token(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserToken,
        where: t.token_hash == ^hash and t.context == "pat",
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserToken{user_id: uid} = token ->
        stamp_last_used(token, now)

        case Repo.get(User, uid) do
          nil -> nil
          user -> {user, token}
        end

      nil ->
        nil
    end
  end

  def verify_personal_access_token(_), do: nil

  # Best-effort, throttled `last_used_at` stamp. Kept OUT of the verify path's
  # critical work: a single update_all guarded by the throttle, with any error
  # logged and ignored (the column is for "is this token dead?", not precise
  # call counting). Never raises into the caller.
  defp stamp_last_used(%UserToken{id: id, last_used_at: prev}, now) do
    if is_nil(prev) or DateTime.diff(now, prev, :second) > @last_used_throttle_seconds do
      stamp = DateTime.truncate(now, :microsecond)

      try do
        from(t in UserToken, where: t.id == ^id)
        |> Repo.update_all(set: [last_used_at: stamp])
      rescue
        e ->
          Logger.warning("stamp_last_used failed for token #{id}: #{inspect(e)}")
          :ok
      end
    end

    :ok
  end

  ## Two-factor authentication (per-user, opt-in TOTP)
  ##
  ## Coolify parity: per-user TOTP with recovery codes, mirroring Laravel
  ## Fortify's lifecycle (enroll → confirm → challenge → disable / regenerate).
  ## The crypto lives in `Accounts.TwoFactor`; these functions orchestrate it
  ## against the Vault + Repo. `is_nil(user.two_factor_confirmed_at)` is the
  ## only "is it on?" check (Coolify's `two_factor_confirmed_at` semantics).

  @doc "Is 2FA fully enabled (confirmed) for this user?"
  @spec two_factor_enabled?(User.t()) :: boolean()
  def two_factor_enabled?(%User{two_factor_confirmed_at: nil}), do: false
  def two_factor_enabled?(%User{}), do: true

  @doc """
  Start enrollment: generate + encrypt a fresh TOTP secret, persist it with
  `confirmed_at` NULL (inert until confirmed — Fortify's `confirm => true`
  gate), and return the provisioning material for the QR panel.

  Returns `{:ok, %{user: user, otpauth_uri: ..., secret_base32: ...}}`. Calling
  it again before confirming rotates the pending secret (last enroll wins), and
  resets the replay-guard step so a re-enrolled secret starts fresh.
  """
  @spec start_two_factor_enrollment(User.t()) ::
          {:ok, %{user: User.t(), otpauth_uri: String.t(), secret_base32: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def start_two_factor_enrollment(%User{} = user) do
    secret = TwoFactor.gen_secret()
    enc = TwoFactor.encrypt_secret(secret)

    with {:ok, user} <- user |> User.two_factor_enroll_changeset(enc) |> Repo.update() do
      {:ok,
       %{
         user: user,
         otpauth_uri: TwoFactor.otpauth_uri(secret, user.email),
         secret_base32: TwoFactor.base32(secret)
       }}
    end
  end

  @doc """
  Confirm enrollment: verify `otp` against the pending secret. On success stamp
  `confirmed_at` and mint + store the recovery codes (hashed-then-encrypted).

  Returns `{:ok, [plaintext_code]}` (shown EXACTLY once) | `{:error, :invalid_otp}`
  | `{:error, :not_enrolled}`.
  """
  @spec confirm_two_factor(User.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :invalid_otp | :not_enrolled}
  def confirm_two_factor(%User{two_factor_secret: nil}, _otp), do: {:error, :not_enrolled}

  def confirm_two_factor(%User{} = user, otp) do
    with {:ok, secret} <- TwoFactor.decrypt_secret(user.two_factor_secret),
         {:ok, step} <- TwoFactor.matching_step(secret, otp) do
      pairs = TwoFactor.gen_recovery_codes()
      enc_codes = TwoFactor.encrypt_codes(Enum.map(pairs, &elem(&1, 1)))
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      # Seed the replay high-water mark with the enrollment step so the code that
      # confirmed 2FA can't turn around and clear the very first login challenge.
      {:ok, _} = user |> User.two_factor_confirm_changeset(enc_codes, now, step) |> Repo.update()
      {:ok, Enum.map(pairs, &elem(&1, 0))}
    else
      # :error  — secret undecryptable (key rotated away) or no step matched;
      #           either way, treat as an invalid OTP.
      _ -> {:error, :invalid_otp}
    end
  end

  @doc """
  Verify a login-challenge OTP against the user's CONFIRMED secret, consuming the
  matched time-step so the SAME code can never clear a second challenge (the
  replay guard). Returns `true` only when the code is valid AND its 30-second
  step is strictly newer than the last one this user consumed; the accepted step
  is then persisted. A confirmed-but-corrupted secret, an unconfirmed user, or a
  replayed/expired code all return `false` without side effects.
  """
  @spec verify_two_factor_otp(User.t(), String.t()) :: boolean()
  def verify_two_factor_otp(%User{two_factor_confirmed_at: nil}, _otp), do: false

  def verify_two_factor_otp(%User{two_factor_secret: enc} = user, otp) do
    with {:ok, secret} <- TwoFactor.decrypt_secret(enc),
         {:ok, step} <- TwoFactor.matching_step(secret, otp) do
      # Consume the step atomically: advance the high-water mark ONLY if this step
      # is still unclaimed (NULL, or strictly newer than the last). The guard lives
      # in the WHERE clause — mirroring oauth consume_state's conditional write —
      # so a stale in-memory struct can never replay a just-consumed code. rows==1
      # means WE consumed it; rows==0 means it was already spent (a replay).
      {rows, _} =
        from(u in User,
          where:
            u.id == ^user.id and
              (is_nil(u.two_factor_last_step) or u.two_factor_last_step < ^step)
        )
        |> Repo.update_all(set: [two_factor_last_step: step])

      rows == 1
    else
      _ -> false
    end
  end

  @doc """
  Consume a one-time recovery code: if its hash is in the stored set, remove it,
  re-encrypt the remainder, persist, and return `{:ok, user}`. Otherwise
  `{:error, :invalid}`. A used code is gone — consumption is the only mutation.
  """
  @spec consume_recovery_code(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid | Ecto.Changeset.t()}
  def consume_recovery_code(%User{two_factor_confirmed_at: nil}, _code), do: {:error, :invalid}

  def consume_recovery_code(%User{} = user, code) when is_binary(code) do
    target = TwoFactor.hash_code(code)

    # The code set is an encrypted blob, so there's no single-query CAS: take a
    # row lock, re-read the CURRENT set (never the passed-in struct — it may be
    # stale and still carry a consumed code), and only then delete + re-encrypt.
    # FOR UPDATE serializes concurrent consumers so a code is spent exactly once.
    Repo.transaction(fn ->
      locked = Repo.get!(User, user.id, lock: "FOR UPDATE")
      hashes = TwoFactor.decrypt_codes(locked.two_factor_recovery_codes)

      if target in hashes do
        enc = TwoFactor.encrypt_codes(List.delete(hashes, target))

        case locked |> User.two_factor_codes_changeset(enc) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        Repo.rollback(:invalid)
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  def consume_recovery_code(%User{}, _code), do: {:error, :invalid}

  @doc "Disable 2FA: null all four columns (Coolify's DELETE semantics)."
  @spec disable_two_factor(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def disable_two_factor(%User{} = user),
    do: user |> User.two_factor_disable_changeset() |> Repo.update()

  @doc """
  Replace the recovery-code set (every old code is invalidated). Returns
  `{:ok, [plaintext_code]}` (shown once) | `{:error, :not_enabled}`.
  """
  @spec regenerate_recovery_codes(User.t()) ::
          {:ok, [String.t()]} | {:error, :not_enabled | Ecto.Changeset.t()}
  def regenerate_recovery_codes(%User{two_factor_confirmed_at: nil}), do: {:error, :not_enabled}

  def regenerate_recovery_codes(%User{} = user) do
    pairs = TwoFactor.gen_recovery_codes()
    enc = TwoFactor.encrypt_codes(Enum.map(pairs, &elem(&1, 1)))

    with {:ok, _} <- user |> User.two_factor_codes_changeset(enc) |> Repo.update() do
      {:ok, Enum.map(pairs, &elem(&1, 0))}
    end
  end

  ## Two-phase login: the 2fa-pending challenge token
  ##
  ## After a correct password but BEFORE the OTP clears, mint a short-lived
  ## token that rides the existing user_tokens.context column with context
  ## "2fa_pending". It is NOT a session token, so `verify_user_session_token/1`
  ## (which filters on context == "session") rejects it everywhere except the
  ## challenge endpoint. Same hash-at-rest discipline as session tokens.

  @doc """
  Mint a 2fa-pending token (#{@two_factor_pending_minutes} min TTL) for `user`.
  Returns the plaintext exactly once.
  """
  @spec create_two_factor_pending_token(User.t()) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_two_factor_pending_token(%User{} = user) do
    plaintext = generate_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@two_factor_pending_minutes * 60, :second)
      |> DateTime.truncate(:microsecond)

    %UserToken{}
    |> UserToken.changeset(%{
      user_id: user.id,
      context: "2fa_pending",
      token_hash: UserToken.hash_token(plaintext),
      expires_at: expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolve a 2fa-pending token to its user (unexpired, context-checked), or `nil`.
  A "session" token never resolves here and vice-versa.
  """
  @spec verify_two_factor_pending_token(binary()) :: User.t() | nil
  def verify_two_factor_pending_token(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserToken,
        where: t.token_hash == ^hash and t.context == "2fa_pending",
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserToken{user_id: user_id} -> Repo.get(User, user_id)
      nil -> nil
    end
  end

  def verify_two_factor_pending_token(_), do: nil

  @doc "Delete every 2fa-pending token for a user (after a successful challenge)."
  @spec delete_two_factor_pending_tokens(User.t()) :: {non_neg_integer(), nil}
  def delete_two_factor_pending_tokens(%User{id: user_id}) do
    from(t in UserToken, where: t.user_id == ^user_id and t.context == "2fa_pending")
    |> Repo.delete_all()
  end

  ## Onboarding

  @doc """
  The team's onboarding view: the durable persisted state PLUS a server-computed
  three-step checklist.

  `completed?` is true once `onboarding_completed_at` is set (the team either
  finished or dismissed). Each checklist step is `%{key, done}` where `done` is
  derived LIVE from the domain — `has_subscription` from `Billing`,
  `has_instance` from `Registry`, `has_published_doc` from an agent-reported
  `content` event OR a user ack — so the checklist self-heals if the user
  subscribed or launched OUTSIDE the wizard (no drift, exactly like Coolify
  recomputes from domain rows rather than trusting a cached flag).
  """
  @spec onboarding_status(Team.t()) :: map()
  def onboarding_status(%Team{} = team) do
    has_subscription = not is_nil(Billing.active_subscription(team))
    instances = Registry.list_barkparks(team)
    has_instance = instances != []

    state = team.onboarding_state || %{}
    acked = Map.get(state, "acked", [])

    steps = [
      %{key: "subscription", done: has_subscription},
      %{key: "instance", done: has_instance},
      # published_doc: the control plane can't see CMS content directly, so the
      # step is done when EITHER an agent reported published content OR the user
      # ticked it (acked). Honest: we don't fake a signal we can't observe.
      %{key: "published_doc", done: published_doc?(instances) or "published_doc" in acked}
    ]

    %{
      completed_at: team.onboarding_completed_at,
      completed?: not is_nil(team.onboarding_completed_at),
      last_step: Map.get(state, "last_step"),
      steps: steps,
      all_done?: Enum.all?(steps, & &1.done)
    }
  end

  @doc "Persist the resume pointer (which step the user last viewed)."
  @spec advance_onboarding(Team.t(), String.t()) ::
          {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def advance_onboarding(%Team{} = team, step) do
    state = Map.merge(team.onboarding_state || %{}, %{"last_step" => step})
    update_onboarding(team, %{onboarding_state: state})
  end

  @doc "Manually tick a step the server can't verify (currently only published_doc)."
  @spec ack_onboarding_step(Team.t(), String.t()) ::
          {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def ack_onboarding_step(%Team{} = team, step) do
    state = team.onboarding_state || %{}
    acked = [step | Map.get(state, "acked", [])] |> Enum.uniq()
    update_onboarding(team, %{onboarding_state: Map.put(state, "acked", acked)})
  end

  @doc """
  Finish onboarding — stamps `completed_at` once, then is idempotent (a second
  call returns the already-stamped team without rewriting the timestamp).
  """
  @spec complete_onboarding(Team.t()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def complete_onboarding(%Team{onboarding_completed_at: nil} = team),
    do: update_onboarding(team, %{onboarding_completed_at: now()})

  def complete_onboarding(%Team{} = team), do: {:ok, team}

  @doc """
  Dismiss the checklist early — Coolify's `skipBoarding`. Also stamps
  `completed_at`, so a dismissed checklist never reappears.
  """
  @spec skip_onboarding(Team.t()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def skip_onboarding(%Team{} = team), do: complete_onboarding(team)

  defp update_onboarding(team, attrs) do
    team |> Team.onboarding_changeset(attrs) |> Repo.update()
  end

  # The one non-trivial derivation. CMS documents live INSIDE the provisioned
  # api/ instance, not in the control plane, so "has published a doc" is not
  # directly observable from cloud/. We treat it as true when the on-box agent
  # has posted a `content` event with published_count > 0 for any of the team's
  # instances. Until the agent emits that, the step is reachable via the user-ack
  # path (ack_onboarding_step/2) — so the feature ships today and tightens
  # automatically when the agent learns to report content.
  defp published_doc?([]), do: false

  defp published_doc?(instances) do
    ids = Enum.map(instances, & &1.id)

    Repo.exists?(
      from e in AgentEvent,
        where: e.barkpark_id in ^ids,
        where: e.type == "content",
        where: fragment("(?->>'published_count')::int > 0", e.payload)
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  ## Helpers

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id), do: id

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id
  defp team_id(nil), do: nil

  ## OAuth internals (oauth-sso)

  # Steps 2 + 3 of the linking precedence for an as-yet-unlinked identity, in ONE
  # flat Repo.transaction (no nested transaction): resolve-or-birth the user,
  # then insert the identity. A unique violation on the identity means a
  # concurrent callback linked it first — roll back and reconcile OUTSIDE the
  # aborted transaction by re-reading the now-linked user.
  defp birth_or_link_oauth(provider, uid, email) do
    result =
      Repo.transaction(fn ->
        user = find_or_birth_oauth_user!(provider, uid, email)

        case link_external_identity(user, %{provider: provider, provider_uid: uid, email: email}) do
          {:ok, _identity} ->
            user

          {:error, %Ecto.Changeset{} = cs} ->
            if unique_violation?(cs),
              do: Repo.rollback(:identity_conflict),
              else: Repo.rollback(cs)
        end
      end)

    case result do
      {:ok, user} ->
        {:ok, user}

      # A concurrent callback linked this identity first; its tx aborted ours on
      # the unique violation. Re-fetch OUTSIDE the aborted tx.
      {:error, :identity_conflict} ->
        case get_user_by_external_identity(provider, uid) do
          %User{} = user -> {:ok, user}
          nil -> {:error, :identity_conflict}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Precedence step 2 (verified-email CONVERGENCE onto an existing account) then
  # step 3 (birth a fresh OAuth account). Reached with a non-nil email only when
  # the IdP VERIFIED it (parse_identity drops unverified to nil), so converging
  # is safe. Runs INSIDE birth_or_link_oauth's transaction — a birth failure
  # Repo.rollbacks the whole thing. The convergence path returns the existing
  # user UNTOUCHED (no password/team/role mutation); only a new identity row is
  # later added by the caller.
  defp find_or_birth_oauth_user!(provider, uid, email) do
    case email && get_user_by_email(email) do
      %User{} = existing ->
        existing

      _ ->
        # No email match (or no email at all) → birth a fresh OAuth-only account
        # with the SAME entitlement chain as a password signup. A withheld email
        # gets a stable synthetic one so the email-required schema is satisfied;
        # the durable link is the (provider, uid) row, not this address.
        birth_oauth_user!(email || synthetic_oauth_email(provider, uid))
    end
  end

  # Birth a passwordless OAuth user + team + owner membership + trial +
  # notification settings — the SAME chain the router's password `register/3`
  # runs, so an OAuth signup is not a second-class citizen (it is entitled to a
  # trial and gets its notification-settings row). Already inside the caller's
  # transaction, so a failure Repo.rollbacks rather than opening a nested tx.
  defp birth_oauth_user!(email) do
    with {:ok, user} <- register_oauth_user(email),
         {:ok, team} <- create_oauth_team(user),
         {:ok, _membership} <- add_member(team, user, "owner"),
         {:ok, _trial} <- Billing.grant_trial(team),
         {:ok, _settings} <- Notifications.ensure_settings(team) do
      user
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Insert a passwordless User via the OAuth changeset (email only + a random
  # hashed_password). The account can never be logged into by password until a
  # future reset sets a real one.
  defp register_oauth_user(email) do
    %User{}
    |> User.oauth_changeset(%{email: email})
    |> Repo.insert()
  end

  # A stable, valid, unique placeholder email for a provider that withholds a
  # verified one (GitHub with a private primary). Satisfies the @ email format;
  # the real identity is the external_identities row, not this string.
  defp synthetic_oauth_email(provider, uid) do
    "#{provider}-#{uid}@oauth.users.barkpark.cloud"
  end

  # Birth a personal team for `user`, slug derived from the email local-part and
  # deduped against teams.slug (a pre-insert lookup, so a collision becomes
  # name-2, name-3, … rather than a unique violation that would abort the signup
  # transaction — mirrors the router's create_signup_team).
  defp create_oauth_team(user) do
    local = user.email |> String.split("@") |> List.first()
    create_team(%{name: local, slug: dedupe_oauth_slug(slugify_oauth(local), 0)})
  end

  defp dedupe_oauth_slug(base_slug, attempt) when attempt < 50 do
    candidate = if attempt == 0, do: base_slug, else: "#{base_slug}-#{attempt + 1}"

    if get_team_by_slug(candidate),
      do: dedupe_oauth_slug(base_slug, attempt + 1),
      else: candidate
  end

  defp dedupe_oauth_slug(base_slug, _attempt), do: base_slug

  # name → slug: lowercase, non-alnum → hyphen, trim hyphens; random fallback so
  # an all-symbol local-part still yields a valid slug.
  defp slugify_oauth(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if base == "",
      do:
        "team-" <>
          (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false) |> String.downcase()),
      else: base
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique end)
  end
end
