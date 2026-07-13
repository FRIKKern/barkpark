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

  ## Import (charter D7)

  Re-imported under `SET session_replication_role = replica` (FK triggers off,
  any insert order). E1/E2/root members re-import via `COPY … FROM STDIN` into a
  clean target; the string-keyed E3 + allowlist members re-import via `INSERT …
  ON CONFLICT DO NOTHING`, because their key is NOT workspace-unique (the same
  `authoring_exemptions` `(doc_id, dataset)` row maps to two workspaces, so a
  second workspace's bundle would otherwise crash a plain INSERT).
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content.Scope
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
  the member's row_count — the return counts rows the bundle carried).
  """
  @spec import_bundle(binary(), keyword()) :: {:ok, stats()}
  def import_bundle(bundle, _opts \\ []) when is_binary(bundle) do
    {manifest, dumps} = Archive.unpack(bundle)

    if manifest["format"] != Archive.format() do
      raise ArgumentError, "not a #{Archive.format()} bundle: #{inspect(manifest["format"])}"
    end

    {:ok, stats} =
      Repo.transaction(
        fn ->
          set_replication_role!("replica")

          try do
            manifest["tables"]
            |> Enum.reduce({%{}, 0}, fn entry, {acc, total} ->
              n = import_member(entry, Map.get(dumps, entry["name"], ""))
              {Map.put(acc, entry["name"], n), total + n}
            end)
            |> then(fn {tables, total} -> %{tables: tables, total_rows: total} end)
          after
            set_replication_role!("DEFAULT")
          end
        end,
        timeout: :infinity
      )

    {:ok, stats}
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

  # Fail-CLOSED dataset-slug map (charter D8): scope the workspace's PROJECTS
  # through `Scope.scope_to_workspace/2` (where(false) on nil), then read the
  # datasets under them. Never `scope_to_workspace_or_global`.
  defp dataset_slugs_for(ws_id) do
    project_ids =
      Project
      |> Scope.scope_to_workspace(ws_id)
      |> select([p], p.id)
      |> Repo.all()

    if project_ids == [] do
      []
    else
      Dataset
      |> where([d], d.project_id in ^project_ids)
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

  # data_keys.scope = "dataset:" <> slug ; search_surface_config.scope = slug.
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

  defp import_member(%{"row_count" => 0}, _dump), do: 0

  defp import_member(entry, dump) do
    table = entry["name"]
    cols = entry["columns"]
    col_list = cols |> Enum.map(&qi/1) |> Enum.join(", ")

    case entry["import_strategy"] do
      "copy" ->
        copy_into(qi(table), col_list, dump)

      "insert_on_conflict" ->
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

  defp set_replication_role!(role) do
    Repo.query!("SET session_replication_role = #{role}", [])
  end

  # ── SQL identifier / hashing helpers ─────────────────────────────────────────

  # Double-quote an identifier (column/table name) — every name originates from
  # the live catalog, never user input; the quote-doubling is belt-and-suspenders.
  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  defp md5_hex(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
end
