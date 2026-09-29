defmodule Barkpark.Plugins.PrePublishFencesTest do
  @moduledoc """
  The plugin pre-publish fence seam (task-8273f2f1b24a6de1, Barkspark phase 1
  slice E): the task gates `Barkpark.Content.Lifecycle` named directly at the
  PUBLISH door — the door gate (`ensure_task_publish_transition_legal/4`:
  `Transitions`, stale claim, `CriteriaContract`, the criteria fence,
  `TerminalCriteriaFence`, the task-door field fence) and the in-transaction
  re-check (`assert_no_criteria_regression!/4`) — now
  `Barkpark.Tasks.PublishGuards`, declared by
  `Barkpark.Plugins.Tasks.pre_publish_fences/0` and resolved by
  `Barkpark.Plugins.Registry.collect_pre_publish_fences/0`.

  Pins the two properties the move could silently break:

    * ORDER — the two resolve in exactly the order and at exactly the
      positions the lifecycle ran them: the door gate at `:door`, the
      re-check at `:in_transaction`.
    * THE EMPTY PATH — with the Tasks plugin out of the load order the list is
      `[]`, a publish the door gate refuses with Tasks loaded LANDS, and the
      in-transaction phase refuses nothing, so the lifecycle names no Tasks
      gate of its own at either position. The true kill switch
      (`BARKPARK_PLUGINS=""`, nothing registered) is pinned in
      `plugin_free_boot_test.exs`.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, PrePublishFences}
  alias Barkpark.Plugins.Registry

  @dataset "pre_publish_fences_test"

  @publish_order [
    {:door, Barkpark.Tasks.PublishGuards, :door_gate},
    {:in_transaction, Barkpark.Tasks.PublishGuards, :no_criteria_regression}
  ]

  describe "order" do
    test "the Tasks plugin declares the two publish gates at the lifecycle's positions, in order" do
      assert Barkpark.Plugins.Tasks.pre_publish_fences() == @publish_order
    end

    test "the Registry resolves exactly those two, in that order, under the default load order" do
      assert Registry.collect_pre_publish_fences() == @publish_order
    end
  end

  describe "the empty path" do
    test "a load order without tasks resolves no publish fence" do
      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_publish_fences() == []
    end

    test "a load order naming nothing registered resolves no publish fence" do
      :ok = Barkpark.PluginEnv.with_plugins(["no-such-plugin"], %{test: __MODULE__})
      assert Registry.collect_pre_publish_fences() == []
    end

    test "with Tasks out of the load order a publish runs no door gate: an open -> done " <>
           "forge is refused with Tasks in, and lands with it out" do
      scope = seed_task_schema!()

      forge_draft!("ppf-door-on", "Door witness forged while the Tasks plugin loads", scope)
      # CONTROL — Tasks loaded: `PublishGuards.door_gate/4` refuses the forge.
      assert {:error, {:invalid_task_content, %{"lifecycle_status" => [msg]}}} =
               Content.publish_document("ppf-door-on", "task", @dataset, scope)

      assert msg =~ "illegal lifecycle transition"

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_publish_fences() == []

      forge_draft!("ppf-door-off", "Unrelated kill switch sample absent every gate", scope)

      assert {:ok, published} =
               Content.publish_document("ppf-door-off", "task", @dataset, scope)

      assert published.content["lifecycle_status"] == "done"
    end

    test "with Tasks out of the load order the in-transaction phase refuses nothing: a " <>
           "criteria regression is refused with Tasks in, and passes with it out" do
      incumbent = %Document{
        doc_id: "ppf-txn",
        type: "task",
        content: %{
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "proven", "met" => true}]
        }
      }

      pub_attrs = %{
        "content" => %{
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "proven", "met" => false}]
        }
      }

      args = ["task", incumbent, pub_attrs, [source: :api]]

      # CONTROL — Tasks loaded: `PublishGuards.no_criteria_regression/4`
      # returns the refusal the lifecycle rolls back with.
      assert {:error, {:invalid_task_content, %{"acceptance_criteria" => [_]}}} =
               PrePublishFences.run(PrePublishFences.list(), :in_transaction, args)

      # The door phase does not run the in-transaction fence.
      assert :ok = PrePublishFences.run(PrePublishFences.list(), :door, args)

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert :ok = PrePublishFences.run(PrePublishFences.list(), :in_transaction, args)
    end
  end

  defp seed_task_schema! do
    Barkpark.LabelFixtures.register_tags!(@dataset)
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

    scope
  end

  # Publish an open task, then stage a `done` draft beside it through the
  # Writer's `:sync` mirror exemption — the one legal way a done draft can
  # coexist with an open published twin (the `publish_door_lifecycle_guard_test`
  # forge shape). Distinct titles keep the E4 dedup wall out of it.
  defp forge_draft!(doc_id, title, scope) do
    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "lifecycle_status" => "open",
        "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "task", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => title,
          "content" => Map.put(content, "lifecycle_status", "done")
        },
        @dataset,
        Keyword.put(scope, :source, :sync)
      )

    :ok
  end
end
