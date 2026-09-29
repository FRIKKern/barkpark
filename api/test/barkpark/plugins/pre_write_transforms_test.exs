defmodule Barkpark.Plugins.PreWriteTransformsTest do
  @moduledoc """
  The plugin pre-write transform seam (task-aed4f02e57d3a760, Barkspark phase
  1 slice F): the two task steps `Barkpark.Content.Writer` named directly at
  the end of its attrs pipeline on both write doors — the brief re-sync
  (`Barkpark.Tasks.BriefMirror.maybe_resync_task_brief/2`, a transform) and the
  kind check (`validate_task_kind/2`, now `Barkpark.Tasks.Validation`) —
  declared by `Barkpark.Plugins.Tasks.pre_write_transforms/0` and resolved by
  `Barkpark.Plugins.Registry.collect_pre_write_transforms/0`.

  Pins the two properties the move could silently break:

    * ORDER — the re-sync runs first and the kind check judges its output,
      the order the writer's pipe ran them in.
    * THE EMPTY PATH — with the Tasks plugin out of the load order the list is
      `[]`, a task write stores its attrs untransformed (the brief is NOT
      re-derived) on both doors, and a task the kind check refuses with Tasks
      loaded LANDS, so the writer names no Tasks step of its own. The true
      kill switch (`BARKPARK_PLUGINS=""`, nothing registered) is pinned in
      `plugin_free_boot_test.exs`.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.PreWriteTransforms
  alias Barkpark.Plugins.Registry

  @dataset "production"

  @transform_order [
    {:transform, Barkpark.Tasks.BriefMirror, :maybe_resync_task_brief},
    {:check, Barkpark.Tasks.Validation, :validate_task_kind}
  ]

  describe "order" do
    test "the Tasks plugin declares the brief re-sync, then the kind check" do
      assert Barkpark.Plugins.Tasks.pre_write_transforms() == @transform_order
    end

    # The Forms plugin (task-71082f5541c13b53) declares one `:check` of its
    # own, for its two types only; plugins resolve in name order, so it comes
    # first and the Tasks pair keeps its relative order.
    test "the Registry resolves exactly those two, in that order, under the default load order" do
      assert Registry.collect_pre_write_transforms() ==
               [{:check, Barkpark.Plugins.Forms.Contract, :validate} | @transform_order]
    end

    test "the kind check judges the TRANSFORMED attrs: a step's output is the next step's input" do
      probe = {:check, __MODULE__, :refuse_unless_resynced}

      attrs = task_attrs("pwt-order", "the authoritative description")

      assert {:error, :saw_the_stale_brief} =
               PreWriteTransforms.run([probe], "task", attrs)

      assert {:ok, resynced} =
               PreWriteTransforms.run(
                 [resync_step(Registry.collect_pre_write_transforms()), probe],
                 "task",
                 attrs
               )

      assert purpose(resynced) == "the authoritative description"
    end
  end

  describe "the empty path" do
    test "a load order without tasks resolves no transform" do
      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_write_transforms() == []
    end

    test "a load order naming nothing registered resolves no transform" do
      :ok = Barkpark.PluginEnv.with_plugins(["no-such-plugin"], %{test: __MODULE__})
      assert Registry.collect_pre_write_transforms() == []
    end

    test "run/3 over an empty list returns the attrs untouched" do
      attrs = task_attrs("pwt-run-empty", "the authoritative description")
      assert PreWriteTransforms.run([], "task", attrs) == {:ok, attrs}
    end

    test "with Tasks out of the load order a task write stores its attrs untransformed: " <>
           "the brief is re-derived with Tasks in, and stored as sent with it out" do
      # CONTROL — Tasks loaded: both doors re-derive the brief.
      {:ok, created} =
        Content.create_document("task", task_attrs("pwt-on-c", "desc on"), @dataset)

      assert purpose(created) == "desc on"

      {:ok, upserted} =
        Content.upsert_document("task", task_attrs("pwt-on-u", "desc on"), @dataset)

      assert purpose(upserted) == "desc on"

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_write_transforms() == []

      sent_c = task_attrs("pwt-off-c", "desc off")
      {:ok, created} = Content.create_document("task", sent_c, @dataset)
      assert purpose(created) == "a brief that never matched"
      assert created.content["brief"] == sent_c["content"]["brief"]

      sent_u = task_attrs("pwt-off-u", "desc off")
      {:ok, upserted} = Content.upsert_document("task", sent_u, @dataset)
      assert purpose(upserted) == "a brief that never matched"
      assert upserted.content["brief"] == sent_u["content"]["brief"]
    end

    test "with Tasks out of the load order the writer runs no kind check: a task with " <>
           "no content.kind is refused with Tasks in, and lands with it out" do
      no_kind = fn id ->
        update_in(task_attrs(id, "kindless"), ["content"], &Map.delete(&1, "kind"))
      end

      # CONTROL — Tasks loaded: the kind check refuses on both doors.
      assert {:error, {:invalid_task_content, %{"kind" => [_]}}} =
               Content.create_document("task", no_kind.("pwt-kind-on-c"), @dataset)

      assert {:error, {:invalid_task_content, %{"kind" => [_]}}} =
               Content.upsert_document("task", no_kind.("pwt-kind-on-u"), @dataset)

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})

      assert {:ok, created} =
               Content.create_document("task", no_kind.("pwt-kind-off-c"), @dataset)

      refute Map.has_key?(created.content, "kind")

      assert {:ok, upserted} =
               Content.upsert_document("task", no_kind.("pwt-kind-off-u"), @dataset)

      refute Map.has_key?(upserted.content, "kind")
    end
  end

  @doc false
  def refuse_unless_resynced(_type, attrs) do
    if purpose(attrs) == "a brief that never matched",
      do: {:error, :saw_the_stale_brief},
      else: :ok
  end

  defp task_attrs(id, description) do
    %{
      "doc_id" => "#{id}-#{System.unique_integer([:positive])}",
      "title" => "Pre-write transform probe #{id}",
      "content" => %{
        "kind" => "task",
        "lifecycle_status" => "open",
        # Four near-identical probe titles in one dataset: the Tasks dedup
        # fence would refuse the second. It is not what this file measures.
        "dedup_bypass" => true,
        "title" => "Pre-write transform probe #{id}",
        "description" => description,
        "brief" => %{
          "version" => 1,
          "blocks" => [
            %{
              "id" => "purpose-copy",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "a brief that never matched"}]
            }
          ]
        }
      }
    }
  end

  defp purpose(%{content: content}), do: purpose(%{"content" => content})

  defp purpose(%{"content" => content}) do
    content["brief"]["blocks"]
    |> Enum.find(&(&1["id"] == "purpose-copy"))
    |> get_in(["content", Access.at(0), "value"])
  end

  # The Registry's brief re-sync step, found by what it is rather than by
  # position: other plugins' steps may precede it in the resolved list.
  defp resync_step(steps),
    do: Enum.find(steps, &match?({:transform, Barkpark.Tasks.BriefMirror, _}, &1))
end
