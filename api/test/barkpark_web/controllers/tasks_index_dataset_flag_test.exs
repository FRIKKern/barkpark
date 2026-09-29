defmodule BarkparkWeb.TasksIndexDatasetFlagTest do
  @moduledoc """
  `?dataset=` ON THE INDEX, made typeable from `bp` (task-052c01b723ce1006).

  #18531 taught `GET /v1/tasks` to honour `?dataset=` as a SCOPE SELECTOR:
  named narrows the page, absent spans every dataset in scope, and the envelope
  says which (`page.dataset` / `page.datasets` / `page.dataset_scope` /
  `page.dataset_ambiguous`). The server half worked. The MANIFEST was the gap:
  `task.ls` declared limit/offset/cursor/parent and no `dataset`, and
  `globalQueryForwards` (internal/cli/globals.go) puts a typed `-d` on the wire
  ONLY for a command that DECLARES the flag (`commandDeclaresFlag`,
  internal/cli/run.go) — so `bp task ls -d aker-brygge` sent no `?dataset=` and
  got the same global page it always got.

  RED on origin/main (5e1344233), measured: `task.ls` carries no `dataset` flag
  on `Barkpark.Plugins.Tasks.cli_commands/0` NOR on the served
  `GET /v1/capabilities` manifest the CLI actually reads.

  THE PREDICATE, and why it is not #18611's. #18611 declares the flag from the
  route because that route can answer a 409 `ambiguous_dataset` and the refusal
  names `?dataset=` as its remedy. `GET /v1/tasks` can never answer that — it
  COLLAPSES/withholds twins instead of refusing. The rule HERE is "a command
  whose route READS `?dataset=` AS A SCOPE SELECTOR declares it", and the
  negative control below measures `task.prime` against that same rule: its
  action (`TasksController.prime/2`) passes only `scope_opts(conn)` to
  `Tasks.prime/1` and `Tasks.ready/1` and touches the param only through
  `seal_docs/2` → `request_dataset/1`, which picks the redaction SCHEMA, never
  which rows come back. Declaring a flag there would advertise a narrowing the
  route does not perform.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Tasks, as: TasksPlugin

  @token "barkpark-test-index-dataset-flag"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-index-dataset-flag", "test", ["read", "write", "admin"])

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

  defp flag_names(cmd), do: Enum.map(cmd[:flags], & &1[:name])

  defp mk_published!(doc_id, dataset, scope) do
    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "#{doc_id} (#{dataset})",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "fixture"
              }
            ]
          }
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  describe "task.ls DECLARES the index scope selector" do
    test "on the plugin's own cli_commands/0" do
      # RED on origin/main: flags were limit/offset/cursor/parent, no dataset.
      ls = Enum.find(TasksPlugin.cli_commands(), &(&1[:id] == "task.ls"))

      assert ls, "task.ls must exist in the tasks plugin manifest"

      assert "dataset" in flag_names(ls),
             "task.ls declares no dataset flag — `bp task ls -d <ds>` sends no ?dataset= " <>
               "and silently returns the global page (flags: #{inspect(flag_names(ls))})"

      # Exactly one — the derived clause must be idempotent, not additive.
      assert Enum.count(flag_names(ls), &(&1 == "dataset")) == 1
    end

    test "it reaches the WIRE: GET /v1/capabilities serves the flag on task.ls", %{conn: conn} do
      # The CLI reads the SERVED manifest, not cli_commands/0. RED on
      # origin/main on this envelope too.
      body = authed(conn) |> get("/v1/capabilities") |> json_response(200)

      cmds = body["commands"] || body["cli_commands"] || []
      ls = Enum.find(cmds, &(&1["id"] == "task.ls"))

      assert ls, "task.ls must ride the served capabilities manifest"
      assert "dataset" in Enum.map(ls["flags"], & &1["name"])
    end

    test "the flag's summary names the SELECTOR semantics, not a disambiguator" do
      ls = Enum.find(TasksPlugin.cli_commands(), &(&1[:id] == "task.ls"))
      ds = Enum.find(ls[:flags], &(&1[:name] == "dataset"))

      # A caller reading help has to learn that ABSENT is not "production" but
      # "every dataset in scope" — the whole reason the envelope names the span.
      assert ds[:summary] =~ "page.datasets"
      assert ds[:summary] =~ "page.dataset_scope"
    end
  end

  describe "the predicate, defended by controls" do
    test "NEGATIVE CONTROL: task.prime and task.next still declare NO dataset flag" do
      # Their actions never bind the param as a selector, so the rule must not
      # reach them. This is the arm that fails if someone widens the clause to
      # 'every task read verb'.
      for id <- ["task.prime", "task.next"] do
        cmd = Enum.find(TasksPlugin.cli_commands(), &(&1[:id] == id))
        assert cmd, "#{id} must exist"

        refute "dataset" in flag_names(cmd),
               "#{id} declares a dataset flag, but its route performs no dataset narrowing"
      end
    end

    test "POSITIVE CONTROL: task.ready's own declaration is left verbatim, exactly once" do
      ready = Enum.find(TasksPlugin.cli_commands(), &(&1[:id] == "task.ready"))

      assert Enum.count(flag_names(ready), &(&1 == "dataset")) == 1

      ds = Enum.find(ready[:flags], &(&1[:name] == "dataset"))
      assert ds[:summary] =~ "Narrow the ready page to ONE dataset"
    end
  end

  describe "the route the declaration makes typeable really narrows" do
    test "named vs absent over a two-dataset scope", ctx do
      a = uniq("idxds-primary")
      b = uniq("idxds-secondary")
      mk_published!(a, @primary, ctx.scope)
      mk_published!(b, @secondary, ctx.scope)

      wide =
        authed(ctx.conn) |> get("/v1/tasks?limit=1000") |> json_response(200)

      wide_ids = Enum.map(wide["documents"] || wide["docs"] || [], & &1["doc_id"])
      assert a in wide_ids
      assert b in wide_ids
      assert wide["page"]["dataset_scope"] == "all-datasets-in-scope"

      narrow =
        authed(ctx.conn)
        |> get("/v1/tasks?limit=1000&dataset=#{@secondary}")
        |> json_response(200)

      narrow_ids = Enum.map(narrow["documents"] || narrow["docs"] || [], & &1["doc_id"])
      assert b in narrow_ids
      refute a in narrow_ids
      assert narrow["page"]["dataset_scope"] == "named"
      assert narrow["page"]["dataset"] == @secondary
    end
  end
end
