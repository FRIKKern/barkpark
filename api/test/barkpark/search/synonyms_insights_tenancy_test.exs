defmodule Barkpark.Search.SynonymsInsightsTenancyTest do
  @moduledoc """
  Two tenancy defects on the `GET /v1/search/:dataset/insights` path, both
  living in `Barkpark.Search.Synonyms`.

  ## 1. The CRASH (every tenant, not just the colliding pair)

  `20260715121000_search_intel_workspace_unique_index` split the crystal
  uniqueness into two partials, the `workspace_id IS NOT NULL` arm keying on
  `workspace_id` as well. Two workspaces that share a scope STRING (and so
  resolve the SAME `dataset_id` via `Tenancy.default_project_dataset_id/1`) may
  therefore hold TWO crystal rows with an identical `(surface, dataset_id,
  period, period_start, query_normalized, filter_fingerprint)` tuple — that is
  the whole point of the migration.

  `crystal_stats/4` looked those rows up with a bare `Repo.get_by(Crystal,
  surface:, scope:, period:, period_start:, query_normalized:,
  filter_fingerprint:)` — NO workspace key. The moment a second tenant
  crystallizes the same query that `get_by` matches two rows and raises
  `Ecto.MultipleResultsError`, an uncaught 500 on the insights endpoint for
  EVERY tenant asking about that query, including the one that never had a
  sibling. The sibling readers had already been converted away from `get_by`
  for exactly this reason (see the "Query (not get_by)" comments in
  `Intelligence.quality_stats/5` and `Crystallizer.upsert_crystal/1`); this one
  site was missed.

  ## 2. The nil-workspace FAIL-OPEN read

  `Synonyms.scope_to_workspace/2` had a catch-all `def scope_to_workspace(query,
  _), do: query`. A nil workspace_id — what the controllers' `workspace_id(conn)`
  yields when `:current_workspace` is absent — therefore left the query
  COMPLETELY UNFILTERED and read every tenant's synonym rows. The nil arm now
  means the shared/global bucket (`workspace_id IS NULL`), matching the
  documented nil semantics of the sibling `Intelligence.scope_ws/2` and
  `Crystallizer.scope_workspace/2`.

  The non-nil arm is deliberately UNCHANGED: a workspace-scoped caller sees its
  own rows PLUS the NULL-workspace global layer. That is why the fix routes
  through `Content.Scope.scope_to_workspace_including_global/3` and NOT through
  the workspace-only `scope_to_workspace/3` — the two are not interchangeable
  here and collapsing them would silently blind every tenant to the shared
  synonym layer.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Search.{Crystal, MergePattern, Synonyms}
  alias Barkpark.{Repo, Tenancy}

  @surface "documents"
  # ONE scope string shared by BOTH workspaces — the isolation must come from
  # workspace_id, never the dataset slug (both resolve the SAME dataset_id).
  @scope "syn-insights-tenancy"
  @window ~D[2026-01-05]

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "syn-insights-a", name: "Insights A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "syn-insights-b", name: "Insights B"})
    %{ws_a: ws_a, ws_b: ws_b, dataset_id: Tenancy.default_project_dataset_id(@scope)}
  end

  defp merge_pattern!(workspace_id, dataset_id) do
    %MergePattern{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      period: "week",
      period_start: @window,
      from_fingerprint: "q:hero",
      to_fingerprint: "q:phoenix",
      pattern_type: "zero_to_hit",
      transition_count: 8,
      success_count: 6,
      workspace_id: workspace_id,
      dataset_id: dataset_id
    })
    |> Repo.insert!()
  end

  defp crystal!(workspace_id, dataset_id, query, attrs) do
    %Crystal{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          surface: @surface,
          scope: @scope,
          period: "week",
          period_start: @window,
          query_normalized: query,
          filter_fingerprint: "",
          workspace_id: workspace_id,
          dataset_id: dataset_id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp synonym!(from, to, workspace_id) do
    {:ok, row} =
      Synonyms.create(
        @surface,
        @scope,
        %{"from" => from, "to" => to, "kind" => "one_way"},
        workspace_id
      )

    row
  end

  defp candidates(workspace_id) do
    Synonyms.candidates(@surface, @scope,
      period: "week",
      period_start: @window,
      workspace_id: workspace_id
    )
  end

  describe "crystal_stats: two tenants' crystals for one query" do
    test "the partial index really does permit both rows to exist", %{
      ws_a: ws_a,
      ws_b: ws_b,
      dataset_id: dataset_id
    } do
      # The premise of the crash, asserted rather than assumed: the ws-partial
      # unique index keys on workspace_id, so an IDENTICAL (surface, dataset_id,
      # period, period_start, query_normalized, filter_fingerprint) tuple
      # inserts twice.
      crystal!(ws_a.id, dataset_id, "hero", %{search_count: 100})
      crystal!(ws_b.id, dataset_id, "hero", %{search_count: 100})

      assert Repo.aggregate(
               from(c in Crystal,
                 where: c.scope == ^@scope and c.query_normalized == "hero"
               ),
               :count
             ) == 2
    end

    test "candidates/3 answers instead of raising Ecto.MultipleResultsError", %{
      ws_a: ws_a,
      ws_b: ws_b,
      dataset_id: dataset_id
    } do
      merge_pattern!(ws_a.id, dataset_id)

      # Deliberately DIFFERENT numbers per tenant, so a crash is not the only
      # failure mode this can catch.
      crystal!(ws_a.id, dataset_id, "hero", %{search_count: 100, zero_hit_count: 80, ctr: 0.1})
      crystal!(ws_a.id, dataset_id, "phoenix", %{search_count: 100, zero_hit_count: 2, ctr: 0.9})
      crystal!(ws_b.id, dataset_id, "hero", %{search_count: 100, zero_hit_count: 5, ctr: 0.9})
      crystal!(ws_b.id, dataset_id, "phoenix", %{search_count: 100, zero_hit_count: 1, ctr: 0.2})

      # RED before the fix: Ecto.MultipleResultsError out of the bare get_by →
      # HTTP 500 on GET /v1/search/:dataset/insights.
      assert [candidate] = candidates(ws_a.id)

      # And the evidence must be workspace A's, not B's and not a blend.
      assert candidate.evidence.fromZeroHitRate == 0.8,
             "evidence read #{candidate.evidence.fromZeroHitRate} — the crystal " <>
               "lookup is not scoped to the asking workspace"

      assert candidate.evidence.toCtr == 0.9
      # transitions 8 -> min(0.8, 1.0) * 0.5 = 0.4, plus toCtr 0.9 * 0.5 = 0.45.
      assert candidate.evidence.confidence == 0.85
    end

    test "each tenant reads its OWN evidence for the same query", %{
      ws_a: ws_a,
      ws_b: ws_b,
      dataset_id: dataset_id
    } do
      merge_pattern!(ws_a.id, dataset_id)
      merge_pattern!(ws_b.id, dataset_id)

      crystal!(ws_a.id, dataset_id, "hero", %{search_count: 100, zero_hit_count: 80, ctr: 0.1})
      crystal!(ws_a.id, dataset_id, "phoenix", %{search_count: 100, zero_hit_count: 2, ctr: 0.9})
      crystal!(ws_b.id, dataset_id, "hero", %{search_count: 100, zero_hit_count: 10, ctr: 0.5})
      crystal!(ws_b.id, dataset_id, "phoenix", %{search_count: 100, zero_hit_count: 1, ctr: 0.2})

      assert [a] = candidates(ws_a.id)
      assert [b] = candidates(ws_b.id)

      assert a.evidence.fromZeroHitRate == 0.8
      assert a.evidence.toCtr == 0.9
      assert b.evidence.fromZeroHitRate == 0.1
      assert b.evidence.toCtr == 0.2
    end

    test "a NULL-workspace legacy crystal is not read by a workspace-scoped caller", %{
      ws_a: ws_a,
      dataset_id: dataset_id
    } do
      merge_pattern!(ws_a.id, dataset_id)

      # Only the legacy/global rows carry numbers; A has crystallized nothing
      # yet, so its evidence must be the zero baseline. (Crystals are per-tenant
      # roll-ups, unlike synonyms, which have a deliberately shared layer.)
      crystal!(nil, dataset_id, "hero", %{search_count: 100, zero_hit_count: 90, ctr: 0.1})
      crystal!(nil, dataset_id, "phoenix", %{search_count: 100, zero_hit_count: 1, ctr: 0.95})

      assert [candidate] = candidates(ws_a.id)
      assert candidate.evidence.fromZeroHitRate == 0.0
      assert candidate.evidence.toCtr == 0.0
    end
  end

  describe "the merge-pattern candidate source is tenant-scoped" do
    test "workspace A is not offered workspace B's merge pattern as a candidate", %{
      ws_a: ws_a,
      ws_b: ws_b,
      dataset_id: dataset_id
    } do
      merge_pattern!(ws_b.id, dataset_id)

      # RED before: the MergePattern read carried no workspace clause at all, so
      # A's insights listed B's zero_to_hit transition as a synonym candidate —
      # while the `mergePatterns` block of the SAME insights payload
      # (Intelligence, via scope_ws/2) correctly showed nothing.
      assert [] = candidates(ws_a.id)
    end

    test "a workspace still sees its own merge pattern", %{ws_a: ws_a, dataset_id: dataset_id} do
      merge_pattern!(ws_a.id, dataset_id)

      assert [candidate] = candidates(ws_a.id)
      assert candidate.from == "hero"
      assert candidate.to == "phoenix"
    end
  end

  describe "nil workspace_id is the shared/global bucket, never every tenant" do
    test "list/3 with a nil workspace does NOT return another tenant's rows", %{ws_a: ws_a} do
      synonym!("wizard", "gandalf", ws_a.id)
      synonym!("hobbit", "halfling", nil)

      froms = @surface |> Synonyms.list(@scope, nil) |> Enum.map(& &1.from)

      refute "wizard" in froms,
             "a nil workspace_id left the synonym query UNFILTERED — this is the " <>
               "cross-tenant read: an unresolved-tenant caller saw workspace A's rows"

      # The global/legacy layer is still served — the point of the nil arm
      # meaning `workspace_id IS NULL` rather than "no rows".
      assert "hobbit" in froms
    end

    test "search_terms/4 with a nil workspace does not expand another tenant's synonym", %{
      ws_a: ws_a
    } do
      synonym!("wizard", "gandalf", ws_a.id)
      synonym!("hobbit", "halfling", nil)

      refute "gandalf" in Synonyms.search_terms(@surface, @scope, "wizard", nil)
      assert "halfling" in Synonyms.search_terms(@surface, @scope, "hobbit", nil)
    end

    test "correction_for/4 with a nil workspace does not correct via another tenant's row", %{
      ws_a: ws_a
    } do
      synonym!("wizard", "gandalf", ws_a.id)
      synonym!("hobbit", "halfling", nil)

      assert Synonyms.correction_for(@surface, @scope, "wizard", nil) == nil
      assert Synonyms.correction_for(@surface, @scope, "hobbit", nil) == "halfling"
    end

    test "a nil-workspace caller sees NOTHING when only tenants wrote", %{ws_b: ws_b} do
      synonym!("orc", "goblin", ws_b.id)

      assert Synonyms.list(@surface, @scope, nil) == []
      assert Synonyms.correction_for(@surface, @scope, "orc", nil) == nil
    end

    test "candidates/3 suppression: a nil caller is not blocked by a tenant's synonym", %{
      ws_b: ws_b,
      dataset_id: dataset_id
    } do
      merge_pattern!(nil, dataset_id)
      synonym!("hero", "phoenix", ws_b.id)

      # RED before: the unfiltered nil read pulled B's hero→phoenix row into the
      # `existing` MapSet and suppressed the global candidate.
      assert [candidate] = candidates(nil)
      assert candidate.from == "hero"
      assert candidate.to == "phoenix"
    end

    test "the non-nil arm is UNCHANGED: own rows PLUS the global layer", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      synonym!("wizard", "gandalf", ws_a.id)
      synonym!("hobbit", "halfling", nil)

      a_froms = @surface |> Synonyms.list(@scope, ws_a.id) |> Enum.map(& &1.from)
      assert "wizard" in a_froms
      assert "hobbit" in a_froms, "the global (NULL-workspace) layer must stay visible"

      b_froms = @surface |> Synonyms.list(@scope, ws_b.id) |> Enum.map(& &1.from)
      refute "wizard" in b_froms
      assert "hobbit" in b_froms

      # And the shared layer still expands / corrects for a tenant caller.
      assert "halfling" in Synonyms.search_terms(@surface, @scope, "hobbit", ws_a.id)
      assert Synonyms.correction_for(@surface, @scope, "hobbit", ws_b.id) == "halfling"
    end
  end
end
