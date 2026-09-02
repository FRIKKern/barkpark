defmodule BarkparkCloud.Accounts.User do
  @moduledoc """
  A Cloud User — the principal behind "one login for all your Barkparks".

  Email + password (no OAuth yet). The password is never stored:
  `registration_changeset/2` hashes it with `Bcrypt.hash_pwd_salt` into
  `hashed_password` and DROPS the virtual `:password` field, so the plaintext
  never reaches the DB.

  Account lifecycle (email-verification-recovery) rides two added columns, each
  with its own focused changeset so a flow validates only what it owns:
  `confirmed_at` (NULL until `confirm_changeset/1` proves the email) and
  `pending_email` (staged by `email_change_changeset/2`, committed by
  `apply_email_change_changeset/1`). Password reset re-uses `password_changeset/2`
  unchanged.

  OAuth (oauth-sso): social login DOES land now — via an `external_identities`
  table keyed by `(provider, provider_uid) → user_id` (never email), NOT columns
  here. `oauth_changeset/2` births a PASSWORDLESS user (a random `hashed_password`
  the account can never be logged into with) whose only credential is the linked
  external identity, until a future password-reset sets a real one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Loose-but-real email shape — exactly one "@", no spaces. Deliberately not
  # an RFC-5322 monster; the citext unique index is the real integrity guard.
  # cch-email-format-missing-u-modifier — the `u` modifier is DELIBERATE. Without
  # it PCRE's \s is ASCII-only, so U+00A0 (NBSP) and every other Unicode space
  # passed as "not whitespace" and an address could carry apparent word breaks
  # (measured: `Regex.match?(~r/\s/, "\u00A0")` is false, `~r/\s/u` is true).
  # Tightened 2026-09-02 after checking the live control plane for rows that would
  # newly fail: users.email 0 of 27, users.pending_email 0 of 0,
  # team_invitations.email 0 of 1 (and 0 rows with ANY non-ASCII byte) — nothing
  # is locked out by this change.
  @email_format ~r/^[^\s@]+@[^\s@]+$/u

  @min_password_length 12
  @max_password_length 72

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    # email-verification-recovery: NULL until the emailed confirm token proves
    # the address; `pending_email` stages the target of a verified email change
    # until the 6-digit code is proven.
    field :confirmed_at, :utc_datetime_usec
    field :pending_email, :string

    # two-factor-auth (per-user, opt-in TOTP). Stored encrypted (the secret) /
    # hashed-then-encrypted (the recovery codes); `redact: true` keeps them out
    # of inspect/logs, exactly like `:hashed_password`. NEVER cast from user
    # input — written only via the dedicated changesets below. `last_step` is
    # the replay guard's high-water mark (not secret, so no redaction).
    field :two_factor_secret, :string, redact: true
    field :two_factor_recovery_codes, :string, redact: true
    field :two_factor_confirmed_at, :utc_datetime_usec
    field :two_factor_last_step, :integer

    has_many :team_memberships, BarkparkCloud.Accounts.TeamMembership
    has_many :external_identities, BarkparkCloud.Accounts.ExternalIdentity

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Minimum accepted password length (Bcrypt caps the hashed input at 72 bytes)."
  def min_password_length, do: @min_password_length

  @doc """
  Changeset for registering a brand-new user.

  Validates the email shape + uniqueness (case-insensitive via the citext
  column), enforces the password length window, and — only when the rest of
  the changeset is valid — hashes the password into `hashed_password` and
  removes the virtual `:password`. The email is downcased so the stored value
  is canonical even though citext already compares case-insensitively.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_email()
    |> validate_password()
    |> hash_password()
  end

  @doc """
  Changeset for changing an EXISTING user's password.

  Validates the new password against the same length window as registration and
  hashes it into `hashed_password`, dropping the virtual `:password`. Does NOT
  touch the email — re-uses the shared `validate_password/1` + `hash_password/1`
  helpers so the registration and change paths can never drift on the rules.

  The caller (`Accounts.update_user_password/4`) is responsible for verifying the
  CURRENT password first; this changeset only governs the NEW one.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
    |> hash_password()
  end

  @doc """
  Changeset for a PASSWORDLESS OAuth-birthed user (oauth-sso).

  Casts + validates ONLY the email (same shape/uniqueness/downcasing rules as
  registration) and sets a random `hashed_password` so the NOT-NULL column is
  satisfied while the account can never be logged into by password — its only
  credential is the linked external identity, until a future password-reset sets
  a real one. Deliberately does NOT go through `registration_changeset/2`: there
  is no plaintext password to validate against the 12-char minimum, so pushing a
  synthetic password through the password rules would be theatre.
  """
  def oauth_changeset(user, attrs) do
    changeset =
      user
      |> cast(attrs, [:email])
      |> validate_email()

    if changeset.valid? do
      random = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(random))
    else
      changeset
    end
  end

  @doc "Stamp `confirmed_at = now` — the email-confirmation commit."
  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
  end

  @doc """
  Stage a pending email-change target on `:pending_email`. Validated + downcased
  the same way registration validates `:email`. The "address already in use"
  check is done in the context (`Accounts.deliver_user_update_email_instructions/2`
  via `get_user_by_email/1`) before this runs; the `users.email` unique index is
  the commit-time race backstop in `apply_email_change_changeset/1`. Nothing is
  committed until the 6-digit code is proven.
  """
  def email_change_changeset(user, attrs) do
    user
    |> cast(attrs, [:pending_email])
    |> validate_required([:pending_email])
    |> validate_format(:pending_email, @email_format,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:pending_email, max: 160)
    |> update_change(:pending_email, &String.downcase/1)
  end

  @doc """
  Commit a confirmed email change: swap `email := pending_email` and clear
  `pending_email`. The `users.email` unique index is the race backstop.
  """
  def apply_email_change_changeset(%__MODULE__{pending_email: pending} = user) do
    user
    |> change(email: pending, pending_email: nil)
    |> unique_constraint(:email)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, @email_format, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> update_change(:email, &String.downcase/1)
    |> unsafe_validate_unique(:email, BarkparkCloud.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: @min_password_length, max: @max_password_length)
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  ## two-factor-auth changesets
  ##
  ## All use `change/2` (not `cast/3`) so the encrypted secret / hashed codes /
  ## replay-guard step can only be set by the Accounts context — never from
  ## request params. `is_nil(two_factor_confirmed_at)` is the single "is 2FA
  ## on?" check, exactly Coolify's `two_factor_confirmed_at` semantics.

  @doc "Stamp the encrypted secret during enroll; confirmed_at stays NULL (inert)."
  def two_factor_enroll_changeset(user, encrypted_secret) do
    change(user,
      two_factor_secret: encrypted_secret,
      two_factor_recovery_codes: nil,
      two_factor_confirmed_at: nil,
      two_factor_last_step: nil
    )
  end

  @doc """
  Flip 2FA on: stamp confirmed_at + the encrypted recovery-code hashes, and seed
  the replay high-water mark with the enrollment `step` so the confirming code
  can't be replayed against the first login challenge.
  """
  def two_factor_confirm_changeset(user, encrypted_codes, confirmed_at, step)
      when is_integer(step) do
    change(user,
      two_factor_recovery_codes: encrypted_codes,
      two_factor_confirmed_at: confirmed_at,
      two_factor_last_step: step
    )
  end

  @doc "Disable 2FA: null all four columns."
  def two_factor_disable_changeset(user) do
    change(user,
      two_factor_secret: nil,
      two_factor_recovery_codes: nil,
      two_factor_confirmed_at: nil,
      two_factor_last_step: nil
    )
  end

  @doc "Replace the recovery-code set (regenerate / consume-one)."
  def two_factor_codes_changeset(user, encrypted_codes) do
    change(user, two_factor_recovery_codes: encrypted_codes)
  end
end
