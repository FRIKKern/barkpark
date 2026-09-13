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

  `DedupFallbackCapTest` already drops the extension for real and proves the
  fallback still REFUSES an alphabetically-late duplicate. What it does not
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

  # A real install without the extension, reproduced inside the sandbox
  # transaction — CASCADE takes the GiST index with it, and the rollback at the
  # end of the test brings both back.
  defp drop_pg_trgm! do
    Repo.query!("DROP EXTENSION IF EXISTS pg_trgm CASCADE")
  end

  describe "what a box without pg_trgm actually reports" do
    test "the `<->` operator raises SQLSTATE 42883 undefined_function, which the rescue covers" do
      drop_pg_trgm!()

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
      drop_pg_trgm!()

      # Postgres accepts any dotted "customized option" name, extension or not.
      # A fresh-install check built on this statement would report healthy.
      assert {:ok, _} = Repo.query("SET LOCAL pg_trgm.similarity_threshold = 0.3")
    end
  end

  describe "the rescue keeps a fresh install usable (mutant D)" do
    test "a genuinely new task still CREATES with the extension gone", %{scope: scope} do
      drop_pg_trgm!()

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
      drop_pg_trgm!()

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
      Repo.query!("ALTER TABLE documents DROP COLUMN title CASCADE")

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
