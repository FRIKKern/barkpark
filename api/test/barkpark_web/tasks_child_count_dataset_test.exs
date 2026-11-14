defmodule BarkparkWeb.TasksChildCountDatasetTest do
  @moduledoc """
  The child counts on a task card follow the dataset the request is held to
  (task-1b52dd91e600c773).

  `Params.batch_child_counts/2`, `batch_live_child_counts/2` and
  `batch_live_parents/2` filtered by workspace and project only. A production
  task whose `parent_id` names a dataset-bound token's own task made that card
  read `child_count: 1` to the bound token: a number about a dataset it may
  not read. And a child id living in two datasets counted 2 for a caller who
  named one of them.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the Tasks plugin's /v1/tasks routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tasks, Tenancy}
  alias BarkparkWeb.TasksController.Params

  @own "bound-own"
  @prod "production"

  setup do
    ws = create_workspace!("child-count-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id]

    for ds <- [@prod, @own] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
      upsert_task_schemas!(ds, scope)
      Barkpark.LabelFixtures.register_tags!(ds)
    end

    parent = task!(@own, scope, new_id(), "PARENT-IN-#{@own}")

    {:ok, ws: ws, scope: scope, parent: parent}
  end

  defp bearer(ws, opts) do
    raw = "child-count-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "child count", @own, ["read", "write", "admin"], ws.id, opts)

    scoped_conn() |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp new_id, do: "child-count-#{System.unique_integer([:positive])}"

  # The parent's card from prime, in whichever slice holds it.
  defp primed_card(conn, query, doc_id) do
    body = conn |> get("/v1/tasks/prime" <> query) |> json_response(200)
    Enum.find(body["in_progress"] ++ body["ready"], &(&1["doc_id"] == doc_id))
  end

  defp listed_card(conn, query, doc_id) do
    body = conn |> get("/v1/tasks" <> query) |> json_response(200)
    Enum.find(body["docs"], &(&1["doc_id"] == doc_id))
  end

  describe "a production child under a bound token's own task" do
    setup %{scope: scope, parent: parent} do
      child = task!(@prod, scope, new_id(), "CHILD-IN-#{@prod}", parent.doc_id)
      {:ok, child: child}
    end

    test "prime counts no child for the dataset-bound token", %{ws: ws, parent: parent} do
      conn = bearer(ws, dataset_bound: true)

      for query <- ["", "?view=brief", "?view=board"] do
        card = primed_card(conn, query, parent.doc_id)
        assert card, "the bound token's own task is on its prime (#{query})"
        assert card["child_count"] == 0, "prime#{query} counted a production child"
      end
    end

    test "the task list counts no child for the dataset-bound token", %{ws: ws, parent: parent} do
      conn = bearer(ws, dataset_bound: true)

      for query <- ["", "?view=brief", "?view=board"] do
        card = listed_card(conn, query, parent.doc_id)
        assert card, "the bound token's own task is on its list (#{query})"
        assert card["child_count"] == 0, "list#{query} counted a production child"
      end
    end

    test "an unbound token naming no dataset still counts it (control)", %{ws: ws, parent: parent} do
      conn = bearer(ws, [])

      assert primed_card(conn, "", parent.doc_id)["child_count"] == 1
      assert primed_card(conn, "?view=brief", parent.doc_id)["child_count"] == 1
      assert listed_card(conn, "", parent.doc_id)["child_count"] == 1
    end

    test "the three batch queries narrow to scope[:dataset]", %{
      scope: scope,
      parent: parent,
      child: child
    } do
      key = parent.doc_id

      assert Params.batch_child_counts([parent], scope) == %{key => 1}
      assert Params.batch_live_child_counts([parent], scope) == %{key => 1}
      assert Params.batch_live_parents([child], scope) == %{key => true}

      own = Keyword.put(scope, :dataset, @own)
      assert Params.batch_child_counts([parent], own) == %{}
      assert Params.batch_live_child_counts([parent], own) == %{}
      assert Params.batch_live_parents([child], own) == %{key => true}

      # The parent lives in `bound-own`: a caller held to production has no
      # live parent to read there.
      prod = Keyword.put(scope, :dataset, @prod)
      assert Params.batch_live_parents([child], prod) == %{}
      assert Params.batch_child_counts([parent], prod) == %{key => 1}
    end
  end

  describe "a child id living in both datasets" do
    test "counts once for a caller naming a dataset", %{ws: ws, scope: scope, parent: parent} do
      twin = new_id()
      task!(@own, scope, twin, "TWIN-IN-#{@own}", parent.doc_id)

      task!(@prod, scope, twin, "TWIN-IN-#{@prod}", parent.doc_id, %{
        "dataset_twin_intended" => true
      })

      unbound = bearer(ws, [])
      assert primed_card(unbound, "?dataset=#{@own}", parent.doc_id)["child_count"] == 1

      bound = bearer(ws, dataset_bound: true)
      assert primed_card(bound, "", parent.doc_id)["child_count"] == 1
    end
  end

  defp upsert_task_schemas!(dataset, scope) do
    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  defp task!(dataset, scope, doc_id, title, parent_id \\ nil, extra \\ %{}) do
    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "fixture #{doc_id} #{dataset}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "fixture", "met" => false}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(extra)
      |> then(&if(parent_id, do: Map.put(&1, "parent_id", parent_id), else: &1))

    attrs = %{"doc_id" => doc_id, "title" => title, "content" => content}
    {:ok, _} = Content.create_document("task", attrs, dataset, scope)
    {:ok, pub} = Content.publish_document(doc_id, "task", dataset, scope)
    pub
  end
end
