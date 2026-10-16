defmodule Barkpark.Repo.Migrations.SearchRefreshOutsideSchemaWrite do
  use Ecto.Migration

  @moduledoc """
  A schema write no longer recomputes the search data of every document of its
  type inside the write (task-9d83c3e0c3b8fabf).

  Two AFTER triggers on `schema_definitions` recomputed a type's documents in
  the schema write itself: `schema_definitions_search_slots` (migration
  20261014150000) whenever `fields` or `list_preview` differed at all, and
  `schema_definitions_public_search_reindex` (migration 20261003200000)
  whenever `fields` differed and mentioned a restriction. On the gyldendal-no
  workspace a product schema write ran `bp_search_slots` for 18,022 documents
  and answered 500 after the 15 s request timeout, although the change touched
  nothing the slots read.

  ## What a change must recompute

  One trigger, `schema_definitions_search_refresh`, replaces both. It compares
  the old and the new row on what the derived data reads:

    * the slot signature (`bp_search_slots_signature/2`): the name and the
      `search` value of every field that `bp_search_slots` can read (a
      `search: title | author` field, a field named `name`, `displayName`,
      `label`, `heading`, `headline`, `Author` or `Authors` in any case), in
      field order, and the `list_preview.title` field;
    * the restriction signature (`bp_search_restriction_signature/2`): the
      declared tree `bp_search_redact` walks (each field's name, whether it is
      restricted, its `fields` kids and its `of` item shape), compared only
      when the old or the new fields mention a restriction, as before.

  A write that changes neither (descriptions, validation, `required`, the
  `list_preview` subtitle, a new plain field) recomputes nothing. The public
  vector holds the slots of the redacted content, so a changed slot signature
  recomputes it too on a type that mentions a restriction. An insert, a
  rename or a move to another dataset recomputes both, for the new and the
  old scope.

  ## Inline when small, in batches when large

  `bp_search_refresh_request` counts the documents in scope, up to
  `barkpark.search_refresh_inline_max` (a setting, default 1,000). A scope of
  that size or smaller is recomputed in the write, as before. A larger one is
  recorded in `search_refresh_pending`, which
  `Barkpark.Search.Workers.SearchRefresh` drains in batches of 500 documents,
  each batch its own statement, outside the request.

  ## Privacy while a refresh is pending

  A pending row whose change made a field restricted (the restriction
  signature changed and the new fields mention a restriction) carries
  `gate = true`. While it exists, `DocumentsRetriever` leaves every document
  in its scope out of a text search for any caller that is not an admin. A
  stale public vector of such a document could still hold a word the new
  schema hides, so the document is not searched at all until the batch that
  recomputes it has run and the row is gone. The pending row is written in the
  same transaction as the schema row, so no reader sees the new schema without
  the gate.

  The worker deletes the row only after the last batch, and after one more
  pass over the scope's documents written since five minutes before the
  schema write. A document write whose statement started before the schema
  write committed computed its public vector from the old schema; if it wrote
  the row after the batch that covered it, that pass recomputes it. A batch
  skips a row that changed after the batch read it, and the same pass picks
  it up.

  A change that only removes restrictions, or only changes the slots, gets no
  gate: a stale public vector then hides more words than the new schema does,
  never fewer, and the slots are computed from the content the vector already
  holds.

  ## Built online

  `search_refresh_pending` is a new, empty table. Its columns are named
  `scope_dataset` and `scope_dataset_id`, not `dataset` and `dataset_id`: it
  is a work queue like `oban_jobs`, not workspace content, and a workspace
  bundle classifies every table with a `dataset` column as content. Its unique
  index is built with `CREATE INDEX CONCURRENTLY`, hence the two flags. Replacing the trigger
  takes a short lock on `schema_definitions` only. `documents` is not
  rewritten and gets no new index.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS search_refresh_pending (
      id bigserial PRIMARY KEY,
      type text NOT NULL,
      scope_dataset text NOT NULL,
      scope_dataset_id uuid,
      wide boolean NOT NULL,
      slots boolean NOT NULL DEFAULT false,
      public boolean NOT NULL DEFAULT false,
      gate boolean NOT NULL DEFAULT false,
      gen bigint NOT NULL DEFAULT 1,
      requested_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    drop_invalid_index("search_refresh_pending_scope_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS search_refresh_pending_scope_index
    ON search_refresh_pending (type, scope_dataset, scope_dataset_id, wide) NULLS NOT DISTINCT
    """)

    create_functions()

    execute("DROP TRIGGER IF EXISTS schema_definitions_search_refresh ON schema_definitions")

    execute("""
    CREATE TRIGGER schema_definitions_search_refresh
    AFTER INSERT OR UPDATE ON schema_definitions
    FOR EACH ROW EXECUTE FUNCTION bp_schema_search_refresh_trg()
    """)

    execute("DROP TRIGGER IF EXISTS schema_definitions_search_slots ON schema_definitions")

    execute(
      "DROP TRIGGER IF EXISTS schema_definitions_public_search_reindex ON schema_definitions"
    )

    execute("DROP FUNCTION IF EXISTS bp_schema_search_slots_trg()")
    execute("DROP FUNCTION IF EXISTS bp_schema_public_search_reindex_trg()")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS schema_definitions_search_refresh ON schema_definitions")

    restore_old_triggers()

    execute("DROP FUNCTION IF EXISTS bp_schema_search_refresh_trg()")

    execute(
      "DROP FUNCTION IF EXISTS bp_search_refresh_request(text, text, uuid, boolean, boolean, boolean, boolean)"
    )

    execute(
      "DROP FUNCTION IF EXISTS bp_search_refresh_batch(text, text, uuid, boolean, boolean, boolean, uuid, integer, timestamp)"
    )

    execute("DROP FUNCTION IF EXISTS bp_search_restriction_signature(jsonb, integer)")
    execute("DROP FUNCTION IF EXISTS bp_search_slots_signature(jsonb, jsonb)")
    execute("DROP INDEX CONCURRENTLY IF EXISTS search_refresh_pending_scope_index")
    execute("DROP TABLE IF EXISTS search_refresh_pending")
  end

  defp drop_invalid_index(name) do
    %{rows: invalid} =
      repo().query!(
        """
        SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = $1 AND NOT i.indisvalid
        """,
        [name]
      )

    if invalid != [], do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
  end

  defp create_functions do
    # What bp_search_slots reads from a schema row. Two rows with the same
    # signature give every document the same slots.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_slots_signature(p_fields jsonb, p_preview jsonb)
    RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT jsonb_build_array(
        (SELECT coalesce(jsonb_agg(jsonb_build_array(f->>'name', f->>'search') ORDER BY o), '[]'::jsonb)
         FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(p_fields) = 'array' THEN p_fields ELSE '[]'::jsonb END
         ) WITH ORDINALITY AS x(f, o)
         WHERE f->>'search' IN ('title', 'author')
            OR f->>'name' IN ('name', 'displayName', 'label', 'heading', 'headline')
            OR lower(f->>'name') IN ('author', 'authors')),
        CASE
          WHEN jsonb_typeof(p_preview -> 'title') = 'string' THEN p_preview ->> 'title'
          WHEN jsonb_typeof(p_preview -> 'title') = 'object' THEN p_preview -> 'title' ->> 'field'
          ELSE NULL
        END
      )
    $$
    """)

    # What bp_search_redact reads from a field declaration: its name, whether
    # it is restricted, its declared kids and its item shape, to the same
    # depth. Two declarations with the same signature redact every content the
    # same way.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_restriction_signature(f jsonb, depth int)
    RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE
      kids jsonb;
    BEGIN
      IF f IS NULL OR jsonb_typeof(f) <> 'object' OR depth > 32 THEN
        RETURN NULL;
      END IF;

      IF jsonb_typeof(f->'fields') = 'array' THEN
        SELECT jsonb_agg(coalesce(bp_search_restriction_signature(k, depth + 1), 'null'::jsonb) ORDER BY o)
        INTO kids
        FROM jsonb_array_elements(f->'fields') WITH ORDINALITY AS t(k, o);
      END IF;

      RETURN jsonb_build_object(
        'n', f->'name',
        'r', bp_search_field_restricted(f),
        'k', kids,
        'i', bp_search_restriction_signature(bp_search_item_field(f), depth + 1)
      );
    END
    $$
    """)

    # Recompute the slots and/or the public vector of the documents of one
    # scope, in id order after p_after, at most p_limit of them (NULL = all),
    # only those written at or after p_since when it is set.
    # Only rows whose values change are written, so only those are locked. A
    # row that another write changed after this statement read it is skipped:
    # that write's BEFORE triggers already computed its values. Returns the
    # last id the batch read (NULL when it read none) and the number of rows
    # written.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_refresh_batch(
      p_type text, p_dataset text, p_dataset_id uuid, p_wide boolean,
      p_slots boolean, p_public boolean, p_after uuid, p_limit int,
      p_since timestamp DEFAULT NULL
    ) RETURNS TABLE(last_id uuid, written bigint) LANGUAGE plpgsql AS $$
    BEGIN
      RETURN QUERY
      WITH batch AS (
        SELECT d.id FROM documents d
        WHERE d.type = p_type
          AND ((p_dataset_id IS NOT NULL AND d.dataset_id = p_dataset_id)
               OR (p_wide AND d.dataset = p_dataset))
          AND (p_after IS NULL OR d.id > p_after)
          AND (p_since IS NULL OR d.updated_at >= p_since)
        ORDER BY d.id
        LIMIT p_limit
      ), x AS MATERIALIZED (
        SELECT d.id, d.type, d.dataset, d.dataset_id, d.workspace_id, d.title, d.content,
               d.search_title, d.search_author, d.public_search_vector,
          CASE WHEN p_slots THEN
            bp_search_slots(d.type, d.dataset, d.dataset_id, d.workspace_id, d.title, d.content)
          END AS slots,
          CASE WHEN p_public THEN
            bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
          END AS pub
        FROM documents d
        WHERE d.id IN (SELECT b.id FROM batch b)
      ), upd AS (
        UPDATE documents d
        SET search_title = CASE WHEN p_slots THEN x.slots[1] ELSE d.search_title END,
            search_author = CASE WHEN p_slots THEN x.slots[2] ELSE d.search_author END,
            search_title_fold = CASE WHEN p_slots THEN f.title_fold ELSE d.search_title_fold END,
            search_names_fold = CASE WHEN p_slots THEN f.names_fold ELSE d.search_names_fold END,
            search_names_tsv = CASE WHEN p_slots THEN f.names_tsv ELSE d.search_names_tsv END,
            public_search_vector = CASE WHEN p_public THEN x.pub ELSE d.public_search_vector END
        FROM x
        CROSS JOIN LATERAL bp_search_folds(x.slots[1], x.title, x.slots[2]) f
        WHERE d.id = x.id
          -- A row another write changed since this statement read it keeps
          -- the values that write's own trigger computed.
          AND d.title IS NOT DISTINCT FROM x.title
          AND d.content IS NOT DISTINCT FROM x.content
          AND d.type = x.type
          AND d.dataset_id IS NOT DISTINCT FROM x.dataset_id
          AND ((p_slots AND (x.search_title IS DISTINCT FROM x.slots[1]
                             OR x.search_author IS DISTINCT FROM x.slots[2]))
               OR (p_public AND x.public_search_vector IS DISTINCT FROM x.pub))
        RETURNING 1
      )
      SELECT (SELECT max(b.id::text)::uuid FROM batch b), (SELECT count(*) FROM upd);
    END
    $$
    """)

    # One scope needs its slots and/or public vector recomputed. A scope of
    # at most `barkpark.search_refresh_inline_max` documents is recomputed
    # now; a larger one is recorded for the refresh worker. `p_gate` marks a
    # change that made a field restricted: see the moduledoc.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_refresh_request(
      p_type text, p_dataset text, p_dataset_id uuid, p_wide boolean,
      p_slots boolean, p_public boolean, p_gate boolean
    ) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      inline_max int := coalesce(
        nullif(current_setting('barkpark.search_refresh_inline_max', true), '')::int, 1000);
      n int;
    BEGIN
      IF NOT p_slots AND NOT p_public THEN
        RETURN;
      END IF;

      SELECT count(*) INTO n FROM (
        SELECT 1 FROM documents d
        WHERE d.type = p_type
          AND ((p_dataset_id IS NOT NULL AND d.dataset_id = p_dataset_id)
               OR (p_wide AND d.dataset = p_dataset))
        LIMIT inline_max + 1
      ) s;

      IF n <= inline_max THEN
        PERFORM bp_search_refresh_batch(p_type, p_dataset, p_dataset_id, p_wide,
                                        p_slots, p_public, NULL, NULL);
        RETURN;
      END IF;

      INSERT INTO search_refresh_pending AS p
        (type, scope_dataset, scope_dataset_id, wide, slots, public, gate)
      VALUES (p_type, p_dataset, p_dataset_id, p_wide, p_slots, p_public, p_gate)
      ON CONFLICT (type, scope_dataset, scope_dataset_id, wide) DO UPDATE
      SET slots = p.slots OR EXCLUDED.slots,
          public = p.public OR EXCLUDED.public,
          gate = p.gate OR EXCLUDED.gate,
          gen = p.gen + 1,
          requested_at = now() AT TIME ZONE 'utc',
          updated_at = now();
    END
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION bp_schema_search_refresh_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      old_r boolean := TG_OP = 'UPDATE'
        AND to_jsonb(OLD.fields)::text ~ '"(private|visibility|readable_by)"';
      new_r boolean := to_jsonb(NEW.fields)::text ~ '"(private|visibility|readable_by)"';
      moved boolean := TG_OP = 'UPDATE' AND (
        OLD.name IS DISTINCT FROM NEW.name
        OR OLD.dataset IS DISTINCT FROM NEW.dataset
        OR OLD.dataset_id IS DISTINCT FROM NEW.dataset_id
        OR OLD.workspace_id IS DISTINCT FROM NEW.workspace_id);
      slots_changed boolean;
      restriction_changed boolean;
    BEGIN
      IF TG_OP = 'UPDATE' AND NOT moved THEN
        slots_changed :=
          bp_search_slots_signature(to_jsonb(OLD.fields), OLD.list_preview)
          IS DISTINCT FROM bp_search_slots_signature(to_jsonb(NEW.fields), NEW.list_preview);
        restriction_changed := (old_r OR new_r) AND
          bp_search_restriction_signature(jsonb_build_object('fields', to_jsonb(OLD.fields)), 0)
          IS DISTINCT FROM
          bp_search_restriction_signature(jsonb_build_object('fields', to_jsonb(NEW.fields)), 0);
      ELSE
        slots_changed := true;
        restriction_changed := old_r OR new_r;
      END IF;

      PERFORM bp_search_refresh_request(
        NEW.name, NEW.dataset, NEW.dataset_id,
        NEW.workspace_id IS NULL OR NEW.dataset_id IS NULL,
        slots_changed,
        restriction_changed OR (slots_changed AND (old_r OR new_r)),
        restriction_changed AND new_r);

      -- The documents the row no longer covers lose its rules. Their stale
      -- public vector then hides more, never less, so they need no gate.
      IF moved THEN
        PERFORM bp_search_refresh_request(
          OLD.name, OLD.dataset, OLD.dataset_id,
          OLD.workspace_id IS NULL OR OLD.dataset_id IS NULL,
          true, old_r, false);
      END IF;

      RETURN NEW;
    END
    $$
    """)
  end

  # The two triggers of migrations 20261003200000 and 20261014150000, as they
  # were.
  defp restore_old_triggers do
    execute("""
    CREATE OR REPLACE FUNCTION bp_schema_public_search_reindex_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      old_r boolean := TG_OP = 'UPDATE' AND to_jsonb(OLD.fields)::text ~ '"(private|visibility|readable_by)"';
      new_r boolean := to_jsonb(NEW.fields)::text ~ '"(private|visibility|readable_by)"';
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.fields IS NOT DISTINCT FROM NEW.fields
         AND OLD.name = NEW.name AND OLD.dataset_id IS NOT DISTINCT FROM NEW.dataset_id THEN
        RETURN NEW;
      END IF;

      IF old_r OR new_r THEN
        UPDATE documents d
        SET public_search_vector =
          bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
        WHERE d.type = NEW.name
          AND (
            (NEW.dataset_id IS NOT NULL AND d.dataset_id = NEW.dataset_id)
            OR ((NEW.workspace_id IS NULL OR NEW.dataset_id IS NULL) AND d.dataset = NEW.dataset)
          );
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER schema_definitions_public_search_reindex
    AFTER INSERT OR UPDATE ON schema_definitions
    FOR EACH ROW EXECUTE FUNCTION bp_schema_public_search_reindex_trg()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION bp_schema_search_slots_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.fields IS NOT DISTINCT FROM NEW.fields
         AND OLD.list_preview IS NOT DISTINCT FROM NEW.list_preview
         AND OLD.name = NEW.name AND OLD.dataset_id IS NOT DISTINCT FROM NEW.dataset_id THEN
        RETURN NEW;
      END IF;

      UPDATE documents d
      SET search_title = x.slots[1], search_author = x.slots[2],
          search_title_fold = f.title_fold, search_names_fold = f.names_fold,
          search_names_tsv = f.names_tsv
      FROM (
        SELECT d2.id, d2.title,
               bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                               d2.title, d2.content) AS slots
        FROM documents d2
        WHERE d2.type = NEW.name
          AND (
            (NEW.dataset_id IS NOT NULL AND d2.dataset_id = NEW.dataset_id)
            OR (NEW.dataset_id IS NULL AND d2.dataset = NEW.dataset)
          )
      ) x
      CROSS JOIN LATERAL bp_search_folds(x.slots[1], x.title, x.slots[2]) f
      WHERE d.id = x.id
        AND (d.search_title IS DISTINCT FROM x.slots[1]
             OR d.search_author IS DISTINCT FROM x.slots[2]);

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER schema_definitions_search_slots
    AFTER INSERT OR UPDATE ON schema_definitions
    FOR EACH ROW EXECUTE FUNCTION bp_schema_search_slots_trg()
    """)
  end
end
