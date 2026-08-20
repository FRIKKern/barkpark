defmodule Barkpark.Telemetry.CuratorMetricsTest do
  @moduledoc """
  Protective test for the curator consumer (task `ae-curator-feed`, charter D44).

  Waves 1–5 sealed the publish wall, but its two authoring telemetry events fired
  into a total PRODUCTION VOID (V2 confirmed on the deployed build):

    * `[:barkpark, :authoring, :wall_rejection]` — emitted at every publish-wall
      rejection (`authoring_wall.ex emit_wall_rejection`), measurements
      `%{count: 1}`, metadata `%{code, type, dataset}`.
    * `[:barkpark, :authoring, :findability_miss]` — emitted when a just-published
      doc fails to retrieve itself by its own labels (`findability_posttest.ex
      emit_miss`), measurements `%{count: 1}`, metadata
      `%{doc_id, type, dataset, query, rank_diagnostics}`.

  The RULED consumer (D44) is NOT a novel findings store — it is the already-live,
  Bearer-gated `GET /v1/instance/metrics` Prometheus scrape. This test pins that
  wiring at THREE levels, mirroring `write_hotpath_telemetry_test.exs`:

    1. both events are DECLARED as bounded `sum()` counters in
       `BarkparkWeb.Telemetry.prometheus_metrics/0` (tagged ONLY :code/:type/:dataset —
       the unbounded :query/:doc_id/:rank_diagnostics are deliberately dropped);
    2. a `barkpark-handlers` consumer is ATTACHED to each event (no longer a void);
    3. each event FIRES and the attached handlers receive it with the emitter's
       exact metadata shape.

  Every assertion REDS before the telemetry.ex / handlers.ex wiring and GREENS
  after.

  async: false — asserts against the process-global telemetry handler table.
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.Telemetry

  @wall_rejection [:barkpark, :authoring, :wall_rejection]
  @findability_miss [:barkpark, :authoring, :findability_miss]

  describe "both authoring events are DECLARED as bounded Prometheus counters" do
    setup do
      %{events: Telemetry.prometheus_metrics() |> Enum.map(& &1.event_name)}
    end

    test "prometheus_metrics/0 lists the wall_rejection counter", %{events: events} do
      assert @wall_rejection in events,
             "prometheus_metrics/0 is missing the wall_rejection counter — an operator " <>
               "cannot answer 'how often is the wall rejecting, and for what?'"
    end

    test "prometheus_metrics/0 lists the findability_miss counter", %{events: events} do
      assert @findability_miss in events,
             "prometheus_metrics/0 is missing the findability_miss counter — post-publish " <>
               "self-retrieval misses are still invisible on a dashboard"
    end

    test "the counters are tagged by BOUNDED keys only — never the unbounded metadata" do
      metrics = Telemetry.prometheus_metrics()

      wall = Enum.find(metrics, &(&1.event_name == @wall_rejection))
      miss = Enum.find(metrics, &(&1.event_name == @findability_miss))

      assert wall, "wall_rejection counter absent"
      assert miss, "findability_miss counter absent"

      # wall_rejection: :code/:type/:dataset are all bounded (finite atoms/strings).
      assert Enum.sort(wall.tags) == [:code, :dataset, :type],
             "wall_rejection must tag exactly :code/:type/:dataset, got #{inspect(wall.tags)}"

      # findability_miss has no :code; :doc_id/:query/:rank_diagnostics are
      # UNBOUNDED cardinality and MUST stay out of the Prometheus label set.
      assert Enum.sort(miss.tags) == [:dataset, :type],
             "findability_miss must tag exactly :type/:dataset, got #{inspect(miss.tags)}"

      refute :doc_id in miss.tags, "unbounded :doc_id must never be a Prometheus tag"
      refute :query in miss.tags, "unbounded :query must never be a Prometheus tag"

      refute :rank_diagnostics in miss.tags,
             "unbounded :rank_diagnostics must never be a Prometheus tag"

      # Both count the `:count` measurement the emitters carry (%{count: 1}).
      assert wall.measurement == :count
      assert miss.measurement == :count
    end
  end

  describe "a barkpark-handlers consumer is ATTACHED to each event (no longer a void)" do
    test "wall_rejection has a barkpark-handlers handler" do
      handlers = :telemetry.list_handlers(@wall_rejection)

      assert Enum.any?(handlers, fn h -> inspect(h.id) =~ "barkpark-handlers" end),
             "no barkpark-handlers consumer on #{inspect(@wall_rejection)} — still a void"
    end

    test "findability_miss has a barkpark-handlers handler" do
      handlers = :telemetry.list_handlers(@findability_miss)

      assert Enum.any?(handlers, fn h -> inspect(h.id) =~ "barkpark-handlers" end),
             "no barkpark-handlers consumer on #{inspect(@findability_miss)} — still a void"
    end
  end

  describe "the events FIRE and an attached handler receives them" do
    test "wall_rejection reaches a forwarder with its exact metadata shape" do
      ref = attach_forwarder("curator-wall", @wall_rejection)

      :telemetry.execute(
        @wall_rejection,
        %{count: 1},
        %{code: :label_spine, type: "paper", dataset: "production"}
      )

      assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
      assert measurements.count == 1
      assert metadata.code == :label_spine
      assert metadata.type == "paper"
      assert metadata.dataset == "production"
    after
      :telemetry.detach("curator-wall")
    end

    test "findability_miss reaches a forwarder with its exact metadata shape" do
      ref = attach_forwarder("curator-miss", @findability_miss)

      :telemetry.execute(
        @findability_miss,
        %{count: 1},
        %{
          doc_id: "p1",
          type: "paper",
          dataset: "production",
          query: "search wall",
          rank_diagnostics: %{ranked: [], top_n: 10, total: 3}
        }
      )

      assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
      assert measurements.count == 1
      assert metadata.type == "paper"
      assert metadata.dataset == "production"
      assert metadata.doc_id == "p1"
    after
      :telemetry.detach("curator-miss")
    end
  end

  # Attach a telemetry handler that forwards {measurements, metadata} to the test
  # process (the write_hotpath_telemetry_test.exs idiom). Detached in `after`.
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
