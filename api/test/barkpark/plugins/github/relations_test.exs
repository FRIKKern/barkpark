defmodule Barkpark.Plugins.Github.RelationsTest do
  @moduledoc """
  Wave-5 slice-3 relations (D11 + D11-retry):

    * `hydrate_blocker_refs/3` resolves a task's blockers to their MIRRORED issue
      numbers and decorates the doc so the projection renders the blocks fence;
      an unmirrored blocker is OMITTED (never fabricated).
    * `sync/5` mirrors `content.parent_id` to a native sub-issue: `:noop` with no
      parent, `{:defer, :parent_unmirrored}` when the parent has no issue,
      `{:flatten, parent}` past the depth cap, and an idempotent `add_sub_issue`
      (422 tolerated) otherwise.

  GitHub HTTP is a seam-injected stub — no live client, no Bypass needed here.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Github.{Link, Projection, Relations}

  @dataset "production"
  @repo "FRIKKern/barkpark"

  # ---------------------------------------------------------------------------
  # Seam stub: a Client replacement dispatched via config. Records each call to
  # the test process and returns a per-test-configurable response.
  # ---------------------------------------------------------------------------
  defmodule StubClient do
    alias Barkpark.Plugins.Github.Errors.NetworkError

    def get_issue(_repo, number, opts) do
      notify(opts, {:get_issue, number})

      case cfg(:get_issue) do
        nil -> {:ok, %{"id" => 9001, "number" => number}}
        resp -> resp
      end
    end

    def add_sub_issue(repo, parent_num, child_db_id, opts) do
      notify(opts, {:add_sub_issue, repo, parent_num, child_db_id})

      case cfg(:add_sub_issue) do
        nil -> {:ok, %{}}
        :already_linked -> {:error, %NetworkError{reason: {:http, 422}, endpoint: "/sub_issues"}}
        resp -> resp
      end
    end

    defp cfg(key), do: Application.get_env(:barkpark, :relations_test_cfg, %{})[key]

    defp notify(opts, msg) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    Application.put_env(:barkpark, Relations, client: StubClient)
    Application.put_env(:barkpark, :relations_test_cfg, %{})

    on_exit(fn ->
      Application.delete_env(:barkpark, Relations)
      Application.delete_env(:barkpark, :relations_test_cfg)
    end)

    # opts carry both the tenant scope AND the test pid the stub notifies.
    %{scope: scope, opts: scope ++ [test_pid: self()]}
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

  defp mk_task!(doc_id, content, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content)
        },
        @dataset,
        scope
      )

    doc
  end

  defp stub_cfg(map), do: Application.put_env(:barkpark, :relations_test_cfg, map)

  # ---------------------------------------------------------------------------
  # hydrate_blocker_refs/3
  # ---------------------------------------------------------------------------

  describe "hydrate_blocker_refs/3 — content.blocked_by" do
    test "collects only MIRRORED blockers; unmirrored is omitted", %{scope: scope, opts: opts} do
      mk_task!("blk-mirrored", %{}, scope)
      {:ok, _} = Link.put("blk-mirrored", @dataset, %{repo: @repo, issue: 42}, scope)
      mk_task!("blk-dark", %{}, scope)

      task =
        mk_task!("t-main", %{"blocked_by" => ["blk-mirrored", "blk-dark"]}, scope)

      decorated = Relations.hydrate_blocker_refs(task, @dataset, opts)

      assert decorated["blocker_issue_refs"] == [42]

      # And the projection renders the blocks fence with that number.
      issue = Projection.task_to_issue(decorated)
      assert issue.body =~ "<!-- barkpark:blocks:start -->"
      assert issue.body =~ "Blocked by: #42"
      refute issue.body =~ "#0"
    end

    test "no blockers → empty refs, no blocks fence", %{scope: scope, opts: opts} do
      task = mk_task!("t-solo", %{}, scope)
      decorated = Relations.hydrate_blocker_refs(task, @dataset, opts)

      assert decorated["blocker_issue_refs"] == []
      refute Projection.task_to_issue(decorated).body =~ "barkpark:blocks"
    end

    test "a plain-map task (no struct) is decorated too", %{scope: scope, opts: opts} do
      mk_task!("blk-x", %{}, scope)
      {:ok, _} = Link.put("blk-x", @dataset, %{repo: @repo, issue: 7}, scope)

      task = %{"doc_id" => "plain", "content" => %{"blocked_by" => ["blk-x"]}}
      decorated = Relations.hydrate_blocker_refs(task, @dataset, opts)
      assert decorated["blocker_issue_refs"] == [7]
    end
  end

  describe "hydrate_blocker_refs/3 — task_edges graph" do
    test "reads blockers from the authoritative dependency graph", %{scope: scope, opts: opts} do
      blocker = mk_task!("blk-edge", %{}, scope)
      {:ok, _} = Link.put("blk-edge", @dataset, %{repo: @repo, issue: 314}, scope)
      task = mk_task!("t-edged", %{}, scope)

      # child (task) blocks on parent (blocker) — the `blocks` edge.
      {:ok, _} = Tasks.add_dep(task.id, blocker.id, :blocks)

      decorated = Relations.hydrate_blocker_refs(task, @dataset, opts)
      assert decorated["blocker_issue_refs"] == [314]
    end
  end

  # ---------------------------------------------------------------------------
  # sync/5
  # ---------------------------------------------------------------------------

  describe "sync/5 — no parent" do
    test "a task with no parent_id is a no-op, no client calls", %{scope: scope, opts: opts} do
      task = mk_task!("t-orphan", %{}, scope)
      assert Relations.sync(task, @repo, 5, @dataset, opts) == :noop
      refute_received {:get_issue, _}
      refute_received {:add_sub_issue, _, _, _}
    end
  end

  describe "sync/5 — mirrored parent → native sub-issue" do
    setup %{scope: scope} do
      mk_task!("parent-mir", %{}, scope)
      {:ok, _} = Link.put("parent-mir", @dataset, %{repo: @repo, issue: 55}, scope)
      :ok
    end

    test "links the child db id under the parent number", %{scope: scope, opts: opts} do
      task = mk_task!("child-a", %{"parent_id" => "parent-mir"}, scope)

      assert Relations.sync(task, @repo, 77, @dataset, opts) == :ok

      # get_issue on the CHILD number to resolve its db id, then add_sub_issue
      # with the parent NUMBER + child DB id.
      assert_received {:get_issue, 77}
      assert_received {:add_sub_issue, @repo, 55, 9001}
    end

    test "a 422 'already a sub-issue' is idempotent → :ok", %{scope: scope, opts: opts} do
      stub_cfg(%{add_sub_issue: :already_linked})
      task = mk_task!("child-b", %{"parent_id" => "parent-mir"}, scope)

      assert Relations.sync(task, @repo, 78, @dataset, opts) == :ok
      assert_received {:add_sub_issue, @repo, 55, 9001}
    end

    test "a non-422 client error bubbles as {:error, _}", %{scope: scope, opts: opts} do
      stub_cfg(%{add_sub_issue: {:error, :boom}})
      task = mk_task!("child-c", %{"parent_id" => "parent-mir"}, scope)

      assert Relations.sync(task, @repo, 79, @dataset, opts) == {:error, :boom}
    end

    # ---- 422 disambiguation (charter 4b): real reject vs idempotent ----------

    test "a 422 whose body says the link ALREADY exists is idempotent → :ok",
         %{scope: scope, opts: opts} do
      stub_cfg(%{
        add_sub_issue:
          {:error, %{reason: {:http, 422}, message: "Sub-issue already exists on this issue"}}
      })

      task = mk_task!("child-idem", %{"parent_id" => "parent-mir"}, scope)
      assert Relations.sync(task, @repo, 82, @dataset, opts) == :ok
    end

    test "a REAL 422 rejection returns a DISTINCT {:sub_issue_rejected, …} the wiring records",
         %{scope: scope, opts: opts} do
      stub_cfg(%{
        add_sub_issue:
          {:error, %{reason: {:http, 422}, message: "Issue may not be a sub-issue of itself"}}
      })

      task = mk_task!("child-reject", %{"parent_id" => "parent-mir"}, scope)

      assert {:error, {:sub_issue_rejected, 55, 9001, detail}} =
               Relations.sync(task, @repo, 83, @dataset, opts)

      assert detail =~ "may not be a sub-issue"
    end

    test "a 422 rejection carried in a nested errors[] body is surfaced too",
         %{scope: scope, opts: opts} do
      stub_cfg(%{
        add_sub_issue:
          {:error,
           %{
             reason: {:http, 422},
             body: %{"errors" => [%{"message" => "Reference is not a valid issue type"}]}
           }}
      })

      task = mk_task!("child-reject2", %{"parent_id" => "parent-mir"}, scope)

      assert {:error, {:sub_issue_rejected, 55, 9001, detail}} =
               Relations.sync(task, @repo, 84, @dataset, opts)

      assert detail =~ "not a valid issue type"
    end

    test "a 422 with NO legible detail stays conservatively idempotent → :ok",
         %{scope: scope, opts: opts} do
      # The real REST Client discards the 422 body, so a %NetworkError{} carries
      # only reason:{:http,422}. Without a body to judge, we never fabricate a
      # rejection — same conservative :ok as before this slice.
      stub_cfg(%{add_sub_issue: :already_linked})
      task = mk_task!("child-bare", %{"parent_id" => "parent-mir"}, scope)

      assert Relations.sync(task, @repo, 85, @dataset, opts) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # sync/5 — child-count cap (charter 4a)
  # ---------------------------------------------------------------------------

  describe "sync/5 — child-count cap past >100 children" do
    setup %{scope: scope} do
      mk_task!("cc-parent", %{}, scope)
      {:ok, _} = Link.put("cc-parent", @dataset, %{repo: @repo, issue: 500}, scope)
      :ok
    end

    test "a parent past the child cap flattens, no sub-issue call",
         %{scope: scope, opts: opts} do
      # Two DISTINCT children of cc-parent; with the cap dialed to 1 the parent
      # is over-full → cap-flatten (no native link).
      mk_task!("cc-child-1", %{"parent_id" => "cc-parent"}, scope)
      task = mk_task!("cc-child-2", %{"parent_id" => "cc-parent"}, scope)

      opts = Keyword.put(opts, :max_children, 1)
      assert Relations.sync(task, @repo, 92, @dataset, opts) == {:flatten, "cc-parent"}
      refute_received {:add_sub_issue, _, _, _}
    end

    test "a draft/published twin child counts ONCE (dedup) → still links natively",
         %{scope: scope, opts: opts} do
      # ONE logical child, present as BOTH a published row (cc-twin) and a draft
      # row (drafts.cc-twin) — both carry parent_id cc-parent. A naive row count
      # sees 2 and would flatten at cap 1; the DISTINCT count sees 1 and links.
      mk_task!("cc-twin", %{"parent_id" => "cc-parent"}, scope)
      {:ok, _} = Content.publish_document("cc-twin", "task", @dataset, scope)
      task = mk_task!("cc-twin", %{"parent_id" => "cc-parent"}, scope)

      opts = Keyword.put(opts, :max_children, 1)
      assert Relations.sync(task, @repo, 93, @dataset, opts) == :ok
      assert_received {:add_sub_issue, @repo, 500, 9001}
    end

    test "under the cap a normal parent links natively (default cap unaffected)",
         %{scope: scope, opts: opts} do
      task = mk_task!("cc-only", %{"parent_id" => "cc-parent"}, scope)
      # default cap is 100 — one child is nowhere near it.
      assert Relations.sync(task, @repo, 94, @dataset, opts) == :ok
      assert_received {:add_sub_issue, @repo, 500, 9001}
    end
  end

  describe "sync/5 — unmirrored parent → defer" do
    test "defers with no client call when the parent has no issue", %{scope: scope, opts: opts} do
      mk_task!("parent-dark", %{}, scope)
      task = mk_task!("child-d", %{"parent_id" => "parent-dark"}, scope)

      assert Relations.sync(task, @repo, 80, @dataset, opts) == {:defer, :parent_unmirrored}
      refute_received {:get_issue, _}
      refute_received {:add_sub_issue, _, _, _}
    end

    test "a missing parent task also defers (never guesses)", %{scope: scope, opts: opts} do
      task = mk_task!("child-e", %{"parent_id" => "ghost-parent"}, scope)
      assert Relations.sync(task, @repo, 81, @dataset, opts) == {:defer, :parent_unmirrored}
    end
  end

  describe "sync/5 — cap-flatten past the depth cap" do
    test "a parent chain deeper than the cap flattens, no sub-issue call",
         %{scope: scope, opts: opts} do
      # grandparent → parent → task. Parent is mirrored so we reach the depth
      # check. With max_parent_depth: 1, the 2-deep ancestor chain flattens.
      mk_task!("gp", %{}, scope)
      mk_task!("p", %{"parent_id" => "gp"}, scope)
      {:ok, _} = Link.put("p", @dataset, %{repo: @repo, issue: 100}, scope)
      task = mk_task!("child-deep", %{"parent_id" => "p"}, scope)

      opts = Keyword.put(opts, :max_parent_depth, 1)
      assert Relations.sync(task, @repo, 90, @dataset, opts) == {:flatten, "p"}

      refute_received {:add_sub_issue, _, _, _}
    end

    test "a shallow chain under the cap still links natively", %{scope: scope, opts: opts} do
      mk_task!("p2", %{}, scope)
      {:ok, _} = Link.put("p2", @dataset, %{repo: @repo, issue: 200}, scope)
      task = mk_task!("child-shallow", %{"parent_id" => "p2"}, scope)

      # default cap (8) — a 1-deep chain does NOT flatten.
      assert Relations.sync(task, @repo, 91, @dataset, opts) == :ok
      assert_received {:add_sub_issue, @repo, 200, 9001}
    end

    test "the projection renders the parent marker from a hydrated key" do
      doc = %{"doc_id" => "child-deep", "content" => %{"description" => "Human context."}}
      flat = Map.put(doc, "parent_marker", "p")

      issue = Projection.task_to_issue(flat)
      assert issue.body =~ "<!-- barkpark:parent:start -->"
      assert issue.body =~ "Parent: p"
      assert issue.body =~ "Human context."
      assert issue.body =~ "Task: child-deep"
    end
  end
end
