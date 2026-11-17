defmodule Barkpark.Tenancy.WorkspaceBundle.ImportConfinement do
  @moduledoc """
  The rules a workspace bundle import follows when the caller is NOT a listed
  instance operator (task-1a6cde75b0adae76).

  A bundle is an uploaded tar of raw `COPY` text. Nothing in it is signed, so
  every value in it is the uploader's choice. While the operator allowlist is
  unset, any admin reaches `POST /api/workspaces/:slug/import`. Before this
  module, such an import restored the root `workspaces` row verbatim, including
  `organization_id`, and seated the importer as admin. That let a non-operator
  put a workspace into any organization: one they had just created (and then
  administer it in full), or a foreign one (whose real admins then stop
  administering every workspace in it, the rule `OrgScope` checks).

  A confined import keeps the bundle inside its own workspace:

    * **Organization and operator columns.** A NEW workspace lands in no
      organization. A workspace that already exists keeps its current
      `organization_id`, `quota`, `suspended*`, `expires_at`, `tier` and
      `archived_at`. Attaching to an organization goes only through the guarded
      attach route (`OrgSsoController`, `RequireOrgAdmin`).
    * **An existing target needs its admin.** A merge into a workspace that
      already exists (same id), or that replaces an empty same-slug shell,
      needs the importer to administer that workspace already.
    * **Seats and credentials do not travel.** `api_tokens`, `token_sessions`,
      `workspace_memberships`, `workspace_invitations` and `access_grants` rows
      are withheld and named in the result. The importer's own admin seat is
      still granted by the engine.
    * **Every row stays in the bundle's workspace.** Each row-copy member is
      staged in a temp table and checked before it is written: the root row is
      the manifest's workspace, an E1 row carries that `workspace_id`, an E2
      row's parent does not resolve to another workspace, a merge never takes
      over a row another workspace owns, and a `session_id` never names
      another workspace's chat session. A row that breaks this refuses the
      whole import (`InvalidBundleError`, 422).
    * **Shared string keys.** E3 rows (`shares`, `preview_token_jti`,
      `authoring_exemptions`) are insert-only already. A confined import keeps
      only those under a dataset slug this workspace owns alone (and, for
      `shares`, under its own `workspace_slug`); the rest are withheld.

  Table classification comes from the LIVE catalog, never from the manifest's
  own `kind`/`import_strategy` claims. A listed operator's import never enters
  this module (`WorkspaceBundle` keeps today's byte path).
  """

  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Catalog, InvalidBundleError}

  @withheld_tables ~w(access_grants api_tokens secrets secrets_audit token_sessions workspace_invitations workspace_memberships)

  # Columns an operator (or the instance) sets, never the tenant.
  @operator_columns ~w(organization_id quota suspended suspended_reason suspended_at expires_at tier archived_at)

  # Boundary FKs into `chat_sessions`, a table no bundle carries.
  @session_columns %{
    "chat_execution_leases" => "session_id",
    "chat_runtime_usage_receipts" => "session_id",
    "epic_assignment_runtime_attempts" => "session_id"
  }

  @doc "Tables whose rows a confined import never writes."
  def withheld_tables, do: @withheld_tables

  @doc "Workspace-row columns a confined import never takes from the bundle."
  def operator_columns, do: @operator_columns

  @doc "Member tables whose `session_id` points at `chat_sessions`."
  def session_columns, do: @session_columns

  @doc "The engine's `:confine` option: true when the caller is not a listed operator."
  def flag!(opts) do
    case Keyword.get(opts, :confine, false) do
      flag when is_boolean(flag) -> flag
      other -> raise ArgumentError, "invalid :confine #{inspect(other)} (expected a boolean)"
    end
  end

  @doc """
  The engine's hook before any write: `nil` for an unconfined import, else the
  state the other hooks take. Reads the catalog while every member FK exists.
  """
  def begin!(false, _manifest, _mode, _grant), do: nil
  def begin!(true, manifest, mode, grant), do: {preflight!(manifest, mode, grant), catalog()}

  @doc "The engine's per-member hook. Unconfined, it calls the engine's own `import_member/3`."
  def import!(nil, entry, dumps, mode, _manifest, import_member),
    do: import_member.(entry, Map.get(dumps, entry["name"], ""), mode)

  # `path` is the engine's own extraction path, as in `release_member/1`.
  # sobelow_skip ["Traversal.FileModule"]
  def import!({_prior, catalog}, entry, dumps, mode, manifest, _import_member) do
    dump = Map.get(dumps, entry["name"], "")
    n = import_member!(entry, dump, mode, manifest, catalog)
    with {:file, path} <- dump, do: File.rm(path)
    n
  end

  @doc """
  The engine's hook after the members landed: put the operator columns back and
  name, per table, the rows the bundle carried that were not written.
  """
  def settle!(nil, stats, _manifest), do: stats

  def settle!({prior, catalog}, stats, manifest) do
    settle_workspace_row!(manifest, prior)

    withheld =
      for %{"name" => t, "row_count" => n} <- manifest["tables"] || [],
          t in @withheld_tables or Map.get(catalog.kinds, t) == :e3,
          is_integer(n) and n > Map.get(stats.tables, t, 0),
          into: %{},
          do: {t, n - Map.get(stats.tables, t, 0)}

    Map.put(stats, :withheld, withheld)
  end

  @doc """
  Before any write. Refuses a confined import into an existing workspace the
  importer does not administer, and returns what `settle_workspace_row!/2`
  restores afterwards: `nil` for a new workspace, else the current operator
  columns.
  """
  def preflight!(manifest, mode, grant) do
    ws_id = cast_ws_id!(manifest)
    slug = manifest["workspace_slug"]

    if mode == :merge do
      case Repo.query!(
             "SELECT id::text FROM workspaces WHERE slug = $1 AND id <> $2::uuid",
             [slug, Ecto.UUID.dump!(ws_id)]
           ).rows do
        [[shell_id]] -> require_admin!(grant, shell_id, "replace")
        [] -> :ok
      end
    end

    case read_operator_columns(ws_id) do
      nil ->
        nil

      prior ->
        require_admin!(grant, ws_id, "import into")
        prior
    end
  end

  @doc "Import one member under the confined rules. Returns the rows written."
  def import_member!(%{"name" => table} = entry, dump, mode, manifest, catalog) do
    cond do
      table in @withheld_tables ->
        0

      entry["row_count"] == 0 ->
        0

      true ->
        import_checked!(table, entry, dump, mode, manifest, catalog)
    end
  end

  @doc """
  Read once per import: the live classification of every member table, and
  every foreign key from a member table to a member table.
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

  @doc """
  After every member landed: put the operator columns back. A new workspace
  lands in no organization; an existing one keeps what it had.
  """
  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query"]
  def settle_workspace_row!(manifest, nil) do
    Repo.query!("UPDATE workspaces SET organization_id = NULL WHERE id = $1::uuid", [
      Ecto.UUID.dump!(cast_ws_id!(manifest))
    ])

    :ok
  end

  # `sets` is built from the fixed @operator_columns list; values are bind params.
  # sobelow_skip ["SQL.Query"]
  def settle_workspace_row!(manifest, prior) when is_map(prior) do
    sets = Enum.map_join(Enum.with_index(@operator_columns, 2), ", ", &set_clause/1)
    values = Enum.map(@operator_columns, &Map.fetch!(prior, &1))

    Repo.query!(
      "UPDATE workspaces SET #{sets} WHERE id = $1::uuid",
      [Ecto.UUID.dump!(cast_ws_id!(manifest)) | values]
    )

    :ok
  end

  # ── Staging + checks ────────────────────────────────────────────────────────

  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query", "SQL.Stream"]
  defp import_checked!(table, entry, dump, mode, manifest, catalog) do
    kind = Map.get(catalog.kinds, table)
    ws_id = cast_ws_id!(manifest)
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
          kept = keep_own_e3_rows!(table, tmp, manifest)
          insert!(table, col_list, tmp, "ON CONFLICT DO NOTHING")
          kept

        scoped when scoped in [:root, :e1, :e2] ->
          refuse_out_of_scope!(table, tmp, scoped, ws)
          refuse_foreign_session!(table, tmp, cols, ws)
          refuse_foreign_references!(table, tmp, Map.get(catalog.fks, table, []), catalog, ws)
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

  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query"]
  defp insert!(table, col_list, tmp, suffix) do
    Repo.query!(
      "INSERT INTO #{qi(table)} (#{col_list}) SELECT #{col_list} FROM #{qi(tmp)} #{suffix}",
      []
    )
  end

  # Root: the one row is the manifest's workspace. E1: the row's own column.
  # E2: the parent the row points at must not belong to another workspace (a
  # parent that exists nowhere is the bundle format's allowed orphan).
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

  # Any foreign key of this row that names an EXISTING row of another
  # workspace (a document's dataset, an edge's target, ...). A key that names
  # nothing is the format's allowed orphan.
  defp refuse_foreign_references!(table, tmp, fks, catalog, ws) do
    Enum.each(fks, fn %{cols: cols, parent: parent, pcols: pcols} ->
      match =
        Enum.zip(pcols, cols)
        |> Enum.map_join(" AND ", fn {pc, c} -> "t.#{qi(pc)} = s.#{qi(c)}" end)

      # `t` is the PARENT row here (the E2 join specs name it so); `s` is the
      # staged child row.
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

  # E3 rows keep only this workspace's own dataset slugs; the rest are deleted
  # from the staging table, so they are never written.
  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query"]
  defp keep_own_e3_rows!(table, tmp, manifest) do
    ws_id = cast_ws_id!(manifest)
    own = Catalog.text_array_literal(WorkspaceBundle.dataset_slugs_for(ws_id))

    slug_guard =
      case Map.get(Catalog.e3_dataset_workspace_slug_column(), table) do
        nil ->
          ""

        col ->
          " OR t.#{qi(col)} IS DISTINCT FROM #{Catalog.text_literal(manifest_slug!(manifest))}"
      end

    Repo.query!(
      "DELETE FROM #{qi(tmp)} t WHERE NOT COALESCE(t.dataset = ANY(#{own}), false)#{slug_guard}",
      []
    )

    count(tmp)
  end

  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query"]
  defp refuse_if!(table, sql, what) do
    case Repo.query!(sql, []).rows do
      [[0]] -> :ok
      [[n]] -> refuse!(table, "carries #{n} row(s) outside the bundle's workspace (#{what})")
    end
  end

  defp refuse!(table, why) do
    raise InvalidBundleError,
      code: "invalid_bundle",
      message:
        "bundle member #{inspect(table)} #{why}. An import by a caller who is not a " <>
          "listed instance operator writes only into the bundle's own workspace."
  end

  @copy_chunk_bytes 65_536
  # `path` is the engine's own extraction path (Archive.unpack_to_dir/2), never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_source({:file, path}), do: File.stream!(path, @copy_chunk_bytes)
  defp copy_source(dump) when is_binary(dump), do: [dump]

  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query"]
  defp count(tmp), do: Repo.query!("SELECT count(*) FROM #{qi(tmp)}", []).rows |> hd() |> hd()

  # ── Workspace row ───────────────────────────────────────────────────────────

  # Identifiers are qi/1-quoted catalog or manifest names behind the member-table
  # check; values are a validated UUID literal or bind params. COPY data never enters SQL.
  # sobelow_skip ["SQL.Query"]
  defp read_operator_columns(ws_id) do
    cols = Enum.map_join(@operator_columns, ", ", &qi/1)

    case Repo.query!("SELECT #{cols} FROM workspaces WHERE id = $1::uuid", [
           Ecto.UUID.dump!(ws_id)
         ]) do
      %{rows: [row]} -> Map.new(Enum.zip(@operator_columns, row))
      %{rows: []} -> nil
    end
  end

  defp set_clause({col, i}), do: "#{qi(col)} = $#{i}"

  defp require_admin!(nil, ws_id, verb), do: refuse_target!(ws_id, verb)

  defp require_admin!({principal_id, principal_type}, ws_id, verb) do
    kind = if principal_type == "user", do: :user, else: :api_token

    case TenancyAuth.membership(principal_id, ws_id, kind) do
      %Membership{role: role} when role in ["owner", "admin"] -> :ok
      _ -> refuse_target!(ws_id, verb)
    end
  end

  defp refuse_target!(ws_id, verb) do
    raise InvalidBundleError,
      code: "invalid_bundle",
      message:
        "this bundle would #{verb} existing workspace #{ws_id}, which the caller does not " <>
          "administer. Only its admins, or a listed instance operator, may do that."
  end

  defp cast_ws_id!(manifest) do
    case Ecto.UUID.cast(manifest["workspace_id"]) do
      {:ok, id} -> id
      :error -> refuse!("workspaces", "names no valid workspace_id in its manifest")
    end
  end

  defp manifest_slug!(manifest) do
    case manifest["workspace_slug"] do
      slug when is_binary(slug) -> slug
      _ -> refuse!("workspaces", "names no workspace_slug in its manifest")
    end
  end

  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")
end
