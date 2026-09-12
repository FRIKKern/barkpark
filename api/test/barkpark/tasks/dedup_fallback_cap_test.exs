defmodule Barkpark.Tasks.DedupFallbackCapTest do
  @moduledoc """
  The UNFILTERED fallback scans do not inherit the KNN candidate cap
  (task-4671d136b2c568b4).

  `Tasks.Dedup` has two fetch shapes. The probe-title shape orders by the trgm
  KNN distance `title <-> $1`, so the rows `@candidate_limit` discards are the
  LEAST title-similar — that ordering is the entire justification for cutting
  the cap from 5,000 to 500 in PR #14061.

  The two UNFILTERED shapes have no such ordering. They are
  `DISTINCT ON (canonical doc_id)` ASCENDING under a LIMIT, i.e. an ALPHABETIC
  cut — the exact blind spot #14061 retired on the working path. They are
  reached from two places, and before this change both handed that clause the
  KNN cap:

    1. a blank probe title (`similarity(x, '')` matches nothing, so the module
       falls back rather than run a gate that matches nothing and reports
       success), and
    2. a `Postgrex.Error` for a missing `<->` operator — an install without
       `pg_trgm`.

  ## What reds each test

  Both tests drive a corpus LARGER than the KNN cap with the real
  near-duplicate sorting LAST by canonical id, and assert the refusal still
  fires. Restoring the inherited cap (`fetch_rows(…, limit, "")`, or a single
  `:dedup_candidate_limit` that sets both numbers) makes the alphabetically-late
  duplicate invisible and both tests go green-on-`:ok` — i.e. they fail.

  The third test is the shape control: the truncation warning and telemetry
  must not describe an unfiltered bind as "the MOST TITLE-SIMILAR", which is the
  half of this row that matters most for a module whose thesis is honest gates.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}

  @dataset "production"

  @rate_limit "add rate limiting to the mutate controller"
  @rate_limit_desc "throttle writes on the REST mutate endpoint per token bucket"

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

    # The same two-axis fixture `DedupTest` tunes: the fillers are TRIGRAM-NEAR
    # the probe (so they survive the pre-filter and really do occupy candidate
    # slots) and TOKEN-FAR (so they cannot themselves refuse). `z-dupe` is the
    # real near-duplicate and sorts LAST under `DISTINCT ON (doc_id) ASC` — the
    # construction that put every live `task-*` id past the cut on guerrilla.
    {:ok, _} =
      create_task("a-filler-one", "add rate throttling to the mutation controllers", scope)

    {:ok, _} = create_task("b-filler-two", "add rate limiters to the mutating controls", scope)
    {:ok, _} = create_task("z-dupe", @rate_limit, scope, %{"description" => @rate_limit_desc})

    %{scope: scope}
  end

  defp create_task(doc_id, title, scope, extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  defp check(doc_id, opts) do
    Tasks.Dedup.check_new_task(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => @rate_limit,
        "content" => %{"kind" => "task", "description" => @rate_limit_desc}
      },
      @dataset,
      nil,
      opts
    )
  end

  describe "the blank-probe fallback" do
    test "still finds an alphabetically-LATE duplicate with the KNN cap at 1", %{scope: scope} do
      # `dedup_candidate_limit: 1` is the KNN cap only. Three eligible rows > 1,
      # so if the fallback inherited it, the scan would read `a-filler-one` and
      # stop, and `z-dupe` — the actual duplicate — would never be compared.
      opts =
        scope
        |> Keyword.put(:probe_title, "")
        |> Keyword.put(:dedup_candidate_limit, 1)

      assert {:error, {:duplicate_task, payload}} = check("blank-probe-new", opts)
      assert [%{id: "z-dupe"} | _] = payload.similar

      # And the scan reports the cap it ACTUALLY applied, not the KNN one.
      assert payload.scan.candidate_limit == 5_000
      assert payload.scan.truncated == false
    end

    test "honours an explicit unfiltered override, so the cap is still testable", %{scope: scope} do
      # CONTROL for the test above: the fallback is not simply unbounded. Cap the
      # UNFILTERED shape at 1 and the same duplicate goes missing — which is what
      # proves the first test measured the cap and not some other effect.
      opts =
        scope
        |> Keyword.put(:probe_title, "")
        |> Keyword.put(:dedup_unfiltered_candidate_limit, 1)

      assert :ok = check("blank-probe-capped", opts)
    end
  end

  describe "the pg_trgm-unavailable fallback" do
    test "still finds an alphabetically-LATE duplicate with the KNN cap at 1", %{scope: scope} do
      # A real install without the extension, reproduced inside the sandbox
      # transaction: every `<->` then raises SQLSTATE 42883 and `fetch_rows/6`'s
      # narrow rescue re-enters the unfiltered clause. CASCADE drops the GiST
      # index with it; both come back on rollback.
      Repo.query!("DROP EXTENSION IF EXISTS pg_trgm CASCADE")

      opts = Keyword.put(scope, :dedup_candidate_limit, 1)

      log =
        capture_log(fn ->
          assert {:error, {:duplicate_task, payload}} = check("no-trgm-new", opts)
          assert [%{id: "z-dupe"} | _] = payload.similar
          assert payload.scan.candidate_limit == 5_000
        end)

      # The warning must say what the fallback ACTUALLY is. "Detection is
      # unaffected" was the false half: on this shape the cut is alphabetic, so
      # detection is affected, by construction.
      assert log =~ "pg_trgm is unavailable"
      assert log =~ "ALPHABETICAL"
      refute log =~ "Detection is unaffected"
    end
  end

  describe "the truncation notice names the SHAPE" do
    test "an unfiltered bind is never reported as most-title-similar", %{scope: scope} do
      :telemetry.attach(
        "dedup-fallback-shape-#{inspect(self())}",
        [:barkpark, :tasks, :dedup, :scan_truncated],
        fn _e, measurements, metadata, pid -> send(pid, {:truncated, measurements, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("dedup-fallback-shape-#{inspect(self())}") end)

      opts =
        scope
        |> Keyword.put(:probe_title, "")
        |> Keyword.put(:dedup_unfiltered_candidate_limit, 1)

      log = capture_log(fn -> assert :ok = check("shape-note-new", opts) end)

      assert log =~ "Tasks.Dedup scan TRUNCATED"
      assert log =~ "ALPHABETICALLY-FIRST"
      refute log =~ "MOST TITLE-SIMILAR"

      assert_received {:truncated, %{returned: 1, limit: 1}, %{shape: :unfiltered}}
    end
  end
end
