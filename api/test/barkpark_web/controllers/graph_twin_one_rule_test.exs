defmodule BarkparkWeb.GraphTwinOneRuleTest do
  @moduledoc """
  THE ONE RULE at the last two doors (task-327276db28c99818, residual of
  task-49eef068420df918 C0). The rule is stated ONCE, in
  `Barkpark.Tasks.TwinResolver`'s moduledoc; this file is its proof for the two
  GRAPH-side resolvers that were still picking a dataset for a task id:

    1. `BarkparkWeb.TasksController.resolve_graph_root/2` — the drafts/raw arm
       ordered `[CASE drafts last, asc: d.dataset, asc: d.id]` and the DEFAULT
       published arm had no order at all, both then `Repo.all() |> List.first()`.
    2. `Barkpark.Content.Graph.resolve_doc/3` (`@canonical capability:slug-resolve`)
       — `limit(1) |> Repo.one()` under a drafts-last CASE order only.

  What is RED on origin/main (mutation-proved, output pasted in the PR body):
  every test in the "rule 3" describe blocks below — both doors returned ONE row
  (whichever sorted first, `aker-brygge` before `production`) instead of
  refusing.

  What is NOT proof of the refusal, stated so nobody reads it as coverage: the
  `?dataset=` and single-row arms are REGRESSION pins — both doors already
  honoured an explicit dataset before this change, and they must keep doing so.

  TASK-SCOPED, and the non-task control is the criterion that pins it (C1):
  `resolve_doc/3` is the resolver for EVERY type, and a second copy of a
  non-task document in another dataset is content replication working as
  designed. A `post` id in two datasets still resolves, exactly as before.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, Graph}
  alias Barkpark.Tasks.AmbiguousTwinError

  @token "barkpark-test-graph-twin-admin"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, _} = Auth.create_token(@token, "graph-twin", @primary, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for dataset <- [@primary, @secondary] do
      Barkpark.LabelFixtures.register_tags!(dataset)

      for schema_def <- Tasks.schema_definitions(dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
      end

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          dataset,
          scope
        )
    end

    %{scope: scope}
  end

  defp bearer(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [
        %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
      ]
    }
  end

  # A PUBLISHED row of `type`, in `dataset`. Created as a draft through the real
  # door then renamed to the published spelling in place — the same shape
  # twin_one_rule_test.exs seeds, and the same shape the eleven live twins are
  # (bare doc_id, status "published", real dataset_id). The authoring wall's
  # label spine is why the real publish door is not used here.
  defp mk_published!(type, doc_id, dataset, scope) do
    content = if type == "task", do: task_content(), else: %{}

    {:ok, draft} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          # Titles DIFFER across the twins on purpose: they are the per-dataset
          # discriminator every assertion below reads, and Tasks.Dedup refuses a
          # near-duplicate title inside one dataset anyway.
          "title" => "#{doc_id} in #{dataset}",
          "content" => Map.put(content, "dataset_twin_intended", true)
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  defp twin_task!(scope) do
    doc_id = uniq("gtwin-task")
    a = mk_published!("task", doc_id, @primary, scope)
    b = mk_published!("task", doc_id, @secondary, scope)
    {doc_id, a, b}
  end

  # ── rule 3, site 1: the graph root resolver ───────────────────────────────

  describe "rule 3 at resolve_graph_root/2 (RED on main: returned one row)" do
    test "GET /v1/graph/:id refuses 409 ambiguous_dataset naming both datasets",
         %{conn: conn, scope: scope} do
      {doc_id, _a, _b} = twin_task!(scope)

      # `assert_error_sent/2`, like tasks_twin_one_rule_test.exs: the refusal is a
      # RAISE at the resolver chokepoint, so this measures the WHOLE wire path —
      # `Plug.Exception`'s 409 AND `BarkparkWeb.ErrorJSON`'s pass-through, which
      # is what keeps the body off a generic `internal_error`.
      #
      # RED on origin/main: 200, answering from @secondary ("aker-brygge" sorts
      # before "production") — a dataset the caller never named.
      {409, _headers, body} =
        assert_error_sent(409, fn -> conn |> bearer() |> get("/v1/graph/#{doc_id}") end)

      assert %{"error" => error} = Jason.decode!(body)
      assert error["code"] == "ambiguous_dataset"
      assert error["details"]["doc_id"] == doc_id
      assert error["details"]["datasets"] == Enum.sort([@primary, @secondary])
      assert error["hint"] =~ "dataset"
    end

    test "GET /v1/graph/:id/tasks refuses the same way (second caller, same resolver)",
         %{conn: conn, scope: scope} do
      {doc_id, _a, _b} = twin_task!(scope)

      {409, _headers, body} =
        assert_error_sent(409, fn -> conn |> bearer() |> get("/v1/graph/#{doc_id}/tasks") end)

      assert Jason.decode!(body)["error"]["code"] == "ambiguous_dataset"
    end

    test "the drafts perspective refuses too — that arm is where asc: d.dataset lived",
         %{conn: conn, scope: scope} do
      {doc_id, _a, _b} = twin_task!(scope)

      {409, _headers, body} =
        assert_error_sent(409, fn ->
          conn |> bearer() |> get("/v1/graph/#{doc_id}?perspective=drafts")
        end)

      assert Jason.decode!(body)["error"]["code"] == "ambiguous_dataset"
    end
  end

  describe "C1 regression pins at resolve_graph_root/2" do
    test "?dataset= names the row: each dataset answers with its OWN title",
         %{conn: conn, scope: scope} do
      {doc_id, a, b} = twin_task!(scope)
      refute a.rev == b.rev

      primary = conn |> bearer() |> get("/v1/graph/#{doc_id}?dataset=#{@primary}")
      assert primary.status == 200, primary.resp_body
      assert primary.resp_body =~ a.title
      refute primary.resp_body =~ b.title

      secondary = conn |> bearer() |> get("/v1/graph/#{doc_id}?dataset=#{@secondary}")
      assert secondary.status == 200, secondary.resp_body
      assert secondary.resp_body =~ b.title
      refute secondary.resp_body =~ a.title
    end

    test "a single-row task is unaffected", %{conn: conn, scope: scope} do
      doc_id = uniq("gtwin-solo")
      doc = mk_published!("task", doc_id, @primary, scope)

      resp = conn |> bearer() |> get("/v1/graph/#{doc_id}")
      assert resp.status == 200, resp.resp_body
      assert resp.resp_body =~ doc.title
    end

    test "THE NON-TASK CONTROL: a post in two datasets still resolves, 200",
         %{conn: conn, scope: scope} do
      doc_id = uniq("gtwin-post")
      _a = mk_published!("post", doc_id, @primary, scope)
      _b = mk_published!("post", doc_id, @secondary, scope)

      resp = conn |> bearer() |> get("/v1/graph/#{doc_id}")

      assert resp.status == 200,
             "a NON-task twin was refused — the refusal is task-scoped (C1): " <> resp.resp_body
    end
  end

  # ── rule 3, site 2: Content.Graph.resolve_doc/3 ───────────────────────────

  describe "rule 3 at Content.Graph.resolve_doc/3 (RED on main: returned one row)" do
    test "raises AmbiguousTwinError naming both datasets when none was given", %{scope: scope} do
      {doc_id, _a, _b} = twin_task!(scope)

      err = assert_raise AmbiguousTwinError, fn -> Graph.resolve_doc(doc_id, nil, scope) end

      assert Enum.sort(err.datasets) == Enum.sort([@primary, @secondary])
      assert err.doc_id == doc_id
    end

    test "the raise reaches Content.Related, which documents itself as returning []",
         %{scope: scope} do
      # WHY THE RAISE AND NOT nil (the shape decision, PR body): this caller's
      # own @doc says "Returns [] for an unresolvable id — existence-hiding". A
      # nil from the resolver would therefore render an ambiguous task as an
      # EMPTY related list — the silent wrong answer one level up, and one that
      # reads as truth. The refusal is deliberately louder than the
      # existence-hiding posture for this one task-scoped case.
      {doc_id, _a, _b} = twin_task!(scope)

      assert_raise AmbiguousTwinError, fn ->
        Barkpark.Content.Related.related_documents(doc_id, nil, scope)
      end
    end
  end

  describe "C1 regression pins at Content.Graph.resolve_doc/3" do
    test "?dataset= named: each dataset's OWN row, _rev asserted", %{scope: scope} do
      {doc_id, a, b} = twin_task!(scope)

      assert %Document{} = got_a = Graph.resolve_doc(doc_id, @primary, scope)
      assert got_a.rev == a.rev
      assert got_a.dataset == @primary

      assert %Document{} = got_b = Graph.resolve_doc(doc_id, @secondary, scope)
      assert got_b.rev == b.rev
      assert got_b.dataset == @secondary

      refute got_a.rev == got_b.rev
    end

    test "a single-row task resolves, and an unknown id is still nil", %{scope: scope} do
      doc_id = uniq("gtwin-solo-rd")
      doc = mk_published!("task", doc_id, @primary, scope)

      assert %Document{rev: rev} = Graph.resolve_doc(doc_id, nil, scope)
      assert rev == doc.rev

      assert Graph.resolve_doc(uniq("gtwin-nope"), nil, scope) == nil
      assert Graph.resolve_doc(nil, nil, scope) == nil
    end

    test "THE NON-TASK CONTROL: a post in two datasets resolves, never raises",
         %{scope: scope} do
      doc_id = uniq("gtwin-post-rd")
      _a = mk_published!("post", doc_id, @primary, scope)
      _b = mk_published!("post", doc_id, @secondary, scope)

      assert %Document{doc_id: ^doc_id} = Graph.resolve_doc(doc_id, nil, scope)
    end

    test "a published task row outranks a drafts.<id> twin in another dataset — no refusal",
         %{scope: scope} do
      doc_id = uniq("gtwin-mixed")
      published = mk_published!("task", doc_id, @primary, scope)

      {:ok, _draft} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => "#{doc_id} draft twin in #{@secondary}",
            "content" => Map.put(task_content(), "dataset_twin_intended", true)
          },
          @secondary,
          scope
        )

      assert %Document{rev: rev, dataset: @primary} = Graph.resolve_doc(doc_id, nil, scope)
      assert rev == published.rev
    end
  end
end
