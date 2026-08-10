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
      {TelemetryMetricsPrometheus.Core, name: :barkpark_metrics, metrics: prometheus_metrics()},

      # Distributions in Core keep every observation in ETS until a scrape folds
      # them into buckets. `prometheus_metrics/0` puts distributions on
      # `barkpark.repo.query.*`, which fire per QUERY, so an instance nobody
      # scrapes grows that table without bound — see the module doc for the
      # measurements. This prunes only when the endpoint looks unused, so an
      # instance with a real Prometheus attached is unaffected.
      BarkparkWeb.Telemetry.DistributionPruner
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
      # Q: "WHICH subsystem is growing?" — the total above says a leak exists but
      # not where it lives. telemetry_poller's default vm measurement already
      # emits the full nine-key `:erlang.memory()` map on [:vm, :memory] every
      # 10s; only the subscription was narrow. These four break the total down
      # into the answers that change what you do: processes (a leaking GenServer
      # state / mailbox), binary (the classic refc-binary leak), ets (an
      # unbounded cache table), code (module churn / hot-loading).
      #
      # UNIT DISCIPLINE (charter D64): every BEAM gauge here carries
      # `unit: {:byte, :kilobyte}` to match `vm.memory.total` above.
      # TelemetryMetricsPrometheus.Core scales the value but keeps the
      # event-derived NAME, so these render unsuffixed (`vm_memory_processes`,
      # not `..._kilobytes`) — an unsuffixed BYTE gauge sitting beside these
      # unsuffixed KILOBYTE ones is exactly how a 1024x unit error renders as a
      # phantom memory leak. Same unit or an explicit `_bytes` suffix, never
      # neither.
      last_value("vm.memory.processes",
        unit: {:byte, :kilobyte},
        description: "BEAM memory held by processes — climbs on leaking state or mailboxes."
      ),
      last_value("vm.memory.binary",
        unit: {:byte, :kilobyte},
        description: "BEAM memory in refc binaries — the classic binary leak."
      ),
      last_value("vm.memory.ets",
        unit: {:byte, :kilobyte},
        description: "BEAM memory in ETS tables — climbs on an unbounded cache."
      ),
      last_value("vm.memory.code",
        unit: {:byte, :kilobyte},
        description: "BEAM memory holding loaded code — climbs on module churn."
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
      # Q: "what is p95 of a search?" — the READ path (QueryPipeline.search/4, the
      # single choke point every documents+media search funnels through) had ZERO
      # timing: it computed `ms` locally for the response body but fired no
      # telemetry (the only search event, [:barkpark, :search, :intel, :record],
      # is a WRITE with no workspace_id). `:telemetry.span` emits
      # [:barkpark, :search, :query, :stop] with :duration; this histogram makes
      # p95 derivable. `:workspace_id` tags per-workspace search volume/latency
      # (perfect-plan-build W7); unscoped/anonymous reads carry the "global"
      # sentinel, mirroring the content.mutate distribution above (D12).
      distribution("barkpark.search.query.stop.duration",
        tags: [:workspace_id],
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "Search read-path (QueryPipeline.search) latency — p95 via histogram_quantile; tag :workspace_id."
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
      ),
      # Q: "which LiveView is slow to mount / re-param / handle an event?" —
      # Studio, the Projects board, the paper reader are all LiveViews; before
      # this, phoenix.live_view.* fired to nobody in prod (metrics/0 is
      # LiveDashboard-only, dev-gated). These four are the REAL event families
      # Phoenix.LiveView emits (V7-verified against the dep): live_view carries
      # mount/handle_params/handle_event; live_component carries ONLY
      # handle_event (no mount, no handle_params).
      #
      # CRITICAL ASYMMETRY — tag_values is `Map.take(fn.(metadata), tags)`, and a
      # returned map MISSING a declared tag key SILENTLY DROPS the sample (fails
      # closed). The live_view metadata carries a raw %Socket{}, so the :view tag
      # must be dug out of `socket.view`; the live_component metadata already
      # carries `:component` as a TOP-LEVEL key, so it needs its OWN fn. Reusing
      # one `%{view: socket.view}` fn across all four would mistag the component
      # metric (no :component key → every live_component sample dropped).
      distribution("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        tag_values: &lv_view_tag/1,
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "LiveView mount latency — p95 via histogram_quantile; tag :view = the module."
      ),
      distribution("phoenix.live_view.handle_params.stop.duration",
        tags: [:view],
        tag_values: &lv_view_tag/1,
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "LiveView handle_params latency — p95 via histogram_quantile; tag :view = the module."
      ),
      distribution("phoenix.live_view.handle_event.stop.duration",
        tags: [:view],
        tag_values: &lv_view_tag/1,
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "LiveView handle_event latency — p95 via histogram_quantile; tag :view = the module."
      ),
      # live_component tags off metadata.component (a top-level key), NOT the
      # socket — its OWN fn, never the shared lv_view_tag.
      distribution("phoenix.live_component.handle_event.stop.duration",
        tags: [:component],
        tag_values: &lc_component_tag/1,
        reporter_options: [buckets: latency_buckets],
        unit: {:native, :millisecond},
        description:
          "LiveComponent handle_event latency — p95 via histogram_quantile; tag :component = the module."
      ),
      # ── Authoring wall — curator legibility (charter D44) ───────────────────
      # Q: "how often is the publish wall rejecting a publish, and for what?"
      # Waves 1–5 sealed the wall; every rejection fired
      # [:barkpark, :authoring, :wall_rejection] (authoring_wall.ex emit_wall_rejection)
      # into a total production VOID — no Prometheus series, no attached handler
      # (proven on the deployed build). Before this, an operator could only raw-grep
      # journalctl for "Sent 422", which drifts with slot + log retention and cannot
      # answer "how often" reproducibly. The RULED consumer is the already-live,
      # Bearer-gated `GET /v1/instance/metrics` scrape (charter D44 inverts D29's
      # inventory doctrine — the consumer now EXISTS, so no novel findings store).
      # Tagged ONLY by BOUNDED keys: :code (label_spine | unknown_tag | duplicate_of),
      # :type (paper | task), :dataset. The emitter carries no other metadata.
      sum("barkpark.authoring.wall_rejection.count",
        tags: [:code, :type, :dataset],
        description:
          "Publish-wall rejections — tags :code=gate (label_spine|unknown_tag|duplicate_of), :type, :dataset."
      ),
      # Q: "how often does a just-published doc fail to retrieve ITSELF by its own
      # labels?" The D9 findability post-test (an Oban worker) fires
      # [:barkpark, :authoring, :findability_miss] (findability_posttest.ex emit_miss)
      # into the same void. Tagged ONLY by BOUNDED :type/:dataset — the emitter's
      # :doc_id, :query and :rank_diagnostics are UNBOUNDED cardinality and are
      # deliberately DROPPED here (never Prometheus tags; they live in the log line).
      sum("barkpark.authoring.findability_miss.count",
        tags: [:type, :dataset],
        description:
          "Post-publish self-retrieval misses — a published doc absent from top-N for its own labels; tags :type, :dataset."
      )
    ]
  end

  # tag_values for the three live_view metrics: the module lives at socket.view,
  # NOT as a top-level metadata key. Fails closed if a future dep drops :socket.
  defp lv_view_tag(%{socket: %{view: view}}), do: %{view: view}
  defp lv_view_tag(_metadata), do: %{view: :unknown}

  # tag_values for the live_component metric: :component is ALREADY a top-level
  # metadata key — this fn must read it directly, never socket.view.
  defp lc_component_tag(%{component: component}), do: %{component: component}
  defp lc_component_tag(_metadata), do: %{component: :unknown}

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
