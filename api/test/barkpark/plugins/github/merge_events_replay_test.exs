defmodule Barkpark.Plugins.Github.MergeEventsReplayTest do
  @moduledoc """
  REAL-ARTIFACT REPLAY — the diagnostic that discriminates candidate cause (b)
  ("the handler runs but returns a non-stamp outcome") from cause (a) ("the
  delivery never arrives").

  `merge_events_test.exs` proves the handler against SYNTHETIC payloads and
  SYNTHETIC criteria the test itself authored. That is exactly the green that
  could never have been red: it cannot tell you whether the handler would stamp
  the criteria REAL leads actually write, in response to the payload GitHub
  actually sends.

  This replays a captured production artifact — the merged `pull_request`
  payload for PR #12210 (`test/support/fixtures/github/pr-12210-merged.json`,
  fetched from `GET /repos/FRIKKern/barkpark/pulls/12210`) — against the REAL
  stored acceptance-criteria wording of `task-lifecycle-visibility-wave-6-log`
  as it stood at merge time (criterion 1 unmet, evidence empty). If the handler
  stamps it, cause (b) is refuted on real data and the failure is upstream of
  the handler.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.MergeEvents

  @dataset "production"

  # The doc_id the captured PR body's `Task:` trailer names.
  @real_doc_id "task-lifecycle-visibility-wave-6-log"

  # VERBATIM from the live ledger (`bp task get task-lifecycle-visibility-wave-6-log`),
  # with criterion 1 restored to its pre-hand-stamp state (met=false, evidence "").
  # The wording is the lead's own, not a test author's — that is the point.
  @real_criteria [
    %{
      "criterion" => "The wave-6 charter PR is opened and reports its checks",
      "met" => true,
      "evidence" => "PR #12210 was opened and ran its checks."
    },
    %{
      "criterion" => "PR merged to main (LEAD closes this criterion on merge)",
      "met" => false,
      "evidence" => "",
      "merge_gate" => true
    }
  ]

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{scope: scope}
  end

  defp captured_payload do
    Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "github", "pr-12210-merged.json"])
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
  end

  defp mk_real_task!(scope) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "in_progress",
      "acceptance_criteria" => @real_criteria
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => @real_doc_id, "title" => @real_doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  test "the captured PR #12210 payload carries exactly one resolvable Task: trailer" do
    payload = captured_payload()

    assert payload["action"] == "closed"
    assert get_in(payload, ["pull_request", "merged"]) == true

    assert get_in(payload, ["pull_request", "merge_commit_sha"]) ==
             "209cd542e83b09e11fcd970a4d712f49d4f531f8"

    body = get_in(payload, ["pull_request", "body"])

    ids =
      ~r/^\s*task:\s*([a-z0-9][a-z0-9._\/-]*)/im
      |> Regex.scan(body, capture: :all_but_first)
      |> Enum.map(fn [id] -> id end)
      |> Enum.uniq()

    # Not :no_trailer, not :ambiguous_trailer — the two (b) outcomes that would
    # have explained the miss.
    assert ids == [@real_doc_id]
  end

  test "replaying the captured merge STAMPS the real criterion — cause (b) refuted", %{
    scope: scope
  } do
    task = mk_real_task!(scope)

    # NOTE: the task is deliberately left UNCLAIMED. The leading hypothesis was
    # that the bridge needs a claim it does not hold; `reconcile_merge_gate/3`
    # never calls `Tasks.Internal.check_holder/2` and never reads `claim.epoch`,
    # so an unclaimed task stamps fine. This assertion is that refutation.
    refute Map.has_key?(task.content, "claim")

    assert {:ok, :stamped, @real_doc_id, [1]} = MergeEvents.handle(captured_payload())

    reloaded = Repo.get!(Document, task.id)
    gate = Enum.at(reloaded.content["acceptance_criteria"], 1)

    assert gate["met"] == true
    assert gate["evidence"] =~ "merge-reconciled by github-merge"
    assert gate["evidence"] =~ "PR #12210"
    assert gate["evidence"] =~ "209cd542e83b09e11fcd970a4d712f49d4f531f8"

    # The machine-readable provenance the corpus scan looks for. ZERO documents
    # on the live ledger carry this key — that absence is the whole finding.
    record = get_in(reloaded.content, ["merge_gate_autostamp", "merge_event"])
    assert record["source"] == "github_merge_event"
    assert record["verified"] == true

    # STAMP-ONLY: the lifecycle is untouched.
    assert reloaded.content["lifecycle_status"] == "in_progress"
  end
end
