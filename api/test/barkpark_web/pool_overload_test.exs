defmodule BarkparkWeb.PoolOverloadTest do
  @moduledoc """
  `mob-lm-guerrilla-pool-storm` — a request DROPPED FROM THE POOL QUEUE must not
  render as 500.

  The first test does not construct its subject: it starts a real Postgrex pool
  of ONE, starves it, and asserts on the `DBConnection.ConnectionError` the real
  `DBConnection.ConnectionPool` raises. That is what pins `reason: :queue_timeout`
  to this dep version rather than to a hand-written struct that agrees with the
  implementation by construction.
  """
  use ExUnit.Case, async: false

  describe "a REAL pool drop (no constructed struct)" do
    test "the pool's own queue-drop error is :queue_timeout and renders 503" do
      opts =
        Barkpark.Repo.config()
        |> Keyword.take([
          :hostname,
          :username,
          :password,
          :database,
          :port,
          :socket_dir,
          :socket_options
        ])
        |> Keyword.merge(
          pool_size: 1,
          queue_target: 1,
          queue_interval: 1,
          backoff_type: :stop
        )

      {:ok, pid} = Postgrex.start_link(opts)

      # A pool of ONE, held for 300ms, with four callers queued behind it and a
      # GENEROUS per-call timeout. The generosity is the point: a short client
      # timeout races the pool and the CLIENT gives up first (reason: :error),
      # which is the other error entirely. Here the POOL is what gives up, so
      # the struct under test is the one `DBConnection.ConnectionPool.drop/2`
      # actually builds in production.
      #
      # Deliberately small: every agent shares this Postgres, and an 8-way burst
      # behind a 3s holder was measured reddening a sibling suite in the same run.
      hog =
        Task.async(fn -> Postgrex.query(pid, "SELECT pg_sleep(0.3)", [], timeout: 10_000) end)

      Process.sleep(50)

      results =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn ->
            try do
              Postgrex.query(pid, "SELECT 1", [], timeout: 5_000)
            catch
              :exit, reason -> {:exit, reason}
            end
          end)
        end)
        |> Task.await_many(15_000)

      error =
        Enum.find_value(results, fn
          {:error, %DBConnection.ConnectionError{reason: :queue_timeout} = e} -> e
          _ -> nil
        end)

      Task.shutdown(hog, :brutal_kill)
      GenServer.stop(pid, :normal, 5_000)

      assert %DBConnection.ConnectionError{reason: :queue_timeout} = error,
             "expected the pool to DROP a queued caller, got: #{inspect(results)}"

      assert error.message =~ "connection not available and request was dropped from queue"

      assert Plug.Exception.status(error) == 503,
             "a request that never reached Postgres must shed as 503, not #{Plug.Exception.status(error)}"
    end
  end

  describe "status mapping" do
    test "a queue drop is 503 Service Unavailable" do
      error =
        DBConnection.ConnectionError.exception(
          "connection not available and request was dropped from queue after 2500ms",
          :queue_timeout
        )

      assert BarkparkWeb.PoolOverload.status(error) == 503
      assert Plug.Exception.status(error) == 503
    end

    test "CONTROL — every OTHER connection fault stays 500" do
      error = DBConnection.ConnectionError.exception("tcp recv: closed")

      assert error.reason == :error
      assert BarkparkWeb.PoolOverload.status(error) == 500
      assert Plug.Exception.status(error) == 500
    end
  end

  describe "the body contract survives the new status" do
    test "a 503 still renders code=internal_error with the fault family" do
      error =
        DBConnection.ConnectionError.exception(
          "connection not available and request was dropped from queue after 2500ms",
          :queue_timeout
        )

      %{error: rendered} =
        BarkparkWeb.ErrorJSON.render("503.json", %{kind: :error, reason: error})

      assert rendered.code == "internal_error",
             "the cloud deploy poller's retry grace keys on this code — it must not move"

      assert rendered.message =~ "DBConnection.ConnectionError"
    end
  end
end
