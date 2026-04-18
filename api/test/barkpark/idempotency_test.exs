defmodule Barkpark.IdempotencyTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Idempotency
  alias Barkpark.Idempotency.Key

  describe "hash_key/4" do
    test "is deterministic for same inputs" do
      a = Idempotency.hash_key("k1", "tok", "POST", "/v1/data/mutate/production")
      b = Idempotency.hash_key("k1", "tok", "POST", "/v1/data/mutate/production")
      assert a == b
      assert byte_size(a) == 64
    end

    test "differs when any input changes" do
      base = Idempotency.hash_key("k1", "tok", "POST", "/path")
      refute base == Idempotency.hash_key("k2", "tok", "POST", "/path")
      refute base == Idempotency.hash_key("k1", "tok2", "POST", "/path")
      refute base == Idempotency.hash_key("k1", "tok", "PUT", "/path")
      refute base == Idempotency.hash_key("k1", "tok", "POST", "/other")
    end
  end

  describe "store/lookup round-trip" do
    test "lookup returns :miss for unknown hash" do
      assert :miss = Idempotency.lookup("deadbeef")
    end

    test "store then lookup returns cached response" do
      hash = Idempotency.hash_key("k-store", "tok", "POST", "/p")
      headers = [{"content-type", "application/json"}, {"x-test", "1"}]

      Idempotency.store(hash, "mutation", 201, ~s({"ok":true}), headers)

      assert {:ok, cached} = Idempotency.lookup(hash)
      assert cached.status == 201
      assert cached.body == ~s({"ok":true})
      assert cached.headers["content-type"] == "application/json"
      assert cached.headers["x-test"] == "1"
    end
  end

  describe "sweep/1" do
    test "removes rows older than TTL, keeps fresh rows" do
      fresh = Idempotency.hash_key("fresh", "tok", "POST", "/p")
      old = Idempotency.hash_key("old", "tok", "POST", "/p")

      Idempotency.store(fresh, "mutation", 200, "{}", [])
      Idempotency.store(old, "mutation", 200, "{}", [])

      # Backdate the "old" row by 48h
      backdated = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)

      from(k in Key, where: k.key_hash == ^old)
      |> Repo.update_all(set: [inserted_at: backdated])

      removed = Idempotency.sweep()

      assert removed == 1
      assert :miss = Idempotency.lookup(old)
      assert {:ok, _} = Idempotency.lookup(fresh)
    end
  end
end
