defmodule Barkpark.Tenancy.WorkspaceBundle.ImportConfinement.Rows do
  @moduledoc """
  The row half of `Barkpark.Tenancy.WorkspaceBundle.ImportConfinement`: each
  row-copy member of a confined import is staged in a temp table, checked, then
  written. These checks hold in every mode.

    * Root: the one `workspaces` row is the manifest's workspace.
    * E1: every row carries the manifest's `workspace_id`.
    * E2: the parent a row points at does not belong to another workspace.
    * Any foreign key (live `pg_constraint`) from a member row to a member table
      names no EXISTING row of another workspace. A key naming nothing is the
      bundle format's allowed orphan.
    * Merge: an `ON CONFLICT` key never names another workspace's row.
    * `session_id` (into `chat_sessions`, which no bundle carries) never names
      another workspace's session.

  A row that breaks one refuses the whole import (`InvalidBundleError`, 422).

  E3 members (bare `dataset` slug keys) keep only rows under a slug this
  workspace owns alone, and for `shares` its own `workspace_slug`. Rows that
  name a user (`@user_rows`) are dropped from the staging table. Neither is a
  refusal: those rows are simply not written, and the engine counts them as
  withheld.

  Classification comes from the live catalog, never from the manifest's own
  `kind` / `import_strategy` claims.
  """

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Catalog, InvalidBundleError}

  # Rows that would let the bundle speak for a user outside it: a token that
  # acts as its owner, a seat that skips the invitation step.
  @user_rows %{
    "api_tokens" => "t.owner_user_id IS NOT NULL",
    "workspace_memberships" => "t.principal_type = 'user'"
  }

  # Boundary FKs into `chat_sessions`, a table no bundle carries.
  @session_columns %{
    "chat_execution_leases" => "session_id",
    "chat_runtime_usage_receipts" => "session_id",
    "epic_assignment_runtime_attempts" => "session_id"
  }

  @copy_chunk_bytes 65_536

  @doc "Tables whose user-naming rows are never written, with the row predicate."
  def user_rows, do: @user_rows

  @doc "Member tables whose `session_id` points at `chat_sessions`."
  def session_columns, do: @session_columns

  @doc """
  The live classification of every member table, and every foreign key from a
  member table to a member table. Read once per import, before the engine drops
  the member FKs.
  """
  def catalog do
    kinds =
      Map.new(Catalog.live_e1(Repo), &{&1, :e1})
      |> Map.merge(Map.new(Map.keys(Catalog.e2_joins()), &{&1, :e2}))
      |> Map.merge(Map.new(Catalog.live_e3(Repo), &{&1, :e3}))
      |> Map.put(Catalog.root_table(), :root)

    fks =
      Enum.filter(member_fks(), fn fk ->
        Map.has_key?(kinds, fk.child) and Map.get(kinds, fk.parent) in [:root, :e1, :e2]
      end)

    %{kinds: kinds, fks: Enum.group_by(fks, & &1.child)}
  end

  @doc "Every foreign key in the public schema, as child/parent table and column lists."
  def member_fks do
    Repo.query!(
      """
      SELECT cl.relname, pl.relname,
             ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY k(n, o)
                   JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.o),
             ARRAY(SELECT a.attname FROM unnest(c.confkey) WITH ORDINALITY k(n, o)
                   JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n ORDER BY k.o)
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_class pl ON pl.oid = c.confrelid
      JOIN pg_namespace ns ON ns.oid = cl.relnamespace
      WHERE c.contype = 'f' AND ns.nspname = 'public'
      ORDER BY 1, 2
      """,
      []
    ).rows
    |> Enum.map(fn [child, parent, cols, pcols] ->
      %{child: child, parent: parent, cols: cols, pcols: pcols}
    end)
  end

  @doc "Stage, check and write one member. Returns the rows written."
  # Identifiers are qi/1-quoted catalog or manifest names behind the engine's
  # member-table check; values are a validated UUID literal. COPY data never
  # enters SQL.
  # sobelow_skip ["SQL.Query", "SQL.Stream"]
  def import_member!(%{"name" => table} = entry, dump, mode, manifest, catalog) do
    kind = Map.get(catalog.kinds, table)
    ws_id = ws_id!(manifest)
    cols = entry["columns"] || []
    col_list = Enum.map_join(cols, ", ", &qi/1)
    tmp = "_bp_conf_#{:erlang.unique_integer([:positive])}"

    Repo.query!(
      "CREATE TEMP TABLE #{qi(tmp)} (LIKE #{qi(table)} INCLUDING DEFAULTS) ON COMMIT DROP",
      []
    )

    stream = Ecto.Adapters.SQL.stream(Repo, "COPY #{qi(tmp)} (#{col_list}) FROM STDIN", [])
    Enum.into(copy_source(dump), stream)

    ws = Catalog.uuid_literal!(ws_id)

    written =
      case kind do
        :e3 ->
          keep_own_e3_rows!(table, tmp, manifest)
          insert!(table, col_list, tmp, "ON CONFLICT DO NOTHING")
          count(tmp)

        scoped when scoped in [:root, :e1, :e2] ->
          refuse_out_of_scope!(table, tmp, scoped, ws)
          refuse_foreign_session!(table, tmp, cols, ws)
          refuse_foreign_references!(table, tmp, Map.get(catalog.fks, table, []), catalog, ws)
          drop_user_rows!(table, tmp, cols)
          write_scoped!(table, col_list, cols, tmp, mode, scoped, ws)
          count(tmp)

        nil ->
          refuse!(table, "is not a member table of a workspace bundle on this instance")
      end

    Repo.query!("DROP TABLE #{qi(tmp)}", [])
    written
  end

  defp write_scoped!(table, col_list, _cols, tmp, :clean, _kind, _ws),
    do: insert!(table, col_list, tmp, "")

  defp write_scoped!(table, col_list, cols, tmp, :merge, kind, ws) do
    keys = Catalog.order_columns(Repo, table)
    refuse_takeover!(table, tmp, keys, kind, ws)

    action =
      case cols -- keys do
        [] -> "DO NOTHING"
        upd -> "DO UPDATE SET " <> Enum.map_join(upd, ", ", &"#{qi(&1)} = EXCLUDED.#{qi(&1)}")
      end

    insert!(table, col_list, tmp, "ON CONFLICT (#{Enum.map_join(keys, ", ", &qi/1)}) #{action}")
  end

  # See import_member!/5: quoted identifiers only.
  # sobelow_skip ["SQL.Query"]
  defp insert!(table, col_list, tmp, suffix) do
    Repo.query!(
      "INSERT INTO #{qi(table)} (#{col_list}) SELECT #{col_list} FROM #{qi(tmp)} #{suffix}",
      []
    )
  end

  defp refuse_out_of_scope!(table, tmp, :root, ws),
    do: refuse_if!(table, "SELECT count(*) FROM #{qi(tmp)} t WHERE t.id <> #{ws}", "root")

  defp refuse_out_of_scope!(table, tmp, :e1, ws) do
    sql = "SELECT count(*) FROM #{qi(tmp)} t WHERE t.workspace_id IS DISTINCT FROM #{ws}"
    refuse_if!(table, sql, "workspace_id")
  end

  defp refuse_out_of_scope!(table, tmp, :e2, ws) do
    {join, ws_col} = Map.fetch!(Catalog.e2_joins(), table)
    sql = "SELECT count(*) FROM #{qi(tmp)} t #{join} WHERE #{ws_col} IS DISTINCT FROM #{ws}"
    refuse_if!(table, sql, "parent row")
  end

  # Merge: a staged key that already names a row of ANOTHER workspace would
  # be rewritten into this one by DO UPDATE.
  defp refuse_takeover!(table, tmp, keys, kind, ws) do
    using = "USING (#{Enum.map_join(keys, ", ", &qi/1)})"

    sql =
      case kind do
        :root ->
          "SELECT 0"

        :e1 ->
          "SELECT count(*) FROM #{qi(table)} t JOIN #{qi(tmp)} s #{using} " <>
            "WHERE t.workspace_id IS DISTINCT FROM #{ws}"

        :e2 ->
          {join, ws_col} = Map.fetch!(Catalog.e2_joins(), table)

          "SELECT count(*) FROM #{qi(table)} t JOIN #{qi(tmp)} s #{using} #{join} " <>
            "WHERE #{ws_col} IS DISTINCT FROM #{ws}"
      end

    refuse_if!(table, sql, "existing row of another workspace")
  end

  # `t` is the PARENT row (the E2 join specs name it so); `s` the staged child.
  defp refuse_foreign_references!(table, tmp, fks, catalog, ws) do
    Enum.each(fks, fn %{cols: cols, parent: parent, pcols: pcols} ->
      match =
        Enum.zip(pcols, cols)
        |> Enum.map_join(" AND ", fn {pc, c} -> "t.#{qi(pc)} = s.#{qi(c)}" end)

      foreign =
        case Map.fetch!(catalog.kinds, parent) do
          :root ->
            "SELECT 1 FROM workspaces t WHERE #{match} AND t.id <> #{ws}"

          :e1 ->
            "SELECT 1 FROM #{qi(parent)} t WHERE #{match} " <>
              "AND t.workspace_id IS DISTINCT FROM #{ws}"

          :e2 ->
            {join, ws_col} = Map.fetch!(Catalog.e2_joins(), parent)

            "SELECT 1 FROM #{qi(parent)} t #{join} WHERE #{match} " <>
              "AND #{ws_col} IS DISTINCT FROM #{ws}"
        end

      sql = "SELECT count(*) FROM #{qi(tmp)} s WHERE EXISTS (#{foreign})"
      refuse_if!(table, sql, "#{Enum.join(cols, ", ")} -> #{parent}")
    end)
  end

  defp refuse_foreign_session!(table, tmp, cols, ws) do
    with col when is_binary(col) <- Map.get(@session_columns, table),
         true <- col in cols do
      sql =
        "SELECT count(*) FROM #{qi(tmp)} t JOIN chat_sessions cs ON cs.id = t.#{qi(col)} " <>
          "WHERE cs.owner_workspace_id IS DISTINCT FROM #{ws}"

      refuse_if!(table, sql, "chat session")
    end
  end

  defp drop_user_rows!(table, tmp, cols) do
    case Map.get(@user_rows, table) do
      nil -> :ok
      where -> if user_column(table) in cols, do: delete!(tmp, where)
    end
  end

  defp user_column("api_tokens"), do: "owner_user_id"
  defp user_column("workspace_memberships"), do: "principal_type"

  # sobelow_skip ["SQL.Query"]
  defp delete!(tmp, where), do: Repo.query!("DELETE FROM #{qi(tmp)} t WHERE #{where}", [])

  # E3 rows keep only this workspace's own dataset slugs.
  defp keep_own_e3_rows!(table, tmp, manifest) do
    own = Catalog.text_array_literal(WorkspaceBundle.dataset_slugs_for(ws_id!(manifest)))

    slug_guard =
      case Map.get(Catalog.e3_dataset_workspace_slug_column(), table) do
        nil ->
          ""

        col ->
          " OR t.#{qi(col)} IS DISTINCT FROM #{Catalog.text_literal(slug!(manifest))}"
      end

    delete!(tmp, "NOT COALESCE(t.dataset = ANY(#{own}), false)#{slug_guard}")
  end

  # sobelow_skip ["SQL.Query"]
  defp refuse_if!(table, sql, what) do
    case Repo.query!(sql, []).rows do
      [[0]] -> :ok
      [[n]] -> refuse!(table, "carries #{n} row(s) outside the bundle's workspace (#{what})")
    end
  end

  @doc false
  def refuse!(table, why) do
    raise InvalidBundleError,
      code: "invalid_bundle",
      message:
        "bundle member #{inspect(table)} #{why}. An import by a caller who is not a " <>
          "listed instance operator writes only into the bundle's own workspace."
  end

  # `path` is the engine's own extraction path (Archive.unpack_to_dir/2).
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_source({:file, path}), do: File.stream!(path, @copy_chunk_bytes)
  defp copy_source(dump) when is_binary(dump), do: [dump]

  # sobelow_skip ["SQL.Query"]
  defp count(tmp), do: Repo.query!("SELECT count(*) FROM #{qi(tmp)}", []).rows |> hd() |> hd()

  @doc false
  def ws_id!(manifest) do
    case Ecto.UUID.cast(manifest["workspace_id"]) do
      {:ok, id} -> id
      :error -> refuse!("workspaces", "names no valid workspace_id in its manifest")
    end
  end

  defp slug!(manifest) do
    case manifest["workspace_slug"] do
      slug when is_binary(slug) -> slug
      _ -> refuse!("workspaces", "names no workspace_slug in its manifest")
    end
  end

  @doc false
  def qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")
end
