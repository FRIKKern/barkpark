defmodule Barkpark.Search.IntelRecentCrossTenantTest do
  @moduledoc """
  Fail-before protective test for the LIVE `suggestions.recent` tenant/anon leak
  (wave 3, the THIRD bleep not closed by the two Door synonym fixes #12227/#12228).

  ## The leak (origin/main)

  `recent_queries/5` selected `search_intel_events` on `(surface, scope,
  actor_key)` ONLY — never `workspace_id`. So:

    * CLAMP 1 (workspace bleed): a workspace-A actor reading recent suggestions
      saw workspace-B's queries under the same `actor_key` (e.g. `client:web`).
    * CLAMP 2 (anon-key collapse): all anonymous actors share the ONE global
      `actor_key == "anon"`, so an anon recent read unioned every anon
      session/tenant's history.

  ## The fix (intelligence.ex, this file's target)

    * CLAMP 1: `recent_queries/6` pipes the Event query `|> scope_ws(workspace_id)`
      exactly like popular/nohits, so a workspace-bound actor sees only ITS
      workspace's recents; fail-closed on `nil` (`workspace_id IS NULL`).
    * CLAMP 2: a leading `recent_queries(_, _, "anon", _, _, _) -> []` clause —
      anon actors get NO recent history (popular/nohits still serve them).

  ## Mutation proof (revert -> RED / restore -> GREEN)

  Verified by hand in the builder worktree:

    * Remove `|> scope_ws(workspace_id)` from `recent_queries/6` -> the
      "workspace-A recents exclude workspace-B" test REDS (B's "beta-secret"
      leaks into A's recents).
    * Remove the leading `"anon"` clause -> the "anon read returns []" test REDS
      (the two tenants' anon recents union).
    * Restoring either clamp -> GREEN.

  ## Seed discipline

  BOTH workspaces get DISTINCT NON-NIL ids (`create_workspace!/0`), never
  nil/Default: legacy backfill stamps unscoped rows to the Default workspace, so
  `scope_ws(nil)` matches nothing and a nil-contrast seed would green on the
  UNFIXED tree (nil-stays-green). Inserted_at carries full `:utc_datetime_usec`
  precision (`DateTime.utc_now()` UNtruncated) so ordering/dedupe is real.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Search.{Event, Intelligence}
  alias Barkpark.Repo

  @surface "documents"
  # The universally-shared slug — isolation MUST come from workspace_id, not the
  # dataset leaf (both tenants resolve the same dataset_id).
  @scope "production"

  test "CLAMP 1: workspace-A recents EXCLUDE workspace-B's query" do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # Same non-anon actor_key across both tenants — isolation is workspace-only.
    {:ok, _} = insert_event(ws_a.id, "client:web", "alpha-visible")
    {:ok, _} = insert_event(ws_b.id, "client:web", "beta-secret")

    a_recents =
      Intelligence.suggestions(@surface, @scope, "client:web", nil, workspace_id: ws_a.id).recent

    queries = Enum.map(a_recents, & &1.query)

    assert "alpha-visible" in queries,
           "workspace A must still see its OWN recent query (over-block regression)"

    refute "beta-secret" in queries,
           "workspace A saw workspace B's recent query (cross-tenant leak on origin/main)"
  end

  test "CLAMP 2: an anon actor gets NO recents (global-key collapse fail-closed)" do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # Two tenants' recents under the ONE globally-shared anon key.
    {:ok, _} = insert_event(ws_a.id, "anon", "alpha-anon")
    {:ok, _} = insert_event(ws_b.id, "anon", "beta-anon")

    a_recents =
      Intelligence.suggestions(@surface, @scope, "anon", nil, workspace_id: ws_a.id).recent

    assert a_recents == [],
           "anon recents must be empty (they collapse to one shared key across all sessions/tenants)"
  end

  test "CLAMP 1: a non-anon actor's OWN recents survive (no over-block)" do
    ws_a = create_workspace!()
    {:ok, _} = insert_event(ws_a.id, "token:abc", "gamma-own")

    recents =
      Intelligence.suggestions(@surface, @scope, "token:abc", nil, workspace_id: ws_a.id).recent

    assert Enum.any?(recents, &(&1.query == "gamma-own")),
           "a token:<id> actor's own recents must still be returned"
  end

  defp insert_event(workspace_id, actor_key, query) do
    %Event{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      workspace_id: workspace_id,
      query: query,
      query_normalized: query,
      filters: %{},
      result_count: 3,
      zero_hits: false,
      actor_key: actor_key,
      quality: "accepted",
      # Full :utc_datetime_usec precision — do NOT truncate.
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
