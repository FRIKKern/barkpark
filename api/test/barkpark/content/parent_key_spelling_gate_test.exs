defmodule Barkpark.Content.ParentKeySpellingGateTest do
  @moduledoc """
  The mutate door's fence on near-miss spellings of `content.parent_id`
  (task-42823fba6f150b97).

  `bp task create --set parent=<goal>` stored `content.parent` and left
  `parent_id` empty, so the goal tree and every `parent_id` filter missed the
  row. The fence refuses the write and names `parent_id`. It fences the write,
  not the row: a row that already carries `content.parent` keeps accepting
  patches to other fields, and unsetting the key is allowed.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.MutateGuards

  @dataset "production"

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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Seeded through the writer, not the mutate door: this is how a legacy row
  # carrying `content.parent` looks to every later write.
  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp create_op(id, extra) do
    %{
      "create" => %{
        "_id" => "drafts." <> id,
        "_type" => "task",
        "title" => id,
        "content" => Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)
      }
    }
  end

  defp set_patch(doc_id, set), do: %{"patch" => %{"id" => doc_id, "type" => "task", "set" => set}}

  defp mutate(ops, scope, extra \\ []) do
    Content.apply_mutations(ops, @dataset, Keyword.merge([source: :api] ++ scope, extra))
  end

  defp fetch(doc_id, scope),
    do: Content.get_document("drafts." <> doc_id, "task", @dataset, scope)

  describe "parent_near_miss_keys/1" do
    test "names every near-miss spelling and nothing else" do
      content = %{
        "parent" => "a",
        "parentId" => "b",
        "parent-id" => "c",
        "parentID" => "d",
        "Parent" => "e",
        "parent_id" => "f",
        "parent_title" => "g",
        "parents" => "h"
      }

      assert MutateGuards.parent_near_miss_keys(content) ==
               Enum.sort(["parent", "parentId", "parent-id", "parentID", "Parent"])
    end
  end

  describe "the create path" do
    @tag :requires_plugins
    test "a create carrying `parent` is refused, names parent_id and writes nothing",
         %{scope: scope} do
      id = uniq("parent-create")

      assert {:error, {:invalid_task_content, %{"parent" => [message]}}} =
               mutate([create_op(id, %{"parent" => "task-97df62c4feec9b51"})], scope)

      assert message =~ "parent_id"
      assert message =~ "--set parent_id=task-97df62c4feec9b51"
      assert {:error, :not_found} = fetch(id, scope)
    end

    @tag :requires_plugins
    test "the camel and kebab spellings are refused too", %{scope: scope} do
      for key <- ["parentId", "parent-id"] do
        id = uniq("parent-create-near")

        assert {:error, {:invalid_task_content, %{^key => [message]}}} =
                 mutate([create_op(id, %{key => "task-97df62c4feec9b51"})], scope)

        assert message =~ "parent_id"
      end
    end

    @tag :requires_plugins
    test "createOrReplace is refused as well", %{scope: scope} do
      id = uniq("parent-cor")

      cor = %{
        "createOrReplace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => %{"kind" => "task", "lifecycle_status" => "open", "parent" => "x"}
        }
      }

      assert {:error, {:invalid_task_content, %{"parent" => _}}} = mutate([cor], scope)
    end

    test "a create with no near-miss key passes", %{scope: scope} do
      id = uniq("parent-create-ok")

      assert {:ok, _} = mutate([create_op(id, %{"parent_title" => "not a parent link"})], scope)
      assert {:ok, _} = fetch(id, scope)
    end
  end

  describe "the patch path" do
    @tag :requires_plugins
    test "a patch that sets `parent` is refused and writes nothing", %{scope: scope} do
      id = uniq("parent-patch")
      mk_task!(id, scope)

      assert {:error, {:invalid_task_content, %{"parent" => [message]}}} =
               mutate([set_patch(id, %{"parent" => "task-97df62c4feec9b51"})], scope)

      assert message =~ "parent_id"
      {:ok, doc} = fetch(id, scope)
      refute Map.has_key?(doc.content, "parent")
    end

    test "a row already carrying `parent` still accepts a patch to another field",
         %{scope: scope} do
      id = uniq("parent-legacy")
      mk_task!(id, scope, %{"parent" => "task-97df62c4feec9b51", "priority" => 3})

      assert {:ok, _} = mutate([set_patch(id, %{"priority" => 1})], scope)

      {:ok, doc} = fetch(id, scope)
      assert doc.content["priority"] == 1
      assert doc.content["parent"] == "task-97df62c4feec9b51"
    end

    test "unsetting a legacy `parent` is allowed", %{scope: scope} do
      id = uniq("parent-unset")
      mk_task!(id, scope, %{"parent" => "task-97df62c4feec9b51"})

      unset = %{"patch" => %{"id" => id, "type" => "task", "unset" => ["parent"]}}
      assert {:ok, _} = mutate([unset], scope)

      {:ok, doc} = fetch(id, scope)
      refute Map.has_key?(doc.content, "parent")
    end

    test "replication is exempt", %{scope: scope} do
      id = uniq("parent-sync")
      mk_task!(id, scope)

      assert {:ok, _} = mutate([set_patch(id, %{"parent" => "x"})], scope, source: :sync)
    end
  end
end
