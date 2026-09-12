defmodule BarkparkWeb.ChildRailTwinOneRuleTest do
  @moduledoc """
  THE ONE RULE at the CHILD RAIL (task-49eef068420df918, the listing residual of
  C0/C1). The rule is stated ONCE, in `Barkpark.Tasks.TwinResolver`'s moduledoc;
  this file is its proof for the three child-count producers and the index page,
  which collapsed the DRAFT axis (`Tasks.Query.collapse_twins/1`) and left the
  DATASET axis open:

    1. `TasksController.child_tasks/2`   — `show`'s `children` + `child_count`
    2. `Params.batch_child_counts/2`     — the brief/ls card `child_count`
    3. `Params.batch_live_child_counts/2`— the live half of the same number
    4. `TasksController.index/2`         — `GET /v1/tasks`

  What is RED on origin/main (mutation-proved, output pasted in the PR body):
  every test in the "rule 3 at the child rail" and "rule 3 at the index"
  describes. On main an epic whose child lives in BOTH `production` and
  `aker-brygge` reported `child_count: 2` for ONE child and listed it TWICE —
  serving an id `GET /v1/tasks/:doc_id` ITSELF refuses with a 409
  `ambiguous_dataset` (the door immediately above, closed by #16474). That is
  the measured live shape: `child_count: 18` on `akbr-feedback-2026-08-epic`
  for nine children, 9+9 across two datasets.

  WHY WITHHOLD AND NOT PICK. Identical to the ready page's answer
  (`queue_cross_dataset_twin_test.exs`): a by-id door refuses with a 409, a
  listing cannot refuse the whole page over one row, so the row is withheld and
  NAMED once — `show` renders `dataset_ambiguous`, exactly the shape
  `/v1/tasks/ready` renders in `page.dataset_ambiguous`.

  WHAT IS NOT PROOF OF THE REFUSAL, stated so nobody reads it as coverage: the
  `?dataset=` arms are POSITIVE controls (naming a dataset must resolve the id
  on this same door) and the untwinned arms are NEGATIVE controls (an ordinary
  epic must read byte-identically, `dataset_ambiguous` ABSENT). Both pass on
  main; neither would fail if the change were reverted.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  @token "barkpark-test-child-rail-twin-admin"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, _} = Auth.create_token(@token, "child-rail-twin", @primary, ["read", "write", "admin"])

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
    end

    %{scope: scope}
  end

  defp bearer(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A PUBLISHED task row in `dataset`. Same seed shape as
  # `graph_twin_one_rule_test.exs` / `twin_one_rule_test.exs`: created as a
  # draft through the real door, then renamed to the published spelling in
  # place — the shape the eleven live twins actually have (bare doc_id, status
  # "published", real dataset_id). `dataset_twin_intended` is what lets
  # `Tasks.DatasetTwinFence` (#16474, the producer half) admit the second birth;
  # the shape under measurement IS the twin.
  defp mk_published!(doc_id, dataset, scope, content_extra \\ %{}) do
    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "dataset_twin_intended" => true,
        "acceptance_criteria" => [
          %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
        ]
      }
      |> Map.merge(content_extra)

    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "#{doc_id} in #{dataset}",
          "content" => content
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  # An epic in @primary with: one child twinned across BOTH datasets (the
  # ambiguous one) and one child living only in @primary (the control that
  # proves the collapse is not a blanket "drop every child").
  defp epic_with_twinned_child!(scope) do
    epic_id = uniq("crail-epic")
    _epic = mk_published!(epic_id, @primary, scope)

    twin_id = uniq("crail-twin-child")
    _ = mk_published!(twin_id, @primary, scope, %{"parent_id" => epic_id})
    _ = mk_published!(twin_id, @secondary, scope, %{"parent_id" => epic_id})

    solo_id = uniq("crail-solo-child")
    _ = mk_published!(solo_id, @primary, scope, %{"parent_id" => epic_id})

    %{epic_id: epic_id, twin_id: twin_id, solo_id: solo_id}
  end

  defp show(conn, doc_id, query \\ "") do
    conn |> bearer() |> get("/v1/tasks/#{doc_id}#{query}") |> json_response(200)
  end

  # ── rule 3 at the child rail ──────────────────────────────────────────────

  describe "rule 3 at the child rail (RED on main: the twin counted twice)" do
    test "a dataset-less show withholds the twinned child and names it once", %{scope: scope} do
      %{epic_id: epic_id, twin_id: twin_id, solo_id: solo_id} = epic_with_twinned_child!(scope)

      body = show(build_conn(), epic_id)

      # RED on main: ["crail-solo-child", "crail-twin-child", "crail-twin-child"]
      # and child_count 3 — one child served twice, under an id this very
      # controller's by-id door answers 409 for.
      assert Enum.map(body["children"], & &1["doc_id"]) == [solo_id]
      assert body["child_count"] == 1
      assert body["doc"]["child_count"] == 1

      assert body["dataset_ambiguous"] == [
               %{"doc_id" => twin_id, "datasets" => Enum.sort([@primary, @secondary])}
             ]
    end

    test "the withheld id is EXACTLY the id the by-id door refuses (one rule, two doors)", %{
      scope: scope
    } do
      %{epic_id: epic_id, twin_id: twin_id} = epic_with_twinned_child!(scope)

      body = show(build_conn(), epic_id)
      [%{"doc_id" => named}] = body["dataset_ambiguous"]
      assert named == twin_id

      # The SAME id, on the by-id door one level down: 409 naming both datasets.
      # `assert_error_sent/2` (as graph_twin_one_rule_test.exs): the refusal is
      # a RAISE at the resolver chokepoint, so this measures the whole wire path
      # — `Plug.Exception`'s 409 AND `BarkparkWeb.ErrorJSON`'s pass-through,
      # which is what keeps the body off a generic `internal_error`.
      {409, _headers, raw} =
        assert_error_sent(409, fn ->
          build_conn() |> bearer() |> get("/v1/tasks/#{twin_id}")
        end)

      assert %{"error" => error} = Jason.decode!(raw)
      assert error["code"] == "ambiguous_dataset"
      assert Enum.sort(error["details"]["datasets"]) == Enum.sort([@primary, @secondary])
    end

    test "POSITIVE CONTROL: naming ?dataset= resolves the child on this same door", %{
      scope: scope
    } do
      %{epic_id: epic_id, twin_id: twin_id, solo_id: solo_id} = epic_with_twinned_child!(scope)

      # `@primary` and not `@secondary`: the EPIC itself lives only in
      # `production`, and `?dataset=` is honoured by `find_task_by_doc_id/2`
      # for the subject too — naming the dataset the subject is not in is a
      # 404, which would measure the subject lookup and not the rail.
      body = show(build_conn(), epic_id, "?dataset=#{@primary}")

      # EXACTLY ONE copy of the twinned child. The first draft of
      # `child_tasks/2` only SKIPPED the collapse when a dataset was named and
      # read `[solo, twin, twin]` here — lifting the refusal without narrowing
      # the rail, which is worse than not gating at all. This assertion is why
      # the named arm now filters by dataset.

      assert Enum.sort(Enum.map(body["children"], & &1["doc_id"])) ==
               Enum.sort([twin_id, solo_id])

      assert body["child_count"] == 2
      refute Map.has_key?(body, "dataset_ambiguous")
    end

    test "NEGATIVE CONTROL: an untwinned epic reads unchanged, with no ambiguity key", %{
      scope: scope
    } do
      epic_id = uniq("crail-plain-epic")
      _ = mk_published!(epic_id, @primary, scope)
      kid = uniq("crail-plain-child")
      _ = mk_published!(kid, @primary, scope, %{"parent_id" => epic_id})

      body = show(build_conn(), epic_id)

      assert Enum.map(body["children"], & &1["doc_id"]) == [kid]
      assert body["child_count"] == 1
      refute Map.has_key?(body, "dataset_ambiguous")
    end

    test "the grouped card counts AGREE with the rail — one number, four producers", %{
      scope: scope
    } do
      %{epic_id: epic_id} = epic_with_twinned_child!(scope)

      body = show(build_conn(), epic_id)
      epic = Repo.one!(from(d in Document, where: d.doc_id == ^epic_id and d.dataset == @primary))

      # RED on main: batch_child_counts said 3, the rail said 3, and BOTH were
      # wrong the same way; the point of this arm is that they cannot drift
      # apart now that each applies the rule, not that they merely match.
      assert Params.batch_child_counts([epic], scope) == %{epic_id => body["child_count"]}
      assert Params.batch_live_child_counts([epic], scope) == %{epic_id => body["child_count"]}
    end
  end

  # ── rule 3 at the index page ──────────────────────────────────────────────

  describe "rule 3 at the index (RED on main: the twinned id appeared twice)" do
    test "GET /v1/tasks serves a twinned doc_id ZERO times and its sibling once", %{scope: scope} do
      %{twin_id: twin_id, solo_id: solo_id} = epic_with_twinned_child!(scope)

      ids =
        build_conn()
        |> bearer()
        |> get("/v1/tasks?limit=1000")
        |> json_response(200)
        |> Map.fetch!("docs")
        |> Enum.map(& &1["doc_id"])

      assert Enum.count(ids, &(&1 == twin_id)) == 0
      assert Enum.count(ids, &(&1 == solo_id)) == 1
    end

    # NO `?dataset=` POSITIVE CONTROL HERE, and the absence is deliberate:
    # `GET /v1/tasks` does not read `?dataset=` as a scope selector at all
    # (task-8483029782444df4, open) — it is not in the route's filter
    # whitelist. Gating the collapse on a param the route then ignores would
    # be strictly WORSE than not gating it: naming a dataset would lift the
    # refusal without narrowing the page, handing back BOTH rows. So the index
    # collapses unconditionally until that row lands with the filter, and the
    # gate goes in beside it. The rail's positive control above is the proof
    # that naming a dataset resolves an ambiguous id on a door that reads it.
  end
end
