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
  raises `ExportScopeError` on ambiguity. The E3 dataset-keyed members whose
  bare slug is genuinely unattributable keep going through `dataset_slugs_for/1`
  and INTERSECT it with the target slug — a shared slug therefore yields the
  empty set, fail-closed.

  ## `dataset_slugs` names the EXCLUSIVE set, and `declared_loss` says what that cost (PDS-D45/D46/D74)

  Two manifest keys that are easy to misread, so read them together:

    * `dataset_slugs` is NOT "the datasets in this bundle". It is the
      workspace-EXCLUSIVE attribution set — the slugs no other workspace's
      project also owns. A shared slug being ABSENT from it is correct behaviour
      (PDS-D46), not a bug: it is the fail-closed key that keeps a bare-slug
      `dataset = ANY(...)` copy from pulling a co-tenant's rows. The workspace's
      documents, media and every other workspace_id-keyed row under that slug
      still travel — they are attributed by column, not by slug.
    * `declared_loss` is what that exclusion actually costs, counted. A table
      whose ONLY tenant key is the bare `dataset` slug
      (`Catalog.e3_dataset_unattributable/0`) genuinely cannot export its rows
      under a shared slug, so it gets an entry naming the slugs, the row count
      and a person-facing reason. `[]` is the normal answer and is ALWAYS
      present — "no loss" must be distinguishable from "an engine too old to
      say". A table that CAN name its own workspace
      (`Catalog.e3_dataset_workspace_slug_column/0`, today `shares`) is exported
      by that column instead and never appears here.

  Silence was the actual defect (PDS-D45): on guerrilla, `production` is owned by
  both `default` and `gyldendal`, so a `:full` "full-fidelity backup" shipped a
  zero-byte `shares` member and said nothing. `shares` now travels; the rows that
  still cannot are counted out loud.

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

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content.Scope
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Dataset, Membership, Project, Workspace}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog, ExportScopeError, InvalidBundleError}
  alias Barkpark.Tenancy.WorkspaceBundle.Janitor

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
          # This function is the one that DELETES the tar, so it is the one that
          # disowns it. `pack/3` deliberately leaves the sidecar in place on
          # success because it hands the path onward; `export_to_file/2`'s
          # callers inherit that same duty (see `Archive.pack/3` @doc).
          File.rm(path)
          Janitor.disown(path)
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
    * `:grant_admin_to` — the principal bringing this workspace onto this
      instance, as `{principal_id, principal_type}`. It is granted an `admin`
      membership on the imported workspace INSIDE the import transaction. See
      `grant_operator_admin!/2` for why that is the completion of the import
      rather than a widening. Defaults to `nil` (grant nothing).

  In `:merge` mode a same-slug/different-id root collision returns
  `{:error, {:workspace_slug_conflict, %{slug, existing_id, bundle_id}}}`
  unless the squatting workspace is a provably EMPTY shell (0 documents,
  0 media_files), which is deleted in-transaction and replaced (PDS-D9).

  In BOTH modes, a bundle whose `media_files` rows carry a `path` a RESIDENT
  workspace (or an unscoped legacy row) already owns returns
  `{:error, {:blob_path_conflict, %{workspace_id, count, sample}}}` and the whole
  import rolls back. The blob keyspace is flat, so two owners at one path means
  the loser's own scoped read streams the winner's bytes — see
  `assert_no_foreign_blob_path_collision!/3` for why the refusal fires at
  ROW-COPY time rather than at blob-push time.
  """
  @spec import_bundle(binary(), keyword()) ::
          {:ok, stats()}
          | {:error, {:workspace_slug_conflict, map()} | {:blob_path_conflict, map()} | term()}
  def import_bundle(bundle, opts \\ []) when is_binary(bundle) do
    mode = import_mode!(opts)
    grant = grant_admin_to!(opts)
    {manifest, dumps} = Archive.unpack(bundle)
    import_unpacked(manifest, dumps, mode, grant)
  end

  @doc """
  Re-import a bundle from a FILE, streaming each member off disk.

  The production import path (PDS wave 23). Same manifest, same stats, same
  errors as `import_bundle/2` — the difference is that neither the bundle nor
  any member is ever a binary in the BEAM: the tar is extracted into a scratch
  directory and each `COPY … FROM STDIN` is fed from `File.stream!/2` in 64 KiB
  chunks. `COPY FROM STDIN` is a byte stream, so chunk boundaries need not be
  line-aligned.

  Peak is **1x the largest single member**, not constant memory — `:erl_tar`
  has no chunked extract API, so the largest member is materialised once while
  it is written out. On guerrilla that is ~1.31 GB (`mutation_events`), against
  ~3x the whole ~2.6 GB archive for `import_bundle/2`.

  Each member file is deleted the MOMENT its COPY completes, and the extraction
  directory is `rm_rf`'d in an `after` clause; a SIGKILL that outruns both is
  collected by `Janitor` via the `bp-ws-import-` prefix. THE CALLER still owns
  `bundle_path` — this function never deletes it.
  """
  @spec import_bundle_file(Path.t(), keyword()) ::
          {:ok, stats()}
          | {:error, {:workspace_slug_conflict, map()} | {:blob_path_conflict, map()} | term()}
  # `dir` is derived from Plug's server-chosen upload path plus a unique suffix,
  # and Archive validates every tar member before extraction. No manifest member
  # can choose the directory removed by the `after` clause.
  # sobelow_skip ["Traversal.FileModule"]
  def import_bundle_file(bundle_path, opts \\ []) when is_binary(bundle_path) do
    mode = import_mode!(opts)
    grant = grant_admin_to!(opts)
    # NAMED WITH THE JANITOR'S PREFIX, and that is a fix, not a formality
    # (pds-w11-janitor-engine-handshake). This directory used to be
    # `members-<int>`, while the janitor's candidate glob is exactly three fixed
    # prefixes — `bp-ws-bundle-`, `bp-ws-spill-`, `bp-ws-import-`. `members-`
    # matched none of them, so the promise four lines up in this very doc —
    # "a SIGKILL that outruns both is collected by `Janitor` via the
    # `bp-ws-import-` prefix" — was FALSE: a kill mid-import stranded a
    # multi-GB extraction directory the sweep could never see, permanently.
    # Observed in the wild, not theorised: two such directories survived
    # crashed runs in a shared spill dir and were still there long enough to
    # break an unrelated test's assertion about that directory being empty.
    dir = Archive.scratch_path(Path.dirname(bundle_path))

    Janitor.own(dir)

    try do
      {manifest, paths} = Archive.unpack_to_dir(bundle_path, dir)
      import_unpacked(manifest, Map.new(paths, fn {t, p} -> {t, {:file, p}} end), mode, grant)
    after
      File.rm_rf(dir)
      Janitor.disown(dir)
    end
  end

  # The grant option is VALIDATED HERE, before the tar is touched — a caller
  # that fumbles the shape learns it as an ArgumentError at the door rather
  # than as a silently ungranted import an hour into a restore. `nil` (the
  # default) means grant nothing, which is every non-HTTP caller: the engine is
  # also driven by mix tasks and round-trip tests that have no operator.
  defp grant_admin_to!(opts) do
    case Keyword.get(opts, :grant_admin_to) do
      nil ->
        nil

      {principal_id, principal_type}
      when is_binary(principal_id) and principal_type in ["api_token", "user"] ->
        {principal_id, principal_type}

      other ->
        raise ArgumentError,
              "invalid :grant_admin_to #{inspect(other)} " <>
                "(expected {principal_id, \"api_token\" | \"user\"} or nil)"
    end
  end

  defp import_mode!(opts) do
    mode = Keyword.get(opts, :mode, :clean)

    unless mode in [:clean, :merge] do
      raise ArgumentError,
            "unknown import mode #{inspect(mode)} (expected :clean or :merge)"
    end

    mode
  end

  defp import_unpacked(manifest, dumps, mode, grant) do
    # A readable tar whose manifest names a DIFFERENT format is a caller
    # mistake, not an engine fault — InvalidBundleError so the HTTP edge
    # answers 422 invalid_bundle instead of the opaque 500 the old
    # ArgumentError produced (task-96d8ab2b582818a4).
    if manifest["format"] != Archive.format() do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message: "not a #{Archive.format()} bundle: format=#{inspect(manifest["format"])}"
    end

    # PDS-D45: a declared loss is only honest if someone HEARS it. The manifest
    # rides back to the caller inside `stats()` (machine-readable), and the
    # restore operator — who is usually watching a log, not parsing a tar — gets
    # it here, before the first row lands.
    warn_declared_loss(manifest)

    # Test-only fault seam (mirrors :export_copy_fault): when configured, the
    # import RETURNS the given {:error, term} after the real unpack + format
    # check, so the HTTP edge's unmatched-term contract (named, logged 500
    # import_failed — task-96d8ab2b582818a4) is provable over the wire without
    # mocking the engine. `nil` in every non-test env.
    case Application.get_env(:barkpark, :import_fault) do
      {:error, _term} = fault -> fault
      nil -> run_import(manifest, dumps, mode, grant)
    end
  end

  # An older bundle has no `declared_loss` key at all; that is not a loss claim of
  # zero, it is no claim — say nothing rather than imply completeness.
  defp warn_declared_loss(%{"declared_loss" => [_ | _] = losses}) do
    total = losses |> Enum.map(& &1["row_count"]) |> Enum.sum()

    Logger.warning(
      "workspace bundle import: the source DECLARED #{total} withheld row(s) across " <>
        "#{length(losses)} table(s) — this restore is knowingly incomplete. " <>
        Enum.map_join(losses, " ", & &1["message"])
    )
  end

  defp warn_declared_loss(_manifest), do: :ok

  defp run_import(manifest, dumps, mode, grant) do
    Repo.transaction(
      fn ->
        # OPT-OUT from the pool-wide 30 s statement_timeout (runtime.exs): each
        # member restores through a single `COPY … FROM STDIN` fed in 64 KiB
        # chunks off disk — the mirror image of the export COPY above, and this
        # transaction has carried `timeout: :infinity` since it was written for
        # the same reason. SET LOCAL, so it cannot leak past the COMMIT.
        Repo.set_local_statement_timeout!(0)

        # FIRST OF ALL: refuse any manifest table the export could never have
        # written, before ANY write — the shell-adopt delete, the FK/trigger
        # DDL and every COPY/INSERT run only over membership-checked names.
        assert_member_tables!(manifest)

        # THEN: drain the deferred-trigger queue, or the DDL below cannot run.
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

        # Reserved-slug seat guard (task-545166efceb1bc91) — BEFORE the PDS-D9
        # pre-flight, so a bundle aimed at a vacant reserved seat never reaches
        # the adopt branch's delete. The snapshot it returns is re-read after
        # the members land; see the section comment on
        # assert_root_slug_not_vacant_reserved!/2.
        vacant_reserved = vacant_reserved_slugs()
        assert_root_slug_not_vacant_reserved!(manifest, vacant_reserved)

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
            # ROW-COPY TIME, deliberately: see
            # assert_no_foreign_blob_path_collision!/3 for why a push-time
            # refusal reproduces the very state it is meant to prevent.
            assert_no_foreign_blob_path_collision!(entry["name"], n, manifest)
            {Map.put(acc, entry["name"], n), total + n}
          end)
          |> then(fn {tables, total} ->
            # The manifest rides back out so the caller can stamp pull
            # provenance without unpacking (and re-inflating) the tar twice.
            %{tables: tables, total_rows: total, manifest: manifest}
          end)

        alter_user_triggers!(live, "ENABLE")
        restore_member_fks!(member_fks)

        # The manifest's declared root slug is a CLAIM; the workspaces COPY
        # member carries the actual slug. Re-read the seats that were vacant at
        # pre-flight so a manifest that under-declares itself is caught by the
        # rows it actually landed, not by what it said about them.
        assert_reserved_seats_still_vacant!(vacant_reserved)

        # LAST, and deliberately AFTER restore_member_fks!/1: the grant is the
        # only row this transaction writes through Ecto rather than COPY, and
        # writing it with the member FKs live means Postgres validates it
        # against the workspace the import just landed. Written INSIDE the
        # transaction, so anything that fails after this point takes the grant
        # down with it — a failed import grants nothing.
        grant_operator_admin!(manifest, grant)

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

  # Search-path visibility, NOT nspname='public' (felix-w27): the unqualified
  # COPY/INSERT below resolves `table` via search_path — pg_catalog implicit-
  # FIRST — so this classifier must answer the same question COPY asks, or a
  # pg_catalog relation (pg_authid) slips OUT of `assert_member_tables!/1`'s
  # `foreign` set instead of being refused. `relkind = 'r'` is KEPT: a bare
  # pg_table_is_visible would match views/indexes/sequences too.
  # RESIDUAL (accepted): this resolves the search-path WINNER, so a public
  # member shadowed by a same-named pg_catalog relation would classify as the
  # catalog copy; no app table name collides with pg_catalog today.
  defp table_exists?(table) do
    Repo.query!(
      "SELECT 1 FROM pg_class cl " <>
        "WHERE cl.relname = $1 AND cl.relkind = 'r' " <>
        "AND pg_catalog.pg_table_is_visible(cl.oid)",
      [table]
    ).rows != []
  end

  # ── Catalog-membership guard (felix-w25-s3, charter D165) ────────────────────
  #
  # NAMED FAILURE MODE: a manifest-named table reaches the interpolated
  # COPY/INSERT path with no membership check — `qi/1` quotes the identifier
  # but never restricts WHICH table, and `table_exists?/1` gates existence,
  # not membership. The export builds member specs PURELY from
  # `[root_table] ++ live_e1/e2/e3 ++ allowlist keys` (do_export/2), so a
  # table outside that enumeration (`users`, `oban_jobs`, `schema_migrations`)
  # cannot come out of a legit export — a manifest naming one is
  # crafted/foreign, and it is refused HERE, before the shell-adopt delete,
  # the FK/trigger DDL and any COPY/INSERT.
  #
  # The allow-set is DERIVED from the same live enumeration export reads —
  # never the pinned lists — so a new tenant table is a member on both sides
  # the moment it exists. Two filters, two jobs: a manifest table ABSENT on
  # this schema version has unknowable membership here and keeps today's
  # cross-version tolerance (`table_exists?/1` 0-row skip; a row-carrying one
  # fails on its own COPY exactly as before) — only a table that EXISTS on
  # the target AND is not a member is refused.
  defp assert_member_tables!(manifest) do
    members =
      MapSet.new(
        [Catalog.root_table()] ++
          Catalog.live_e1(Repo) ++
          Catalog.live_e2(Repo) ++
          Catalog.live_e3(Repo) ++
          Map.keys(Catalog.allowlist())
      )

    foreign =
      (manifest["tables"] || [])
      |> Enum.map(& &1["name"])
      |> Enum.reject(&MapSet.member?(members, &1))
      |> Enum.filter(&table_exists?/1)

    if foreign != [] do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message:
          "manifest names table(s) a #{Archive.format()} export could never have written: " <>
            Enum.join(Enum.sort(foreign), ", ")
    end
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

    slug_partition = partition_dataset_slugs_for(ws.id)
    dataset_slugs = narrow_slugs(slug_partition.exclusive, target)
    ctx = export_ctx(ws, dataset_slugs, profile, target)
    declared_loss = declared_loss(slug_partition.shared, target, profile)

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

    # Claim every spill UP FRONT, for the same reason the paths are computed up
    # front: the window the liveness sidecar has to cover starts before the
    # first COPY, not when a file happens to appear. Owning a path whose file is
    # never written is harmless — the `after` clause disowns all of them, and a
    # sidecar with no subject is skipped by the sweep either way.
    #
    # Until this call existed, `Janitor.own/1` had ZERO callers in `api/lib`
    # (only its own unit test), so the liveness guard protected nothing on a
    # real box and the derived mtime cutoff was the only thing standing between
    # a boot-time sweep and a live concurrent export.
    Enum.each(Map.values(spills), &Janitor.own/1)

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
        # PDS-D45/D74: what this bundle could NOT carry, said out loud. ALWAYS
        # present (`[]` on the overwhelmingly common no-collision path) — a key
        # that appears only on loss cannot be told apart from an engine too old
        # to have one, which is the same silence in a new costume.
        "declared_loss" => declared_loss,
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
      # And the sidecars with them. Best-effort on both sides — this runs on the
      # failure path too, where the point is to leave nothing claimed by a pid
      # that is about to stop existing.
      Enum.each(Map.values(spills), &Janitor.disown/1)
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

  # ── Declared loss (PDS-D45/D74) ──────────────────────────────────────────────

  # THE RULE THIS ENFORCES: a `:full` bundle that cannot carry something must SAY
  # SO. `Catalog.e3_dataset_unattributable/0` names the tables whose only tenant
  # key is a bare `dataset` slug; under a slug a sibling workspace also owns, that
  # key attributes to NEITHER, so the rows cannot travel without becoming a
  # cross-tenant leak. Refusing them is right. Refusing them SILENTLY — a
  # zero-byte member under a manifest that reads like a complete backup — is the
  # defect: whoever restores gets a quietly incomplete dataset and nothing
  # anywhere says so.
  #
  # So each such table gets an entry naming the slugs, the row count that did not
  # travel, and a sentence a person can act on. The count is the honest UPPER
  # bound — it includes rows that may belong to the co-tenant, because the whole
  # point is that the table cannot tell. Over-reporting what was withheld is the
  # safe direction; under-reporting is the bug being fixed.
  #
  # Zero cost on the healthy path: with no shared slugs the list is `[]` and not
  # one count query runs.
  defp declared_loss([], _target, _profile), do: []

  defp declared_loss(shared_slugs, target, profile) do
    case narrow_slugs(shared_slugs, target) do
      [] ->
        []

      slugs ->
        Catalog.e3_dataset_unattributable()
        # A table the profile DENIES is absent from the bundle by an explicit,
        # reviewed decision (PDS-D31), not by this silent drop — declaring a
        # loss for it would be noise that hides the real one.
        |> Enum.reject(&(profile == :dev and Catalog.dev_action(&1) == :deny))
        |> Enum.map(&declared_loss_entry(&1, slugs))
        |> Enum.reject(&(&1["row_count"] == 0))
    end
  end

  # Reachability: `table` comes from `Catalog.e3_dataset_unattributable/0` (a
  # pinned literal list) via `qi/1`; `slugs` is rendered by
  # `Catalog.text_array_literal/1`, which single-quotes and doubles every
  # embedded quote.
  # sobelow_skip ["SQL.Query"]
  defp declared_loss_entry(table, slugs) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM #{qi(table)} t " <>
          "WHERE t.dataset = ANY(#{Catalog.text_array_literal(slugs)})",
        []
      )

    %{
      "table" => table,
      "reason" => "unattributable_shared_dataset_slug",
      "slugs" => slugs,
      "row_count" => count,
      "message" =>
        "#{count} row(s) in #{table} were NOT exported: their only tenant key is the " <>
          "dataset slug #{Enum.map_join(slugs, ", ", &inspect/1)}, which a project of another " <>
          "workspace also owns, so the rows cannot be attributed to this workspace and " <>
          "carrying them would leak a co-tenant's data. The count is an upper bound — some " <>
          "may be the co-tenant's. Give #{table} a workspace column to end this loss."
    }
  end

  defp export_ctx(%Workspace{} = ws, slugs, profile, target) do
    %{
      ws_lit: Catalog.uuid_literal!(ws.id),
      # PDS-D74: the tenant key for the ATTRIBUTED E3-dataset arm. Safe precisely
      # because `workspaces.slug` is uniquely indexed — unlike the `dataset` slug,
      # which is unique only per project.
      ws_slug_lit: Catalog.text_literal(ws.slug),
      dataset_slug_lit: target && Catalog.text_literal(target.slug),
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
  def dataset_slugs_for(ws_id), do: partition_dataset_slugs_for(ws_id).exclusive

  @doc """
  The same derivation as `dataset_slugs_for/1`, but keeping BOTH halves.

    * `:exclusive` — the slugs this workspace owns and no other does. The
      bare-slug E3/allowlist copy and teardown key on these, and only these.
    * `:shared` — the slugs `dataset_slugs_for/1` DROPS because a project of
      another workspace owns them too.

  `:shared` used to be an anonymous subtraction inside one function, which is how
  a `:full` bundle came to omit rows with nothing anywhere saying so (PDS-D45).
  Naming it is what lets the exporter DECLARE that omission: for an E3-dataset
  table with no workspace key of its own (`Catalog.e3_dataset_unattributable/0`),
  these slugs are exactly the population it cannot carry.
  """
  @spec partition_dataset_slugs_for(binary()) :: %{exclusive: [String.t()], shared: [String.t()]}
  def partition_dataset_slugs_for(ws_id) do
    project_ids =
      Project
      |> Scope.scope_to_workspace(ws_id)
      |> select([p], p.id)
      |> Repo.all()

    if project_ids == [] do
      %{exclusive: [], shared: []}
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

      owned =
        Dataset
        |> where([d], d.project_id in ^project_ids)
        |> select([d], d.slug)
        |> distinct(true)
        |> Repo.all()

      {shared, exclusive} = Enum.split_with(owned, &(&1 in shared_slugs))

      # Sorted: a bare `DISTINCT` has no defined row order, and both halves are
      # serialised into the manifest (`dataset_slugs`, `declared_loss`). Leaving
      # them at the planner's mercy would make two exports of an unchanged
      # workspace differ in bytes for no reason.
      %{exclusive: Enum.sort(exclusive), shared: Enum.sort(shared)}
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

  # E3 dataset-keyed, ATTRIBUTED arm (PDS-D74). A table that carries its own
  # workspace slug column is scoped by THAT, never by the bare `dataset` slug:
  # `workspaces.slug` is uniquely indexed, so the column names exactly one tenant,
  # whereas a `dataset` slug two workspaces both own names neither. This is what
  # keeps a `:full` bundle from dropping every `shares` row of a workspace that
  # happens to share a slug with a co-tenant — the guerrilla shape, where
  # `production` belongs to both `default` and `gyldendal`.
  #
  # It does NOT weaken the exclusivity rule: the sibling's rows carry the
  # sibling's `workspace_slug`, so they are excluded by the same predicate that
  # includes ours. The dataset GRAIN is re-applied separately, in
  # `dataset_predicates/3` — without it this predicate would widen a
  # dataset-scoped pull to every dataset the workspace shares.
  defp copy_where(table, :e3_dataset, ctx) do
    case Map.fetch(Catalog.e3_dataset_workspace_slug_column(), table) do
      {:ok, col} -> "WHERE t.#{qi(col)} = #{ctx.ws_slug_lit}"
      :error -> "WHERE t.dataset = ANY(#{Catalog.text_array_literal(ctx.slugs)})"
    end
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

  # The ATTRIBUTED E3-dataset arm is the ONE member whose base scope is not
  # already dataset-grained: `copy_where/4` keys it on the workspace slug, which
  # spans every dataset that workspace shares. Re-apply the grain here or a
  # dataset-scoped pull would silently WIDEN — the mirror-image defect of the
  # silent narrowing this slice fixes. The `dataset` slug is a safe grain HERE
  # (where it was not safe as a tenant key) because the workspace is already
  # pinned by the base predicate, and `resolve_dataset!/2` REFUSES a slug two of
  # the workspace's projects both own — so within one workspace the slug names
  # exactly one dataset.
  defp dataset_predicates(table, :e3_dataset, ctx) do
    if Map.has_key?(Catalog.e3_dataset_workspace_slug_column(), table) do
      ["t.#{qi("dataset")} = #{ctx.dataset_slug_lit}"]
    else
      []
    end
  end

  # E3/allowlist members are keyed by the ALREADY-narrowed slug set; the doc-keyed
  # semi-join is narrowed inside its EXISTS anchor (see doc_anchor_narrowing/1).
  defp dataset_predicates(_table, kind, _ctx)
       when kind in [:e3_doc, :allowlist],
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
              # OPT-OUT from the pool-wide 30 s statement_timeout (runtime.exs):
              # ONE `COPY … TO STDOUT` is one statement, run-proven at 9.34 s
              # (mutation_events, 478 MB) on a WARM cache and longer cold, so the
              # wall would cancel a legitimate export mid-dump. SET LOCAL, so it
              # dies with this transaction and never rides the pooled connection
              # back out. Issued INSIDE the existing transaction rather than by
              # wrapping it in `with_statement_timeout/2`: an outer transaction
              # would make the `timeout: copy_out_timeout()` below a savepoint
              # option and INERT — the precise PDS-D42 trap two paragraphs up.
              Repo.set_local_statement_timeout!(0)

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
  # ── The operator grant (task-ed7ae8110c7c8b41) ───────────────────────
  #
  # AN IMPORTED WORKSPACE ARRIVES WITH ZERO VALID ADMINISTRATORS. The bundle
  # carries only the SOURCE instance's `workspace_memberships` rows, and those
  # name principals that do not exist here; `api_tokens` is `@pinned_e1` too,
  # so the source's credentials land as rows nobody holds a secret for. Nothing
  # else on the import path writes a membership —
  # `Auth.insert_token_with_membership/3` is the token-MINT seam and stamps a
  # membership for a token it is creating, which import never does.
  #
  # That gap PREDATES the tenancy binding of PRs #12824/#12826/#12827; the old
  # workspace-blind `require_admin` was papering over it, so closing the hole
  # did not create this — it made it visible. The remedy is the completion of
  # an unfinished flow, not a policy change: the operator who brought the
  # workspace onto this instance is by definition the party entitled to
  # administer it, and absent this row nobody is.
  #
  # ROLE LEVEL IS LOAD-BEARING — `admin`, not `member`. The blob route binds on
  # `TenancyAuth.member?/2`, but its two siblings bind on
  # `TenancyAuth.workspace_admin?/2` (owner|admin only): DELETE
  # /api/workspaces/:workspace_slug and GET /api/workspaces/:workspace_slug/
  # export. A `member` grant would repair the blob push and leave the workspace
  # with no administrator — the same hole, one route narrower, and an operator
  # that can neither re-export nor remove what it just imported.
  #
  # ADDITIVE, and NARROW in three directions: the bundle's own membership rows
  # are untouched; only the IMPORTING principal is granted, so a bystander
  # holding the same global `admin` permission gains nothing; and only the
  # IMPORTED workspace is granted, so the grant is never instance-wide.
  #
  # NEVER AN ESCALATION. An existing membership for this principal is left
  # exactly as it is. A pre-existing `member` row is a relationship somebody
  # chose, and a re-import is not consent to upgrade it.
  defp grant_operator_admin!(_manifest, nil), do: :ok

  defp grant_operator_admin!(manifest, {principal_id, principal_type}) do
    ws_id = manifest["workspace_id"]

    # Explicit map, not String.to_existing_atom/1: `grant_admin_to!/1` has
    # already fixed the domain to these two, and `membership/3` guards on the
    # ATOM (`principal_kind in [:user, :api_token]`) while `create_membership/4`
    # takes the STRING. Spelling both out keeps the pair impossible to drift.
    kind = if principal_type == "user", do: :user, else: :api_token

    # `principal_type` is threaded EXPLICITLY end to end: it is a discriminator
    # column with an implicit default, and `TenancyAuth.create_membership/4`
    # documents omitting it as this repo's proven vacuous-green generator — a
    # mis-typed row is invisible to `membership/2` while reading TRUE off the
    # bare-id arm of `workspace_admin?/2`.
    case TenancyAuth.membership(principal_id, ws_id, kind) do
      %Membership{} ->
        :ok

      nil ->
        case TenancyAuth.create_membership(ws_id, principal_id, "admin", principal_type) do
          {:ok, _membership} ->
            :ok

          {:error, changeset} ->
            # Inside the transaction, so this aborts the whole import rather
            # than committing a workspace nobody can administer. Ecto needs the
            # explicit rollback: a bare {:error, _} here would be the block's
            # return value and COMMIT (the FK-abort scar).
            Repo.rollback({:operator_grant_failed, changeset})
        end
    end
  end

  # ── Reserved-slug seat guard (task-545166efceb1bc91) ────────────────────────
  #
  # THE HOLE. `copy_where("workspaces", :root, ctx)` restores the root
  # workspaces row by a bare `COPY`. No `Workspace.changeset/2` is ever built,
  # so the row reaches the table through NEITHER of the two guards that police
  # every other way a workspace comes into existence:
  #
  #   * `Tenancy.singleton_slug_error/1` — refuses a PRINCIPAL claiming the
  #     instance-default singleton slug, and
  #   * `Workspace.changeset/2`'s `validate_exclusion(:slug, @reserved_slugs)`
  #     — refuses the routing-prefix names (admin, api, studio, media, …).
  #
  # WHY THAT MATTERS. `Tenancy.get_default_workspace/0` is
  # `Repo.get_by(Workspace, slug: "default")`. Whoever holds that slug IS the
  # instance default: `AssignDefaultScope` binds every flat route to it, and
  # `Content.WriteScope.resolve_write_scope/1` stamps an UNSCOPED WRITE with
  # it. The `unique_index(:workspaces, [:slug])` the import route's own comment
  # leans on refuses a squat only while the seat is OCCUPIED — with the seat
  # VACANT there is no row to collide with and the COPY simply lands.
  #
  # THE RULE, AND ITS EXACT EDGE. A reserved seat that is VACANT on this
  # instance at pre-flight time may not be filled by an import. That is
  # deliberately narrower than "an import may never hold a reserved slug",
  # because the wider rule would break a SUPPORTED production flow:
  # `bp cloud support add --ws default` (internal/cli/cloud_support_cmd.go)
  # runs SupportResetDefaultWorkspaceStep → SupportAdminTokenStep (whose
  # `Seeds.Shared.ensure_default_scope/0` re-mints an EMPTY default workspace)
  # → merge-import, and the PDS-D9 adopt branch below then replaces that empty
  # shell with the imported workspace ON PURPOSE. At that import the seat is
  # OCCUPIED, so this guard is silent and the adopt branch is unchanged.
  #
  # STATED PLAINLY, because it is the residue: the shell-eviction arm — a
  # bundle whose root slug is `default` landing while the seat is held by an
  # EMPTY workspace — is state-identical to that supported flow. Nothing the
  # engine can read off the database tells the two apart; only the CALLER'S
  # INTENT does, and the intent signal exists but does not reach here:
  # `POST /api/workspaces/:workspace_slug/import` carries the operator's named
  # target in the path and `WorkspaceController.import/2` discards it (its
  # sibling `export/2` binds on it). Closing that arm means threading the
  # request's `:workspace_slug` into the engine as an expectation and refusing
  # a manifest that disagrees — a controller change, filed separately rather
  # than guessed at here.
  #
  # The refusal is an `InvalidBundleError`, matching `assert_member_tables!/1`:
  # a bundle that cannot be landed on THIS instance is a caller-fixable 422 at
  # the HTTP edge, not an opaque 500.
  defp vacant_reserved_slugs do
    reserved = Tenancy.reserved_workspace_slugs()

    held =
      Repo.query!("SELECT slug FROM workspaces WHERE slug = ANY($1::text[])", [reserved]).rows
      |> List.flatten()
      |> MapSet.new()

    Enum.reject(reserved, &MapSet.member?(held, &1))
  end

  defp assert_root_slug_not_vacant_reserved!(manifest, vacant_reserved) do
    slug = manifest["workspace_slug"]

    if slug in vacant_reserved do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message:
          "bundle root workspace slug #{inspect(slug)} is reserved on this instance and its " <>
            "seat is currently VACANT — a raw-COPY import would CLAIM it without ever " <>
            "reaching Workspace.changeset/2. Re-establish the seat first " <>
            "(Seeds.Shared.ensure_default_scope/0, or the support chain's " <>
            "SupportAdminTokenStep) so the import lands on the PDS-D9 adopt branch, or " <>
            "re-export the bundle under a slug that is not reserved."
    end
  end

  defp assert_reserved_seats_still_vacant!(vacant_reserved) do
    claimed =
      Repo.query!(
        "SELECT slug, id::text FROM workspaces WHERE slug = ANY($1::text[]) ORDER BY slug",
        [vacant_reserved]
      ).rows

    if claimed != [] do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message:
          "the bundle's rows CLAIMED reserved workspace slug(s) whose seat was vacant before " <>
            "the import: " <>
            Enum.map_join(claimed, ", ", fn [slug, id] -> "#{inspect(slug)} -> #{id}" end) <>
            " — the manifest's declared workspace_slug did not match the workspaces row it " <>
            "carried."
    end
  end

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
    document_count =
      Repo.query!("SELECT count(*) FROM documents WHERE workspace_id = $1::text::uuid", [ws_id]).rows
      |> hd()
      |> hd()

    media_count =
      Repo.query!("SELECT count(*) FROM media_files WHERE workspace_id = $1::text::uuid", [ws_id]).rows
      |> hd()
      |> hd()

    document_count == 0 and media_count == 0
  end

  # ── Cross-tenant blob-path refusal (task-918106d49c62563e) ──────────────────
  #
  # THE FAILURE MODE, AS IT WAS. The blob keyspace was FLAT: `Blobstore`
  # resolved an object by the very string `media_files.path` holds
  # (`Media.serve/2` → `Blobstore.serve_strategy(file.path)`), while
  # `media_files` uniqueness is `(path, dataset_id)` — NOT path alone. Two
  # workspaces could therefore hold a row at ONE path, and the loser's OWN
  # scoped `GET /w/:ws/p/:proj/media/files/*path` answered 200 carrying the
  # winner's bytes: a silent, cross-tenant, read-side substitution.
  #
  # THE READ IS NOW SEALED (task-8eb6542ece62aff1) — read this refusal as
  # defence in depth, not as the only wall. `media_files.object_key` holds each
  # row's own object address and every byte-resolving consumer goes through
  # `Barkpark.Media.Storage.ObjectKey.for_row/1`, so a flat path resolves only
  # within the tenant whose row matched. `authorize_blob_key/2` also stopped
  # being a wedge: a second claimant's push now lands at its OWN address instead
  # of being refused `:blob_key_not_owned`. Refusing the COPY here is still
  # right — it keeps the contested state from being constructed at all, which is
  # cheaper than resolving it — but it is no longer load-bearing for the read.
  #
  # WHY THE IMPORT. Import paths are copied VERBATIM from the source instance,
  # so a bundle whose media paths already belong to a resident workspace
  # CONSTRUCTS the collision rather than chancing it (`unique_filename/1` carries
  # 32 bits — accidental collision is ~1 in 4.3e9 and was never the reachable
  # case).
  #
  # WHY ROW-COPY TIME, not blob-push time. Push time is already where the
  # failure SURFACES: by then the rows exist and the loser's row points at the
  # winner's object, so refusing the push reproduces exactly the wedged,
  # victim-unrepairable state the guard exists to prevent. This runs inside the
  # import transaction the instant the `media_files` member's COPY completes, so
  # `Repo.rollback/1` un-creates the row — nothing ever becomes visible to a
  # reader and no blob is ever pushed.
  #
  # FAIL CLOSED on both foreign shapes, mirroring `authorize_blob_key/2`:
  #   * a resident row at this path owned by a DIFFERENT workspace, and
  #   * a resident row owned by NO workspace (`workspace_id IS NULL`) — the
  #     legacy layer, which `Content.Scope.scope_to_workspace_or_global/3`
  #     serves to EVERY tenant, so sharing its key is the same substitution with
  #     a wider blast radius.
  #
  # The operator remedy is named in the error: the resident owner's row (or the
  # incoming one) must be re-pathed before the import can proceed. Silently
  # importing is the one outcome that is never acceptable.
  #
  # Only fires for the `media_files` member, and only when the bundle actually
  # CARRIED rows into it — a 0-row member cannot construct a collision, and
  # refusing an unrelated import over a pre-existing one would be a new failure
  # of its own.
  defp assert_no_foreign_blob_path_collision!("media_files", rows, manifest) when rows > 0 do
    ws_id = manifest["workspace_id"]

    # `count(*) OVER ()` is evaluated over the FULL result set before LIMIT, so
    # one round trip yields both the exact total and a bounded sample — a
    # thousand-file collision never materialises a thousand rows in the BEAM.
    conflicts =
      Repo.query!(
        """
        SELECT mine.path, other.workspace_id::text, count(*) OVER () AS total
        FROM media_files mine
        JOIN media_files other ON other.path = mine.path
        WHERE mine.workspace_id = $1::text::uuid
          AND (other.workspace_id IS NULL OR other.workspace_id <> $1::text::uuid)
        ORDER BY mine.path
        LIMIT 10
        """,
        [ws_id]
      ).rows

    case conflicts do
      [] ->
        :ok

      [[_path, _owner, total] | _] = sample ->
        Repo.rollback(
          {:blob_path_conflict,
           %{
             workspace_id: ws_id,
             count: total,
             sample:
               Enum.map(sample, fn [path, owner, _total] ->
                 %{path: path, owner_workspace_id: owner}
               end)
           }}
        )
    end
  end

  defp assert_no_foreign_blob_path_collision!(_table, _rows, _manifest), do: :ok

  # ── COPY sources: a binary dump or a member file on disk ─────────────────────
  #
  # `import_bundle/2` hands each member as BYTES; `import_bundle_file/2` hands
  # `{:file, path}` and the bytes never enter the BEAM whole. Both end in the
  # same `Enum.into(source, stream)` — `Ecto.Adapters.SQL.stream/4` collects any
  # enumerable of iodata into `COPY … FROM STDIN`, and COPY FROM STDIN is a BYTE
  # stream, so a 64 KiB chunk boundary mid-row is safe (it is exactly what the
  # wire protocol does anyway).
  @copy_chunk_bytes 65_536

  # File-backed members are paths returned by Archive.unpack_to_dir/2 after its
  # separator/type traversal gate; callers cannot supply an arbitrary path here.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_source({:file, path}), do: File.stream!(path, @copy_chunk_bytes)
  defp copy_source(dump) when is_binary(dump), do: [dump]

  # Free the member the MOMENT it is in Postgres. Peak transient disk is what
  # this slice trades BEAM peak for, so holding every extracted member until the
  # import finishes would make the scratch as large as the whole bundle again.
  # The same Archive traversal gate proves this is an extracted member path.
  # sobelow_skip ["Traversal.FileModule"]
  defp release_member({:file, path}), do: File.rm(path)
  defp release_member(dump) when is_binary(dump), do: :ok

  defp import_member(%{"row_count" => 0}, dump, _mode) do
    release_member(dump)
    0
  end

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

    release_member(dump)

    entry["row_count"]
  end

  # Direct COPY FROM STDIN into the real table (clean target). Postgres
  # re-generates any generated column absent from the column list.
  # Every interpolated identifier is double-quoted by qi/1; COPY data remains a
  # protocol stream and never enters the SQL text.
  # sobelow_skip ["SQL.Stream"]
  defp copy_into(qualified_table, col_list, dump) do
    stream =
      Ecto.Adapters.SQL.stream(Repo, "COPY #{qualified_table} (#{col_list}) FROM STDIN", [])

    Enum.into(copy_source(dump), stream)
  end

  # Idempotent import (charter D7): COPY into a temp shaped like the target, then
  # INSERT … SELECT … ON CONFLICT DO NOTHING so a shared, non-workspace-unique
  # row (e.g. authoring_exemptions (doc_id, dataset)) is a no-op instead of a
  # crash. COPY-to-temp does the text→type casting for free.
  # `table`, every column, and the generated temp name are identifier-quoted by
  # qi/1; none of the streamed COPY bytes are interpolated into SQL.
  # sobelow_skip ["SQL.Query", "SQL.Stream"]
  defp insert_on_conflict(table, col_list, dump) do
    tmp = "_bp_imp_#{:erlang.unique_integer([:positive])}"

    Repo.query!(
      "CREATE TEMP TABLE #{qi(tmp)} (LIKE #{qi(table)} INCLUDING DEFAULTS) ON COMMIT DROP",
      []
    )

    stream = Ecto.Adapters.SQL.stream(Repo, "COPY #{qi(tmp)} (#{col_list}) FROM STDIN", [])
    Enum.into(copy_source(dump), stream)

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
  # All manifest identifiers pass through qi/1, including the conflict arbiter
  # and update targets; `action` is assembled only from fixed SQL tokens.
  # sobelow_skip ["SQL.Query", "SQL.Stream"]
  defp merge_upsert(table, cols, order_cols, dump)
       when is_list(order_cols) and order_cols != [] do
    col_list = cols |> Enum.map(&qi/1) |> Enum.join(", ")
    tmp = "_bp_mrg_#{:erlang.unique_integer([:positive])}"

    Repo.query!(
      "CREATE TEMP TABLE #{qi(tmp)} (LIKE #{qi(table)} INCLUDING DEFAULTS) ON COMMIT DROP",
      []
    )

    stream = Ecto.Adapters.SQL.stream(Repo, "COPY #{qi(tmp)} (#{col_list}) FROM STDIN", [])
    Enum.into(copy_source(dump), stream)

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

  # ── SQL identifier / hashing helpers ─────────────────────────────────────────

  # Double-quote an identifier (column/table name). The quote-doubling is the
  # ACTUAL control here, not belt-and-suspenders — on the IMPORT path these
  # names are REQUEST-DERIVED, not catalog-derived.
  #
  #   * export: names come from the live catalog (`table_exists?/1`-filtered),
  #     so nothing attacker-shaped reaches this function.
  #   * import: `import_member/3` reads `entry["name"]` and `entry["columns"]`
  #     straight off the uploaded tar manifest. `assert_member_tables!/1`
  #     (felix-w25-s3) now refuses, before any write, any manifest TABLE that
  #     exists on the target but is outside the export-side catalog
  #     enumeration — but that is a membership gate, NOT input laundering:
  #     member COLUMN names, and the name of a table ABSENT on this schema
  #     version (tolerated for cross-version bundles), still reach the
  #     interpolated statements below as manifest strings.
  #
  # Those sites are defended by quoting plus the membership guard plus an
  # ADMIN GATE (the router's `:require_admin` pipeline), with `:merge`
  # additionally fail-closed behind the `:allow_bundle_import` config. That is
  # the honest waiver: request-derived identifiers behind correct quoting, a
  # membership refusal for existing non-member tables, and an admin gate.
  # Calling them catalog-derived would still be a FALSE annotation on the one
  # bucket where a real injection could hide — so do not weaken the quoting,
  # and do not extend this helper's callers on the import path without a
  # `table_exists?/1` check.
  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")
end
