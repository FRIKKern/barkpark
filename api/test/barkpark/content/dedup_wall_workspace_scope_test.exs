defmodule Barkpark.Content.DedupWallWorkspaceScopeTest do
  @moduledoc """
  TENANCY regression: the E4 near-duplicate wall must scope its candidate scan
  to the ACTOR's workspace/project, not to the raw `dataset` STRING alone.

  Documents uniqueness is `[:doc_id, :type, :dataset_id]` (migration
  20260527134000), so a `dataset` string is NOT globally unique — two distinct
  workspaces can share one dataset string. Before the fix, `do_fetch_candidates`
  filtered by the raw string only (`maybe_filter_dataset/2`), so workspace-A's
  publish of a walled (paper|task) doc whose title is trgm-similar to a
  DIFFERENT workspace-B incumbent returned `{:error, {:duplicate_of, payload}}`
  (409) — leaking B's title + published_id across the tenant boundary.

  The fix pipes `Scope.scope_to_workspace_or_global(workspace_id, project_id)`
  into the candidate query. This test seeds two DISTINCT non-Default
  workspaces/projects sharing one dataset string, publishes a walled doc in each
  with trgm-similar titles, and asserts A's publish does NOT 409 against B.

  ## Non-vacuity — proven by reverting the scope pipe

  With the `Scope.scope_to_workspace_or_global` pipe removed from
  `do_fetch_candidates` (dedup_wall.ex), this test reds exactly so, with
  workspace-B's incumbent surfacing in the 409 payload (captured output):

      2) test workspace-A's walled publish does NOT 409 against a foreign
         workspace-B near-dup (Barkpark.Content.DedupWallWorkspaceScopeTest)
         match (=) failed
         code:  assert :ok = result
         left:  :ok
         right: {:error,
                 {:duplicate_of,
                  %{duplicate_of: "ws-b-incumbent",
                    similar: [%{id: "ws-b-incumbent", similarity: 1.0, shared_tokens: 5}]}}}

  Restoring the pipe greens it (21 tests, 0 failures across this file +
  dedup_wall_test.exs). The same-workspace positive control
  (`still 409s a same-workspace near-dup`) stays green in BOTH states — proving
  the fix narrows the scan to the actor, it does not disable the wall.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.{DedupWall, Document}
  alias Barkpark.TenancyFixtures
  alias Barkpark.Repo

  # Deliberately the SAME dataset string across both workspaces — isolation must
  # come from workspace_id, not the dataset leaf (mirrors TenancyFixtures'
  # shared-"test"-dataset design).
  @shared_dataset "shared-content"

  # A title with enough shared tokens to clear the refuse floor (sim >= 0.55,
  # shared >= 3) so the wall WOULD 409 if the foreign row were in scope.
  @dup_title "Rate limiting the mutate controller endpoint"

  defp publish_paper_in!(doc_id, workspace, project, title) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => doc_id,
      "type" => "paper",
      "dataset" => @shared_dataset,
      "title" => title,
      "status" => "published",
      "content" => %{
        "tags" => [
          %{"tag" => "rate-limiting", "strength" => 50, "rationale" => "r"},
          %{"tag" => "mutate", "strength" => 50, "rationale" => "r"}
        ]
      },
      "rev" => "rev-#{doc_id}",
      "workspace_id" => workspace.id,
      "project_id" => project.id
    })
    |> Repo.insert!()
  end

  defp incoming(doc_id, title) do
    %{
      doc_id: "drafts.#{doc_id}",
      title: title,
      content: %{
        "tags" => [%{"tag" => "rate-limiting"}, %{"tag" => "mutate"}]
      }
    }
  end

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    # Workspace-B already published a near-identical-titled paper in the SAME
    # dataset string.
    publish_paper_in!("ws-b-incumbent", ws_b, proj_b, @dup_title)

    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  test "workspace-A's walled publish does NOT 409 against a foreign workspace-B near-dup",
       %{ws_a: ws_a, proj_a: proj_a} do
    result =
      DedupWall.check(
        incoming("ws-a-new", @dup_title),
        "paper",
        @shared_dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    # The foreign incumbent is out of A's scope, so the scan finds no candidate.
    assert :ok = result

    # Belt-and-braces: even a {:ok, warnings} advise band must never name B's
    # row — assert no foreign title/published_id crosses the boundary in ANY
    # returned payload shape.
    refute inspect(result) =~ "ws-b-incumbent"
    refute inspect(result) =~ @dup_title |> String.slice(0, 12)
  end

  test "still 409s a same-workspace near-dup (the wall is narrowed, not disabled)",
       %{ws_a: ws_a, proj_a: proj_a} do
    # A's OWN prior publish in A's scope.
    publish_paper_in!("ws-a-incumbent", ws_a, proj_a, @dup_title)

    result =
      DedupWall.check(
        incoming("ws-a-new", @dup_title),
        "paper",
        @shared_dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    assert {:error, {:duplicate_of, payload}} = result
    assert payload.duplicate_of == "ws-a-incumbent"
  end
end
