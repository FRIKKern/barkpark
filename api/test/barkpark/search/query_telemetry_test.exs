defmodule Barkpark.Search.QueryTelemetryTest do
  @moduledoc """
  Protective test for the search READ-path observability slice (perfect-plan-
  build W7, task `bpb-search-read-telemetry`). Pins the regression the audit
  found: `QueryPipeline.search/4` computed a local `ms` latency for the response
  body but emitted NO `:telemetry` event, so "what is p95 of a search?" was
  unanswerable — the only search event ([:barkpark, :search, :intel, :record])
  is a WRITE with no `workspace_id`.

  The fix mirrors the D12 content-write precedent: one `:telemetry.span`
  ([:barkpark, :search, :query]) wraps the single choke point every
  documents+media search funnels through, tagged with `workspace_id` (nil coerced
  to "global"). The metric is checked at three levels: it FIRES on the live path
  with the expected metadata, it's DECLARED in the Prometheus reporter's metric
  set, and the live aggregator RECORDS a sample.

  async: false — asserts against the process-global telemetry handler table and
  the app-wide `:barkpark_metrics` aggregator.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Search.{QueryPipeline, SurfaceConfigs}
  alias BarkparkWeb.Telemetry

  @aggregator :barkpark_metrics
  @query_stop [:barkpark, :search, :query, :stop]
  # SurfaceConfig.workspace_id is :binary_id, so the scoped-search opt must be a
  # real UUID — the telemetry tag carries whatever the caller threaded verbatim.
  @ws_id "11111111-1111-4111-8111-111111111111"

  setup do
    SurfaceConfigs.seed_defaults!()

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "telem"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.t1", "title" => "Elixir Phoenix Guide"},
      "telem"
    )

    Content.publish_document("t1", "post", "telem")
    :ok
  end

  test "search/4 emits a query.stop span carrying the caller's workspace_id" do
    ref = attach_forwarder("search-ws", @query_stop)

    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, _result} =
             QueryPipeline.search("documents", "telem", context,
               perspective: :published,
               limit: 10,
               workspace_id: @ws_id
             )

    assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
    assert measurements.duration > 0
    assert metadata.workspace_id == @ws_id
    assert metadata.surface == "documents"
    assert metadata.scope == "telem"
  after
    :telemetry.detach("search-ws")
  end

  test "an unscoped (anonymous) search coerces workspace_id to the \"global\" sentinel" do
    ref = attach_forwarder("search-global", @query_stop)

    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, _result} =
             QueryPipeline.search("documents", "telem", context,
               perspective: :published,
               limit: 10
             )

    assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
    assert measurements.duration > 0
    # nil workspace_id (anonymous / unscoped) MUST become "global" so the
    # Prometheus tag is always present — never nil, which the reporter drops.
    assert metadata.workspace_id == "global"
  after
    :telemetry.detach("search-global")
  end

  test "the query histogram is DECLARED in the Prometheus reporter's metric set" do
    events = Telemetry.prometheus_metrics() |> Enum.map(& &1.event_name)

    assert @query_stop in events,
           "prometheus_metrics/0 is missing the search-query histogram — p95 of a search is blind"

    metric = Telemetry.prometheus_metrics() |> Enum.find(&(&1.event_name == @query_stop))
    assert :workspace_id in metric.tags, "search-query histogram must tag :workspace_id"
  end

  test "the live Prometheus aggregator records a sample after a real search" do
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, _} =
             QueryPipeline.search("documents", "telem", context,
               perspective: :published,
               limit: 10,
               workspace_id: @ws_id
             )

    scraped = TelemetryMetricsPrometheus.Core.scrape(@aggregator)

    assert scraped =~ "barkpark_search_query_stop_duration_bucket",
           "search-query histogram never recorded a sample in the live reporter"
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
