defmodule BarkparkCloud.Push.FanoutResultTest do
  @moduledoc """
  `Push.record_insert_result/2` — the fan-out's per-job failure policy
  (`mob-bl-relay-build-notes`, advisory 2 of the PR #6097 review).

  Before this, `{:error, _}` from `Oban.insert/2` collapsed into the same
  silent `false` as a dedupe conflict. The consequence was invisible BY
  CONSTRUCTION: the receiver still answered 202 with a quietly undercounted
  `enqueued`, so a needs-you notification that was never enqueued left no trace
  in the response, the job table, or the log — the exact failure the relay
  exists to prevent.

  The policy is tested here rather than by forcing a real Oban insert failure:
  `Oban.insert/2` cannot be made to fail on demand inside an otherwise-real
  test, and a test that mocked Oban would be asserting on the mock. The fan-out
  calls THIS function with THAT verdict, so the seam is the honest place to
  prove it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.Push

  @context %{
    device_push_token_id: "dev-1",
    barkpark_id: "bp-1",
    session_id: "sess-42"
  }

  test "a NEW job counts as enqueued and says nothing" do
    log =
      capture_log(fn ->
        assert Push.record_insert_result({:ok, %Oban.Job{conflict?: false}}, @context)
      end)

    assert log == ""
  end

  test "a dedupe CONFLICT does not count and stays silent — a replay is expected" do
    log =
      capture_log(fn ->
        refute Push.record_insert_result({:ok, %Oban.Job{conflict?: true}}, @context)
      end)

    assert log == ""
  end

  test "an insert ERROR does not count, is LOUD, and names the device it lost" do
    log =
      capture_log(fn ->
        refute Push.record_insert_result({:error, :some_db_failure}, @context)
      end)

    assert log =~ "could not enqueue delivery"
    # Each id is load-bearing: without them a missing notification cannot be
    # traced back to the device that never got it.
    assert log =~ "device_push_token_id=dev-1"
    assert log =~ "barkpark_id=bp-1"
    assert log =~ "sess-42"
    assert log =~ "some_db_failure"
  end

  test "an error is non-fatal — a changeset reason logs instead of raising" do
    changeset = Ecto.Changeset.change(%Oban.Job{})

    log =
      capture_log(fn ->
        refute Push.record_insert_result({:error, changeset}, @context)
      end)

    assert log =~ "could not enqueue delivery"
  end
end
