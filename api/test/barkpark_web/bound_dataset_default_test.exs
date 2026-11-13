defmodule BarkparkWeb.BoundDatasetDefaultTest do
  @moduledoc """
  A token minted with an explicit dataset is held to it for everything. The
  request fence used to refuse only a dataset the request NAMED; a request
  naming none fell to each controller's own default, and the ones that
  defaulted to `production` let a bound token act there.

  `BarkparkWeb.Plugs.BoundDataset.resolve/2` now gives such a request the
  token's dataset where the token is resolved. Shown on the Tasks API, which
  had no bound-token handling of its own (task-732a5ad258adddf2): a token bound
  to `bound-own` read and staged a production task.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the Tasks plugin's /v1/tasks routes and the chat API.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo, Tasks, Tenancy}
  alias Barkpark.Content.Document
  alias BarkparkWeb.Plugs.BoundDataset

  @own "bound-own"
  @prod "production"

  setup do
    ws = create_workspace!("bound-fill-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id]

    tasks =
      for ds <- [@prod, @own], into: %{} do
        {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
        upsert_task_schemas!(ds, scope)
        Barkpark.LabelFixtures.register_tags!(ds)
        {ds, task!(ds, scope, "TASK-IN-#{ds}")}
      end

    {:ok, ws: ws, tasks: tasks}
  end

  defp bearer(ws, opts) do
    raw = "bound-fill-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "bound fill", @own, ["read", "write", "admin"], ws.id, opts)

    {scoped_conn() |> put_req_header("authorization", "Bearer " <> raw), token}
  end

  defp lifecycle(doc), do: Repo.get!(Document, doc.id).content["lifecycle_status"]

  describe "the Tasks API, a request naming no dataset" do
    test "a dataset-bound token cannot read or stage a production task", %{ws: ws, tasks: tasks} do
      {conn, _} = bearer(ws, dataset_bound: true)
      prod = tasks[@prod]

      assert conn |> get("/v1/tasks/#{prod.doc_id}") |> response(404)

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post("/v1/tasks/#{prod.doc_id}/stage", Jason.encode!(%{state: "considering"}))
             |> response(404)

      assert lifecycle(prod) == "open"
    end

    test "it reads its own dataset's task, and lists only that one", %{ws: ws, tasks: tasks} do
      {conn, _} = bearer(ws, dataset_bound: true)

      assert conn |> get("/v1/tasks/#{tasks[@own].doc_id}") |> response(200)

      listed = conn |> get("/v1/tasks") |> response(200)
      assert listed =~ "TASK-IN-#{@own}"
      refute listed =~ "TASK-IN-#{@prod}"
    end

    test "an unbound token still reads both (control)", %{ws: ws, tasks: tasks} do
      {conn, _} = bearer(ws, [])

      assert conn |> get("/v1/tasks/#{tasks[@prod].doc_id}") |> response(200)
      assert conn |> get("/v1/tasks/#{tasks[@own].doc_id}") |> response(200)
    end
  end

  describe "what a bound token may name" do
    test "another dataset, or a dataset that is not a string, is refused", %{ws: ws} do
      {conn, _} = bearer(ws, dataset_bound: true)

      for query <- ["dataset=#{@prod}", "dataset[]=#{@prod}", "dataset[a]=#{@prod}"] do
        body = conn |> get("/v1/tasks?" <> query) |> response(403)
        assert body =~ "dataset_not_bound"
      end

      assert conn |> get("/v1/tasks?dataset=#{@own}") |> response(200)
    end
  end

  describe "endpoints that cannot take an extra param" do
    test "the chat API does not see the filled dataset as an unknown key", %{ws: ws} do
      {conn, _} = bearer(ws, dataset_bound: true)

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/sessions", Jason.encode!(%{}))

      refute resp.resp_body =~ "unrecognized"
      refute resp.resp_body =~ "dataset"
    end
  end

  describe "BoundDataset.resolve/2 and unfill/1" do
    defp conn_with(params, path_params \\ %{}),
      do: %{Plug.Test.conn(:get, "/") | params: params, path_params: path_params}

    test "fills an absent dataset, and unfill takes exactly that back out", %{ws: ws} do
      {_, token} = bearer(ws, dataset_bound: true)

      assert {:ok, filled} = BoundDataset.resolve(conn_with(%{"a" => "1"}), token)
      assert filled.params == %{"a" => "1", "dataset" => @own}
      assert BoundDataset.unfill(filled).params == %{"a" => "1"}

      # A dataset the CALLER named is not ours to remove.
      assert {:ok, named} = BoundDataset.resolve(conn_with(%{"dataset" => @own}), token)
      assert BoundDataset.unfill(named).params == %{"dataset" => @own}
    end

    test "refuses another dataset in the path or the params; leaves the path alone", %{ws: ws} do
      {_, token} = bearer(ws, dataset_bound: true)

      assert {:error, :forbidden_dataset} =
               BoundDataset.resolve(conn_with(%{"dataset" => @prod}), token)

      assert {:error, :forbidden_dataset} =
               BoundDataset.resolve(conn_with(%{}, %{"dataset" => @prod}), token)

      assert {:ok, same} = BoundDataset.resolve(conn_with(%{}, %{"dataset" => @own}), token)
      assert same.params == %{}
    end

    test "an unbound token and no token are untouched", %{ws: ws} do
      {_, token} = bearer(ws, [])
      conn = conn_with(%{"a" => "1"})

      assert {:ok, ^conn} = BoundDataset.resolve(conn, token)
      assert {:ok, ^conn} = BoundDataset.resolve(conn, nil)
      assert {:ok, _} = BoundDataset.resolve(conn_with(%{"dataset" => ["x"]}), token)
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

  defp task!(dataset, scope, title) do
    doc_id = "bound-fill-#{System.unique_integer([:positive])}"

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "fixture #{doc_id}",
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
