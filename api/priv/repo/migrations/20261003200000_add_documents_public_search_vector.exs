defmodule Barkpark.Repo.Migrations.AddDocumentsPublicSearchVector do
  use Ecto.Migration

  # Owner ruling #20 (2026-10-03, task-3c68de39a19285c4): the search index for
  # callers who may not read private fields holds public fields only.
  #
  # `search_vector` (20260614220000) folds EVERY content string in, so a
  # non-admin search for a word that occurs only in a `private` /
  # `owner_only` / `readable_by` field still matched, and the hit count told the
  # caller what the hidden field contains.
  #
  # `public_search_vector` is the same expression (same weights, same configs)
  # computed over the content AFTER the schema's restricted fields are removed —
  # the SQL twin of `Content.Envelope`'s anonymous redaction walk (top-level
  # fields, declared `fields` kids, `of` item shapes, and `_bpenc` ciphertext
  # under a declared parent). It is NULL when removing those fields changes
  # nothing, which is every document whose type declares no restricted field —
  # so the column costs nothing outside the types that need it, and the search
  # read path reads `coalesce(public_search_vector, search_vector)`.
  #
  # A BEFORE trigger keeps it current on every document write. A second trigger
  # on `schema_definitions` recomputes a type's documents when the schema's
  # field declarations change, so making a field private takes effect for
  # documents already stored. The backfill at the end of `up` covers documents
  # written before this migration; it touches only documents of types whose
  # schema mentions a restriction (none ship by default). The re-runnable check
  # is `mix barkpark.search.reindex_public` (dry run by default).
  def up do
    execute("ALTER TABLE documents ADD COLUMN IF NOT EXISTS public_search_vector tsvector")

    # Is this field declaration restricted for a non-admin, non-owner reader?
    # Mirrors Envelope.field_visible?/3 with no allowlist match and no owner:
    # `private` true, `visibility` private/owner_only, or a non-empty
    # `readable_by` allowlist.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_field_restricted(f jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS $$
      SELECT jsonb_typeof(f) = 'object' AND (
        coalesce(f->>'private', '') = 'true'
        OR coalesce(f->>'visibility', '') IN ('private', 'owner_only')
        OR (jsonb_typeof(f->'readable_by') = 'array' AND jsonb_array_length(f->'readable_by') > 0)
      )
    $$
    """)

    # The item shape of an array field: `of` as a map, or the union of every
    # member's `fields` when `of` is a list (Envelope.item_field/1). NULL when
    # the field declares no item shape.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_item_field(f jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
      SELECT CASE
        WHEN jsonb_typeof(f->'of') = 'object' THEN f->'of'
        WHEN jsonb_typeof(f->'of') = 'array' THEN (
          SELECT CASE WHEN count(*) = 0 THEN NULL ELSE jsonb_build_object('fields', jsonb_agg(k)) END
          FROM jsonb_array_elements(f->'of') m,
               LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m->'fields') = 'array' THEN m->'fields' ELSE '[]'::jsonb END) k
        )
        ELSE NULL
      END
    $$
    """)

    # Remove from `val` every value the declaration `field` marks restricted,
    # walking only the DECLARED shape (Envelope.redact_nested/5). A kid declared
    # twice (two array member shapes) is removed when ANY declaration restricts
    # it — the conservative reading Envelope takes by sorting restricted first.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_redact(val jsonb, field jsonb, depth int)
    RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE
      kids jsonb;
      item jsonb;
      out jsonb := '{}'::jsonb;
      k text;
      v jsonb;
      kid jsonb;
    BEGIN
      IF val IS NULL OR field IS NULL OR depth > 32 THEN
        RETURN val;
      END IF;

      IF jsonb_typeof(val) = 'object' THEN
        kids := CASE WHEN jsonb_typeof(field->'fields') = 'array' THEN field->'fields' ELSE NULL END;
        IF kids IS NULL OR jsonb_array_length(kids) = 0 THEN
          RETURN val;
        END IF;

        FOR k, v IN SELECT * FROM jsonb_each(val) LOOP
          SELECT d INTO kid
          FROM jsonb_array_elements(kids) d
          WHERE d->>'name' = k
          ORDER BY bp_search_field_restricted(d) DESC
          LIMIT 1;

          IF jsonb_typeof(v) = 'object' AND v ? '_bpenc' THEN
            CONTINUE;
          ELSIF kid IS NOT NULL AND bp_search_field_restricted(kid) THEN
            CONTINUE;
          ELSE
            out := out || jsonb_build_object(k, bp_search_redact(v, kid, depth + 1));
          END IF;
        END LOOP;

        RETURN out;
      ELSIF jsonb_typeof(val) = 'array' THEN
        item := bp_search_item_field(field);
        IF item IS NULL THEN
          RETURN val;
        END IF;

        RETURN coalesce(
          (SELECT jsonb_agg(bp_search_redact(e, item, depth + 1) ORDER BY ord)
           FROM jsonb_array_elements(val) WITH ORDINALITY AS t(e, ord)),
          '[]'::jsonb
        );
      ELSE
        RETURN val;
      END IF;
    END
    $$
    """)

    # The search_vector expression (20260614220000) over a given content.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_vector_of(title text, content jsonb) RETURNS tsvector
    LANGUAGE sql IMMUTABLE AS $$
      SELECT
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(content->>'author', '')), 'B') ||
        setweight(to_tsvector('english', coalesce(content->>'category', '')), 'B') ||
        setweight(to_tsvector('simple', coalesce(content->>'slug', '')), 'C') ||
        setweight(jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]'), 'D')
    $$
    """)

    # The public vector of one document: NULL when no schema in its scope
    # restricts anything this document carries. Schema rows considered: the
    # document's own dataset, plus shared (workspace-less) and legacy
    # (dataset_id-less) rows of the same dataset name. Considering more rows
    # than the reader's resolver does only removes more, never less.
    execute("""
    CREATE OR REPLACE FUNCTION bp_public_search_vector(
      p_type text, p_dataset text, p_dataset_id uuid, p_title text, p_content jsonb
    ) RETURNS tsvector LANGUAGE plpgsql STABLE AS $$
    DECLARE
      redacted jsonb := coalesce(p_content, '{}'::jsonb);
      s record;
    BEGIN
      FOR s IN
        SELECT to_jsonb(sd.fields) AS fields
        FROM schema_definitions sd
        WHERE sd.name = p_type
          AND (
            (p_dataset_id IS NOT NULL AND sd.dataset_id = p_dataset_id)
            OR (sd.workspace_id IS NULL AND sd.dataset = p_dataset)
            OR (sd.dataset_id IS NULL AND sd.dataset = p_dataset)
          )
          AND to_jsonb(sd.fields)::text ~ '"(private|visibility|readable_by)"'
      LOOP
        redacted := bp_search_redact(redacted, jsonb_build_object('fields', s.fields), 0);
      END LOOP;

      IF redacted = coalesce(p_content, '{}'::jsonb) THEN
        RETURN NULL;
      END IF;

      RETURN bp_search_vector_of(p_title, redacted);
    END
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION bp_documents_public_search_vector_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.public_search_vector :=
        bp_public_search_vector(NEW.type, NEW.dataset, NEW.dataset_id, NEW.title, NEW.content);
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER documents_public_search_vector
    BEFORE INSERT OR UPDATE OF content, title, type, dataset, dataset_id ON documents
    FOR EACH ROW EXECUTE FUNCTION bp_documents_public_search_vector_trg()
    """)

    # A schema whose field declarations change recomputes its documents. Only
    # when the old or new declarations mention a restriction — a schema that
    # never declared one has no public vector to keep current.
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

    # Backfill: only documents of types some schema row declares a restriction
    # on. The set is empty on a box whose schemas declare no private field.
    execute("""
    UPDATE documents d
    SET public_search_vector =
      bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
    WHERE d.type IN (
      SELECT DISTINCT sd.name FROM schema_definitions sd
      WHERE to_jsonb(sd.fields)::text ~ '"(private|visibility|readable_by)"'
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS documents_public_search_vector_idx
    ON documents USING GIN (public_search_vector)
    WHERE public_search_vector IS NOT NULL
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS schema_definitions_public_search_reindex ON schema_definitions"
    )

    execute("DROP TRIGGER IF EXISTS documents_public_search_vector ON documents")
    execute("DROP FUNCTION IF EXISTS bp_schema_public_search_reindex_trg()")
    execute("DROP FUNCTION IF EXISTS bp_documents_public_search_vector_trg()")
    execute("DROP FUNCTION IF EXISTS bp_public_search_vector(text, text, uuid, text, jsonb)")
    execute("DROP FUNCTION IF EXISTS bp_search_vector_of(text, jsonb)")
    execute("DROP FUNCTION IF EXISTS bp_search_redact(jsonb, jsonb, int)")
    execute("DROP FUNCTION IF EXISTS bp_search_item_field(jsonb)")
    execute("DROP FUNCTION IF EXISTS bp_search_field_restricted(jsonb)")
    execute("DROP INDEX IF EXISTS documents_public_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS public_search_vector")
  end
end
