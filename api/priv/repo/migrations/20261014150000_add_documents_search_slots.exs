defmodule Barkpark.Repo.Migrations.AddDocumentsSearchSlots do
  use Ecto.Migration

  require Logger

  @moduledoc """
  The weighted title and author slots of the search, filled from the schema
  (task-3c6d02392d430c98).

  The search vector weighted the `title` column 'A' and `content.author` 'B'.
  A type with no `title` field (the gyldendal.no `productSearch` type keeps the
  book name in `displayName` and the authors in `Authors`) left the 'A' slot
  empty, so every match came from the 'D' bucket of all strings, and the
  retriever's title arms (the fold, the trigram typo match, the substring and
  prefix match) never fired.

  ## Nullable columns, kept by a trigger

  A BEFORE trigger on every document write fills:

    * `search_title`: the search title when it is not the `title` column: the
      value of the field the schema marks `"search": "title"`, else, when the
      `title` column is blank, the `list_preview.title` field, else the first
      declared field among `name`, `displayName`, `label`, `heading`,
      `headline` that holds a value. NULL when the `title` column is the
      search title.
    * `search_author`: the values of the fields marked `"search": "author"`,
      else of the declared fields named `Author`/`Authors`/`authors` (any case
      except `author`), then the `content.author` string. A name that two
      fields repeat (`Author` and `Authors`) is kept once. NULL when there is
      none.
    * `search_title_fold`, `search_names_fold` and `search_names_tsv`, from
      `bp_search_folds/3`: the search title folded, the search title and the
      author slot folded in one text, and the names vector (the search title
      in English and folded in `simple`, weighted 'A', the author slot in
      English and folded, weighted 'B'). All three are NULL when both slots are.

  Every column is added with no default, so the ALTER changes the catalog only
  and does not rewrite `documents`. A row with a `title` column and no author
  has no slot and keeps NULL in all five.

  ## Expressions over the stored values and the title

  `search_vector` stays the generated column it was. The retriever reads three
  expressions, each the stored value of a row with a slot, else the same value
  computed from the `title` column:

    * `bp_search_label_fold(search_title_fold, title)`, the folded search title;
    * `bp_search_names(search_names_fold, title)`, the folded search names;
    * `bp_search_names_vector(search_names_tsv, title)`, the names vector.

  A row with a slot is never folded at query time, and a row without one folds
  only its title, as `main` did. The retriever matches a word when either
  `search_vector` or the names vector holds it, and ranks on
  `bp_search_names_vector(...) || search_vector`. For a document whose title
  is a slot that concatenation is byte for byte the vector a regenerated
  `search_vector` would hold, so ranking is unchanged. None of the three reads
  `content`.

  Trigram GIN indexes cover the search title, the two folded expressions and
  the slug, and a GIN index covers the names vector. The expressions in
  `DocumentsRetriever` must stay identical to the index expressions for the
  planner to use them.

  ## Built online

  Every index is built with `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, which
  takes no `ACCESS EXCLUSIVE` lock and cannot run in a transaction, hence the
  two flags. An index left INVALID by an earlier failed build is dropped and
  built again. The slots of existing rows are filled in batches of 1,000
  rows, each its own statement, before the indexes are built, so a
  batch writes no entry into them. Only rows whose type has a schema or whose
  content has an `author` are written.

  Measured on a copy of the gyldendal-no workspace (47,361 documents,
  `documents` 375 MiB with indexes and TOAST): see the PR for the numbers and
  how they scale.

  A schema write recomputes the slots of its type's documents (only the rows
  whose slots change). A bundle import runs with user triggers disabled, so
  `WorkspaceBundle` calls `bp_refresh_search_slots(workspace_id)` after it
  commits. The public vector (the content with restricted fields removed) is
  recomputed with the slots for the rows that have one.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch 1_000
  @vacuum_every 5_000

  # name => "USING ..." clause. The expressions here and in DocumentsRetriever
  # must stay identical.
  @indexes [
    {"documents_search_names_vector_idx",
     "USING GIN (bp_search_names_vector(search_names_tsv, title))"},
    {"documents_search_label_trgm_idx",
     "USING GIN ((coalesce(search_title, nullif(title, ''))) gin_trgm_ops)"},
    {"documents_search_label_fold_trgm_idx",
     "USING GIN (bp_search_label_fold(search_title_fold, title) gin_trgm_ops)"},
    {"documents_search_names_trgm_idx",
     "USING GIN (bp_search_names(search_names_fold, title) gin_trgm_ops)"},
    {"documents_slug_text_trgm_idx", "USING GIN (slug_text gin_trgm_ops)"}
  ]

  def up do
    # `bp_fold` is nine nested string replacements. At the default cost of 1
    # the planner preferred evaluating it on every row of a type over the
    # trigram index that holds its result.
    execute("ALTER FUNCTION bp_fold(text) COST 50")

    # Nullable, no default: a catalog change, no table rewrite.
    execute("""
    ALTER TABLE documents
      ADD COLUMN IF NOT EXISTS search_title text,
      ADD COLUMN IF NOT EXISTS search_author text,
      ADD COLUMN IF NOT EXISTS search_title_fold text,
      ADD COLUMN IF NOT EXISTS search_names_fold text,
      ADD COLUMN IF NOT EXISTS search_names_tsv tsvector
    """)

    create_functions()
    create_triggers()
    backfill_slots()
    build_indexes()
    backfill_public_vectors()
  end

  def down do
    for {name, _using} <- Enum.reverse(@indexes) do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end

    execute("DROP TRIGGER IF EXISTS schema_definitions_search_slots ON schema_definitions")
    execute("DROP FUNCTION IF EXISTS bp_schema_search_slots_trg()")
    execute("DROP FUNCTION IF EXISTS bp_refresh_search_slots(uuid)")
    execute("DROP TRIGGER IF EXISTS documents_search_slots ON documents")
    execute("DROP FUNCTION IF EXISTS bp_documents_search_slots_trg()")

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

    backfill_public_vectors()

    execute("DROP FUNCTION IF EXISTS bp_search_vector_of(text, text, text, jsonb)")
    execute("DROP FUNCTION IF EXISTS bp_search_folds(text, text, text)")
    execute("DROP FUNCTION IF EXISTS bp_search_names(text, text)")
    execute("DROP FUNCTION IF EXISTS bp_search_label_fold(text, text)")
    execute("DROP FUNCTION IF EXISTS bp_search_names_vector(tsvector, text)")
    execute("DROP FUNCTION IF EXISTS bp_search_names_vector_of(text, text, text)")
    execute("DROP FUNCTION IF EXISTS bp_search_slots(text, text, uuid, uuid, text, jsonb)")
    execute("ALTER FUNCTION bp_fold(text) COST 1")
    execute("DROP FUNCTION IF EXISTS bp_search_join(jsonb, text[])")
    execute("DROP FUNCTION IF EXISTS bp_search_text(jsonb)")

    execute("""
    ALTER TABLE documents
      DROP COLUMN IF EXISTS search_names_tsv,
      DROP COLUMN IF EXISTS search_names_fold,
      DROP COLUMN IF EXISTS search_title_fold,
      DROP COLUMN IF EXISTS search_author,
      DROP COLUMN IF EXISTS search_title
    """)
  end

  defp create_functions do
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
      ca text;
      pf text;
    BEGIN
      IF p_content IS NULL OR jsonb_typeof(p_content) <> 'object' THEN
        RETURN ARRAY[NULL, NULL]::text[];
      END IF;

      ca := bp_search_text(p_content -> 'author');

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
        RETURN ARRAY[NULL, ca]::text[];
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

      RETURN ARRAY[t, nullif(concat_ws(' ', a, ca), '')];
    END
    $$
    """)

    # The names part of the search vector: the search title and the author
    # slot, in English and folded. Reads no content.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_names_vector_of(
      title text, search_title text, search_author text
    ) RETURNS tsvector LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT
        setweight(to_tsvector('english', coalesce(search_title, '')), 'A') ||
        setweight(to_tsvector('simple', bp_fold(coalesce(search_title, nullif(title, ''), ''))), 'A') ||
        setweight(to_tsvector('english', coalesce(search_author, '')), 'B') ||
        setweight(to_tsvector('simple', bp_fold(coalesce(search_author, ''))), 'B')
    $$
    """)

    # The stored values of a row with a slot. All NULL when it has none: the
    # three expressions below then compute the same values from the title.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_folds(
      search_title text, title text, search_author text
    ) RETURNS TABLE(title_fold text, names_fold text, names_tsv tsvector)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT
        bp_fold(coalesce(search_title, nullif(title, ''), '')),
        bp_fold(coalesce(search_title, nullif(title, ''), '') || ' ' ||
                coalesce(search_author, '')),
        bp_search_names_vector_of(title, search_title, search_author)
      WHERE search_title IS NOT NULL OR search_author IS NOT NULL
      UNION ALL
      SELECT NULL, NULL, NULL
      WHERE search_title IS NULL AND search_author IS NULL
    $$
    """)

    # The search title folded.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_label_fold(stored text, title text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT coalesce(stored, bp_fold(coalesce(nullif(title, ''), '')))
    $$
    """)

    # The search title and the author slot, folded, in one text.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_names(stored text, title text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT coalesce(stored, bp_fold(coalesce(nullif(title, ''), '')))
    $$
    """)

    # The names vector. Without a slot it is the folded title, weighted 'A',
    # which is what bp_search_names_vector_of(title, NULL, NULL) gives.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_names_vector(stored tsvector, title text)
    RETURNS tsvector LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT coalesce(stored,
        setweight(to_tsvector('simple', bp_fold(coalesce(nullif(title, ''), ''))), 'A'))
    $$
    """)

    # The whole search vector of one document with its slots: what the
    # retriever ranks on, `bp_search_names_vector(...) || search_vector`. The
    # public vector is built from it.
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_vector_of(
      title text, search_title text, search_author text, content jsonb
    ) RETURNS tsvector LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT bp_search_names_vector_of(title, search_title, search_author) ||
             bp_search_vector_of(title, content)
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
      f record;
    BEGIN
      slots := bp_search_slots(NEW.type, NEW.dataset, NEW.dataset_id, NEW.workspace_id,
                               NEW.title, NEW.content);
      SELECT * INTO f FROM bp_search_folds(slots[1], NEW.title, slots[2]);
      NEW.search_title := slots[1];
      NEW.search_author := slots[2];
      NEW.search_title_fold := f.title_fold;
      NEW.search_names_fold := f.names_fold;
      NEW.search_names_tsv := f.names_tsv;
      RETURN NEW;
    END
    $$
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
      SET search_title = x.slots[1], search_author = x.slots[2],
          search_title_fold = f.title_fold, search_names_fold = f.names_fold,
          search_names_tsv = f.names_tsv
      FROM (
        SELECT d2.id, d2.title,
               bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                               d2.title, d2.content) AS slots
        FROM documents d2
        WHERE p_workspace_id IS NULL OR d2.workspace_id = p_workspace_id
      ) x
      CROSS JOIN LATERAL bp_search_folds(x.slots[1], x.title, x.slots[2]) f
      WHERE d.id = x.id
        AND (d.search_title IS DISTINCT FROM x.slots[1]
             OR d.search_author IS DISTINCT FROM x.slots[2]);
      GET DIAGNOSTICS n = ROW_COUNT;
      RETURN n;
    END
    $$
    """)
  end

  defp create_triggers do
    execute("DROP TRIGGER IF EXISTS documents_search_slots ON documents")

    execute("""
    CREATE TRIGGER documents_search_slots
    BEFORE INSERT OR UPDATE OF content, title, type, dataset, dataset_id, workspace_id ON documents
    FOR EACH ROW EXECUTE FUNCTION bp_documents_search_slots_trg()
    """)

    execute("DROP TRIGGER IF EXISTS schema_definitions_search_slots ON schema_definitions")

    execute("""
    CREATE TRIGGER schema_definitions_search_slots
    AFTER INSERT OR UPDATE ON schema_definitions
    FOR EACH ROW EXECUTE FUNCTION bp_schema_search_slots_trg()
    """)
  end

  # The trigger covers every write from here on. The rows already there are
  # filled in id order, @batch rows per statement, each committed on its own.
  # Only a type with a schema, or a content with an `author`, can get a slot;
  # a row whose slots are already right is not written.
  #
  # A written row is a new row version: the old one stays on disk until a
  # VACUUM, and each new version adds entries to every index of `documents`.
  # After every @vacuum_every written rows the migration runs VACUUM, so the
  # next batches reuse that space and the table grows by at most about
  # @vacuum_every rows' worth.
  defp backfill_slots do
    flush()
    {written, _since_vacuum} = backfill_slots(nil, {0, 0})
    if written > 0, do: vacuum_documents()
    Logger.info("search slots filled on #{written} documents")
  end

  defp backfill_slots(after_id, {written, since_vacuum}) do
    %{rows: [[last_id, n]]} =
      repo().query!(
        """
        WITH batch AS (
          SELECT id FROM documents
          WHERE $1::uuid IS NULL OR id > $1::uuid
          ORDER BY id
          LIMIT $2
        ), upd AS (
          UPDATE documents d
          SET search_title = x.slots[1], search_author = x.slots[2],
          search_title_fold = f.title_fold, search_names_fold = f.names_fold,
          search_names_tsv = f.names_tsv
          FROM (
            SELECT d2.id, d2.title,
                   bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                                   d2.title, d2.content) AS slots
            FROM documents d2
            WHERE d2.id IN (SELECT id FROM batch)
              AND (d2.type IN (SELECT name FROM schema_definitions) OR d2.content ? 'author')
          ) x
          CROSS JOIN LATERAL bp_search_folds(x.slots[1], x.title, x.slots[2]) f
          WHERE d.id = x.id
            AND (d.search_title IS DISTINCT FROM x.slots[1]
                 OR d.search_author IS DISTINCT FROM x.slots[2])
          RETURNING 1
        )
        SELECT (SELECT max(id::text) FROM batch), (SELECT count(*) FROM upd)
        """,
        [after_id && Ecto.UUID.dump!(after_id), @batch],
        timeout: :infinity
      )

    since_vacuum =
      if since_vacuum + n >= @vacuum_every do
        vacuum_documents()
        0
      else
        since_vacuum + n
      end

    if last_id,
      do: backfill_slots(last_id, {written + n, since_vacuum}),
      else: {written + n, since_vacuum}
  end

  defp vacuum_documents,
    do: repo().query!("VACUUM documents", [], timeout: :infinity)

  defp build_indexes do
    for {name, using} <- @indexes do
      %{rows: invalid} =
        repo().query!(
          """
          SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
          WHERE c.relname = $1 AND NOT i.indisvalid
          """,
          [name]
        )

      if invalid != [] do
        repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{name}", [], timeout: :infinity)
      end

      repo().query!(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} ON documents #{using}",
        [],
        timeout: :infinity
      )
    end
  end

  # The public vector carries the slots too. Only rows that hold a restricted
  # field have one, in batches like the slots.
  defp backfill_public_vectors do
    flush()
    backfill_public_vectors(nil)
  end

  defp backfill_public_vectors(after_id) do
    %{rows: [[last_id]]} =
      repo().query!(
        """
        WITH batch AS (
          SELECT id FROM documents
          WHERE public_search_vector IS NOT NULL AND ($1::uuid IS NULL OR id > $1::uuid)
          ORDER BY id
          LIMIT $2
        ), upd AS (
          UPDATE documents d
          SET public_search_vector =
            bp_public_search_vector(d.type, d.dataset, d.dataset_id, d.title, d.content)
          WHERE d.id IN (SELECT id FROM batch)
          RETURNING 1
        )
        SELECT (SELECT max(id::text) FROM batch) FROM (SELECT count(*) FROM upd) u
        """,
        [after_id && Ecto.UUID.dump!(after_id), @batch],
        timeout: :infinity
      )

    if last_id, do: backfill_public_vectors(last_id)
  end
end
