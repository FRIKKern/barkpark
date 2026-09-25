defmodule Barkpark.Tenancy.WorkspaceBundle.DatasetRemapError do
  @moduledoc """
  A dataset remap import (`WorkspaceBundle.import_bundle/2` with `:into_dataset`)
  refused to land the bundle. Nothing was written: every refusal is raised inside
  the import transaction, so the new dataset row and every staged row roll back.

  `code` is a stable, machine-branchable reason:

    * `"invalid_target"` — the target project does not exist, is not in the
      named workspace, or the new slug fails the dataset changeset.
    * `"dataset_slug_conflict"` — the target project already has a dataset with
      the requested slug. The import never merges into an existing dataset.
    * `"not_a_dataset_bundle"` — the bundle was not exported with the `:dataset`
      option, so it has no single source dataset to remap.
    * `"unknown_member_table"` — the bundle carries rows for a table this
      database does not have, so their shape cannot be checked.
    * `"unexpected_dataset"` — a row in a remapped table names a dataset other
      than the bundle's source dataset.
    * `"dangling_reference"` — a remapped row points at a document or revision
      the bundle does not carry, so its rewritten form would point nowhere.
    * `"unhandled_dataset_rows"` — the bundle carries rows that belong to the
      source dataset in a table the remap does not rewrite (media, webhooks,
      search intel, data keys, …). Importing without them would lose data;
      importing them unchanged would point them at the source.
    * `"unremapped_source_id"` — after rewriting, a row about to be inserted
      still contains the id of the source workspace, project, dataset, or of a
      source document or revision. This is the backstop for reference shapes
      the explicit rewrites do not know about.

  `table` names the table the refusal is about (or `nil`), and `details` carries
  counts and a sample for the caller.
  """
  defexception [:code, :table, :message, details: %{}]

  @type t :: %__MODULE__{
          code: String.t(),
          table: String.t() | nil,
          message: String.t(),
          details: map()
        }
end

defmodule Barkpark.Tenancy.WorkspaceBundle.DatasetRemap do
  @moduledoc """
  Import a dataset-scoped bundle under a NEW dataset id and slug in a target
  workspace and project, rewriting every stored pointer to the source dataset.

  Reached through `WorkspaceBundle.import_bundle/2` or `import_bundle_file/2`
  with `into_dataset: [workspace_id: …, project_id: …, slug: …]`. The ordinary
  import restores rows byte for byte under their original ids; this path is the
  opposite: nothing from the bundle keeps its workspace, project, dataset, or
  row id.

  ## What is rewritten, and what is not

  Every member table of a dataset-scoped bundle falls into exactly one class:

  | Class | Tables | What happens |
  |---|---|---|
  | spine | `workspaces`, `projects`, `datasets` | Not imported. The target workspace and project already exist; the new dataset row is created with a fresh id, the target project and the requested slug. |
  | rewritten | `documents`, `revisions`, `content_edges`, `task_edges`, `plugin_doc_state`, `mutation_events`, `schema_definitions`, `authoring_exemptions` | Imported with the rewrites listed below. |
  | guarded | every other member table that has a `dataset_id`, `dataset` or `scope` column, or a foreign key to `documents.id` / `revisions.id` (derived live) | Rows that belong to the source dataset, or point at one of its documents or revisions, REFUSE the import (`unhandled_dataset_rows`). Rows about other datasets of the source workspace are dropped and counted. |
  | not carried | `api_tokens`, `access_grants`, `share_links`, `preview_token_jti`, `paper_access_log` | Not imported and counted. They name the dataset but are the source's credentials, grants and access trail; carrying them into another tenant would give the source's holders access to the new dataset. |
  | workspace-scoped | every remaining member table (tokens, memberships, roles, audit, secrets, chat, cycle and epic ledgers, …) | Not imported and counted: they describe the source workspace, not the dataset, and carry no dataset grain. |

  The rewrites, column by column:

    * `documents` — `id` gets a fresh UUID (recorded in an id map);
      `workspace_id`, `project_id`, `dataset_id`, `dataset` take the target
      values; `current_revision_id` and `released_revision_id` are mapped
      through the revision id map (inserted as NULL, then set once the
      revisions exist, because the two tables reference each other).
    * `revisions` — `id` fresh (id map); `document_id` mapped through the
      document id map; tenancy columns as above.
    * `content_edges`, `task_edges` — `id` fresh; `from_id` and `to_id` mapped.
      An edge whose source document is not in the bundle belongs to another
      dataset and is dropped. An edge from a bundled document to a document
      the bundle does not carry refuses (`dangling_reference`).
    * `plugin_doc_state` — `doc_id` (a `documents.id` FK) mapped; rows for
      documents outside the bundle are dropped.
    * `mutation_events` — `id` is left to the sequence; tenancy columns as
      above.
    * `schema_definitions` — `id` fresh; tenancy columns as above.
    * `authoring_exemptions` — `dataset` takes the new slug.

  Not rewritten, because they do not name the dataset:

    * `doc_id` strings, including the `drafts.` and `versions.<release>.`
      prefixes. They name a document inside a dataset; the dataset is the row's
      `dataset_id`, so the same `doc_id` in the new dataset is the same document.
    * Reference fields inside `content` (`{"_ref": "<doc_id>"}` or a bare
      `doc_id`). They are resolved against the reader's dataset
      (`Content.Expand`, `EdgeProjector`), so they resolve inside the new
      dataset as soon as the referenced `doc_id` exists there.
    * `mutation_events.document` and `revisions.content` snapshots. They carry
      `doc_id`s and content, not row ids.
    * Actor and owner columns (`documents.owner_id`, `revisions.actor_*`). They
      name instance principals, not dataset rows.

  The backstop for everything this list missed: before any insert, every
  rewritten row is serialised with `row_to_json` and scanned for UUIDs; if one
  is the source workspace, project or dataset id, or the old id of a bundled
  document or revision, the import refuses with `unremapped_source_id`, naming
  the table.

  ## Integrity

  Foreign keys stay enforced on the rewritten tables for the whole import, so a
  mapped id that does not exist in the target is a hard failure, not an orphan.
  The one DDL statement is `ALTER TABLE revisions DISABLE TRIGGER USER` around
  the revisions insert: `revisions_bind_document` requires each inserted
  revision to match its document's CURRENT state, which historical revisions do
  not, and `revisions_immutable` is not exercised by an insert. Both are
  re-enabled before commit. The whole import is one transaction.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Dataset, Project}
  alias Barkpark.Tenancy.WorkspaceBundle.DatasetRemapError

  @spine ~w(workspaces projects datasets)

  @rewritten ~w(documents revisions content_edges task_edges plugin_doc_state
                mutation_events schema_definitions authoring_exemptions)

  @tenancy_tables ~w(documents revisions mutation_events schema_definitions)

  # Tables that name the dataset but hold the SOURCE's credentials, grants or
  # access trail. They are never carried into another tenant: a source token,
  # grant or share link landing next to the new dataset would give its source
  # holders access to it. Not refused either, because they are not dataset
  # content — the count is reported in `stats.remap.not_carried`.
  @not_carried %{
    "api_tokens" => "credential of the source workspace",
    "access_grants" => "authorization granted to source principals",
    "share_links" => "share-link credential of the source workspace",
    "preview_token_jti" => "preview-token ledger of the source workspace",
    "paper_access_log" => "access audit trail of the source dataset"
  }

  # Lowercase canonical UUID text, which is what `row_to_json` prints for a uuid
  # column and what every writer in this codebase stores in text/jsonb.
  @uuid_regex "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

  @copy_chunk_bytes 65_536
  @ddl_lock_timeout "2s"

  @typedoc "The validated `:into_dataset` option."
  @type target :: %{workspace_id: String.t(), project_id: String.t(), slug: String.t()}

  @doc "The tables whose rows the remap rewrites and imports."
  @spec rewritten_tables() :: [String.t()]
  def rewritten_tables, do: @rewritten

  @doc "Tables the remap never carries, with the reason."
  @spec not_carried_tables() :: %{String.t() => String.t()}
  def not_carried_tables, do: @not_carried

  @doc "The tables the remap replaces with the target instead of importing."
  @spec spine_tables() :: [String.t()]
  def spine_tables, do: @spine

  @doc """
  Validate the `:into_dataset` import option. Raises `ArgumentError` on a
  malformed shape, before the bundle is read.
  """
  @spec target!(term()) :: target() | nil
  def target!(nil), do: nil

  def target!(opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)

    target =
      for key <- [:workspace_id, :project_id, :slug], into: %{} do
        case Map.get(opts, key) do
          value when is_binary(value) and value != "" ->
            {key, value}

          other ->
            raise ArgumentError,
                  "invalid :into_dataset #{inspect(key)} #{inspect(other)} " <>
                    "(expected a non-empty string)"
        end
      end

    extra = Map.keys(opts) -- [:workspace_id, :project_id, :slug]

    if extra != [] do
      raise ArgumentError, "unknown :into_dataset key(s) #{inspect(extra)}"
    end

    for key <- [:workspace_id, :project_id] do
      if Repo.uuid_or_nil(target[key]) == nil do
        raise ArgumentError, "invalid :into_dataset #{inspect(key)}: not a UUID"
      end
    end

    target
  end

  def target!(other) do
    raise ArgumentError,
          "invalid :into_dataset #{inspect(other)} " <>
            "(expected [workspace_id: uuid, project_id: uuid, slug: string] or nil)"
  end

  @doc """
  Run the remap import. `dumps` maps each member table to its COPY text, as a
  binary or `{:file, path}`. Returns `{:ok, stats}`; every refusal raises
  `DatasetRemapError` after rolling back.
  """
  @spec run(map(), %{optional(String.t()) => binary() | {:file, Path.t()}}, target()) ::
          {:ok, map()}
  def run(manifest, dumps, target) do
    Repo.transaction(fn -> do_run(manifest, dumps, target) end, timeout: :infinity)
  end

  defp do_run(manifest, dumps, target) do
    # A COPY of a large dataset is one long statement; see the same opt-out in
    # WorkspaceBundle.run_import_once/4.
    Repo.set_local_statement_timeout!(0)
    # Empty the deferred-trigger queue so the ALTER TABLE on revisions below is
    # allowed (Postgres refuses ALTER on a table with pending trigger events).
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [])

    assert_dataset_bundle!(manifest)
    project = resolve_target!(target)

    entries = Enum.filter(manifest["tables"] || [], &(&1["row_count"] > 0))
    classes = Map.new(entries, fn e -> {e["name"], classify!(e["name"])} end)

    staged =
      entries
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {entry, i}, acc ->
        table = entry["name"]
        dump = Map.get(dumps, table, "")

        case classes[table] do
          {skip, _} when skip in [:workspace_scoped, :not_carried] ->
            release_member(dump)
            acc

          _ ->
            Map.put(acc, table, stage!(entry, dump, i))
        end
      end)

    source = source!(manifest, staged)
    build_id_maps!(staged)

    dropped = check_guarded!(staged, classes, source)

    check_rewritten!(staged, source)
    dropped = Map.merge(dropped, drop_out_of_dataset!(staged))

    dataset = create_dataset!(project, target.slug, source)

    dest = %{
      workspace_id: project.workspace_id,
      project_id: project.id,
      dataset_id: dataset.id,
      slug: dataset.slug
    }

    rewrite!(staged, dest)
    assert_no_source_ids!(staged, source)
    inserted = insert!(staged)
    drop_temp_tables!(staged)

    carried_rows = Map.new(entries, &{&1["name"], &1["row_count"]})

    skipped =
      for {table, {:workspace_scoped, _}} <- classes, into: %{}, do: {table, carried_rows[table]}

    not_carried =
      for {table, {:not_carried, _}} <- classes, into: %{}, do: {table, carried_rows[table]}

    %{
      tables: inserted,
      total_rows: inserted |> Map.values() |> Enum.sum(),
      manifest: manifest,
      attempts: 1,
      remap: %{
        dataset_id: dataset.id,
        dataset_slug: dataset.slug,
        workspace_id: project.workspace_id,
        project_id: project.id,
        source: %{
          workspace_id: source.workspace_id,
          project_id: source.project_id,
          dataset_id: source.dataset_id,
          dataset_slug: source.slug
        },
        rewritten: inserted,
        dropped_out_of_dataset: dropped,
        skipped_workspace_scoped: skipped,
        not_carried: not_carried
      }
    }
  end

  # ── Preconditions ────────────────────────────────────────────────────────────

  defp assert_dataset_bundle!(manifest) do
    unless is_binary(manifest["dataset"]) and manifest["dataset"] != "" do
      refuse!(
        "not_a_dataset_bundle",
        nil,
        "this bundle was exported for the whole workspace, not for one dataset, so there " <>
          "is no single source dataset to import under a new id. Export it again with the " <>
          "dataset option."
      )
    end
  end

  defp resolve_target!(target) do
    project = Repo.one(from p in Project, where: p.id == ^target.project_id)

    cond do
      project == nil ->
        refuse!("invalid_target", nil, "target project #{target.project_id} does not exist")

      String.downcase(project.workspace_id) != String.downcase(target.workspace_id) ->
        refuse!(
          "invalid_target",
          nil,
          "target project #{target.project_id} belongs to workspace #{project.workspace_id}, " <>
            "not #{target.workspace_id}"
        )

      true ->
        project
    end
  end

  # ── Classification ───────────────────────────────────────────────────────────

  @doc """
  How the remap treats rows of `table`, derived from the live catalog:
  `:spine`, `:rewritten`, `{:guarded, grain_columns, fk_columns}`,
  `{:workspace_scoped, table}`, or `:unknown` for a table this database lacks.
  """
  @spec member_class(String.t()) ::
          :spine
          | :rewritten
          | {:guarded, [String.t()], [{String.t(), String.t()}]}
          | {:workspace_scoped, String.t()}
          | {:not_carried, String.t()}
          | :unknown
  def member_class(table) do
    cond do
      table in @spine ->
        :spine

      table in @rewritten ->
        :rewritten

      Map.has_key?(@not_carried, table) ->
        {:not_carried, Map.fetch!(@not_carried, table)}

      not table_exists?(table) ->
        :unknown

      true ->
        grain = grain_columns(table)
        fks = row_fk_columns(table)

        if grain == [] and fks == [] do
          {:workspace_scoped, table}
        else
          {:guarded, grain, fks}
        end
    end
  end

  defp classify!(table) do
    case member_class(table) do
      :unknown ->
        refuse!(
          "unknown_member_table",
          table,
          "the bundle carries rows for #{table}, which this database does not have, so the " <>
            "import cannot tell whether they belong to the dataset"
        )

      class ->
        class
    end
  end

  # Columns through which a row names a dataset. `dataset_id` is canonical;
  # `dataset` is the slug mirror; `scope` is the search-intel / data-key key
  # (`<slug>` or `dataset:<slug>`).
  defp grain_columns(table) do
    Repo.query!(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1
        AND column_name IN ('dataset_id', 'dataset', 'scope')
      ORDER BY column_name
      """,
      [table]
    ).rows
    |> List.flatten()
  end

  # Columns of `table` that are single-column FKs to `documents.id` or
  # `revisions.id`, derived live — the rows the id maps can speak for.
  defp row_fk_columns(table) do
    Repo.query!(
      """
      SELECT a.attname, pl.relname
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = cl.relnamespace
      JOIN pg_class pl ON pl.oid = c.confrelid
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      JOIN pg_attribute ra ON ra.attrelid = c.confrelid AND ra.attnum = c.confkey[1]
      WHERE c.contype = 'f' AND n.nspname = 'public' AND cl.relname = $1
        AND pl.relname IN ('documents', 'revisions') AND ra.attname = 'id'
        AND array_length(c.conkey, 1) = 1
      ORDER BY a.attname
      """,
      [table]
    ).rows
    |> Enum.map(fn [col, parent] -> {col, parent} end)
  end

  defp table_exists?(table) do
    Repo.query!(
      "SELECT 1 FROM pg_class cl WHERE cl.relname = $1 AND cl.relkind = 'r' " <>
        "AND pg_catalog.pg_table_is_visible(cl.oid)",
      [table]
    ).rows != []
  end

  # ── Staging: every row-carrying member that needs a look lands in a temp table

  # Temp tables are named by position, not by table, so no identifier derived
  # from the manifest is ever part of a temp name.
  # sobelow_skip ["SQL.Query", "SQL.Stream"]
  defp stage!(entry, dump, index) do
    table = entry["name"]
    cols = entry["columns"]
    tmp = "_bp_remap_#{index}"
    col_list = Enum.map_join(cols, ", ", &qi/1)

    Repo.query!(
      "CREATE TEMP TABLE #{qi(tmp)} (LIKE #{qi(table)} INCLUDING DEFAULTS) ON COMMIT DROP",
      []
    )

    stream = Ecto.Adapters.SQL.stream(Repo, "COPY #{qi(tmp)} (#{col_list}) FROM STDIN", [])
    Enum.into(copy_source(dump), stream)
    release_member(dump)

    %{tmp: tmp, cols: cols, rows: entry["row_count"]}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp copy_source({:file, path}), do: File.stream!(path, @copy_chunk_bytes)
  defp copy_source(dump) when is_binary(dump), do: [dump]

  # sobelow_skip ["Traversal.FileModule"]
  defp release_member({:file, path}), do: File.rm(path)
  defp release_member(dump) when is_binary(dump), do: :ok

  # ── The source dataset, read from the rows the bundle carries ────────────────

  # sobelow_skip ["SQL.Query"]
  defp source!(manifest, staged) do
    rows =
      case staged["datasets"] do
        nil ->
          []

        %{tmp: tmp} ->
          Repo.query!("SELECT id::text, project_id::text, slug, name FROM #{qi(tmp)}", []).rows
      end

    expected_slug = manifest["dataset"]

    case rows do
      [[id, project_id, ^expected_slug, name]] ->
        %{
          workspace_id: manifest["workspace_id"],
          project_id: project_id,
          dataset_id: id,
          slug: expected_slug,
          name: name
        }

      _ ->
        refuse!(
          "not_a_dataset_bundle",
          "datasets",
          "a dataset bundle carries exactly one datasets row, the one named in its manifest " <>
            "(#{inspect(manifest["dataset"])}); this one carries #{length(rows)}"
        )
    end
  end

  # ── Id maps ──────────────────────────────────────────────────────────────────

  # One map for every row id the remap re-mints and other rows point at. Built
  # before any rewrite, from the OLD ids, so every lookup below reads old -> new.
  # sobelow_skip ["SQL.Query"]
  defp build_id_maps!(staged) do
    Repo.query!(
      "CREATE TEMP TABLE _bp_remap_ids (kind text NOT NULL, old uuid NOT NULL, " <>
        "new uuid NOT NULL, PRIMARY KEY (kind, old)) ON COMMIT DROP",
      []
    )

    for table <- ~w(documents revisions), staged[table] do
      Repo.query!(
        "INSERT INTO _bp_remap_ids (kind, old, new) " <>
          "SELECT $1, id, gen_random_uuid() FROM #{qi(staged[table].tmp)}",
        [table]
      )
    end

    :ok
  end

  # ── Guarded tables: refuse the source dataset's rows, drop everyone else's ──

  # sobelow_skip ["SQL.Query"]
  defp check_guarded!(staged, classes, source) do
    for {table, {:guarded, grain, fks}} <- classes, into: %{} do
      %{tmp: tmp, rows: rows} = staged[table]
      predicate = guarded_predicate(grain, fks)

      [[owned]] =
        Repo.query!(
          "SELECT count(*) FROM #{qi(tmp)} t " <>
            "WHERE $1::text IS NOT NULL AND $2::text IS NOT NULL AND #{predicate}",
          [source.dataset_id, source.slug]
        ).rows

      if owned > 0 do
        refuse!(
          "unhandled_dataset_rows",
          table,
          "#{owned} row(s) in #{table} belong to the source dataset #{inspect(source.slug)}, " <>
            "and the dataset remap does not rewrite #{table} yet. Importing without them would " <>
            "lose them; importing them unchanged would leave them pointing at the source.",
          %{count: owned}
        )
      end

      {table, rows}
    end
  end

  # $1 = source dataset id, $2 = source slug.
  defp guarded_predicate(grain, fks) do
    grain_terms =
      Enum.flat_map(grain, fn
        "dataset_id" ->
          ["t.dataset_id = $1::text::uuid"]

        "dataset" ->
          if "dataset_id" in grain,
            do: ["(t.dataset_id IS NULL AND t.dataset = $2)"],
            else: ["t.dataset = $2"]

        "scope" ->
          ["t.scope IN ($2, 'dataset:' || $2)"]
      end)

    fk_terms =
      Enum.map(fks, fn {col, parent} ->
        "t.#{qi(col)} IN (SELECT old FROM _bp_remap_ids WHERE kind = '#{parent}')"
      end)

    "(" <> Enum.join(grain_terms ++ fk_terms, " OR ") <> ")"
  end

  # ── Rewritten tables: preconditions on the OLD values ────────────────────────

  # sobelow_skip ["SQL.Query"]
  defp check_rewritten!(staged, source) do
    for table <- @tenancy_tables, staged[table] do
      [[n]] =
        Repo.query!(
          "SELECT count(*) FROM #{qi(staged[table].tmp)} t " <>
            "WHERE t.dataset_id IS DISTINCT FROM $1::text::uuid",
          [source.dataset_id]
        ).rows

      if n > 0 do
        refuse!(
          "unexpected_dataset",
          table,
          "#{n} row(s) in #{table} name a dataset other than the source dataset " <>
            "#{inspect(source.slug)} (#{source.dataset_id})",
          %{count: n}
        )
      end
    end

    if staged["revisions"] do
      assert_mapped!(staged, "revisions", "document_id", "documents")
    end

    if staged["documents"] do
      assert_mapped!(staged, "documents", "current_revision_id", "revisions")
      assert_mapped!(staged, "documents", "released_revision_id", "revisions")
    end

    :ok
  end

  # sobelow_skip ["SQL.Query"]
  defp assert_mapped!(staged, table, col, kind) do
    %{rows: rows} =
      Repo.query!(
        "SELECT t.#{qi(col)}::text, count(*) OVER () FROM #{qi(staged[table].tmp)} t " <>
          "WHERE t.#{qi(col)} IS NOT NULL AND NOT EXISTS " <>
          "(SELECT 1 FROM _bp_remap_ids m WHERE m.kind = $1 AND m.old = t.#{qi(col)}) LIMIT 5",
        [kind]
      )

    case rows do
      [] ->
        :ok

      [[_, total] | _] ->
        refuse!(
          "dangling_reference",
          table,
          "#{total} row(s) in #{table}.#{col} point at a #{kind} row the bundle does not " <>
            "carry: #{Enum.map_join(rows, ", ", &hd/1)}",
          %{count: total, sample: Enum.map(rows, &hd/1)}
        )
    end
  end

  # Edges and plugin state are exported workspace-whole even in a dataset
  # bundle (they have no dataset column). A row whose SOURCE document is not in
  # the bundle is another dataset's and is dropped; an edge from a bundled
  # document to one the bundle does not carry is a real dangling reference.
  # sobelow_skip ["SQL.Query"]
  defp drop_out_of_dataset!(staged) do
    owned = "IN (SELECT old FROM _bp_remap_ids WHERE kind = 'documents')"

    edges =
      for table <- ~w(content_edges task_edges), staged[table], into: %{} do
        tmp = qi(staged[table].tmp)

        %{num_rows: dropped} =
          Repo.query!(
            "DELETE FROM #{tmp} t WHERE t.from_id IS NULL OR NOT t.from_id #{owned}",
            []
          )

        %{rows: rows} =
          Repo.query!(
            "SELECT t.to_id::text, count(*) OVER () FROM #{tmp} t " <>
              "WHERE t.to_id IS NULL OR NOT t.to_id #{owned} LIMIT 5",
            []
          )

        case rows do
          [] ->
            {table, dropped}

          [[_, total] | _] ->
            refuse!(
              "dangling_reference",
              table,
              "#{total} #{table} row(s) lead from a document in the dataset to a document " <>
                "outside it (to_id #{Enum.map_join(rows, ", ", &inspect(hd(&1)))}); the " <>
                "rewritten edge would have nothing to point at",
              %{count: total, sample: Enum.map(rows, &hd/1)}
            )
        end
      end

    state =
      if staged["plugin_doc_state"] do
        %{num_rows: dropped} =
          Repo.query!(
            "DELETE FROM #{qi(staged["plugin_doc_state"].tmp)} t " <>
              "WHERE t.doc_id IS NULL OR NOT t.doc_id #{owned}",
            []
          )

        %{"plugin_doc_state" => dropped}
      else
        %{}
      end

    Map.merge(edges, state)
  end

  # ── The new dataset row ──────────────────────────────────────────────────────

  defp create_dataset!(%Project{} = project, slug, source) do
    case Repo.one(
           from d in Dataset, where: d.project_id == ^project.id and d.slug == ^slug, select: d.id
         ) do
      nil ->
        :ok

      existing ->
        refuse!(
          "dataset_slug_conflict",
          "datasets",
          "project #{project.id} already has a dataset #{inspect(slug)} (#{existing}); a remap " <>
            "import only creates a new dataset and never merges into an existing one",
          %{existing_dataset_id: existing, project_id: project.id, slug: slug}
        )
    end

    attrs = %{slug: slug, name: source.name || slug, project_id: project.id}

    case Repo.insert(Dataset.changeset(%Dataset{}, attrs)) do
      {:ok, dataset} ->
        dataset

      {:error, changeset} ->
        refuse!(
          "invalid_target",
          "datasets",
          "the new dataset could not be created: #{inspect(changeset.errors)}",
          %{errors: changeset.errors}
        )
    end
  end

  # ── Rewrites (on the staged rows, before anything touches a real table) ─────

  @tenancy_set "workspace_id = $1::text::uuid, project_id = $2::text::uuid, " <>
                 "dataset_id = $3::text::uuid, dataset = $4"

  defp map_expr(col, kind),
    do: "(SELECT m.new FROM _bp_remap_ids m WHERE m.kind = '#{kind}' AND m.old = t.#{col})"

  # sobelow_skip ["SQL.Query"]
  defp rewrite!(staged, dest) do
    params = [dest.workspace_id, dest.project_id, dest.dataset_id, dest.slug]

    # A statement that names no parameter must be sent none: Postgres cannot
    # type a `$n` that the SQL never mentions.
    run = fn table, set ->
      if staged[table] do
        ps = if String.contains?(set, "$1"), do: params, else: []
        Repo.query!("UPDATE #{qi(staged[table].tmp)} t SET #{set}", ps)
      end
    end

    run.(
      "documents",
      "#{@tenancy_set}, " <>
        "current_revision_id = #{map_expr("current_revision_id", "revisions")}, " <>
        "released_revision_id = #{map_expr("released_revision_id", "revisions")}, " <>
        "id = #{map_expr("id", "documents")}"
    )

    run.(
      "revisions",
      "#{@tenancy_set}, document_id = #{map_expr("document_id", "documents")}, " <>
        "id = #{map_expr("id", "revisions")}"
    )

    for table <- ~w(content_edges task_edges) do
      run.(
        table,
        "id = gen_random_uuid(), from_id = #{map_expr("from_id", "documents")}, " <>
          "to_id = #{map_expr("to_id", "documents")}"
      )
    end

    run.("plugin_doc_state", "doc_id = #{map_expr("doc_id", "documents")}")
    run.("mutation_events", @tenancy_set)
    run.("schema_definitions", "#{@tenancy_set}, id = gen_random_uuid()")

    if staged["authoring_exemptions"] do
      Repo.query!(
        "UPDATE #{qi(staged["authoring_exemptions"].tmp)} t SET dataset = $1",
        [dest.slug]
      )
    end

    :ok
  end

  # ── The backstop scan ────────────────────────────────────────────────────────

  # sobelow_skip ["SQL.Query"]
  defp assert_no_source_ids!(staged, source) do
    Repo.query!(
      "CREATE TEMP TABLE _bp_remap_source_ids (id uuid PRIMARY KEY) ON COMMIT DROP",
      []
    )

    Repo.query!(
      "INSERT INTO _bp_remap_source_ids (id) " <>
        "SELECT old FROM _bp_remap_ids UNION " <>
        "SELECT unnest(ARRAY[$1::text::uuid, $2::text::uuid, $3::text::uuid])",
      [source.workspace_id, source.project_id, source.dataset_id]
    )

    for table <- @rewritten, staged[table] do
      %{rows: rows} =
        Repo.query!(
          "SELECT s.id::text, count(*) " <>
            "FROM #{qi(staged[table].tmp)} t " <>
            "CROSS JOIN LATERAL " <>
            "regexp_matches(row_to_json(t)::text, '(#{@uuid_regex})', 'g') AS m(u) " <>
            "JOIN _bp_remap_source_ids s ON s.id = m.u[1]::uuid " <>
            "GROUP BY s.id ORDER BY s.id LIMIT 5",
          []
        )

      case rows do
        [] ->
          :ok

        [_ | _] ->
          total = rows |> Enum.map(&List.last/1) |> Enum.sum()

          refuse!(
            "unremapped_source_id",
            table,
            "after rewriting, #{table} still contains id(s) of the source dataset's rows or " <>
              "tenancy (#{Enum.map_join(rows, ", ", &hd/1)}). A column or embedded value " <>
              "holds a reference the remap does not rewrite; importing it would point the " <>
              "new dataset at the source.",
            %{count: total, sample: Enum.map(rows, &hd/1)}
          )
      end
    end

    :ok
  end

  # ── Inserts, with every FK enforced ──────────────────────────────────────────

  # sobelow_skip ["SQL.Query"]
  defp insert!(staged) do
    counts = %{}

    counts =
      insert_table!(staged, "documents", counts, fn col ->
        if col in ["current_revision_id", "released_revision_id"],
          do: "NULL",
          else: "t.#{qi(col)}"
      end)

    counts =
      if staged["revisions"] do
        with_revision_triggers_disabled(fn -> insert_table!(staged, "revisions", counts) end)
      else
        counts
      end

    if staged["documents"] do
      Repo.query!(
        "UPDATE documents d SET current_revision_id = t.current_revision_id, " <>
          "released_revision_id = t.released_revision_id " <>
          "FROM #{qi(staged["documents"].tmp)} t WHERE d.id = t.id",
        []
      )
    end

    counts =
      ~w(content_edges task_edges plugin_doc_state schema_definitions)
      |> Enum.reduce(counts, &insert_table!(staged, &1, &2))

    counts =
      insert_table!(staged, "mutation_events", counts, fn col -> "t.#{qi(col)}" end, drop: ["id"])

    insert_table!(staged, "authoring_exemptions", counts, fn col -> "t.#{qi(col)}" end,
      suffix: " ON CONFLICT DO NOTHING"
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp insert_table!(staged, table, counts, select \\ nil, opts \\ []) do
    case staged[table] do
      nil ->
        counts

      %{tmp: tmp, cols: cols} ->
        cols = cols -- Keyword.get(opts, :drop, [])
        select = select || fn col -> "t.#{qi(col)}" end

        %{num_rows: n} =
          Repo.query!(
            "INSERT INTO #{qi(table)} (#{Enum.map_join(cols, ", ", &qi/1)}) " <>
              "SELECT #{Enum.map_join(cols, ", ", select)} FROM #{qi(tmp)} t" <>
              Keyword.get(opts, :suffix, ""),
            []
          )

        Map.put(counts, table, n)
    end
  end

  defp with_revision_triggers_disabled(fun) do
    alter_revision_triggers!("DISABLE")
    result = fun.()
    alter_revision_triggers!("ENABLE")
    result
  end

  defp alter_revision_triggers!(action) when action in ["DISABLE", "ENABLE"] do
    Repo.query!("SET LOCAL lock_timeout = '#{@ddl_lock_timeout}'", [])
    Repo.query!("ALTER TABLE public.revisions #{action} TRIGGER USER", [])
    Repo.query!("SET LOCAL lock_timeout = '0'", [])
  end

  # `ON COMMIT DROP` drops these at the outermost COMMIT. When the import runs
  # nested in a caller's transaction (the ExUnit sandbox does exactly that),
  # that commit is not ours, so a second import in the same outer transaction
  # would find them still there. Drop them on the way out; a refusal needs no
  # cleanup, because the rollback un-creates them.
  # sobelow_skip ["SQL.Query"]
  defp drop_temp_tables!(staged) do
    tmps = Enum.map(staged, fn {_table, %{tmp: tmp}} -> tmp end)

    for tmp <- tmps ++ ~w(_bp_remap_ids _bp_remap_source_ids) do
      Repo.query!("DROP TABLE IF EXISTS #{qi(tmp)}", [])
    end

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp refuse!(code, table, message, details \\ %{}) do
    raise DatasetRemapError, code: code, table: table, message: message, details: details
  end

  # Same quoting as WorkspaceBundle.qi/1: manifest-derived identifiers are
  # double-quoted with embedded quotes doubled.
  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")
end
