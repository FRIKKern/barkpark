defmodule Barkpark.Search.SynonymsCandidatesCrossTenantTest do
  @moduledoc """
  Regression pin for the THREE tenancy arms inside `Synonyms.candidates/3` that
  `synonyms_insights_tenancy_test.exs` (shipped with #14349) does not reach.

  `candidates/3` runs two reads with two DIFFERENT tenant boundaries, and the
  sibling file only covers one arm of each:

    * the `MergePattern` source read (`scope_rollup_to_workspace/2` — roll-ups
      have NO shared layer, so `nil` means `workspace_id IS NULL`). The sibling
      file proves the workspace-scoped arm; this file proves the **nil/legacy**
      arm, i.e. that an unresolved-tenant caller is not handed a tenant's mined
      transitions.
    * the `existing` synonym dedup read (`scope_to_workspace/2` — synonyms DO
      have a deliberately shared NULL-workspace layer, so this one routes
      through `Content.Scope.scope_to_workspace_including_global/3`). The
      sibling file proves that layer through `list/3`, `search_terms/4` and
      `correction_for/4`; this file proves it **through the dedup MapSet**, in
      both directions: a GLOBAL synonym must still suppress a candidate, and a
      SIBLING tenant's synonym must NOT.

  Each of those three is the only test in the tree that reds when its own arm
  is broken (mutation-verified: three single-line mutations, one red each, with
  the sibling file's 12 tests staying green in all three).

  Everything else about `candidates/3` — the workspace-scoped merge-pattern
  arm, the `Ecto.MultipleResultsError` crash, and BOTH arms of the crystal read
  — is already pinned by the sibling file and deliberately not repeated here.

  Door: `GET /v1/search/:dataset/insights` (and the media twin) ->
  `Intelligence.insights/3` -> `Synonyms.candidates/3`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.Search.{MergePattern, Synonyms}
  alias Barkpark.Tenancy

  # ONE scope string shared by BOTH workspaces — isolation must come from the
  # stamped workspace_id, not the dataset slug. Deliberately a string no other
  # fixture in the tree uses: every agent runs against ONE test database.
  @scope "syn-cand-cross-tenant"
  @surface "documents"
  # A pinned window, not Date.utc_today/0 — the assertions must not depend on
  # what day the suite runs, nor collide with a live crystallizer key.
  @window ~D[2026-01-05]

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "syn-cand-tenant-a", name: "Tenant A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "syn-cand-tenant-b", name: "Tenant B"})
    %{ws_a: ws_a, ws_b: ws_b}
  end

  defp insert_pattern!(ws_id, from_fp, to_fp) do
    %MergePattern{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      period: "week",
      period_start: @window,
      from_fingerprint: from_fp,
      to_fingerprint: to_fp,
      pattern_type: "zero_to_hit",
      transition_count: 4,
      success_count: 3,
      workspace_id: ws_id
    })
    |> Repo.insert!()
  end

  defp candidates(workspace_id) do
    Synonyms.candidates(@surface, @scope,
      period: "week",
      period_start: @window,
      workspace_id: workspace_id
    )
  end

  describe "candidates/3 merge-pattern read" do
    test "NON-VACUITY: this file's fixture really does produce a candidate", %{ws_a: ws_a} do
      # Every other test here asserts an ABSENCE (`== []`, `refute … in`), so a
      # fixture that silently produced nothing would make the whole file green
      # and blind. This is the one test that fails if the scope string, window
      # or transition_count floor ever stops matching `candidates/3`.
      insert_pattern!(ws_a.id, "q:hero", "q:phoenix")

      assert [%{from: "hero", to: "phoenix"}] = candidates(ws_a.id)
    end

    test "a nil/legacy caller sees only the shared (NULL-workspace) layer", %{ws_a: ws_a} do
      insert_pattern!(ws_a.id, "q:hero", "q:phoenix")
      insert_pattern!(nil, "q:legacy", "q:global")

      froms =
        @surface
        |> Synonyms.candidates(@scope, period: "week", period_start: @window)
        |> Enum.map(& &1.from)

      # The legacy bucket is still served — `nil` means `workspace_id IS NULL`,
      # not "no rows", so a pre-tenancy instance still reads what it wrote.
      assert "legacy" in froms

      # …and it means the legacy bucket ALONE. A fail-open nil arm hands an
      # unresolved-tenant caller a real tenant's mined search transitions.
      refute "hero" in froms,
             "a nil workspace_id read tenant A's merge pattern — the rollup " <>
               "read's nil arm is fail-open"
    end
  end

  describe "the dedup read's shared layer must SURVIVE the fix" do
    # `Synonyms.scope_to_workspace/2` routes to
    # `Content.Scope.scope_to_workspace_including_global/3`: `ws == ^id OR
    # is_nil(ws)`. It deliberately INCLUDES the legacy/global layer, unlike the
    # rollup boundary above. These two tests are the anti-refactor guards for
    # that asymmetry AT THE DEDUP SEAT — collapsing this call onto the
    # fail-closed workspace-ONLY `scope_to_workspace/3` would silently
    # re-propose already-promoted global synonyms, and opening it back up would
    # let a sibling's promotion suppress this tenant's candidate.

    test "a GLOBAL synonym still suppresses a scoped tenant's candidate", %{ws_a: ws_a} do
      insert_pattern!(ws_a.id, "q:hero", "q:phoenix")
      # NULL-workspace synonym — the legacy/global layer.
      assert {:ok, _} =
               Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"}, nil)

      # The dedup read must SEE the global row, so the already-promoted pair
      # drops out. A workspace-ONLY helper here would miss it.
      assert [] == candidates(ws_a.id)
    end

    test "a SIBLING tenant's synonym does NOT suppress this tenant's candidate", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      insert_pattern!(ws_a.id, "q:hero", "q:phoenix")
      # B's own promotion must be invisible to A, so A still gets the candidate.
      assert {:ok, _} =
               Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"}, ws_b.id)

      assert [%{from: "hero", to: "phoenix"}] = candidates(ws_a.id)
    end
  end
end
