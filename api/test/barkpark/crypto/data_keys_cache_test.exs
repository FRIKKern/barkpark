defmodule Barkpark.Crypto.DataKeysCacheTest do
  use ExUnit.Case, async: false

  alias Barkpark.Crypto.DataKeys

  @cache :barkpark_dek_cache

  setup do
    # First put lazily creates the table (ensure_cache); then clear for a clean
    # start regardless of whether an earlier op already populated it.
    DataKeys.__cache_put_for_test__(nil, "__seed__", 0, <<0>>)
    :ets.delete_all_objects(@cache)
    :ok
  end

  test "the unwrapped-DEK cache is bounded (clear-on-full at the cap)" do
    dek = :crypto.strong_rand_bytes(32)

    # Fill past the 10_000 cap with distinct {workspace_id, scope, version} keys —
    # without the bound this grows one permanent entry per scope.
    for i <- 1..10_050 do
      DataKeys.__cache_put_for_test__(nil, "scope-#{i}", 1, dek)
    end

    assert :ets.info(@cache, :size) <= 10_000

    # A put after the cap tripped is still stored + retrievable (evict → refill
    # works; nothing about put/get changed beyond the bound).
    DataKeys.__cache_put_for_test__(nil, "scope-final", 7, dek)
    assert [{{nil, "scope-final", 7}, ^dek}] = :ets.lookup(@cache, {nil, "scope-final", 7})
  end

  test "a cached DEK is retrievable while under the bound (no spurious eviction)" do
    dek = :crypto.strong_rand_bytes(32)
    DataKeys.__cache_put_for_test__(nil, "acme", 3, dek)
    assert [{{nil, "acme", 3}, ^dek}] = :ets.lookup(@cache, {nil, "acme", 3})
  end

  test "the cache key is per-workspace — same (scope, version), distinct workspaces" do
    dek_a = :crypto.strong_rand_bytes(32)
    dek_b = :crypto.strong_rand_bytes(32)
    ws_a = Ecto.UUID.generate()
    ws_b = Ecto.UUID.generate()

    DataKeys.__cache_put_for_test__(ws_a, "dataset:production", 1, dek_a)
    DataKeys.__cache_put_for_test__(ws_b, "dataset:production", 1, dek_b)

    # Two distinct cache entries — the workspace_id is part of the key, so
    # workspace A's cached DEK is never served for workspace B's read.
    assert [{{^ws_a, "dataset:production", 1}, ^dek_a}] =
             :ets.lookup(@cache, {ws_a, "dataset:production", 1})

    assert [{{^ws_b, "dataset:production", 1}, ^dek_b}] =
             :ets.lookup(@cache, {ws_b, "dataset:production", 1})
  end
end
