defmodule Barkpark.Tenancy.Workspace do
  @moduledoc """
  A Workspace is the hard tenant boundary. It owns Projects and Memberships.
  Slug is unique across all workspaces and appears in the routing path.

  ## Deletion — DO NOT call `Repo.delete/1` directly on a Workspace

  Use `Barkpark.Tenancy.delete_workspace/1`. It is the canonical
  workspace-delete path and is the ONLY safe entry point:

    * walks every `media_files` row and fires `Media.delete_file/1`
      (blob removal from object storage + CDN purge + `:after_media_delete`
      plugin hook) BEFORE the workspace row is deleted;
    * walks every `documents` row and fires `Content.delete_document/1`
      (`:before_document_delete` / `:after_document_delete` plugin hooks);
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

  schema "workspaces" do
    field :slug, :string
    field :name, :string

    has_many :projects, Barkpark.Tenancy.Project
    has_many :memberships, Barkpark.Tenancy.Membership

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def reserved_slugs, do: @reserved_slugs

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:slug, :name])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint(:slug)
  end
end
