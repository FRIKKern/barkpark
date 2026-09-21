defmodule Barkpark.ContentProjectPinnedNilWorkspaceScopeTest do
  @moduledoc """
  task-ab5da5c4faf1a04c: the PROJECT-PINNED, WORKSPACE-UNPINNED scope.

  `BarkparkWeb.Plugs.DatasetCors.cors_scope/1` builds `[project_id: id]` with
  NO `:workspace_id` — a real, routed request shape, not a synthetic one. Two
  things went wrong for that shape and this file reds both:

    1. `Scope.scope_to_workspace_or_global(q, nil, project_id)` matched its
       nil-workspace clause and returned the query UNTOUCHED, DISCARDING the
       project_id. Every tenancy-scoped read reached through that helper with
       a project and no workspace therefore carried NO tenancy clause at all.

    2. `Schema.allowed_origins_for_dataset/2` — the read
       `DatasetCors` actually performs — applied `scope_to_dataset/3` and no
       workspace/project scope WHATSOEVER. Its sibling
       `schema_hash_for_dataset/2` in the same module already applied both.

  With no tenancy clause left, the dataset STRING is the only discriminator,
  and `scope_to_dataset/3` falls back to a bare `x.dataset == ^dataset` match
  whenever the string resolves to no `dataset_id` in the caller's project —
  which is exactly the case when the caller's project owns no dataset row of
  that name. A sibling project's same-named dataset then answers the read.

  Counts are useless here: the test database is shared with other suites. Every
  assertion below is the ABSENCE of a uniquely-suffixed foreign id/origin.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  # A dataset name owned by project B alone. Unique per run so no other suite's
  # rows can satisfy or defeat the assertions.
  defp b_only_dataset, do: "bonly-#{System.unique_integer([:positive])}"

  defp two_projects do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    {proj_a, proj_b, ws_b}
  end

  test "a project-pinned, workspace-unpinned document read does not return a sibling project's rows" do
    {proj_a, proj_b, ws_b} = two_projects()
    ds = b_only_dataset()
    foreign_id = "bdoc-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => foreign_id, "title" => "B-TITLE"},
        ds,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # THE SHAPE UNDER TEST: project_id present, workspace_id absent. Project A
    # owns no dataset row named `ds`, so scope_to_dataset/3 takes its bare
    # STRING fallback and B's row is the only string match in the corpus.
    a_scope = [project_id: proj_a.id]

    a_ids =
      Content.list_documents("post", ds, a_scope)
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    refute Enum.any?(a_ids, &String.contains?(&1, foreign_id)),
           "project A's project-pinned read returned project B's document #{foreign_id}"

    # CONTROL: B's own fully-pinned read DOES see it — proving the row exists
    # and the assertion above is not vacuous.
    b_ids =
      Content.list_documents("post", ds, workspace_id: ws_b.id, project_id: proj_b.id)
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    assert Enum.any?(b_ids, &String.contains?(&1, foreign_id)),
           "control failed: project B cannot see its own document #{foreign_id}"
  end

  test "allowed_origins_for_dataset/2 with a project-pinned, workspace-unpinned scope does not return a sibling project's origins" do
    {proj_a, proj_b, ws_b} = two_projects()
    ds = b_only_dataset()
    foreign_origin = "https://borigin-#{System.unique_integer([:positive])}.example"

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "cors_origins" => [foreign_origin]},
        ds,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # The exact call DatasetCors makes: Content.allowed_origins_for_dataset(ds,
    # [project_id: <caller project>]).
    a_origins = Content.allowed_origins_for_dataset(ds, project_id: proj_a.id)

    refute foreign_origin in a_origins,
           "project A's CORS allowlist for #{ds} leaked project B's origin #{foreign_origin}"

    # CONTROL: B's own scope DOES see it.
    b_origins =
      Content.allowed_origins_for_dataset(ds, workspace_id: ws_b.id, project_id: proj_b.id)

    assert foreign_origin in b_origins,
           "control failed: project B cannot see its own CORS origin"
  end

  test "an opts-less (fully unscoped) internal read still reads globally" do
    # The nil/nil arm is the DELIBERATE global read named in Scope's docs. The
    # project clause must not be applied when there is no project either — this
    # test reds if the fix narrows the wrong arm.
    ds = b_only_dataset()
    origin = "https://global-#{System.unique_integer([:positive])}.example"
    ws = create_workspace!()
    proj = create_project!(ws)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "cors_origins" => [origin]},
        ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

    assert origin in Content.allowed_origins_for_dataset(ds)
  end
end
