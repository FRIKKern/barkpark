defmodule Barkpark.Accounts.User do
  @moduledoc """
  A Barkpark core user — a human principal that logs in with email + password.

  Core historically had no user model (only API tokens); this is the first-class
  account. Security discipline mirrors `cloud/`'s `Accounts.User`:

    * password is hashed with **argon2id** (`Argon2.hash_pwd_salt/1`) and the
      virtual `:password` is dropped — plaintext never reaches the DB;
    * the email is downcased + uniqueness-guarded by a citext unique index;
    * `totp_secret` is encrypted at rest (`Barkpark.EncryptedBinary` / Cloak);
    * `recovery_codes_hashed` holds only SHA-256 hashes of one-time codes.

  TOTP MFA, email confirmation, and password reset flows are driven by
  `Barkpark.Accounts`; this module owns the schema + changesets only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Loose-but-real email shape — exactly one "@", no spaces. The citext unique
  # index is the real integrity guard (matches cloud/'s deliberate non-RFC rule).
  @email_format ~r/^[^\s@]+@[^\s@]+$/

  @min_password_length 12
  @max_password_length 72

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime_usec
    field :totp_secret, Barkpark.EncryptedBinary, redact: true
    field :totp_enabled, :boolean, default: false
    field :recovery_codes_hashed, {:array, :string}, default: []

    has_many :sessions, Barkpark.Accounts.UserSession

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Minimum accepted password length (argon2 caps the hashed input at 72 bytes)."
  def min_password_length, do: @min_password_length

  @doc "Changeset for registering a brand-new user (validates + hashes password)."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_email()
    |> validate_password()
    |> hash_password()
  end

  @doc "Changeset for changing an existing user's password (caller verifies the current one)."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
    |> hash_password()
  end

  @doc "Changeset that stamps `confirmed_at` (email verification)."
  def confirm_changeset(user, now \\ DateTime.utc_now()) do
    change(user, confirmed_at: DateTime.truncate(now, :microsecond))
  end

  @doc "Changeset for TOTP enrolment / disablement + recovery-code hashes."
  def totp_changeset(user, attrs) do
    user
    |> cast(attrs, [:totp_secret, :totp_enabled, :recovery_codes_hashed])
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, @email_format, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> update_change(:email, &String.downcase/1)
    |> unsafe_validate_unique(:email, Barkpark.Repo)
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
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verify `password` against the user's hash in constant time. Runs a dummy hash
  when `user` is nil so the response time does not leak account existence
  (Argon2's no-user-verify defense).
  """
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password) do
    Argon2.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end
end
