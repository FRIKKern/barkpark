defmodule Barkpark.TenancyDefaultProjectRoundTripTest do
  @moduledoc """
  `Tenancy.get_default_project/0` costs ONE database round-trip.

  It used to call `get_default_workspace/0` and then run its own
  `Repo.get_by(Project, workspace_id: ws_id, slug: "default")` — two queries for
  one answer. `BarkparkWeb.Plugs.AssignDefaultScope` calls BOTH
  `get_default_workspace/0` and `get_default_project/0` on every flat `/v1/*`
  request, so the workspace lookup was issued twice per request: three queries
  for two rows, on a pipeline that runs ahead of every controller including the
  ones that read nothing.

  Counted from Ecto's `[:barkpark, :repo, :query]` telemetry, not read off the
  source — a join that quietly grew a second statement would still be caught.

  `async: false`: the counter attaches a GLOBAL telemetry handler.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Tenancy

  # Count the Ecto queries THIS process issues while `fun` runs. Scoped to the
  # caller's pid so a concurrent async test cannot inflate the count.
  defp with_query_count(fun) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _cfg ->
        if self() == test_pid, do: send(test_pid, {:repo_query, handler_id, meta[:query]})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(handler_id, acc) do
    receive do
      {:repo_query, ^handler_id, sql} -> drain(handler_id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "get_default_project/0 answers in exactly ONE query" do
    {project, queries} = with_query_count(&Tenancy.get_default_project/0)

    assert %Tenancy.Project{slug: "default"} = project

    assert length(queries) == 1,
           "get_default_project/0 issued #{length(queries)} queries, expected 1:\n" <>
             Enum.join(queries, "\n")
  end

  test "the one query still returns the project owned by the Default Workspace" do
    workspace = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()

    assert project.workspace_id == workspace.id
  end

  test "get_default_workspace/0 is itself one query — the plug pays two, not three" do
    {_ws, ws_queries} = with_query_count(&Tenancy.get_default_workspace/0)
    {_proj, proj_queries} = with_query_count(&Tenancy.get_default_project/0)

    assert length(ws_queries) + length(proj_queries) == 2
  end
end
