defmodule Barkpark.Content.ErrorsPoolTimeoutTest do
  @moduledoc """
  task-61dbf8a21cd155d1: a database pool or queue timeout that comes back as a
  RETURNED error term answers the retryable 503 `storage_unavailable`, not 500
  `internal_error`. On a 2 vCPU test instance a `bp import` batch got the 500
  after 15 s and the import stopped, because the import client shrinks and
  resends a batch only on 503 `storage_unavailable`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.Errors

  @queue_drop DBConnection.ConnectionError.exception(
                "connection not available and request was dropped from queue after 2000ms",
                :queue_timeout
              )

  @checkout_deadline DBConnection.ConnectionError.exception(
                       "client #PID<0.4242.0> timed out because it queued and checked out " <>
                         "the connection for longer than 15000ms"
                     )

  defp envelope(term) do
    {env, _log} = with_log(fn -> Errors.to_envelope(term) end)
    env
  end

  test "a returned queue drop is 503 storage_unavailable with the connection_unavailable reason" do
    env = envelope({:error, @queue_drop})

    assert env.status == 503
    assert env.code == "storage_unavailable"
    assert env.reason == "connection_unavailable"
    assert env.hint =~ "CHECK WHETHER IT LANDED"
  end

  test "a returned checkout deadline, the 15 s pool timeout, is the same 503" do
    env = envelope({:error, @checkout_deadline})

    assert env.status == 503
    assert env.code == "storage_unavailable"
    assert env.reason == "connection_unavailable"
  end

  test "a pool timeout inside a tagged tuple is the same 503" do
    env = envelope({:error, {:batch_failed, @queue_drop}})

    assert env.status == 503
    assert env.code == "storage_unavailable"
  end

  test "the message never carries the exception text, which names a pid" do
    env = envelope({:error, @checkout_deadline})

    refute env.message =~ "PID"
    refute env.message =~ "15000ms"
    assert env.message =~ "pool timed out"
  end

  test "CONTROL: any other returned connection fault keeps the 500 catch-all" do
    closed = DBConnection.ConnectionError.exception("tcp recv: closed")

    log =
      capture_log(fn ->
        env = Errors.to_envelope({:error, closed})
        assert env.status == 500
        assert env.code == "internal_error"
      end)

    assert log =~ "no build/1 clause matched"
    refute Errors.pool_timeout?(closed)
  end

  test "pool_timeout?/1 names exactly the queue drop and the checkout deadline" do
    assert Errors.pool_timeout?(@queue_drop)
    assert Errors.pool_timeout?(@checkout_deadline)
    refute Errors.pool_timeout?(DBConnection.ConnectionError.exception("ssl recv: closed"))
    refute Errors.pool_timeout?(:queue_timeout)
  end
end
