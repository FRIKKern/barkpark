defmodule Barkpark.SelfUpdate.CheckerTest do
  # async: false — starts the globally-NAMED Checker GenServer and mutates
  # Application env (the Fake client's script), both process-global.
  use ExUnit.Case, async: false

  alias Barkpark.BuildInfo
  alias Barkpark.SelfUpdate
  alias Barkpark.SelfUpdate.Checker

  @fake Barkpark.SelfUpdate.Client.Fake

  # Push both timers far outside the test window; every check below is
  # driven explicitly through SelfUpdate.check_now/0.
  @quiet_opts [initial_delay_ms: 3_600_000, check_interval_ms: 3_600_000]

  setup do
    prior = Application.get_env(:barkpark, @fake)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, @fake, prior),
        else: Application.delete_env(:barkpark, @fake)
    end)

    :ok
  end

  defp prime(script), do: Application.put_env(:barkpark, @fake, script)

  test "status/0 without a running Checker returns the :disabled map, never raises" do
    # test.exs has enabled: false, so no Checker is in the supervision tree.
    assert Process.whereis(Checker) == nil

    status = SelfUpdate.status()

    assert status == %{
             state: :disabled,
             running_version: BuildInfo.version(),
             running_release: BuildInfo.release(),
             latest_release: nil,
             digest: [],
             checked_at: nil,
             error: nil
           }
  end

  test "enabled?/0 is false in the test env" do
    refute SelfUpdate.enabled?()
  end

  test "check_now/0 reports :behind when the latest release exceeds the running one" do
    # The running release derives from the real `git describe` at build time
    # (v0.2.x today), so 999.0.0 always sorts above it.
    prime(
      latest: {:ok, %{release: "999.0.0", tag: "v999.0.0"}},
      digest: {:ok, ["fix: a thing", "feat: another"]}
    )

    start_supervised!({Checker, @quiet_opts})

    status = SelfUpdate.check_now()

    assert status.state == :behind
    assert status.latest_release == "999.0.0"
    assert status.digest == ["fix: a thing", "feat: another"]
    assert status.running_release == BuildInfo.release()
    assert %DateTime{} = status.checked_at
    assert status.error == nil

    # status/0 returns the cached result of that check.
    assert SelfUpdate.status() == status
  end

  test "check_now/0 reports :current when the latest release does not exceed the running one" do
    prime(latest: {:ok, %{release: "0.0.1", tag: "v0.0.1"}})
    start_supervised!({Checker, @quiet_opts})

    status = SelfUpdate.check_now()

    assert status.state == :current
    assert status.latest_release == "0.0.1"
    assert status.digest == []
    assert status.error == nil
  end

  test "a client error degrades to :unknown with the error recorded" do
    prime(latest: {:error, :nxdomain})
    start_supervised!({Checker, @quiet_opts})

    status = SelfUpdate.check_now()

    assert status.state == :unknown
    assert status.latest_release == nil
    assert status.error =~ "nxdomain"
    assert %DateTime{} = status.checked_at
  end

  test "a digest error is tolerated — still :behind, digest []" do
    prime(
      latest: {:ok, %{release: "999.0.0", tag: "v999.0.0"}},
      digest: {:error, :rate_limited}
    )

    start_supervised!({Checker, @quiet_opts})

    status = SelfUpdate.check_now()

    assert status.state == :behind
    assert status.latest_release == "999.0.0"
    assert status.digest == []
    assert status.error == nil
  end

  test "the pre-first-check status is the :unknown baseline" do
    prime(latest: {:ok, %{release: "999.0.0", tag: "v999.0.0"}})
    start_supervised!({Checker, @quiet_opts})

    # initial_delay_ms is an hour out, so no check has run yet.
    status = SelfUpdate.status()

    assert status.state == :unknown
    assert status.latest_release == nil
    assert status.checked_at == nil
  end
end
