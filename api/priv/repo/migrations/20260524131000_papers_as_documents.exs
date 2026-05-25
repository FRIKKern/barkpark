defmodule Barkpark.Repo.Migrations.PapersAsDocuments do
  use Ecto.Migration

  @moduledoc """
  Convergence: papers become first-class `documents` (type "paper").

  This migration:

    1. Migrates every row in the dedicated `papers` table into a `documents`
       row of type "paper". `doc_id` = the slug; the block list / HTML cache /
       provenance move into the `content` map; the monotonic streaming rev
       lands at `content["rev"]`.
    2. Seeds the `paper` schema definition so the Studio desk picks papers up
       like any other content type. Idempotent on `(name, dataset)`.
    3. Drops the now-empty `papers` table.

  Demo data is disposable; the migration just must not crash on it. It is
  written with raw SQL against whatever columns the `papers` table happens to
  have (Wave 3 vs Wave 4 shape) so it survives a partially-migrated dev DB.
  """

  def up do
    flush()

    if papers_table_exists?() do
      migrate_papers_to_documents()
    end

    seed_paper_schemas()

    # Drop the dedicated table — papers now live in `documents`.
    execute("DROP TABLE IF EXISTS papers")
  end

  def down do
    # Recreate the dedicated papers table (Wave 4 shape) and copy rows back.
    create_if_not_exists table(:papers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :text, null: false
      add :dataset, :text, null: false, default: "paperflow"
      add :source_doc, :text
      add :goal_id, :text
      add :event_type, :text
      add :body_html, :text, null: false, default: ""
      add :blocks, :jsonb, null: true
      add :rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:papers, [:dataset, :slug])

    flush()

    repo().query!(
      """
      INSERT INTO papers (id, slug, dataset, source_doc, goal_id, event_type, body_html, blocks, rev, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        doc_id,
        dataset,
        content->>'source_doc',
        content->>'goal_id',
        content->>'event_type',
        COALESCE(content->>'body_html', ''),
        content->'blocks',
        COALESCE((content->>'rev')::int, 0),
        inserted_at,
        updated_at
      FROM documents
      WHERE type = 'paper'
      ON CONFLICT (dataset, slug) DO NOTHING
      """,
      []
    )

    repo().query!("DELETE FROM documents WHERE type = 'paper'", [])

    repo().query!(
      "DELETE FROM schema_definitions WHERE name = 'paper'",
      []
    )
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp papers_table_exists? do
    %{rows: [[exists]]} =
      repo().query!(
        "SELECT to_regclass('public.papers') IS NOT NULL",
        []
      )

    exists
  end

  defp migrate_papers_to_documents do
    columns = papers_columns()

    has_blocks = "blocks" in columns
    rev_is_integer = column_type("papers", "rev") in ["integer", "bigint"]

    rev_sql =
      cond do
        not ("rev" in columns) -> "1"
        rev_is_integer -> "GREATEST(COALESCE(rev, 0), 1)"
        # Wave 3 string rev — not monotonic; reset to 1 on migration.
        true -> "1"
      end

    blocks_select = if has_blocks, do: "blocks", else: "NULL::jsonb"

    # Build the content JSON map from the papers row. body_html always present;
    # blocks/source_doc/goal_id/event_type included only when non-null;
    # rev is the integer streaming rev.
    repo().query!(
      """
      INSERT INTO documents (id, doc_id, type, dataset, title, status, content, rev, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        p.slug,
        'paper',
        p.dataset,
        COALESCE(
          (
            SELECT b->>'text'
            FROM jsonb_array_elements(COALESCE(p.blocks_val, '[]'::jsonb)) AS b
            WHERE b->>'type' = 'heading' AND COALESCE(b->>'text', '') <> ''
            LIMIT 1
          ),
          p.slug
        ),
        'published',
        (
          jsonb_strip_nulls(
            jsonb_build_object(
              'body_html', COALESCE(p.body_html, ''),
              'blocks', p.blocks_val,
              'source_doc', p.source_doc_val,
              'goal_id', p.goal_id_val,
              'event_type', p.event_type_val
            )
          )
          || jsonb_build_object('rev', p.rev_val)
        ),
        md5(random()::text || clock_timestamp()::text),
        p.inserted_at,
        p.updated_at
      FROM (
        SELECT
          slug,
          dataset,
          body_html,
          #{blocks_select} AS blocks_val,
          #{nullable_col(columns, "source_doc")} AS source_doc_val,
          #{nullable_col(columns, "goal_id")} AS goal_id_val,
          #{nullable_col(columns, "event_type")} AS event_type_val,
          (#{rev_sql}) AS rev_val,
          inserted_at,
          updated_at
        FROM papers
      ) p
      ON CONFLICT (doc_id, type, dataset) DO NOTHING
      """,
      []
    )
  end

  defp nullable_col(columns, name) do
    if name in columns, do: name, else: "NULL::text"
  end

  defp papers_columns do
    %{rows: rows} =
      repo().query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'papers'
        """,
        []
      )

    Enum.map(rows, fn [c] -> c end)
  end

  defp column_type(table, column) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    case rows do
      [[t]] -> t
      _ -> nil
    end
  end

  # Seed the `paper` schema for every dataset that has papers, plus the default
  # paperflow dataset, so the Studio desk renders a "Papers" node. Idempotent on
  # (name, dataset).
  #
  # Raw SQL, NOT Content.upsert_schema/2: that app code SELECTs the CURRENT
  # SchemaDefinition struct, which includes columns (layout, prefill,
  # workspace_id, project_id) added by LATER migrations. On a from-zero migrate
  # those columns do not exist yet, so calling app code here crashes with
  # undefined_column. We touch ONLY the schema_definitions columns that exist at
  # this migration's point in history (id, name, title, icon, visibility,
  # fields, dataset, timestamps); every other column is NOT NULL-with-default or
  # nullable, so omitting it is safe. `fields` is jsonb[] — we unfold a JSON
  # array via the chained $1::text::jsonb cast (the documented Postgrex
  # jsonb-array workaround). ON CONFLICT (name, dataset) DO NOTHING keeps it
  # re-run safe.
  defp seed_paper_schemas do
    fields_json = Jason.encode!(paper_fields())

    Enum.each(paper_datasets(), fn dataset ->
      repo().query!(
        """
        INSERT INTO schema_definitions
          (id, name, title, icon, visibility, fields, dataset, inserted_at, updated_at)
        VALUES (
          gen_random_uuid(),
          'paper',
          'Papers',
          $1,
          'public',
          ARRAY(SELECT jsonb_array_elements($2::text::jsonb))::jsonb[],
          $3,
          now(),
          now()
        )
        ON CONFLICT (name, dataset) DO NOTHING
        """,
        [paper_icon(), fields_json, dataset]
      )
    end)
  end

  defp paper_datasets do
    %{rows: rows} =
      repo().query!(
        "SELECT DISTINCT dataset FROM documents WHERE type = 'paper'",
        []
      )

    found = Enum.map(rows, fn [d] -> d end)
    Enum.uniq(["paperflow" | found])
  end

  defp paper_icon, do: "📰"

  # Minimal fields — papers are rendered via PaperLive, not the Studio form
  # editor, so the field set is intentionally tiny (just enough for the desk).
  defp paper_fields do
    [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "event_type", "title" => "Event Type", "type" => "string"},
      %{"name" => "source_doc", "title" => "Source Doc", "type" => "string"},
      %{"name" => "goal_id", "title" => "Goal", "type" => "string"}
    ]
  end
end
