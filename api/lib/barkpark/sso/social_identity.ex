defmodule Barkpark.Sso.SocialIdentity do
  @moduledoc "Links a Barkpark User to a `(provider, external_id)` social account."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "social_identities" do
    field :provider, :string
    field :external_id, :string
    belongs_to :user, Barkpark.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(si, attrs) do
    si
    |> cast(attrs, [:user_id, :provider, :external_id])
    |> validate_required([:user_id, :provider, :external_id])
    |> assoc_constraint(:user)
    |> unique_constraint([:provider, :external_id],
      name: :social_identities_provider_external_idx
    )
  end
end
