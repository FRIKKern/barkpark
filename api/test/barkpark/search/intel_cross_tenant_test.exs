defmodule Barkpark.Search.IntelCrossTenantTest do
  @moduledoc """
  Fail-before protective test for the LIVE cross-tenant search-intelligence bleed
  (W7 Intel-tenancy, VF2 RUN-proven).

  ## The bleed

  The crystallizer resolves a crystal/merge-pattern's `dataset_id` from its
  `scope` STRING, and two workspaces that both own the universally-seeded
  `"production"` slug resolve to the SAME `dataset_id`. The pre-fix crystallizer
  enumerated only `(surface, scope)` pairs and stamped NO `workspace_id`, so 3
  workspace-A + 4 workspace-B `"hero"` searches under `(documents, production)`
  folded into ONE crystal `search_count=7, workspace_id=nil`, the two tenants'
  merge transitions summed to `transition_count=2`, and `popular` unioned both.

  ## RED on origin/main

    * crystal roll-up: ONE row `search_count=7` (`workspace_id=nil`); the
      per-workspace `Repo.get_by(..., workspace_id: ws.id)` returns `nil`.
    * merge pattern: ONE `hero→hero filter_merge` row `transition_count=2`.
    * insights.topQueries / suggestions.popular: one `hero` bucket count 7.

  ## GREEN after the fix

  Events are stamped with `workspace_id` at ingest, the crystallizer enumerates
  `(surface, scope, workspace_id)` triples and threads the leaf into the upsert
  get_by keys, and every insights/popular read filters on `workspace_id` — so
  each tenant gets its OWN isolated roll-up (A=3, B=4; transitions 1/1).

  Events use a day inside BOTH the `@backfill_days` window (so `crystallize_due`
  processes them end-to-end) and the 30-day popular window, so the assertions are
  deterministic against `Date.utc_today()`.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Search.{Crystal, Crystallizer, Event, Intelligence, MergePattern}
  alias Barkpark.Repo

  @surface "documents"
  # Deliberately the universally-shared slug — isolation MUST come from
  # workspace_id, not the dataset leaf (both tenants resolve the same dataset_id).
  @scope "production"

  setup do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    today = Date.utc_today()
    # today-2: inside @backfill_days (3) AND the 30-day popular window.
    day = Date.add(today, -2)
    at = fn h, m -> DateTime.new!(day, Time.new!(h, m, 0, {0, 6}), "Etc/UTC") end

    # ── workspace A: 3 "hero" searches, one linked pair (1 transition) ────────
    {:ok, a1} = insert_event(ws_a.id, "a1", "hero", @scope, at.(10, 0))
    {:ok, _a2} = insert_event(ws_a.id, "a1", "hero", @scope, at.(10, 1), parent: a1.id)
    # 59 min later, no parent → NOT a linked transition (chain gap is 30 min).
    {:ok, _a3} = insert_event(ws_a.id, "a1", "hero", @scope, at.(11, 0))

    # ── workspace B: 4 "hero" searches, one linked pair (1 transition) ────────
    {:ok, b1} = insert_event(ws_b.id, "b1", "hero", @scope, at.(10, 0))
    {:ok, _b2} = insert_event(ws_b.id, "b1", "hero", @scope, at.(10, 1), parent: b1.id)
    {:ok, _b3} = insert_event(ws_b.id, "b1", "hero", @scope, at.(11, 0))
    {:ok, _b4} = insert_event(ws_b.id, "b1", "hero", @scope, at.(12, 0))

    # End-to-end: exercises the (surface, scope, workspace_id) enumeration.
    Crystallizer.crystallize_due(today)

    {:ok, ws_a: ws_a, ws_b: ws_b, day: day}
  end

  test "crystal roll-ups are ISOLATED per workspace (not one summed row)", ctx do
    a = hero_crystal(ctx.ws_a.id, ctx.day)
    b = hero_crystal(ctx.ws_b.id, ctx.day)

    assert a.search_count == 3,
           "workspace A's crystal should count only A's 3 searches (was 7 merged on origin/main)"

    assert b.search_count == 4,
           "workspace B's crystal should count only B's 4 searches (was 7 merged on origin/main)"

    # And there is NO merged workspace_id=nil row swallowing both tenants
    # (is_nil query — Ecto forbids `workspace_id: nil` in get_by).
    refute Repo.exists?(
             from(c in Crystal,
               where:
                 c.surface == ^@surface and c.scope == ^@scope and c.period == "day" and
                   c.period_start == ^ctx.day and c.query_normalized == "hero" and
                   c.filter_fingerprint == "q:hero" and is_nil(c.workspace_id)
             )
           )
  end

  test "merge-pattern roll-ups are ISOLATED per workspace (transitions 1/1 not 2)", ctx do
    a = hero_merge(ctx.ws_a.id, ctx.day)
    b = hero_merge(ctx.ws_b.id, ctx.day)

    assert a.transition_count == 1,
           "workspace A's merge pattern should count only A's 1 transition (was 2 merged)"

    assert b.transition_count == 1,
           "workspace B's merge pattern should count only B's 1 transition (was 2 merged)"
  end

  test "insights.topQueries reads only the caller's workspace", ctx do
    a = insights_hero(ctx.ws_a.id, ctx.day)
    b = insights_hero(ctx.ws_b.id, ctx.day)

    assert a.searchCount == 3, "insights for A saw B's traffic (merged 7 on origin/main)"
    assert b.searchCount == 4, "insights for B saw A's traffic (merged 7 on origin/main)"
  end

  test "suggestions.popular is isolated per workspace (not unioned)", ctx do
    a = popular_hero(ctx.ws_a.id)
    b = popular_hero(ctx.ws_b.id)

    assert a.count == 3, "popular for A unioned B's traffic (merged 7 on origin/main)"
    assert b.count == 4, "popular for B unioned A's traffic (merged 7 on origin/main)"
  end

  # --- helpers --------------------------------------------------------------

  defp hero_crystal(workspace_id, day) do
    Repo.get_by!(Crystal,
      surface: @surface,
      scope: @scope,
      period: "day",
      period_start: day,
      query_normalized: "hero",
      filter_fingerprint: "q:hero",
      workspace_id: workspace_id
    )
  end

  defp hero_merge(workspace_id, day) do
    Repo.get_by!(MergePattern,
      surface: @surface,
      scope: @scope,
      period: "day",
      period_start: day,
      from_fingerprint: "q:hero",
      to_fingerprint: "q:hero",
      pattern_type: "filter_merge",
      workspace_id: workspace_id
    )
  end

  defp insights_hero(workspace_id, day) do
    Intelligence.insights(@surface, @scope,
      period: "day",
      period_start: day,
      workspace_id: workspace_id
    ).topQueries
    |> Enum.find(&(&1.query == "hero"))
  end

  defp popular_hero(workspace_id) do
    Intelligence.suggestions(@surface, @scope, "reader", nil, workspace_id: workspace_id).popular
    |> Enum.find(&(&1.query == "hero"))
  end

  defp insert_event(workspace_id, actor, query, scope, at, opts \\ []) do
    %Event{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: scope,
      workspace_id: workspace_id,
      query: query,
      query_normalized: query,
      filters: %{},
      result_count: 3,
      zero_hits: false,
      actor_key: actor,
      quality: "accepted",
      parent_event_id: Keyword.get(opts, :parent),
      inserted_at: at
    })
    |> Repo.insert()
  end
end
