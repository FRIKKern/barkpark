defmodule BarkparkCloud.OAuth.State do
  @moduledoc """
  The single-use ledger row behind the OAuth CSRF `state` (oauth-sso).

  The `state` param is a self-verifying HMAC-signed token (see
  `BarkparkCloud.OAuth`) — tamper-proof and TTL-bound WITHOUT a DB row. This
  schema adds the one property a signed token can't give itself: SINGLE USE. Each
  minted state inserts one row keyed by its random `nonce`; `verify_state/2`
  deletes it (a single DELETE) and rejects any state whose nonce is already gone
  (a replay) or past `expires_at`. The `nonce` unique index is the integrity
  guard against two states colliding on the same CSPRNG nonce.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "oauth_states" do
    field :nonce, :string
    field :provider, :string
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Changeset for minting a single-use state ledger row."
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:nonce, :provider, :expires_at])
    |> validate_required([:nonce, :provider, :expires_at])
    |> unique_constraint(:nonce)
  end
end
