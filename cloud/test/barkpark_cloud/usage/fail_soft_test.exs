defmodule BarkparkCloud.Usage.FailSoftTest do
  @moduledoc """
  ccpca-bl-usage-bare-rescue-narrow. The three control-plane gatherers
  (`seats/1`, `pending_invitations/1`, `instances_input/1`) degrade ONE meter to
  "unmetered" on a transient repo fault, through `Usage.fail_soft/3`. Before, each
  used a BARE `rescue _`, which also swallowed a programmer error into a silent
  "unmetered". The whitelist is now `DBConnection.ConnectionError` and
  `Postgrex.Error`; everything else re-raises.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.Usage

  test "a whitelisted transient DB fault still degrades the meter to its fallback" do
    log =
      capture_log(fn ->
        assert Usage.fail_soft(:seats, nil, fn ->
                 raise DBConnection.ConnectionError, "tcp recv: closed"
               end) == nil

        assert Usage.fail_soft(:instances, %{value: nil, quota: nil}, fn ->
                 raise Postgrex.Error, message: "canceling statement due to statement timeout"
               end) == %{value: nil, quota: nil}
      end)

    assert log =~ "usage meter seats degraded"
    assert log =~ "usage meter instances degraded"
  end

  test "a programmer error RE-RAISES instead of returning the unmetered value" do
    assert_raise KeyError, fn ->
      Usage.fail_soft(:seats, nil, fn -> Map.fetch!(%{}, :members) end)
    end

    assert_raise Protocol.UndefinedError, fn ->
      Usage.fail_soft(:pending_invitations, nil, fn -> Enum.count(:not_a_list) end)
    end
  end

  test "the happy path is the function's own value" do
    assert Usage.fail_soft(:seats, nil, fn -> 3 end) == 3
  end

  test "a missing team is a nil clause, not a swallowed exception" do
    assert Usage.team_instances_meter(nil).value == "unmetered"
  end

  test "a malformed team through the public door now raises instead of reading unmetered" do
    assert_raise FunctionClauseError, fn -> Usage.team_instances_meter(%{not: :a_team}) end
  end
end
