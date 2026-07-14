defmodule BarkparkCloud.Repo.Migrations.AddContentBindingToSitesAndDeployments do
  use Ecto.Migration

  # site-spawner W1 (charter D1/D2/D3): EXTEND the existing container-hosting
  # substrate for content-bound STATIC sites — the "spawn an Astro site next to
  # Phoenix" story. No parallel `site` concept: one row shape, discriminated by
  # `kind`.
  #
  # sites gains:
  #   * kind — THE discriminator. "container" (BYO-repo runtime, the pre-W1 shape)
  #     or "static" (Astro/Hugo/plain, built once and served as files). Defaults
  #     to "container" so every existing row keeps its meaning.
  #   * bootstrap_workspace/project/dataset — the content binding: WHICH Barkpark
  #     dataset the static build fetches from over the internal link. Mirrors the
  #     Barkpark row's own bootstrap_* triple.
  #   * read_token_encrypted — a public-read-scoped token the build uses to read
  #     that dataset. Vault-encrypted at rest exactly like env_encrypted; the
  #     plaintext is never persisted.
  #
  # deployments gains:
  #   * build_id — hash(code_rev + content_rev + config). Names releases/<build_id>/
  #     on disk AND is the PLAN idempotency key: a repeat build_id for the same
  #     site is a no-op (enforced by the unique index below).
  #   * content_rev — the content revision this build baked in (drives build_id
  #     and lets a content-only change re-trigger a build).
  #   * stage — nullable STAGE telemetry (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE),
  #     the six-phase deploy pipeline's current phase. Latest-wins, best-effort;
  #     it rides ALONGSIDE the unchanged 6-value `status` enum (which is NOT
  #     widened — status stays the coarse queued/building/pushing/live/… lifecycle).
  def change do
    alter table(:sites) do
      add :kind, :string, null: false, default: "container"
      add :bootstrap_workspace, :string
      add :bootstrap_project, :string
      add :bootstrap_dataset, :string
      add :read_token_encrypted, :binary
    end

    alter table(:deployments) do
      add :build_id, :string
      add :content_rev, :string
      add :stage, :string
    end

    # A repeat build_id for the same site is an enforceable no-op — the DB
    # backstop for PLAN-stage idempotency. NULL build_id rows (every pre-W1
    # container deployment) are exempt: Postgres treats NULLs as distinct, so the
    # partial predicate keeps the index tight and back-compatible.
    create unique_index(:deployments, [:site_id, :build_id],
             name: :deployments_site_build_id_index,
             where: "build_id IS NOT NULL"
           )
  end
end
