defmodule BarkparkCloud.Repo.Migrations.AddPrebuiltDeploySource do
  use Ecto.Migration

  # site-spawner W9 (charter D86/D87/D91/D97): THE BUILD LEAVES THE SERVING BOX.
  #
  # Until now every byte a spawned site serves was produced ON the box that
  # serves it — `npm ci && npm run build` competing with the API for the same two
  # cores. A PREBUILT deploy uploads the already-built `dist/` instead, and the
  # box only stages + health-gates + switches it.
  #
  # deployments gains:
  #
  #   * source — WHERE the bytes came from. "box-build" (the pre-W9 default, so
  #     every existing row backfills to it without a data migration) or
  #     "prebuilt" (the bytes were built elsewhere and uploaded). It mirrors
  #     `trigger` exactly — NOT NULL + a default, set at CREATE and never mutated
  #     by a transition, because provenance is a fact about how a row was born.
  #     A deploy stream that could not tell the two apart would be claiming the
  #     control plane knows something it does not.
  #
  #   * artifact_sha256 — the digest of the uploaded tarball, recorded by the
  #     upload route BEFORE the driver is started. Nullable: a box-build has no
  #     artifact, and a prebuilt row is minted before its bytes exist (the
  #     build_id is baked INTO those bytes, so the mint must come first).
  #
  # sites gains:
  #
  #   * prebuilt_enabled — the per-site opt-in. Default FALSE: turning a site's
  #     deploys over to bytes the control plane did not produce is a different
  #     trust statement than building them on the box, so it is an explicit
  #     choice per site, never a fleet-wide flip.
  #
  # site_artifacts is the SINK that retires the `file://` plane. The old upload
  # route wrote a host-local file and returned `file:///…` — but the control
  # plane's container declares no volume for that dir AND runs on a different
  # host from the box, so the "survives restarts" promise in runtime.exs was
  # false and nothing could ever read the path back. `cloud_pgdata` is the CP's
  # only durable volume, so the bytes live in Postgres (sites already carries
  # three :binary columns). They are a SEPARATE table on purpose: a bytea column
  # on `deployments` would make the driver's 2-second poll (`Repo.get(Deployment,
  # …)`) drag up to 32 MB out of Postgres on every beat.
  def change do
    alter table(:deployments) do
      add :source, :string, null: false, default: "box-build"
      add :artifact_sha256, :string
    end

    alter table(:sites) do
      add :prebuilt_enabled, :boolean, null: false, default: false
    end

    create table(:site_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :site_id, references(:sites, type: :binary_id, on_delete: :delete_all), null: false

      # Nullable: the site-scoped upload route mints an artifact BEFORE it is
      # bound to any deployment. `on_delete: :delete_all` means a deleted
      # deployment takes its (potentially 32 MB) bytes with it.
      add :deployment_id, references(:deployments, type: :binary_id, on_delete: :delete_all)

      add :sha256, :string, null: false
      add :byte_size, :integer, null: false
      add :bytes, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:site_artifacts, [:site_id])

    # At most ONE artifact per deployment — the DB backstop under the upload
    # route's re-POST no-op. Partial, because the site-scoped uploads carry a
    # NULL deployment_id and must not collide with each other.
    create unique_index(:site_artifacts, [:deployment_id],
             where: "deployment_id IS NOT NULL",
             name: :site_artifacts_deployment_id_index
           )
  end
end
