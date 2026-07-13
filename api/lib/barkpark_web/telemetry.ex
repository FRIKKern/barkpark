defmodule BarkparkWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},

      # PROD-REACHABLE reporter. `metrics/0` below is only ever consumed by
      # LiveDashboard, which the router mounts behind `if dev_routes` — true
      # ONLY in config/dev.exs. So in prod the whole metrics list was computed
      # by nobody: no answer to "p95 Ecto query?", "which route is slow?", "is
      # VM memory climbing?" (the last a real OOM scar). This Prometheus core
      # aggregator attaches telemetry handlers to each event in
      # `prometheus_metrics/0` and holds the running aggregates in ETS; the
      # token-gated `GET /v1/instance/metrics` route scrapes them. It runs in
      # EVERY env (not dev-gated) so the prod hole cannot reopen unnoticed.
      {TelemetryMetricsPrometheus.Core, name: :barkpark_metrics, metrics: prometheus_metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The Prometheus-exposed subset, one metric per NAMED production question.

  `TelemetryMetricsPrometheus.Core` supports only counter/sum/last_value/
  distribution (NOT `summary` — the type `metrics/0` uses for LiveDashboard), so
  this is a deliberate, curated list rather than a reuse of `metrics/0`. Latency
  questions use `distribution` (a Prometheus histogram: `histogram_quantile` over
  the buckets yields p95); level questions use `last_value` (a gauge). Nothing
  here is decorative — every metric answers a question the finding named.
  """
  def prometheus_metrics do
    # Millisecond buckets shared by every latency histogram. Covers a fast
    # in-pool query (<10ms) through a pathological multi-second request.
    latency_buckets = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]

    [
      # Q: "what is p95 Ecto query time?" — total_time is the wall-clock a caller
      # actually waited (queue + query + decode). Its histogram is the headline.
      distribution("barkpark.repo.query.total_time",
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "End-to-end Ecto query latency (queue+query+decode). p95 via histogram_quantile."
      ),
      # Q: "is the query slow because of the DB or a starved connection pool?" —
      # queue_time isolates pool saturation (a distinct prod failure that
      # masquerades as slow queries) from actual execution time.
      distribution("barkpark.repo.query.queue_time",
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description: "Time waiting for a DB connection — climbs when the pool is saturated."
      ),
      # Q: "which route is slow?" — per-route request-handling histogram. The
      # :route tag is the discriminator that answers *which* one.
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description: "Per-route dispatch latency — tag :route identifies the slow endpoint."
      ),
      # Q: "is VM memory climbing?" — the documented OOM scar (codelist OOM kills
      # the box). A gauge sampled every 10s by telemetry_poller; a climbing line
      # is a leak caught before OOM instead of after.
      last_value("vm.memory.total",
        unit: {:byte, :kilobyte},
        description: "Total BEAM memory — watch for a monotonic climb (leak → OOM)."
      ),
      # Q: "is the scheduler backing up?" — run-queue length is the twin health
      # signal to memory; a sustained non-zero backlog means the box is overloaded
      # before latency alone makes it obvious.
      last_value("vm.total_run_queue_lengths.total",
        description: "Total scheduler run-queue length — sustained >0 means the VM is saturated."
      ),
      # Q: "what is p95 of a mutate?" — the batch-write hot path
      # (Content.apply_mutations) had ZERO timing before this. `:telemetry.span`
      # emits [:barkpark, :content, :mutate, :stop] with :duration; this
      # histogram makes p95 derivable via histogram_quantile.
      # `:workspace_id` tags per-workspace mutate volume/latency (perfect-plan-
      # build W1, D12); unscoped writes carry the "global" sentinel.
      distribution("barkpark.content.mutate.stop.duration",
        tags: [:workspace_id],
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "Batch-mutate (apply_mutations) latency — p95 via histogram_quantile; tag :workspace_id."
      ),
      # Q: "what is p95 of a publish?" — the publish/lifecycle hot path had ZERO
      # timing. One span [:barkpark, :content, :lifecycle, :stop] covers all four
      # ops; the :op tag selects publish (or unpublish/discard_draft/delete);
      # :workspace_id tags it per-tenant (perfect-plan-build W1, D12).
      distribution("barkpark.content.lifecycle.stop.duration",
        tags: [:op, :workspace_id],
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "Publish/lifecycle latency — p95 via histogram_quantile; tag :op selects publish, :workspace_id per-tenant."
      ),
      # Q: "how many media writes per workspace?" — the media upload/update/delete
      # path has NO :telemetry.span of its own (it bypasses Content), so
      # RequireWithinQuota emits one [:barkpark, :media, :mutate] event per
      # allowed scoped media write (perfect-plan-build W1, D12). This sum meters
      # it per-tenant.
      sum("barkpark.media.mutate.count",
        tags: [:workspace_id],
        description: "Scoped media writes (upload/update/delete) per workspace."
      ),
      # Q: "which plugin hook is slowing our writes?" — before_*/after_* hooks run
      # on the write path (the sheets before_save gate does a full Engine
      # recompute). Hooks.timed_invoke/3 emits [:barkpark, :hooks, :hook, :stop];
      # this histogram was previously emitted to the void (no consumer). Tags
      # :event (lifecycle stage) + :module (which plugin) pinpoint the culprit.
      distribution("barkpark.hooks.hook.stop.duration",
        tags: [:event, :module],
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "Per-plugin-hook duration — p95 via histogram_quantile; tags :event=stage, :module=plugin."
      )
    ]
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("barkpark.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("barkpark.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("barkpark.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("barkpark.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("barkpark.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),
      sum("search.intel.record.count",
        tags: [:surface, :result],
        description: "Search intelligence record outcomes"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {BarkparkWeb, :count_users, []}
    ]
  end
end
