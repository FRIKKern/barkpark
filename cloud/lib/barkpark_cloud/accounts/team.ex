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

  # A team name is free-form display text, but it must not carry C0/C1 control
  # bytes (NUL 0x00 … 0x1f, plus DEL 0x7f and the 0x80–0x9f C1 range). The NUL
  # byte is the sharp edge: it's invalid UTF-8 for a Postgres text column, so an
  # unsanitized name reaches the INSERT and Postgres raises 22021
  # (character_not_in_repertoire) — an uncaught Postgrex error that escapes as an
  # HTTP 500 on the unauthenticated /v1/auth/register surface. Rejecting it at
  # the changeset boundary turns that 500 into a clean 422 and keeps
  # attacker-supplied control chars off the wire. The slug never carries these
  # (its @slug_format is alnum+hyphen), but we guard it too for defense in depth.
  #
  # Phrased as the POSITIVE shape `validate_format` wants: the whole string is
  # zero-or-more NON-control chars. A NUL/control byte anywhere fails the match.
  @no_control_chars ~r/\A[^\x00-\x1f\x7f-\x9f]*\z/u

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
    |> validate_format(:name, @no_control_chars, message: "must not contain control characters")
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_format(:slug, @no_control_chars, message: "must not contain control characters")
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint(:slug)
  end
end
