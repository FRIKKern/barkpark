defmodule BarkparkWeb.TasksLandedTest do
  @moduledoc """
  Contract tests for `POST /v1/tasks/:doc_id/landed` — the non-holder landing
  mark (task-59fe7b40b719b379).

  These are the tests the requesting workflow actually needs, so they are
  written as the WIRE it will call: a plain write-capable bearer, NO worker_id
  and NO observed_epoch in the body, over HTTP.

    * a fresh row records the landing sentence, and a SECOND call accumulates;
    * with `criterion` it flips ONE merge-shaped criterion;
    * every refusal is a 409 whose `reason` names which one it was and whose
      `message` says what to type instead;
    * the shape errors (nothing to record, a criterion with no note) are 400s
      before any DB work;
    * an unknown task is a 404.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-tasks-landed-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-tasks-landed", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(scope, content_extra \\ %{}) do
    doc_id = uniq("landed-conn")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" =>
            Map.merge(
              %{
                "kind" => "task",
                "acceptance_criteria" => [
                  %{
                    "criterion" => "the fixture states its bar",
                    "met" => true,
                    "evidence" => "fixture"
                  }
                ],
                "lifecycle_status" => "open"
              },
              content_extra
            )
        },
        @dataset,
        scope
      )

    doc
  end

  # THE STORE, NOT THE ENVELOPE. A 2xx is not a landed write — this ledger has
  # watched a task verb return exit 0 on a stamp the store did not hold — so the
  # receipt assertions below are made against the row the store hands back, and
  # the response body is checked for AGREEING with it rather than trusted on its
  # own. This is also what earns the receipt census's `end_to_end` basis: the
  # cited block drives the route AND reads the stored row.
  defp stored(task), do: Repo.get!(Document, task.id)

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp mark(conn, task, body) do
    resp =
      conn
      |> authed()
      |> post("/v1/tasks/#{task.doc_id}/landed", Jason.encode!(body))

    {resp.status, Jason.decode!(resp.resp_body)}
  end

  describe "the landing sentence" do
    test "a fresh row records commit/pr/note with NO worker_id and NO epoch",
         %{conn: conn, scope: scope} do
      task = mk_task!(scope)

      assert {200, body} =
               mark(conn, task, %{commit: "a1b2c3d", pr: "14993", note: "merged to main"})

      assert body["ok"] == true

      assert body["doc"]["content"]["landed"] == %{
               "commits" => ["a1b2c3d"],
               "prs" => ["14993"],
               "notes" => ["merged to main"]
             }

      # The receipt is only true if the store agrees with it.
      assert stored(task).content["landed"] == body["doc"]["content"]["landed"]
    end

    test "a second call ACCUMULATES on the same row", %{conn: conn, scope: scope} do
      task = mk_task!(scope)

      assert {200, _} = mark(conn, task, %{commit: "aaa", pr: "1"})
      assert {200, body} = mark(conn, task, %{commit: "bbb", note: "the second landing"})

      landed = body["doc"]["content"]["landed"]
      assert landed["commits"] == ["aaa", "bbb"]
      assert landed["prs"] == ["1"], "the first call's PR is not clobbered"
      assert landed["notes"] == ["the second landing"]
    end

    test "a task claimed by someone ELSE still takes the mark", %{conn: conn, scope: scope} do
      task = mk_task!(scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "another-worker", scope)

      assert {200, body} = mark(conn, task, %{commit: "a1b2c3d", note: "merged to main"})
      assert body["doc"]["content"]["landed"]["commits"] == ["a1b2c3d"]
      assert body["doc"]["claim"]["worker"] == "another-worker"
      assert body["doc"]["claim"]["epoch"] == claimed.content["claim"]["epoch"]
    end
  end

  describe "the criterion flip" do
    test "flips ONE merge-shaped criterion, evidence = the note",
         %{conn: conn, scope: scope} do
      task =
        mk_task!(scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "the gate is green", "met" => false},
            %{"criterion" => "LEAD-OWNED: PR merged to main", "met" => false}
          ]
        })

      assert {200, body} =
               mark(conn, task, %{
                 commit: "a1b2c3d",
                 note: "PR #14993 merged to main as a1b2c3d",
                 criterion: 1
               })

      [first, second] = body["doc"]["content"]["acceptance_criteria"]
      assert first["met"] == false
      assert second["met"] == true
      assert second["evidence"] == "PR #14993 merged to main as a1b2c3d"
      assert body["doc"]["criteria_progress"] == %{"met" => 1, "total" => 2}
    end

    test "criterion arrives as a STRING too (the query-param spelling)",
         %{conn: conn, scope: scope} do
      task =
        mk_task!(scope, %{
          "acceptance_criteria" => [%{"criterion" => "merged into main", "met" => false}]
        })

      assert {200, body} = mark(conn, task, %{note: "landed", criterion: "0"})
      assert hd(body["doc"]["content"]["acceptance_criteria"])["met"] == true
    end
  end

  describe "409 — the state refusals name why" do
    test "a criterion that is not merge-shaped", %{conn: conn, scope: scope} do
      task =
        mk_task!(scope, %{
          "acceptance_criteria" => [%{"criterion" => "the gate is green", "met" => false}]
        })

      assert {409, body} = mark(conn, task, %{commit: "aaa", note: "merged", criterion: 0})
      assert body["ok"] == false
      assert body["reason"] == "criterion_not_merge_shaped"
      assert body["message"] =~ "merge-shaped"
      assert body["message"] =~ "merge_gate"

      # Nothing was written — the digest did not sneak in behind the refusal.
      # (The flip and the digest ride ONE CAS.)
      fresh = conn |> authed() |> get("/v1/tasks/#{task.doc_id}")
      assert fresh.status == 200
      refute Map.has_key?(Jason.decode!(fresh.resp_body)["doc"]["content"], "landed")
    end

    test "a criterion already met is never overwritten", %{conn: conn, scope: scope} do
      task =
        mk_task!(scope, %{
          "acceptance_criteria" => [
            %{
              "criterion" => "LEAD-OWNED (merge-gated): PR merged to main",
              "met" => true,
              "evidence" => "the original proof"
            }
          ]
        })

      assert {409, body} = mark(conn, task, %{note: "a merge notice", criterion: 0})
      assert body["reason"] == "criterion_already_met"
      assert body["message"] =~ "NEVER overwrites"
    end

    test "an index past the end of the list", %{conn: conn, scope: scope} do
      task =
        mk_task!(scope, %{
          "acceptance_criteria" => [%{"criterion" => "PR merged to main", "met" => false}]
        })

      assert {409, body} = mark(conn, task, %{note: "merged", criterion: 9})
      assert body["reason"] == "criteria_index_out_of_range"
      assert body["message"] =~ "0-BASED"
    end
  end

  describe "400 — shape errors, before any DB work" do
    test "nothing to record", %{conn: conn, scope: scope} do
      task = mk_task!(scope)
      assert {400, body} = mark(conn, task, %{})
      assert body["reason"] == "bad_request"
      assert body["message"] =~ "at least one of commit, pr, note"
    end

    test "a criterion with no note to use as evidence", %{conn: conn, scope: scope} do
      task =
        mk_task!(scope, %{
          "acceptance_criteria" => [%{"criterion" => "PR merged to main", "met" => false}]
        })

      assert {400, body} = mark(conn, task, %{commit: "aaa", criterion: 0})
      assert body["reason"] == "bad_request"
      assert body["message"] =~ "note is required with criterion"
    end

    test "an unparseable criterion index", %{conn: conn, scope: scope} do
      task = mk_task!(scope)
      assert {400, body} = mark(conn, task, %{note: "x", criterion: "first"})
      assert body["reason"] == "bad_request"
      assert body["message"] =~ "non-negative integer"
    end
  end

  test "404 for an unknown task", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> post("/v1/tasks/task-does-not-exist/landed", Jason.encode!(%{note: "merged to main"}))

    assert resp.status == 404
  end

  describe "manifest wiring" do
    test "the route is mounted and the task.landed verb is declared" do
      assert {:post, "/tasks/:doc_id/landed", BarkparkWeb.TasksController, :landed,
              auth: :token_root} in Barkpark.Plugins.Tasks.register_routes(%{})

      spec = Enum.find(Barkpark.Plugins.Tasks.cli_commands(), &(&1.id == "task.landed"))
      assert spec, "task.landed must be in the capabilities manifest"
      assert spec.verb == "landed"
      assert spec.noun == "task"
      assert spec.writes == true
      assert spec.auth_tier == "write"
      assert spec.http == %{method: "POST", path_template: "/v1/tasks/:doc_id/landed"}

      flags = MapSet.new(spec.flags, & &1.name)
      assert MapSet.subset?(MapSet.new(~w(commit pr note criterion)), flags)

      # ADDITIVE: the verb that already shipped is untouched.
      assert Enum.find(Barkpark.Plugins.Tasks.cli_commands(), &(&1.id == "task.stamp"))
    end
  end
end
