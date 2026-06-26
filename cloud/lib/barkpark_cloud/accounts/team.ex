defmodule BarkparkCloud.Accounts.Team do
  @moduledoc """
  A Team is the control-plane boundary a set of Barkpark instances + members
  belong to — the Cloud analogue of api/'s `Barkpark.Tenancy.Workspace`.

  Slug rules are mirrored from the Workspace: lowercase alphanumeric +
  hyphens (`@slug_format`), a reserved-prefix denylist, and a global UNIQUE.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Slugs that would collide with reserved routing prefixes / system surfaces
  # on the future Cloud control-plane web. Mirrors the Workspace denylist.
  @reserved_slugs ~w(admin api login signup settings billing dashboard team teams user users)

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "teams" do
    field :name, :string
    field :slug, :string

    has_many :team_memberships, BarkparkCloud.Accounts.TeamMembership
    has_many :users, through: [:team_memberships, :user]

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def reserved_slugs, do: @reserved_slugs

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint(:slug)
  end
end
