defmodule Barkpark.Search.SurfaceConfigCacheInvalidationTest do
  @moduledoc """
  Charter D64 cache-coherency guard.

  A per-workspace surface-config MISS falls through to the nil-global (operator
  admin-tuned) row, and `load_or_default/3` caches THAT inherited payload under
  the per-workspace key `{workspace_id, surface, scope}` (surface_configs.ex
  `get/3` + `store_config/2`). So when an operator retunes the nil-global row,
  `invalidate/3` must evict not only `{nil, surface, scope}` but EVERY
  per-workspace key that inherited it — otherwise an untuned workspace serves the
  STALE inherited config for up to the 60s ETS TTL.

  Fail-before (the bug this closes): `invalidate/3` deleted ONLY
  `{workspace_id, surface, scope}`, so on a nil-workspace upsert the inherited
  copies cached under real workspace keys survived, and the fresh-workspace read
  below kept returning the pre-upsert value for up to 60s.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Search.SurfaceConfigs

  @surface "documents"
  @scope "production"

  # A tuned typo_policy distinct from the seeded default (similarity_threshold
  # 0.25), so a stale-vs-fresh read is unambiguous.
  defp tuned_policy do
    %{
      "enabled" => true,
      "min_len_1typo" => 5,
      "similarity_threshold" => 0.9,
      "similarity_threshold_relaxed" => 0.9
    }
  end

  setup do
    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    SurfaceConfigs.__reset_cache_for_test__()
    :ok
  end

  test "a nil-global upsert IMMEDIATELY evicts per-workspace keys that inherited the D64 fallthrough" do
    # Operator's global default: similarity_threshold 0.25.
    SurfaceConfigs.seed_defaults!()

    # A workspace with NO own SurfaceConfig row. Its read MISSES and falls through
    # (D64) to the nil-global row, caching that inherited payload under
    # {ws_id, surface, scope}. (A synthetic id is fine: the fallthrough only READS
    # — get_row returns nil for an unknown workspace — so no FK row is written.)
    ws_id = Ecto.UUID.generate()

    inherited =
      SurfaceConfigs.get(@surface, @scope, ws_id)["typo_policy"]["similarity_threshold"]

    assert inherited == 0.25,
           "the untuned workspace should inherit the nil-global default (0.25) via the D64 fallthrough — and CACHE it under its own key"

    # Operator retunes the NIL-GLOBAL row to a distinct value.
    {:ok, _} =
      SurfaceConfigs.upsert(@surface, @scope, %{"typoPolicy" => tuned_policy()}, nil)

    # The workspace read must reflect the NEW value IMMEDIATELY — no 60s TTL wait.
    # FAIL-BEFORE: invalidate/3 deleted only {nil, ...}, so the stale inherited
    # 0.25 was served from the {ws_id, ...} entry until it expired (up to 60s).
    retuned =
      SurfaceConfigs.get(@surface, @scope, ws_id)["typo_policy"]["similarity_threshold"]

    assert retuned == 0.9,
           "the nil-global upsert must evict the per-workspace fallthrough copy so the retuned value (0.9) is served immediately (fail-before: stale 0.25 for up to 60s)"
  end

  test "the eviction is surgical: an UNRELATED (surface, scope) cache entry survives the nil-global upsert" do
    SurfaceConfigs.seed_defaults!()

    # Prime an unrelated cache entry under a DIFFERENT scope. Stored via the real
    # store_config path (nil-workspace key {nil, surface, "beta"}), it is a plain
    # cache hit on read — no DB round-trip.
    SurfaceConfigs.__store_config_for_test__(@surface, "beta", %{"who" => "unrelated"})

    # Retune the nil-global row for the "production" scope only.
    {:ok, _} =
      SurfaceConfigs.upsert(@surface, @scope, %{"typoPolicy" => tuned_policy()}, nil)

    # match_delete targets only {*, surface, "production"} — the "beta" entry must
    # still be served verbatim (proves the fix is NOT a blunt delete_all_objects).
    assert SurfaceConfigs.get(@surface, "beta") == %{"who" => "unrelated"},
           "a nil-global upsert for one scope must not evict cached configs for a different scope"
  end
end
