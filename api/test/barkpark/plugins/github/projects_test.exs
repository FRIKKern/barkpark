defmodule Barkpark.Plugins.Github.ProjectsTest do
  @moduledoc """
  Wave-5 slice-2 gate: one-directional Projects v2 GraphQL, `project_id`-gated
  and fingerprint-diffed. The `Client` is reached through an injected seam
  (`opts[:client]`) so these tests run WITHOUT the slice-1 `Client.graphql/3`
  transport in the tree — a stub records every call and returns scripted
  responses. Pure/async: `opts[:project_id]` bypasses the DB-backed Settings
  gate.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github.Projects

  # --------------------------------------------------------------------------
  # A stub Client that records calls (via `test_pid`) and returns scripted
  # responses keyed by GraphQL operation. Stands in for the slice-1 transport.
  # --------------------------------------------------------------------------
  defmodule StubClient do
    def get_issue(repo, number, opts) do
      notify(opts, {:get_issue, repo, number})
      resp(opts, :get_issue, {:ok, %{"node_id" => "NODE_default"}})
    end

    def graphql(query, vars, opts) do
      op = op_of(query)
      notify(opts, {:graphql, op, vars})
      resp(opts, op, default_graphql(op))
    end

    defp op_of(q) do
      cond do
        String.contains?(q, "addProjectV2ItemById") -> :add
        String.contains?(q, "updateProjectV2ItemFieldValue") -> :update
        String.contains?(q, "fields(first") -> :fields
        true -> :unknown
      end
    end

    defp default_graphql(:add),
      do: {:ok, %{"addProjectV2ItemById" => %{"item" => %{"id" => "ITEM_default"}}}}

    defp default_graphql(:update),
      do: {:ok, %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "ITEM_default"}}}}

    defp default_graphql(:fields), do: {:ok, %{"node" => %{"fields" => %{"nodes" => []}}}}
    defp default_graphql(_), do: {:ok, %{}}

    defp resp(opts, key, default) do
      case opts[:responses] do
        %{^key => v} -> v
        _ -> default
      end
    end

    defp notify(opts, msg) do
      if pid = opts[:test_pid], do: send(pid, msg)
      :ok
    end
  end

  @repo "FRIKKern/barkpark"
  @project "PVT_kwProject1"

  # A board with a Status single-select (option "Todo") and a Worker
  # single-select (option "bob" only — "alice" deliberately absent).
  defp board_fields do
    %{
      "node" => %{
        "fields" => %{
          "nodes" => [
            %{
              "id" => "FIELD_status",
              "name" => "Status",
              "options" => [%{"id" => "OPT_todo", "name" => "Todo"}]
            },
            %{
              "id" => "FIELD_worker",
              "name" => "Worker",
              "options" => [%{"id" => "OPT_bob", "name" => "bob"}]
            },
            # Goal is a plain (text) field — no options.
            %{"id" => "FIELD_goal", "name" => "Goal"}
          ]
        }
      }
    }
  end

  defp base_opts(extra) do
    [client: StubClient, project_id: @project, test_pid: self()] ++ extra
  end

  defp task(content), do: %{content: content}

  # ==========================================================================
  # (a) Blank project_id → :noop, ZERO client calls (the D10 isolation gate).
  # ==========================================================================
  describe "project_id gate (D10 isolation)" do
    test "blank project_id → :noop, zero client calls" do
      opts = [client: StubClient, project_id: "", test_pid: self()]

      assert Projects.sync(task(%{"lifecycle_status" => "Todo"}), @repo, 7, nil, opts) == :noop

      refute_received {:get_issue, _, _}
      refute_received {:graphql, _, _}
    end

    test "whitespace-only project_id → :noop" do
      opts = [client: StubClient, project_id: "   ", test_pid: self()]
      assert Projects.sync(task(%{"priority" => 1}), @repo, 7, nil, opts) == :noop
      refute_received {:graphql, _, _}
    end
  end

  # ==========================================================================
  # (b) Stored fingerprint == current → :noop, ZERO GraphQL (flagship diff).
  # ==========================================================================
  describe "fingerprint diff (D10 — unchanged → zero GraphQL)" do
    test "stored projects_fingerprint equal to current → :noop, no GraphQL" do
      content = %{
        "lifecycle_status" => "Todo",
        "priority" => 2,
        "claim" => %{"worker" => "alice"},
        "parent_id" => "epic-1"
      }

      doc = task(content)
      fp = Projects.fingerprint(doc)
      link = %{"projects_fingerprint" => fp}

      assert Projects.sync(doc, @repo, 7, link, base_opts([])) == :noop

      refute_received {:get_issue, _, _}
      refute_received {:graphql, _, _}
    end

    test "a changed fingerprint proceeds (stored differs)" do
      doc = task(%{"lifecycle_status" => "Todo"})
      link = %{"projects_fingerprint" => -999_999}

      opts = base_opts(responses: %{fields: {:ok, board_fields()}})
      assert {:ok, %{item_id: "ITEM_default"}} = Projects.sync(doc, @repo, 7, link, opts)

      assert_received {:graphql, :add, _}
    end
  end

  # ==========================================================================
  # (c) Changed fingerprint → addProjectV2ItemById then
  #     updateProjectV2ItemFieldValue with the EXACT fieldId + optionId.
  # ==========================================================================
  describe "GraphQL write sequence on a changed fingerprint" do
    test "adds the item then writes a matched single-select with exact ids" do
      doc = task(%{"lifecycle_status" => "Todo"})
      opts = base_opts(responses: %{fields: {:ok, board_fields()}})

      assert {:ok, %{fingerprint: fp, item_id: "ITEM_default"}} =
               Projects.sync(doc, @repo, 42, nil, opts)

      assert is_integer(fp)

      # node id resolved from REST get_issue, then the board add, then fields.
      assert_received {:get_issue, @repo, 42}
      assert_received {:graphql, :add, %{"projectId" => @project, "contentId" => "NODE_default"}}

      # the Status single-select written with the exact resolved ids.
      assert_received {:graphql, :update, update_vars}
      assert update_vars["fieldId"] == "FIELD_status"
      assert update_vars["optionId"] == "OPT_todo"
      assert update_vars["itemId"] == "ITEM_default"
      assert update_vars["projectId"] == @project
    end

    test "Goal writes a text field (value:{text: parent_id})" do
      doc = task(%{"parent_id" => "epic-7"})
      opts = base_opts(responses: %{fields: {:ok, board_fields()}})

      assert {:ok, %{item_id: _}} = Projects.sync(doc, @repo, 9, nil, opts)

      assert_received {:graphql, :update, vars}
      assert vars["fieldId"] == "FIELD_goal"
      assert vars["text"] == "epic-7"
      refute Map.has_key?(vars, "optionId")
    end

    test "tolerates a graphql response still wrapped in a top-level \"data\" key" do
      doc = task(%{"lifecycle_status" => "Todo"})

      opts =
        base_opts(
          responses: %{
            add: {:ok, %{"data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => "ITEM_w"}}}}},
            fields: {:ok, %{"data" => board_fields()}}
          }
        )

      assert {:ok, %{item_id: "ITEM_w"}} = Projects.sync(doc, @repo, 42, nil, opts)
      assert_received {:graphql, :update, %{"fieldId" => "FIELD_status", "optionId" => "OPT_todo"}}
    end

    test "a stored projects_item_id SKIPS the issue GET + addProjectV2ItemById" do
      doc = task(%{"lifecycle_status" => "Todo"})
      link = %{"projects_item_id" => "ITEM_stored"}
      opts = base_opts(responses: %{fields: {:ok, board_fields()}})

      assert {:ok, %{item_id: "ITEM_stored"}} = Projects.sync(doc, @repo, 5, link, opts)

      refute_received {:get_issue, _, _}
      refute_received {:graphql, :add, _}

      assert_received {:graphql, :update, vars}
      assert vars["itemId"] == "ITEM_stored"
      assert vars["fieldId"] == "FIELD_status"
    end
  end

  # ==========================================================================
  # (d) Unmatched option name → that field skipped, others still written.
  # ==========================================================================
  describe "graceful skips (never crash on operator board config)" do
    test "unmatched single-select option → skip that field, still write others" do
      # worker "alice" has no matching board option; status "Todo" does.
      content = %{"lifecycle_status" => "Todo", "worker" => "alice"}
      opts = base_opts(responses: %{fields: {:ok, board_fields()}})

      assert {:ok, %{item_id: "ITEM_default"}} = Projects.sync(task(content), @repo, 3, nil, opts)

      # Status was written; the unmatched Worker field was NOT.
      assert_received {:graphql, :update, %{"fieldId" => "FIELD_status"}}
      refute_received {:graphql, :update, %{"fieldId" => "FIELD_worker"}}
    end

    test "a field NAME absent from the board → skip it, no crash" do
      # Board with NO Status field at all.
      empty_board = %{"node" => %{"fields" => %{"nodes" => []}}}
      opts = base_opts(responses: %{fields: {:ok, empty_board}})

      assert {:ok, %{item_id: "ITEM_default"}} =
               Projects.sync(task(%{"lifecycle_status" => "Todo"}), @repo, 3, nil, opts)

      refute_received {:graphql, :update, _}
    end
  end

  # ==========================================================================
  # (e) A Client {:error,_} → {:error,_} (sync stays honest; the wiring swallows).
  # ==========================================================================
  describe "honest failure (isolation is the caller's job)" do
    test "get_issue error bubbles as {:error, _}" do
      opts = base_opts(responses: %{get_issue: {:error, :boom}})
      assert {:error, :boom} = Projects.sync(task(%{"lifecycle_status" => "Todo"}), @repo, 7, nil, opts)
    end

    test "an update GraphQL error bubbles as {:error, _}" do
      opts =
        base_opts(
          responses: %{
            fields: {:ok, board_fields()},
            update: {:error, %{reason: {:graphql, ["nope"]}}}
          }
        )

      assert {:error, _} = Projects.sync(task(%{"lifecycle_status" => "Todo"}), @repo, 7, nil, opts)
    end

    test "a fields-query error bubbles as {:error, _}" do
      opts = base_opts(responses: %{fields: {:error, :graphql_down}})
      assert {:error, :graphql_down} =
               Projects.sync(task(%{"lifecycle_status" => "Todo"}), @repo, 7, nil, opts)
    end
  end

  # ==========================================================================
  # Pure derivation + directional purity (D5: no reverse writer exists).
  # ==========================================================================
  describe "desired-value derivation mirrors the projection's label sources" do
    test "status=lifecycle_status, priority=content.priority, worker=claim.worker, goal=parent_id" do
      content = %{
        "lifecycle_status" => "in_progress",
        "priority" => 0,
        "claim" => %{"worker" => "fable"},
        "parent_id" => "goal-9"
      }

      assert %{status: "in_progress", priority: 0, worker: "fable", goal: "goal-9"} =
               Projects.desired_fields(task(content))
    end

    test "worker falls back to content.worker when no claim" do
      assert %{worker: "solo"} = Projects.desired_fields(task(%{"worker" => "solo"}))
    end

    test "absent/blank fields derive to nil (never fabricated)" do
      assert %{status: nil, priority: nil, worker: nil, goal: nil} =
               Projects.desired_fields(task(%{"lifecycle_status" => "  "}))
    end

    test "fingerprint is stable for equal desired maps and differs when a field changes" do
      a = task(%{"lifecycle_status" => "Todo", "priority" => 1})
      b = task(%{"lifecycle_status" => "Todo", "priority" => 1})
      c = task(%{"lifecycle_status" => "Done", "priority" => 1})

      assert Projects.fingerprint(a) == Projects.fingerprint(b)
      refute Projects.fingerprint(a) == Projects.fingerprint(c)
    end

    test "no reverse GitHub→task writer is exported (D5 directional purity)" do
      names = Projects.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert Enum.sort(names) == [:desired_fields, :fingerprint, :sync]
    end
  end
end
