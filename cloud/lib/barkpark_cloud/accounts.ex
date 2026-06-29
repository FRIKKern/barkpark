defmodule BarkparkCloud.Accounts do
  @moduledoc """
  The Cloud identity context — Users, Teams, and the membership binding
  between them, plus email+password authentication.

  This is what makes "one login for all your Barkparks" real: a single User
  authenticates here, and Team memberships fan that identity out across the
  control plane. Scope is deliberately narrow (YAGNI):

    * email + password ONLY — no OAuth, no sessions/tokens, no web layer, no
      password-reset / email-confirmation. Those are later tasks. What lives
      here is the callable, tested Accounts context + auth functions.

  Authentication entry points:

    * `register_user/1` — create a User from attrs (hashes the password).
    * `get_user_by_email_and_password/2` — verify a login, timing-safe.

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

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.{Team, TeamInvitation, TeamMembership, User, UserToken}

  # How long a freshly minted invitation stays acceptable. A module attribute
  # mirroring `UserToken.@default_validity_days`; promote to config only if ops
  # needs to tune it.
  @invite_validity_days 7

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

  @doc "Fetch a user by id, or nil."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

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

  @doc "Fetch a team by id, or nil."
  @spec get_team(binary()) :: Team.t() | nil
  def get_team(id), do: Repo.get(Team, id)

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
    case BarkparkCloud.Accounts.Authz.can_grant?(actor, team, role) do
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

    case Repo.get_by(UserToken, id: token_id, user_id: uid) do
      %UserToken{} = t -> stamp_revoked(t)
      nil -> {:error, :not_found}
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

    base = from t in UserToken, where: t.user_id == ^uid, where: is_nil(t.revoked_at)

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

    from(t in UserToken,
      where: t.user_id == ^uid,
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
  """
  @spec create_personal_access_token(User.t(), Team.t() | binary(), map()) ::
          {:ok, binary(), UserToken.t()} | {:error, Ecto.Changeset.t()}
  def create_personal_access_token(%User{} = user, team, attrs) do
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
  Delete ALL of `user`'s session tokens — an immediate logout everywhere. The
  Cloud analogue of Coolify's `RevokeUserTeamTokens` (it deletes session rows
  rather than flag a `revoked_at` column we don't have).

  NOTE: Cloud session tokens are GLOBAL, not per-team (unlike Coolify's
  team-scoped tokens). In the single-team beta, removing a user from their team
  logs them out entirely — acceptable and even desirable. When multi-team lands,
  narrow this to the team the action targeted (add a `team_id` to user_tokens, or
  scope by team). Returns `{:ok, count}`.
  """
  @spec delete_user_session_tokens(User.t() | binary()) :: {:ok, non_neg_integer()}
  def delete_user_session_tokens(user) do
    uid = user_id(user)
    {count, _} = from(t in UserToken, where: t.user_id == ^uid) |> Repo.delete_all()
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

        expires_at =
          DateTime.utc_now()
          |> DateTime.add(@invite_validity_days * 24 * 3600, :second)
          |> DateTime.truncate(:microsecond)

        attrs = %{
          team_id: team.id,
          email: norm,
          role: role,
          invited_by_id: invited_by.id,
          token_hash: TeamInvitation.hash_token(raw),
          expires_at: expires_at
        }

        case %TeamInvitation{} |> TeamInvitation.changeset(attrs) |> Repo.insert() do
          {:ok, inv} -> {:ok, %{invitation: inv, token: raw}}
          {:error, cs} -> {:error, cs}
        end
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

  @doc "Revoke a pending invitation by id, team-scoped. `{:ok, inv}` | `{:error, :not_found}`."
  @spec revoke_invitation(Team.t(), binary()) ::
          {:ok, TeamInvitation.t()} | {:error, :not_found}
  def revoke_invitation(%Team{id: tid}, inv_id) when is_binary(inv_id) do
    case Repo.get_by(TeamInvitation, id: inv_id, team_id: tid) do
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
  Remove `user` from `team` and evict their live sessions (Coolify's
  `RevokeUserTeamTokens` analogue). Guards the last-owner invariant: the sole
  owner cannot be removed. `{:ok, :removed}` | `{:error, :not_found | :last_owner}`.
  """
  @spec remove_member(Team.t(), User.t()) ::
          {:ok, :removed} | {:error, :not_found | :last_owner}
  def remove_member(%Team{} = team, %User{} = user) do
    case get_membership(team, user) do
      nil ->
        {:error, :not_found}

      %TeamMembership{role: "owner"} = m ->
        if owner_count(team) <= 1, do: {:error, :last_owner}, else: do_remove(m, user)

      %TeamMembership{} = m ->
        do_remove(m, user)
    end
  end

  defp do_remove(membership, user) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.delete!(membership)
        # Immediate logout — the removed user's bearer tokens stop working now.
        {:ok, _} = delete_user_session_tokens(user)
        :removed
      end)

    {:ok, result}
  end

  @doc """
  Change `user`'s role in `team` to `new_role`, guarding the last-owner
  invariant on a downgrade away from owner. On a downgrade from an admin/owner
  grant to `member`, the user's sessions are also evicted so a demoted user
  loses elevated access immediately (mirrors Coolify revoking tokens on a role
  change). `{:ok, %TeamMembership{}}` | `{:error, :invalid_role | :not_found | :last_owner}`.
  """
  @spec update_member_role(Team.t(), User.t(), String.t()) ::
          {:ok, TeamMembership.t()} | {:error, :invalid_role | :not_found | :last_owner}
  def update_member_role(%Team{} = team, %User{} = user, new_role) do
    cond do
      new_role not in TeamMembership.roles() ->
        {:error, :invalid_role}

      true ->
        case get_membership(team, user) do
          nil ->
            {:error, :not_found}

          %TeamMembership{role: "owner"} when new_role != "owner" ->
            if owner_count(team) <= 1,
              do: {:error, :last_owner},
              else: do_update_role(user, team, new_role)

          %TeamMembership{} ->
            do_update_role(user, team, new_role)
        end
    end
  end

  defp do_update_role(user, team, new_role) do
    membership = get_membership(team, user)
    was_elevated = TeamMembership.admin?(membership.role)

    {:ok, updated} =
      Repo.transaction(fn ->
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

    {:ok, updated}
  end

  defp owner_count(team) do
    tid = team_id(team)

    from(m in TeamMembership,
      where: m.team_id == ^tid and m.role == "owner",
      select: count(m.id)
    )
    |> Repo.one()
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

    case Repo.get_by(UserToken, id: token_id, user_id: uid, context: "pat") do
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

  ## Helpers

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id), do: id

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id
  defp team_id(nil), do: nil
end
