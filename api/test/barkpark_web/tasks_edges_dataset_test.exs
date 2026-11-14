defmodule BarkparkWeb.TasksEdgesDatasetTest do
  @moduledoc """
  Task edges and the edge counts on a task card follow the dataset the request
  is held to (task-0a3dcbd61d618a00).

  `GET /v1/tasks/:id/edges` read `Tasks.dependencies/2` and `dependents/2` by
  the task's primary key alone, and `Params.batch_edge_counts/1` counted every
  edge touching the page. A `blocks` edge between a dataset-bound token's own
  task and a production task therefore handed the bound token the production
  row (title, doc_id, dataset) and a count about it.

  What "ready" means does not move: a production blocker still keeps the
  own-dataset task out of the ready queue.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the Tasks plugin's /v1/tasks routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tasks, Tenancy}
  alias BarkparkWeb.TasksController.{CountScope, Params}

  @own "bound-own"
  @prod "production"
  @views ["", "?view=board"]

  setup do
    ws = create_workspace!("edges-ds-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id]

    for ds <- [@prod, @own] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
      upsert_task_schemas!(ds, scope)
      Barkpark.LabelFixtures.register_tags!(ds)
    end

    # P waits on T: T's card has one dependent, in production.
    t = task!(@own, scope, new_id(), "T-IN-#{@own}")
    p = task!(@prod, scope, new_id(), "P-WAITS-IN-#{@prod}")
    {:ok, _} = Tasks.add_dep(p, t, "blocks", nil)

    # T2 waits on P2: T2's card has one dependency, in production.
    t2 = task!(@own, scope, new_id(), "T2-IN-#{@own}")
    p2 = task!(@prod, scope, new_id(), "P2-BLOCKS-IN-#{@prod}")
    {:ok, _} = Tasks.add_dep(t2, p2, "blocks", nil)

    {:ok, ws: ws, scope: scope, t: t, p: p, t2: t2, p2: p2}
  end

  defp bearer(ws, opts) do
    raw = "edges-ds-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "edges ds", @own, ["read", "write", "admin"], ws.id, opts)
    scoped_conn() |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp new_id, do: "edges-ds-#{System.unique_integer([:positive])}"

  defp edges(conn, doc_id, query \\ "") do
    conn |> get("/v1/tasks/#{doc_id}/edges" <> query) |> json_response(200)
  end

  defp primed_card(conn, query, doc_id) do
    body = conn |> get("/v1/tasks/prime" <> query) |> json_response(200)
    Enum.find(body["in_progress"] ++ body["ready"], &(&1["doc_id"] == doc_id))
  end

  defp listed_card(conn, path, query, doc_id) do
    body = conn |> get(path <> query) |> json_response(200)
    Enum.find(body["docs"], &(&1["doc_id"] == doc_id))
  end

  defp shown(conn, doc_id), do: (conn |> get("/v1/tasks/#{doc_id}") |> json_response(200))["doc"]

  describe "the dataset-bound token" do
    test "GET edges returns no production row, in either direction", ctx do
      conn = bearer(ctx.ws, dataset_bound: true)

      for query <- ["", "?kind=all", "?kind=blocks"] do
        assert %{"dependencies" => [], "dependents" => []} = edges(conn, ctx.t.doc_id, query)
        assert %{"dependencies" => [], "dependents" => []} = edges(conn, ctx.t2.doc_id, query)
      end

      raw = conn |> get("/v1/tasks/#{ctx.t.doc_id}/edges") |> response(200)
      refute raw =~ ctx.p.doc_id
      refute raw =~ "P-WAITS-IN"
    end

    test "list, ready, prime and show count no production dependent", ctx do
      conn = bearer(ctx.ws, dataset_bound: true)
      id = ctx.t.doc_id

      for view <- @views do
        for {name, card} <- [
              {"list", listed_card(conn, "/v1/tasks", view, id)},
              {"ready", listed_card(conn, "/v1/tasks/ready", view, id)},
              {"prime", primed_card(conn, view, id)}
            ] do
          assert card, "the bound token's own task is on its #{name} (#{view})"
          assert card["dependent_count"] == 0, "#{name}#{view} counted a production dependent"
          assert card["dependency_count"] == 0
        end
      end

      assert shown(conn, id)["dependent_count"] == 0
    end

    test "list and show count no production dependency; the blocker still blocks", ctx do
      conn = bearer(ctx.ws, dataset_bound: true)
      id = ctx.t2.doc_id

      for view <- @views do
        card = listed_card(conn, "/v1/tasks", view, id)
        assert card, "the bound token's own task is on its list (#{view})"
        assert card["dependency_count"] == 0, "list#{view} counted a production dependency"

        # Unchanged meaning of ready: the production blocker keeps T2 out.
        refute listed_card(conn, "/v1/tasks/ready", view, id)
        refute primed_card(conn, view, id)
      end

      assert shown(conn, id)["dependency_count"] == 0
    end

    test "an edge inside its own dataset is still read and counted", ctx do
      t3 = task!(@own, ctx.scope, new_id(), "T3-IN-#{@own}")
      {:ok, _} = Tasks.add_dep(t3, ctx.t, "blocks", nil)
      conn = bearer(ctx.ws, dataset_bound: true)

      assert [%{"doc_id" => dependent}] = edges(conn, ctx.t.doc_id)["dependents"]
      assert dependent == t3.doc_id
      assert [%{"doc_id" => blocker}] = edges(conn, t3.doc_id)["dependencies"]
      assert blocker == ctx.t.doc_id

      assert shown(conn, ctx.t.doc_id)["dependent_count"] == 1
      assert shown(conn, t3.doc_id)["dependency_count"] == 1
      assert listed_card(conn, "/v1/tasks", "", ctx.t.doc_id)["dependent_count"] == 1
    end
  end

  describe "an unbound token naming no dataset (control)" do
    test "still reads the edge rows", ctx do
      conn = bearer(ctx.ws, [])

      assert [%{"doc_id" => dependent, "dataset" => @prod}] =
               edges(conn, ctx.t.doc_id)["dependents"]

      assert dependent == ctx.p.doc_id

      assert [%{"doc_id" => blocker, "dataset" => @prod}] =
               edges(conn, ctx.t2.doc_id)["dependencies"]

      assert blocker == ctx.p2.doc_id
    end

    test "still counts the edges on list, ready, prime and show", ctx do
      conn = bearer(ctx.ws, [])
      id = ctx.t.doc_id

      for view <- @views do
        assert listed_card(conn, "/v1/tasks", view, id)["dependent_count"] == 1
        assert listed_card(conn, "/v1/tasks/ready", view, id)["dependent_count"] == 1
        assert primed_card(conn, view, id)["dependent_count"] == 1
        assert listed_card(conn, "/v1/tasks", view, ctx.t2.doc_id)["dependency_count"] == 1
        refute listed_card(conn, "/v1/tasks/ready", view, ctx.t2.doc_id)
      end

      assert shown(conn, id)["dependent_count"] == 1
      assert shown(conn, ctx.t2.doc_id)["dependency_count"] == 1
    end
  end

  test "the scoped count equals Params.batch_edge_counts/1 when no dataset is named", ctx do
    docs = [ctx.t, ctx.t2]
    conn = %Plug.Conn{params: %{}}

    assert CountScope.edge_counts(docs, conn) == Params.batch_edge_counts(docs)
    assert CountScope.edge_counts(docs, conn) == %{ctx.t.id => {0, 1}, ctx.t2.id => {1, 0}}

    held = %Plug.Conn{params: %{"dataset" => @own}}
    assert CountScope.edge_counts(docs, held) == %{ctx.t.id => {0, 0}, ctx.t2.id => {0, 0}}
    assert CountScope.edge_counts([], held) == %{}
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

  defp task!(dataset, scope, doc_id, title) do
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

    attrs = %{"doc_id" => doc_id, "title" => title, "content" => content}
    {:ok, _} = Content.create_document("task", attrs, dataset, scope)
    {:ok, pub} = Content.publish_document(doc_id, "task", dataset, scope)
    pub
  end
end
