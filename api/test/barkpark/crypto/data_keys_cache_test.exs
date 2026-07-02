defmodule Barkpark.Crypto.DataKeysCacheTest do
  use ExUnit.Case, async: false

  alias Barkpark.Crypto.DataKeys

  @cache :barkpark_dek_cache

  setup do
    # First put lazily creates the table (ensure_cache); then clear for a clean
    # start regardless of whether an earlier op already populated it.
    DataKeys.__cache_put_for_test__("__seed__", 0, <<0>>)
    :ets.delete_all_objects(@cache)
    :ok
  end

  test "the unwrapped-DEK cache is bounded (clear-on-full at the cap)" do
    dek = :crypto.strong_rand_bytes(32)

    # Fill past the 10_000 cap with distinct {scope, version} keys — without the
    # bound this grows one permanent entry per scope.
    for i <- 1..10_050 do
      DataKeys.__cache_put_for_test__("scope-#{i}", 1, dek)
    end

    assert :ets.info(@cache, :size) <= 10_000

    # A put after the cap tripped is still stored + retrievable (evict → refill
    # works; nothing about put/get changed beyond the bound).
    DataKeys.__cache_put_for_test__("scope-final", 7, dek)
    assert [{{"scope-final", 7}, ^dek}] = :ets.lookup(@cache, {"scope-final", 7})
  end

  test "a cached DEK is retrievable while under the bound (no spurious eviction)" do
    dek = :crypto.strong_rand_bytes(32)
    DataKeys.__cache_put_for_test__("acme", 3, dek)
    assert [{{"acme", 3}, ^dek}] = :ets.lookup(@cache, {"acme", 3})
  end
end
