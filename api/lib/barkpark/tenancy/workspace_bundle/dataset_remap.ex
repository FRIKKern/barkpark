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
    * `"column_mismatch"` — a rewritten table's columns in the bundle differ
      from this database's (a bundle from another schema version).
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
    * `mutation_events` — `id` takes fresh values from its sequence; tenancy
      columns as above.
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

  The backstop for everything this list missed: every rewritten row is scanned,
  as the COPY line about to be written, for UUIDs; if one is the source
  workspace, project or dataset id, or the old id of a bundled document or
  revision, the import refuses with `unremapped_source_id`, naming the table,
  and the transaction rolls back.

  ## Integrity

  Every row is rewritten in the BEAM, on the COPY text the bundle carries, and
  written with a literal `COPY <table> FROM STDIN` chosen by clause match on the
  closed set of rewritten tables. No SQL statement in this module is built from
  bundle input. The bundle's columns must equal this database's non-generated
  columns for each rewritten table (`column_mismatch` otherwise), which is what
  makes a column-list-free COPY land each value in its own column.

  Foreign keys stay enforced on the rewritten tables for the whole import, so a
  mapped id that does not exist in the target is a hard failure, not an orphan.
  The one DDL statement is `ALTER TABLE revisions DISABLE TRIGGER USER` around
  the revisions COPY: `revisions_bind_document` requires each inserted revision
  to match its document's CURRENT state, which historical revisions do not, and
  `revisions_immutable` is not exercised by an insert. Both are re-enabled
  before commit. The whole import is one transaction.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Dataset, Project}
  alias Barkpark.Tenancy.WorkspaceBundle.{Catalog, DatasetRemapError}
  alias Ecto.Adapters.SQL

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

  # Any UUID in a COPY line, either case.
  @uuid ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/

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
  Run the remap import. `sources` maps each member table to an enumerable of
  its COPY text chunks (re-enumerable: it is read more than once). Returns
  `{:ok, stats}`; every refusal raises `DatasetRemapError` after rolling back.
  """
  @spec run(map(), %{optional(String.t()) => Enumerable.t()}, target()) :: {:ok, map()}
  def run(manifest, sources, target) do
    Repo.transaction(fn -> do_run(manifest, sources, target) end, timeout: :infinity)
  end

  defp do_run(manifest, sources, target) do
    # A COPY of a large dataset is one long statement; see the same opt-out in
    # WorkspaceBundle.run_import_once/4.
    Repo.set_local_statement_timeout!(0)
    # Empty the deferred-trigger queue so the ALTER TABLE on revisions below is
    # allowed (Postgres refuses ALTER on a table with pending trigger events).
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [])

    assert_dataset_bundle!(manifest)
    project = resolve_target!(target)

    entries = Enum.filter(manifest["tables"] || [], &(&1["row_count"] > 0))

    members =
      Map.new(entries, fn e ->
        {e["name"],
         %{
           table: e["name"],
           cols: e["columns"] || [],
           rows: e["row_count"],
           source: Map.get(sources, e["name"], [])
         }}
      end)

    classes = Map.new(entries, fn e -> {e["name"], classify!(e["name"])} end)

    for {table, :rewritten} <- classes, do: assert_live_columns!(members[table])

    source = source!(manifest, members["datasets"])
    maps = build_id_maps(members)
    guarded = check_guarded!(members, classes, source, maps)
    check_rewritten!(members, source, maps)
    dropped = count_out_of_dataset!(members, maps)

    dataset = create_dataset!(project, target.slug, source)

    ctx = %{
      dest: %{
        workspace_id: project.workspace_id,
        project_id: project.id,
        dataset_id: dataset.id,
        slug: dataset.slug
      },
      maps: maps,
      source_ids:
        MapSet.new(
          [source.workspace_id, source.project_id, source.dataset_id] ++
            Map.keys(maps.documents) ++ Map.keys(maps.revisions)
        )
    }

    inserted = write!(members, ctx, dropped)

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
        dropped_out_of_dataset: Map.merge(guarded, dropped),
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

  # ── Column layout: the rewrite addresses columns by the manifest's order ─────

  # Every rewritten member is written back with a column-list-free `COPY <table>
  # FROM STDIN`, which takes the table's non-generated columns in ordinal order.
  # That is only the manifest's order when the bundle came from this schema, so
  # a bundle from another schema version is refused rather than mis-assigned.
  defp assert_live_columns!(%{table: table, cols: cols}) do
    live = Catalog.non_generated_columns(Repo, table)

    if cols != live do
      refuse!(
        "column_mismatch",
        table,
        "the bundle's #{table} columns do not match this database's (a bundle from another " <>
          "schema version): bundle #{inspect(cols)}, here #{inspect(live)}",
        %{bundle: cols, live: live}
      )
    end
  end

  # ── Reading COPY text ────────────────────────────────────────────────────────

  # Rows of a member as lists of raw COPY fields. COPY text escapes tab and
  # newline inside a value, so a bare tab separates fields and a bare newline
  # ends a row, whatever the chunk boundaries were.
  defp rows(nil), do: []

  defp rows(%{source: source}) do
    source
    |> Stream.transform(
      fn -> "" end,
      fn chunk, buffer ->
        parts = String.split(buffer <> IO.iodata_to_binary(chunk), "\n")
        {complete, [rest]} = Enum.split(parts, -1)
        {complete, rest}
      end,
      fn
        "" -> {[], ""}
        rest -> {[rest], ""}
      end,
      fn _ -> :ok end
    )
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&String.split(&1, "\t"))
  end

  defp col!(%{table: table, cols: cols}, col) do
    Enum.find_index(cols, &(&1 == col)) ||
      refuse!("column_mismatch", table, "the bundle's #{table} member has no #{col} column")
  end

  # The decoded value of field `i`: `nil` for SQL NULL, otherwise the text with
  # COPY's backslash escapes undone.
  defp value(fields, i) do
    case Enum.at(fields, i) do
      "\\N" -> nil
      nil -> nil
      raw -> unescape(raw)
    end
  end

  defp unescape(raw) do
    if String.contains?(raw, "\\") do
      Regex.replace(~r/\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)/s, raw, fn _, esc ->
        case esc do
          "b" -> "\b"
          "f" -> "\f"
          "n" -> "\n"
          "r" -> "\r"
          "t" -> "\t"
          "v" -> "\v"
          "x" <> hex -> <<String.to_integer(hex, 16)>>
          <<d, _::binary>> = oct when d in ?0..?7 -> <<String.to_integer(oct, 8)>>
          other -> other
        end
      end)
    else
      raw
    end
  end

  # Only ever called with UUIDs, the dataset slug (the Dataset changeset limits
  # it to [a-z0-9_-]) or nil, none of which needs COPY escaping.
  defp put(fields, i, nil), do: List.replace_at(fields, i, "\\N")
  defp put(fields, i, value), do: List.replace_at(fields, i, value)

  defp line(fields), do: [Enum.join(fields, "\t"), "\n"]

  # ── The source dataset, read from the rows the bundle carries ────────────────

  defp source!(manifest, datasets) do
    expected = manifest["dataset"]

    found =
      case datasets do
        nil ->
          []

        member ->
          [id, project_id, slug, name] =
            Enum.map(~w(id project_id slug name), &col!(member, &1))

          member
          |> rows()
          |> Enum.map(fn f ->
            {value(f, id), value(f, project_id), value(f, slug), value(f, name)}
          end)
      end

    case found do
      [{id, project_id, ^expected, name}] ->
        %{
          workspace_id: manifest["workspace_id"],
          project_id: project_id,
          dataset_id: id,
          slug: expected,
          name: name
        }

      _ ->
        refuse!(
          "not_a_dataset_bundle",
          "datasets",
          "a dataset bundle carries exactly one datasets row, the one named in its manifest " <>
            "(#{inspect(expected)}); this one carries #{length(found)}"
        )
    end
  end

  # ── Id maps: old row id -> new row id, for every id other rows point at ──────

  defp build_id_maps(members) do
    %{
      documents: fresh_ids(members["documents"]),
      revisions: fresh_ids(members["revisions"])
    }
  end

  defp fresh_ids(nil), do: %{}

  defp fresh_ids(member) do
    id = col!(member, "id")
    member |> rows() |> Map.new(fn f -> {value(f, id), Ecto.UUID.generate()} end)
  end

  # ── Guarded tables: refuse the source dataset's rows, drop everyone else's ──

  defp check_guarded!(members, classes, source, maps) do
    for {table, {:guarded, grain, fks}} <- classes, into: %{} do
      member = members[table]
      owned? = owned_predicate(member, grain, fks, source, maps)
      owned = member |> rows() |> Enum.count(owned?)

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

      {table, member.rows}
    end
  end

  defp owned_predicate(member, grain, fks, source, maps) do
    has_dataset_id? = "dataset_id" in grain

    grain_tests =
      Enum.map(grain, fn
        "dataset_id" ->
          i = col!(member, "dataset_id")
          fn f -> value(f, i) == source.dataset_id end

        "dataset" ->
          i = col!(member, "dataset")
          j = if has_dataset_id?, do: col!(member, "dataset_id")

          fn f ->
            value(f, i) == source.slug and (j == nil or value(f, j) == nil)
          end

        "scope" ->
          i = col!(member, "scope")
          fn f -> value(f, i) in [source.slug, "dataset:" <> source.slug] end
      end)

    fk_tests =
      Enum.map(fks, fn {col, parent} ->
        i = col!(member, col)
        ids = if parent == "documents", do: maps.documents, else: maps.revisions
        fn f -> Map.has_key?(ids, value(f, i)) end
      end)

    tests = grain_tests ++ fk_tests
    fn f -> Enum.any?(tests, & &1.(f)) end
  end

  # ── Rewritten tables: preconditions on the OLD values ────────────────────────

  defp check_rewritten!(members, source, maps) do
    for table <- @tenancy_tables, member = members[table] do
      i = col!(member, "dataset_id")
      bad = member |> rows() |> Enum.count(&(value(&1, i) != source.dataset_id))

      if bad > 0 do
        refuse!(
          "unexpected_dataset",
          table,
          "#{bad} row(s) in #{table} name a dataset other than the source dataset " <>
            "#{inspect(source.slug)} (#{source.dataset_id})",
          %{count: bad}
        )
      end
    end

    assert_mapped!(members["revisions"], "document_id", maps.documents, "documents")
    assert_mapped!(members["documents"], "current_revision_id", maps.revisions, "revisions")
    assert_mapped!(members["documents"], "released_revision_id", maps.revisions, "revisions")

    # An edge from a document IN the dataset to one outside it cannot be
    # rewritten: its target does not travel.
    for table <- ~w(content_edges task_edges), member = members[table] do
      from = col!(member, "from_id")
      to = col!(member, "to_id")

      member
      |> rows()
      |> Enum.filter(
        &(Map.has_key?(maps.documents, value(&1, from)) and
            not Map.has_key?(maps.documents, value(&1, to)))
      )
      |> Enum.map(&value(&1, to))
      |> refuse_dangling!(
        table,
        "lead from a document in the dataset to a document outside it"
      )
    end

    :ok
  end

  defp assert_mapped!(nil, _col, _ids, _kind), do: :ok

  defp assert_mapped!(member, col, ids, kind) do
    i = col!(member, col)

    member
    |> rows()
    |> Enum.map(&value(&1, i))
    |> Enum.reject(&(&1 == nil or Map.has_key?(ids, &1)))
    |> refuse_dangling!(member.table, "point (#{col}) at a #{kind} row the bundle does not carry")
  end

  defp refuse_dangling!([], _table, _what), do: :ok

  defp refuse_dangling!(targets, table, what) do
    sample = targets |> Enum.uniq() |> Enum.take(5)

    refuse!(
      "dangling_reference",
      table,
      "#{length(targets)} #{table} row(s) #{what} (#{Enum.map_join(sample, ", ", &inspect/1)}); " <>
        "the rewritten row would have nothing to point at",
      %{count: length(targets), sample: sample}
    )
  end

  # Edges and plugin state travel workspace-whole even in a dataset bundle
  # (they have no dataset column). A row whose SOURCE document is not in the
  # bundle belongs to another dataset and is dropped; this counts them.
  defp count_out_of_dataset!(members, maps) do
    for {table, col} <- [
          {"content_edges", "from_id"},
          {"task_edges", "from_id"},
          {"plugin_doc_state", "doc_id"}
        ],
        member = members[table],
        into: %{} do
      i = col!(member, col)
      {table, member |> rows() |> Enum.count(&(not Map.has_key?(maps.documents, value(&1, i))))}
    end
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

  # ── Writes: rewrite each row in the BEAM, COPY it into the real table ────────

  defp write!(members, ctx, dropped) do
    %{maps: maps, dest: dest} = ctx
    counts = %{}

    # documents: re-keyed, revision pointers NULL until the revisions exist.
    counts =
      write_member(members["documents"], counts, ctx, fn member ->
        [id, cur, rel] =
          Enum.map(~w(id current_revision_id released_revision_id), &col!(member, &1))

        fn f ->
          f
          |> put(id, Map.fetch!(maps.documents, value(f, id)))
          |> retenant(member, dest)
          |> put(cur, nil)
          |> put(rel, nil)
        end
      end)

    counts =
      with_revision_triggers_disabled(fn ->
        write_member(members["revisions"], counts, ctx, fn member ->
          [id, doc] = Enum.map(~w(id document_id), &col!(member, &1))

          fn f ->
            f
            |> put(id, Map.fetch!(maps.revisions, value(f, id)))
            |> put(doc, maps.documents[value(f, doc)])
            |> retenant(member, dest)
          end
        end)
      end)

    set_revision_pointers!(members["documents"], maps)

    counts =
      Enum.reduce(~w(content_edges task_edges), counts, fn table, acc ->
        write_member(members[table], acc, ctx, dropped[table], fn member ->
          [id, from, to] = Enum.map(~w(id from_id to_id), &col!(member, &1))

          fn f ->
            case maps.documents[value(f, from)] do
              nil ->
                :drop

              new_from ->
                f
                |> put(id, Ecto.UUID.generate())
                |> put(from, new_from)
                |> put(to, Map.fetch!(maps.documents, value(f, to)))
            end
          end
        end)
      end)

    counts =
      write_member(
        members["plugin_doc_state"],
        counts,
        ctx,
        dropped["plugin_doc_state"],
        fn member ->
          doc = col!(member, "doc_id")

          fn f ->
            case maps.documents[value(f, doc)] do
              nil -> :drop
              new_doc -> put(f, doc, new_doc)
            end
          end
        end
      )

    counts =
      write_member(members["schema_definitions"], counts, ctx, fn member ->
        id = col!(member, "id")
        fn f -> f |> put(id, Ecto.UUID.generate()) |> retenant(member, dest) end
      end)

    counts = write_mutation_events!(members["mutation_events"], counts, ctx)
    write_exemptions!(members["authoring_exemptions"], counts, ctx)
  end

  defp write_member(member, counts, ctx, dropped \\ 0, rewriter)

  defp write_member(nil, counts, _ctx, _dropped, _rewriter), do: counts

  defp write_member(member, counts, ctx, dropped, rewriter) do
    rewrite = rewriter.(member)

    member
    |> rows()
    |> Stream.map(rewrite)
    |> Stream.reject(&(&1 == :drop))
    |> Stream.map(&scan!(member.table, line(&1), ctx.source_ids))
    |> Enum.into(copy_in(member.table))

    Map.put(counts, member.table, member.rows - (dropped || 0))
  end

  defp retenant(fields, member, dest) do
    fields
    |> put(col!(member, "workspace_id"), dest.workspace_id)
    |> put(col!(member, "project_id"), dest.project_id)
    |> put(col!(member, "dataset_id"), dest.dataset_id)
    |> put(col!(member, "dataset"), dest.slug)
  end

  # mutation_events.id is a sequence: the new rows take fresh values from it
  # rather than the source's, which may already be taken here.
  defp write_mutation_events!(nil, counts, _ctx), do: counts

  defp write_mutation_events!(member, counts, ctx) do
    id = col!(member, "id")
    carried = member |> rows() |> Enum.count()

    ids =
      Repo.query!(
        "SELECT nextval('mutation_events_id_seq')::text FROM generate_series(1, $1)",
        [carried]
      ).rows
      |> List.flatten()

    member
    |> rows()
    |> Stream.zip(ids)
    |> Stream.map(fn {f, new_id} -> f |> put(id, new_id) |> retenant(member, ctx.dest) end)
    |> Stream.map(&scan!(member.table, line(&1), ctx.source_ids))
    |> Enum.into(copy_in("mutation_events"))

    Map.put(counts, "mutation_events", carried)
  end

  # authoring_exemptions is keyed by the bare (doc_id, dataset) pair, which
  # another workspace may already hold under the same slug. First writer wins,
  # the same rule the ordinary import applies (ON CONFLICT DO NOTHING).
  defp write_exemptions!(nil, counts, _ctx), do: counts

  defp write_exemptions!(member, counts, ctx) do
    ds = col!(member, "dataset")

    Repo.query!(
      "CREATE TEMP TABLE _bp_remap_exemptions (LIKE authoring_exemptions INCLUDING DEFAULTS) " <>
        "ON COMMIT DROP",
      []
    )

    member
    |> rows()
    |> Stream.map(&put(&1, ds, ctx.dest.slug))
    |> Stream.map(&scan!(member.table, line(&1), ctx.source_ids))
    |> Enum.into(copy_in("_bp_remap_exemptions"))

    %{num_rows: n} =
      Repo.query!(
        "INSERT INTO authoring_exemptions SELECT * FROM _bp_remap_exemptions " <>
          "ON CONFLICT DO NOTHING",
        []
      )

    Repo.query!("DROP TABLE _bp_remap_exemptions", [])
    Map.put(counts, "authoring_exemptions", n)
  end

  # Every statement is a literal, one per table the remap writes; the table is
  # chosen by clause match on the closed @rewritten set, never interpolated.
  defp copy_in("documents"), do: SQL.stream(Repo, "COPY documents FROM STDIN", [])
  defp copy_in("revisions"), do: SQL.stream(Repo, "COPY revisions FROM STDIN", [])
  defp copy_in("content_edges"), do: SQL.stream(Repo, "COPY content_edges FROM STDIN", [])
  defp copy_in("task_edges"), do: SQL.stream(Repo, "COPY task_edges FROM STDIN", [])
  defp copy_in("plugin_doc_state"), do: SQL.stream(Repo, "COPY plugin_doc_state FROM STDIN", [])
  defp copy_in("mutation_events"), do: SQL.stream(Repo, "COPY mutation_events FROM STDIN", [])

  defp copy_in("schema_definitions"),
    do: SQL.stream(Repo, "COPY schema_definitions FROM STDIN", [])

  defp copy_in("_bp_remap_exemptions"),
    do: SQL.stream(Repo, "COPY _bp_remap_exemptions FROM STDIN", [])

  # documents <-> revisions reference each other, so the documents land with
  # NULL revision pointers and get them here, once the revisions exist.
  defp set_revision_pointers!(nil, _maps), do: :ok

  defp set_revision_pointers!(member, maps) do
    [id, cur, rel] = Enum.map(~w(id current_revision_id released_revision_id), &col!(member, &1))

    triples =
      member
      |> rows()
      |> Enum.map(fn f ->
        {maps.documents[value(f, id)], maps.revisions[value(f, cur)],
         maps.revisions[value(f, rel)]}
      end)
      |> Enum.reject(fn {_doc, c, r} -> c == nil and r == nil end)

    if triples != [] do
      {docs, curs, rels} =
        Enum.reduce(Enum.reverse(triples), {[], [], []}, fn {d, c, r}, {ds, cs, rs} ->
          {[d | ds], [c | cs], [r | rs]}
        end)

      Repo.query!(
        "UPDATE documents d SET current_revision_id = v.cur, released_revision_id = v.rel " <>
          "FROM unnest($1::text[]::uuid[], $2::text[]::uuid[], $3::text[]::uuid[]) " <>
          "AS v(id, cur, rel) WHERE d.id = v.id",
        [docs, curs, rels]
      )
    end

    :ok
  end

  # `revisions_bind_document` requires each inserted revision to match its
  # document's CURRENT state, which a historical revision does not. Owner-level
  # DDL inside the import transaction, bounded like WorkspaceBundle's DDL passes.
  defp with_revision_triggers_disabled(fun) do
    Repo.query!("SET LOCAL lock_timeout = '2s'", [])
    Repo.query!("ALTER TABLE public.revisions DISABLE TRIGGER USER", [])
    Repo.query!("SET LOCAL lock_timeout = '0'", [])
    result = fun.()
    Repo.query!("SET LOCAL lock_timeout = '2s'", [])
    Repo.query!("ALTER TABLE public.revisions ENABLE TRIGGER USER", [])
    Repo.query!("SET LOCAL lock_timeout = '0'", [])
    result
  end

  # ── The backstop scan ────────────────────────────────────────────────────────

  # Every rewritten row is scanned, as the COPY line about to be written, for
  # any UUID that is a source tenancy id or the old id of a bundled document or
  # revision. A hit means a reference shape the rewrites above do not know
  # about, and the import stops (inside the transaction, so nothing lands).
  defp scan!(table, line, source_ids) do
    hits =
      @uuid
      |> Regex.scan(IO.iodata_to_binary(line))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&MapSet.member?(source_ids, &1))

    if hits != [] do
      sample = hits |> Enum.uniq() |> Enum.take(5)

      refuse!(
        "unremapped_source_id",
        table,
        "after rewriting, #{table} still contains id(s) of the source dataset's rows or " <>
          "tenancy (#{Enum.join(sample, ", ")}). A column or embedded value holds a " <>
          "reference the remap does not rewrite; importing it would point the new dataset " <>
          "at the source.",
        %{count: length(hits), sample: sample}
      )
    end

    line
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp refuse!(code, table, message, details \\ %{}) do
    raise DatasetRemapError, code: code, table: table, message: message, details: details
  end
end
