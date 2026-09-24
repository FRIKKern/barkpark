defmodule Barkpark.Tasks.DedupTrgmAbsentTest do
  @moduledoc """
  The pg_trgm-absent rescue in `Tasks.Dedup.fetch_rows/6` — mutant D, the arm
  PR #14061's own mutation matrix skipped (task-2aa305bfa90fdebd).

  THE NAMED FAILURE MODE. `pg_trgm` is optional: `Application.check_pg_trgm/0`
  WARNS rather than crashes, so a legitimate Barkpark can run without the `<->`
  operator. If `trgm_unavailable?/1`'s code set is wrong for the error Postgrex
  actually reports on such a box, the rescue reraises, `fetch_candidates/2`
  turns it into `{:degraded, _}` and `check_new_task/5` answers
  `{:error, {:dedup_unavailable, _}}` — i.e. EVERY task create on a fresh
  install is refused 503, caused by a performance fix. The clause is
  load-bearing by its author's own argument and was the one load-bearing branch
  nothing exercised.

  ## What each test is for, and what reds it

    * `the error a box without pg_trgm really raises` PINS THE CODE SET against
      what Postgres actually reports, rather than against a hand-built
      `Postgrex.Error` — which would only prove the predicate matches itself.
      It reds if the real SQLSTATE ever leaves `[:undefined_function,
      :undefined_object, :undefined_table]`.
    * `SET LOCAL pg_trgm.similarity_threshold does not raise` is the row's own
      caveat as a control: Postgres accepts any dotted "customized option" name,
      so that statement CANNOT be the probe for a missing extension.
    * `a create still succeeds` is MUTANT D. Flip `trgm_unavailable?/1` to
      return false (or narrow its code set to the wrong error) and this test
      goes red with `{:error, {:dedup_unavailable, …}}` — the fresh-install
      lockout, reproduced.

  Neither module drops the extension: `hide_pg_trgm!/0` hides the `<->`
  operator from `search_path` instead, so the real 42883 still fires without
  catalog DDL on the shared test database (see its comment). The LOUD-degrade
  control likewise hides `title` behind a temp view (`hide_title_column!/0`)
  rather than dropping the column.

  `DedupFallbackCapTest` already proves the fallback still REFUSES an
  alphabetically-late duplicate. What it does not
  cover — and what the 503 failure mode is actually about — is a NON-duplicate
  create surviving the same conditions, and the error code itself.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}

  @dataset "production"

  # Verbatim from `Barkpark.Tasks.Dedup.trgm_unavailable?/1` (it is private, so
  # this is the code set restated; the first test is what keeps the two honest).
  @rescued_codes [:undefined_function, :undefined_object, :undefined_table]

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    {:ok, _} =
      create_task(
        "trgm-absent-existing",
        "add rate limiting to the mutate controller",
        scope,
        %{"description" => "throttle writes on the REST mutate endpoint per token bucket"}
      )

    %{scope: scope}
  end

  defp create_task(doc_id, title, scope, extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  defp check(doc_id, title, description, opts) do
    Tasks.Dedup.check_new_task(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => title,
        "content" => %{"kind" => "task", "description" => description}
      },
      @dataset,
      nil,
      opts
    )
  end

  # A box without the extension, as the dedup query sees it. `<->` is
  # unqualified SQL, so Postgres resolves it through `search_path`, and pg_trgm
  # installs it in `public`. A temp view named `documents` over
  # `public.documents`, plus an EMPTY search_path, leaves the table reachable
  # (pg_temp is searched first for relations) and the operator not (pg_temp is
  # never searched for operators, pg_catalog does not have it). The query then
  # raises the same 42883 a box without pg_trgm raises — the first test below
  # measures that rather than assuming it.
  #
  # It used to `DROP EXTENSION pg_trgm CASCADE` inside the sandbox txn. That is
  # catalog DDL on the ONE shared test database, and a concurrent session using a
  # pg_trgm function made it fail with XX000 "cache lookup failed for function"
  # (main run 35980575238). Both objects here are private to this backend and
  # transaction-scoped: the rollback at test end removes the view and the SET.
  # Twin: `DedupFallbackCapTest.hide_pg_trgm!/0`.
  defp hide_pg_trgm! do
    Repo.query!("CREATE TEMP VIEW documents AS SELECT * FROM public.documents")
    Repo.query!("SET LOCAL search_path TO ''")
  end

  # A `documents` with no `title` column, as the dedup query sees it — for the
  # LOUD-degrade control below, which needs a Postgres error OUTSIDE the rescued
  # code set. Same seam as `hide_pg_trgm!/0`: a temp view named `documents`
  # shadows `public.documents` (pg_temp is searched first for relations, and
  # `Document` is an unprefixed schema), here projecting every column EXCEPT
  # `title`, so `d0.title` raises 42703 undefined_column.
  #
  # It used to `ALTER TABLE documents DROP COLUMN title CASCADE` inside the
  # sandbox txn: an ACCESS EXCLUSIVE lock on the shared `documents` table until
  # rollback, plus catalog DDL on the ONE shared test database — the race class
  # of the DROP EXTENSION above (task-97d01059eb906830). The view is private to
  # this backend and dropped by the test's rollback.
  defp hide_title_column! do
    %{rows: [[cols]]} =
      Repo.query!("""
      SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum)
      FROM pg_attribute
      WHERE attrelid = 'public.documents'::regclass
        AND attnum > 0 AND NOT attisdropped AND attname <> 'title'
      """)

    Repo.query!("CREATE TEMP VIEW documents AS SELECT #{cols} FROM public.documents")
  end

  describe "what a box without pg_trgm actually reports" do
    test "the `<->` operator raises SQLSTATE 42883 undefined_function, which the rescue covers" do
      hide_pg_trgm!()

      assert {:error, %Postgrex.Error{postgres: pg}} =
               Repo.query("SELECT title <-> $1 FROM documents LIMIT 1", ["probe"])

      # THE RECORDED ANSWER, measured rather than assumed: this is what the
      # `undefined_function` atom stands for on the wire.
      assert pg.code == :undefined_function
      assert pg.pg_code == "42883"

      # …and it IS inside the set the rescue matches on. If this ever fails, the
      # rescue reraises and every create on a fresh install is refused 503.
      assert pg.code in @rescued_codes
    end

    test "SET LOCAL pg_trgm.similarity_threshold does NOT raise, so it cannot be the probe" do
      hide_pg_trgm!()

      # Postgres accepts any dotted "customized option" name, extension or not.
      # A fresh-install check built on this statement would report healthy.
      assert {:ok, _} = Repo.query("SET LOCAL pg_trgm.similarity_threshold = 0.3")

      # The extension is only HIDDEN here, not gone, so the line above cannot by
      # itself show "extension or not". This prefix belongs to no extension
      # anywhere, and Postgres accepts it all the same.
      assert {:ok, _} = Repo.query("SET LOCAL barkpark_no_such_ext.similarity_threshold = 0.3")
    end
  end

  describe "the rescue keeps a fresh install usable (mutant D)" do
    test "a genuinely new task still CREATES with the extension gone", %{scope: scope} do
      hide_pg_trgm!()

      log =
        capture_log(fn ->
          # Not a duplicate of anything in the corpus — the outcome under test is
          # that the gate RAN and passed, not that it refused.
          assert :ok =
                   check(
                     "trgm-absent-new",
                     "publish the quarterly royalty statement exporter",
                     "emit ONIX royalty statements as a quarterly CSV for finance",
                     scope
                   )
        end)

      assert log =~ "pg_trgm is unavailable"
      assert log =~ "CREATE EXTENSION IF NOT EXISTS pg_trgm"
    end

    test "a real duplicate is still REFUSED with the extension gone", %{scope: scope} do
      # CONTROL for the test above: the fallback is a working gate, not a hole.
      # Without this, `:ok` above would also be produced by a scan that returned
      # nothing at all.
      hide_pg_trgm!()

      capture_log(fn ->
        assert {:error, {:duplicate_task, payload}} =
                 check(
                   "trgm-absent-dupe",
                   "add rate limiting to the mutate controller",
                   "throttle writes on the REST mutate endpoint per token bucket",
                   scope
                 )

        assert [%{id: "trgm-absent-existing"} | _] = payload.similar
      end)
    end

    test "a Postgrex error OUTSIDE the code set still degrades LOUD", %{scope: scope} do
      # The OTHER control, and the one that keeps the rescue narrow: a Postgres
      # error that is NOT the missing operator must still become the named 503.
      # Widening this clause to a bare `rescue` would rebuild the silent
      # fail-open the module exists to kill — an unfiltered retry after a REAL
      # failure answering "no duplicate" from an empty set — and nothing above
      # would notice. `undefined_column` (42703) is outside
      # #{inspect(@rescued_codes)} by construction.
      #
      # WHAT REDS THIS, measured (task-97d01059eb906830): neutering the degrade
      # branch in `fetch_candidates/2` (fail open to `{:ok, [], _}`) reds it with
      # `right: :ok`. WIDENING `trgm_unavailable?/1` to include 42703 does NOT:
      # the unfiltered retry also selects `d.title`, raises the same 42703, and
      # still degrades. This test guards the degrade branch, not the code set's
      # narrowness — that needs an error only the `<->` query raises.
      hide_title_column!()

      # PRECONDITION, measured: the shadow really does raise 42703 on the column
      # the dedup query reads, and the table itself is untouched for everyone else.
      assert {:error, %Postgrex.Error{postgres: %{code: :undefined_column, pg_code: "42703"}}} =
               Repo.query("SELECT title FROM documents LIMIT 1")

      refute :undefined_column in @rescued_codes

      assert {:ok, %{rows: [[1]]}} =
               Repo.query(
                 "SELECT 1 FROM information_schema.columns " <>
                   "WHERE table_schema = 'public' AND table_name = 'documents' " <>
                   "AND column_name = 'title'"
               )

      assert {:error, {:dedup_unavailable, message}} =
               check(
                 "trgm-absent-degraded",
                 "publish the quarterly royalty statement exporter",
                 "emit ONIX royalty statements as a quarterly CSV for finance",
                 scope
               )

      assert message =~ "could not complete"
    end
  end
end
