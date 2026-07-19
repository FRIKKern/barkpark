defmodule Barkpark.Repo.Migrations.PreserveRevisionHistoryOnDocumentDelete do
  use Ecto.Migration

  @moduledoc """
  Repairs databases that applied `20260719010000` before the revision-to-document
  foreign key changed from cascading deletes to nullification.

  Revisions are immutable historical evidence. Removing a draft or published
  document twin may clear the live binding, but must not delete its snapshots.
  """

  def up do
    execute("""
    ALTER TABLE revisions
      DROP CONSTRAINT IF EXISTS revisions_document_id_fkey
    """)

    execute("""
    ALTER TABLE revisions
      ADD CONSTRAINT revisions_document_id_fkey
      FOREIGN KEY (document_id) REFERENCES documents(id)
      ON DELETE SET NULL
    """)

    execute(revision_nullification_function())
  end

  def down do
    execute("""
    ALTER TABLE revisions
      DROP CONSTRAINT IF EXISTS revisions_document_id_fkey
    """)

    execute("""
    ALTER TABLE revisions
      ADD CONSTRAINT revisions_document_id_fkey
      FOREIGN KEY (document_id) REFERENCES documents(id)
      ON DELETE CASCADE
    """)

    execute(revision_cascade_function())
  end

  defp revision_nullification_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_revision_immutable() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND pg_trigger_depth() > 1 AND
         OLD.document_id IS NOT NULL AND NEW.document_id IS NULL AND
         to_jsonb(NEW) - 'document_id' = to_jsonb(OLD) - 'document_id' AND
         NOT EXISTS (SELECT 1 FROM documents WHERE id = OLD.document_id) THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'revision history is append-only';
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp revision_cascade_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_revision_immutable() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'revision history is append-only';
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
