defmodule Barkpark.Content.PublishKeepsTaskClaimTest do
  @moduledoc """
  task-9b5e1a6a688d27fc — publishing a doc patch that does not NAME the
  claim/lifecycle fields must not change them.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.DraftId

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [
        %{"criterion" => "the original criterion", "met" => false, "evidence" => ""}
      ]
    }
    |> Map.merge(extra)
    |> LabelFixtures.with_registered_labels(@dataset)
  end

  defp mk_published_task!(scope, extra \\ %{}) do
    id = uniq("pkc-task")

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => id, "content" => task_content(extra)},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, "task", @dataset, scope)
    id
  end

  test "claim -> doc patch -> doc publish keeps the claim and lifecycle_status",
       %{scope: scope} do
    id = mk_published_task!(scope)
    worker = uniq("w")

    assert {:ok, claimed} = Tasks.claim_by_id(id, worker, scope)
    claim = claimed.content["claim"]
    assert claimed.content["lifecycle_status"] == "in_progress"
    assert claim["worker"] == worker

    # `bp doc patch task <id> --set acceptance_criteria:=[...]` — a field the
    # task door does NOT own.
    criteria = [%{"criterion" => "a new criterion", "met" => false, "evidence" => ""}]

    assert {:ok, {_tx, _res}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => id,
                     "type" => "task",
                     "set" => %{"acceptance_criteria" => criteria}
                   }
                 }
               ],
               @dataset,
               [source: :api] ++ scope
             )

    # `bp doc publish task <id>`
    _ = Content.publish_document(id, "task", @dataset, [source: :api] ++ scope)

    {:ok, reread} = Content.get_document(id, "task", @dataset, scope)

    assert reread.content["acceptance_criteria"] == criteria,
           "the criteria must land"

    assert reread.content["lifecycle_status"] == "in_progress",
           "publish reopened the row: #{inspect(reread.content["lifecycle_status"])}"

    assert reread.content["claim"] == claim,
           "publish dropped/changed the claim: #{inspect(reread.content["claim"])}"
  end

  test "a draft forked BEFORE the claim cannot publish the claim away", %{scope: scope} do
    id = mk_published_task!(scope)
    worker = uniq("w")

    # A draft twin minted from the PRE-claim published content (the shape the
    # filing measured: the draft was forked before the claim landed).
    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => id,
          "title" => id,
          "content" =>
            task_content(%{
              "acceptance_criteria" => [
                %{
                  "criterion" => "written from a pre-claim fork",
                  "met" => false,
                  "evidence" => ""
                }
              ]
            })
        },
        @dataset,
        scope
      )

    assert draft.doc_id == DraftId.draft_id(id)

    assert {:ok, claimed} = Tasks.claim_by_id(id, worker, scope)
    claim = claimed.content["claim"]

    assert {:error, {:invalid_task_content, details}} =
             Content.publish_document(id, "task", @dataset, [source: :api] ++ scope)

    assert [message] = details["claim"]
    assert message =~ "claim"

    {:ok, reread} = Content.get_document(id, "task", @dataset, scope)

    assert reread.content["lifecycle_status"] == "in_progress",
           "publish reopened the row: #{inspect(reread.content["lifecycle_status"])}"

    assert reread.content["claim"] == claim,
           "publish dropped/changed the claim: #{inspect(reread.content["claim"])}"
  end

  describe "the publish door fences every field the TASK door owns" do
    test "a claim-identical draft may not ERASE close_reason", %{scope: scope} do
      id = mk_published_task!(scope)
      worker = uniq("w")

      assert {:ok, claimed} = Tasks.claim_by_id(id, worker, scope)
      epoch = claimed.content["claim"]["epoch"]

      assert {:ok, closed} =
               Tasks.close(claimed.id, worker,
                 observed_epoch: epoch,
                 lifecycle_status: "done",
                 reason: "landed in #16999",
                 criteria_override: "criterion is an honest miss"
               )

      assert closed.content["close_reason"] == "landed in #16999"

      # The draft the document door mints: the CURRENT published content (claim
      # byte-identical, `done` preserved, criteria preserved) minus the one key
      # the task door wrote. Every existing publish-door gate waves it through.
      {:ok, draft} =
        Content.create_document(
          "task",
          %{
            "doc_id" => id,
            "title" => id,
            "content" => Map.delete(closed.content, "close_reason")
          },
          @dataset,
          scope
        )

      assert draft.doc_id == DraftId.draft_id(id)

      assert {:error, {:invalid_task_content, details}} =
               Content.publish_document(id, "task", @dataset, [source: :api] ++ scope)

      assert [message] = details["close_reason"]
      assert message =~ "bp task close"

      {:ok, reread} = Content.get_document(id, "task", @dataset, scope)

      assert reread.content["close_reason"] == "landed in #16999",
             "publish erased close_reason: #{inspect(reread.content["close_reason"])}"
    end

    test "a claim-identical draft may not ERASE reopen_trigger", %{scope: scope} do
      id = mk_published_task!(scope, %{"reopen_trigger" => "when the upstream API ships"})

      {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert published.content["reopen_trigger"] == "when the upstream API ships"

      {:ok, _draft} =
        Content.create_document(
          "task",
          %{
            "doc_id" => id,
            "title" => id,
            "content" => Map.delete(published.content, "reopen_trigger")
          },
          @dataset,
          scope
        )

      assert {:error, {:invalid_task_content, details}} =
               Content.publish_document(id, "task", @dataset, [source: :api] ++ scope)

      assert [message] = details["reopen_trigger"]
      assert message =~ "bp task stage"

      {:ok, reread} = Content.get_document(id, "task", @dataset, scope)
      assert reread.content["reopen_trigger"] == "when the upstream API ships"
    end

    # THE FENCE'S NON-VACUITY CONTROL. A draft that carries the task-door fields
    # BYTE-IDENTICAL is the ordinary patch-then-publish idiom and must still
    # publish — without this the fence could pass by refusing everything.
    test "a draft that carries the task-door fields verbatim still publishes",
         %{scope: scope} do
      id = mk_published_task!(scope, %{"reopen_trigger" => "when the upstream API ships"})
      {:ok, published} = Content.get_document(id, "task", @dataset, scope)

      {:ok, _draft} =
        Content.create_document(
          "task",
          %{
            "doc_id" => id,
            "title" => id,
            "content" => Map.put(published.content, "note", "an ordinary content edit")
          },
          @dataset,
          scope
        )

      assert {:ok, _} = Content.publish_document(id, "task", @dataset, [source: :api] ++ scope)

      {:ok, reread} = Content.get_document(id, "task", @dataset, scope)
      assert reread.content["note"] == "an ordinary content edit"
      assert reread.content["reopen_trigger"] == "when the upstream API ships"
    end
  end
end
