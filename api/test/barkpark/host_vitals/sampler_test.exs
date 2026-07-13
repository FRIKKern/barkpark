defmodule Barkpark.HostVitals.SamplerTest do
  use ExUnit.Case, async: false

  alias Barkpark.HostVitals.Sampler

  @pinned_keys ~w(cpu_pct load1 load5 load15 mem_used_mb mem_total_mb mem_pct
                  disk_pct disk_total_gb host_uptime_s sampled_at)a

  describe "snapshot/0 default (no tick yet / sampler down)" do
    setup do
      # Ensure no stale persistent_term entry leaks between runs.
      :persistent_term.erase({Sampler, :snapshot})
      :ok
    end

    test "returns an honest all-nil frame, never fabricated zeros" do
      snap = Sampler.snapshot()

      for key <- @pinned_keys do
        assert Map.has_key?(snap, key), "missing pinned key #{key}"

        assert Map.fetch!(snap, key) == nil,
               "#{key} should be nil before first tick, not a fake value"
      end
    end
  end

  describe "sample/0 (live probes)" do
    test "returns the pinned shape with numeric-or-nil fields, never crashes" do
      # os_mon may or may not be up in the test node; either way sample/0 must
      # return the full shape and never raise (each probe degrades to nil).
      snap = Sampler.sample()

      assert MapSet.subset?(MapSet.new(@pinned_keys), MapSet.new(Map.keys(snap)))

      for key <- @pinned_keys -- [:sampled_at] do
        val = Map.fetch!(snap, key)
        assert is_nil(val) or is_number(val), "#{key}=#{inspect(val)} must be number or nil"
      end

      # sampled_at is stamped every tick — an integer epoch, never nil.
      assert is_integer(snap.sampled_at)
    end
  end

  test "topic/0 is the shared broadcast topic" do
    assert Sampler.topic() == "server_vitals"
  end
end
