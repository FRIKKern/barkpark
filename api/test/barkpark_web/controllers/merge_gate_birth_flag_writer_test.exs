defmodule BarkparkWeb.MergeGateBirthFlagWriterTest do
  @moduledoc """
  The merge-gate birth flag at the WRITER (task-0ed428e843b83382). The
  predicate itself is walked against the live-ledger fixture in
  `Barkpark.Tasks.MergeGateBirthFlagTest`. This file pins WHERE it fires: on a
  genuine birth only, never on an edit (and never on the draft twin of a
  published row, which `prev_doc` cannot see), never on replication, and never
  over a declared value.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Writer

  @dataset "test"
  @lead "MERGE-GATED (the lead closes this): the PR merges with the required gates green."
  @buried "The four lead-gated rows are adjudicated `open` — NOT closed — each naming the outstanding [MERGE-GATED] lead act."

  setup do
    {:ok, _} =
      Barkpark.Auth.create_token(
        "mgbf-token",
        "mgbf",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp crit(text, extra \\ %{}), do: Map.merge(%{"criterion" => text, "met" => false}, extra)

  defp task_attrs(doc_id, title, criteria, extra \\ %{}) do
    %{
      "doc_id" => doc_id,
      "title" => title,
      "content" =>
        Map.merge(
          %{
            "kind" => "task",
            "brief" => Barkpark.TaskBriefFixtures.brief(),
            "lifecycle_status" => "open",
            "priority" => 2,
            "acceptance_criteria" => criteria
          },
          extra
        )
    }
  end

  defp flags(doc),
    do: Enum.map(doc.content["acceptance_criteria"], &Map.get(&1, "merge_gate", :absent))

  test "a BIRTH flags the leading marker only, and keeps every declared value" do
    {:ok, doc} =
      Writer.create_document(
        "task",
        task_attrs("mgbf-birth", "Birth flag sets the leading merge gate on create", [
          crit("ordinary work"),
          crit(@lead),
          crit(@buried),
          crit(@lead, %{"merge_gate" => false}),
          crit("[MERGE-GATED] declared by hand", %{"merge_gate" => true})
        ]),
        @dataset,
        source: :api
      )

    assert flags(doc) == [:absent, true, :absent, false, true]
  end

  test "replication (source: :sync) mirrors the upstream row verbatim" do
    {:ok, doc} =
      Writer.create_document(
        "task",
        task_attrs("mgbf-sync", "Replicated rows keep their criteria byte for byte", [crit(@lead)]),
        @dataset,
        source: :sync
      )

    assert flags(doc) == [:absent]
  end

  test "the draft twin of a PUBLISHED row is an edit, not a birth: no flag (no backfill)", %{
    conn: conn
  } do
    register_tag!("tasks")

    # A legacy-shaped row: an unflagged leading criterion, published. Born
    # through replication so the birth flag does not touch it on the way in.
    {:ok, _} =
      Writer.create_document(
        "task",
        task_attrs(
          "mgbf-twin",
          "A legacy published row carrying an unflagged merge gate",
          [crit(@lead)],
          %{
            "description" => "A legacy published task row, born before the birth flag shipped.",
            "main_tag" => "tasks",
            "tags" => [
              %{"tag" => "tasks", "strength" => 80, "rationale" => "a task-ledger fixture"}
            ]
          }
        ),
        @dataset,
        source: :sync
      )

    {:ok, _} = Content.publish_document("mgbf-twin", "task", @dataset)
    {:ok, published} = Content.get_document("mgbf-twin", "task", @dataset)
    assert flags(published) == [:absent], "precondition: the published row is unflagged"

    # The edit door that mints `drafts.<id>` with no drafts-exact prev_doc.
    resp =
      conn
      |> put_req_header("authorization", "Bearer mgbf-token")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{
          "mutations" => [
            %{
              "createOrReplace" => %{
                "_id" => "mgbf-twin",
                "_type" => "task",
                "title" => published.title,
                "content" => Map.put(published.content, "priority", 1)
              }
            }
          ]
        })
      )

    assert resp.status == 200
    {:ok, twin} = Content.get_document("drafts.mgbf-twin", "task", @dataset)
    assert twin.content["priority"] == 1

    assert flags(twin) == [:absent],
           "the edit of a published row was flagged: a backfill riding an edit"
  end

  defp register_tag!(name) do
    Barkpark.Content.TagRegistry.register!(@dataset)
    {:ok, _} = Content.create_document("tag", %{"doc_id" => name, "title" => name}, @dataset, [])
    {:ok, _} = Content.publish_document(name, "tag", @dataset, [])
    name
  end
end
