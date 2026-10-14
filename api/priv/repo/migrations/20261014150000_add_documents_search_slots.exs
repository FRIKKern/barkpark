defmodule Barkpark.Repo.Migrations.AddDocumentsSearchSlots do
  use Ecto.Migration

  @moduledoc """
  The weighted title and author slots of the search vector, filled from the
  schema (task-3c6d02392d430c98).

  The search vector weighted the `title` column 'A' and `content.author` 'B'.
  A type with no `title` field (the gyldendal.no `productSearch` type keeps the
  book name in `displayName` and the authors in `Authors`) left the 'A' slot
  empty, so every match came from the 'D' bucket of all strings, and the
  retriever's title arms (the fold, the trigram typo match, the substring and
  prefix match) never fired.

  Two columns, kept by a BEFORE trigger on every document write:

    * `search_title` — the search title when it is not the `title` column: the
      value of the field the schema marks `"search": "title"`, else, when the
      `title` column is blank, the `list_preview.title` field, else the first
      declared field among `name`, `displayName`, `label`, `heading`,
      `headline` that holds a value. NULL when the `title` column is the
      search title.
    * `search_author` — the values of the fields marked `"search": "author"`,
      else of the declared fields named `Author`/`Authors`/`authors` (any case
      except `author`, which the vector already reads as `content.author`).
      A name that two fields repeat (`Author` and `Authors`) is kept once.

  The retriever reads the effective title as
  `coalesce(search_title, nullif(title, ''))`. Two generated columns hold its
  Norwegian fold (`search_label_fold`) and the folded search names, title and
  author slots together (`search_names`), so neither the match nor the ranking
  folds a string per row. Trigram indexes cover the effective title, both
  folded columns and the slug, so the substring, prefix and typo arms are index
  scans.

  `search_vector` is regenerated from `bp_search_vector_of/4`, which adds the
  two slots and a folded `simple` copy of the title and author words (prefix
  and æ/ø/å matching on names). One ALTER adds it with the two folded columns,
  so `documents` is rewritten once, as 20260614220000 did. A schema write recomputes the slots of its type's
  documents (only the rows whose slots change). A bundle import runs with
  user triggers disabled, so `WorkspaceBundle` calls
  `bp_refresh_search_slots(workspace_id)` after it commits.
  """

  def up do
    # `bp_fold` is nine nested string replacements. At the default cost of 1
    # the planner preferred evaluating it on every row of a type over the
    # trigram index that holds its result.
    execute("ALTER FUNCTION bp_fold(text) COST 50")

    execute("ALTER TABLE documents ADD COLUMN IF NOT EXISTS search_title text")
    execute("ALTER TABLE documents ADD COLUMN IF NOT EXISTS search_author text")

    # The searchable text of one content value: a string or a number as is, an
    # array as its string and number elements joined by spaces. NULL otherwise.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_text(v jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT CASE jsonb_typeof(v)
        WHEN 'string' THEN nullif(btrim(v #>> '{}'), '')
        WHEN 'number' THEN v #>> '{}'
        WHEN 'array' THEN nullif(btrim((
          SELECT string_agg(e #>> '{}', ' ' ORDER BY o)
          FROM jsonb_array_elements(v) WITH ORDINALITY AS t(e, o)
          WHERE jsonb_typeof(e) IN ('string', 'number')
        )), '')
        ELSE NULL
      END
    $$
    """)

    # The values of several content fields as one text: each string or number,
    # and each string or number element of an array, once, in field order.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_join(content jsonb, names text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT nullif(string_agg(e, ' ' ORDER BY o1, o2), '')
      FROM (
        SELECT DISTINCT ON (e) e, o1, o2
        FROM (
          SELECT btrim(el #>> '{}') AS e, n.o1, y.o2
          FROM unnest(names) WITH ORDINALITY AS n(name, o1),
               LATERAL jsonb_array_elements(
                 CASE jsonb_typeof(content -> n.name)
                   WHEN 'array' THEN content -> n.name
                   WHEN 'string' THEN jsonb_build_array(content -> n.name)
                   WHEN 'number' THEN jsonb_build_array(content -> n.name)
                   ELSE '[]'::jsonb
                 END
               ) WITH ORDINALITY AS y(el, o2)
          WHERE jsonb_typeof(el) IN ('string', 'number')
        ) items
        WHERE e <> ''
        ORDER BY e, o1, o2
      ) distinct_items
    $$
    """)

    # {search_title, search_author} of one document. See the moduledoc for the
    # order of the rules. The schema row is the one the document's dataset
    # resolves to: its dataset_id first, then a workspace row, then a shared row.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_slots(
      p_type text, p_dataset text, p_dataset_id uuid, p_workspace_id uuid,
      p_title text, p_content jsonb
    ) RETURNS text[] LANGUAGE plpgsql STABLE AS $$
    DECLARE
      s record;
      fields jsonb;
      t text;
      a text;
      pf text;
    BEGIN
      IF p_content IS NULL OR jsonb_typeof(p_content) <> 'object' THEN
        RETURN ARRAY[NULL, NULL]::text[];
      END IF;

      SELECT to_jsonb(sd.fields) AS fields, sd.list_preview AS preview INTO s
      FROM schema_definitions sd
      WHERE sd.name = p_type
        AND (
          (p_dataset_id IS NOT NULL AND sd.dataset_id = p_dataset_id)
          OR (sd.dataset_id IS NULL AND sd.dataset = p_dataset
              AND (sd.workspace_id IS NULL OR sd.workspace_id = p_workspace_id))
        )
      ORDER BY (p_dataset_id IS NOT NULL AND sd.dataset_id = p_dataset_id) DESC,
               (sd.workspace_id IS NOT NULL) DESC
      LIMIT 1;

      IF NOT FOUND THEN
        RETURN ARRAY[NULL, NULL]::text[];
      END IF;

      fields := CASE WHEN jsonb_typeof(s.fields) = 'array' THEN s.fields ELSE '[]'::jsonb END;

      SELECT bp_search_text(p_content -> (f->>'name')) INTO t
      FROM jsonb_array_elements(fields) WITH ORDINALITY AS x(f, o)
      WHERE f->>'search' = 'title' AND bp_search_text(p_content -> (f->>'name')) IS NOT NULL
      ORDER BY o
      LIMIT 1;

      IF t IS NULL AND nullif(btrim(coalesce(p_title, '')), '') IS NULL THEN
        pf := CASE
          WHEN jsonb_typeof(s.preview -> 'title') = 'string' THEN s.preview ->> 'title'
          WHEN jsonb_typeof(s.preview -> 'title') = 'object' THEN s.preview -> 'title' ->> 'field'
          ELSE NULL
        END;

        IF pf IS NOT NULL THEN
          t := bp_search_text(p_content -> pf);
        END IF;

        IF t IS NULL THEN
          SELECT bp_search_text(p_content -> (f->>'name')) INTO t
          FROM jsonb_array_elements(fields) AS x(f)
          WHERE f->>'name' IN ('name', 'displayName', 'label', 'heading', 'headline')
            AND bp_search_text(p_content -> (f->>'name')) IS NOT NULL
          ORDER BY array_position(
            ARRAY['name', 'displayName', 'label', 'heading', 'headline'], f->>'name')
          LIMIT 1;
        END IF;
      END IF;

      a := bp_search_join(p_content, ARRAY(
        SELECT f->>'name'
        FROM jsonb_array_elements(fields) WITH ORDINALITY AS x(f, o)
        WHERE f->>'search' = 'author'
        ORDER BY o
      ));

      IF a IS NULL AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(fields) f WHERE f->>'search' = 'author'
      ) THEN
        a := bp_search_join(p_content, ARRAY(
          SELECT f->>'name'
          FROM jsonb_array_elements(fields) WITH ORDINALITY AS x(f, o)
          WHERE lower(f->>'name') IN ('author', 'authors') AND f->>'name' <> 'author'
          ORDER BY o
        ));
      END IF;

      RETURN ARRAY[t, a];
    END
    $$
    """)

    # The search vector of one document. `search_vector` is generated from it,
    # and the public vector calls it over the redacted content.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_vector_of(
      title text, search_title text, search_author text, content jsonb
    ) RETURNS tsvector LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT
        setweight(to_tsvector('english', coalesce(search_title, nullif(title, ''), '')), 'A') ||
        setweight(to_tsvector('simple', bp_fold(coalesce(search_title, nullif(title, ''), ''))), 'A') ||
        setweight(to_tsvector('english', coalesce(content->>'author', '')), 'B') ||
        setweight(to_tsvector('english', coalesce(search_author, '')), 'B') ||
        setweight(to_tsvector('simple', bp_fold(
          coalesce(content->>'author', '') || ' ' || coalesce(search_author, ''))), 'B') ||
        setweight(to_tsvector('english', coalesce(content->>'category', '')), 'B') ||
        setweight(to_tsvector('simple', coalesce(content->>'slug', '')), 'C') ||
        setweight(jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]'), 'D')
    $$
    """)

    # The two-argument form keeps its old meaning (no slots) for any caller
    # written against 20261003200000.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_vector_of(title text, content jsonb) RETURNS tsvector
    LANGUAGE sql IMMUTABLE AS $$
      SELECT bp_search_vector_of(title, NULL, NULL, content)
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION bp_public_search_vector(
      p_type text, p_dataset text, p_dataset_id uuid, p_title text, p_content jsonb
    ) RETURNS tsvector LANGUAGE plpgsql STABLE AS $$
    DECLARE
      redacted jsonb := coalesce(p_content, '{}'::jsonb);
      s record;
      slots text[];
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

      slots := bp_search_slots(p_type, p_dataset, p_dataset_id, NULL, p_title, redacted);
      RETURN bp_search_vector_of(p_title, slots[1], slots[2], redacted);
    END
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION bp_documents_search_slots_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      slots text[];
    BEGIN
      slots := bp_search_slots(NEW.type, NEW.dataset, NEW.dataset_id, NEW.workspace_id,
                               NEW.title, NEW.content);
      NEW.search_title := slots[1];
      NEW.search_author := slots[2];
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER documents_search_slots
    BEFORE INSERT OR UPDATE OF content, title, type, dataset, dataset_id, workspace_id ON documents
    FOR EACH ROW EXECUTE FUNCTION bp_documents_search_slots_trg()
    """)

    # A schema whose fields or list preview change recomputes the slots of its
    # type's documents. Only rows whose slots differ are written.
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
      SET search_title = x.slots[1], search_author = x.slots[2]
      FROM (
        SELECT d2.id,
               bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                               d2.title, d2.content) AS slots
        FROM documents d2
        WHERE d2.type = NEW.name
          AND (
            (NEW.dataset_id IS NOT NULL AND d2.dataset_id = NEW.dataset_id)
            OR (NEW.dataset_id IS NULL AND d2.dataset = NEW.dataset)
          )
      ) x
      WHERE d.id = x.id
        AND (d.search_title IS DISTINCT FROM x.slots[1]
             OR d.search_author IS DISTINCT FROM x.slots[2]);

      RETURN NEW;
    END
    $$
    """)

    # Recompute the slots of one workspace's documents (NULL = every
    # workspace), writing only the rows whose slots differ. A bundle import
    # calls it after its COPY, which ran with user triggers disabled.
    execute("""
    CREATE OR REPLACE FUNCTION bp_refresh_search_slots(p_workspace_id uuid) RETURNS bigint
    LANGUAGE plpgsql AS $$
    DECLARE
      n bigint;
    BEGIN
      UPDATE documents d
      SET search_title = x.slots[1], search_author = x.slots[2]
      FROM (
        SELECT d2.id,
               bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                               d2.title, d2.content) AS slots
        FROM documents d2
        WHERE p_workspace_id IS NULL OR d2.workspace_id = p_workspace_id
      ) x
      WHERE d.id = x.id
        AND (d.search_title IS DISTINCT FROM x.slots[1]
             OR d.search_author IS DISTINCT FROM x.slots[2]);
      GET DIAGNOSTICS n = ROW_COUNT;
      RETURN n;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER schema_definitions_search_slots
    AFTER INSERT OR UPDATE ON schema_definitions
    FOR EACH ROW EXECUTE FUNCTION bp_schema_search_slots_trg()
    """)

    # Backfill before the vector is regenerated, so the rewrite reads them.
    # Only types that have a schema can get a slot.
    execute("""
    UPDATE documents d
    SET search_title = x.slots[1], search_author = x.slots[2]
    FROM (
      SELECT d2.id,
             bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                             d2.title, d2.content) AS slots
      FROM documents d2
      WHERE d2.type IN (SELECT DISTINCT name FROM schema_definitions)
    ) x
    WHERE d.id = x.id AND (x.slots[1] IS NOT NULL OR x.slots[2] IS NOT NULL)
    """)

    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    # One ALTER, so the table is rewritten once for all three columns.
    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      bp_search_vector_of(title, search_title, search_author, content)
    ) STORED,
    ADD COLUMN search_label_fold text
    GENERATED ALWAYS AS (
      bp_fold(coalesce(search_title, nullif(title, ''), ''))
    ) STORED,
    ADD COLUMN search_names text
    GENERATED ALWAYS AS (
      bp_fold(coalesce(search_title, nullif(title, ''), '') || ' ' ||
        coalesce(search_author, '') || ' ' || coalesce(content->>'author', ''))
    ) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")

    # The retriever's title arms read the effective title. The expressions here
    # and in DocumentsRetriever must stay identical for the planner to use them.
    execute("""
    CREATE INDEX IF NOT EXISTS documents_search_label_trgm_idx ON documents
    USING GIN ((coalesce(search_title, nullif(title, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS documents_search_label_fold_trgm_idx ON documents
    USING GIN (search_label_fold gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS documents_search_names_trgm_idx ON documents
    USING GIN (search_names gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS documents_slug_text_trgm_idx ON documents
    USING GIN (slug_text gin_trgm_ops)
    """)

    # The public vector carries the slots too.
    execute("""
    UPDATE documents d
    SET public_search_vector =
      bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
    WHERE d.public_search_vector IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS documents_slug_text_trgm_idx")
    execute("DROP INDEX IF EXISTS documents_search_names_trgm_idx")
    execute("DROP INDEX IF EXISTS documents_search_label_fold_trgm_idx")
    execute("DROP INDEX IF EXISTS documents_search_label_trgm_idx")
    execute("DROP TRIGGER IF EXISTS schema_definitions_search_slots ON schema_definitions")
    execute("DROP FUNCTION IF EXISTS bp_schema_search_slots_trg()")
    execute("DROP FUNCTION IF EXISTS bp_refresh_search_slots(uuid)")
    execute("DROP TRIGGER IF EXISTS documents_search_slots ON documents")
    execute("DROP FUNCTION IF EXISTS bp_documents_search_slots_trg()")

    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_names")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_label_fold")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(content->>'author', '')), 'B') ||
      setweight(to_tsvector('english', coalesce(content->>'category', '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(content->>'slug', '')), 'C') ||
      setweight(
        jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]'),
        'D'
      )
    ) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")

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

    execute("DROP FUNCTION IF EXISTS bp_search_vector_of(text, text, text, jsonb)")
    execute("DROP FUNCTION IF EXISTS bp_search_slots(text, text, uuid, uuid, text, jsonb)")
    execute("ALTER FUNCTION bp_fold(text) COST 1")
    execute("DROP FUNCTION IF EXISTS bp_search_join(jsonb, text[])")
    execute("DROP FUNCTION IF EXISTS bp_search_text(jsonb)")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_author")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_title")
  end
end
