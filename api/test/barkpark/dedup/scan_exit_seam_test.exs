defmodule Barkpark.Dedup.ScanExitSeamTest do
  @moduledoc """
  THE COVERAGE FOR THE `catch :exit` ARM OF BOTH DEDUP CANDIDATE FETCHES.

  `Barkpark.Content.DedupWall` and `Barkpark.Tasks.Dedup` each carry a
  `catch :exit` beside their `rescue`, because a DBConnection pool checkout that
  dies arrives as an EXIT and a rescue-only clause would let it escape as a 500
  instead of the fail-LOUD `{:error, {:dedup_unavailable, _}}` refusal.

  That arm was landed UNPROVEN and it was not an oversight. Inside the Ecto SQL
  sandbox every failure mode that can be staged from a test — dead or live dummy
  dynamic repo, ownership timeout, unallowed process, `pg_terminate_backend`,
  query timeout 0 and 1, transaction timeout 0 and 1 — surfaces as an EXCEPTION
  and lands in the `rescue`. MEASURED: with BOTH catch clauses deleted from
  `main`, all 119 tests across the 15 dedup suites passed, exit 0.

  So the exit is injected, through `Barkpark.Dedup.ScanSeam` — one verb,
  `exit/1`, compiled in only under `MIX_ENV=test`. The seam sits INSIDE each
  fetch's try body, so these two cases are assertions about the catch clause and
  nothing else.

  A GREEN HERE WITH NO SUBJECT IS THE HAZARD, so:

    * the first test asserts the seam is actually compiled in — without it both
      cases below would pass on the ordinary no-duplicate path;
    * each case pins the surface's OWN log line, so a case cannot be satisfied
      by the other module's clause;
    * the cross-arm case proves `arm/2` is surface-scoped — arming one gate
      leaves the other running its normal, DB-backed scan.

  MUTATION CONTROL, run per surface and reported in the PR:
  deleting `catch :exit` from `Content.DedupWall` reds ONLY
  "DedupWall: a pool-checkout :exit during the candidate fetch becomes
  dedup_unavailable"; deleting it from `Tasks.Dedup` reds ONLY
  "Tasks.Dedup: a pool-checkout :exit during the candidate fetch becomes
  dedup_unavailable".
  """
  # `async: true` keeps this case on its own sandbox connection. The seam itself
  # never touches the pool — it exits BEFORE the query is built — so nothing here
  # can disturb another partition's connections.
  use Barkpark.DataCase, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.DedupWall
  alias Barkpark.Dedup.ScanSeam
  alias Barkpark.Tasks.Dedup

  @dataset "production"

  # The real shape a dying DBConnection checkout exits with.
  @checkout_death {:timeout, {DBConnection.Holder, :checkout, [:barkpark_pool, []]}}

  defp wall_doc do
    %{
      doc_id: "drafts.exit-seam-probe",
      title: "Rate limiting the mutate controller",
      content: %{"tags" => [%{"tag" => "rate-limiting"}, %{"tag" => "mutate"}]}
    }
  end

  defp task_attrs do
    %{
      "doc_id" => "exit-seam-probe",
      "title" => "Rate limiting the mutate controller",
      "content" => %{
        "kind" => "task",
        "description" => "the mutate controller has no rate limit at all"
      }
    }
  end

  test "THE PRECONDITION: the exit seam is compiled into this build" do
    # Without this, every assertion below is satisfiable by the ordinary
    # no-duplicate path and this file measures nothing.
    assert ScanSeam.enabled?(),
           "the ScanSeam is not compiled in — config/test.exs must set :dedup_scan_seam, " <>
             "and until it does the two exit cases below are vacuous"

    assert function_exported?(ScanSeam, :arm, 2)
    assert ScanSeam.check!(:content_dedup_wall) == :ok, "an UNARMED process must be a no-op"
    assert ScanSeam.check!(:tasks_dedup) == :ok, "an UNARMED process must be a no-op"
  end

  test "DedupWall: a pool-checkout :exit during the candidate fetch becomes dedup_unavailable" do
    :ok = ScanSeam.arm(:content_dedup_wall, @checkout_death)

    {result, log} =
      with_log(fn -> DedupWall.check(wall_doc(), "paper", @dataset) end)

    assert {:error, {:dedup_unavailable, message}} = result

    # The exit must be converted by the WALL's own catch clause, not by some
    # other rescue upstream: only that clause writes this sentence.
    assert log =~ "Content.DedupWall degraded: candidate fetch exited"
    assert message =~ "the duplicate scan was cut off by the database"
    assert message =~ "publish dedup wall could not complete"

    # And it is the OUTAGE arm, not the DEFECT arm — an exit is infrastructure.
    refute message =~ "DEFECT"
  end

  test "Tasks.Dedup: a pool-checkout :exit during the candidate fetch becomes dedup_unavailable" do
    :ok = ScanSeam.arm(:tasks_dedup, @checkout_death)

    {result, log} =
      with_log(fn -> Dedup.check_new_task("task", task_attrs(), @dataset, nil, []) end)

    assert {:error, {:dedup_unavailable, message}} = result

    assert log =~ "Tasks.Dedup degraded: candidate fetch exited"
    assert message =~ "the backlog scan was cut off by the database"
    assert message =~ "task dedup gate could not complete"

    refute message =~ "DEFECT"
  end

  test "the seam is surface-scoped: arming the task gate leaves the wall's scan alone" do
    # THE CONTROL THAT KEEPS THE TWO CASES INDEPENDENT. If `arm/2` were global,
    # one deleted catch clause could red both cases above and they would be
    # measuring one thing, not two.
    :ok = ScanSeam.arm(:tasks_dedup, @checkout_death)

    {result, log} = with_log(fn -> DedupWall.check(wall_doc(), "paper", @dataset) end)

    # An empty corpus and a real scan: `:ok`, not a refusal of any kind.
    assert result == :ok
    refute log =~ "Content.DedupWall degraded"

    # ... while the gate that IS armed still exits.
    assert {:error, {:dedup_unavailable, _}} =
             Dedup.check_new_task("task", task_attrs(), @dataset, nil, [])
  end

  test "an UNARMED process runs the real scan on both surfaces (the seam changes nothing)" do
    # c1's behavioural half, in the build where the seam EXISTS: unset means the
    # fetch proceeds exactly as it did before the seam was added.
    assert ScanSeam.check!(:content_dedup_wall) == :ok
    assert DedupWall.check(wall_doc(), "paper", @dataset) == :ok
    assert Dedup.check_new_task("task", task_attrs(), @dataset, nil, []) == :ok
  end
end
