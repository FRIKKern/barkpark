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

  # How long a minted SSE stream ticket stays redeemable, in SECONDS — NOT the
  # house `*_minutes` idiom, because a minute is the entire budget here and
  # minutes would be a lossy unit for it. 60s is ~20x the measured ~3000ms
  # native EventSource reconnect delay, so a ticket comfortably survives the
  # mint→open round trip on a slow link, while the copy of it left in an access
  # log is worthless within a minute. The window is SELF-HEALING under the
  # client's remint-on-error loop: an expired ticket costs exactly one extra
  # mint round-trip, never a dead stream. The ~3000ms figure is Chrome 150 only
  # (Safari is untested and has historically diverged on EventSource error
  # handling), which is why the TTL sits an order of magnitude above it rather
  # than tuned tightly against one browser.
  @sse_ticket_validity_seconds 60

  # cch-w10 — how long a one-time OAuth EXCHANGE CODE stays redeemable. 120s, and
  # the number is sized against a measured page weight rather than copied from the
  # SSE ticket above: the window has to cover IdP 302 → COLD SPA BOOT → POST, and
  # a cold boot here downloads app.js (959,628 bytes) plus app.css (198,954) off a
  # `Plug.Static` with no `gzip:` option and no `.gz` siblings on disk. The SSE
  # ticket's 60s is NOT the same physics — its redeemer is an `EventSource` opened
  # in the same tick as the mint, with the app already parsed and running.
  #
  # It is still short by design: the code is the ONLY thing on the wire that a
  # response-header log can capture, and it buys the holder nothing after two
  # minutes or after the browser's own POST, whichever lands first.
  @oauth_exchange_validity_seconds 120

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

  @typedoc """
  Which of `get_or_create_user_from_oauth/1`'s three precedence arms ran.
  See that function's "The BRANCH is part of the return" section.
  """
  @type oauth_branch :: :existing | :linked | :created

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

  Returns `{:ok, %User{}, branch}` or `{:error, term}`. A concurrent
  double-callback that races to link the same identity is reconciled to the
  now-linked user rather than surfacing a 500.

  ## The BRANCH is part of the return, not an inference

  The three precedence arms above are three DIFFERENT events, and until
  cch-w53-bl-oauth-linked-needs-a-branch-reporting-return this function
  collapsed them into one bare `{:ok, user}`. A caller that wanted to record
  "this account gained a provider" had no way to tell arm 2 (a LINK onto an
  account that already existed) from arm 3 (a first-ever signup), so any audit
  producer wired to it would have stamped `oauth.linked` on every OAuth signup —
  a trail entry describing a linking event that did not happen.

  So the branch is reported:

    * `:existing` — arm 1, plus the concurrent-callback reconcile. Nothing was
      created and nothing was linked on THIS call; the identity was already
      ours.
    * `:linked` — arm 2. An account that already existed gained a new provider
      identity. This is the ONE branch `oauth.linked` may be produced on.
    * `:created` — arm 3. A first-ever signup. An identity row was inserted, but
      there was no prior account for it to be "linked" to.

  It is a three-value atom rather than a boolean on purpose: `:existing` and
  `:created` are both "not a link" for the audit question and would collapse
  under a boolean, while they are opposites for every other question a caller
  could ask (one wrote no rows at all, the other birthed a user, a team, a
  membership, a trial and a settings row).
  """
  @spec get_or_create_user_from_oauth(%{
          provider: String.t(),
          provider_uid: String.t(),
          email: String.t() | nil
        }) :: {:ok, User.t(), oauth_branch()} | {:error, term()}
  def get_or_create_user_from_oauth(%{provider: provider, provider_uid: uid} = identity)
      when is_binary(provider) and is_binary(uid) do
    email = Map.get(identity, :email)

    case get_user_by_external_identity(provider, uid) do
      %User{} = user -> {:ok, user, :existing}
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
    * `:actor_user_id` — only events this member caused ("what did Alice do?").
                       System/webhook events carry a nil actor and are therefore
                       never matched by an actor filter.
    * `:action_prefix` — narrow to one noun of the closed `noun.verb` action
                       vocabulary (`"webhook"` → every `webhook.*` event).
                       Matched as `LIKE '<prefix>%'` with the caller's `%`, `_`
                       and `\\` ESCAPED, so a filter value can never widen its
                       own match (`_` is a legitimate character in the
                       vocabulary — `notifications.channels_changed` — and must
                       stay a literal, not a single-char wildcard).

  Preloads `:actor_user` so the read renders "alice@x invited a member" without
  an N+1. Strictly team-scoped — never crosses teams.
  """
  @spec list_audit_events(Team.t() | binary(), keyword()) :: [AuditEvent.t()]
  def list_audit_events(team, opts \\ []) do
    tid = team_id(team)
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)

    AuditEvent
    |> where([e], e.team_id == ^tid)
    |> maybe_audit_before(opts[:before], opts[:before_id])
    |> maybe_audit_target(opts[:target_type], opts[:target_id])
    |> maybe_audit_actor(opts[:actor_user_id])
    |> maybe_audit_action_prefix(opts[:action_prefix])
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> preload(:actor_user)
    |> Repo.all()
  end

  # The `target_type` an account-security row stamps for the human it is about.
  # `audit_account_security/2` in the router writes `target_type: "user",
  # target_id: user.id` alongside `actor_user_id: user.id`; the self predicate
  # below is only meaningful against that spelling, so it is named once here
  # rather than inlined as a bare string in a `where`.
  @self_audit_target_type "user"

  @doc """
  The MEMBER SELF-READ over account-security audit rows: the rows where `user` is
  BOTH THE ACTOR AND THE TARGET. Newest first, same shape and same cursor as
  `list_audit_events/2`.

  THE PREDICATE IS COMPOUND, DELIBERATELY (the owner's ruling of 2026-08-23).
  "Self" on an audit row is not a column — a row carries an actor, a target and a
  team. This function requires ALL of:

    * `actor_user_id == user.id` — the member did it, and
    * `target_type == "user"` AND `target_id == user.id` — it was done TO them.

  A row where the member is the TARGET but not the actor (an admin disabling
  someone else's 2FA) is NOT self-scoped and is NOT returned; neither is the
  reverse (the member acting on someone else). Both halves are load-bearing: a
  single-column check would satisfy one direction and silently fail the other.

  The general team trail (`list_audit_events/2`, `GET /v1/audit`) is UNTOUCHED
  and stays admin-gated. This is an additional, strictly narrower read, not a
  widening of that one.

  ## THE MOVED-MEMBER DECISION — `:team_scope`

  Audit team scoping resolves by PRIMARY-TEAM-AT-WRITE-TIME (`audit_account_security/2`
  stamps `conn.assigns.current_team`), so a member whose primary team later
  changes has rows sitting under a FORMER team. Either answer is implementable
  and the query would silently pick one, so the choice is an EXPLICIT OPTION with
  a default, never something emergent:

    * `:across_teams` (DEFAULT, and the shipped behaviour) — the member sees
      their own actor=self AND target=self rows REGARDLESS of which team each row
      was written under. The rows are about THEM, not about the team: "I enabled
      2FA on my account" is a fact about one human's credentials, and losing
      sight of it because an admin moved them between teams would make the
      security history a member is being given deliberately incomplete — the
      exact cost the ruling refused to carry.
    * `:current_team` — clamp to one team; pass `:team` alongside. Not wired to
      any route today; it exists so the alternative is a NAMED clause a reader
      can see was considered, not an absence.

  `opts`: `:limit` (default 50, capped 200, floored 1), `:before` + `:before_id`
  (the same compound keyset cursor as `list_audit_events/2`), `:action_prefix`,
  `:team_scope` (`:across_teams` | `:current_team`) and `:team`.

  Preloads `:actor_user`, so the row renders identically to a `/v1/audit` row.
  """
  @spec list_self_security_audit_events(User.t() | binary(), keyword()) :: [AuditEvent.t()]
  def list_self_security_audit_events(user, opts \\ []) do
    uid = user_id(user)
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)

    AuditEvent
    |> where([e], e.actor_user_id == ^uid)
    |> where([e], e.target_type == ^@self_audit_target_type and e.target_id == ^uid)
    |> self_audit_team_scope(Keyword.get(opts, :team_scope, :across_teams), opts[:team])
    |> maybe_audit_before(opts[:before], opts[:before_id])
    |> maybe_audit_action_prefix(opts[:action_prefix])
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> preload(:actor_user)
    |> Repo.all()
  end

  # The moved-member decision, IN CODE. Two named clauses, so the shipped answer
  # is a value the caller passes and not a property of whichever `where` happened
  # to be written. `:across_teams` adds NO team predicate at all — that absence is
  # the decision, which is why it has a clause of its own instead of being the
  # fall-through of a `maybe_`.
  defp self_audit_team_scope(query, :across_teams, _team), do: query

  defp self_audit_team_scope(query, :current_team, team) do
    where(query, [e], e.team_id == ^team_id(team))
  end

  # The keyset cursor. The trail is ordered by the COMPOUND key
  # `(inserted_at DESC, id DESC)`, so the page predicate has to compare that same
  # compound key or the page boundary is not a real cut: with a stamp-only
  # `<`, two rows sharing an `inserted_at` that straddle a boundary lose the far
  # side of the tie PERMANENTLY and SILENTLY (routine the moment a burst of
  # audit writes lands in the same microsecond). `before_id` is the second half
  # of the cursor, and the predicate is strictly lexicographic on the pair.
  #
  # BACKWARD COMPATIBLE by construction: the tiebreak arm engages only when BOTH
  # halves arrive, so a bookmarked `?before=<stamp>` URL keeps the exact
  # stamp-only cutoff it has always had. `id` is a `:binary_id`, so a non-UUID
  # from a query string would raise Ecto.Query.CastError — it is cast first, and
  # anything that is not a UUID degrades to the stamp-only arm rather than 500ing.
  #
  # The tiebreak arm is a ROW comparator, not the equivalent OR-decomposition: the
  # two select the same rows, but only the ROW form can SEEK. On the EXISTING
  # `(team_id, inserted_at)` index the OR form leaves `Index Cond:` carrying
  # `team_id` alone and drops the stamp bound into `Filter:` — a full scan of the
  # team's trail per page (542 buffers / 4.284 ms for a 50-row page on a 250k-row
  # corpus); the ROW form lifts `inserted_at <= $2` into the Index Cond (14
  # buffers / 0.104 ms), with NO migration. Prophylactic at today's row counts.
  #
  # THE SPELLING IS LOAD-BEARING. `type(^ts, :utc_datetime_usec)` renders
  # `$2::timestamp` — a naive timestamp against a `timestamptz` column, coerced
  # through the SESSION TimeZone, which slips the page boundary by the server's
  # UTC offset. `$2` is left UNCAST so Postgres infers `timestamptz` from the
  # ROW's left operand. The uuid half needs `type(^uuid, Ecto.UUID)` or Ecto never
  # dumps the string and Postgrex raises "expected a binary of 16 bytes".
  #
  # ROW comparison differs from the OR form on NULLs, and no NULL is reachable:
  # `audit_events.id` is the primary key and `inserted_at` comes from
  # `timestamps(type: :utc_datetime_usec, updated_at: false)` — both NOT NULL —
  # and both params are non-nil by the clause head and the successful cast.
  defp maybe_audit_before(query, nil, _before_id), do: query

  defp maybe_audit_before(query, %DateTime{} = ts, before_id) when is_binary(before_id) do
    case Ecto.UUID.cast(before_id) do
      {:ok, uuid} ->
        where(
          query,
          [e],
          fragment("(?,?) < (?,?)", e.inserted_at, e.id, ^ts, type(^uuid, Ecto.UUID))
        )

      :error ->
        where(query, [e], e.inserted_at < ^ts)
    end
  end

  defp maybe_audit_before(query, %DateTime{} = ts, _before_id),
    do: where(query, [e], e.inserted_at < ^ts)

  defp maybe_audit_target(query, type, id) when is_binary(type) and is_binary(id),
    do: where(query, [e], e.target_type == ^type and e.target_id == ^id)

  # REVIEW FIX (GR80 leg 2): `target_type` ALONE is a legitimate filter — "show me
  # everything that happened to instances" — and it is the one the Activity page's
  # chip row has been sending since I-01. Before this clause the pair-guard above
  # fell through to the catch-all, so `?target_type=barkpark` with no `target_id`
  # was silently a NO-OP: the chip lit, the request went out, and the server
  # answered the whole unfiltered trail. That is a filter UI that lies, which is
  # worse than no filter UI. An empty string stays a no-op (an absent filter must
  # never narrow to nothing).
  defp maybe_audit_target(query, type, _id) when is_binary(type) and type != "",
    do: where(query, [e], e.target_type == ^type)

  defp maybe_audit_target(query, _type, _id), do: query

  # actor_user_id arrives from a query string, so it is NOT trusted to be a UUID:
  # a raw non-uuid binary in a :binary_id comparison raises Ecto.Query.CastError
  # (a 500 on a typo'd filter). Cast first; anything that is not a UUID is simply
  # not a filter.
  defp maybe_audit_actor(query, actor_user_id) when is_binary(actor_user_id) do
    case Ecto.UUID.cast(actor_user_id) do
      {:ok, uuid} -> where(query, [e], e.actor_user_id == ^uuid)
      :error -> query
    end
  end

  defp maybe_audit_actor(query, _), do: query

  # Prefix-match one noun of the closed `noun.verb` action vocabulary. The LIKE
  # metacharacters in the caller's value are escaped (Postgres LIKE's default
  # escape character is `\`), so `%` / `_` in a filter are literals and a filter
  # can never match MORE than it spells.
  defp maybe_audit_action_prefix(query, prefix) when is_binary(prefix) and prefix != "" do
    pattern = escape_like(prefix) <> "%"
    where(query, [e], like(e.action, ^pattern))
  end

  defp maybe_audit_action_prefix(query, _), do: query

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

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
    * `:origin` — HOW this session was established, as known BY THE CALLER
      ("password", "two_factor", "oauth:<provider>", "password_change",
      "register", "device_link"). OMITTED means unknown, and unknown is stored
      as NULL and rendered as nothing — this function never infers an origin
      from the other opts, and nothing backfills the column. Deliberately NOT
      folded into the web layer's `session_opts/1` helper: five of the six mint
      sites share that helper, so one shared value there would make a single
      helper answer for five different origins.

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
      origin: Keyword.get(opts, :origin),
      last_used_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Once-per-minute is enough resolution for "is this device still around?";
  # inside the window the stamp is skipped so a chatty SPA does not turn every
  # read into an UPDATE. Mirrors the PAT twin's `@last_used_throttle_seconds`
  # and api/'s `@session_last_used_throttle_seconds` (both 60).
  @session_last_used_throttle_seconds 60

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
  def verify_user_session_token(plaintext), do: verify_user_session_token(plaintext, [])

  @doc """
  `verify_user_session_token/1` with control over the `last_used_at` stamp.

  Options:

    * `:touch` — `true` (default) stamps EAGERLY, right here, throttled to the
      `#{@session_last_used_throttle_seconds}s` window. `false` stamps NOTHING
      and leaves it to the caller.

  WHY THE OPTION EXISTS. `last_used_at` is a LIVENESS claim — the sessions card
  renders it as "Active just now" — but this function runs during
  AUTHENTICATION, strictly before AUTHORIZATION has ruled. `Web.Auth` has six
  distinct `forbidden(conn)` sites, every one of them downstream of this call,
  so an eager stamp here makes a device that was REFUSED 403 look active. A
  throttle cannot fix that (an idle device satisfies any staleness guard —
  measured: idle 3600s, one request, 403, stamp still jumped a full hour), so
  the plug pipeline passes `touch: false` and re-stamps from
  `Plug.Conn.register_before_send/2` once the status is known.

  `touch: true` remains the default for the callers that hold no `Plug.Conn` and
  make no authorization decision of their own.

  THE SSE STREAM OPEN IS NO LONGER ONE OF THEM, and the paragraph that used to
  say so was refuted by the route's own 422. `GET /v1/events` resolves its header
  credential here and only THEN answers `no_team`, so the eager stamp made a
  teamless header client that was REFUSED print as freshly active. The claim that
  deferring "would buy nothing" rested on the conn status being set once at
  `send_chunked` — true for the stream, false for the refusal, which never
  reaches `send_chunked` at all. The router now passes `touch: false` there and
  re-stamps from `register_before_send/2`, which fires for `send_chunked` as well
  — so a served stream still stamps at its 200, at the same instant the eager
  call did, and nothing is deferred past the park.
  """
  @spec verify_user_session_token(binary(), keyword()) :: User.t() | nil
  def verify_user_session_token(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
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
        if Keyword.get(opts, :touch, true), do: touch_last_used(hash, now)
        Repo.get(User, user_id)

      nil ->
        nil
    end
  end

  def verify_user_session_token(_, _), do: nil

  @doc """
  Stamp `last_used_at` on the session row behind `plaintext`, throttled to the
  #{@session_last_used_throttle_seconds}s window. Always `:ok` — a token revoked
  or deleted since the verify matches zero rows, which `update_all` treats as a
  no-op.

  Public because the stamp does not belong at the verify: `Web.Auth` defers it
  to `register_before_send/2` so it fires only for a request the platform
  actually SERVED (`conn.status < 400`), never for one it refused.
  """
  @spec touch_session_last_used(binary()) :: :ok
  def touch_session_last_used(plaintext) when is_binary(plaintext) do
    touch_last_used(UserToken.hash_token(plaintext), DateTime.utc_now())
  end

  def touch_session_last_used(_), do: :ok

  # Best-effort "last seen" refresh keyed by hash. The throttle rides the WHERE
  # clause rather than a read-then-write, so the skip costs one statement and
  # cannot race itself. `last_used_at <= now - window` is the `>=`-seconds
  # predicate: a row stamped EXACTLY `window` seconds ago is stale and writes.
  # update_all never raises on a zero-row match, so a token revoked between the
  # verify SELECT and this UPDATE is a harmless no-op — the return contract
  # (User | nil) is unaffected.
  #
  # FAIL-SOFT, in the same shape as `touch_pat_last_used/1`'s rescue. A zero-row
  # match is a no-op, but the statement itself can still RAISE — a pool timeout,
  # a dropped connection, a deadlock. Since the wave-8 fix this write runs inside
  # a `Plug.Conn.register_before_send/2` callback, and an exception raised there
  # ESCAPES `send_resp`: the request was already SERVED, and a transient DB
  # hiccup while stamping "last seen" would convert that served 200 into a 500.
  # The column answers "is this token dead?", never a billed count — so a failed
  # stamp is logged and swallowed, never charged to the person's response.
  defp touch_last_used(hash, now) do
    cutoff = DateTime.add(now, -@session_last_used_throttle_seconds, :second)

    try do
      from(t in UserToken,
        where: t.token_hash == ^hash,
        where: is_nil(t.last_used_at) or t.last_used_at <= ^cutoff
      )
      |> Repo.update_all(set: [last_used_at: DateTime.truncate(now, :microsecond)])
    rescue
      e -> Logger.warning("touch_session_last_used failed: #{inspect(e)}")
    end

    :ok
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
      %UserToken{} = t -> revoke_session_row(t)
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
      revoke_session_row(t)
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
  the number of SESSION rows stamped revoked, which is the number the console
  reports back as `{revoked: N}`; the `"sse"` tickets swept below are NOT counted
  (they are plumbing, and inflating N would put a new unsupported number on the
  screen in place of the old one).

  ## Why this ALSO sweeps the user's live `"sse"` stream tickets (cch-w53-s4)

  A `"sse"` ticket is a 60-second bearer for `GET /v1/events` riding the same
  polymorphic `user_tokens` table. Leaving it alone left a measured hole: a
  ticket minted one second before "sign out everywhere" still opened a fresh
  authenticated stream AFTER the revoke, for the rest of its TTL. So the sweep
  is `context in ["session", "sse"]`.

  THE WIDENING STOPS THERE, and both fences are load-bearing:

    * NOT `"pat"` — a PAT is a programmatic credential a human never sees a
      browser prompt for; killing one on a password change is the silent
      breakage this carve-out exists to prevent (pinned by accounts_test's
      "sign out everywhere revokes sessions but NOT the user's PATs").
    * This is a `user_id + context` SWEEP, and it is correct ONLY here, on the
      sign-out-everywhere / password-change path. The per-ticket burn in
      `consume_sse_ticket/1` stays MATCHED-ROW-ONLY: making that one a sweep is
      charter D28's two-tab mutual-eviction storm (tab B's mint kills tab A's
      unconsumed ticket, A 401s, A remints, B dies, forever).

  The `:except` plaintext is a SESSION token, so it never spares an `"sse"` row:
  the surviving tab's pre-minted ticket dies with the rest and the client remints
  on the next stream error (app.js already remints on every error, because a 401
  is terminal for `EventSource`). That is one extra round trip on the caller's
  own tab, deliberately traded for closing the 60s window.
  """
  @spec revoke_all_user_sessions(User.t() | binary(), keyword()) :: {:ok, non_neg_integer()}
  def revoke_all_user_sessions(user, opts \\ []) do
    uid = user_id(user)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    live =
      from t in UserToken,
        where: t.user_id == ^uid,
        where: is_nil(t.revoked_at)

    # context == "session" ONLY: "sign out everywhere" / a password change must
    # never silently revoke the user's live PATs (programmatic credentials).
    base = from t in live, where: t.context == "session"

    query =
      case Keyword.get(opts, :except) do
        nil -> base
        plaintext -> from t in base, where: t.token_hash != ^UserToken.hash_token(plaintext)
      end

    {count, _} = Repo.update_all(query, set: [revoked_at: now])

    # Second statement, not a widened first one, so the reported count stays a
    # count of SESSIONS. Unredeemed stream tickets are dead weight the moment
    # the sessions behind them are gone.
    {_tickets, _} =
      Repo.update_all(from(t in live, where: t.context == "sse"), set: [revoked_at: now])

    {:ok, count}
  end

  ## STREAM BINDING HELPERS (cch-w53-bl)
  ##
  ## `user_has_live_session?/1` is a question about the USER, and on the per-row
  ## revoke path the answer is YES by construction: the device that pressed
  ## Revoke is itself a live session, so the count never reaches zero and the
  ## revoked device's parked stream survived its own revocation. These two
  ## narrow the question to ONE session row.

  @doc """
  Resolve a presented SESSION token `plaintext` to its row `id`, or `nil` when it
  is absent, unknown, revoked, expired, or not a `"session"` row.

  READ-ONLY on purpose, and that is the difference from
  `verify_user_session_token/2`: it stamps NOTHING. It runs at the SSE-ticket
  mint and at a header-authenticated stream connect, both of which already
  verified the same token a line earlier, and a second `last_used_at` stamp from
  here would be a duplicate liveness claim.
  """
  @spec live_session_token_id(binary() | nil) :: binary() | nil
  def live_session_token_id(plaintext) when is_binary(plaintext) and plaintext != "" do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    Repo.one(
      from t in UserToken,
        where: t.token_hash == ^hash,
        where: t.context == "session",
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now,
        select: t.id
    )
  end

  def live_session_token_id(_), do: nil

  @doc """
  Is THIS ONE session row still live (unrevoked, unexpired, `context = "session"`)?

  The per-device half of `user_has_live_session?/1`, for the SSE loop: a stream
  bound to its minting session rechecks this row, so revoking that one row from
  the sessions panel ends that one stream, bounded by a heartbeat, while every
  other device keeps streaming.

  A `token_id` that is not a UUID answers `false` rather than raising — the id
  arrives from a ticket column and a stream must end, not 500, if it is ever
  garbage.
  """
  @spec session_token_live?(binary() | nil) :: boolean()
  def session_token_live?(token_id) when is_binary(token_id) do
    case Repo.uuid_or_nil(token_id) do
      nil ->
        false

      id ->
        now = DateTime.utc_now()

        Repo.exists?(
          from t in UserToken,
            where: t.id == ^id,
            where: t.context == "session",
            where: is_nil(t.revoked_at),
            where: is_nil(t.expires_at) or t.expires_at > ^now
        )
    end
  end

  def session_token_live?(_), do: false

  @doc """
  Does `user` still hold at least ONE live session? The cheap existence half of
  `list_user_sessions/1`, for callers that only need the boolean.

  Exists for the SSE loop (`GET /v1/events`), which authenticates ONCE at connect
  and then parks: without a recheck, a stream opened before "sign out everywhere"
  kept delivering team events forever, and the confirm sheet's promise that every
  other device is signed out was true of the ROWS and false of the CHANNEL. The
  loop calls this on each heartbeat tick and ends the stream when it goes false,
  which bounds revocation at one heartbeat rather than never.

  `context == "session"` matches the two credentials that can open a stream (a
  session bearer, or an `"sse"` ticket that only a live session could have
  minted), and deliberately does NOT count PATs — a PAT cannot open `/v1/events`,
  so counting one would keep a revoked human's stream alive off a machine
  credential.
  """
  @spec user_has_live_session?(User.t() | binary()) :: boolean()
  def user_has_live_session?(user) do
    uid = user_id(user)
    now = DateTime.utc_now()

    Repo.exists?(
      from t in UserToken,
        where: t.user_id == ^uid,
        where: t.context == "session",
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now
    )
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
  cch-w30-bl — the PATs whose expiry warning is DUE right now: `context = "pat"`
  rows that are still live (not revoked), carry a bounded `expires_at` that has
  not yet passed, fall inside `[now, now + horizon_seconds]`, and have never been
  warned (`expiry_warned_at IS NULL`). Newest deadline first, with the owning
  `:user` preloaded — the worker mails `user.email` and nobody else.

  EVERY CLAUSE IS LOAD-BEARING, and the two nobody would think to write are the
  ones this doc exists for:

    * `is_nil(t.revoked_at)` — a revoked token has no future to warn about, and
      mailing about one tells its owner to go rotate a credential that is
      already dead.
    * `t.expires_at > ^now` — a token that expired while the worker was down is
      PAST, not expiring. A future-tense warning about a lapsed credential is
      the same class of lie `TrialExpiryWorker`'s `:trial_expired` event was
      split out to stop telling.

  There is NO `team_id` filter and there must never be one. The audience of this
  query is a set of USERS, one per row, reached through `user_id`; a team fence
  here would be the first step back toward the team fan-out this whole feature
  is defined against.
  """
  @spec pats_expiring_within(DateTime.t(), pos_integer()) :: [UserToken.t()]
  def pats_expiring_within(%DateTime{} = now, horizon_seconds)
      when is_integer(horizon_seconds) and horizon_seconds > 0 do
    deadline = DateTime.add(now, horizon_seconds, :second)

    from(t in UserToken,
      where:
        t.context == "pat" and is_nil(t.revoked_at) and is_nil(t.expiry_warned_at) and
          not is_nil(t.expires_at) and t.expires_at > ^now and t.expires_at <= ^deadline,
      order_by: [asc: t.expires_at, asc: t.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Atomically claim the one-shot expiry-warning budget on ONE PAT row. Returns
  true iff THIS call won it — the `UPDATE … WHERE expiry_warned_at IS NULL`
  can match at most once, so two overlapping worker passes send one email
  between them, never two.

  The caller stamps AFTER deciding the mail can leave the building, for the
  reason `TrialExpiryWorker.receivable?/1` documents at length: the stamp is the
  ENTIRE budget for this warning and nothing anywhere reads it back, so spending
  it on a send that never happened costs the owner their only notice with no
  surface to show the loss.
  """
  @spec claim_pat_expiry_warning(binary(), DateTime.t()) :: boolean()
  def claim_pat_expiry_warning(token_id, %DateTime{} = now) when is_binary(token_id) do
    {count, _} =
      from(t in UserToken,
        where: t.id == ^token_id and t.context == "pat" and is_nil(t.expiry_warned_at)
      )
      |> Repo.update_all(set: [expiry_warned_at: now])

    count == 1
  end

  @doc """
  Delete ALL of `user`'s SESSION tokens — an immediate logout everywhere. The
  Cloud analogue of Coolify's `RevokeUserTeamTokens` (it deletes session rows
  rather than flag a `revoked_at` column we don't have).

  SCOPED to `context == "session"`: a member removal / demotion (the callers)
  must log the user out without incidentally HARD-DELETING their PATs — a
  programmatic credential is never DESTROYED as a side effect of a role change.
  The membership-scoped PAT eviction is a SEPARATE, narrower step the same
  callers take (`revoke_team_pats/2` on removal, `revoke_team_pats_exceeding_role/3`
  on demotion): it stamps `revoked_at` on the team's rows only, leaving the
  audit tombstone and every other team's credentials intact.

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

  @doc """
  Revoke (stamp `revoked_at` on) EVERY live PAT `user` holds on `team` — the
  removal remedy. No membership, no team-scoped credential: the Console's
  destroy-tier modal promises "Ends <email>'s access to the team immediately",
  and a PAT that outlives the membership row makes that promise false (it kept
  reading `GET /v1/barkparks` and writing `POST /v1/fleet/supports` on a team
  the holder had left).

  TEAM-SCOPED ON PURPOSE (`team_id == team`, never `user_id` alone): a user may
  hold PATs on several teams, and a blast radius that crossed teams would be a
  new tenancy defect, not a fix. Returns `{:ok, count}`.
  """
  @spec revoke_team_pats(Team.t() | binary(), User.t() | binary()) ::
          {:ok, non_neg_integer()}
  def revoke_team_pats(team, user),
    do: revoke_live_team_pats(team, user, fn _abilities -> true end)

  @doc """
  Revoke only the PATs `user` holds on `team` whose abilities EXCEED what a
  holder of `role` could mint TODAY — the demotion remedy, deliberately
  narrower than `revoke_team_pats/2`.

  A demoted user is still a member, so the read-only PAT they remain entitled
  to mint keeps working; only the elevated grant they could no longer obtain
  (`write`/`deploy`/`root`) dies. The predicate is `pat_abilities_allowed?/2` —
  the same one the mint fence uses — so the surface can never honour a stale
  grant it would refuse to issue. Returns `{:ok, count}`.
  """
  @spec revoke_team_pats_exceeding_role(
          Team.t() | binary(),
          User.t() | binary(),
          String.t() | nil
        ) ::
          {:ok, non_neg_integer()}
  def revoke_team_pats_exceeding_role(team, user, role) do
    revoke_live_team_pats(team, user, &(not pat_abilities_allowed?(role, &1)))
  end

  # The shared body: load the user's LIVE PATs on this team, keep the ones
  # `doomed?` selects (the abilities check is Elixir-side — the ability set is
  # an array column and the predicate is the mint fence itself), stamp them.
  defp revoke_live_team_pats(team, user, doomed?) do
    uid = user_id(user)
    tid = team_id(team)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    doomed_ids =
      from(t in UserToken,
        where: t.user_id == ^uid,
        where: t.team_id == ^tid,
        where: t.context == "pat",
        where: is_nil(t.revoked_at),
        select: {t.id, t.abilities}
      )
      |> Repo.all()
      |> Enum.filter(fn {_id, abilities} -> doomed?.(abilities || []) end)
      |> Enum.map(fn {id, _abilities} -> id end)

    case doomed_ids do
      [] ->
        {:ok, 0}

      ids ->
        {count, _} =
          from(t in UserToken, where: t.id in ^ids)
          |> Repo.update_all(set: [revoked_at: now])

        {:ok, count}
    end
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
  # Revoke ONE session row and, in the same breath, the unredeemed `"sse"` stream
  # tickets that row minted (cch-w53-bl). Both single-row kill switches —
  # `revoke_user_session_token/1` (this device logs out) and
  # `revoke_user_session/2` (one row from the sessions panel) — go through here,
  # so neither can leave a 60-second bearer behind that opens a FRESH
  # authenticated stream for a device that was just signed out. That is the
  # per-row twin of the ticket sweep `revoke_all_user_sessions/2` already does
  # for sign-out-everywhere.
  #
  # SCOPED BY `session_token_id`, never by `user_id + context`: a user-wide "sse"
  # sweep here would be charter D28's two-tab mutual-eviction storm (revoking a
  # phone would evict the laptop's unredeemed ticket). A PAT row reaching this
  # function sweeps nothing — no ticket points at it.
  defp revoke_session_row(%UserToken{} = t) do
    with {:ok, revoked} <- stamp_revoked(t) do
      {_swept, _} =
        Repo.update_all(
          from(s in UserToken,
            where: s.session_token_id == ^t.id,
            where: s.context == "sse",
            where: is_nil(s.revoked_at)
          ),
          set: [revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond)]
        )

      {:ok, revoked}
    end
  end

  defp stamp_revoked(%UserToken{} = t) do
    t
    |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
    |> Repo.update()
  end

  @doc """
  Change `user`'s password after verifying `current_password` (timing-safe via
  the same Bcrypt path as login). On success, in ONE transaction: writes the new
  hash AND revokes every OTHER session the user holds — the "change password ⇒
  sign out everywhere" guarantee (Coolify's DeletesUserSessions,
  DeletesUserSessions.php:31-37, done as an explicit context step rather than a
  model `updated` hook).

  `opts[:keep]` is the acting browser's plaintext token — kept alive through the
  bulk revoke so the in-flight request never invalidates its own auth mid-call.

  SCOPE — USER-held credentials ONLY, never MACHINE credentials. This path used
  to also call `Registry.revoke_all_agent_tokens_for_user/1`, killing the agent
  token of every box owned by every team the user belonged to (a ROLE-BLIND join;
  the lowest-privilege member rotating their own password disarmed boxes they
  could not otherwise touch). That was removed, and the function with it, because
  it was a one-way state with no exit: the ONLY minter of an agent token is
  `Registry.mint_agent_token/3` via `put_agent_token/2` inside a provision or
  resurrect claim, every one of them behind `Auth.require_worker` — so the only
  way back was to re-provision the box.

  It also mitigated nothing. An agent-token plaintext is emitted at exactly one
  place to exactly one audience (a holder of the platform WORKER_TOKEN); no
  user-authenticated route ever returns one. An attacker holding this user's
  password never had the agent token, so revoking it took nothing from them. The
  Coolify control this was modelled on revokes USER-HELD API tokens scoped to a
  team; the analogy broke when it was mapped onto machine credentials the user
  never possesses. Sessions and PATs — which the user DOES hold, and which they
  can re-mint themselves — are still revoked here, which is the real guarantee.

  To kill ONE box's machine credential after a genuine box compromise, use
  `Registry.revoke_agent_token/1` and read its docstring first: the revoke is
  unrecoverable without a re-provision.
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
             {:ok, _n} <- revoke_all_user_sessions(user, except: opts[:keep]) do
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
  the user holds AND revoke every session (a credential reset signs the user out
  everywhere, exactly like `update_user_password/4` — and, exactly like it,
  touches no MACHINE credential; see that docstring for why the agent-token
  revoke was removed from both paths).

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
           {:ok, _n} <- revoke_all_user_sessions(user) do
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
  @spec list_team_members(Team.t() | binary()) :: [map()]
  def list_team_members(team) do
    tid = team_id(team)

    from(m in TeamMembership,
      join: u in User,
      on: u.id == m.user_id,
      where: m.team_id == ^tid,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: %{user: u, role: m.role, joined_at: m.inserted_at}
    )
    |> Repo.all()
  end

  @doc """
  Remove `target` from `team`, AUTHORIZED by an actor holding `actor_role`. The
  anti-escalation sibling of `remove_member/2`, and it is SELF-SUFFICIENT — it
  does not assume a route gate ran first:

    * the actor must hold an admin-or-higher grant (`TeamMembership.admin?/1`),
      AND
    * an OWNER may then remove any peer (including another owner, while
      `owner_count > 1`), while an ADMIN may remove only someone they strictly
      OUTRANK (a member, never an admin/owner).

  The first clause is not redundant with the second. `TeamMembership.rank/1`
  returns 0 for a role it does not know, and `team_memberships.role` has NO
  CHECK constraint, so an off-ladder string in that column ranks BELOW everyone
  — which made `outranks?("member", "superadmin")` true and let a plain member
  remove such a row. Before cch-w44 the only thing refusing that was
  `with_team_role(conn, "admin", …)` at the single call site, i.e. the safety
  held only in composition. The floor is on the ACTOR side on purpose: an
  off-ladder TARGET is still removable by an admin, which
  `cloud/priv/static/__app.test.mjs` (cch-w42-s3) pins the console to offer.

  An authority miss is `{:error, :forbidden}`. Last-owner + not-found are
  preserved (delegated to `remove_member/2`). The route threads
  `current_team_role` here.
  """
  @spec remove_member_as(String.t(), Team.t(), User.t()) ::
          {:ok, :removed} | {:error, :forbidden | :not_found | :last_owner}
  def remove_member_as(actor_role, %Team{} = team, %User{} = target)
      when is_binary(actor_role) do
    case get_membership(team, target) do
      nil ->
        {:error, :not_found}

      %TeamMembership{role: target_role} ->
        # THE ACTOR TIER IS A CONJUNCT, and it has to be one: the rank ladder
        # answers 0 for a role it does not know, so an OFF-LADDER target sits
        # below everyone and `outranks?("member", "superadmin")` is `1 > 0` —
        # true. Without `admin?/1` a plain MEMBER was accepted as the remover,
        # and the only thing refusing them was `with_team_role(conn, "admin", …)`
        # at the single call site. That made the safety a property of the
        # COMPOSITION, not of this function, so calling it from anywhere else
        # was unsafe. `update_member_role_as/4` has had this floor all along via
        # `Authz.can_grant?/3` (its `not team_admin?` arm); this restores the
        # symmetry between the two member verbs rather than inventing a rule.
        #
        # DELIBERATELY NOT a fail-closed `rank/1`. Hardening the ladder would
        # flip (admin, off-ladder) from accept to refuse — a FALSE REFUSAL that
        # `cloud/priv/static/__app.test.mjs`'s `MEMBER_AUTHORITY_MATRIX` pins
        # against (cch-w42-s3) — and would break `Web.Auth.require_team_role/3`
        # and `Authz.can_grant?/3`, both of which are fail-closed TODAY precisely
        # because an unknown ACTOR role ranks 0. The floor belongs on the actor.
        if TeamMembership.admin?(actor_role) and
             (actor_role == "owner" or TeamMembership.outranks?(actor_role, target_role)) do
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
      # …and their PROGRAMMATIC access to THIS team ends with it: an ex-member's
      # PAT kept authorizing reads and writes on a team they had left. Scoped to
      # this team — PATs they hold elsewhere are untouched.
      {:ok, _} = revoke_team_pats(team, user)
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
  invariant on a downgrade away from owner. On ANY demotion — a drop in
  `TeamMembership.rank/1`, owner→admin included — the user's sessions are
  evicted and the PATs the new role could no longer mint are revoked, so a
  demoted user loses elevated access immediately (mirrors Coolify revoking
  tokens on a role change).
  `{:ok, %TeamMembership{}}` | `{:error, :invalid_role | :not_found | :last_owner}`.

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
    # A DEMOTION is a RANK DROP, derived from the ladder that ranks the roles —
    # never a named role. The old equality-against-a-role-literal gate was right
    # only while `pat_abilities_allowed?/2` happened to collapse owner and
    # admin: split those two and the remedy would silently stop running on an
    # owner→admin demotion while the elevated PATs stayed alive. Derived, the
    # gate cannot go stale — when the two roles ARE equivalent the revoker's
    # own predicate simply selects zero rows.
    demoted? = TeamMembership.rank(new_role) < TeamMembership.rank(current_role)

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

      # A demotion evicts the user's sessions, and the PATs minted under the
      # old role that the new role could not mint — but ONLY those: a plain
      # member may still hold the read-only PAT they are entitled to mint.
      if demoted? do
        {:ok, _} = delete_user_session_tokens(user)
        {:ok, _} = revoke_team_pats_exceeding_role(team, user, new_role)
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
  Every PAT minted against `team`, newest first, with `:user` preloaded — the
  TEAM-ADMIN read that `list_personal_access_tokens/1` (per-user, caller-scoped)
  cannot serve.

  Why a second list function and not an option on the first: the caller-scoped
  read answers "what have *I* minted"; this one answers "what programmatic
  credentials can act on *this team*", and the two have different authorities
  (a session user vs. a team admin) and different blast radii. Keeping them
  apart means the per-user query can never be widened by a stray option.

  TEAM-SCOPED ON PURPOSE (`team_id == team`, never `user_id`): a member may hold
  PATs on several teams, and a row from another team appearing in this list
  would be a tenancy leak, not a feature. Includes revoked rows — the tombstone
  is the point of an admin view.
  """
  @spec list_team_personal_access_tokens(Team.t() | binary()) :: [UserToken.t()]
  def list_team_personal_access_tokens(team) do
    tid = team_id(team)

    from(t in UserToken,
      where: t.team_id == ^tid and t.context == "pat",
      order_by: [desc: t.inserted_at, desc: t.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Revoke (stamp `revoked_at` on) ONE PAT minted against `team`, whoever holds
  it — the admin-side kill switch for a member's leaked credential. Idempotent.

  The fence is `team_id == team` (plus `context == "pat"`), NOT `user_id`: this
  is the whole point of the function, and it is also its whole blast radius. A
  token id belonging to another team, a non-PAT row, a non-UUID string, or
  nothing at all is the SAME `{:error, :not_found}` the caller-scoped
  `revoke_personal_access_token/2` returns — a 404 shape, so an admin cannot
  probe another team's token ids for existence.

  Returns `{:ok, token}` with `:user` preloaded so the caller can name the
  holder in an audit row without a second read.
  """
  @spec revoke_team_personal_access_token(Team.t() | binary(), binary()) ::
          {:ok, UserToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_team_personal_access_token(team, token_id) when is_binary(token_id) do
    tid = team_id(team)

    # A non-UUID token_id would make the get_by cast raise → 500; guard it to the
    # not_found (404) branch, exactly as revoke_personal_access_token/2 does.
    case Repo.uuid_or_nil(token_id) &&
           Repo.get_by(UserToken, id: token_id, team_id: tid, context: "pat") do
      nil ->
        {:error, :not_found}

      %UserToken{revoked_at: nil} = token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, Repo.preload(updated, :user)}
          other -> other
        end

      %UserToken{} = token ->
        # Already revoked — idempotent.
        {:ok, Repo.preload(token, :user)}
    end
  end

  def revoke_team_personal_access_token(_team, _token_id), do: {:error, :not_found}

  @doc """
  Verify a presented PAT `plaintext`. Returns `{user, token}` when the row
  exists, is `context = "pat"`, unrevoked, and unexpired; otherwise `nil`.

  Best-effort stamps `last_used_at` (throttled to once / minute) so operators
  can spot dead tokens. A stamp failure is swallowed — never block auth on it.

  Pass `touch: false` to verify WITHOUT stamping — the caller then owns the
  stamp and can place it downstream of the response decision (see
  `touch_pat_last_used/1` and `Web.Auth`'s `defer_pat_touch/2`).

  WHICH FORM PRODUCTION TAKES, stated so the default is not misread as the live
  path: after this change the ONE production call site (`Web.Auth`, the PAT
  branch of `require_user_or_pat/2`) passes `touch: false`, so the eager stamp
  runs for no served request. The arity-1 form keeps the eager default because
  it is the published contract of a public function — not because a caller
  still depends on it — and `accounts_test.exs` pins that behaviour. A future
  caller that genuinely wants the stamp at the verify gets it by asking for
  arity 1; anything that serves an HTTP response should defer instead, because
  authentication runs strictly before authorization.
  """
  @spec verify_personal_access_token(binary()) :: {User.t(), UserToken.t()} | nil
  def verify_personal_access_token(plaintext), do: verify_personal_access_token(plaintext, [])

  @spec verify_personal_access_token(binary(), keyword()) :: {User.t(), UserToken.t()} | nil
  def verify_personal_access_token(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserToken,
        where: t.token_hash == ^hash and t.context == "pat",
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserToken{user_id: uid} = token ->
        if Keyword.get(opts, :touch, true), do: stamp_last_used(token, now)

        case Repo.get(User, uid) do
          nil -> nil
          user -> {user, token}
        end

      nil ->
        nil
    end
  end

  def verify_personal_access_token(_, _), do: nil

  @doc """
  Stamp `last_used_at` on the PAT row behind `plaintext`, throttled to the
  #{@last_used_throttle_seconds}s window. Always `:ok` — a token revoked or
  deleted since the verify matches zero rows, which `update_all` treats as a
  no-op.

  The PAT mirror of `touch_session_last_used/1`, and public for the same
  reason: the stamp does not belong at the verify. `last_used_at` is the
  liveness claim the tokens card renders, and authentication runs strictly
  before authorization — so `Web.Auth` defers this to `register_before_send/2`
  and fires it only for a request the platform actually SERVED
  (`conn.status < 400`), never for one it refused 403.
  """
  @spec touch_pat_last_used(binary()) :: :ok
  def touch_pat_last_used(plaintext) when is_binary(plaintext) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@last_used_throttle_seconds, :second)
    hash = UserToken.hash_token(plaintext)

    # The throttle rides the WHERE clause rather than a read-then-write, so the
    # skip costs one statement and cannot race itself. `last_used_at <= cutoff`
    # is the `>=`-seconds predicate: a row stamped EXACTLY the window ago is
    # stale and writes.
    try do
      from(t in UserToken,
        where: t.token_hash == ^hash and t.context == "pat",
        where: is_nil(t.last_used_at) or t.last_used_at <= ^cutoff
      )
      |> Repo.update_all(set: [last_used_at: DateTime.truncate(now, :microsecond)])
    rescue
      e -> Logger.warning("touch_pat_last_used failed: #{inspect(e)}")
    end

    :ok
  end

  def touch_pat_last_used(_), do: :ok

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

  `first_factor` names WHAT ALREADY CLEARED before this challenge was minted, and
  rides the row's `sent_to` — the same column, for the same reason, as
  `create_oauth_exchange_code/2`'s `"oauth:<provider>"`. `nil` is the password leg
  (`POST /v1/auth/login`), which is why it is the default: that caller established
  the first factor itself and has nothing to carry.

  cch-w53-s6 — it exists because `POST /v1/auth/oauth/exchange` can now mint one of
  these too. Without the provider travelling here, the session the challenge
  finally mints would be stamped `origin: "two_factor"`, whose own comment at the
  challenge leg asserts the PASSWORD leg already passed — false for an IdP
  sign-in, and the sessions security panel would say so out loud.
  """
  @spec create_two_factor_pending_token(User.t(), binary() | nil) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_two_factor_pending_token(%User{} = user, first_factor \\ nil)
      when is_binary(first_factor) or is_nil(first_factor) do
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
      sent_to: first_factor,
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

  @doc """
  Resolve a 2fa-pending token to the first factor that ALREADY cleared before it
  was minted (the `sent_to` written by `create_two_factor_pending_token/2`), or
  `nil` when the token is unknown, expired, or was minted by the password leg.

  Read it BEFORE `delete_two_factor_pending_tokens/1` burns the row. Same
  context-scoped, expiry-filtered lookup as `verify_two_factor_pending_token/1`,
  deliberately: a caller must not be able to learn a first factor from a token the
  verifier would refuse.

  `nil` collapses the two honest "no OAuth here" answers — password-minted, and
  minted before this column carried anything — into the one that stamps the
  unqualified `"two_factor"`. That is the conservative direction: an unnamed first
  factor degrades to the ORIGINAL origin rather than inventing a provider.
  """
  @spec two_factor_pending_first_factor(binary()) :: binary() | nil
  def two_factor_pending_first_factor(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserToken,
        where: t.token_hash == ^hash and t.context == "2fa_pending",
        where: is_nil(t.expires_at) or t.expires_at > ^now,
        select: t.sent_to

    Repo.one(query)
  end

  def two_factor_pending_first_factor(_), do: nil

  @doc "Delete every 2fa-pending token for a user (after a successful challenge)."
  @spec delete_two_factor_pending_tokens(User.t()) :: {non_neg_integer(), nil}
  def delete_two_factor_pending_tokens(%User{id: user_id}) do
    from(t in UserToken, where: t.user_id == ^user_id and t.context == "2fa_pending")
    |> Repo.delete_all()
  end

  ## SSE stream tickets

  ## A THIRD `user_tokens.context`, `"sse"`, riding the same polymorphic table:
  ## the credential `GET /v1/events` accepts in its URL. It exists so that the
  ## thing in the URL is NOT a 30-day session token. Reuses the discriminator, so
  ## no migration: `verify_user_session_token/1` filters `context == "session"`
  ## and rejects an SSE ticket everywhere else, and vice-versa.

  @doc "The SSE ticket TTL in seconds — the value the mint route reports as `expires_in`."
  @spec sse_ticket_validity_seconds() :: pos_integer()
  def sse_ticket_validity_seconds, do: @sse_ticket_validity_seconds

  @doc """
  Mint a single-use SSE stream ticket (#{@sse_ticket_validity_seconds}s TTL) for
  `user`. Returns the plaintext exactly once.

  The browser's `EventSource` API cannot set request headers, so the stream
  credential has to ride the URL and land in every access log and proxy trace.
  This ticket is what makes that survivable: SSE-scoped, 60 seconds long, and
  BURNED on first redemption by `consume_sse_ticket/1`, so the logged copy is
  dead on arrival.

  Mint is deliberately NON-SUPERSEDING — it never revokes the user's other live
  tickets (the mint template is `create_two_factor_pending_token/1`, which is
  matched-row-only; the password-reset mint, which supersedes, is NOT the model).
  Two console tabs each hold their own ticket, and a mint in one must not evict
  the other's unredeemed ticket: that tab would 401, which would make it remint,
  which would evict the first — a mutual-eviction storm, one junk 401 per turn.
  """
  ## `session_token` (cch-w53-bl) is the plaintext SESSION token the mint request
  ## carried in its `Authorization` header — the device asking for a stream. It is
  ## resolved to that session ROW's id and stamped on the ticket as
  ## `session_token_id`, which is what lets the parked stream be ended by a
  ## PER-ROW revoke of that one device (`DELETE /v1/account/sessions/:id`) instead
  ## of only by a user-wide sign-out. `nil` (the default, and any plaintext that
  ## does not resolve to a live session) leaves the binding NULL, and the loop
  ## falls back to the user-wide check — see `session_token_live?/1` and
  ## `user_has_live_session?/1`.
  @spec create_sse_ticket(User.t(), binary() | nil) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_sse_ticket(%User{} = user, session_token \\ nil) do
    plaintext = generate_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@sse_ticket_validity_seconds, :second)
      |> DateTime.truncate(:microsecond)

    %UserToken{}
    |> UserToken.changeset(%{
      user_id: user.id,
      context: "sse",
      token_hash: UserToken.hash_token(plaintext),
      expires_at: expires_at,
      session_token_id: live_session_token_id(session_token)
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Redeem an SSE ticket exactly once: resolve it to its `User` and burn it in the
  SAME transaction. Returns the `User`, or `nil` for an unknown, already-burned,
  expired, or wrong-context token.

  STRICTLY SINGLE-USE and MATCHED-ROW-ONLY. The lookup locks the ONE row matching
  the presented hash `FOR UPDATE` and stamps `revoked_at` on THAT row before the
  transaction commits, so two concurrent redemptions of the same plaintext
  serialize and the loser finds it revoked. It deliberately does NOT reuse any
  `revoke_*_tokens(user_id, …)` helper: every one of those is scoped by
  `user_id + context` with NO `token_hash`, so burning one ticket would revoke
  every live sibling of the same user — see the two-tab storm in
  `create_sse_ticket/1`.

  The validity filters mirror `verify_user_session_token/1` (context, then
  `is_nil(revoked_at)`, then unexpired). `verify_two_factor_pending_token/1` is
  explicitly NOT the model: it omits the `revoked_at` filter entirely, so a
  burned token would still resolve through it and single-use would be
  unenforceable.
  """
  @spec consume_sse_ticket(binary()) :: User.t() | nil
  def consume_sse_ticket(plaintext) do
    case consume_sse_ticket_binding(plaintext) do
      {%User{} = user, _session_token_id} -> user
      nil -> nil
    end
  end

  @doc """
  `consume_sse_ticket/1` plus the ticket's STREAM BINDING: returns
  `{user, session_token_id}` — where `session_token_id` is the `"session"` row
  that minted the ticket, or `nil` for an unbound one — and `nil` for a ticket
  that does not redeem.

  THE BINDING HAS TO COME OUT OF THE REDEMPTION, not a later lookup, and that is
  the whole reason this function exists (cch-w53-bl). Redeeming BURNS the row in
  the same transaction and `SseTicketReaper` DELETES burnt rows on the minute, so
  a caller that wanted the binding afterwards would be racing a reaper with the
  plaintext it just spent. The stream loop needs it forever (it parks for hours),
  so it is handed over once, at connect.

  `consume_sse_ticket/1` stays the shape every non-stream caller wants — the
  single-use semantics, filters, and the matched-row-only burn are all here and
  described there.
  """
  @spec consume_sse_ticket_binding(binary()) :: {User.t(), binary() | nil} | nil
  def consume_sse_ticket_binding(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = lifecycle_now()

    result =
      Repo.transaction(fn ->
        token =
          Repo.one(
            from t in UserToken,
              where: t.token_hash == ^hash,
              where: t.context == "sse",
              where: is_nil(t.revoked_at),
              where: is_nil(t.expires_at) or t.expires_at > ^now,
              lock: "FOR UPDATE"
          )

        case token do
          %UserToken{user_id: user_id, session_token_id: session_token_id} = t ->
            {:ok, _burned} = Repo.update(UserToken.changeset(t, %{revoked_at: now}))

            case Repo.get(User, user_id) do
              %User{} = user -> {user, session_token_id}
              nil -> nil
            end

          nil ->
            nil
        end
      end)

    case result do
      {:ok, binding} -> binding
      {:error, _reason} -> nil
    end
  end

  def consume_sse_ticket_binding(_), do: nil

  @doc """
  Delete every `"sse"` ticket row that is BURNED (`revoked_at` stamped) or past
  its `expires_at`. Hygiene only — returns `%{reaped: count}`; the
  `BarkparkCloud.Workers.SseTicketReaper` Oban worker calls this per minute.

  Correctness never depends on this running: `consume_sse_ticket/1` already
  filters `is_nil(revoked_at)` and `expires_at > now`, so a burned or lapsed
  ticket is unredeemable the instant either becomes true. What this stops is the
  ACCRETION. The mint is a bare `Repo.insert` per call and is deliberately
  NON-SUPERSEDING (see `create_sse_ticket/1`), and the burn is a soft
  `revoked_at` stamp rather than a DELETE — so before this helper existed, a
  console tab's reconnect loop left one permanent row per connect, forever.

  STRICTLY `context == "sse"`. `user_tokens` is polymorphic and every other
  context (`session`, `pat`, `confirm`, `change_email`, `2fa_pending`, `reset`,
  `device`) has its OWN lifecycle owner — a revoked `session` row, for one, is
  the tombstone the active-sessions UI renders. Widening this `where` by even one
  context would delete other people's evidence, so it is pinned by test.

  A row with a NULL `expires_at` and no `revoked_at` survives: SQL's
  `NULL <= now` is NULL, and `false OR NULL` is NULL, so it never matches. That
  is the correct outcome — such a row is still live.
  """
  @spec reap_sse_tickets() :: %{reaped: non_neg_integer()}
  def reap_sse_tickets do
    now = lifecycle_now()

    {count, _} =
      from(t in UserToken,
        where: t.context == "sse",
        where: not is_nil(t.revoked_at) or t.expires_at <= ^now
      )
      |> Repo.delete_all()

    %{reaped: count}
  end

  ## OAuth exchange codes

  ## A FOURTH single-use credential on the same polymorphic `user_tokens` table,
  ## `context = "oauth_exchange"`. NO MIGRATION: `UserToken.changeset/2` casts
  ## `:context` with no `validate_inclusion` and the column is plain text.
  ##
  ## WHY IT EXISTS (cch-w10). The OAuth callback used to 302 the browser to
  ## `/#oauth=<session token>` — and `redirect_to/2` is `put_resp_header("location",
  ## …) + send_resp(302, "")`, so the ONE legitimate response of the whole sign-in
  ## carried a live 30-day session token in a RESPONSE HEADER. A fragment is
  ## invisible to a SERVER access log, but it is fully visible to anything that
  ## logs RESPONSE headers: a TLS-terminating middlebox, a reverse proxy, an APM
  ## agent. Same defect class as the `?token=` on `GET /v1/events`, and it gets the
  ## same answer: make the thing on the wire worthless. What rides the header now
  ## is a 120s, hashed, burn-on-first-POST code that mints nothing by itself.

  @doc "The OAuth exchange-code TTL in seconds — reported as `expires_in` is NOT needed (the SPA redeems immediately); exposed for the tests and the reaper."
  @spec oauth_exchange_validity_seconds() :: pos_integer()
  def oauth_exchange_validity_seconds, do: @oauth_exchange_validity_seconds

  @doc """
  Mint a single-use OAuth exchange code (#{@oauth_exchange_validity_seconds}s TTL)
  for `user`, remembering which `provider` authenticated them. Returns the
  plaintext exactly once.

  `sent_to` carries `"oauth:<provider>"` — the SAME string the session row's
  `origin` used to be stamped with at the callback. The mint moved to the
  exchange, so the provider has to survive the hop somewhere, and `sent_to` is
  already the "who was this token issued FOR" column on this table (the confirm /
  change_email contexts use it for exactly that). Without it every OAuth session
  would collapse to a generic origin and the sessions security panel would stop
  naming the provider.

  Mint is MATCHED-ROW-ONLY and NON-SUPERSEDING, like `create_sse_ticket/1`: it
  never revokes the user's other live codes. Two tabs mid-sign-in are rare but not
  impossible (a user clicking "Continue with GitHub" in two windows), and a mint
  in one evicting the other's unredeemed code would fail a sign-in that was going
  to work.
  """
  @spec create_oauth_exchange_code(User.t(), binary()) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_oauth_exchange_code(%User{} = user, provider) when is_binary(provider) do
    plaintext = generate_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@oauth_exchange_validity_seconds, :second)
      |> DateTime.truncate(:microsecond)

    %UserToken{}
    |> UserToken.changeset(%{
      user_id: user.id,
      context: "oauth_exchange",
      token_hash: UserToken.hash_token(plaintext),
      sent_to: "oauth:#{provider}",
      expires_at: expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Redeem an OAuth exchange code exactly once: resolve it to `{user, provider}` and
  burn it in the SAME transaction. Returns `nil` for an unknown, already-burned,
  expired, or wrong-context code.

  STRICTLY SINGLE-USE and MATCHED-ROW-ONLY — the `consume_sse_ticket/1` shape,
  deliberately: the lookup locks the ONE row matching the presented hash
  `FOR UPDATE` and stamps `revoked_at` on THAT row before commit, so two
  concurrent redemptions serialize and the loser finds it revoked.

  `verify_two_factor_pending_token/1` is explicitly NOT the model. Its own comment
  records that it omits the `revoked_at` filter — through that shape a burned code
  would still resolve, and single-use here is the entire point: the code is the
  value a response-header log can hold, so a second redemption must be worthless.

  `provider` comes back from `sent_to` (`"oauth:<provider>"`) so the caller can
  stamp the honest `origin: "oauth:<provider>"` on the session it mints. A row
  written before this field existed, or one with a malformed `sent_to`, degrades
  to `"oauth"` rather than raising — an unnamed provider is a weaker audit line,
  never a failed sign-in.
  """
  @spec consume_oauth_exchange_code(binary()) :: {User.t(), binary()} | nil
  def consume_oauth_exchange_code(plaintext) when is_binary(plaintext) do
    hash = UserToken.hash_token(plaintext)
    now = lifecycle_now()

    result =
      Repo.transaction(fn ->
        token =
          Repo.one(
            from t in UserToken,
              where: t.token_hash == ^hash,
              where: t.context == "oauth_exchange",
              where: is_nil(t.revoked_at),
              where: is_nil(t.expires_at) or t.expires_at > ^now,
              lock: "FOR UPDATE"
          )

        case token do
          %UserToken{user_id: user_id, sent_to: sent_to} = t ->
            {:ok, _burned} = Repo.update(UserToken.changeset(t, %{revoked_at: now}))

            case Repo.get(User, user_id) do
              %User{} = user -> {user, oauth_origin(sent_to)}
              nil -> nil
            end

          nil ->
            nil
        end
      end)

    case result do
      {:ok, pair} -> pair
      {:error, _reason} -> nil
    end
  end

  def consume_oauth_exchange_code(_), do: nil

  # `sent_to` is the mint's `"oauth:<provider>"`; hand back the whole string so the
  # caller stamps it verbatim as `origin`. Anything else collapses to the generic
  # "oauth" — honest about not knowing, rather than inventing a provider.
  defp oauth_origin("oauth:" <> provider) when byte_size(provider) > 0, do: "oauth:" <> provider
  defp oauth_origin(_), do: "oauth"

  @doc """
  Delete every `"oauth_exchange"` row that is BURNED (`revoked_at` stamped) or past
  its `expires_at`. Hygiene only — returns `%{reaped: count}`; the
  `BarkparkCloud.Workers.OAuthExchangeReaper` Oban worker calls this per minute.

  THIS SHIPS WITH THE MINT, ON PURPOSE. Every prior single-use context on this
  surface accreted first and got its reaper later — `oauth_states` (cch-w2) and
  `"sse"` (cch-w3) were both "a row nothing ever deletes" findings. The mint here
  is a bare `Repo.insert` on the tail of an UNAUTHENTICATED route, and the burn is
  a soft `revoked_at` stamp rather than a DELETE, so it is the identical shape:
  every completed sign-in, and every abandoned one, would leave a permanent row.

  Correctness never depends on this running — `consume_oauth_exchange_code/1`
  already filters `is_nil(revoked_at)` and `expires_at > now`. What this stops is
  the pile.

  STRICTLY `context == "oauth_exchange"`, for the same reason `reap_sse_tickets/0`
  is strictly `"sse"`: `user_tokens` is polymorphic and a revoked `session` row is
  the tombstone the active-sessions UI renders. Widening this `where` by one
  context would delete other people's evidence. Pinned by test.
  """
  @spec reap_oauth_exchange_codes() :: %{reaped: non_neg_integer()}
  def reap_oauth_exchange_codes do
    now = lifecycle_now()

    {count, _} =
      from(t in UserToken,
        where: t.context == "oauth_exchange",
        where: not is_nil(t.revoked_at) or t.expires_at <= ^now
      )
      |> Repo.delete_all()

    %{reaped: count}
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
        {user, branch} = find_or_birth_oauth_user!(provider, uid, email)

        case link_external_identity(user, %{provider: provider, provider_uid: uid, email: email}) do
          {:ok, _identity} ->
            {user, branch}

          {:error, %Ecto.Changeset{} = cs} ->
            if unique_violation?(cs),
              do: Repo.rollback(:identity_conflict),
              else: Repo.rollback(cs)
        end
      end)

    case result do
      {:ok, {user, branch}} ->
        {:ok, user, branch}

      # A concurrent callback linked this identity first; its tx aborted ours on
      # the unique violation. Re-fetch OUTSIDE the aborted tx.
      #
      # The branch here is `:existing`, NOT the branch our aborted transaction
      # was taking: whatever this call was about to do, it did not do it — the
      # winner did. Reporting `:linked` from here would stamp a second
      # `oauth.linked` row for the one link the other callback already recorded.
      {:error, :identity_conflict} ->
        case get_user_by_external_identity(provider, uid) do
          %User{} = user -> {:ok, user, :existing}
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
  #
  # Returns `{user, branch}` — `:linked` for the convergence arm, `:created` for
  # the birth arm. THE BRANCH IS DECIDED HERE AND NOWHERE ELSE: this `case` IS
  # the difference between "an account gained a provider" and "an account was
  # born", and a caller reconstructing it afterwards (e.g. by comparing
  # inserted_at, or by counting identity rows) would be guessing at exactly the
  # moment the guess stops being cheap.
  defp find_or_birth_oauth_user!(provider, uid, email) do
    case email && get_user_by_email(email) do
      %User{} = existing ->
        {existing, :linked}

      _ ->
        # No email match (or no email at all) → birth a fresh OAuth-only account
        # with the SAME entitlement chain as a password signup. A withheld email
        # gets a stable synthetic one so the email-required schema is satisfied;
        # the durable link is the (provider, uid) row, not this address.
        {birth_oauth_user!(email || synthetic_oauth_email(provider, uid)), :created}
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
