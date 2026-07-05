defmodule Barkpark.Accounts.WebauthnCredential do
  @moduledoc """
  A registered WebAuthn/passkey credential bound to a `User`.

  `credential_id` is the raw authenticator credential handle (unique across all
  users). `cose_key` is the credential's public key, stored term-encoded (a COSE
  key map: integer labels → binaries/ints), used to verify future assertions.
  `sign_count` is the authenticator's monotonic signature counter — a decrease
  signals a cloned authenticator. No secret material is ever stored: the private
  key never leaves the authenticator.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :cose_key, :binary
    field :sign_count, :integer, default: 0
    field :nickname, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, Barkpark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(cred, attrs) do
    cred
    |> cast(attrs, [:credential_id, :cose_key, :sign_count, :nickname, :last_used_at, :user_id])
    |> validate_required([:credential_id, :cose_key, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:credential_id)
  end
end
