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

  # task-31dc7c0068696546. A ticking sampler re-renders every Studio page's
  # footer with the machine's live vitals, so two renders of one unchanged page
  # differ (BoardLiveTest, main run 36554218282: `CPU 97% -> 94%`). Under test
  # the boot-started instance must arm NO tick; dev/prod must still tick.
  describe "the tick is gated by config (dormant in test, ON by default)" do
    test "the boot-started sampler arms no tick under test" do
      pid = Process.whereis(Sampler)
      assert is_pid(pid), "the sampler is a boot child; it must still be running (dormant)"
      assert %{timer: nil} = :sys.get_state(pid)
    end

    test "enabled — the dev/prod default — init arms the tick; disabled arms nothing" do
      saved = Application.get_env(:barkpark, Sampler)
      on_exit(fn -> Application.put_env(:barkpark, Sampler, saved) end)

      Application.delete_env(:barkpark, Sampler)
      assert {:ok, %{timer: ref}} = Sampler.init([])
      assert is_reference(ref), "with no config the sampler must tick (dev/prod unchanged)"
      assert is_integer(Process.cancel_timer(ref))

      Application.put_env(:barkpark, Sampler, enabled: false)
      assert {:ok, %{timer: nil}} = Sampler.init([])
    end
  end
end
