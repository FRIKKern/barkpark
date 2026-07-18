defmodule Barkpark.Repo.Migrations.AddDocumentsTagsMetaGeneratedColumn do
  use Ecto.Migration

  @moduledoc """
  search-latency slice d — ranking ORDER BY (task-9faff63dd9199c7d). Move the
  weighted-tag boost's source array OUT of the giant `content` jsonb and into a
  narrow GENERATED STORED column, so the per-candidate ORDER BY subquery reads a
  KB-sized tags array instead of DETOASTING the whole ~8.5KB–88KB `content` per
  matched row.

  ## Why (measured, guerrilla barkpark_prod 2026-07-18, 2584 rows / 48MB TOAST)

  `order_rank`'s ranking key #2 (`relevance_key`) adds a weighted-tag boost:

      0.1 * max((e->>'strength')::int) over jsonb_array_elements(
        CASE WHEN jsonb_typeof(content->'tags')='array'
             THEN content->'tags' ELSE '[]'::jsonb END) e
        WHERE ... lower(e->>'tag') = ANY($query_terms)

  The `content->'tags'` inside `jsonb_array_elements` forces a per-row DETOAST of
  the out-of-line `content` jsonb for EVERY candidate the ORDER BY scores.
  EXPLAIN (ANALYZE, BUFFERS) over a 200-row recency pool on prod:

      SubPlan (tag boost over content): shared hit=2,126 buffers   (47.0 ms)
      SubPlan (tag boost over tags_meta):            0 buffers      ( 1.6 ms)

  i.e. the boost's content detoast is ~89% of the ranking key's read cost, and it
  disappears when the array is a narrow stored column (proven via a session-local
  TEMP copy carrying this exact generated value — no lock on `documents`).

  ## Behaviour-identical BY CONSTRUCTION

  `tags_meta` is the VERBATIM CASE expression the ORDER BY evaluates today, so
  `jsonb_array_elements(tags_meta)` is byte-identical to
  `jsonb_array_elements(CASE WHEN ... content->'tags' ... END)` for every row —
  the ranking key computes the same value, only cheaper. The stripped
  `jsonb_agg({tag,strength})` shape the slice sketched is NOT expressible as a
  GENERATED column (aggregates/subqueries are disallowed there), so we store the
  full `content->'tags'` array — still KBs, never the ~88KB `content`.

  NOT declared read_after_writes / not a loaded schema field: like `search_vector`
  (also a GENERATED STORED column), `tags_meta` is `virtual: true` in the schema
  and referenced ONLY through an ORDER BY `fragment`. It is never SELECTed into
  `%Document{}` and never shipped, so it adds zero payload bytes and cannot trip
  the struct-equality parity that bit the #4174 scalar columns.

  ## Prod-safety

  `ADD COLUMN ... GENERATED ALWAYS AS (...) STORED` rewrites the whole table
  (Postgres must compute the stored value for every existing row) under an ACCESS
  EXCLUSIVE lock. `documents` is 75MB / ~2.6k rows on prod, so the rewrite
  completes in seconds; acceptable, same shape/risk as the `search_vector`
  (20260527101000) and facet-column (20260718090000) GENERATED migrations.
  instance-deploy.sh runs `ecto.migrate` on the idle slot BEFORE the Caddy flip,
  so this lands automatically on deploy with no manual step.

  Additive + reversible: `down/0` drops the column; `content` is untouched.
  """

  def up do
    execute("""
    ALTER TABLE documents
    ADD COLUMN tags_meta jsonb
    GENERATED ALWAYS AS (
      CASE WHEN jsonb_typeof(content->'tags') = 'array'
           THEN content->'tags'
           ELSE '[]'::jsonb END
    ) STORED
    """)
  end

  def down do
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS tags_meta")
  end
end
