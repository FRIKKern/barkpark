defmodule Barkpark.Tenancy.WorkspaceBundle.ExportScopeError do
  @moduledoc """
  A `profile` / `dataset` export option the engine REFUSES to guess at.

  Raised — never silently coerced — because every one of these is a scope
  mistake whose silent resolution would produce a WRONG bundle: an unknown
  profile would fall back to the full-fidelity secret-carrying dump, an
  unknown dataset slug would export the empty set, and an AMBIGUOUS slug (two
  projects of the SAME workspace owning it) has no defensible pick at all
  (PDS-D29). `code` is a stable, machine-branchable reason:

    * `"invalid_profile"`       — not `:full` / `:dev`
    * `"invalid_dataset"`       — not a slug string
    * `"dataset_not_found"`     — no dataset with that slug under the workspace
    * `"ambiguous_dataset_slug"` — more than one, across sibling projects
  """
  defexception [:code, :message]

  @type t :: %__MODULE__{code: String.t(), message: String.t()}
end

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

  ## Export profiles + dataset grain (PDS-D3/D4/D5/D7 · D27/D28/D29/D31)

  `export/2` takes two scope opts, both defaulting to today's behavior so the
  full-fidelity backup path is BYTE-IDENTICAL to before (the md5-parity suite
  plus an explicit omitted-vs-`:full` equality assertion are the tripwires):

    * `:profile` — `:full` (default) carries every reachable table verbatim;
      `:dev` carries only the reviewed `Catalog.dev_partition/0` `:copy` set.
      The deny is a SKIP, not a post-filter (PDS-D31): denied tables are
      dropped from the spec list BEFORE the COPY loop, so their bytes are
      never queried, never materialized, and never enter the artifact — which
      is what keeps a dev pull at ~50 MB / low-hundreds-of-MB beam RSS instead
      of the ~1.9 GB peak a full guerrilla export measures.
    * `:dataset` — a dataset SLUG. Group-A tables (the dual dataset-column
      family) narrow on the canonical `dataset_id`, never the string mirror;
      the triad roots always travel (the workspace row, its OWNING project,
      the target dataset row); Group-C (workspace-only, no dataset grain)
      travels workspace-whole because there is no row-level grain to fake.

  Two dev-profile subtleties, each of which a run refuted the naive version of:

    * the documents type-deny is read from `Catalog.dev_doc_type_deny/0`, NOT
      from `dev_action/1` — which deliberately flattens
      `{:copy, deny_types: [...]}` to a bare `:copy` (PDS-D28), so an exporter
      driven off `dev_action/1` alone would ship every denied type; and
    * it CASCADES (PDS-D27): every FK column pointing at `documents.id` is
      derived LIVE and the child row is excluded when its document is denied,
      because `copy_where/3`'s doc semi-join and the E2 parent-joins are all
      type-BLIND — a denied ticket's `content_edges` / `task_edges` /
      `plugin_doc_state` rows would otherwise travel as FK-violating orphans.

  The dataset arbiter deliberately does NOT resolve through
  `dataset_slugs_for/1` (PDS-D29): that helper drops any slug a sibling
  workspace also owns, so on a real host it selects the EMPTY SET for the very
  dataset being pulled. It resolves datasets → projects → workspace instead and
  raises `ExportScopeError` on ambiguity. The E3 dataset-keyed members, whose
  bare slug is genuinely unattributable, keep going through
  `dataset_slugs_for/1` and INTERSECT it with the target slug — a shared slug
  therefore yields the empty set, fail-closed.

  ## Import (charter D7 · PDS-D8/D9 · task-7889645a51769a36)

  The import needs NO superuser privilege. It used to run under
  `SET session_replication_role = replica` — a superuser-only parameter, which
  500'd (Postgrex 42501 insufficient_privilege) on every managed box, where the
  app's DB role is the table OWNER but not superuser (`deploy.sh`:
  `CREATE USER … CREATEDB` + `createdb -O`). CI never caught it because CI's
  `postgres` role IS superuser — privilege parity, not state, was the missing
  model. What the replica role was actually buying, and its owner-privilege
  replacement:

    * **FK suppression** — the manifest lists members root → E1 → E2 → E3,
      each partition ALPHABETICAL (`Catalog.live_e*` `ORDER BY table_name`),
      which is not a dependency order (`documents` (E1) precedes its FK
      parents `projects` (E1, later alphabetically) and `datasets` (E2, later
      partition)) — and, more fundamentally, the FORMAT deliberately permits
      rows whose FK target travels in no bundle at all: a dataset-grained
      pull ships Group-C tables (`content_edges` / `task_edges` /
      `plugin_doc_state`, no dataset grain) workspace-WHOLE while `documents`
      is narrowed, so an edge into another dataset lands as a recoverable
      orphan by design (PDS-D7); and five boundary FKs point at tables no
      bundle carries (`workspaces.organization_id` → `organizations`;
      `api_tokens.owner_user_id` → `users`; `chat_execution_leases` /
      `chat_runtime_usage_receipts` / `epic_assignment_runtime_attempts`
      `.session_id` → `chat_sessions`). Ordering therefore cannot save FK
      enforcement — dangling is contractual. So every FK constraint whose
      CHILD is a member table (derived live from `pg_constraint`) is DROPPED
      at the start of the transaction and re-added `NOT VALID` at the end —
      owner-privilege DDL, fully rolled back on failure. `NOT VALID` is the
      honest state: imported rows may dangle (they always could — the replica
      role merely skipped the check while leaving the constraint marked
      valid), future writes stay enforced, and an operator can
      `VALIDATE CONSTRAINT` any of them after cleaning orphans.
    * **User triggers** — the ledger tables carry immutability triggers
      (`*_no_update_delete`, `revisions_immutable`, release-gate `*_immutable`:
      BEFORE UPDATE OR DELETE, raise) that would abort the merge upsert's
      `DO UPDATE` on any resident row, BEFORE INSERT/UPDATE validation triggers
      that re-judge already-validated source rows against target-local state,
      and DEFERRABLE CONSTRAINT triggers (release-gate validation) that would
      fire at commit. `ALTER TABLE … DISABLE TRIGGER USER` (ownership, not
      superuser) suppresses exactly the same set the replica role did (no
      trigger in this schema is `ENABLE ALWAYS`/`ENABLE REPLICA`); internally
      generated FK triggers are outside `USER` by definition — those are
      handled by the constraint drop above. Constraint-trigger events are
      queued at statement time, so re-enabling before commit resurrects
      nothing.

  All of this DDL lives INSIDE the import transaction: on any member failure
  the rollback restores every constraint and trigger state, and the original
  exception propagates untouched (the old `after`-clause role reset used to
  swallow it as a 25P02 — that blindfold class is gone with the `after` clause,
  task-63a199c0a0ce2a06).

  Two modes:

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
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog, ExportScopeError, InvalidBundleError}

  @type stats :: %{
          tables: %{optional(String.t()) => non_neg_integer()},
          total_rows: non_neg_integer(),
          manifest: map()
        }

  @doc """
  Export a workspace to a bp-export-v1 bundle binary.

  Returns `{:ok, bundle}` (a tar binary), `{:error, :workspace_id_required}`
  when the id is missing / not a UUID (fail-closed — never a nil-scoped
  all-tenant read), or `{:error, :workspace_not_found}`.

  ## Options (all optional; omitting every one reproduces today's bundle byte
  for byte)

    * `:profile` — `:full` (default) | `:dev` (`"full"` / `"dev"` accepted so a
      controller can pass a query param straight through).
    * `:dataset` — a dataset SLUG to narrow the bundle to.
    * `:source_server` — provenance passthrough stamped into the manifest (the
      pull CLI supplies it; `nil` is fine).

  An unknown profile, an unknown dataset slug, or a slug owned by TWO sibling
  projects of the same workspace raises `ExportScopeError` — a scope mistake is
  never silently resolved into a wrong bundle.

  MEMORY (PDS-D205): this entry point reads the finished tar back into ONE
  full-size binary, so it costs the bundle's size in RAM. That contract is kept
  deliberately — it is what the whole md5-parity fidelity suite is written
  against, and after this slice `export/2` has NO non-test caller in `lib`: the
  HTTP edge moved to `export_to_file/2`, which never materializes the bundle.
  The binary entry point is kept solely so the fidelity suite keeps its
  `{:ok, binary()}` contract.
  """
  @spec export(binary() | nil, keyword()) ::
          {:ok, binary()} | {:error, :workspace_id_required | :workspace_not_found}
  # @canonical capability:workspace-bundle aka:export_workspace,import_workspace,tenant_bundle,per_workspace_export doc:.claude/workflows/bp-cloud-build-charter.md
  # File.read!/File.rm act on `path`, the engine-chosen temp tar from
  # export_to_file/2 (bp-ws-bundle-<int>.tar under the fetch_env! spill dir);
  # no request input reaches it. PR #5083 security review.
  # sobelow_skip ["Traversal.FileModule"]
  def export(workspace_id, opts \\ []) do
    case export_to_file(workspace_id, opts) do
      {:ok, path} ->
        try do
          {:ok, File.read!(path)}
        after
          File.rm(path)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Export a workspace to a bp-export-v1 bundle ON DISK, returning `{:ok, path}`.

  Same options, same errors, same BYTES as `export/2` — the difference is that
  the tar is never held in memory. Peak RAM is one COPY chunk (the producer
  streams each table straight to a spill file) and `:erl_tar` reads each spill
  back in bounded 64 KiB chunks, so a 941 MB bundle costs kilobytes rather than
  four stacked full-size materializations of itself.

  THE CALLER OWNS THE FILE and must delete it — `try/after File.rm(path)` around
  whatever consumes it. `Barkpark.Media`-style long-lived storage this is not:
  the path is a per-request temp tar.
  """
  @spec export_to_file(binary() | nil, keyword()) ::
          {:ok, Path.t()} | {:error, :workspace_id_required | :workspace_not_found}
  def export_to_file(workspace_id, opts \\ [])

  def export_to_file(workspace_id, opts) when is_binary(workspace_id) do
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

  def export_to_file(_nil_or_other, _opts), do: {:error, :workspace_id_required}

  @doc """
  Re-import a bundle binary. Returns `{:ok, stats}` where `stats.manifest` is
  the bundle's own manifest (so the caller can stamp pull provenance without
  re-inflating the tar) and `stats.tables` maps
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

    # A readable tar whose manifest names a DIFFERENT format is a caller
    # mistake, not an engine fault — InvalidBundleError so the HTTP edge
    # answers 422 invalid_bundle instead of the opaque 500 the old
    # ArgumentError produced (task-96d8ab2b582818a4).
    if manifest["format"] != Archive.format() do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message: "not a #{Archive.format()} bundle: format=#{inspect(manifest["format"])}"
    end

    # Test-only fault seam (mirrors :export_copy_fault): when configured, the
    # import RETURNS the given {:error, term} after the real unpack + format
    # check, so the HTTP edge's unmatched-term contract (named, logged 500
    # import_failed — task-96d8ab2b582818a4) is provable over the wire without
    # mocking the engine. `nil` in every non-test env.
    case Application.get_env(:barkpark, :import_fault) do
      {:error, _term} = fault -> fault
      nil -> run_import(manifest, dumps, mode)
    end
  end

  defp run_import(manifest, dumps, mode) do
    Repo.transaction(
      fn ->
        # FIRST: drain the deferred-trigger queue, or the DDL below cannot run.
        # The epic-ledger FKs into `documents` are DEFERRABLE INITIALLY
        # DEFERRED (20260715001200/1300), so any earlier delete of documents in
        # THIS transaction (the ExUnit sandbox wraps a whole test in one — its
        # seeding/teardown queues exactly this; live-proven by CI as
        # `ERROR 55006 (object_in_use) cannot ALTER TABLE "documents" because
        # it has pending trigger events`, and in prod the adopt-shell delete
        # below can queue the same class) leaves referenced-side RI events
        # pending until COMMIT, and Postgres refuses ALTER TABLE on any table
        # with pending events. Forcing IMMEDIATE fires them NOW — outcome-
        # equivalent (they would have fired at commit; a violation surfaces
        # earlier, never differently) — and makes events queued later in this
        # transaction fire at their own statement's end, so the queue is empty
        # at every DDL point. Transaction-scoped; no privilege required.
        Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [])

        # PDS-D9 pre-flight runs FIRST among the import's own writes, before
        # any trigger/constraint DDL, so the empty-shell delete's FK cascades
        # AND teardown triggers (workspaces_teardown_cycle_ledger) fire with
        # everything live.
        if mode == :merge, do: adopt_or_refuse_root_slug!(manifest)

        # Only tables that exist on the target participate in the DDL passes;
        # a manifest member the target schema lacks behaves as before — a
        # 0-row member is skipped silently, a row-carrying one fails on its
        # own COPY (cross-version bundles).
        live =
          manifest["tables"]
          |> Enum.map(& &1["name"])
          |> Enum.filter(&table_exists?/1)

        # No try/after: every statement below runs inside THIS transaction, so
        # a member failure rolls back the DDL together with the data and the
        # ORIGINAL exception propagates untouched (no after-clause exists to
        # replace it with a 25P02 — the blindfold class of
        # task-63a199c0a0ce2a06 cannot recur).
        member_fks = drop_member_fks!(live)
        alter_user_triggers!(live, "DISABLE")

        stats =
          manifest["tables"]
          |> Enum.reduce({%{}, 0}, fn entry, {acc, total} ->
            n = import_member(entry, Map.get(dumps, entry["name"], ""), mode)
            {Map.put(acc, entry["name"], n), total + n}
          end)
          |> then(fn {tables, total} ->
            # The manifest rides back out so the caller can stamp pull
            # provenance without unpacking (and re-inflating) the tar twice.
            %{tables: tables, total_rows: total, manifest: manifest}
          end)

        alter_user_triggers!(live, "ENABLE")
        restore_member_fks!(member_fks)

        stats
      end,
      timeout: :infinity
    )
  end

  # ── Owner-privilege import mechanics (task-7889645a51769a36) ─────────────────
  #
  # See the moduledoc §Import for why each of these exists. Everything here is
  # owner-privilege DDL/catalog reads — nothing requires superuser, which is
  # the entire point: managed boxes run the app role as table owner WITHOUT
  # superuser, and `SET session_replication_role` 42501'd there on every
  # merge-import while superuser-role CI stayed green.

  # Every FK constraint whose CHILD is a member table, derived live from
  # pg_constraint (like the catalog's E2 walk). Dropped for the transaction and
  # re-added NOT VALID by restore_member_fks!/1: the bundle format contractually
  # permits rows whose FK target is absent on the target (PDS-D7 dataset-grain
  # orphans; boundary references into organizations/users/chat_sessions), so
  # enforcement during the load — in ANY member order — would abort legitimate
  # bundles. Byte-fidelity is preserved (no row is scrubbed or skipped), future
  # writes stay enforced, and the constraint's validity flag stops overstating
  # what the data guarantees. FKs pointing INTO member tables from outside are
  # untouched — the import never deletes parents nor updates arbiter keys, so
  # they cannot fire. Returns what to restore.
  #
  # Interpolated identifiers: `table`/`conname` come from pg_constraint for
  # tables named by an admin-gated bundle manifest, quoted via qi/1;
  # `defn` is pg_get_constraintdef output. No request-shaped input reaches
  # the SQL string — same posture as copy_into/merge_upsert below.
  # sobelow_skip ["SQL.Query"]
  defp drop_member_fks!(names) do
    member_fks =
      Repo.query!(
        """
        SELECT cl.relname, c.conname, pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        JOIN pg_class cl ON cl.oid = c.conrelid
        JOIN pg_namespace cn ON cn.oid = cl.relnamespace
        WHERE c.contype = 'f'
          AND cn.nspname = 'public'
          AND cl.relname = ANY($1)
        ORDER BY cl.relname, c.conname
        """,
        [names]
      ).rows

    Enum.each(member_fks, fn [table, conname, _defn] ->
      Repo.query!("ALTER TABLE public.#{qi(table)} DROP CONSTRAINT #{qi(conname)}", [])
    end)

    member_fks
  end

  # Identifiers/defn straight from pg_constraint / pg_get_constraintdef (see
  # drop_member_fks! above) — never request input.
  # sobelow_skip ["SQL.Query"]
  defp restore_member_fks!(member_fks) do
    Enum.each(member_fks, fn [table, conname, defn] ->
      # An already-NOT VALID definition must not double the suffix.
      base = String.replace_suffix(defn, " NOT VALID", "")

      Repo.query!(
        "ALTER TABLE public.#{qi(table)} ADD CONSTRAINT #{qi(conname)} #{base} NOT VALID",
        []
      )
    end)
  end

  # DISABLE/ENABLE TRIGGER USER on every member table — ownership-privilege,
  # and USER cannot touch internally generated FK triggers (those are handled
  # by the constraint drop above). Alphabetical for a deterministic
  # lock-acquisition order. `table` is manifest-named + existence-checked and
  # qi/1-quoted; `action` is guard-pinned to two literals — no request input.
  # sobelow_skip ["SQL.Query"]
  defp alter_user_triggers!(names, action) when action in ["DISABLE", "ENABLE"] do
    Enum.each(Enum.sort(names), fn table ->
      Repo.query!("ALTER TABLE public.#{qi(table)} #{action} TRIGGER USER", [])
    end)
  end

  defp table_exists?(table) do
    Repo.query!(
      "SELECT 1 FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace " <>
        "WHERE n.nspname = 'public' AND cl.relname = $1 AND cl.relkind = 'r'",
      [table]
    ).rows != []
  end

  # ── Export ───────────────────────────────────────────────────────────────────

  # Belt-and-braces File.rm sweeps `spills`, engine-built paths from
  # Archive.spill_path (bp-ws-spill-<table>-<int>.copy, fetch_env! spill dir);
  # `table` is catalog-derived (Catalog.live_e*), never request input.
  # PR #5083 security review.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_export(%Workspace{} = ws, opts) do
    profile = normalize_profile!(Keyword.get(opts, :profile))
    target = resolve_dataset!(ws, Keyword.get(opts, :dataset))

    dataset_slugs = narrow_slugs(dataset_slugs_for(ws.id), target)
    ctx = export_ctx(ws, dataset_slugs, profile, target)

    specs =
      ([{Catalog.root_table(), "root", :root}] ++
         Enum.map(Catalog.live_e1(Repo), &{&1, "E1", :e1}) ++
         Enum.map(Catalog.live_e2(Repo), &{&1, "E2", :e2}) ++
         Enum.map(Catalog.live_e3(Repo), &{&1, "E3", e3_kind(&1)}) ++
         Enum.map(Map.keys(Catalog.allowlist()), &{&1, "allowlist", :allowlist}))
      # PDS-D31: the profile deny is applied HERE, before the COPY loop — a
      # denied table is never queried and its bytes never materialize.
      |> reject_denied_tables(profile)

    dir = Archive.spill_dir()

    # Every spill path is computed UP FRONT so the `after` clause below can
    # clean up whatever the reduce created before it died — a reduce
    # accumulator is not in scope from `after`, and a half-finished export must
    # never strand hundreds of MB per table.
    spills =
      Map.new(specs, fn {table, _partition, _kind} -> {table, Archive.spill_path(dir, table)} end)

    try do
      {members, files} =
        Enum.reduce(specs, {[], %{}}, fn {table, partition, kind}, {members, files} ->
          cols = Catalog.non_generated_columns(Repo, table)
          order_cols = Catalog.order_columns(Repo, table)
          sql = copy_out_sql(table, kind, cols, order_cols, ctx)
          spill = Map.fetch!(spills, table)
          {row_count, md5} = run_copy_out(sql, spill)

          member = %{
            "name" => table,
            "partition" => partition,
            "import_strategy" => import_strategy(kind),
            "columns" => cols,
            "order_columns" => order_cols,
            "row_count" => row_count,
            "md5" => md5
          }

          {[member | members], Map.put(files, table, spill)}
        end)

      # PDS-D3: `format` stays EXACTLY bp-export-v1 (import's hard equality check
      # is the compatibility contract); everything new is an ADDITIVE key an old
      # consumer ignores.
      manifest = %{
        "format" => Archive.format(),
        "grain" => Archive.grain(),
        "workspace_id" => ws.id,
        "workspace_slug" => ws.slug,
        "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "dataset_slugs" => dataset_slugs,
        "profile" => Atom.to_string(profile),
        "dataset" => target && target.slug,
        "source_workspace" => ws.slug,
        "source_dataset" => target && target.slug,
        "source_server" => Keyword.get(opts, :source_server),
        "tables" => Enum.reverse(members)
      }

      Archive.pack(manifest, files, dir: dir)
    after
      # Belt and braces: `Archive.pack/3` already deletes each spill the moment
      # it is added, so on the happy path every one of these is a no-op enoent.
      Enum.each(Map.values(spills), &File.rm/1)
    end
  end

  # ── Profile + dataset scope resolution (PDS-D28/D29) ─────────────────────────

  defp normalize_profile!(nil), do: :full
  defp normalize_profile!(profile) when profile in [:full, :dev], do: profile
  defp normalize_profile!(""), do: :full
  defp normalize_profile!("full"), do: :full
  defp normalize_profile!("dev"), do: :dev

  defp normalize_profile!(other) do
    raise ExportScopeError,
      code: "invalid_profile",
      message: "unknown export profile #{inspect(other)} (expected :full or :dev)"
  end

  # PDS-D29: resolve datasets → projects → workspace. NEVER through
  # `dataset_slugs_for/1`, which project-qualifies a slug OUT the moment a
  # sibling workspace owns it too — on a real host that selects the empty set
  # for the very dataset being pulled (guerrilla's manifest omits "production"
  # for exactly this reason).
  defp resolve_dataset!(_ws, nil), do: nil
  defp resolve_dataset!(_ws, ""), do: nil

  defp resolve_dataset!(%Workspace{} = ws, slug) when is_binary(slug) do
    matches =
      Dataset
      |> join(:inner, [d], p in Project, on: p.id == d.project_id)
      |> where([d, p], p.workspace_id == ^ws.id and d.slug == ^slug)
      |> select([d, _p], %{id: d.id, slug: d.slug, project_id: d.project_id})
      |> Repo.all()

    case matches do
      [dataset] ->
        dataset

      [] ->
        raise ExportScopeError,
          code: "dataset_not_found",
          message:
            "workspace #{inspect(ws.slug)} owns no dataset with slug #{inspect(slug)} — " <>
              "nothing to export at that grain"

      many ->
        # A slug is unique only per (project_id, slug), so ONE workspace can own
        # it twice through two projects. There is no defensible pick; refuse.
        raise ExportScopeError,
          code: "ambiguous_dataset_slug",
          message:
            "dataset slug #{inspect(slug)} is owned by #{length(many)} projects of workspace " <>
              "#{inspect(ws.slug)} (#{many |> Enum.map(& &1.project_id) |> Enum.join(", ")}) — " <>
              "refusing to guess which one to export"
    end
  end

  defp resolve_dataset!(_ws, other) do
    raise ExportScopeError,
      code: "invalid_dataset",
      message: "dataset must be a slug string, got #{inspect(other)}"
  end

  # The E3-dataset / allowlist bare-slug members INTERSECT the project-qualified
  # slug set with the target (PDS-D29): a shared slug is already absent from
  # `dataset_slugs_for/1`, so the intersection is empty — fail-closed, never a
  # bare-slug WHERE that would pull a co-tenant's unattributable rows.
  defp narrow_slugs(slugs, nil), do: slugs
  defp narrow_slugs(slugs, %{slug: slug}), do: Enum.filter(slugs, &(&1 == slug))

  defp export_ctx(%Workspace{} = ws, slugs, profile, target) do
    %{
      ws_lit: Catalog.uuid_literal!(ws.id),
      slugs: slugs,
      profile: profile,
      dataset: target,
      dataset_lit: target && Catalog.uuid_literal!(target.id),
      project_lit: target && Catalog.uuid_literal!(target.project_id),
      # Group-A (the dual dataset-column family) is derived LIVE, so a new
      # dataset_id table inherits the narrowing instead of silently exporting
      # workspace-whole under a dataset-scoped pull.
      dataset_id_tables:
        if(target, do: MapSet.new(Catalog.live_dataset_id_tables(Repo)), else: MapSet.new()),
      # PDS-D28: read the type deny EXPLICITLY — `dev_action/1` flattens it away.
      doc_type_deny: if(profile == :dev, do: Catalog.dev_doc_type_deny(), else: [])
    }
  end

  defp reject_denied_tables(specs, :full), do: specs

  defp reject_denied_tables(specs, :dev) do
    Enum.reject(specs, fn {table, _partition, _kind} -> Catalog.dev_action(table) == :deny end)
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
  defp copy_out_sql(table, kind, cols, order_cols, ctx) do
    select_list = cols |> Enum.map_join(", ", &select_expr(table, &1, ctx))
    order_by = order_cols |> Enum.map(&"t.#{qi(&1)}") |> Enum.join(", ")
    order_clause = if order_by == "", do: "", else: " ORDER BY #{order_by}"
    from = "FROM #{qi(table)} t"
    where = copy_where(table, kind, ctx) <> extra_predicates(table, kind, ctx)

    "COPY (SELECT #{select_list} #{from} #{where}#{order_clause}) TO STDOUT"
  end

  # A `{:scrub_fields, fields}` table travels with the named columns NULLED at
  # export — the column stays in the manifest's column list (so the member is
  # still COPY-importable), it just never carries the value. Empty in W1; the
  # seam exists so adding a scrub entry needs no engine change.
  defp select_expr(table, col, ctx) do
    if col in scrub_fields(table, ctx), do: "NULL", else: "t.#{qi(col)}"
  end

  defp scrub_fields(table, %{profile: :dev}) do
    case Catalog.dev_action(table) do
      {:scrub_fields, fields} -> fields
      _copy -> []
    end
  end

  defp scrub_fields(_table, _ctx), do: []

  defp copy_where("workspaces", :root, ctx), do: "WHERE t.id = #{ctx.ws_lit}"

  defp copy_where(_table, :e1, ctx), do: "WHERE t.workspace_id = #{ctx.ws_lit}"

  defp copy_where(table, :e2, ctx) do
    {join, pred} = Map.fetch!(Catalog.e2_joins(), table)
    "#{join} WHERE #{pred} = #{ctx.ws_lit}"
  end

  # E3 doc-keyed: a (doc_id, dataset) semi-join — EXISTS, never a plain JOIN,
  # which would fan out on the (doc_id, dataset) → 2-document case (charter D6).
  # The dataset grain and the dev type-deny both narrow the ANCHOR (the document
  # the row hangs off), because the member itself carries no such column.
  defp copy_where(_table, :e3_doc, ctx) do
    "WHERE EXISTS (SELECT 1 FROM documents d " <>
      "WHERE d.workspace_id = #{ctx.ws_lit} AND d.doc_id = t.doc_id AND d.dataset = t.dataset" <>
      doc_anchor_narrowing(ctx) <> ")"
  end

  defp copy_where(_table, :e3_dataset, ctx) do
    "WHERE t.dataset = ANY(#{Catalog.text_array_literal(ctx.slugs)})"
  end

  # data_keys.scope = "dataset:" <> slug (search_surface_config left the allowlist
  # in Wave 5 Slice A — it is now a plain E1 workspace_id table, charter D45/D49).
  defp copy_where(table, :allowlist, ctx) do
    prefix = Map.fetch!(Catalog.allowlist(), table)
    scopes = Enum.map(ctx.slugs, &(prefix <> &1))
    "WHERE t.scope = ANY(#{Catalog.text_array_literal(scopes)})"
  end

  # Both narrowings are "" on the default full/whole-workspace path, so the
  # emitted SQL — and therefore every dump byte — is identical to before.
  defp doc_anchor_narrowing(ctx) do
    dataset = if ctx.dataset, do: " AND d.dataset_id = #{ctx.dataset_lit}", else: ""

    types =
      case ctx.doc_type_deny do
        [] -> ""
        deny -> " AND d.#{qi("type")} <> ALL(#{Catalog.text_array_literal(deny)})"
      end

    dataset <> types
  end

  # ── Profile / dataset predicates (appended to the base scope WHERE) ──────────

  defp extra_predicates(table, kind, ctx) do
    (dataset_predicates(table, kind, ctx) ++ doc_type_predicates(table, kind, ctx))
    |> Enum.map_join("", &" AND #{&1}")
  end

  defp dataset_predicates(_table, _kind, %{dataset: nil}), do: []

  # The TRIAD roots always travel: the workspace row itself (already `t.id = ws`),
  # its OWNING project, and the target dataset row — a dataset-scoped bundle is
  # useless without the tenancy spine it hangs from.
  defp dataset_predicates("workspaces", :root, _ctx), do: []
  defp dataset_predicates("projects", _kind, ctx), do: ["t.#{qi("id")} = #{ctx.project_lit}"]
  defp dataset_predicates("datasets", _kind, ctx), do: ["t.#{qi("id")} = #{ctx.dataset_lit}"]

  # E3/allowlist members are keyed by the ALREADY-narrowed slug set; the doc-keyed
  # semi-join is narrowed inside its EXISTS anchor (see doc_anchor_narrowing/1).
  defp dataset_predicates(_table, kind, _ctx)
       when kind in [:e3_doc, :e3_dataset, :allowlist],
       do: []

  defp dataset_predicates(table, _kind, ctx) do
    # Group-A narrows on the CANONICAL dataset_id, never the `dataset` string
    # mirror (PDS-D7). Group-C carries no dataset grain at all and travels
    # workspace-whole — there is no row-level grain to fake.
    if MapSet.member?(ctx.dataset_id_tables, table) do
      ["t.#{qi("dataset_id")} = #{ctx.dataset_lit}"]
    else
      []
    end
  end

  defp doc_type_predicates(_table, _kind, %{doc_type_deny: []}), do: []

  defp doc_type_predicates(_table, :e3_doc, _ctx), do: []

  defp doc_type_predicates("documents", _kind, ctx) do
    ["t.#{qi("type")} <> ALL(#{Catalog.text_array_literal(ctx.doc_type_deny)})"]
  end

  defp doc_type_predicates(table, _kind, ctx) do
    # PDS-D27, THE CASCADE: `copy_where/3`'s doc semi-join and every E2
    # parent-join are type-BLIND, so a denied document's children would travel
    # as FK-violating orphans. Every FK column pointing at `documents.id` is
    # derived LIVE from pg_constraint, so a future child table inherits the
    # cascade instead of quietly shipping orphans.
    deny = Catalog.text_array_literal(ctx.doc_type_deny)

    for col <- Catalog.document_fk_columns(Repo, table) do
      "NOT EXISTS (SELECT 1 FROM documents dtd " <>
        "WHERE dtd.id = t.#{qi(col)} AND dtd.#{qi("type")} = ANY(#{deny}))"
    end
  end

  # PDS-D42, THE ASYMMETRY THIS CLOSES. `import_bundle/2`'s transaction has
  # carried `timeout: :infinity` since it was written; the export COPY loop
  # carried NO `:timeout` at all, so every `COPY … TO STDOUT` silently inherited
  # Ecto's 15,000 ms default (`config/runtime.exs` repo_opts sets url/pool_size/
  # socket_options only — no `:timeout` key — so the default is genuinely in
  # force in prod). Run-proven live: a full-fidelity export of `default` died at
  # 27.0s with `(DBConnection.ConnectionError) tcp recv: closed` raised from THIS
  # function. The fat members sit just under the default on a warm cache
  # (mutation_events 9.34s / 478 MB, revisions 8.04s / 385 MB) and cross it on a
  # cold one — a wall-clock coin flip, which is the worst kind of failure.
  # An export is an explicit admin-initiated backup, never a request-path query:
  # its natural bound is "as long as the dump takes", so it gets the same
  # `:infinity` import already had rather than a new arbitrary number to
  # re-tune. The value is read from config so an operator can cap it on a
  # constrained box without a deploy; nothing sets it in prod, and the test that
  # pins this reads the option OFF the driver call (`:erlang.trace` on
  # `Repo.query!/3`) rather than driving a real timeout — a pool timeout under
  # the SQL sandbox arrives as an ownership-shutdown EXIT, not a rescuable
  # raise. `:export_copy_fault` (below) is the separate test-only seam that
  # reproduces the FAILURE for the envelope proof.
  #
  # PDS-D44, BUDGET: the one-export memory budget counts ATTEMPTS, not
  # successes. Measured on the ACTIVE green slot (blue is inactive and reports
  # MemoryPeak `[not set]`, so the obvious probe measures nothing): baseline
  # 700 MiB, 2.65 GiB after a FAILED export, 2.90 GiB after the successful one,
  # on a 3819 MB box. A dead export has already paid nearly the full cost — so
  # do NOT wrap this in a naive retry loop; two attempts is an OOM, not a
  # second chance. The real fix for size was streaming
  # (pds-bl-streaming-workspace-export) — which is what this function now is.
  #
  # THE STREAM. `Repo.query!` buffered the ENTIRE `COPY … TO STDOUT` as
  # `res.rows` and then `IO.iodata_to_binary` made a second full copy of it.
  # `Ecto.Adapters.SQL.stream/4` fetches in bounded chunks instead; each chunk
  # goes straight to the table's spill file while the member md5 folds forward
  # incrementally, so peak RAM per table is ONE chunk rather than the whole
  # table.
  #
  # THE TRANSACTION IS MANDATORY, NOT STYLISTIC: `Ecto.Adapters.SQL.reduce/6`
  # raises "cannot reduce stream outside of transaction". And the `:timeout`
  # MUST sit on `Repo.transaction/2` — a 4-cell probe matrix proved the
  # stream-level `:timeout` is INERT (txn `:infinity` + stream 300 ms survived
  # 3002 ms) and cannot override the transaction's budget (txn 300 ms + stream
  # `:infinity` died at 310 ms). Moving it onto the `SQL.stream` call ships a
  # green suite while silently reinstating Ecto's 15,000 ms default in prod —
  # the exact live failure PDS-D42 exists to close. The test that pins this
  # reads the option off `Repo.transaction/2` via `:erlang.trace`.
  #
  # ROW COUNT: `length(chunk.rows)` summed across chunks reproduces the old
  # `length(res.rows)` EXACTLY — both count COPY CopyData wire messages, and
  # Postgrex's `:max_rows` chunks on that identical unit. It is deliberately
  # NOT a decoded-row count. The stream also yields an EMPTY TERMINAL CHUNK
  # (chunk_count = ceil(rows/max_rows) + 1; a zero-row table yields exactly
  # one), which contributes 0 rows and 0 bytes and needs no special case.
  # File.open! targets `spill_path` (engine-built bp-ws-spill-<table>-<int>.copy,
  # fetch_env! spill dir) and SQL.stream runs `sql`, a COPY ... TO STDOUT built
  # by copy_out_sql from catalog-derived table/columns (Catalog.live_e*,
  # information_schema); neither carries request input. PR #5083 security review.
  # sobelow_skip ["Traversal.FileModule", "SQL.Stream"]
  defp run_copy_out(sql, spill_path) do
    inject_copy_fault!()

    {row_count, digest} =
      File.open!(spill_path, [:write, :binary, :raw], fn io ->
        {:ok, acc} =
          Repo.transaction(
            fn ->
              Repo
              |> Ecto.Adapters.SQL.stream(sql, [])
              |> Enum.reduce({0, :crypto.hash_init(:md5)}, fn chunk, {count, hash} ->
                # `rows: nil` is defensive; the terminal chunk carries [].
                rows = chunk.rows || []
                # iodata all the way down — never flattened into a binary.
                :ok = IO.binwrite(io, rows)
                {count + length(rows), :crypto.hash_update(hash, rows)}
              end)
            end,
            timeout: copy_out_timeout()
          )

        acc
      end)

    {row_count, digest |> :crypto.hash_final() |> Base.encode16(case: :lower)}
  end

  defp copy_out_timeout do
    Application.get_env(:barkpark, :export_copy_timeout, :infinity)
  end

  # Test-only fault seam for the honest-envelope proof (PDS-D43). The SQL
  # sandbox cannot produce a REAL rescuable transport failure — a pool timeout
  # under `Ecto.Adapters.SQL.Sandbox` arrives as an ownership-shutdown EXIT and
  # takes the test's connection with it — so the envelope test raises the exact
  # exception the live 500 carried, from the exact function it was raised in.
  # `nil` in every non-test env: one `Application.get_env` on a path that is
  # already about to dump hundreds of MB.
  defp inject_copy_fault! do
    case Application.get_env(:barkpark, :export_copy_fault) do
      nil -> :ok
      message when is_binary(message) -> raise DBConnection.ConnectionError, message
    end
  end

  # ── Import ─────────────────────────────────────────────────────────────────

  # Root-slug pre-flight (PDS-D9). Every fresh migrate-seeded target already
  # holds a `slug=default` workspace under a DIFFERENT id, so the first pull
  # into it collided on `workspaces_slug_index` — masked as an opaque aborted-
  # transaction error (25P02) on the next member. In `:merge` mode: when the
  # bundle's root slug exists on the target under a different id AND that
  # workspace is provably EMPTY (0 documents, 0 media_files), delete the shell
  # inside the import transaction (via `Tenancy.delete_workspace/1`, whose FK
  # cascades and teardown triggers must all fire — hence pre-flight runs
  # before any trigger/constraint DDL) and proceed; otherwise refuse with a
  # clear named error.
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

  # A manifest member without an order_columns arbiter is a STALE BUNDLE the
  # caller can fix by re-exporting — InvalidBundleError (422 invalid_bundle at
  # the HTTP edge), never an opaque ArgumentError 500 (task-96d8ab2b582818a4).
  defp merge_upsert(table, _cols, order_cols, _dump) do
    raise InvalidBundleError,
      code: "invalid_bundle",
      message:
        "merge import needs a non-empty order_columns arbiter for #{inspect(table)}, " <>
          "got #{inspect(order_cols)} — re-export the bundle with a current manifest"
  end

  defp scalar!(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  # ── SQL identifier / hashing helpers ─────────────────────────────────────────

  # Double-quote an identifier (column/table name) — every name originates from
  # the live catalog, never user input; the quote-doubling is belt-and-suspenders.
  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")
end
