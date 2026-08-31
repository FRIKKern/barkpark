defmodule BarkparkWeb.WriteHotpathTelemetryTest do
  @moduledoc """
  Protective test for the write-hot-path observability fix (task
  `task-5aac97bc8fb7166e`). Pins THREE regressions the audit found:

    1. The mutate/publish pipeline emitted NO timing telemetry — "p95 of a
       mutate?"/"p95 of a publish?" were unanswerable.
    2. `Barkpark.Plugins.Hooks` measured every after_* hook duration then emitted
       `[:barkpark, :hooks, <event>, :hook]` to the VOID — no handler, absent
       from the Prometheus reporter.
    3. before_* hooks (the sheets before_save Engine-recompute gate) were timed
       by NOTHING at all.

  Each `assert` maps to a NAMED production question, and each named event is
  checked at three levels: it's DECLARED in the Prometheus reporter's metric set,
  a handler is ATTACHED to it (not orphaned), and it actually FIRES with a
  duration measurement on the live code path.

  async: false — asserts against the process-global telemetry handler table, the
  app-wide `:barkpark_metrics` aggregator, and `:barkpark, :plugins` env.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Hooks
  alias BarkparkWeb.Telemetry

  @aggregator :barkpark_metrics

  @mutate_stop [:barkpark, :content, :mutate, :stop]
  @lifecycle_stop [:barkpark, :content, :lifecycle, :stop]
  @hook_stop [:barkpark, :hooks, :hook, :stop]

  # A plugin with an intentionally SLOW before_save hook — models the sheets
  # before_save Engine recompute that can degrade to seconds and stall a save.
  defmodule SlowGatePlugin do
    @moduledoc false
    def lifecycle_hooks, do: %{before_save: [&__MODULE__.slow_gate/1]}

    def slow_gate(_payload) do
      Process.sleep(120)
      :ok
    end
  end

  defp before_save_payload do
    %{
      event: :before_save,
      doc: %{"_id" => "x", "_type" => "post"},
      dataset: "production",
      prev_doc: nil,
      ctx: %{source: :studio, user_id: nil}
    }
  end

  describe "each new event is DECLARED in the Prometheus reporter's metric set" do
    test "mutate/publish/hook duration histograms are all present" do
      events = Telemetry.prometheus_metrics() |> Enum.map(& &1.event_name)

      # Q: "what is p95 of a mutate?"
      assert @mutate_stop in events,
             "prometheus_metrics/0 is missing the mutate histogram — p95 of a mutate is blind"

      # Q: "what is p95 of a publish?"
      assert @lifecycle_stop in events,
             "prometheus_metrics/0 is missing the lifecycle histogram — p95 of a publish is blind"

      # Q: "which plugin hook is slowing our writes?" — the event that was
      # emitted to the void now has a Prometheus consumer.
      assert @hook_stop in events,
             "prometheus_metrics/0 is missing the hook-duration histogram — hook timing is orphaned"
    end
  end

  describe "the hook-duration event is ATTACHED (no longer emitted to the void)" do
    test "a barkpark handler AND the Prometheus reporter both subscribe to it" do
      handlers = :telemetry.list_handlers(@hook_stop)

      assert Enum.any?(handlers, fn h -> inspect(h.id) =~ "barkpark-handlers" end),
             "no barkpark-handlers consumer on #{inspect(@hook_stop)} — hook duration is still orphaned"

      assert Enum.any?(handlers, fn h ->
               inspect(h.id) =~ "barkpark_metrics" or inspect(h.config) =~ "barkpark_metrics"
             end),
             "no :barkpark_metrics handler on #{inspect(@hook_stop)} — hook histogram not wired"
    end
  end

  describe "the events FIRE with a duration measurement on the live code path" do
    test "a slow before_save hook emits a hook.stop with duration_ms past the slow floor" do
      set_plugins_env([SlowGatePlugin])
      ref = attach_forwarder("hook", @hook_stop)

      assert Hooks.fire(:before_save, before_save_payload()) == :ok

      assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
      # before_* hooks used to be timed by NOTHING — now the duration is real.
      assert measurements.duration > 0

      assert measurements.duration_ms >= 100,
             "the 120ms before_save gate should measure past the 100ms slow floor"

      assert metadata.event == :before_save
      assert metadata.module == SlowGatePlugin
    after
      :telemetry.detach("hook")
    end

    test "apply_mutations emits a mutate.stop with a positive duration" do
      ref = attach_forwarder("mutate", @mutate_stop)

      # Error path still fires :stop — we assert the SPAN, not the write outcome.
      _ = Content.apply_mutations([%{"bogus" => %{}}], "production", [])

      assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
      assert measurements.duration > 0
      assert metadata.count == 1
    after
      :telemetry.detach("mutate")
    end

    test "publish_document emits a lifecycle.stop with op=:publish and a positive duration" do
      ref = attach_forwarder("publish", @lifecycle_stop)

      # not_found path still fires :stop — the span wraps the whole op.
      _ = Content.publish_document("does-not-exist", "post", "production", [])

      assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
      assert measurements.duration > 0
      assert metadata.op == :publish
    after
      :telemetry.detach("publish")
    end
  end

  describe "the live Prometheus aggregator records the samples (measurement)" do
    test "hook + mutate + publish histograms leave the floor after real calls" do
      set_plugins_env([SlowGatePlugin])

      assert Hooks.fire(:before_save, before_save_payload()) == :ok
      _ = Content.apply_mutations([%{"bogus" => %{}}], "production", [])
      _ = Content.publish_document("does-not-exist", "post", "production", [])

      scraped = TelemetryMetricsPrometheus.Core.scrape(@aggregator)

      assert scraped =~ "barkpark_hooks_hook_stop_duration_bucket",
             "hook-duration histogram never recorded a sample in the live reporter"

      assert scraped =~ "barkpark_content_mutate_stop_duration_bucket",
             "mutate histogram never recorded a sample in the live reporter"

      assert scraped =~ "barkpark_content_lifecycle_stop_duration_bucket",
             "lifecycle histogram never recorded a sample in the live reporter"
    end
  end

  # Sets `:barkpark, :plugins` for the duration of one test and restores the
  # prior value in `on_exit`. Without this, the two tests below leaked
  # `[SlowGatePlugin]` — a fake module with no `register_routes/1` — into the
  # rest of the `mix test` run: `Barkpark.DataCase`'s per-test setup resets
  # the env before every OTHER `DataCase` test, but a bare `ExUnit.Case`
  # module (e.g. `plugin_routes_test.exs`) running next in the async: false
  # order inherited the leak, saw only `SlowGatePlugin` when it called
  # `Registry.collect_routes/1`, and its "every auth: bucket declared by a
  # registered plugin route is an accepted scope" test failed with "no
  # plugin contributed any route" — a standing, run-order-dependent flake,
  # not a defect in that test or in this PR's BPML changes.
  defp set_plugins_env(modules) do
    prior = Application.get_env(:barkpark, :plugins, :unset)
    Application.put_env(:barkpark, :plugins, modules)

    on_exit(fn ->
      case prior do
        :unset -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end
    end)
  end

  # Attach a telemetry handler that forwards {measurements, metadata} to the
  # test process. Detached in each test's `after` block.
  defp attach_forwarder(id, event) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      id,
      event,
      fn ^event, measurements, metadata, _cfg ->
        send(test_pid, {:telemetry, ref, measurements, metadata})
      end,
      nil
    )

    ref
  end
end
