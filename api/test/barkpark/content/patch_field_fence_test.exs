defmodule Barkpark.Content.PatchFieldFenceTest do
  @moduledoc """
  task-61e9a7d8a8b51192 — a mutate patch fenced only on the fields it touches
  (`"fence": "fields"`). Five editors on one post (studio task-86f75846c256e3b4)
  had their field patches refused 133 times in five minutes, stale only because
  someone else wrote another field. With the opt-in, a write to other fields since
  `ifRevisionID` does not refuse the patch; a change to one of its own fields still
  answers 412 with the actual rev. Without the opt-in, nothing changes.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, TenancyFixtures}

  @dataset "patch_field_fence_test"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "fencepost",
          "title" => "Fence post",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "excerpt", "type" => "string"},
            %{"name" => "note", "type" => "string"}
          ]
        },
        @dataset,
        scope
      )

    id = "ff-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.apply_mutations(
        [
          %{
            "createOrReplace" => %{
              "_id" => "drafts." <> id,
              "_type" => "fencepost",
              "title" => "T",
              "excerpt" => "E",
              "note" => "N"
            }
          }
        ],
        @dataset,
        scope
      )

    {:ok, scope: scope, id: id, r0: rev!(id, scope)}
  end

  defp rev!(id, scope) do
    {:ok, doc} = Content.get_document("drafts." <> id, "fencepost", @dataset, scope)
    doc.rev
  end

  defp patch(id, set, extra \\ %{}),
    do: [%{"patch" => Map.merge(%{"id" => id, "type" => "fencepost", "set" => set}, extra)}]

  test "a write to another field since ifRevisionID refuses a plain patch, not a fields-fenced one",
       %{scope: scope, id: id, r0: r0} do
    {:ok, _} = Content.apply_mutations(patch(id, %{"note" => "theirs"}), @dataset, scope)
    r1 = rev!(id, scope)

    assert {:error, {:rev_mismatch, %{expected: ^r0, actual: ^r1}}} =
             Content.apply_mutations(
               patch(id, %{"excerpt" => "mine"}, %{"ifRevisionID" => r0}),
               @dataset,
               scope
             )

    assert {:ok, _} =
             Content.apply_mutations(
               patch(id, %{"excerpt" => "mine"}, %{"ifRevisionID" => r0, "fence" => "fields"}),
               @dataset,
               scope
             )

    {:ok, doc} = Content.get_document("drafts." <> id, "fencepost", @dataset, scope)
    assert doc.content["excerpt"] == "mine"
    assert doc.content["note"] == "theirs"
    refute doc.rev == r1
  end

  test "a change to a field the patch touches still answers 412 with the actual rev",
       %{scope: scope, id: id, r0: r0} do
    {:ok, _} = Content.apply_mutations(patch(id, %{"excerpt" => "theirs"}), @dataset, scope)
    r1 = rev!(id, scope)

    assert {:error, {:rev_mismatch, %{expected: ^r0, actual: ^r1}}} =
             Content.apply_mutations(
               patch(id, %{"excerpt" => "mine"}, %{"ifRevisionID" => r0, "fence" => "fields"}),
               @dataset,
               scope
             )

    # An unset of the field is touching it too.
    assert {:error, {:rev_mismatch, _}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => id,
                     "type" => "fencepost",
                     "unset" => ["excerpt"],
                     "ifRevisionID" => r0,
                     "fence" => "fields"
                   }
                 }
               ],
               @dataset,
               scope
             )

    {:ok, doc} = Content.get_document("drafts." <> id, "fencepost", @dataset, scope)
    assert doc.content["excerpt"] == "theirs"
  end
end
