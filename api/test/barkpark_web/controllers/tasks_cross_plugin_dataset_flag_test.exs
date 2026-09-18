defmodule BarkparkWeb.TasksCrossPluginDatasetFlagTest do
  @moduledoc """
  THE `:doc_id` DATASET RULE IS ROUTE-KEYED, NOT LIST-KEYED
  (task-4968634c648cda54).

  #18611 derived the right predicate — "a command whose route carries `:doc_id`
  under `/v1/tasks` resolves through `TasksController.find_task_by_doc_id/2`,
  can therefore answer a 409 `ambiguous_dataset`, and must declare the
  `?dataset=` remedy that refusal names" — and then applied it with an
  `Enum.map/2` over the TASKS PLUGIN'S OWN `cli_commands/0` list. The predicate
  was about the ROUTE; the application was about the LIST.

  So a command targeting a tasks `:doc_id` route but DECLARED IN ANOTHER PLUGIN
  escaped it. Exactly one exists today:

      session.link-task   POST /v1/tasks/:doc_id/sessions
                          declared in Barkpark.Plugins.Bulldocs

  Its route is `TasksController.sessions/2`, which calls
  `find_task_by_doc_id/2` — so it CAN answer the 409, and the refusal named a
  remedy `bp` could not type for this one verb.

  RED on origin/main (5e1344233): `session.link-task` carries
  `flags: ["add"]` on `Registry.collect_cli_commands/1` AND on the served
  `GET /v1/capabilities` manifest.

  The fix moves the rule to `Registry.collect_cli_commands/1` — the collector
  the `/v1/capabilities` controller folds into `commands[]`, which every
  plugin's declaration passes through. No hand-written exception for
  link-task; the ELEVEN tasks-plugin verbs are the positive control and are
  asserted by the same route predicate the code applies.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Plugins.Registry

  @token "barkpark-test-cross-plugin-dataset-flag"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-cross-plugin-ds-flag", "test", ["read", "write", "admin"])

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp assembled, do: Registry.collect_cli_commands([])

  defp flag_names(cmd), do: Enum.map(cmd[:flags] || [], & &1[:name])

  defp task_doc_id?(path),
    do:
      is_binary(path) and String.starts_with?(path, "/v1/tasks/") and
        String.contains?(path, ":doc_id")

  describe "the escaping command" do
    test "session.link-task declares the dataset flag on the ASSEMBLED manifest" do
      # RED on origin/main: flags were ["add"].
      cmd = Enum.find(assembled(), &(&1[:id] == "session.link-task"))

      assert cmd, "session.link-task must ride the assembled manifest"

      assert cmd[:http][:path_template] == "/v1/tasks/:doc_id/sessions",
             "the row's premise is this verb's ROUTE; if it moved, re-derive the rule"

      assert "dataset" in flag_names(cmd),
             "session.link-task declares no dataset flag — its route can answer 409 " <>
               "ambiguous_dataset and `bp session link-task -d <ds>` cannot type the " <>
               "remedy (flags: #{inspect(flag_names(cmd))})"

      # It is still the BULLDOCS declaration, untouched apart from the appended
      # flag: the fix must not have moved the command into the tasks plugin.
      assert "add" in flag_names(cmd)
      assert cmd[:noun] == "session"
    end

    test "it reaches the WIRE: GET /v1/capabilities serves it", %{conn: conn} do
      body = authed(conn) |> get("/v1/capabilities") |> json_response(200)

      cmd =
        (body["commands"] || [])
        |> Enum.find(&(&1["id"] == "session.link-task"))

      assert cmd, "session.link-task must ride the served capabilities manifest"
      assert "dataset" in Enum.map(cmd["flags"] || [], & &1["name"])
    end
  end

  describe "the predicate, applied over the assembled manifest" do
    test "EVERY /v1/tasks/:doc_id command declares it, whichever plugin declared it" do
      cmds = assembled()
      by_route = Enum.filter(cmds, &task_doc_id?(&1[:http][:path_template]))

      # Guard the guard: an empty (or tasks-only) set would make this vacuous.
      assert length(by_route) >= 12,
             "expected the whole /v1/tasks/:doc_id family across plugins, got " <>
               inspect(Enum.map(by_route, & &1[:id]))

      # The rule is CROSS-PLUGIN or it is not the rule: the set must contain at
      # least one command whose noun is not "task".
      assert Enum.any?(by_route, &(&1[:noun] != "task")),
             "no cross-plugin :doc_id task command in the assembled manifest — this test " <>
               "cannot distinguish a route-keyed rule from the list-keyed one it replaces"

      missing = for c <- by_route, "dataset" not in flag_names(c), do: c[:id]

      assert missing == [],
             "these /v1/tasks/:doc_id commands declare no dataset flag: #{inspect(missing)}"
    end

    test "POSITIVE CONTROL: the eleven tasks-plugin verbs still carry it, exactly once" do
      cmds = assembled()

      for id <- ~w(task.get task.claim task.close task.release task.landed task.stamp
                   task.move task.stage task.pulse task.renew task.discharges) do
        cmd = Enum.find(cmds, &(&1[:id] == id))
        assert cmd, "#{id} must exist in the assembled manifest"
        assert "dataset" in flag_names(cmd), "#{id} lost its dataset flag"

        assert Enum.count(flag_names(cmd), &(&1 == "dataset")) == 1,
               "#{id} declares dataset twice — the assembly pass is not idempotent"
      end
    end

    test "IDEMPOTENCE: an already-declaring command is left verbatim" do
      # task.ready / task.events declare their own dataset flag by hand. Running
      # the rule over them (which assembly does, on top of the tasks plugin's
      # own pass) must append nothing and must not rewrite the summary.
      for id <- ["task.ready", "task.events"] do
        cmd = Enum.find(assembled(), &(&1[:id] == id))
        assert Enum.count(flag_names(cmd), &(&1 == "dataset")) == 1
      end

      ready = Enum.find(assembled(), &(&1[:id] == "task.ready"))
      ds = Enum.find(ready[:flags], &(&1[:name] == "dataset"))
      assert ds[:summary] =~ "Narrow the ready page to ONE dataset"
    end

    test "NEGATIVE CONTROL: the rule does not reach non-/v1/tasks :doc_id routes" do
      # The predicate is ':doc_id UNDER /v1/tasks', not ':doc_id anywhere' — the
      # twin resolver is the task family's rule. Asserted on the function
      # directly because no such route exists in the tree today, which is
      # exactly why the guard is written before one appears.
      elsewhere = %{
        id: "probe.elsewhere",
        noun: "probe",
        http: %{method: "GET", path_template: "/v1/plugins/probe/:doc_id"},
        flags: []
      }

      assert Registry.declare_dataset_on_task_doc_id_route(elsewhere) == elsewhere

      under_tasks = %{
        id: "probe.under-tasks",
        noun: "probe",
        http: %{method: "GET", path_template: "/v1/tasks/:doc_id/probe"},
        flags: []
      }

      rewritten = Registry.declare_dataset_on_task_doc_id_route(under_tasks)
      assert Enum.map(rewritten.flags, & &1.name) == ["dataset"]
    end

    test "NEGATIVE CONTROL: a malformed command is passed through, never raised on" do
      # This runs inside a boot-time collector; a plugin with an odd shape must
      # not take the manifest down.
      assert Registry.declare_dataset_on_task_doc_id_route(%{id: "no.http"}) == %{id: "no.http"}

      odd = %{id: "x", http: %{path_template: nil}, flags: []}
      assert Registry.declare_dataset_on_task_doc_id_route(odd) == odd
    end
  end
end
