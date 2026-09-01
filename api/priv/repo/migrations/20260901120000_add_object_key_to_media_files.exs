defmodule Barkpark.Repo.Migrations.AddObjectKeyToMediaFiles do
  use Ecto.Migration

  # THE READ-SIDE TENANT WALL FOR BLOB BYTES (task-8eb6542ece62aff1).
  #
  # `media_files` uniqueness is `(path, dataset_id)`, but the blob store was
  # addressed by `path` ALONE — `serve_strategy(file.path)`. Two rows in
  # different tenants at one path therefore resolved to ONE object, and the
  # second claimant's own scoped GET answered 200 carrying the first one's
  # bytes. `authorize_blob_key/2` closed the WRITE seam (it refuses the
  # victim's repair) and structurally could not close the read.
  #
  # `object_key` is that row's OWN object address, decided once at insert by
  # `Barkpark.Media.Storage.ObjectKey.derive/3` and never recomputed. Deciding
  # it per-read is unsound: "the earliest row at this path owns it" is a
  # function of the live row SET, so deleting the earliest row silently
  # re-points every other claimant at the flat key — in `delete_file/2` that is
  # deterministic, not even a race, because the deferred `Blobstore.delete`
  # runs after `Repo.delete` commits. A stored address cannot move.
  #
  # NOTHING IS MOVED AND NOTHING IS REWRITTEN. `media_files.path` is a
  # PUBLISHED REFERENCE — documents persist `"/media/files/<path>"` into their
  # content and `serve/2` resolves that literal string (pinned by
  # `test/barkpark/media_path_is_a_published_reference_test.exs`). This adds a
  # column beside it; `path` is untouched, every published URL still names the
  # same string, and every uncontested row still addresses the same object.
  #
  # THE BACKFILL IS THE SEAL FOR EXISTING DATA, and it is deliberately not a
  # blanket `object_key = path`. Ranked by `(inserted_at, id)` within each
  # `path`:
  #
  #   * rn = 1 — the first claimant keeps the flat key. Its bytes are the ones
  #     physically there: `authorize_blob_key/2` refused every later claimant's
  #     push, and `upload/3` writes as it inserts. Byte-identical behaviour.
  #   * rn > 1 with a `dataset_id` — namespaced to its OWN tenant shadow
  #     `d/<dataset_id>/<path>`. This is the row that was being served someone
  #     else's bytes; after this it addresses an object only it can hold.
  #   * `dataset_id IS NULL` — left flat regardless of rank. The untenanted
  #     layer has no namespace to resolve within, and
  #     `Content.Scope.scope_to_workspace_or_global/3` already serves an
  #     unscoped row to every tenant: one row, one identity, a
  #     global-visibility question rather than a substitution.
  #
  # On a healthy install every row is rn = 1 and the backfill is `object_key =
  # path` for all of them — the seal costs nothing where nothing was wrong. A
  # row that CHANGES here is one that was reading another tenant's bytes.
  #
  # NULLABLE, not `null: false`. A `COPY` that bypasses `MediaFile.changeset/2`
  # (the workspace bundle importer) leaves NULL, and `ObjectKey.for_row/1`
  # falls back to `path` — today's exact behaviour. That importer already
  # REFUSES (PR #12873) to copy a row whose path another workspace owns, so it
  # cannot create the contested shape the column exists for.

  def up do
    alter table(:media_files) do
      add :object_key, :string
    end

    # `flush/0` so the column exists before the backfill statement runs.
    flush()

    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (PARTITION BY path ORDER BY inserted_at ASC, id ASC) AS rn
        FROM media_files
    )
    UPDATE media_files m
       SET object_key =
             CASE
               WHEN m.dataset_id IS NULL OR r.rn = 1 THEN m.path
               ELSE 'd/' || m.dataset_id::text || '/' || m.path
             END
      FROM ranked r
     WHERE r.id = m.id
    """)
  end

  def down do
    alter table(:media_files) do
      remove :object_key
    end
  end
end
