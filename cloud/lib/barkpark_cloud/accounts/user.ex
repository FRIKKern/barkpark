defmodule BarkparkCloud.Accounts.User do
  @moduledoc """
  A Cloud User — the principal behind "one login for all your Barkparks".

  Email + password only (YAGNI: no OAuth, no email-confirmation, no
  password-reset flows yet — those are later tasks). The password is never
  stored: `registration_changeset/2` hashes it with `Bcrypt.hash_pwd_salt`
  into `hashed_password` and DROPS the virtual `:password` field, so the
  plaintext never reaches the DB.

  OAuth note: when social login lands, add an external-identities table keyed
  by (provider, provider_uid) → user_id rather than columns here; do not grow a
  provider abstraction until a second provider actually exists.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Loose-but-real email shape — exactly one "@", no spaces. Deliberately not
  # an RFC-5322 monster; the citext unique index is the real integrity guard.
  @email_format ~r/^[^\s@]+@[^\s@]+$/

  @min_password_length 12
  @max_password_length 72

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    has_many :team_memberships, BarkparkCloud.Accounts.TeamMembership

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
end
