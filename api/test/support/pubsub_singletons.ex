defmodule Barkpark.PubSubSingletons do
  @moduledoc """
  THE THIRD SANDBOX HAZARD SHAPE: a long-lived, boot-time, PubSub-subscribed
  singleton that reaches `Repo`.

  `DataCase.drain_owned_tasks/3` covers the FIRST shape — fire-and-forget work on
  the two global `Task.Supervisor`s, matched via `$callers`. A singleton is
  structurally invisible to it: it is not a `Task`, it is not rooted at the test
  pid, and its `$callers` never contains one. So when a test broadcasts on a
  topic such a singleton subscribes to, the singleton picks up the SHARED-mode
  sandbox connection implicitly, and when the test's `on_exit` stops the owner
  while that read is in flight the connection dies mid-query:

      Client #PID<0.390.0> (Barkpark.Quiz.Bridge) is still using a connection
      from owner

  The pool has no slack (`pool_size == max concurrent tests`), so every killed
  connection starves whichever test is checking out during the reconnect window.
  CI run 29710726459 ended `27 doctests, 11957 tests, 1310 failures` from exactly
  this, first disconnect naming `Quiz.Content.load_question/2 <- bridge.ex:113
  apply_now/3 <- bridge.ex:73 handle_info/2`.

  ## The barrier, and why `:sys.get_state/2` is the right instrument

  `drain!/1` does NOT need the singleton to cooperate, and deliberately adds no
  `:ping` callback to production code. `:sys.get_state/2` is an OTP *system*
  message, and `gen_server` processes system messages in **mailbox order** like
  any other. A local `Phoenix.PubSub.broadcast` delivers to local subscribers by
  a direct `send/2` before it returns, so by the time the test body finishes, the
  `{:document_changed, …}` message is ALREADY in the singleton's mailbox. A
  `:sys.get_state/2` issued after it therefore cannot be answered until that
  message — and the Ecto read inside it — has been fully processed.

  That is the whole contract: **when the owner stops, no singleton is mid-query
  on its connection.** It is the same doctrine `drain_owned_tasks/3` applies to
  tasks, extended to the shape tasks cannot express.

  ## The registry is set-equality-checked, not advisory

  `pubsub_singleton_census_test.exs` derives the CLASS from source — every module
  under `api/lib` that is a `GenServer` (not a LiveView, Channel, or Controller —
  those are per-connection processes the test owns) AND calls
  `Phoenix.PubSub.subscribe/2` — and asserts that class is exactly
  `drained() ++ no_repo()`. A new boot-time PubSub singleton that nobody
  classified REDS. That is what stops this file from rotting into a comment.
  """

  require Logger

  @drain_timeout_ms 5_000

  # THE DRAINED LIST. Singletons that reach `Repo` and therefore MUST be quiesced
  # before the sandbox owner stops. Each entry names why it is in this list.
  #
  # Barkpark.Quiz.Bridge — subscribes to `documents:<dataset>` and, on a `quiz`
  # document change, calls `Quiz.load_question/2` (a real Ecto read) for every
  # bound pin, synchronously inside `handle_info/2`. This is the module the
  # 1,310-failure cascade named.
  # Barkpark.StudioChat.Recorder — subscribes to `documents:<task dataset>` (the
  # ledger stream, tlv-bl-chat-live-transition-stream) and reaches `Repo` all
  # over its own `handle_info/2`: `StudioChat.update_status/2`,
  # `attach_tool_result/3`, `mark_exited/1`, `ChatHosts.live_report_fence/1`.
  # The transition projection it subscribed FOR is pure, but the class is about
  # the PROCESS, not one callback — any message already in that mailbox can be
  # mid-read when the owner stops, which is the whole hazard.
  @drained [Barkpark.Quiz.Bridge, Barkpark.StudioChat.Recorder]

  # THE LOCATOR, and why it is not optional. `drain!/1` has to FIND a member's
  # process, and `Process.whereis/1` answers only for a module-NAMED one. A
  # member started under a `{:via, Registry, …}` name is structurally invisible
  # to it: `whereis` returns nil, `quiesce/2` takes the "not running" arm, and
  # the barrier degenerates into a silent no-op — strictly worse than leaving
  # the module off the list, because the registry then READS as covered while
  # covering nothing. So every Registry-named member names its registry here,
  # and the census asserts the mapping exists for each one.
  #
  # Barkpark.StudioChat.Recorder is not a singleton in the literal sense — one
  # runs per LIVE chat session under `RecorderRegistry` — but it is the same
  # sandbox shape (a `GenServer` on a broadcast topic, unreachable through
  # `$callers`), so every live one is drained, not just a first.
  @registries %{Barkpark.StudioChat.Recorder => Barkpark.StudioChat.RecorderRegistry}

  # THE NO-REPO LIST. Singletons in the same class that are safe WITHOUT a barrier
  # because they never reach `Repo`. Listed — not omitted — so that a future edit
  # which gives one of them a database read is a deliberate move of a name between
  # two lists, and so the census can assert the class is fully accounted for.
  #
  # Barkpark.StudioChat.FleetHub — started by `StudioChat.Supervisor` and
  # subscribed to `Recorder.activity_topic()`, so it IS in this class. Its
  # handlers fold in-memory frames only; `studio_chat.ex` states the constraint
  # in as many words: the fleet wire "can never run a per-flip DB query". The
  # census asserts that claim against the module's own source rather than
  # trusting this comment.
  @no_repo [Barkpark.StudioChat.FleetHub]

  @doc "Singletons that reach `Repo`; `drain!/1` quiesces exactly these."
  @spec drained() :: [module()]
  def drained, do: @drained

  @doc "Singletons in the class that never reach `Repo`, so need no barrier."
  @spec no_repo() :: [module()]
  def no_repo, do: @no_repo

  @spec all() :: [module()]
  def all, do: @drained ++ @no_repo

  @doc """
  The `Registry` a member is named under, or `nil` when it is registered by
  module name and `Process.whereis/1` is enough to find it.

  Public so the census can assert the barrier can actually reach every
  `drained/0` member, rather than trusting that it can.
  """
  @spec registry_of(module()) :: module() | nil
  def registry_of(module), do: Map.get(@registries, module)

  @doc """
  Quiesce every `drained/0` singleton: block until it has processed everything
  already in its mailbox, so a subsequent `Sandbox.stop_owner/1` cannot kill an
  in-flight query.

  Never raises. A singleton that is not running (plugin disabled, app partly
  started) is skipped. One still alive past `@drain_timeout_ms` is logged and
  RETRIED, not abandoned — see `await_quiesced/3` for why a fixed wall-clock
  ceiling is the wrong gate for "has this live process been scheduled yet."
  Only a genuinely dead/hung singleton (caught by `@drain_deadlock_guard_ms`,
  four times the warning threshold, but still comfortably under
  ExUnit's own default per-test timeout) gives up, because a test's
  `on_exit` hanging forever is strictly worse than the disconnect this barrier
  exists to prevent — the ORIGINAL failure mode `@drain_timeout_ms` guarded
  against, which a liveness check now catches directly instead.
  """
  @spec drain!(timeout()) :: :ok
  def drain!(timeout \\ @drain_timeout_ms) do
    Enum.each(@drained, &quiesce(&1, timeout))
  end

  # A deadlock circuit-breaker for genuinely-stuck work (e.g. a Postgres
  # statement that never returns), which this repo's own Postgrex config
  # gives no smaller bound to catch first — NOT a "give the race more room"
  # number (that was tried and rejected — see the moduledoc note above).
  # Measured (2026-08-23, 8 concurrent `yes` stressors on an already
  # oversubscribed box): a value here at ExUnit's own default 60_000ms test
  # timeout collides with it when `drain!/1` runs inside a test body (as
  # `bridge_sandbox_cascade_test.exs` does directly, to capture the barrier's
  # log) — ExUnit kills the whole test before this guard gets to log its own,
  # more specific warning. Kept comfortably under that ceiling so a genuine
  # deadlock is caught by NAME rather than surfacing as an opaque
  # `ExUnit.TimeoutError` with no indication which singleton stalled.
  @drain_deadlock_guard_ms 20_000

  defp quiesce(module, timeout) do
    Enum.each(live_pids(module), fn pid ->
      deadline = System.monotonic_time(:millisecond) + timeout
      guard_deadline = System.monotonic_time(:millisecond) + @drain_deadlock_guard_ms
      await_quiesced(module, pid, deadline, guard_deadline, false)
    end)
  end

  # A member is either module-named (at most one process) or Registry-named (N,
  # one per live key). Nothing running is `[]` either way, so a disabled plugin
  # or a partly-started app still skips silently — the behaviour `whereis/1`
  # returning nil used to give.
  defp live_pids(module) do
    case registry_of(module) do
      nil -> module |> Process.whereis() |> List.wrap()
      registry -> registry_pids(registry)
    end
  end

  # `Registry.select/2` raises when the registry itself is not started, which is
  # the Registry-named equivalent of `whereis/1` returning nil — not an error.
  defp registry_pids(registry) do
    Registry.select(registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  # `:sys.get_state/2` is the barrier, NOT a state read — the return value is
  # deliberately discarded. A SINGLE long wait races the barrier against the
  # scheduler: under enough concurrent load (measured: 8 concurrent `yes`
  # busy-loops on top of an already-oversubscribed box) the singleton is
  # ALIVE and WILL answer, but the scheduler had simply not reached it inside
  # one arbitrary window — that is a scheduling delay, not evidence the
  # singleton is stuck, and no fixed number is safe against unbounded
  # contention (the same lesson the 20,001-entry cap test taught: the fix was
  # removing the expensive work, not raising its budget — reproduced here as
  # removing the wall-clock gate, not raising it).
  #
  # So retry on a SHORT per-attempt window, bounded by the singleton's own
  # liveness rather than by a bigger clock: a process still alive keeps
  # getting another short attempt (correctness holds as long as OTP's fair
  # scheduler eventually runs it — it always does); a dead one stops on the
  # next attempt via `Process.alive?/1`, immediately, not after the whole
  # window elapses. `@drain_timeout_ms` still gates exactly one thing: the ONE
  # warning log emitted the first time the deadline is crossed, so a loaded
  # run is still observable without being abandoned for it.
  @drain_poll_ms 200

  defp await_quiesced(module, pid, deadline, guard_deadline, warned?) do
    _ = :sys.get_state(pid, @drain_poll_ms)
    :ok
  catch
    :exit, {:timeout, _} ->
      now = System.monotonic_time(:millisecond)

      cond do
        not Process.alive?(pid) ->
          :ok

        now > guard_deadline ->
          Logger.warning(
            "PubSubSingletons.drain!: #{inspect(module)} did not quiesce within " <>
              "the #{@drain_deadlock_guard_ms}ms deadlock guard; the sandbox owner " <>
              "is about to stop and an in-flight query on it may disconnect."
          )

          :ok

        true ->
          warned? = warned? or maybe_warn(module, pid, now, deadline)
          await_quiesced(module, pid, deadline, guard_deadline, warned?)
      end

    # ALREADY GONE when we asked — `:sys.get_state/2` on a dead pid. For a
    # Registry-named member this is routine, not a hazard: `Registry.select/2`
    # returns a snapshot, and an ephemeral member (the Recorder is
    # `restart: :temporary` and reaps itself on idle) can exit inside the
    # window before the system message lands. A process that is gone holds no
    # in-flight query, so this is the SAME non-event as `Process.whereis/1`
    # returning nil for a module-named member — which `live_pids/1` already
    # treats as `[]`, silently. Warning here would fire on every chat test and
    # bury the one exit this warning exists to surface.
    :exit, {:noproc, _} ->
      :ok

    :exit, reason ->
      Logger.warning(
        "PubSubSingletons.drain!: #{inspect(module)} exited while quiescing " <>
          "(#{inspect(reason)}); the sandbox owner is about to stop and an " <>
          "in-flight query on it may disconnect."
      )

      :ok
  end

  # Logs once, the moment the original deadline is crossed, so a loaded run
  # is still observable in CI output — but returns `true` rather than giving
  # up, so the caller keeps retrying instead of abandoning the wait.
  defp maybe_warn(_module, _pid, now, deadline) when now <= deadline, do: false

  defp maybe_warn(module, _pid, _now, _deadline) do
    Logger.warning(
      "PubSubSingletons.drain!: #{inspect(module)} still quiescing past " <>
        "#{@drain_timeout_ms}ms under load; retrying (bounded by liveness, " <>
        "not by a bigger clock) rather than stopping the owner underneath it."
    )

    true
  end
end
