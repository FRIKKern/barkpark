defmodule Barkpark.Accounts.UserSession do
  @moduledoc """
  A login session bearer for a `User`. Hash-at-rest: only `token_hash`
  (SHA-256, lowercase hex) is stored; the plaintext is returned once at mint and
  is unrecoverable. `revoked_at` is the kill switch (logout / sign-out-everywhere);
  `expires_at` bounds lifetime. Mirrors `cloud/`'s `Accounts.UserToken` session
  context and the core `Barkpark.Auth.ApiToken` hashing scheme.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @default_validity_days 30

  # Idle-timeout window (seconds). `nil` ⇒ idle-logout DISABLED — the default.
  # Enabling it is intentionally NOT enough to log anyone out: the predicates
  # below are PURE and are NOT wired into `Accounts.verify_user_session_token/1`,
  # whose absolute-only check stays intact (wiring idle-logout in would evict
  # currently-valid sessions — a behaviour regression). See
  # docs/auth-user-sessions.md.
  @idle_timeout_seconds nil

  schema "user_sessions" do
    field :token_hash, :string
    field :context, :string, default: "session"
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :mfa_verified_at, :utc_datetime_usec
    field :ip_address, :string

    # Which claim `ip_address` holds: "forwarded" (derived from a trusted
    # front's x-forwarded-for chain) or "peer" (the verified TCP peer). NULL on
    # every row minted before the trust boundary existed — see
    # `Barkpark.RateLimiter.client_ip_with_source/1`. A reader who cannot tell
    # the two apart cannot tell a real loopback client from a boundary that
    # silently stopped firing.
    field :ip_source, :string

    field :user_agent, :string

    # SAML birth context (nil for non-SAML sessions): lets logout send an
    # SP-initiated LogoutRequest, and lets an IdP's LogoutRequest find and
    # revoke exactly the sessions it names.
    field :saml_name_id, :string
    field :saml_session_index, :string
    field :saml_org_slug, :string

    belongs_to :user, Barkpark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Default session validity, in days."
  def default_validity_days, do: @default_validity_days

  @doc """
  Idle-timeout window in seconds, or `nil` when idle-logout is disabled
  (the default). Read through this accessor — never the attribute — so
  callers branch on a runtime value.
  """
  @spec idle_timeout_seconds() :: pos_integer() | nil
  def idle_timeout_seconds, do: @idle_timeout_seconds

  @doc """
  True when the session's absolute `expires_at` has passed. A `nil`
  `expires_at` (unbounded session) is never expired.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(session, now \\ DateTime.utc_now())
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false
  def expired?(%__MODULE__{expires_at: exp}, now), do: DateTime.compare(now, exp) != :lt

  @doc """
  True when idle-logout is enabled (`idle_timeout_seconds/0` non-nil) AND the
  session has been idle past that window (measured from `last_used_at`).
  Always `false` while the window is disabled. PURE predicate — not enforced on
  the verify path; see the module note.
  """
  @spec idle_expired?(t(), DateTime.t()) :: boolean()
  def idle_expired?(session, now \\ DateTime.utc_now())

  def idle_expired?(%__MODULE__{last_used_at: last}, now) do
    case idle_timeout_seconds() do
      nil ->
        false

      window ->
        base = last || now
        DateTime.compare(now, DateTime.add(base, window, :second)) != :lt
    end
  end

  @doc """
  True when the session is usable: not revoked, not absolutely expired, and
  not idle-expired. The single predicate a future hardened verify path would
  call; today's verify path enforces only `revoked_at` + absolute `expires_at`.
  """
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(session, now \\ DateTime.utc_now())

  def active?(%__MODULE__{revoked_at: r} = s, now) do
    is_nil(r) and not expired?(s, now) and not idle_expired?(s, now)
  end

  # ── Org session-policy predicates (era-w8-org-session-policy) ──────────────
  #
  # These take the window FROM THE CALLER (the org-resolved value), NOT the
  # held-back module constant `@idle_timeout_seconds`. They are the fail-closed
  # enforcement the verify path calls once an org governs the session. A `nil`
  # (or non-positive) bound imposes NO limit — the zero-tax default.

  @doc """
  True when `window` (seconds) is a positive idle bound AND the session has been
  idle past it, measured from `last_used_at` (falling back to `inserted_at`,
  then `now`). The org-policy counterpart of `idle_expired?/2`, driven by an
  explicit window instead of the module constant.
  """
  @spec idle_expired_for_window?(t(), pos_integer() | nil, DateTime.t()) :: boolean()
  def idle_expired_for_window?(session, window, now \\ DateTime.utc_now())

  def idle_expired_for_window?(%__MODULE__{last_used_at: last, inserted_at: ins}, window, now)
      when is_integer(window) and window > 0 do
    base = last || ins || now
    DateTime.compare(now, DateTime.add(base, window, :second)) != :lt
  end

  def idle_expired_for_window?(%__MODULE__{}, _window, _now), do: false

  @doc """
  True when `max_age` (seconds) is a positive absolute bound AND the session's
  age from birth (`inserted_at`) has reached it. The org-policy absolute-lifetime
  counterpart of `expired?/2` (which reads the per-session `expires_at`); this
  one measures from birth against an org-supplied window.
  """
  @spec absolute_expired_for_window?(t(), pos_integer() | nil, DateTime.t()) :: boolean()
  def absolute_expired_for_window?(session, max_age, now \\ DateTime.utc_now())

  def absolute_expired_for_window?(%__MODULE__{inserted_at: ins}, max_age, now)
      when is_integer(max_age) and max_age > 0 and not is_nil(ins) do
    DateTime.compare(now, DateTime.add(ins, max_age, :second)) != :lt
  end

  def absolute_expired_for_window?(%__MODULE__{}, _max_age, _now), do: false

  @doc """
  True when the session SATISFIES an org session policy — neither idle past
  `policy.idle_timeout_seconds` nor older than `policy.absolute_lifetime_seconds`.
  A `nil` bound on either axis imposes no limit, so the all-nil policy (the
  zero-tax default) is always satisfied. FAIL-CLOSED companion to `active?/2`:
  the verify path treats a `false` here as "no session" (logged out).
  """
  @spec within_org_policy?(t(), map(), DateTime.t()) :: boolean()
  def within_org_policy?(session, policy, now \\ DateTime.utc_now()) do
    idle = Map.get(policy, :idle_timeout_seconds)
    absolute = Map.get(policy, :absolute_lifetime_seconds)

    not idle_expired_for_window?(session, idle, now) and
      not absolute_expired_for_window?(session, absolute, now)
  end

  @doc """
  Default step-up window (seconds): how long a successful MFA factor keeps a
  session "fresh" for sensitive actions. 10 minutes — long enough to chain a
  few admin actions, short enough that a walked-away session goes stale fast.
  """
  @spec default_step_up_window() :: pos_integer()
  def default_step_up_window, do: 600

  @doc """
  True when the session presented an MFA factor within `window` seconds of
  `now`. A `nil` `mfa_verified_at` (never stepped up) is never fresh, and
  neither is an `mfa_verified_at` in the FUTURE.

  RECENCY, not DEADLINE — the distinction that separates this predicate from the
  five above it (`expired?/2`, `idle_expired?/2`, `idle_expired_for_window?/3`,
  `absolute_expired_for_window?/3`, `within_org_policy?/3`). All six read the
  wall clock against a stored instant, and all six are correctly class A: an
  absolute stored instant MUST be wall-clock, since it has to survive a restart
  and be comparable across nodes. Those five are CITED SAFE and deliberately
  keep their single-sided shape — a deadline's anchor is SUPPOSED to sit in the
  future, so flooring one would reject every live session at once (a mass
  logout) for zero security gain, and there is no second, clock-independent
  anchor to floor it against. Their residual, named out loud: under a backward
  wall-clock step every absolute-instant TTL in this module extends by the size
  of the step. That is inherent to correct class-A wall-clock semantics, not a
  defect.

  `mfa_verified_at` is the opposite shape: a RECENCY anchor the issuer stamps in
  the PAST, so an anchor later than `now` is nonsensical and is rejected
  (fail-closed). Not `abs/1` — the repo's two-sided gates all guard a
  remote-supplied signature timestamp; this value is server-written.
  """
  @spec mfa_fresh?(t(), pos_integer(), DateTime.t()) :: boolean()
  def mfa_fresh?(session, window \\ default_step_up_window(), now \\ DateTime.utc_now())
  def mfa_fresh?(%__MODULE__{mfa_verified_at: nil}, _window, _now), do: false

  def mfa_fresh?(%__MODULE__{mfa_verified_at: at}, window, now) do
    DateTime.compare(at, now) != :gt and
      DateTime.compare(now, DateTime.add(at, window, :second)) == :lt
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :context,
      :expires_at,
      :revoked_at,
      :last_used_at,
      :mfa_verified_at,
      :ip_address,
      :ip_source,
      :user_agent,
      :saml_name_id,
      :saml_session_index,
      :saml_org_slug,
      :user_id
    ])
    |> validate_required([:token_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
