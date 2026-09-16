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
          # NOT 1ms/1ms: that is aggressive enough to drop the HOLDER's own
          # checkout against an idle pool, and the starvation never begins.
          # 50/100 lets a free pool serve instantly while guaranteeing a drop
          # for anyone queued behind the multi-second hold below.
          queue_target: 50,
          queue_interval: 100,
          backoff_type: :stop
        )

      {:ok, pid} = Postgrex.start_link(opts)

      # HOLD the single connection INSIDE a transaction and wait for the holder
      # to CONFIRM it is checked out. A `Process.sleep` before the queued
      # callers is a race, not a hold: measured in CI, all four callers were
      # served by the same connection_id because the holder had not checked out
      # yet. The receive is what makes the starvation a FACT rather than a hope.
      test = self()

      # spawn, NOT Task.async: the holder is DELIBERATELY starved and its own
      # transaction dies with a queue-drop on the way out. A linked task would
      # take the test process down with it — an exit from the fixture, reported
      # as a failure of the thing under test.
      hog =
        spawn(fn ->
          Postgrex.transaction(
            pid,
            fn conn ->
              Postgrex.query!(conn, "SELECT 1", [])
              send(test, :held)

              receive do
                :release -> :ok
              after
                10_000 -> :timeout
              end
            end,
            timeout: 20_000
          )
        end)

      assert_receive :held, 10_000

      # Deliberately small: every agent shares this Postgres, and an 8-way burst
      # behind a 3s holder was measured reddening a sibling suite in the same run.
      #
      # The per-call timeout is GENEROUS on purpose: a short client timeout races
      # the pool and the CLIENT gives up first (reason: :error), which is the
      # other error entirely. Here the POOL is what gives up, so the struct under
      # test is the one `DBConnection.ConnectionPool.drop/2` builds in production.
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

      Process.exit(hog, :kill)
      GenServer.stop(pid, :normal, 5_000)

      assert match?(%DBConnection.ConnectionError{reason: :queue_timeout}, error),
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
