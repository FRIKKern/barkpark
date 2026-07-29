defmodule BarkparkCloud.Registry.SiteArtifact do
  @moduledoc """
  site-spawner W9 (charter D91) — an uploaded build ARTIFACT: the tar.gz of a
  `dist/` that was built somewhere other than the serving box.

  ## Why Postgres, and why not on `deployments`

  The pre-W9 upload route wrote the tarball to a host-local directory and handed
  back a `file://` URL, on the theory that "the builder process shares the dir".
  Nothing shared it: the control-plane container declares no volume for that
  path, and the box that would read it runs on a different host entirely. The
  URL was a path nothing could ever open, and `runtime.exs` claimed it survived
  restarts. `cloud_pgdata` is the control plane's ONLY durable volume, so the
  bytes live here.

  They are a SEPARATE table rather than a `bytea` column on `deployments`
  because the deploy driver re-reads its Deployment row every two seconds while
  polling the box — a column would drag up to 32 MB out of Postgres on every
  beat of every build.

  ## Lifecycle

  Minted by the upload route, read ONCE by `Sites.Deploy` when it builds the
  box payload, and dropped the moment the deployment settles (live or failed) —
  the box has the bytes by then, and a terminal Deployment is never re-driven.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "site_artifacts" do
    # The raw tarball. Never serialized to any JSON view — an artifact is
    # identified on the wire by its id and digest, never by its content.
    field :bytes, :binary
    field :sha256, :string
    field :byte_size, :integer

    belongs_to :site, BarkparkCloud.Registry.Site
    belongs_to :deployment, BarkparkCloud.Registry.Deployment

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for storing an uploaded artifact. `sha256` is computed by the
  caller from the bytes it actually received — never accepted from the client,
  which is the whole point of recording a digest.

  `deployment_id` is optional: the site-scoped upload route stores an artifact
  that is not yet bound to any deployment.
  """
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:bytes, :sha256, :byte_size, :site_id, :deployment_id])
    |> validate_required([:bytes, :sha256, :byte_size, :site_id])
    |> assoc_constraint(:site)
    |> assoc_constraint(:deployment)
    # At most ONE artifact per deployment. The upload route already answers a
    # repeat digest as a 200 no-op; this is the DB backstop under a concurrent
    # double-upload, surfaced as a changeset error rather than a raised
    # Ecto.ConstraintError.
    |> unique_constraint(:deployment_id, name: :site_artifacts_deployment_id_index)
  end
end
