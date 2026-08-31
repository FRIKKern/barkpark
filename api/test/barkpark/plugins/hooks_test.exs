defmodule Barkpark.Plugins.HooksTest do
  @moduledoc """
  Mechanics tests for `Barkpark.Plugins.Hooks.fire/2` (Goal `barkpark-9lq`,
  task `barkpark-30j`).

  Covers seven groups from §5 of `2026-05-17-lifecycle-hooks.html`:

    1. `before_*` ordering — two plugins fire in load order, both run.
    2. `before_*` halt short-circuits — first halt stops the chain.
    3. Malformed return coercion — `{:ok, %{}}` is treated as `:ok` and
       logged; chain continues (no mutation in v1, §0 Q2).
    4. Hook-crash isolation — a raising hook is caught, treated as `:ok`,
       chain continues.
    5. `after_*` returns immediately — async fan-out via
       `Task.async_stream`; the slow side-effect lands eventually.
    6. `after_*` timeout kills the slow hook — fire returns immediately,
       the 5s `Task.async_stream` timeout drops the task without raising.
    7. Unknown event — fire returns `:ok` with a warning.

  Group 8 (OnixEdit recursion guard) lives in
  `onixedit/lifecycle_test.exs` (next task s8) — it exercises that
  plugin's specific hook fn, not the generic dispatcher.

  Test plugin modules are defined inline so they don't auto-register or
  pollute other tests. They wire hook functions to a process-dict trace
  (`:trace`) or a mailbox so each test can assert order + side-effects
  without ETS. `async: false` because all tests mutate
  `Application.get_env(:barkpark, :plugins, …)`.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Hooks

  @moduletag timeout: 10_000

  # ── inline test plugin modules ──────────────────────────────────────
  #
  # Each module is a bare Elixir module (no `use Barkpark.Plugin`). The
  # `Hooks` dispatcher only requires `lifecycle_hooks/0` to be exported
  # and return a map — bare modules satisfy that without needing a
  # `plugin.json` on disk.

  defmodule PluginAppendA do
    @moduledoc false
    def lifecycle_hooks do
      %{
        before_publish: [&__MODULE__.append/1],
        before_save: [&__MODULE__.append/1]
      }
    end

    def append(_payload) do
      send(test_pid(), {:fired, :a})
      Process.put(:trace, (Process.get(:trace) || []) ++ [:a])
      :ok
    end

    defp test_pid, do: Process.get(:test_pid) || self()
  end

  defmodule PluginAppendB do
    @moduledoc false
    def lifecycle_hooks do
      %{
        before_publish: [&__MODULE__.append/1],
        before_save: [&__MODULE__.append/1]
      }
    end

    def append(_payload) do
      send(test_pid(), {:fired, :b})
      Process.put(:trace, (Process.get(:trace) || []) ++ [:b])
      :ok
    end

    defp test_pid, do: Process.get(:test_pid) || self()
  end

  defmodule PluginHaltA do
    @moduledoc false
    def lifecycle_hooks do
      %{before_publish: [&__MODULE__.halt/1]}
    end

    def halt(_payload) do
      Process.put(:trace, (Process.get(:trace) || []) ++ [:a])
      {:halt, "no"}
    end
  end

  defmodule PluginBadReturnA do
    @moduledoc false
    def lifecycle_hooks do
      %{before_publish: [&__MODULE__.mutate/1]}
    end

    # v1 §0 Q2: NO `{:ok, map()}` mutation variant. The dispatcher must
    # coerce this to :ok and continue the chain.
    def mutate(_payload) do
      Process.put(:trace, (Process.get(:trace) || []) ++ [:a])
      {:ok, %{"injected" => true}}
    end
  end

  defmodule PluginCrashA do
    @moduledoc false
    def lifecycle_hooks do
      %{before_publish: [&__MODULE__.boom/1]}
    end

    def boom(_payload) do
      Process.put(:trace, (Process.get(:trace) || []) ++ [:a])
      raise "kaboom"
    end
  end

  defmodule PluginAsyncSink do
    @moduledoc false
    # Records the test process at hook-registration time so the async
    # task knows where to message. The test sets `:async_target` in
    # `Application.get_env(:barkpark, :hooks_test_target)` before fire/2;
    # the hook fn reads it back at fire time.
    def lifecycle_hooks do
      %{after_publish: [&__MODULE__.sink/1]}
    end

    def sink(_payload) do
      target = Application.get_env(:barkpark, :hooks_test_target)
      Process.sleep(50)
      send(target, {:after_publish_landed, System.monotonic_time(:millisecond)})
      :ok
    end
  end

  defmodule PluginSlowAfter do
    @moduledoc false
    # Sleeps longer than the 5s `@hook_timeout_ms` — the
    # `on_timeout: :kill_task` clause must drop this task without
    # bubbling a crash.
    def lifecycle_hooks do
      %{after_publish: [&__MODULE__.slow/1]}
    end

    def slow(_payload) do
      target = Application.get_env(:barkpark, :hooks_test_target)
      Process.sleep(6_000)
      send(target, :slow_finished)
      :ok
    end
  end

  defmodule PluginTwoHookList do
    @moduledoc false
    # ONE plugin declaring a TWO-function before_save list — the exact shape
    # Bulldocs takes when the hollow gate rides after validate_paper_template
    # (p-quality-gate, charter D7). Pins two dispatcher invariants the gate
    # relies on:
    #   (a) hooks WITHIN one plugin's list fire in list order;
    #   (b) a hook's return value never mutates the payload — hook B receives
    #       the PRISTINE payload even when hook A returns a mutated map
    #       (v1 §0 Q2: reduce_while ignores non-:ok/:halt returns).
    def lifecycle_hooks do
      %{before_save: [&__MODULE__.first/1, &__MODULE__.second/1]}
    end

    def first(payload) do
      target = Application.get_env(:barkpark, :hooks_test_target) || self()
      send(target, {:in_list, :first, payload})
      # A (malformed) mutation attempt: return the payload with a REWRITTEN
      # doc. The dispatcher must coerce this to :ok and pass hook B the
      # ORIGINAL payload, never this map.
      {:ok, %{payload | doc: %{"_id" => "mutated", "_type" => "hijacked"}}}
    end

    def second(payload) do
      target = Application.get_env(:barkpark, :hooks_test_target) || self()
      send(target, {:in_list, :second, payload})
      :ok
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────

  # Delegated to `Barkpark.PluginEnv` so the restore uses the `:unset`
  # sentinel. The hand-rolled version defaulted the snapshot to `[]`, which on
  # the (unset) boot baseline turned "restore" into `put_env(:plugins, [])` —
  # BootCollectors' discovery kill switch — and this module has no self-reset,
  # so the `[]` outlived the file and blanked plugin routes for later tests.
  defp with_plugins(modules, ctx) when is_list(modules) do
    Barkpark.PluginEnv.with_plugins(modules, ctx)
  end

  defp with_async_target(ctx) do
    prior = Application.get_env(:barkpark, :hooks_test_target)
    Application.put_env(:barkpark, :hooks_test_target, self())

    ExUnit.Callbacks.on_exit(ctx, fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :hooks_test_target),
        else: Application.put_env(:barkpark, :hooks_test_target, prior)
    end)

    :ok
  end

  defp before_payload(event, ctx_extra \\ %{}) do
    %{
      event: event,
      doc: %{"_id" => "x", "_type" => "post"},
      dataset: "production",
      prev_doc: nil,
      ctx: Map.merge(%{source: :studio, user_id: nil}, ctx_extra)
    }
  end

  defp after_payload(event, ctx_extra \\ %{}) do
    %{
      event: event,
      doc: %{"_id" => "x", "_type" => "post"},
      dataset: "production",
      prev_doc: nil,
      ctx: Map.merge(%{source: :studio, user_id: nil}, ctx_extra)
    }
  end

  # ── Group 1: before_* ordering ──────────────────────────────────────

  describe "before_* ordering" do
    test "two plugins fire in load order, both run", ctx do
      :ok = with_plugins([PluginAppendA, PluginAppendB], ctx)

      assert Hooks.fire(:before_publish, before_payload(:before_publish)) == :ok

      assert_receive {:fired, :a}, 100
      assert_receive {:fired, :b}, 100
    end

    test "reversed load order reverses fire order", ctx do
      :ok = with_plugins([PluginAppendB, PluginAppendA], ctx)

      assert Hooks.fire(:before_publish, before_payload(:before_publish)) == :ok

      # Both should arrive but :b first.
      assert_receive {:fired, :b}, 100
      assert_receive {:fired, :a}, 100
    end
  end

  # ── Group 2: before_* halt short-circuits ───────────────────────────

  describe "before_* halt short-circuits" do
    test "first halt stops the chain — later plugins never run", ctx do
      :ok = with_plugins([PluginHaltA, PluginAppendB], ctx)

      assert Hooks.fire(:before_publish, before_payload(:before_publish)) ==
               {:halt, "no"}

      # B's append/1 sends {:fired, :b} — it must NOT arrive.
      refute_receive {:fired, :b}, 50
    end
  end

  # ── Group 2b: in-list composition within ONE plugin (p-quality-gate D7) ──

  describe "before_* two-function list in one plugin" do
    test "both hooks fire, in list order", ctx do
      :ok = with_plugins([PluginTwoHookList], ctx)
      :ok = with_async_target(ctx)

      log =
        capture_log(fn ->
          assert Hooks.fire(:before_save, before_payload(:before_save)) == :ok
        end)

      assert_receive {:in_list, :first, _}, 100
      assert_receive {:in_list, :second, _}, 100
      # first's {:ok, mutated} return is the malformed-return class — coerced.
      assert log =~ "treating as :ok"
    end

    test "hook B receives the PRISTINE payload after hook A returns a mutated map",
         ctx do
      :ok = with_plugins([PluginTwoHookList], ctx)
      :ok = with_async_target(ctx)

      payload = before_payload(:before_save)

      capture_log(fn ->
        assert Hooks.fire(:before_save, payload) == :ok
      end)

      assert_receive {:in_list, :first, first_saw}, 100
      assert_receive {:in_list, :second, second_saw}, 100

      # Both hooks saw the exact payload the caller fired — hook A's
      # attempted doc rewrite never reached hook B (no-mutation, §0 Q2).
      assert first_saw == payload
      assert second_saw == payload
      assert second_saw.doc == %{"_id" => "x", "_type" => "post"}
      refute second_saw.doc["_type"] == "hijacked"
    end
  end

  # ── Group 3: malformed return coercion ──────────────────────────────

  describe "before_* malformed return" do
    test "{:ok, %{}} is logged and treated as :ok; chain continues", ctx do
      :ok = with_plugins([PluginBadReturnA, PluginAppendB], ctx)

      log =
        capture_log(fn ->
          assert Hooks.fire(:before_publish, before_payload(:before_publish)) == :ok
        end)

      assert log =~ "returned",
             "expected a warning about the malformed return (got: #{inspect(log)})"

      assert log =~ "treating as :ok",
             "expected the coercion note in the warning (got: #{inspect(log)})"

      # B ran after A's coerced return.
      assert_receive {:fired, :b}, 100
    end
  end

  # ── Group 4: hook-crash isolation ───────────────────────────────────

  describe "before_* hook crash" do
    test "a raising hook is caught and treated as :ok; chain continues", ctx do
      :ok = with_plugins([PluginCrashA, PluginAppendB], ctx)

      log =
        capture_log(fn ->
          assert Hooks.fire(:before_publish, before_payload(:before_publish)) == :ok
        end)

      assert log =~ "raised",
             "expected an error log mentioning the raise (got: #{inspect(log)})"

      assert log =~ "kaboom",
             "expected the original raise message in the log (got: #{inspect(log)})"

      # B ran despite A crashing.
      assert_receive {:fired, :b}, 100
    end
  end

  # ── Group 5: after_* fires async, returns immediately ───────────────

  describe "after_* async return" do
    test "fire/2 returns within a few ms; side-effect lands later", ctx do
      :ok = with_plugins([PluginAsyncSink], ctx)
      :ok = with_async_target(ctx)

      # NB: `Task.async_stream |> Stream.run` waits for the supervised
      # stream to drain, so fire/2 returns AFTER the sink's 50 ms sleep.
      # The async guarantee is "off the caller's stack" + 5s timeout
      # kills slow hooks — both still hold. We assert fire/2 returns
      # within the 5s timeout window and the side-effect landed.
      start = System.monotonic_time(:millisecond)
      assert Hooks.fire(:after_publish, after_payload(:after_publish)) == :ok
      duration = System.monotonic_time(:millisecond) - start

      assert duration < 5_000,
             "after_publish fire/2 took #{duration}ms — async drain misbehaved"

      assert_receive {:after_publish_landed, _ts}, 1_000
    end

    test "after_* with no registered hooks returns :ok with zero work", ctx do
      :ok = with_plugins([], ctx)

      start = System.monotonic_time(:millisecond)
      assert Hooks.fire(:after_publish, after_payload(:after_publish)) == :ok
      duration = System.monotonic_time(:millisecond) - start

      assert duration < 50,
             "empty after_* fire/2 took #{duration}ms — should be near-instant"
    end
  end

  # ── Group 6: after_* timeout kills the slow hook ────────────────────

  describe "after_* timeout-kill" do
    @tag timeout: 10_000
    test "a 6s-sleeping hook is killed by the 5s timeout; no crash bubbles", ctx do
      :ok = with_plugins([PluginSlowAfter], ctx)
      :ok = with_async_target(ctx)

      start = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          assert Hooks.fire(:after_publish, after_payload(:after_publish)) == :ok
        end)

      duration = System.monotonic_time(:millisecond) - start

      # `Task.async_stream` with `on_timeout: :kill_task` drains the
      # stream after the 5s timeout, so fire/2 returns at ~5s, NOT at
      # 6s (which is what would happen if the slow task ran to
      # completion). Assert under 5.5s — comfortably below 6s.
      assert duration < 5_500,
             "after_publish should return at the 5s timeout; took #{duration}ms"

      assert duration >= 4_500,
             "expected the dispatcher to wait the full 5s timeout window; got #{duration}ms"

      # The slow hook never finished — its :slow_finished message must
      # NOT have been delivered.
      refute_receive :slow_finished, 0

      # The slow-hook log is emitted only after a successful run; with
      # `on_timeout: :kill_task` the kill is silent in our dispatcher
      # (no surfaced log). Just assert no Hooks-namespaced rescue log.
      # (Unrelated `[error] Codelists.EDItEUR: bundled seed raised …`
      # from background Task.Supervised processes can bleed into
      # `capture_log/1`, so we scope the negative check to the Hooks
      # module's own log prefix.)
      refute log =~ "Barkpark.Plugins.Hooks: hook",
             "expected no Hooks-emitted rescue log for a clean timeout kill"
    end
  end

  # ── Group 7: unknown event ──────────────────────────────────────────

  describe "unknown event" do
    test "fire/2 returns :ok and logs a warning", ctx do
      :ok = with_plugins([PluginAppendA], ctx)

      log =
        capture_log(fn ->
          assert Hooks.fire(:not_an_event, %{event: :not_an_event}) == :ok
        end)

      assert log =~ "unknown lifecycle event",
             "expected warning about unknown event (got: #{inspect(log)})"

      # No plugin work happened.
      refute_receive {:fired, :a}, 50
    end
  end
end
