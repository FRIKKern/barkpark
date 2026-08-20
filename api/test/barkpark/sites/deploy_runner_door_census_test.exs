defmodule Barkpark.Sites.DeployRunnerDoorCensusTest do
  @moduledoc """
  Mutation proofs for the two gauges dr-w22-s2 added to the box: what the
  build-slot door is actually doing (`DeployRunner.door_census/0`) and how long
  this box has been serving what it is serving (`Barkpark.Sites.ServingMemory`).

  Every test here is shaped so that the OLD behaviour fails it. That is the
  whole point of the slice. The instrument it replaces was
  `body["build_slots"] == DeployRunner.build_slot_capacity()` — an assertion in
  which both sides are the same compile-time constant, so it holds on an idle
  box, on a saturated box, on a box that refused 1,810 deploys in 34 hours, and
  on a box with no door at all. A test a constant satisfies by identity cannot
  notice a missing measurement.

  The four properties, and the way each one is made able to lose:

    * `observed_in_flight` is a MEASUREMENT — driven to 1 with a build actually
      running and back to 0 when it ends. A constant fails both halves.
    * `refusals_total` rises across a refusal AND does not rise without one —
      a counter that only ever went up would pass the first half alone.
    * the serving clock is UN-IMPROVABLE by a restart: re-reading an unchanged
      sha returns a BYTE-IDENTICAL `first_seen_at`, proven after real wall-clock
      time has passed, so a fabricated `now` would differ.
    * an unknown sha renders TWO EXPLICIT NULLS — never a zero, never `now`,
      which is exactly the inverse this whole epic exists to remove.
  """
  # async: false — mutates the singleton Runner + Application env, and the
  # census counter is process-global.
  use ExUnit.Case, async: false

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.DeployRunner
  alias Barkpark.Sites.Provisioner
  alias Barkpark.Sites.ServingMemory

  # Every `deploy` provisions first, so the Provisioner needs a real (tmp) sites
  # root + template or a trigger dies before it ever reaches the door.
  setup do
    base = Path.join(System.tmp_dir!(), "bp-census-#{System.unique_integer([:positive])}")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"census-stub"}))

    prior = Application.get_env(:barkpark, Provisioner)

    Application.put_env(:barkpark, Provisioner,
      sites_dir: Path.join(base, "sites"),
      template_dir: template
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, DeployRunner)
    Application.put_env(:barkpark, DeployRunner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)
    end)
  end

  defp req(slug, opts \\ []) do
    {:ok, request} =
      DeployRequest.new(%{
        "slug" => slug,
        "build_id" => Keyword.get(opts, :build_id, "b1"),
        "mode" => Keyword.get(opts, :mode, "deploy")
      })

    request
  end

  defp stub(script), do: {"bash", ["-c", script]}

  defp await_in_flight(target, budget_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_in_flight(target, deadline)
  end

  defp do_await_in_flight(target, deadline) do
    observed = DeployRunner.door_census().observed_in_flight

    cond do
      observed == target -> observed
      System.monotonic_time(:millisecond) >= deadline -> observed
      true -> Process.sleep(25) && do_await_in_flight(target, deadline)
    end
  end

  # ── observed concurrency: a real measurement, not the attribute ──────────

  describe "door_census/0 observed_in_flight" do
    test "reads 0 idle, 1 with a build in flight, and 0 again when it ends" do
      put_cfg(enabled: true, command: stub("sleep 0.8; exit 0"))

      assert await_in_flight(0) == 0

      before = DeployRunner.door_census()
      assert before.observed_in_flight == 0
      assert before.in_flight_slugs == []
      # The capacity column still says what it always said.
      assert before.capacity == DeployRunner.build_slot_capacity()

      assert DeployRunner.trigger(req("census-alpha")) == {:ok, :started}

      busy = DeployRunner.door_census()

      # A CONSTANT CANNOT DO THIS. `build_slots` reads 1 here and read 1 a line
      # ago; `observed_in_flight` moved because the box moved.
      assert busy.observed_in_flight == 1
      assert busy.in_flight_slugs == ["census-alpha"]
      assert busy.observed_in_flight != before.observed_in_flight

      # …and it falls back on its own when the build finishes.
      assert await_in_flight(0) == 0
      assert DeployRunner.door_census().in_flight_slugs == []
    end

    test "measured_at moves with the measurement, so staleness is stated and not implied" do
      put_cfg(enabled: true, command: stub("exit 0"))

      first = DeployRunner.door_census().measured_at
      assert %DateTime{} = first

      Process.sleep(5)
      assert DeployRunner.trigger(req("census-measured-at")) == {:ok, :started}

      second = DeployRunner.door_census().measured_at
      assert DateTime.compare(second, first) == :gt
      assert await_in_flight(0) == 0
    end

    test "refresh_door_census/1 recomputes inside the Runner and agrees with the ETS reading" do
      put_cfg(enabled: true, command: stub("exit 0"))
      assert await_in_flight(0) == 0

      fresh = DeployRunner.refresh_door_census()
      assert fresh.observed_in_flight == 0
      assert fresh.capacity == DeployRunner.build_slot_capacity()
      assert DeployRunner.door_census().observed_in_flight == fresh.observed_in_flight
    end
  end

  # ── the refusal counter: it must be able to NOT rise ─────────────────────

  describe "door_census/0 refusals" do
    test "rises across a refusal, does NOT rise across an admitted deploy, and never travels without its window" do
      put_cfg(enabled: true, command: stub("sleep 0.8; exit 0"))
      assert await_in_flight(0) == 0

      start = DeployRunner.door_census()
      assert is_integer(start.refusals_total)

      # THE WINDOW. The counter lives in a table the Runner owns, so the total
      # is meaningless without the instant it started — and rendering it bare is
      # how a fresh process gets misread as a quiet door.
      assert %DateTime{} = start.refusals_since

      # An ADMITTED deploy: the door opened, so nothing may be counted.
      assert DeployRunner.trigger(req("census-admitted")) == {:ok, :started}
      admitted = DeployRunner.door_census()
      assert admitted.refusals_total == start.refusals_total

      # A REFUSED one, while that build holds the box's only slot.
      assert DeployRunner.trigger(req("census-refused")) == {:error, :box_at_capacity}
      refused = DeployRunner.door_census()
      assert refused.refusals_total == start.refusals_total + 1

      # Two more refusals count as two, not as "busy".
      assert DeployRunner.trigger(req("census-refused-2")) == {:error, :box_at_capacity}
      assert DeployRunner.trigger(req("census-refused-3")) == {:error, :box_at_capacity}
      assert DeployRunner.door_census().refusals_total == start.refusals_total + 3

      # The window did not move underneath the count.
      assert DateTime.compare(DeployRunner.door_census().refusals_since, start.refusals_since) ==
               :eq

      assert await_in_flight(0) == 0

      # A refusal for a DIFFERENT reason is not a door refusal: the same slug
      # twice is `already_running`, which never reaches the door.
      base = DeployRunner.door_census().refusals_total
      assert DeployRunner.trigger(req("census-same")) == {:ok, :started}

      assert DeployRunner.trigger(req("census-same", build_id: "b2")) ==
               {:error, :already_running}

      assert DeployRunner.door_census().refusals_total == base

      assert await_in_flight(0) == 0
    end

    test "a disabled box refuses without touching the door's counter" do
      put_cfg(enabled: false)
      before = DeployRunner.door_census().refusals_total

      assert DeployRunner.trigger(req("census-disabled")) == {:error, :disabled}

      # `feature off` is not `door busy`. Counting it would inflate exactly the
      # number an operator would use to decide the door is too tight.
      assert DeployRunner.door_census().refusals_total == before
    end
  end

  # ── the serving clock: a restart must not improve it ─────────────────────

  describe "ServingMemory — a clock a restart cannot improve" do
    setup %{base: base} do
      dir = Path.join(base, "run-state")
      File.mkdir_p!(dir)
      {:ok, dir: dir}
    end

    test "THE RESTART TEST: an UNCHANGED sha returns a byte-identical first_seen_at", %{dir: dir} do
      sha = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"

      first = ServingMemory.read(dir: dir, sha: sha)
      assert first.serving_sha == sha
      assert is_binary(first.serving_since)

      # Real wall-clock time passes — more than the record's one-second
      # resolution — so a fabricated `now` on the second read CANNOT come back
      # equal. This is the whole mechanism: `docker restart` changes nothing
      # about the sha, so it must change nothing about the clock.
      Process.sleep(1_100)

      second = ServingMemory.read(dir: dir, sha: sha)
      assert second.serving_since === first.serving_since
      assert second == first

      # And the re-read did not rewrite the record.
      third = ServingMemory.read(dir: dir, sha: sha)
      assert third.serving_since === first.serving_since
    end

    test "a CHANGED sha MOVES first_seen_at — a real deploy is the only thing that resets it",
         %{dir: dir} do
      old_sha = "1111111111111111111111111111111111111111"
      new_sha = "2222222222222222222222222222222222222222"

      first = ServingMemory.read(dir: dir, sha: old_sha)
      Process.sleep(1_100)
      moved = ServingMemory.read(dir: dir, sha: new_sha)

      assert moved.serving_sha == new_sha
      refute moved.serving_since == first.serving_since
      assert DateTime.compare(iso!(moved.serving_since), iso!(first.serving_since)) == :gt

      # The new sighting is now the durable one: re-reading it is stable again.
      Process.sleep(1_100)
      assert ServingMemory.read(dir: dir, sha: new_sha).serving_since === moved.serving_since
    end

    test "an UNREADABLE sha renders two explicit nulls — never a zero, never a fabricated now",
         %{dir: dir} do
      assert ServingMemory.read(dir: dir, sha: nil) == %{serving_sha: nil, serving_since: nil}

      # A value that is not a sha (a branch name, a git error on stdout, an
      # empty var) is unknown, not recorded — a bad record is worse than none.
      for junk <- ["", "   ", "HEAD", "not-a-sha", "zzzzzzz"] do
        assert ServingMemory.read(dir: dir, sha: junk) == %{
                 serving_sha: nil,
                 serving_since: nil
               }
      end

      # …and nothing was written on the unknown path.
      refute File.exists?(Path.join(dir, "serving-memory.json"))
    end

    test "a corrupt record is replaced, not believed", %{dir: dir} do
      sha = "abcabcabcabcabcabcabcabcabcabcabcabcabca"
      File.write!(Path.join(dir, "serving-memory.json"), "{not json")

      read = ServingMemory.read(dir: dir, sha: sha)
      assert read.serving_sha == sha
      assert is_binary(read.serving_since)

      # Having replaced it, the clock is stable again from here.
      assert ServingMemory.read(dir: dir, sha: sha).serving_since === read.serving_since
    end

    test "a record whose sha is stored but whose first_seen_at is missing is not trusted",
         %{dir: dir} do
      sha = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
      File.write!(Path.join(dir, "serving-memory.json"), Jason.encode!(%{sha: sha}))

      read = ServingMemory.read(dir: dir, sha: sha)
      assert read.serving_sha == sha
      assert is_binary(read.serving_since)
    end

    test "the record is sited in the Runner's run-state dir, which is where a restart can find it" do
      dir = Path.join(System.tmp_dir!(), "bp-serving-#{System.unique_integer([:positive])}")
      put_cfg(run_state_dir: dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert DeployRunner.run_state_dir() == dir

      sha = "dededededededededededededededededededede"
      recorded = ServingMemory.read(sha: sha)
      assert recorded.serving_sha == sha

      # Charter D382: this dir is bounded by COUNT only and is not wiped, which
      # is why the clock lives here and not in journald (10 days, volume-bound).
      assert File.exists?(Path.join(dir, "serving-memory.json"))

      assert %{"sha" => ^sha, "first_seen_at" => first_seen_at} =
               dir |> Path.join("serving-memory.json") |> File.read!() |> Jason.decode!()

      assert first_seen_at === recorded.serving_since
    end
  end

  defp iso!(value) do
    {:ok, dt, _offset} = DateTime.from_iso8601(value)
    dt
  end
end
