defmodule Barkpark.Sso.SocialProvider do
  @moduledoc """
  App-level OAuth client credentials for a social login provider
  (`google` / `github` / `microsoft`). `client_secret` is encrypted at rest.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(google github microsoft)
  @type t :: %__MODULE__{}

  schema "social_providers" do
    field :provider, :string
    field :client_id, :string
    field :client_secret, Barkpark.EncryptedBinary, redact: true
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end

  def providers, do: @providers

  def changeset(p, attrs) do
    p
    |> cast(attrs, [:provider, :client_id, :client_secret, :enabled])
    |> validate_required([:provider, :client_id])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint(:provider)
  end
end
