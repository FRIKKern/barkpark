defmodule BarkparkWeb.TasksDocIdDatasetFlagTest do
  @moduledoc """
  `?dataset=` — THE REMEDY THE `ambiguous_dataset` REFUSAL NAMES, made typeable
  (task-1e3101eaf9a03f84).

  `GET /v1/tasks/:doc_id` refuses a doc_id that lives in two datasets of one
  workspace+project with a 409 whose message says "Name the dataset you mean
  (?dataset=<name> on the task route)". Both halves of that remedy already
  worked — `find_task_by_doc_id/2` reads `conn.params["dataset"]`, and
  `globalQueryForwards` (internal/cli/globals.go) forwards a TYPED `-d` for any
  command whose manifest DECLARES a dataset flag (`commandDeclaresFlag`,
  internal/cli/run.go). The MANIFEST was the gap: `task.get` declared
  `flags: []`, so the forward was gated off and
  `bp task get <ambiguous-id> -d production` came back BYTE-IDENTICAL to the
  refusal that told the caller to type it.

  RED on origin/main (9e6daf39d), measured:

    * `task.get` (and ten sibling `:doc_id` verbs) declared no `dataset` flag,
      on the plugin's own `cli_commands/0` AND on the served
      `GET /v1/capabilities` manifest the CLI actually reads.

  The QUIET arm is `describe "the honest refusal survives"`: a caller who names
  NO dataset still gets the 409 on an ambiguous id and a normal 200 on an
  unambiguous one. A change that made the plain call succeed by PICKING a
  dataset would pass the declaration arm while re-introducing exactly the
  behaviour the honest refusal replaced.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-docid-dataset-flag"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-docid-dataset-flag", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for dataset <- [@primary, @secondary], schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  # Same fixture shape as `BarkparkWeb.TasksIndexDatasetTest` — a published row
  # is seeded by renaming a draft in place.
  defp mk_published!(doc_id, dataset, scope, extra \\ %{}) do
    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "#{doc_id} (#{dataset} #{System.unique_integer([:positive])})",
          "content" =>
            Map.merge(
              %{
                "kind" => "task",
                "lifecycle_status" => "open",
                "acceptance_criteria" => [
                  %{
                    "criterion" => "the fixture states its bar",
                    "met" => true,
                    "evidence" => "fixture"
                  }
                ]
              },
              extra
            )
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  # ── the predicate, spelled once ─────────────────────────────────────────
  # DERIVED FROM THE ROUTE, not from a list of verbs: a task command whose
  # `path_template` carries `:doc_id` is resolved by
  # `TasksController.find_task_by_doc_id/2` and can therefore answer 409
  # `ambiguous_dataset`. The test asserts the SAME predicate the plugin applies,
  # so the next `:doc_id` verb someone adds is covered without editing this file.
  defp doc_id_task_commands(cmds) do
    Enum.filter(cmds, fn c ->
      c[:noun] == "task" and String.contains?(c[:http][:path_template], ":doc_id")
    end)
  end

  defp flag_names(cmd), do: Enum.map(cmd[:flags], & &1[:name])

  describe "every :doc_id task verb DECLARES the dataset flag" do
    test "task.get declares it — the verb the refusal's own remedy is unreachable from" do
      # RED on origin/main: `task.get` declared `flags: []`.
      get_cmd =
        Barkpark.Plugins.Tasks.cli_commands()
        |> Enum.find(&(&1[:id] == "task.get"))

      assert get_cmd, "task.get must exist in the tasks plugin manifest"
      assert "dataset" in flag_names(get_cmd)
    end

    test "the declaration is route-derived: EVERY :doc_id task verb carries it" do
      cmds = Barkpark.Plugins.Tasks.cli_commands()
      by_doc_id = doc_id_task_commands(cmds)

      # Guard the guard: an empty set would make the assertion below vacuous.
      assert length(by_doc_id) >= 10,
             "expected the :doc_id task family, got #{inspect(Enum.map(by_doc_id, & &1[:id]))}"

      missing = for c <- by_doc_id, "dataset" not in flag_names(c), do: c[:id]

      assert missing == [],
             "these :doc_id task verbs declare no dataset flag: #{inspect(missing)}"
    end

    test "the CONTROL: ready and events already declared it, and are left verbatim" do
      cmds = Barkpark.Plugins.Tasks.cli_commands()

      for id <- ["task.ready", "task.events"] do
        cmd = Enum.find(cmds, &(&1[:id] == id))
        assert cmd, "#{id} must exist"
        assert "dataset" in flag_names(cmd)
        # exactly one — the clause must not append a second declaration
        assert Enum.count(flag_names(cmd), &(&1 == "dataset")) == 1
      end
    end

    test "the NEGATIVE control: non-:doc_id verbs are untouched by the rule" do
      cmds = Barkpark.Plugins.Tasks.cli_commands()

      for id <- ["task.ls", "task.prime", "task.next"] do
        cmd = Enum.find(cmds, &(&1[:id] == id))
        assert cmd, "#{id} must exist"
        refute String.contains?(cmd[:http][:path_template], ":doc_id")
      end
    end

    test "it reaches the WIRE: GET /v1/capabilities serves the flag on task.get", %{conn: conn} do
      # The CLI reads the SERVED manifest, not `cli_commands/0`. RED on
      # origin/main: `flags` was `[]` on this envelope too.
      body = authed(conn) |> get("/v1/capabilities") |> json_response(200)

      cmds = body["commands"] || body["cli_commands"] || []
      get_cmd = Enum.find(cmds, &(&1["id"] == "task.get"))

      assert get_cmd, "task.get must ride the served capabilities manifest"
      assert "dataset" in Enum.map(get_cmd["flags"], & &1["name"])
    end
  end

  describe "the honest refusal survives" do
    test "an ambiguous id with NO dataset is still REFUSED, never picked", ctx do
      doc_id = uniq("docidds-ambig")
      mk_published!(doc_id, @primary, ctx.scope)
      mk_published!(doc_id, @secondary, ctx.scope, %{"dataset_twin_intended" => true})

      # `Barkpark.Tasks.AmbiguousTwinError` is a Plug.Exception (409) — under
      # ConnCase it propagates, so the refusal is read off the rendered body.
      {409, _headers, raw} =
        assert_error_sent(409, fn -> authed(ctx.conn) |> get("/v1/tasks/#{doc_id}") end)

      body = Jason.decode!(raw)

      assert body["error"]["code"] == "ambiguous_dataset"
      assert Enum.sort(body["error"]["details"]["datasets"]) == Enum.sort([@primary, @secondary])
    end

    test "naming the dataset FOLLOWS the remedy on the same route", ctx do
      doc_id = uniq("docidds-ambig")
      mk_published!(doc_id, @primary, ctx.scope)
      mk_published!(doc_id, @secondary, ctx.scope, %{"dataset_twin_intended" => true})

      for ds <- [@primary, @secondary] do
        body = authed(ctx.conn) |> get("/v1/tasks/#{doc_id}?dataset=#{ds}") |> json_response(200)
        assert body["doc"]["doc_id"] == doc_id
      end
    end

    test "an UNAMBIGUOUS id with no dataset still reads normally", ctx do
      doc_id = uniq("docidds-solo")
      mk_published!(doc_id, @primary, ctx.scope)

      body = authed(ctx.conn) |> get("/v1/tasks/#{doc_id}") |> json_response(200)
      assert body["doc"]["doc_id"] == doc_id
    end
  end
end
