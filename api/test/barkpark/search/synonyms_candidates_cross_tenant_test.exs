defmodule Barkpark.Search.SynonymsCandidatesCrossTenantTest do
  @moduledoc """
  Parity proof for the W7 intel-tenancy fix (20260715121000).

  That slice taught the crystallizer to STAMP `workspace_id` on every
  `search_intel_crystals` / `search_intel_merge_patterns` row, split the unique
  indexes into per-workspace + legacy-NULL partial arms, and taught EVERY read
  in `Barkpark.Search.Intelligence` to narrow with `scope_ws/2`
  (nil -> `workspace_id IS NULL`, the shared/legacy layer).

  It was NOT carried sideways into `Barkpark.Search.Synonyms`, which
  `Intelligence.insights/3` calls with the same `workspace_id`:

    * `Synonyms.candidates/3` reads `MergePattern` with NO workspace clause at
      all (synonyms.ex:208) while narrowing the `Synonym` read in the SAME
      function (synonyms.ex:242).
    * `Synonyms.crystal_stats/4` reads `Crystal` via a bare `Repo.get_by/2`
      keyed on `(surface, scope, period, period_start, query_normalized,
      filter_fingerprint)` (synonyms.ex:355) — exactly the workspace-blind
      `get_by` that `Intelligence.quality_stats/5` and
      `Crystallizer.upsert_crystal/1` both explicitly refuse in a comment.

  Reachable door: `GET /v1/search/insights?dataset=...` (and the media twin)
  -> `SearchIntelligence.insights/2` -> `Intelligence.insights/3` ->
  `Synonyms.candidates/3`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.Search.{Crystal, MergePattern, Synonyms}
  alias Barkpark.Tenancy

  # ONE scope string shared by BOTH workspaces — isolation must come from the
  # stamped workspace_id, not the dataset slug.
  @scope "production"
  @surface "documents"

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "cand-tenant-a", name: "Tenant A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "cand-tenant-b", name: "Tenant B"})
    %{ws_a: ws_a, ws_b: ws_b, period_start: Date.utc_today()}
  end

  defp insert_pattern!(ws_id, period_start, from_fp, to_fp) do
    %MergePattern{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      period: "week",
      period_start: period_start,
      from_fingerprint: from_fp,
      to_fingerprint: to_fp,
      pattern_type: "zero_to_hit",
      transition_count: 4,
      success_count: 3,
      workspace_id: ws_id
    })
    |> Repo.insert!()
  end

  defp insert_crystal!(ws_id, period_start, query_normalized) do
    %Crystal{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      period: "week",
      period_start: period_start,
      query_normalized: query_normalized,
      filter_fingerprint: "",
      search_count: 10,
      zero_hit_count: 5,
      ctr: 0.5,
      workspace_id: ws_id
    })
    |> Repo.insert!()
  end

  describe "candidates/3 merge-pattern read" do
    test "tenant A's own read SEES its pattern (fixture is well-formed, not vacuous)", %{
      ws_a: ws_a,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")

      assert [%{from: "hero", to: "phoenix"}] =
               Synonyms.candidates(@surface, @scope,
                 period: "week",
                 period_start: period_start,
                 workspace_id: ws_a.id
               )
    end

    test "tenant B NEVER sees tenant A's merge pattern", %{
      ws_a: ws_a,
      ws_b: ws_b,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")

      # RED BEFORE: the MergePattern read carries no workspace clause, so B's
      # insights page proposes a synonym mined from A's users' search queries.
      assert [] ==
               Synonyms.candidates(@surface, @scope,
                 period: "week",
                 period_start: period_start,
                 workspace_id: ws_b.id
               )
    end

    test "a nil/legacy caller sees only the shared (NULL-workspace) layer", %{
      ws_a: ws_a,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")
      insert_pattern!(nil, period_start, "q:legacy", "q:global")

      froms =
        @surface
        |> Synonyms.candidates(@scope, period: "week", period_start: period_start)
        |> Enum.map(& &1.from)

      assert "legacy" in froms
      # RED BEFORE: "hero" leaks into the unscoped/legacy read too.
      refute "hero" in froms
    end
  end

  describe "the global (NULL-workspace) layer must SURVIVE the fix" do
    # These two are the anti-refactor guards. `Synonyms.scope_to_workspace/2`'s
    # NON-nil arm is `ws == ^id OR is_nil(ws)` — it deliberately INCLUDES the
    # legacy/global layer, unlike `Intelligence.scope_ws/2` (workspace-only).
    # Consolidating the Synonym reads onto `Content.Scope.scope_to_workspace/3`
    # (fail-closed, workspace-ONLY) would silently stop returning global
    # synonyms. `scope_to_workspace_including_global/3` is the correct target.
    # Both assertions PASS today and must still pass after the fix.

    test "a GLOBAL synonym still suppresses a scoped tenant's candidate", %{
      ws_a: ws_a,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")
      # NULL-workspace synonym — the legacy/global layer.
      assert {:ok, _} =
               Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"}, nil)

      # The dedup read at synonyms.ex:242 must SEE the global row, so the
      # already-promoted pair drops out. A workspace-ONLY helper would miss it
      # and re-propose an existing synonym.
      assert [] ==
               Synonyms.candidates(@surface, @scope,
                 period: "week",
                 period_start: period_start,
                 workspace_id: ws_a.id
               )
    end

    test "a SIBLING tenant's synonym does NOT suppress this tenant's candidate", %{
      ws_a: ws_a,
      ws_b: ws_b,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")
      # B's own promotion is invisible to A, so A still gets the candidate.
      assert {:ok, _} =
               Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"}, ws_b.id)

      assert [%{from: "hero", to: "phoenix"}] =
               Synonyms.candidates(@surface, @scope,
                 period: "week",
                 period_start: period_start,
                 workspace_id: ws_a.id
               )
    end
  end

  describe "candidate_evidence -> crystal_stats/4 crystal read" do
    test "two tenants' crystals on the SAME key do not crash the insights read", %{
      ws_a: ws_a,
      ws_b: ws_b,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")

      # The per-workspace partial unique index (20260715121000) ALLOWS both of
      # these rows: same (surface, dataset_id, period, period_start,
      # query_normalized, filter_fingerprint), different workspace_id.
      insert_crystal!(ws_a.id, period_start, "hero")
      insert_crystal!(ws_b.id, period_start, "hero")

      # RED BEFORE: `Repo.get_by(Crystal, surface:, scope:, period:,
      # period_start:, query_normalized:, filter_fingerprint:)` matches BOTH
      # rows and raises Ecto.MultipleResultsError -> HTTP 500 on
      # GET /v1/search/insights for EVERY tenant once two tenants search the
      # same term in one period.
      assert [%{from: "hero"}] =
               Synonyms.candidates(@surface, @scope,
                 period: "week",
                 period_start: period_start,
                 workspace_id: ws_a.id
               )
    end

    test "evidence is computed from the caller's OWN crystal, not a sibling's", %{
      ws_a: ws_a,
      ws_b: ws_b,
      period_start: period_start
    } do
      insert_pattern!(ws_a.id, period_start, "q:hero", "q:phoenix")
      # ONLY tenant B has a crystal for the pattern's target term.
      insert_crystal!(ws_b.id, period_start, "phoenix")

      [candidate] =
        Synonyms.candidates(@surface, @scope,
          period: "week",
          period_start: period_start,
          workspace_id: ws_a.id
        )

      # RED BEFORE: A's confidence score is computed from B's click-through
      # rate (ctr 0.5 -> +0.25), so evidence bleeds across the tenant boundary.
      assert candidate.evidence.toCtr == 0.0
    end
  end
end
