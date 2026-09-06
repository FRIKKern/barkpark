defmodule Barkpark.Tasks.QueueCrossDatasetTwinTest do
  @moduledoc """
  Axis 5 at the QUERY, and the property that makes it more than cosmetics:
  `Tasks.Claim.claim/2` rides `Queue.ready_query/1`, so whatever the ready page
  will not place, `bp task next` will not hand out either (task-0084e191d406de96).

  The rule is `Barkpark.Tasks.TwinResolver`'s, stated once in that moduledoc.
  Rule 3 — an unnamed cross-dataset tie is REFUSED, never broken by `dataset` —
  already governs `Tasks.claim_by_id/3` (a typed 409). A queue that offered a
  row the claim door refuses would be exactly the ready/claim disagreement
  `Tasks.Queue` exists to prevent.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Queue

  @primary "production"
  @secondary "aker-brygge"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for dataset <- [@primary, @secondary], schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end

    %{scope: scope, phase_id: uniq("phase-queue-twin")}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_published!(doc_id, dataset, scope, phase_id, extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "parent_id" => phase_id,
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ]
        },
        extra
      )

    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "#{doc_id} (#{dataset} #{System.unique_integer([:positive])})",
          "content" => content
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  defp seed_tied_twin!(scope, phase_id) do
    doc_id = uniq("queue-twin")
    _ = mk_published!(doc_id, @primary, scope, phase_id)
    # `dataset_twin_intended` — `Tasks.DatasetTwinFence` (#16474, the producer
    # half) refuses this birth without a stated intent, and the shape under
    # measurement IS the twin.
    _ = mk_published!(doc_id, @secondary, scope, phase_id, %{"dataset_twin_intended" => true})
    doc_id
  end

  test "a dataset-less ready yields the twinned id ZERO times, and names it once", %{
    scope: scope,
    phase_id: phase_id
  } do
    doc_id = seed_tied_twin!(scope, phase_id)
    opts = scope ++ [phase_id: phase_id]

    # RED without axis 5: TWO rows, one per dataset, in ONE page.
    assert Queue.ready(opts) |> Enum.map(& &1.doc_id) == []

    assert Queue.dataset_ambiguous(opts) == [
             %{doc_id: doc_id, datasets: Enum.sort([@primary, @secondary])}
           ]
  end

  test "naming the dataset resolves it — one row, and nothing is reported ambiguous", %{
    scope: scope,
    phase_id: phase_id
  } do
    doc_id = seed_tied_twin!(scope, phase_id)
    opts = scope ++ [phase_id: phase_id, dataset: @secondary]

    assert Queue.ready(opts) |> Enum.map(& &1.doc_id) == [doc_id]
    assert Queue.dataset_ambiguous(opts) == []
  end

  test "claim/2 does not hand out a row the ready page refused to place", %{
    scope: scope,
    phase_id: phase_id
  } do
    _doc_id = seed_tied_twin!(scope, phase_id)

    # `claim_by_id` already refuses this id with a typed 409; the QUEUE claim
    # must not quietly succeed where the targeted one refuses.
    assert {:ok, nil} = Tasks.claim("queue-twin-worker", scope ++ [phase_id: phase_id])
  end
end
