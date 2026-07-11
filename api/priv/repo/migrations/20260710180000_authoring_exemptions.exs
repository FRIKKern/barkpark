defmodule Barkpark.Repo.Migrations.AuthoringExemptions do
  use Ecto.Migration

  @moduledoc """
  The publish wall's legacy exemption ledger (authoring-excellence D6).

  Seeds a deploy-time SNAPSHOT of the already-published corpus: every document
  row that is `status = 'published'` AT THE MOMENT THIS MIGRATION RUNS gets an
  exemption row (the SELECT is the predicate — never a baked literal count, so
  the seed is correct on every instance regardless of corpus size). After the
  seed the table is DELETE-only: `Barkpark.Content.Exemptions.clear/2` removes
  a row when its document passes the label spine, so the exempt count is
  monotone non-increasing (the ratchet).

  PK is (doc_id, dataset) per the charter; `ON CONFLICT DO NOTHING` absorbs the
  legal case of two types sharing a (doc_id, dataset) leaf — one exemption row
  covers the id either way.
  """

  def up do
    create table(:authoring_exemptions, primary_key: false) do
      add :doc_id, :string, null: false, primary_key: true
      add :dataset, :string, null: false, primary_key: true
      add :type, :string, null: false
      add :exempted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute """
    INSERT INTO authoring_exemptions (doc_id, dataset, type, exempted_at)
    SELECT doc_id, dataset, type, now()
    FROM documents
    WHERE status = 'published'
    ON CONFLICT (doc_id, dataset) DO NOTHING
    """
  end

  def down do
    drop table(:authoring_exemptions)
  end
end
