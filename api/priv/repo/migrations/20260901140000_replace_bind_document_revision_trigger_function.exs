defmodule Barkpark.Repo.Migrations.ReplaceBindDocumentRevisionTriggerFunction do
  use Ecto.Migration

  @moduledoc """
  Repairs databases that ran `20260719010000` before that migration's own file
  was edited in place.

  `20260719010000_add_cycle_correction_quarantine_promotion.exs` shipped on
  2026-07-19 and was then AMENDED SEVEN MORE TIMES — `a0357fff38`, `5a7aa8616a`,
  `223c1264da`, `fbd25ff938`, `d3b7cb1789` (all the same day) and `d6c6f94af9`
  (a 2026-07-30 formatter pass). Its `barkpark_bind_document_revision()` trigger
  function started as an exact-equality predicate (`document.doc_id =
  NEW.doc_id`, `document.dataset_id = NEW.dataset_id`) and only the last version
  carries the `drafts.`-prefix normalization plus the `IS NOT DISTINCT FROM`
  arms.

  Migrations never re-run. A database that applied `20260719010000` from a
  mid-window checkout keeps the EARLY function body forever while
  `mix ecto.migrations` reports zero pending — that check reads a version row in
  `schema_migrations`, never the object the migration claims to have produced.
  Every draft-document `save_revision` on such a box then raises
  `P0001 revision snapshot does not exactly match its document`.

  `git pull` ships the corrected FILE and repairs nothing. THIS is the repair:
  a forward migration that re-states the final body with CREATE OR REPLACE.

  Idempotent by construction — CREATE OR REPLACE over a function that already
  holds this body is a no-op, so it is safe on the boxes the 2026-09-01 fleet
  census found already CORRECTED (all 7 that carry the function). Boxes still
  behind `20260719010000` run that migration first (version order), get the
  corrected body from it, and this one confirms it.

  The function body below is a VERBATIM copy of the final text in
  `20260719010000`. It is duplicated on purpose: a migration is a historical
  record, so the repair must carry its own text rather than reach into another
  migration's private helper.
  """

  def up do
    execute(bind_document_revision_function())
  end

  # Deliberately irreversible-as-a-no-op: the only thing `down` could restore is
  # the broken early body, and re-installing a known-defective trigger is not a
  # rollback anyone wants. `20260719010000.down` still drops the function.
  def down do
    :ok
  end

  defp bind_document_revision_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_bind_document_revision() RETURNS trigger AS $$
    BEGIN
      IF NEW.document_id IS NULL THEN
        RETURN NEW;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM documents document
        WHERE document.id = NEW.document_id AND
          NEW.doc_id = CASE
            WHEN left(document.doc_id, 7) = 'drafts.' THEN substr(document.doc_id, 8)
            ELSE document.doc_id
          END AND
          document.type = NEW.type AND
          document.dataset IS NOT DISTINCT FROM NEW.dataset AND
          document.dataset_id IS NOT DISTINCT FROM NEW.dataset_id AND
          document.workspace_id IS NOT DISTINCT FROM NEW.workspace_id AND
          document.project_id IS NOT DISTINCT FROM NEW.project_id AND
          document.title IS NOT DISTINCT FROM NEW.title AND
          document.status IS NOT DISTINCT FROM NEW.status AND
          document.content IS NOT DISTINCT FROM NEW.content
      ) THEN
        RAISE EXCEPTION 'revision snapshot does not exactly match its document';
      END IF;
      UPDATE documents SET current_revision_id = NEW.id,
        released_revision_id = CASE
          WHEN NEW.action = 'publish' AND NEW.status = 'published' THEN NEW.id
          ELSE released_revision_id END
      WHERE id = NEW.document_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
