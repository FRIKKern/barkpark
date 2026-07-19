defmodule Barkpark.Tenancy.WorkspaceBundle do
  @moduledoc """
  Export ANY workspace into one complete, self-describing bp-export-v1 bundle
  and re-import it into a clean database with ZERO silent loss — the keystone
  the five Cloud consumers (backup, eject, rebalance, graduation, migration)
  inherit.

  Completeness is PROVEN, never asserted by grep: an `information_schema` +
  `pg_constraint` partition diff plus per-table count-parity and
  `md5(non-generated-cols)` parity on a real seeded round-trip. The proof lives
  in `test/barkpark/tenancy/workspace_bundle_test.exs`.

  ## The byte carrier (charter D2/D3/D9)

  Each table member is the RAW `COPY (SELECT <non-generated cols> WHERE
  <workspace scope>) TO STDOUT` text — never `Envelope.render` output, which
  synthesizes `_draft`/`_publishedId`, merges `title`, and drops `status` +
  every tenancy column, corrupting the round-trip. Generated columns (today only
  `documents.search_vector`) are excluded from the column list and Postgres
  re-generates them on import.

  ## The three enumerations (charter D4) — see `Catalog`

  E1 (`workspace_id` scan), E2 (recursive FK-walk, parent-join), E3 (`dataset`
  scan + a `scope`-column allowlist). All derived LIVE from the catalog; the
  reviewed partition sentinel (`Catalog.assert_partition!/1`) is the drift
  tripwire.

  ## Fail-closed scope (charter D8)

  `export/2` requires a NON-NIL UUID `workspace_id`. The dataset-slug map that
  drives E3/allowlist membership is derived through
  `Content.Scope.scope_to_workspace/2` (fail-CLOSED `where(false)` on nil) on
  the workspace's projects — NEVER `scope_to_workspace_or_global` (which routes
  nil to a fully-unscoped, all-tenant read → a cross-tenant leak into a
  single-workspace bundle).

  ## Import (charter D7 · PDS-D8/D9)

  Re-imported under `SET session_replication_role = replica` (FK triggers off,
  any insert order). Two modes:

    * `:clean` (default) — byte-identical restore into a CLEAN target. E1/E2/
      root members re-import via `COPY … FROM STDIN`; the string-keyed E3 +
      allowlist members re-import via `INSERT … ON CONFLICT DO NOTHING`,
      because their key is NOT workspace-unique (the same
      `authoring_exemptions` `(doc_id, dataset)` row maps to two workspaces, so
      a second workspace's bundle would otherwise crash a plain INSERT).
    * `:merge` (PDS-D8) — convergent refresh over a possibly-POPULATED target.
      Root/E1/E2 copy members ride a temp table (`LIKE … INCLUDING DEFAULTS`,
      `ON COMMIT DROP`) + `COPY` + `INSERT … ON CONFLICT (order_columns)
      DO UPDATE SET <non-key> = EXCLUDED.<non-key>` — the arbiter is the
      manifest member's existing `order_columns` (= the primary key for every
      table today; zero manifest change). When every column is part of the key
      the degenerate action is `DO NOTHING`. E3/allowlist members STAY on bare
      `DO NOTHING` (first-workspace-wins on shared string-keyed rows is
      deliberate). Before any member imports, the root-slug pre-flight
      (PDS-D9) adopts or refuses a same-slug/different-id target — see
      `adopt_or_refuse_root_slug!/1`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content.Scope
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Dataset, Project, Workspace}
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog}

  @type stats :: %{
          tables: %{optional(String.t()) => non_neg_integer()},
          total_rows: non_neg_integer()
        }

  @doc """
  Export a workspace to a bp-export-v1 bundle binary.

  Returns `{:ok, bundle}` (a tar binary), `{:error, :workspace_id_required}`
  when the id is missing / not a UUID (fail-closed — never a nil-scoped
  all-tenant read), or `{:error, :workspace_not_found}`.
  """
  @spec export(binary() | nil, keyword()) ::
          {:ok, binary()} | {:error, :workspace_id_required | :workspace_not_found}
  # @canonical capability:workspace-bundle aka:export_workspace,import_workspace,tenant_bundle,per_workspace_export doc:.claude/workflows/bp-cloud-build-charter.md
  def export(workspace_id, opts \\ [])

  def export(workspace_id, opts) when is_binary(workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        {:error, :workspace_id_required}

      ws_id ->
        case Repo.get(Workspace, ws_id) do
          nil -> {:error, :workspace_not_found}
          %Workspace{} = ws -> {:ok, do_export(ws, opts)}
        end
    end
  end

  def export(_nil_or_other, _opts), do: {:error, :workspace_id_required}

  @doc """
  Re-import a bundle binary. Returns `{:ok, stats}` where `stats.tables` maps
  each table to the rows imported into it (rows already present via the
  ON-CONFLICT path are not double-counted at the SQL level but ARE included in
  the member's row_count — the return counts rows the bundle CARRIED, in BOTH
  modes: a merge that updated-in-place rather than inserted still reports the
  carried row count, never a per-row insert/update split).

  ## Options

    * `:mode` — `:clean` (default; byte-identical restore into a clean target)
      or `:merge` (PDS-D8; convergent upsert over a possibly-populated target).

  In `:merge` mode a same-slug/different-id root collision returns
  `{:error, {:workspace_slug_conflict, %{slug, existing_id, bundle_id}}}`
  unless the squatting workspace is a provably EMPTY shell (0 documents,
  0 media_files), which is deleted in-transaction and replaced (PDS-D9).
  """
  @spec import_bundle(binary(), keyword()) ::
          {:ok, stats()} | {:error, {:workspace_slug_conflict, map()} | term()}
  def import_bundle(bundle, opts \\ []) when is_binary(bundle) do
    mode = Keyword.get(opts, :mode, :clean)

    unless mode in [:clean, :merge] do
      raise ArgumentError,
            "unknown import mode #{inspect(mode)} (expected :clean or :merge)"
    end

    {manifest, dumps} = Archive.unpack(bundle)

    if manifest["format"] != Archive.format() do
      raise ArgumentError, "not a #{Archive.format()} bundle: #{inspect(manifest["format"])}"
    end

    Repo.transaction(
      fn ->
        # PDS-D9 pre-flight runs BEFORE the replica-role flip so the empty-shell
        # delete's FK cascades still fire (replica role disables FK triggers).
        if mode == :merge, do: adopt_or_refuse_root_slug!(manifest)

        set_replication_role!("replica")

        try do
          manifest["tables"]
          |> Enum.reduce({%{}, 0}, fn entry, {acc, total} ->
            n = import_member(entry, Map.get(dumps, entry["name"], ""), mode)
            {Map.put(acc, entry["name"], n), total + n}
          end)
          |> then(fn {tables, total} -> %{tables: tables, total_rows: total} end)
        after
          set_replication_role!("DEFAULT")
        end
      end,
      timeout: :infinity
    )
  end

  # ── Export ───────────────────────────────────────────────────────────────────

  defp do_export(%Workspace{} = ws, _opts) do
    ws_lit = Catalog.uuid_literal!(ws.id)
    dataset_slugs = dataset_slugs_for(ws.id)

    specs =
      [{Catalog.root_table(), "root", :root}] ++
        Enum.map(Catalog.live_e1(Repo), &{&1, "E1", :e1}) ++
        Enum.map(Catalog.live_e2(Repo), &{&1, "E2", :e2}) ++
        Enum.map(Catalog.live_e3(Repo), &{&1, "E3", e3_kind(&1)}) ++
        Enum.map(Map.keys(Catalog.allowlist()), &{&1, "allowlist", :allowlist})

    {members, dumps} =
      Enum.reduce(specs, {[], %{}}, fn {table, partition, kind}, {members, dumps} ->
        cols = Catalog.non_generated_columns(Repo, table)
        order_cols = Catalog.order_columns(Repo, table)
        sql = copy_out_sql(table, kind, cols, order_cols, ws_lit, dataset_slugs)
        {dump, row_count} = run_copy_out(sql)

        member = %{
          "name" => table,
          "partition" => partition,
          "import_strategy" => import_strategy(kind),
          "columns" => cols,
          "order_columns" => order_cols,
          "row_count" => row_count,
          "md5" => md5_hex(dump)
        }

        {[member | members], Map.put(dumps, table, dump)}
      end)

    manifest = %{
      "format" => Archive.format(),
      "grain" => Archive.grain(),
      "workspace_id" => ws.id,
      "workspace_slug" => ws.slug,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "dataset_slugs" => dataset_slugs,
      "tables" => Enum.reverse(members)
    }

    Archive.pack(manifest, dumps)
  end

  @doc """
  The distinct dataset slugs a workspace owns EXCLUSIVELY — the fail-CLOSED,
  project-qualified slug map that drives E3/allowlist membership (charter
  D8/D21).

  Scope the workspace's PROJECTS through `Scope.scope_to_workspace/2`
  (`where(false)` on nil), read the datasets under them, then DROP any slug that
  is ALSO owned by a project of a DIFFERENT workspace.

  ## Why exclusive, not merely owned (charter D21)

  A dataset slug is unique only per `(project_id, slug)` (`datasets` unique
  index), NOT globally — every workspace gets a `"production"` dataset, so
  `"production"` collides across tenants. The E3-dataset tables
  (`preview_token_jti`, `shares`) carry ONLY that bare slug — no
  `project_id` / `dataset_id` / `workspace_id` column — so a row under a SHARED
  slug is genuinely unattributable to a single workspace. The bare
  `dataset = ANY(slugs)` predicate that BOTH the exporter (`copy_where/4`) and
  the teardown sweep (`Tenancy.delete_workspace/1`) run over that slug set
  therefore MUST NOT match a shared slug, else it becomes a cross-tenant COPY
  (leak into a single-workspace bundle) or a cross-tenant DELETE (stripping a
  co-tenant's rows on teardown). Dropping shared slugs here narrows BOTH
  callers in lockstep — fail-CLOSED: an ambiguous slug's bare-keyed rows are left
  untouched (an orphan is recoverable; a cross-tenant delete is not).

  The `scope`-column allowlist is now EMPTY: both former members moved to E1
  because a bare `scope` is exactly this unattributable-under-a-shared-slug trap.
  `search_surface_config` (Wave 5 Slice A, charter D45/D49) and `data_keys` (the
  per-dataset DEK store — a shared-slug DEK was silently dropped from a
  single-workspace bundle for exactly this reason) each gained a `workspace_id`
  FK and now ride E1: copied via `WHERE workspace_id = $ws` and swept via the FK
  cascade, so a shared-slug row travels by attribution, not by slug
  (`bpb-datakeys-write-path-workspace-attribution`, charter D51-D54).

  NEVER `scope_to_workspace_or_global` (which routes nil to a fully-unscoped,
  all-tenant read → a cross-tenant leak). Public so the teardown path derives
  the slug set from ONE source of truth instead of re-deriving it.
  """
  @spec dataset_slugs_for(binary()) :: [String.t()]
  def dataset_slugs_for(ws_id) do
    project_ids =
      Project
      |> Scope.scope_to_workspace(ws_id)
      |> select([p], p.id)
      |> Repo.all()

    if project_ids == [] do
      []
    else
      # Slugs owned by a project NOT belonging to this workspace — because
      # `project_ids` is the COMPLETE set of this workspace's projects, "not in
      # project_ids" is exactly "owned by another workspace". A slug the same
      # workspace owns via a second project is still ITS own (both projects are
      # in `project_ids`), so it is never treated as shared.
      shared_slugs =
        Dataset
        |> where([d], d.project_id not in ^project_ids)
        |> select([d], d.slug)
        |> distinct(true)
        |> Repo.all()

      Dataset
      |> where([d], d.project_id in ^project_ids)
      |> where([d], d.slug not in ^shared_slugs)
      |> select([d], d.slug)
      |> distinct(true)
      |> Repo.all()
    end
  end

  defp e3_kind(table) do
    cond do
      table in Catalog.e3_doc_keyed() ->
        :e3_doc

      table in Catalog.e3_dataset_keyed() ->
        :e3_dataset

      true ->
        raise "WorkspaceBundle: live E3 table #{inspect(table)} has no keyed extraction shape"
    end
  end

  defp import_strategy(kind) when kind in [:e3_doc, :e3_dataset, :allowlist],
    do: "insert_on_conflict"

  defp import_strategy(_), do: "copy"

  # Build the `COPY (SELECT … WHERE <scope>) TO STDOUT` for a table. The SELECT
  # is the non-generated column list; the ORDER BY makes a re-exported dump
  # byte-identical (the md5 parity check needs determinism).
  defp copy_out_sql(table, kind, cols, order_cols, ws_lit, dataset_slugs) do
    select_list = cols |> Enum.map(&"t.#{qi(&1)}") |> Enum.join(", ")
    order_by = order_cols |> Enum.map(&"t.#{qi(&1)}") |> Enum.join(", ")
    order_clause = if order_by == "", do: "", else: " ORDER BY #{order_by}"
    from = "FROM #{qi(table)} t"
    where = copy_where(table, kind, ws_lit, dataset_slugs)

    "COPY (SELECT #{select_list} #{from} #{where}#{order_clause}) TO STDOUT"
  end

  defp copy_where("workspaces", :root, ws_lit, _slugs), do: "WHERE t.id = #{ws_lit}"

  defp copy_where(_table, :e1, ws_lit, _slugs), do: "WHERE t.workspace_id = #{ws_lit}"

  defp copy_where(table, :e2, ws_lit, _slugs) do
    {join, pred} = Map.fetch!(Catalog.e2_joins(), table)
    "#{join} WHERE #{pred} = #{ws_lit}"
  end

  # E3 doc-keyed: a (doc_id, dataset) semi-join — EXISTS, never a plain JOIN,
  # which would fan out on the (doc_id, dataset) → 2-document case (charter D6).
  defp copy_where(_table, :e3_doc, ws_lit, _slugs) do
    "WHERE EXISTS (SELECT 1 FROM documents d " <>
      "WHERE d.workspace_id = #{ws_lit} AND d.doc_id = t.doc_id AND d.dataset = t.dataset)"
  end

  defp copy_where(_table, :e3_dataset, _ws_lit, slugs) do
    "WHERE t.dataset = ANY(#{Catalog.text_array_literal(slugs)})"
  end

  # data_keys.scope = "dataset:" <> slug (search_surface_config left the allowlist
  # in Wave 5 Slice A — it is now a plain E1 workspace_id table, charter D45/D49).
  defp copy_where(table, :allowlist, _ws_lit, slugs) do
    prefix = Map.fetch!(Catalog.allowlist(), table)
    scopes = Enum.map(slugs, &(prefix <> &1))
    "WHERE t.scope = ANY(#{Catalog.text_array_literal(scopes)})"
  end

  defp run_copy_out(sql) do
    res = Repo.query!(sql, [])
    dump = IO.iodata_to_binary(res.rows)
    {dump, length(res.rows)}
  end

  # ── Import ─────────────────────────────────────────────────────────────────

  # Root-slug pre-flight (PDS-D9). Every fresh migrate-seeded target already
  # holds a `slug=default` workspace under a DIFFERENT id, so the first pull
  # into it collided on `workspaces_slug_index` — masked as an opaque aborted-
  # transaction error (25P02) on the next member. In `:merge` mode: when the
  # bundle's root slug exists on the target under a different id AND that
  # workspace is provably EMPTY (0 documents, 0 media_files), delete the shell
  # inside the import transaction (via `Tenancy.delete_workspace/1`, whose FK
  # cascades need the DEFAULT replication role — hence pre-flight runs before
  # the replica flip) and proceed; otherwise refuse with a clear named error.
  defp adopt_or_refuse_root_slug!(manifest) do
    bundle_id = manifest["workspace_id"]
    slug = manifest["workspace_slug"]

    case Repo.query!(
           "SELECT id::text FROM workspaces WHERE slug = $1 AND id <> $2::text::uuid",
           [slug, bundle_id]
         ).rows do
      [] ->
        :ok

      [[existing_id]] ->
        if empty_shell?(existing_id) do
          case Tenancy.delete_workspace(existing_id) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Repo.rollback(
                {:workspace_slug_conflict,
                 %{slug: slug, existing_id: existing_id, bundle_id: bundle_id, reason: reason}}
              )
          end
        else
          Repo.rollback(
            {:workspace_slug_conflict,
             %{slug: slug, existing_id: existing_id, bundle_id: bundle_id}}
          )
        end
    end
  end

  # Provably EMPTY (PDS-D9): zero documents AND zero media_files. Anything
  # populated is refused, never silently replaced — fail-closed.
  defp empty_shell?(ws_id) do
    scalar!("SELECT count(*) FROM documents WHERE workspace_id = $1::text::uuid", [ws_id]) == 0 and
      scalar!("SELECT count(*) FROM media_files WHERE workspace_id = $1::text::uuid", [ws_id]) ==
        0
  end

  defp import_member(%{"row_count" => 0}, _dump, _mode), do: 0

  defp import_member(entry, dump, mode) do
    table = entry["name"]
    cols = entry["columns"]
    col_list = cols |> Enum.map(&qi/1) |> Enum.join(", ")

    case {entry["import_strategy"], mode} do
      {"copy", :clean} ->
        copy_into(qi(table), col_list, dump)

      {"copy", :merge} ->
        merge_upsert(table, cols, entry["order_columns"], dump)

      {"insert_on_conflict", _mode} ->
        # E3/allowlist stays bare DO NOTHING in BOTH modes: their string keys
        # are not workspace-unique, so first-workspace-wins is deliberate
        # (PDS-D8) — a merge must never overwrite a co-tenant's shared row.
        insert_on_conflict(table, col_list, dump)
    end

    entry["row_count"]
  end

  # Direct COPY FROM STDIN into the real table (clean target). Postgres
  # re-generates any generated column absent from the column list.
  defp copy_into(qualified_table, col_list, dump) do
    stream =
      Ecto.Adapters.SQL.stream(Repo, "COPY #{qualified_table} (#{col_list}) FROM STDIN", [])

    Enum.into([dump], stream)
  end

  # Idempotent import (charter D7): COPY into a temp shaped like the target, then
  # INSERT … SELECT … ON CONFLICT DO NOTHING so a shared, non-workspace-unique
  # row (e.g. authoring_exemptions (doc_id, dataset)) is a no-op instead of a
  # crash. COPY-to-temp does the text→type casting for free.
  defp insert_on_conflict(table, col_list, dump) do
    tmp = "_bp_imp_#{:erlang.unique_integer([:positive])}"

    Repo.query!(
      "CREATE TEMP TABLE #{qi(tmp)} (LIKE #{qi(table)} INCLUDING DEFAULTS) ON COMMIT DROP",
      []
    )

    stream = Ecto.Adapters.SQL.stream(Repo, "COPY #{qi(tmp)} (#{col_list}) FROM STDIN", [])
    Enum.into([dump], stream)

    Repo.query!(
      "INSERT INTO #{qi(table)} (#{col_list}) SELECT #{col_list} FROM #{qi(tmp)} " <>
        "ON CONFLICT DO NOTHING",
      []
    )

    Repo.query!("DROP TABLE #{qi(tmp)}", [])
  end

  # Merge upsert (PDS-D8): COPY into a temp shaped like the target (typed cast
  # for free), then converge via INSERT … ON CONFLICT (order_columns)
  # DO UPDATE SET <non-key> = EXCLUDED.<non-key> so a re-import over a
  # POPULATED workspace restores drifted rows and resurrects deleted ones
  # instead of crashing. The arbiter is the manifest member's `order_columns`
  # (= the primary key for every table today — Catalog.order_columns/2 falls
  # back to all columns only for a PK-less table, which would have no arbiter
  # index; fail loudly rather than guess). Degenerate all-key tables have
  # nothing to update → DO NOTHING against the same arbiter.
  defp merge_upsert(table, cols, order_cols, dump)
       when is_list(order_cols) and order_cols != [] do
    col_list = cols |> Enum.map(&qi/1) |> Enum.join(", ")
    tmp = "_bp_mrg_#{:erlang.unique_integer([:positive])}"

    Repo.query!(
      "CREATE TEMP TABLE #{qi(tmp)} (LIKE #{qi(table)} INCLUDING DEFAULTS) ON COMMIT DROP",
      []
    )

    stream = Ecto.Adapters.SQL.stream(Repo, "COPY #{qi(tmp)} (#{col_list}) FROM STDIN", [])
    Enum.into([dump], stream)

    arbiter = order_cols |> Enum.map(&qi/1) |> Enum.join(", ")

    action =
      case cols -- order_cols do
        [] ->
          "DO NOTHING"

        updatable ->
          "DO UPDATE SET " <>
            (updatable |> Enum.map(&"#{qi(&1)} = EXCLUDED.#{qi(&1)}") |> Enum.join(", "))
      end

    Repo.query!(
      "INSERT INTO #{qi(table)} (#{col_list}) SELECT #{col_list} FROM #{qi(tmp)} " <>
        "ON CONFLICT (#{arbiter}) #{action}",
      []
    )

    Repo.query!("DROP TABLE #{qi(tmp)}", [])
  end

  defp merge_upsert(table, _cols, order_cols, _dump) do
    raise ArgumentError,
          "merge import needs a non-empty order_columns arbiter for #{inspect(table)}, " <>
            "got #{inspect(order_cols)} — re-export the bundle with a current manifest"
  end

  defp set_replication_role!(role) do
    Repo.query!("SET session_replication_role = #{role}", [])
  end

  defp scalar!(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  # ── SQL identifier / hashing helpers ─────────────────────────────────────────

  # Double-quote an identifier (column/table name) — every name originates from
  # the live catalog, never user input; the quote-doubling is belt-and-suspenders.
  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  defp md5_hex(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
end
