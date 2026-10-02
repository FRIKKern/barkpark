defmodule Barkpark.Content.DeferredWebhookFlushIsolationTest do
  @moduledoc """
  One queued webhook whose in-process dispatch work raises must not take the
  rest of the committed transaction's webhooks with it, and must not raise out
  of `flush_deferred_broadcasts/0` onto a write that already committed.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content.Broadcast

  setup do
    me = self()
    ids = for n <- ["sel", "err"], do: "flush-iso-#{n}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      Enum.at(ids, 0),
      [:barkpark, :webhooks, :fan_out, :selected],
      fn _e, _m, meta, _ -> send(me, {:fan_out, meta.doc_id}) end,
      nil
    )

    :telemetry.attach(
      Enum.at(ids, 1),
      [:barkpark, :webhooks, :flush, :error],
      fn _e, _m, meta, _ -> send(me, {:flush_error, meta.doc_id}) end,
      nil
    )

    on_exit(fn -> Enum.each(ids, &:telemetry.detach/1) end)
    :ok
  end

  test "a raising item is logged and counted; the items after it still dispatch" do
    # A PID in the document cannot be JSON-encoded: dispatch_async raises while
    # building the payload, in THIS process.
    poison = {"production", "update", "post", "poison-doc", %{"bad" => self()}, 1, []}
    healthy = {"production", "update", "post", "healthy-doc", %{"_id" => "healthy-doc"}, 2, []}

    # Queue is newest-first; flush reverses it, so poison runs FIRST.
    Process.put(:barkpark_deferred_webhooks, [healthy, poison])

    log = capture_log(fn -> assert :ok == Broadcast.flush_deferred_broadcasts() end)

    assert_receive {:flush_error, "poison-doc"}
    assert_receive {:fan_out, "healthy-doc"}
    assert log =~ "deferred dispatch FAILED"
    assert Process.get(:barkpark_deferred_webhooks) == nil
  end
end
