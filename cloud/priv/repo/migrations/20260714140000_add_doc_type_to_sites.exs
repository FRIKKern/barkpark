defmodule BarkparkCloud.Repo.Migrations.AddDocTypeToSites do
  use Ecto.Migration

  # site-spawner W4 (charter D35): the content TYPE a static build's flagship
  # fetch reads. `@barkpark/core`'s `fetchFlagshipDoc` needs a doc type to query
  # (newest-of-type); today it is baked into the template as "post", which is
  # UNSAFE on guerrilla (production/post 404s — zero post docs — so a real
  # `npm run build` hard-fails, while production/paper serves 100 docs). Plumbing
  # this per-site makes the live proof pass with `--doc-type paper` while keeping
  # "post" the canonical default.
  #
  # NOT NULL + default "post" mirrors the `kind` column (D2): every existing row
  # — all container, all pre-W4 — backfills to the canonical default, so the
  # deploy payload can inject `site.doc_type` without ever seeing a NULL.
  def change do
    alter table(:sites) do
      add :doc_type, :string, null: false, default: "post"
    end
  end
end
