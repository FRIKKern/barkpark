defmodule Barkpark.Plugins.PreWriteFencesTest do
  @moduledoc """
  The plugin pre-write fence seam (task-e5baaaa14ddf2e1c, task-2978357a0701cd10):
  the Tasks plugin's seven write fences, formerly named directly in
  `Barkpark.Content.Writer` (the last two moved were the writer's own birth
  guards, `ensure_task_born_adjudicated/5` and `ensure_task_surface_declared/5`,
  now `Barkpark.Tasks.BirthGuards`), declared by
  `Barkpark.Plugins.Tasks.pre_write_fences/0` and resolved by
  `Barkpark.Plugins.Registry.collect_pre_write_fences/0`.

  Pins the two properties the move could silently break:

    * ORDER — the seven resolve as ONE list in exactly the order the
      writer's `with` chain ran them: the four early fences, born-adjudicated,
      surface-declared, then dedup. No phases remain.
    * THE EMPTY PATH — with the Tasks plugin out of the load order the list is
      `[]`, and a write the draft-terminal fence refuses with Tasks loaded
      LANDS, so the writer names no Tasks fence of its own. The true kill
      switch (`BARKPARK_PLUGINS=""`, nothing registered) is pinned in
      `plugin_free_boot_test.exs`.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Registry

  @dataset "pre_write_fences_test"

  @writer_order [
    {Barkpark.Tasks.DraftTerminalFence, :check},
    {Barkpark.Tasks.DatasetTwinFence, :check},
    {Barkpark.Tasks.TerminalCriteriaFence, :check},
    {Barkpark.Tasks.CriteriaRequiredFence, :check},
    {Barkpark.Tasks.BirthGuards, :born_adjudicated},
    {Barkpark.Tasks.BirthGuards, :surface_declared},
    {Barkpark.Plugins.Tasks, :dedup_check_new_task}
  ]

  describe "order" do
    test "the Tasks plugin declares the seven fences in the writer's order" do
      assert Barkpark.Plugins.Tasks.pre_write_fences() == @writer_order
    end

    test "the Registry resolves exactly those seven, in that order, under the default load order" do
      assert Registry.collect_pre_write_fences() == @writer_order
    end
  end

  describe "the empty path" do
    test "a load order without tasks resolves no fence" do
      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_write_fences() == []
    end

    test "a load order naming nothing registered resolves no fence" do
      :ok = Barkpark.PluginEnv.with_plugins(["no-such-plugin"], %{test: __MODULE__})
      assert Registry.collect_pre_write_fences() == []
    end

    test "with Tasks out of the load order the writer runs no Tasks fence: the " <>
           "draft-terminal witness write is refused with Tasks in, and lands with it out" do
      scope = seed_task_schema!()

      {:ok, _} = write("pwf-witness-on", %{}, scope)
      # CONTROL — Tasks loaded (default load order): the fence refuses.
      assert {:error, {:invalid_task_content, _}} =
               write("pwf-witness-on", %{"lifecycle_status" => "cancelled"}, scope)

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_write_fences() == []

      {:ok, _} = write("pwf-witness-off", %{}, scope)

      assert {:ok, doc} =
               write("pwf-witness-off", %{"lifecycle_status" => "cancelled"}, scope)

      assert doc.content["lifecycle_status"] == "cancelled"
    end

    test "with Tasks out of the load order the writer runs no birth guard: an " <>
           "off-vocabulary disposition birth is refused with Tasks in, and lands with it out" do
      scope = seed_task_schema!()

      # CONTROL — Tasks loaded: `BirthGuards.born_adjudicated/6` refuses the term.
      assert {:error, {:invalid_task_content, %{"disposition" => [_]}}} =
               write("pwf-birth-on", %{"disposition" => "OPEN"}, scope)

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_pre_write_fences() == []

      assert {:ok, doc} = write("pwf-birth-off", %{"disposition" => "OPEN"}, scope)
      assert doc.content["disposition"] == "OPEN"
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

  defp write(doc_id, extra, scope) do
    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "lifecycle_status" => "open",
        "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => "Pre-write fence fixture #{doc_id}", "content" => content},
      @dataset,
      scope
    )
  end
end
