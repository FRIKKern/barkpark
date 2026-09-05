defmodule Barkpark.Tenancy.Workspace do
  @moduledoc """
  A Workspace is the hard tenant boundary. It owns Projects and Memberships.
  Slug is unique across all workspaces and appears in the routing path.

  ## Deletion — DO NOT call `Repo.delete/1` directly on a Workspace

  Use `Barkpark.Tenancy.delete_workspace/1`. It is the canonical
  workspace-delete path and is the ONLY safe entry point:

    * walks every `media_files` row and fires `Media.delete_file/2` with the
      workspace scope and `where_used: :cascade` (blob removal from object
      storage + CDN purge + `:after_media_delete` plugin hook) BEFORE the
      workspace row is deleted. `:cascade` is the honest
      policy here and not a shortcut: the workspace that owns the blob owns
      every document that could reference it, and both are going away in the
      same operation. `Media.delete_file/2` has NO default `:where_used`;
      arity-1 no longer exists;
    * walks every `documents` row and fires `Content.delete_document/1`
      (`:before_delete` / `:after_delete` plugin hooks);
    * THEN `Repo.delete(workspace)`, letting Postgres CASCADE prune the
      remaining child tables (projects, datasets, memberships, webhooks,
      search_*, mutation_events, paper_events, …).

  Calling `Repo.delete(workspace)` directly skips the cleanup pass and
  reintroduces the orphan-blob / orphan-CDN-cache / missed-hook leak
  documented in `test/barkpark/tenancy_delete_workspace_test.exs`
  ("control: raw Repo.delete(workspace) bypasses cleanup"). The control
  test deliberately uses the raw form to PROVE the leak — production
  callers must not.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Slugs that would collide with reserved routing prefixes / system surfaces.
  @reserved_slugs ~w(admin api _plugins studio login media v1 w p)

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  # Known non-normal workspace tiers. `nil` (the common case) is a normal
  # workspace and is never validated here (validate_inclusion only runs on a
  # cast, non-nil value). Only `"playground"` exists today.
  @tiers ~w(playground)

  schema "workspaces" do
    field :slug, :string
    field :name, :string

    # Per-workspace preferences bag (ts-w4e). Additive jsonb, defaults to `%{}`.
    # The theme system reads `settings["theme"]` via `Tenancy.workspace_theme/1`
    # (validated against the known theme ids, evergreen fallback). Absent/unknown
    # → the baked-in default, so a workspace with no settings renders unchanged.
    field :settings, :map, default: %{}

    # Quota + suspension state (perfect-plan-build W1, charter D13). Read at the
    # mutate seam by `BarkparkWeb.Plugs.RequireWithinQuota`; written by
    # `Barkpark.Tenancy.Quota`. `quota` NULL = unlimited (every workspace ships
    # uncapped); `suspended` is a hard write-block flag defaulting false, so the
    # gate is a no-op until an operator sets a quota or suspends.
    field :quota, :integer
    field :suspended, :boolean, default: false
    field :suspended_reason, :string
    field :suspended_at, :utc_datetime_usec

    # Ephemeral-playground TTL + tier (perfect-plan-build W2c, charter D25/D27).
    # `expires_at` NULL = never expires (every normal workspace is permanent);
    # a playground workspace is stamped `now + 48h` at provision. `tier` NULL =
    # a normal workspace; `"playground"` marks a disposable quota-capped one
    # minted by the front door. Both cast below; the TTL reaper (W3) scans the
    # `expires_at` index.
    field :expires_at, :utc_datetime_usec
    field :tier, :string

    # Thin Organization tier (era-w1-org): nullable, additive, not read by any
    # authorization path — a workspace joins an org when SSO/SCIM is configured.
    belongs_to :organization, Barkpark.Tenancy.Organization

    has_many :projects, Barkpark.Tenancy.Project
    has_many :memberships, Barkpark.Tenancy.Membership

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def reserved_slugs, do: @reserved_slugs

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:slug, :name, :organization_id, :settings, :expires_at, :tier])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> validate_inclusion(:tier, @tiers, message: "is not a known tier")
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:organization_id)
  end
end
