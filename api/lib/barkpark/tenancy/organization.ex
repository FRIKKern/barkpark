defmodule Barkpark.Tenancy.Organization do
  @moduledoc """
  A thin tier ABOVE the Workspace. An Organization groups one or more
  Workspaces so a single enterprise identity connection (SSO/SCIM, later
  waves) maps to a customer that may span several workspaces.

  The tier is additive: a Workspace's `organization_id` is nullable and no
  authorization path reads it yet. Organizations are the anchor future waves
  hang per-org SSO/SCIM connections and policies on.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "organizations" do
    field :slug, :string
    field :name, :string

    # era-w2-org-require-mfa: when true, every user who is a member (via any
    # of this org's workspaces) must have an MFA factor enrolled before the
    # session-auth surface serves them. Opt-in; default false = no behaviour
    # change. Governing rule across orgs: ANY-org-requires → enforce.
    field :require_mfa, :boolean, default: false

    # era-w8-org-session-policy: org-wide session lifetime governance, in
    # seconds. NULL on either axis = no bound → byte-identical to the hardcoded
    # 30-day / no-idle default. `session_idle_timeout_seconds` logs out a session
    # idle past the window (measured from last activity); `session_absolute_
    # lifetime_seconds` logs one out once its age from birth reaches the bound.
    # Strictest-wins across a user's orgs (`Tenancy.org_session_policy_for_user/1`).
    field :session_idle_timeout_seconds, :integer
    field :session_absolute_lifetime_seconds, :integer

    has_many :workspaces, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(org, attrs) do
    org
    |> cast(attrs, [
      :slug,
      :name,
      :require_mfa,
      :session_idle_timeout_seconds,
      :session_absolute_lifetime_seconds
    ])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_number(:session_idle_timeout_seconds, greater_than: 0)
    |> validate_number(:session_absolute_lifetime_seconds, greater_than: 0)
    |> unique_constraint(:slug)
  end
end
