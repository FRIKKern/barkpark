defmodule BarkparkCloud.Web.PoolOverloadTest do
  @moduledoc """
  `mob-lm-guerrilla-pool-storm`, cloud half — a control-plane request DROPPED
  FROM THE POOL QUEUE must not render as 500.

  THE ABSENCE THIS ROW WAS FILED AGAINST WAS MEASURED WITH A CONTROL, not read:
  `grep -rn "defimpl Plug.Exception" cloud/lib` answered with NOTHING on
  origin/main while the same grep over `api/lib` answered with four — so the
  cloud tree's silence was a real gap and not a grep that never matched
  anything.

  The first test does not construct its subject. It starts a real Postgrex pool
  of ONE against the control plane's own credentials, starves it, and asserts on
  the `DBConnection.ConnectionError` that the real `DBConnection.ConnectionPool`
  raises — which pins `reason: :queue_timeout` to this dep version rather than
  to a hand-written struct that agrees with the implementation by construction.

  The last test drives the ACTUAL `BarkparkCloud.Web.Router.handle_errors/2`
  through a real `Plug.ErrorHandler` pipeline, because the status mapping is
  only worth anything if the door in front of it consults `Plug.Exception` —
  and because the console's copy depends on the BODY staying `server_error`.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  ## ── the probe pipeline: the real handle_errors/2, behind a real ErrorHandler ──

  defmodule ProbeRouter do
    @moduledoc false
    use Plug.Router
    use Plug.ErrorHandler

    plug(:match)
    plug(:dispatch)

    get "/queue-drop" do
      _ = conn

      raise DBConnection.ConnectionError.exception(
              "connection not available and request was dropped from queue after 2500ms",
              :queue_timeout
            )
    end

    get "/socket-fault" do
      _ = conn
      raise DBConnection.ConnectionError.exception("tcp recv: closed")
    end

    # The whole point: the envelope under test is the CONTROL PLANE's, not a
    # copy written to agree with the assertion.
    defdelegate handle_errors(conn, error), to: BarkparkCloud.Web.Router
  end

  @probe_opts ProbeRouter.init([])

  # `Plug.ErrorHandler` responds and then RE-RAISES so the server still logs the
  # crash, so the conn never comes back from `call/2`. A `register_before_send`
  # installed BEFORE the call survives into `handle_errors/2` — same conn — and
  # forwards the fully-populated response out. NO callback firing means nothing
  # was ever sent, which is a distinct failure from "sent the wrong status".
  defp drive(path) do
    test = self()

    conn =
      Plug.Test.conn(:get, path)
      |> register_before_send(fn sent ->
        send(test, {:sent, sent.status, sent.resp_body, get_resp_header(sent, "content-type")})
        sent
      end)

    try do
      ProbeRouter.call(conn, @probe_opts)
    rescue
      _ -> :reraised
    end

    receive do
      {:sent, status, body, ctype} -> {status, Jason.decode!(body), ctype}
    after
      0 -> :no_response
    end
  end

  describe "a REAL pool drop (no constructed struct)" do
    @tag :slow
    test "the pool's own queue-drop error is :queue_timeout and renders 503" do
      opts =
        BarkparkCloud.Repo.config()
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
          # NOT 1ms/1ms: that drops the HOLDER's own checkout against an idle
          # pool and the starvation never begins. 50/100 serves a free pool
          # instantly while guaranteeing a drop behind a multi-second hold.
          queue_target: 50,
          queue_interval: 100,
          backoff_type: :stop
        )

      {:ok, pid} = Postgrex.start_link(opts)

      test = self()

      # spawn, NOT Task.async: the holder is deliberately starved and its own
      # transaction dies on the way out; a linked task would take the test
      # process down with it and report a fixture exit as a failure of the
      # thing under test.
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

      # The receive is what makes the starvation a FACT rather than a hope: a
      # `Process.sleep` before the queued callers is a race.
      assert_receive :held, 10_000

      # Deliberately small — every agent on this box shares one Postgres, and a
      # wide burst behind a multi-second holder reddens sibling suites. The
      # per-call timeout is GENEROUS on purpose: a short client timeout races
      # the pool and the CLIENT gives up first (`reason: :error`), which is the
      # other error entirely. Here the POOL is what gives up.
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

      assert BarkparkCloud.Web.PoolOverload.status(error) == 503
      assert Plug.Exception.status(error) == 503
    end

    test "CONTROL — every OTHER connection fault stays 500" do
      error = DBConnection.ConnectionError.exception("tcp recv: closed")

      assert error.reason == :error
      assert BarkparkCloud.Web.PoolOverload.status(error) == 500
      assert Plug.Exception.status(error) == 500
    end
  end

  describe "the control plane's own crash envelope" do
    test "a queue drop leaves the door as 503 with the UNCHANGED flat envelope" do
      assert {status, body, ctype} = drive("/queue-drop")

      assert status == 503,
             "Plug.ErrorHandler must carry the Plug.Exception status through to the door"

      assert body["error"] == "server_error",
             "the console SPA's friendly() map keys on this slug — it must not move"

      assert is_binary(body["request_id"])
      assert Enum.any?(ctype, &String.contains?(&1, "application/json"))
    end

    test "CONTROL — a socket fault still leaves the door as 500, same envelope" do
      assert {status, body, ctype} = drive("/socket-fault")

      assert status == 500
      assert body["error"] == "server_error"
      assert is_binary(body["request_id"])
      assert Enum.any?(ctype, &String.contains?(&1, "application/json"))
    end
  end
end
