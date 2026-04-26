defmodule Barkpark.Telemetry.Handlers do
  @moduledoc """
  Telemetry attachment for Phase-1 plugin foundations.

  Attaches loggers for:
    * `[:barkpark, :oban, :job, :start | :stop | :exception]`
      (re-emitted from Oban's native `[:oban, :job, ...]` events)
    * `[:barkpark, :plugin_settings, :read | :write]`
  """

  require Logger

  @app_events [
    [:barkpark, :oban, :job, :start],
    [:barkpark, :oban, :job, :stop],
    [:barkpark, :oban, :job, :exception],
    [:barkpark, :plugin_settings, :read],
    [:barkpark, :plugin_settings, :write]
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
end
