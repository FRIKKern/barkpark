defmodule Barkpark.Plugins.MutateDoorFencesTest do
  @moduledoc """
  The plugin mutate-door fence seam (task-b04cbe7823d084a6, Barkspark phase 1
  slice G): the task guards `Barkpark.Content.Mutations` named directly — the
  create family's published-fork fence (`QueueGate`) and the adjudication
  guards (`Stage`) — declared by `Barkpark.Plugins.Tasks.mutate_door_fences/0`,
  published to `Barkpark.Content.MutateDoorFences`, and run by `apply_one/3` at
  the two positions they held.

  Pins what the move could silently break:

    * ORDER — refusal order for a raw mutate write that breaches two guards is
      unchanged: across the two phases, against the door's own guards that
      stayed behind (`ensure_rev/2`, the claim fence), within `:after_claim`,
      and against the writer's own checks (the ruling's disposition+priority
      case).
    * THE PUBLISHED ROW — a bare-id patch of a PUBLISHED task is still judged
      against that published row (the writer's `prev_doc` would be `nil`
      there, which is why these are not pre-write fences).
    * THE EMPTY PATH — with Tasks out of the load order the list is `[]` and
      both the raw disposition write and the create-family fork LAND. The true
      kill switch (`BARKPARK_PLUGINS=""`) is pinned in
      `plugin_free_boot_test.exs`.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.{MutateDoorFences, Mutations}
  alias Barkpark.Plugins.Registry

  @dataset "production"

  @fence_order [
    {:before_rev, Barkpark.Tasks.MutateGuards, :create_not_forking_published},
    {:after_claim, Barkpark.Tasks.MutateGuards, :disposition_via_verb},
    {:after_claim, Barkpark.Tasks.MutateGuards, :adoption_adjudicated},
    {:after_claim, Barkpark.Tasks.MutateGuards, :disposition_owner_registered}
  ]

  setup do
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

    %{scope: scope}
  end

  describe "order" do
    test "the Tasks plugin declares the fork fence, then the three adjudication guards" do
      assert Barkpark.Plugins.Tasks.mutate_door_fences() == @fence_order
    end

    test "the Registry resolves exactly those four, in that order, under the default load order" do
      assert Registry.collect_mutate_door_fences() == @fence_order
      assert MutateDoorFences.list() == @fence_order
    end

    test ":before_rev runs BEFORE ensure_rev: a create that forks a claimed published task " <>
           "AND carries a stale revision is refused as a FORK",
         %{scope: scope} do
      id = uniq("mdf-fork-rev")
      publish_task!(id, scope)
      claim!(id, scope, "mdf-worker")

      attrs = Map.put(create_attrs(id), "ifRevisionID", "not-the-rev")

      assert {:error, {:invalid_task_content, %{"_id" => [msg]}}} =
               mutate([%{"createOrReplace" => attrs}], scope)

      assert msg =~ "refusing to fork the published task"
    end

    test ":after_claim runs AFTER the claim fence: a patch that drops the claim AND changes " <>
           "the disposition is refused on the CLAIM",
         %{scope: scope} do
      id = uniq("mdf-claim-disp")
      publish_task!(id, scope)
      claim!(id, scope, "mdf-worker")

      assert {:error, {:invalid_task_content, errors}} =
               mutate([set_patch(id, %{"claim" => nil, "disposition" => "parked"})], scope)

      assert Map.keys(errors) == ["claim"]
    end

    test "within :after_claim, disposition-by-verb is judged before the owner registry",
         %{scope: scope} do
      id = uniq("mdf-disp-owner")
      publish_task!(id, scope)

      assert {:error, {:invalid_task_content, errors}} =
               mutate(
                 [set_patch(id, %{"disposition" => "parked", "disposition_owner" => "wave-99"})],
                 scope
               )

      assert Map.keys(errors) == ["disposition"]

      # CONTROL: the owner alone IS refused — the case above is not passing
      # because the owner guard never fires.
      assert {:error, {:invalid_task_content, owner_errors}} =
               mutate([set_patch(id, %{"disposition_owner" => "wave-99"})], scope)

      assert Map.keys(owner_errors) == ["disposition_owner"]
    end

    test "RULING (ii): a disposition + bad priority patch still refuses on DISPOSITION first, " <>
           "not on the writer's kind check",
         %{scope: scope} do
      id = uniq("mdf-disp-prio")
      publish_task!(id, scope)

      assert {:error, {:invalid_task_content, errors}} =
               mutate(
                 [set_patch(id, %{"disposition" => "parked", "priority" => "banana"})],
                 scope
               )

      assert Map.keys(errors) == ["disposition"]

      # CONTROL: the priority alone is refused by the writer's kind check, so
      # the case above measured an order, not a missing check.
      assert {:error, {:invalid_task_content, prio_errors}} =
               mutate([set_patch(id, %{"priority" => "banana"})], scope)

      assert Map.keys(prio_errors) == ["priority"]
    end
  end

  describe "the published row" do
    test "RULING (i): a bare-id patch of a PUBLISHED task (no draft) changing the disposition " <>
           "is refused exactly as before, naming the stage verb",
         %{scope: scope} do
      id = uniq("mdf-published")
      publish_task!(id, scope, %{"disposition" => "open"})

      assert {:error, :not_found} =
               Content.get_document("drafts." <> id, "task", @dataset, scope)

      assert {:error, {:invalid_task_content, %{"disposition" => [msg]}}} =
               mutate([set_patch(id, %{"disposition" => "parked"})], scope)

      assert msg =~ ~s{cannot be set to "parked" through /v1/data/mutate (currently "open")}
      assert msg =~ "bp task stage"

      {:ok, pub} = Content.get_document(id, "task", @dataset, scope)
      assert pub.content["disposition"] == "open"
    end

    test "an unrelated patch on a published task with a disposition still lands", %{scope: scope} do
      id = uniq("mdf-published-ok")
      publish_task!(id, scope, %{"disposition" => "open"})

      assert {:ok, _} =
               mutate([set_patch(id, %{"description" => "an unrelated edit here"})], scope)
    end
  end

  describe "the empty path" do
    test "a load order without tasks resolves no mutate-door fence" do
      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
      assert Registry.collect_mutate_door_fences() == []
      assert MutateDoorFences.list() == []
    end

    test "run/3 over an empty list is :ok for both phases" do
      assert MutateDoorFences.run([], :before_rev, []) == :ok
      assert MutateDoorFences.run([], :after_claim, []) == :ok
    end

    test "with Tasks out of the load order the raw disposition write LANDS " <>
           "(refused with Tasks in)",
         %{scope: scope} do
      id = uniq("mdf-off-disp")
      publish_task!(id, scope, %{"disposition" => "open"})

      # CONTROL — Tasks loaded: refused.
      assert {:error, {:invalid_task_content, %{"disposition" => [_]}}} =
               mutate([set_patch(id, %{"disposition" => "closed"})], scope)

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})

      assert {:ok, _} = mutate([set_patch(id, %{"disposition" => "closed"})], scope)
      {:ok, pub} = Content.get_document(id, "task", @dataset, scope)
      assert pub.content["disposition"] == "closed"
    end

    test "with Tasks out of the load order the create-family fork LANDS and the legacy " <>
           "delegate is :ok (both refuse with Tasks in)",
         %{scope: scope} do
      id = uniq("mdf-off-fork")
      publish_task!(id, scope)
      claim!(id, scope, "mdf-worker")

      opts = [source: :api] ++ scope

      # CONTROL — Tasks loaded: both doors refuse.
      assert {:error, {:invalid_task_content, %{"_id" => [_]}}} =
               Mutations.ensure_create_not_forking_published_task("task", id, @dataset, opts)

      assert {:error, {:invalid_task_content, %{"_id" => [_]}}} =
               mutate([%{"createOrReplace" => create_attrs(id)}], scope)

      :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})

      assert :ok = Mutations.ensure_create_not_forking_published_task("task", id, @dataset, opts)
      assert {:ok, _} = mutate([%{"createOrReplace" => create_attrs(id)}], scope)
      assert {:ok, _twin} = Content.get_document("drafts." <> id, "task", @dataset, scope)
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content(extra) do
    %{
      "kind" => "task",
      "brief" => Barkpark.TaskBriefFixtures.brief(),
      "lifecycle_status" => "open",
      "dedup_bypass" => true,
      "description" => "mutate-door fence fixture #{System.unique_integer([:positive])}",
      "acceptance_criteria" => [%{"criterion" => "the fixture publishes", "met" => false}]
    }
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # A PUBLISHED task row at the bare id, no draft twin left behind.
  defp publish_task!(doc_id, scope, extra \\ %{}) do
    {:ok, _draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "Mutate door fixture #{doc_id}",
          "content" => task_content(extra)
        },
        @dataset,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @dataset, scope)
    pub
  end

  defp claim!(doc_id, scope, worker) do
    assert {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    assert claimed.content["claim"]["worker"] == worker
    claimed
  end

  defp create_attrs(doc_id),
    do: %{
      "_id" => doc_id,
      "_type" => "task",
      "title" => "FORKED by the create family",
      "content" => task_content(%{})
    }

  defp set_patch(doc_id, set), do: %{"patch" => %{"id" => doc_id, "type" => "task", "set" => set}}

  defp mutate(ops, scope),
    do: Content.apply_mutations(ops, @dataset, [source: :api] ++ scope)
end
