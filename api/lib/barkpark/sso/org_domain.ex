defmodule Barkpark.Sso.OrgDomain do
  @moduledoc """
  A domain claimed by an Organization for SSO auto-routing. `verified_at` is set
  only after the DNS TXT record proves ownership.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "org_domains" do
    field :domain, :string
    field :dns_token, :string
    field :verified_at, :utc_datetime_usec

    belongs_to :organization, Barkpark.Tenancy.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:organization_id, :domain, :dns_token, :verified_at])
    |> validate_required([:organization_id, :domain, :dns_token])
    |> update_change(:domain, &String.downcase/1)
    |> assoc_constraint(:organization)
    |> unique_constraint(:domain)
  end
end
