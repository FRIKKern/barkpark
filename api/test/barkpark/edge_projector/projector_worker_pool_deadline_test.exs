defmodule Barkpark.EdgeProjector.ProjectorWorkerPoolDeadlineTest do
  @moduledoc """
  REPRODUCES the guerrilla incident of 2026-07-30 — the journal line

      EdgeProjector.ProjectorWorker rebuild raised for scope=production,
      snoozing: tcp recv closed

  — and pins, WITH A RUN, which mechanism actually produces that string. It
  is not the one the row (or the desk analysis) names.

  ## The string, from the driver source

  `deps/postgrex/lib/postgrex/protocol.ex:3428-3436` formats a non-POSIX socket
  error as `"\#{mod} \#{action}: \#{reason}"`, so a read returning
  `{:error, :closed}` yields literally `tcp recv: closed`. `protocol.ex:840`
  recvs with `:infinity`: a client blocked on a slow query can be unblocked
  ONLY by the socket closing under it.

  ## What the checkout deadline alone does — and it is NOT that

  `deps/db_connection/lib/db_connection/connection_pool.ex:188-209` disconnects
  the connection at the checkout deadline (armed once at checkout,
  `holder.ex:318`; the measured span INCLUDES QUEUE TIME), logging
  `client … timed out because it queued and checked out the connection for
  longer than Nms` — the exact line `api/lib/barkpark/repo.ex:277-280` quotes
  from a LIVE log naming `Barkpark.EdgeProjector.ProjectorWorker` at 15000ms.

  But `Postgrex.Protocol.disconnect/2` (`protocol.ex:283-296`) does this, in
  this order, with the comment "cancel the request first":

      cancel_request(s)   # a NEW TCP connect to the peer, send CancelRequest,
                          # wait for the backend to ack (protocol.ex:3577-3601)
      terminate(s)
      sock_close(s)

  So when the cancel SUCCEEDS the backend cancels the statement and sends an
  ErrorResponse down the still-open socket; the blocked client reads a PACKET,
  not a close, and raises
  `%Postgrex.Error{postgres: %{code: :query_canceled}}` — the SAME exception a
  `statement_timeout` produces. `tcp recv: closed` is what the client gets only
  when the socket closes with NO error packet, i.e. when that cancel never
  lands.

  That is why the string is a SATURATION signature and not a slow-query
  signature: `cancel_request/3` opens a brand-new connection to Postgres
  (`protocol.ex:3582`), and on a box that is out of connections / swapping /
  refusing, that connect fails, the cancel is silently skipped ("we don't log
  when failing to cancel requests"), `sock_close/1` runs immediately, and the
  client — still in `:prim_inet.recv0/3` — gets `:closed`. The incident's
  conditions (a 10-connection pool saturated by a crash-looping rebuild, a
  2-vCPU box in swap) are exactly the conditions that break the cancel path.

  ## The arms

  All arms run on a DEDICATED REAL POOL, never the SQL sandbox:
  `workspace_bundle.ex:1880-1897` (PDS-D42) records why — "a pool timeout under
  the SQL sandbox arrives as an ownership-shutdown EXIT, not a rescuable
  raise". PDS-D42 is also the in-repo precedent for this exact string from a
  checkout deadline on a different caller (a live export died at 27.0s with
  `(DBConnection.ConnectionError) tcp recv: closed`).

    * ARM A — the incident. Checkout deadline 200 ms vs `pg_sleep(1)`, with the
      cancel path UNREACHABLE → `DBConnection.ConnectionError` /
      `tcp recv: closed`. The cancel is broken honestly, at the transport: the
      pool talks to Postgres through a loopback relay that forwards ordinary
      traffic and CLOSES any new connection whose first 8 bytes are the
      CancelRequest header `<<16::32, 80877102::32>>`. Nothing else is
      degraded — the pool's own connection and its reconnects still work — so
      the arm isolates the cancel and nothing else. That is a faithful model of
      "the box has no connection to spare", the incident's own condition. The
      arm asserts its own precondition (`{:cancel_dropped, _}`) rather than
      assuming it.
    * ARM A-CONTROL — the SAME rig with the cancel FORWARDED instead of dropped.
      The outcome is then a RACE between the backend's ErrorResponse
      (`:query_canceled`) and `sock_close/1`; BOTH were observed on this rig.
      That is the correction a desk reading misses: a checkout deadline does
      NOT deterministically produce `tcp recv: closed` on postgrex 0.22.3 — it
      produces it only when the cancel cannot land. Dropping the cancel is what
      turns a coin flip into a certainty, which is why the string is a
      SATURATION signature.
    * ARM B — `SET LOCAL statement_timeout` → `:query_canceled` on an OPEN
      socket, deterministically, and never the string. So `statement_timeout`
      cannot be the incident (it was also `0` on the box until #15005 /
      `7b16f025e`): a cancelled statement answers with a PACKET. The
      discriminator is the CLOSE, not the timeout.
    * ARM C — the actual code path. The worker's documented `"content"` seam
      runs arm A's query as its `collect_all_documents/3`, i.e. on
      `projector_worker.ex:248` — the PRE-TRANSACTION region that inherits
      Ecto's unconfigured 15,000 ms default (`config/runtime.exs` repo_opts
      sets url/pool_size/socket_options only; the rebuild TRANSACTION is NOT
      exposed, `projector.ex:188-203` sets an explicit `timeout: 60_000`).
      Asserts the journal payload: the rescue at `projector_worker.ex:284-291`
      logs `rebuild raised for scope=production, erroring` carrying
      `tcp recv: closed`, and returns `{:error, %DBConnection.ConnectionError{}}`.

  Cost: two `pg_sleep(1)`s and two `pg_sleep(0.5)`s, serially — the whole file
  runs in ~2.5 s. No load generator, no fan-out, `async: false`.

  ## POOL CONTENTION, before and after #8405 (c3)

  CHECKOUTS PER REBUILD ATTEMPT, counted off the call sites (each its own
  checkout at the 15 s default unless noted):

      collect_all_documents/3        up to max_pages = 50   PER TYPE
                                     (projector_worker.ex:248; the 50 bound at
                                     :495-500, page_size 1000 at :482-489)
      hydrate_edges_batch/1                             2   (tasks.ex, in
                                     `hydrate_edges_batch/1` — one task_edges query over every
                                     task PK + one Document id->doc_id map)
      bind_from_ids/3 -> typed_pks/3                    1   (projector.ex:345)
      rebuild_scope/3 transaction                       1   (projector.ex:188;
                                     EXPLICIT timeout: 60_000 — delete_outbound_for
                                     and Content.add_edges re-use this checkout)
      -------------------------------------------------------------
      TOTAL  ~= 50 * types + 4       = 54 for a single-type rebuild (UPPER
      bound: a corpus under page_size * max_pages walks fewer pages)

  AGAINST: `POOL_SIZE` 10 (`config/runtime.exs`, the `POOL_SIZE` repo `pool_size:`
  default and the sizing commentary above it), shared by 29 Oban
  queue slots and all HTTP traffic; `:edge_projector` runs concurrency 2.

    * BEFORE (#8405^ / `8d99e98ef^`: `projector_worker.ex` `@snooze_seconds
      60`, rescue returning `{:snooze, @snooze_seconds}`). Oban's `snooze_job`
      does `inc: [max_attempts: 1]`, exactly refunding fetch's
      `inc: [attempt: 1]`, so `max_attempts: 5` was decorative: a rebuild that
      can never finish re-armed every 60 s FOREVER. ~54 checkouts per minute
      per stuck scope, UNBOUNDED in total — and each failed attempt is itself a
      new chance for a saturated box to refuse the cancel connect and re-emit
      `tcp recv: closed`. That is the incident: `Tasks.Dedup` failing open and
      `POST /v1/data/mutate/production` 500ing behind a projector that would
      not stop asking.
    * AFTER (main: `projector_worker.ex:85` `max_attempts: 5` + the
      `{:error, e}` rescue at `:284-291`). The same poison rebuild costs at
      most 5 * 54 = 270 checkouts TOTAL, spread over Oban's default exponential
      backoff (~16/31/96/271 s, `oban/worker.ex:180-182`), then DISCARDED —
      permanently. Bounded, not merely slower: the integral over time goes from
      divergent to finite.

  The HONEST limit: the per-attempt figure is DERIVED from the call sites
  above, not measured under production load — telemetry inside these arms would
  count this test's own pool, not prod's. What is MEASURED here is the
  mechanism (arms A / A-CONTROL / B / C). Making the walk itself cheap is a
  separate row, `task-a1c9cced6456cbd0`; this file does not touch the
  collection strategy.
  """

  # async: false — these arms start real connection pools and sleep on them.
  use Barkpark.DataCase, async: false

  use Oban.Testing, repo: Barkpark.Repo

  import ExUnit.CaptureLog

  alias Barkpark.EdgeProjector.ProjectorWorker
  alias Barkpark.Repo

  @checkout_timeout_ms 200

  # The process-dictionary key arm C hands its pool to the content seam under.
  # The worker resolves the seam BY NAME (`content_mod/1`,
  # `projector_worker.ex:505-511`), so the seam cannot be a closure.
  @pool_key :projector_pool_deadline_pool

  # ── A loopback relay that DROPS CancelRequest connections ────────────────────
  #
  # Only purpose: model "the box has no connection to spare for the cancel".
  # `cancel_request/3` (`protocol.ex:3581-3601`) opens a BRAND-NEW connection to
  # the peer (postgrex state, `protocol.ex:774`) and sends a CancelRequest — a
  # 16-byte message whose header is `<<16::32, 80877102::32>>` (the 1234/5678
  # magic). The relay reads every new connection's first 8 bytes, forwards
  # ordinary startup traffic untouched, and CLOSES anything carrying that
  # header. Surgical: the pool's own connection and any reconnect still work,
  # so the only thing broken is the cancel — exactly the asymmetry a saturated
  # box produces, and nothing else.
  #
  # Each dropped cancel is reported to `owner`, so the arm can PROVE its own
  # precondition instead of assuming it.
  defmodule DeadCancelRelay do
    @moduledoc false

    @cancel_header <<16::32, 80_877_102::32>>

    @spec start(pid(), charlist(), :inet.port_number(), :drop | :forward) ::
            {:ok, :inet.port_number()}
    def start(owner, upstream_host, upstream_port, mode) when mode in [:drop, :forward] do
      {:ok, lsock} =
        :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

      {:ok, lport} = :inet.port(lsock)
      acceptor = spawn(fn -> accept_loop(lsock, owner, upstream_host, upstream_port, mode) end)
      :ok = :gen_tcp.controlling_process(lsock, acceptor)
      {:ok, lport}
    end

    defp accept_loop(lsock, owner, host, port, mode) do
      case :gen_tcp.accept(lsock) do
        {:ok, client} ->
          relay = spawn(fn -> await_and_relay(owner, host, port, mode) end)
          :ok = :gen_tcp.controlling_process(client, relay)
          send(relay, {:client, client})
          accept_loop(lsock, owner, host, port, mode)

        {:error, _closed} ->
          :ok
      end
    end

    defp await_and_relay(owner, host, port, mode) do
      receive do
        {:client, client} ->
          # Every Postgres frontend opening message is at least 8 bytes
          # (SSLRequest, StartupMessage, CancelRequest all carry a 4-byte
          # length + a 4-byte code), so peeking 8 is safe and complete.
          case :gen_tcp.recv(client, 8, 5_000) do
            {:ok, @cancel_header = head} when mode == :forward ->
              send(owner, {:cancel_forwarded, self()})
              forward(client, head, host, port)

            {:ok, @cancel_header} ->
              send(owner, {:cancel_dropped, self()})
              :gen_tcp.close(client)

            {:ok, head} ->
              forward(client, head, host, port)

            {:error, _} ->
              :gen_tcp.close(client)
          end
      after
        5_000 -> :ok
      end
    end

    defp forward(client, head, host, port) do
      case :gen_tcp.connect(host, port, [:binary, {:active, true}]) do
        {:ok, upstream} ->
          :ok = :gen_tcp.send(upstream, head)
          :ok = :inet.setopts(client, active: true)
          relay(client, upstream)

        {:error, _} ->
          :gen_tcp.close(client)
      end
    end

    defp relay(client, upstream) do
      receive do
        {:tcp, ^client, data} ->
          :gen_tcp.send(upstream, data)
          relay(client, upstream)

        {:tcp, ^upstream, data} ->
          :gen_tcp.send(client, data)
          relay(client, upstream)

        {:tcp_closed, _} ->
          close_both(client, upstream)

        {:tcp_error, _, _} ->
          close_both(client, upstream)
      end
    end

    defp close_both(a, b) do
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end
  end

  # ── The seam: a content module whose corpus walk IS arm A's query ────────────
  #
  # `run_rebuild_scoped/4` calls
  # `content_mod(args).collect_all_documents(type, scope, list_opts)` BEFORE the
  # rebuild transaction (`projector_worker.ex:248`). Running the deadline query
  # here puts the raise on exactly that line, and therefore on the rescue at
  # `:284-291`.
  defmodule FakeContentPoolDeadline do
    @moduledoc false

    def collect_all_documents(_type, _scope, _opts) do
      pool = Process.get(:projector_pool_deadline_pool)

      Barkpark.Repo.with_export_repo(pool, fn ->
        Barkpark.Repo.query!("SELECT pg_sleep(1)", [], timeout: 200)
      end)

      {[], nil}
    end
  end

  defmodule FakeProjectorUnreached do
    @moduledoc false
    def rebuild_scope(_scope, _docs, _opts),
      do: raise("the corpus walk must raise FIRST — the projector was reached")
  end

  # ── Pool helpers ─────────────────────────────────────────────────────────────

  # A real pool (pool: DBConnection.ConnectionPool, NEVER the sandbox) whose
  # cancel path is dead. Mirrors `Repo.start_export_pool/1` (`repo.ex:323-355`)
  # — unnamed, pid-as-handle — but routes through the relay so the peer can be
  # made unreachable.
  defp start_dead_cancel_pool, do: start_relayed_pool(:drop)

  # Same rig, cancel path HEALTHY — the arm that shows what the rig changes.
  defp start_live_cancel_pool, do: start_relayed_pool(:forward)

  defp start_relayed_pool(mode) do
    base = Repo.config()
    host = base |> Keyword.fetch!(:hostname) |> to_charlist()
    upstream_port = Keyword.get(base, :port, 5432)

    {:ok, relay_port} = DeadCancelRelay.start(self(), host, upstream_port, mode)

    {:ok, pid} =
      base
      |> Keyword.drop([:name, :pool, :pool_size, :pool_count, :socket_dir, :socket_options])
      |> Keyword.merge(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        hostname: "127.0.0.1",
        port: relay_port
      )
      |> Repo.start_link()

    # Force the single connection up THROUGH the relay before the listener goes
    # away — otherwise the pool has nothing to disconnect and the arm is vacuous.
    assert %Postgrex.Result{rows: [[1]]} =
             Repo.with_export_repo(pid, fn -> Repo.query!("SELECT 1") end)

    on_exit(fn -> Repo.stop_export_pool(pid) end)
    pid
  end

  # ── ARM A ────────────────────────────────────────────────────────────────────

  describe "ARM A — checkout deadline + unreachable cancel = 'tcp recv: closed'" do
    test "the client raises DBConnection.ConnectionError with the incident string" do
      pool = start_dead_cancel_pool()

      err =
        assert_raise DBConnection.ConnectionError, fn ->
          Repo.with_export_repo(pool, fn ->
            Repo.query!("SELECT pg_sleep(1)", [], timeout: @checkout_timeout_ms)
          end)
        end

      message = Exception.message(err)

      # The incident string, character for character. (The row quotes it without
      # the colon; postgrex emits it WITH one — `protocol.ex:3428-3436`.)
      assert message =~ "tcp recv: closed",
             "expected the socket-close message, got: #{inspect(message)}"

      # PRECONDITION, asserted rather than assumed: the disconnect really did
      # try to cancel, and the relay really did drop it. Without this the arm
      # could pass for some unrelated close and nobody would know.
      assert_received {:cancel_dropped, _}
    end
  end

  # ── ARM A-CONTROL ────────────────────────────────────────────────────────────

  describe "ARM A-CONTROL — the same deadline with a LIVE cancel path" do
    # WHAT THIS ARM ACTUALLY FOUND, and why it does not assert one outcome.
    #
    # `disconnect/2` runs `cancel_request` and then `sock_close`, and the client
    # is a DIFFERENT process blocked in `:prim_inet.recv0/3` on that socket. So
    # with a working cancel the two are RACING: the backend's ErrorResponse
    # (-> %Postgrex.Error{code: :query_canceled}) against the close
    # (-> tcp recv: closed). Both were observed on this rig at 200 ms vs
    # pg_sleep(1) and at 200 ms vs pg_sleep(0.5) — see the report; asserting
    # either one alone is a flake generator, and asserting a SPLIT would be
    # asserting the scheduler.
    #
    # The finding this arm carries is therefore the CONTRAST, not a single
    # verdict: with the cancel dropped (arm A) the string is CERTAIN; with the
    # cancel landing it is a coin flip. "Saturation makes an intermittent
    # signature deterministic" is precisely the incident's shape — intermittent
    # 500s, then a wall of them.
    test "the outcome is a RACE — the string is NOT the deterministic one" do
      pool = start_live_cancel_pool()

      err =
        assert_raise RuntimeError, fn ->
          try do
            Repo.with_export_repo(pool, fn ->
              Repo.query!("SELECT pg_sleep(0.5)", [], timeout: @checkout_timeout_ms)
            end)
          rescue
            e -> reraise RuntimeError.exception(Exception.message(e)), __STACKTRACE__
          end
        end

      message = Exception.message(err)

      assert message =~ "query_canceled" or message =~ "tcp recv: closed",
             "expected either race outcome, got: #{inspect(message)}"

      # PRECONDITION: the cancel really did reach Postgres on this arm — the
      # ONLY thing that differs from arm A.
      assert_received {:cancel_forwarded, _}
    end
  end

  # ── ARM B ────────────────────────────────────────────────────────────────────

  describe "ARM B — control: statement_timeout CANNOT produce that string" do
    test "SET LOCAL statement_timeout cancels the query on an OPEN socket" do
      pool = start_live_cancel_pool()

      # A cancelled statement aborts the surrounding transaction, so the inner
      # error is carried out through `Repo.rollback/1` — otherwise Ecto reports
      # only `{:error, :rollback}` and the exception (the thing under test)
      # is thrown away.
      result =
        Repo.with_export_repo(pool, fn ->
          Repo.transaction(
            fn ->
              Repo.query!("SET LOCAL statement_timeout = '#{@checkout_timeout_ms}ms'")

              case Repo.query("SELECT pg_sleep(0.5)") do
                {:error, e} -> Repo.rollback(e)
                {:ok, res} -> res
              end
            end,
            timeout: :infinity
          )
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}} = err} = result
      refute Exception.message(err) =~ "tcp recv: closed"

      # The socket was never closed on this arm: no disconnect, so no cancel
      # connection was ever opened.
      refute_received {:cancel_forwarded, _}
      refute_received {:cancel_dropped, _}
    end
  end

  # ── ARM C ────────────────────────────────────────────────────────────────────

  describe "ARM C — the rebuild's own rescue, carrying the incident payload" do
    test "a deadline-killed corpus walk lands on the rescue and ERRORS" do
      pool = start_dead_cancel_pool()

      Process.put(@pool_key, pool)
      on_exit(fn -> Process.delete(@pool_key) end)

      {result, log} =
        with_log(fn ->
          perform_job(ProjectorWorker, %{
            "op" => "rebuild",
            "scope" => "production",
            "types" => ["post"],
            "content" =>
              "Barkpark.EdgeProjector.ProjectorWorkerPoolDeadlineTest.FakeContentPoolDeadline",
            "projector" =>
              "Barkpark.EdgeProjector.ProjectorWorkerPoolDeadlineTest.FakeProjectorUnreached"
          })
        end)

      # The rescue at projector_worker.ex:284-291 — {:error, e}, NOT
      # {:snooze, _}. The journal's own word "snoozing" dates the box to
      # pre-#8405 code (`8d99e98ef`, 2026-08-02 — three days AFTER the
      # 2026-07-30 incident).
      assert {:error, %DBConnection.ConnectionError{} = err} = result
      assert Exception.message(err) =~ "tcp recv: closed"

      assert log =~ "rebuild raised for scope=production, erroring"
      assert log =~ "tcp recv: closed"

      # Same precondition control as arm A.
      assert_received {:cancel_dropped, _}
    end
  end
end
