defmodule BarkparkCloud.Accounts.UserToken do
  @moduledoc """
  A USER bearer credential — DUAL-PURPOSE, discriminated by `context`:

    * `context = "session"` — the login bearer a logged-in User presents on the
      control-plane HTTP API (cloud-12a) after `POST /v1/auth/login`. The
      web-layer twin of `Registry.AgentToken`: same hash-at-rest discipline,
      different principal (a human User instead of an on-box agent).
    * `context = "pat"` — a **Personal Access Token**: a named, scoped,
      revocable credential a user mints for programmatic API use (adapted from
      Coolify's `app/Models/PersonalAccessToken.php`). Carries an `abilities`
      array (`read`/`write`/`deploy`/`root`), an optional bounded `expires_at`,
      a `last_used_at` stamp, a `revoked_at` tombstone, and the `team_id` it was
      minted under.

    * `context = "confirm"` / `"change_email"` — the email-verification-recovery
      lifecycle tokens: a single-use email-confirmation link and the 6-digit
      verified-email-change code. Both carry `sent_to` (the address the token was
      issued FOR, so a code can't be replayed against a different target) and, for
      the change code, `failed_attempts` (the brute-force lockout counter).

  One table, one verify-by-hash path; the `context` column is the discriminator
  and every query is scoped by it so the session lifecycle never touches PAT
  rows and vice-versa.

  Both kinds share the hash-at-rest invariant:

    * Only a `token_hash` (SHA-256, lowercase hex) is stored — NEVER the
      plaintext. The plaintext is returned exactly once at mint time
      (`Accounts.create_user_session_token/2` for sessions /
      `Accounts.create_personal_access_token/3` for PATs) and is unrecoverable
      after.
    * `revoked_at` / `expires_at` gate validity; verify rejects a revoked or
      expired token. `revoked_at` is the kill switch / tombstone — stamped by
      `revoke_user_session_token/1` (single-device logout), `revoke_user_session/2`
      (one row by id), and `revoke_all_user_sessions/2` ("sign out everywhere" on
      a password change), and reused for PAT revocation and member-removal, exactly
      as `Registry.revoke_agent_token/1` stamps the agent-token twin.
    * `ip_address` / `user_agent` / `last_used_at` are device metadata captured
      at mint and refreshed on each verify, backing the active-sessions list UI.

  A lookup is by hash: hash the presented plaintext, find the row, then check it
  is neither revoked nor past `expires_at`. `hash_token/1` is the single source
  of the hashing scheme so mint and verify can never drift.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # How long a freshly minted session token stays valid. Sessions are cheap to
  # re-mint (just log in again), so a bounded lifetime is the safe default; a
  # "remember me" / refresh flow is a later concern (YAGNI).
  @default_validity_days 30

  # Default PAT validity, in days. A PAT is a higher-risk long-lived credential,
  # so it ALSO carries a finite default horizon (Coolify's bounded-expiry select
  # — app/Livewire/Security/ApiTokens.php). `nil` (the "never" choice) is
  # allowed but opt-in.
  @pat_default_validity_days 30

  # email-verification-recovery per-context validity windows, as
  # `{seconds, :second}`. A confirm link is long-lived (you might click it days
  # later); an email-change code is short on purpose (the higher blast-radius
  # case). The password-reset window is NOT here — that flow rides the existing
  # `context = "reset"` lifecycle in `Accounts`, which owns its own horizon.
  @confirm_validity_days 7
  @change_email_validity_minutes 10

  # Hard cap on wrong 6-digit codes before an in-flight email change is LOCKED
  # (token revoked + pending_email dropped). A per-user lockout, distinct from
  # the mint-rate throttle — a code is only 10^6 wide, so it MUST fail closed
  # under brute force rather than lean on a rate limiter alone.
  @max_code_attempts 5

  # The PAT ability vocabulary — small, Coolify-shaped but CMS-flavoured:
  #   read   — baseline read of control-plane resources (the default).
  #   write  — mutating calls (create/deploy/env/domains/…).
  #   deploy — go-live / launch only (the exclusive deploy-token, like Coolify's
  #            `deploy` ability).
  #   root   — superset; bypasses every ability check. Exclusive at mint time.
  @abilities ~w(read write deploy root)

  schema "user_tokens" do
    field :token_hash, :string
    field :context, :string, default: "session"
    # PAT columns (personal-access-tokens)
    field :name, :string
    field :abilities, {:array, :string}, default: ["read"]
    # validity / kill-switch (shared by sessions + PATs)
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    # email-verification-recovery: the address a lifecycle token (confirm /
    # change_email) was issued FOR, and the per-token wrong-code counter that
    # backs the email-change brute-force lockout.
    field :sent_to, :string
    field :failed_attempts, :integer, default: 0
    # session device metadata (account-sessions)
    field :ip_address, :string
    field :user_agent, :string
    # session PROVENANCE: HOW this session was established, stamped at mint by
    # the write site that already knows the answer ("password", "two_factor",
    # "oauth:<provider>", "password_change", "register", "device_link"). NULL
    # means "we do not know" — every row minted before the column existed, and
    # any future mint site that has no honest answer. It is never inferred and
    # never backfilled: a partial provenance that cannot lie beats a complete one
    # that invents. Session-only; `pat_changeset/2` has its own cast list and can
    # neither receive nor expose it.
    field :origin, :string
    # STREAM BINDING (cch-w53-bl): on a `context = "sse"` ticket row, the id of
    # the `context = "session"` row that minted it. NULL means "not bound" —
    # every ticket row that predates the column, plus any mint site with no
    # honest answer — and the SSE loop then falls back to the user-wide liveness
    # check. Never inferred, never backfilled: a guessed binding would tie a
    # live stream to the WRONG device, which is worse than the unbound stream
    # this closes. Ticket-only; `pat_changeset/2` neither casts nor exposes it.
    field :session_token_id, :binary_id

    belongs_to :user, BarkparkCloud.Accounts.User
    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Default session-token validity, in days."
  def default_validity_days, do: @default_validity_days

  @doc "Default PAT validity, in days."
  def pat_default_validity_days, do: @pat_default_validity_days

  @doc "The allowed PAT abilities (`read`/`write`/`deploy`/`root`)."
  def abilities, do: @abilities

  @doc """
  Validity window for an email-verification-recovery token context, as
  `{seconds, :second}`. Confirm: 7 days. Change-email code: 10 minutes. (Password
  reset rides the existing `context = "reset"` lifecycle in `Accounts`, which
  owns its own window — no `:reset_password` here.)
  """
  @spec validity(:confirm | :change_email) :: {pos_integer(), :second}
  def validity(:confirm), do: {@confirm_validity_days * 24 * 3600, :second}
  def validity(:change_email), do: {@change_email_validity_minutes * 60, :second}

  @doc "Max wrong 6-digit codes before an in-flight email change is locked."
  def max_code_attempts, do: @max_code_attempts

  @doc """
  Generate a 6-digit numeric confirmation code for the email-change flow. Returns
  `{code, hash}` — the plaintext code is shown once (emailed to the NEW address);
  only `hash` (via `hash_token/1`) is stored, the SAME hash-at-rest discipline as
  a link token. Drawn from `:crypto.strong_rand_bytes`, not `:rand`, so the short
  code isn't predictable.
  """
  @spec generate_email_change_code() :: {String.t(), String.t()}
  def generate_email_change_code do
    code =
      :crypto.strong_rand_bytes(4)
      |> :binary.decode_unsigned()
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    {code, hash_token(code)}
  end

  @doc """
  Changeset for a SESSION token. Deliberately unchanged from the original — the
  session path can never grow PAT-validation surprises. `context` is castable so
  a session row is written with `"session"` explicitly.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :context,
      :expires_at,
      :revoked_at,
      :ip_address,
      :user_agent,
      # `:origin` MUST stay on this allowlist. `cast/3` silently DISCARDS any key
      # that is not listed — no Ecto warning, no compiler warning — so dropping
      # it here writes NULL on every row while the whole suite stays green. The
      # round-trip probe in accounts_test.exs (struct read AND raw SQL read) is
      # the only thing that reds when this line goes.
      :origin,
      # Same allowlist hazard as `:origin` above — `cast/3` discards an unlisted
      # key in silence, so dropping this line would write NULL on every ticket
      # row and quietly demote per-row stream revocation back to the user-wide
      # count. The round-trip probe in router_sse_per_row_revoke_test.exs is what
      # reds when it goes.
      :session_token_id,
      :last_used_at,
      :sent_to,
      :failed_attempts,
      :user_id
    ])
    |> validate_required([:token_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Changeset for a PAT row. Forces `context = "pat"`, requires a name + owner +
  TEAM, validates the abilities against the bounded vocabulary, and ENFORCES the
  exclusivity rules server-side (never trust the client) via
  `normalize_abilities/1`.

  `team_id` IS REQUIRED, and that is a security invariant rather than tidiness
  (cch-w30-s6 review). `Accounts.revoke_team_pats/2` ends a removed member's
  programmatic access with `where: t.team_id == ^tid` — team-scoped on purpose,
  since a `user_id`-only blast radius would cross tenants. A PAT row with a NULL
  `team_id` is therefore invisible to that filter and would OUTLIVE the
  membership it was minted under: a credential still reading and writing on a
  team its holder was removed from, which is the exact defect s6 exists to fix.
  The column is nullable (session rows legitimately leave it NULL) and until now
  the only thing keeping PATs team-bound was the `is_nil(current_team)` → 422
  `no_team` guard at `POST /v1/tokens` — one route's cond branch, not a property
  of the row. A second minting call site would have silently produced
  unrevokable credentials. Now the row itself refuses.
  """
  def pat_changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :name,
      :abilities,
      :expires_at,
      :revoked_at,
      :user_id,
      :team_id
    ])
    |> put_change(:context, "pat")
    |> validate_required([:token_hash, :name, :user_id, :team_id])
    |> validate_length(:name, min: 3, max: 255)
    |> validate_subset(:abilities, @abilities)
    |> normalize_abilities()
    |> validate_length(:abilities, min: 1)
    |> assoc_constraint(:user)
    |> assoc_constraint(:team)
    |> unique_constraint(:token_hash)
  end

  # Enforce the exclusivity rules server-side, mirroring Coolify's
  # ApiTokens.updatedPermissions (app/Livewire/Security/ApiTokens.php):
  #   * `root` collapses to just ["root"] (a superset — every other ability is
  #     redundant);
  #   * `deploy` is the exclusive deploy-token, so it collapses to ["deploy"];
  #   * otherwise dedupe.
  # The client UI mirrors this for ergonomics, but THIS is the authority.
  defp normalize_abilities(changeset) do
    case get_change(changeset, :abilities) || get_field(changeset, :abilities) do
      abilities when is_list(abilities) ->
        cond do
          "root" in abilities -> put_change(changeset, :abilities, ["root"])
          "deploy" in abilities -> put_change(changeset, :abilities, ["deploy"])
          true -> put_change(changeset, :abilities, Enum.uniq(abilities))
        end

      _ ->
        changeset
    end
  end

  @doc "Hash a raw token string for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
