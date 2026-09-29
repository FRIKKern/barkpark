defmodule Barkpark.Plugins.Github.IntakeDedupOutageTest do
  @moduledoc """
  THE DEDUP OUTAGE ON THE GITHUB INBOUND DOOR (jpf-bl-intake-dedup-clause-test).

  `Intake.birth/2` forwards `{:error, {:dedup_unavailable, reason}}` untouched,
  and `GithubWebhookController.receive/2` answers that with a 500
  `intake_failed`. Together they are the one rule that keeps a TRANSIENT dedup
  outage from being answered 2xx — which would drop the outsider's issue with
  no record anywhere, because a 2xx is final.

  ## Why the obvious greps did not settle this, and what did

  Before this file, `git grep dedup_unavailable -- api/test` hit seven files and
  `intake_failed` was asserted at
  `github_webhook_controller_test.exs` ("a genuine intake failure ({:error, _})
  answers 5xx"). Neither fact says the ARM is pinned. That controller assertion
  drives the stub with `{:error, :db_unavailable}`: it proves the generic
  catch-all maps to 500, and a DIFFERENT error reaching the same mapping
  satisfies it identically. Nothing anywhere asserted where a
  `{:dedup_unavailable, _}` in particular LANDS.

  Reachability was settled by deleting, not by grepping. Measured at
  `origin/main` 06120ffc8, over `test/barkpark/plugins/github/` plus the
  controller test plus all seven `dedup_unavailable` files (609 tests):

  | mutation to `api/lib` | before this file |
  |---|---|
  | delete the Intake `{:error, {:dedup_unavailable, reason}}` clause outright | 609 tests, 0 failures — and it is a **semantic no-op**: the `{:error, reason}` catch-all below it returns the identical tuple, so the clause's only unique effect is its log line |
  | make that clause return `{:refused, :vetoed, doc_id}` (the real silent drop) | 609 tests, 0 failures |
  | give the controller a `{:error, {:dedup_unavailable, _}}` → 202 arm | 609 tests, 0 failures |
  | rename the catch-all's `code: "intake_failed"` | **25 tests, 1 failure** — the generic mapping was already pinned |

  So the row's premise needs one correction worth keeping: deleting the Intake
  clause does NOT by itself restore the silent drop — the `{:error, reason}`
  catch-all returns the identical tuple, so the clause's only UNIQUE effect is
  its log line. The live hazard is the SEMANTIC one: an edit that files the
  outage next to its look-alike neighbour, the deterministic
  `{:error, {:halted, _}}` veto, which is correctly a 2xx. The two arms sit
  adjacent in `birth/2` and read almost identically.

  With this file, re-measured over `test/barkpark/plugins/github/` plus the
  controller test (518 tests): the plain deletion reds **on the log
  assertion** — the clause's only unique effect, and the operator's only notice
  that a delivery needs re-sending — and the `{:refused, :vetoed, doc_id}`
  mutation reds **on the returned shape**. 518 tests, 1 failure each.

  ## How the outage is staged

  `Content.DedupWall` takes its default scan budget from
  `Application.get_env(:barkpark, :dedup_timeout_ms)`, a read compiled out of
  every non-`:test` build (see the seam comment in `dedup_wall.ex`). A `0`
  budget is refused BEFORE the connection pool is touched, so the degraded arm
  is deterministic and never a checkout race. `task` is one of
  `AuthoringWall`'s `@walled_types`, so a GitHub birth runs the real gate.

  Every outage assertion is paired with a CONTROL running the identical call
  with the override unset, so no test here can pass by the birth path being
  broken for another reason.

  ## One thing this file does NOT claim

  GitHub does not auto-redeliver a 5xx: redelivery is manual or API-triggered.
  The 500 is not self-healing. Its whole value is being LOUD AND FINDABLE —
  a failed delivery in the repo's webhook log and an error line in ours —
  instead of a 2xx that leaves no trace at either end.

  `async: false`, like `intake_test.exs`: the birth path reaches the
  `Github.Auth` GenServer unless the `comment_fun` seam is threaded, and a
  GenServer outside the test process needs the SHARED sandbox.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Github.Intake

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  # The `comment_fun` seam keeps the CONTROL's birth off the network AND out of
  # the `Github.Auth` GenServer, which owns no sandbox connection of its own.
  defp opts(scope) do
    test_pid = self()

    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, "FRIKKern/barkpark")
    |> Keyword.put(:comment_fun, fn repo, number, body, _o ->
      send(test_pid, {:comment, repo, number, body})
      {:ok, %{"id" => 1}}
    end)
  end

  defp opened_payload(number) do
    %{
      "action" => "opened",
      "issue" => %{
        "number" => number,
        "title" => "Outsider found a bug",
        "body" => "Steps to reproduce: click the thing.",
        "user" => %{"login" => "outsider", "type" => "User"}
      },
      "sender" => %{"login" => "outsider", "type" => "User"},
      "repository" => %{"full_name" => "FRIKKern/barkpark"}
    }
  end

  # THE INJECTOR, and why it is this one. A non-numeric scan budget makes
  # `Tasks.Dedup`'s bounded `Repo.all/2` raise inside `fetch_candidates/2`,
  # which its rescue turns into the module's `{:error, {:dedup_unavailable, _}}`
  # — the exact tuple `Intake` must forward. It raises BEFORE any I/O, so the
  # sandbox connection survives and this test can still query afterwards.
  #
  # The two infra-class levers were both tried first and both REJECTED, with
  # numbers: `workspace_id: "not-a-uuid"` (the lever
  # `tasks/dedup_test.exs:check_with_failing_scan/3` uses) never reaches the
  # gate through `Intake` — the scope cast fails earlier, in the schema lookup;
  # and a non-positive `dedup_timeout_ms` kills the sandbox connection
  # mid-ingest, which flaked 2 of 8 and then 1 of 6 runs with
  # `DBConnection.OwnershipError`. `Tasks.Dedup` has no non-positive-budget
  # guard of the kind `Content.DedupWall.fetch_candidates/4` carries, so a
  # 0ms budget there IS the coin-flip that module's comment describes.
  #
  # The message class differs from a real database outage (DEFECT vs outage —
  # see `tasks/dedup_defect_message_test.exs`, which pins both). That split is
  # downstream of this file's subject: `Intake` and the controller see ONE
  # tuple shape, `{:error, {:dedup_unavailable, _}}`, and treat both classes
  # identically.
  defp task_rows(number) do
    like = "%gh-#{number}"

    Repo.all(
      from(d in Content.Document,
        where: d.type == "task" and like(d.doc_id, ^like),
        select: d.doc_id
      )
    )
  end

  defp outage_opts(scope),
    do: scope |> opts() |> Keyword.put(:dedup_timeout_ms, :no_budget_at_all)

  describe "Intake forwards the outage tuple — it is never collapsed into a refusal" do
    test "a dedup outage returns {:error, {:dedup_unavailable, reason}} and births nothing",
         %{scope: scope} do
      log =
        capture_log(fn ->
          # The pattern is the assertion: ANY {:refused, _, _} (the 2xx family)
          # or {:ok, :born, _} would fail to match here. That is the whole
          # point — the hazard is this arm being filed next to the
          # deterministic `{:halted, _}` veto, which answers 2xx.
          assert {:error, {:dedup_unavailable, reason}} =
                   Intake.ingest(opened_payload(9401), outage_opts(scope))

          assert is_binary(reason)
          # The message names the gate and the consequence — nothing here
          # claims the issue was checked.
          assert reason =~ "task dedup gate"
          assert reason =~ "REFUSED rather than filed unchecked"
          assert reason =~ "no duplicate check ran"
        end)

      # The log line is the operator's half of "loud and findable" — GitHub
      # does not redeliver a 5xx on its own, so this line is how anyone learns
      # a delivery needs re-sending.
      assert log =~ "github intake: dedup gate unavailable for gh-9401"

      # Nothing half-tracked: the gate refuses before persistence, so a manual
      # redelivery re-runs the deterministic `gh-<num>` birth from scratch.
      assert task_rows(9401) == []

      # And no backlink comment was posted on an issue nothing was written for.
      refute_receive {:comment, _, _, _}
    end

    test "CONTROL: with a bindable workspace the same payload births normally",
         %{scope: scope} do
      assert {:ok, :born, doc} = Intake.ingest(opened_payload(9402), opts(scope))
      assert doc.doc_id == Content.draft_id("gh-9402")
    end
  end
end
