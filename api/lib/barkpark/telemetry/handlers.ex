defmodule Barkpark.Telemetry.Handlers do
  @moduledoc """
  Telemetry attachment for Phase-1 plugin foundations.

  Attaches loggers for:
    * `[:barkpark, :oban, :job, :start | :stop | :exception]`
      (re-emitted from Oban's native `[:oban, :job, ...]` events)
    * `[:barkpark, :plugin_settings, :read | :write]`
    * `[:barkpark, :hooks, :hook, :stop]` (plugin lifecycle-hook duration —
      previously measured then emitted to the void)
  """

  require Logger

  @app_events [
    [:barkpark, :oban, :job, :start],
    [:barkpark, :oban, :job, :stop],
    [:barkpark, :oban, :job, :exception],
    [:barkpark, :plugin_settings, :read],
    [:barkpark, :plugin_settings, :write],
    [:barkpark, :search, :intel, :record],
    # Plugin lifecycle-hook duration. `Barkpark.Plugins.Hooks.timed_invoke/3`
    # measures every before_*/after_* hook then emits this. Before this handler
    # existed the measurement was computed on the write hot path and emitted to
    # the VOID (no attach, not in metrics/0) — the audit's "measured then thrown
    # away". A debug consumer here + the Prometheus histogram in
    # BarkparkWeb.Telemetry now both consume it.
    [:barkpark, :hooks, :hook, :stop]
  ]

  @oban_events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  @doc """
  Attach all Phase-1 handlers. Idempotent — safe to call once at boot.
  """
  def attach do
    detach()

    :telemetry.attach_many(
      "barkpark-handlers",
      @app_events,
      &__MODULE__.handle_event/4,
      nil
    )

    :telemetry.attach_many(
      "barkpark-oban-forwarder",
      @oban_events,
      &__MODULE__.forward_oban/4,
      nil
    )

    :ok
  end

  @doc "Detach handlers (used for cleanup in tests / hot reloads)."
  def detach do
    :telemetry.detach("barkpark-handlers")
    :telemetry.detach("barkpark-oban-forwarder")
    :ok
  end

  @doc false
  def forward_oban([:oban, :job, kind], measurements, metadata, _config) do
    :telemetry.execute(
      [:barkpark, :oban, :job, kind],
      measurements,
      metadata
    )
  end

  @doc false
  def handle_event([:barkpark, :oban, :job, kind], measurements, metadata, _config) do
    Logger.info(
      "oban.job.#{kind} worker=#{inspect(metadata[:worker])} " <>
        "queue=#{inspect(metadata[:queue])} duration=#{inspect(measurements[:duration])}"
    )
  end

  def handle_event([:barkpark, :plugin_settings, kind], _measurements, metadata, _config) do
    Logger.info("plugin_settings.#{kind} plugin=#{inspect(metadata[:plugin_name])}")
  end

  def handle_event([:barkpark, :hooks, :hook, :stop], measurements, metadata, _config) do
    Logger.debug(
      "hooks.hook event=#{inspect(metadata[:event])} " <>
        "module=#{inspect(metadata[:module])} duration_ms=#{inspect(measurements[:duration_ms])}"
    )
  end

  def handle_event([:barkpark, :search, :intel, :record], _measurements, metadata, _config) do
    Logger.debug(
      "search.intel.record surface=#{inspect(metadata[:surface])} " <>
        "scope=#{inspect(metadata[:scope])} result=#{inspect(metadata[:result])} " <>
        "reason=#{inspect(metadata[:reason])}"
    )
  end
end
