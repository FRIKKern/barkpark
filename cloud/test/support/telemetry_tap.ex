defmodule BarkparkCloud.TelemetryTap do
  @moduledoc """
  The cloud suite's ONE telemetry handler. Tests register their handlers here
  instead of calling `:telemetry.attach/4`.

  WHY. `:telemetry.attach/4` and `detach/1` are calls to the single
  `:telemetry_handler_table` gen_server, and each one REPLACES the
  `persistent_term` that holds the handler table. Replacing a persistent term
  releases the old one's literal area, which means every live process must be
  checked against it — the cost grows with the total heap in the VM, and the
  next replace waits behind it (measured: 10 back-to-back replaces cost
  ~0.2 ms each on an idle VM and 1–37 ms each with 50–200 processes holding
  large heaps). On a saturated CI runner a per-test attach waited out the
  5 s `GenServer.call` default:

      ** (exit) exited in: :gen_server.call(:telemetry_handler_table, {:insert, ...})
          ** (EXIT) time out

  — in eight Cloud-test jobs (ProvisioningTest, RouterMeMembershipReadCountTest,
  RouterLaunchFlowTest, RegistryAdminTokenWithheldTest, …), always at this
  call and never at another gen_server.

  HOW. `start!/0` (test_helper.exs, once, before any test) attaches ONE real
  handler for every event in `events/0`. `attach/4` and `detach/1` only write a
  public ETS bag, so a test never touches the handler table or
  `persistent_term`. `dispatch/4` runs in the EMITTING process — the same
  process a `:telemetry` handler runs in — and calls every registered
  function with the same four arguments. A function that raises is removed,
  as `:telemetry` removes a failing handler.

  `BarkparkCloud.TelemetryTapTest` reds any cloud test that calls
  `:telemetry.attach` directly.
  """

  require Logger

  @table __MODULE__

  # Every event a cloud test listens to. A new one goes here — `attach/4`
  # raises on an event the tap was not started with, rather than silently
  # never firing. Names a lib module owns (`telemetry_event/0`) are read from
  # it, so a rename there cannot leave the tap listening to the old name.
  @literal_events [
    [:barkpark_cloud, :repo, :query],
    [:barkpark_cloud, :registry, :admin_token_withheld],
    [:barkpark_cloud, :notifications, :fleet_digest, :settled],
    [:barkpark_cloud, :sites, :deploy, :grace],
    [:barkpark_cloud, :sites, :deploy, :deferral_unrecorded]
  ]

  @doc "The events the tap dispatches."
  def events do
    @literal_events ++
      [
        BarkparkCloud.AgentCommandResults.telemetry_event(),
        BarkparkCloud.GitHub.CommitDistanceSweep.telemetry_event(),
        BarkparkCloud.Notifications.ReceiptLoss.telemetry_event()
      ]
  end

  @doc """
  Create the registry and attach the one real handler. Call once, from
  test_helper.exs, before `ExUnit.start/1` runs any test.
  """
  def start! do
    parent = self()

    # The table outlives every test process: its owner is a process that only
    # waits, so no test exit can take the registry with it.
    spawn(fn ->
      :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
      send(parent, {__MODULE__, :ready})
      Process.sleep(:infinity)
    end)

    receive do
      {__MODULE__, :ready} -> :ok
    after
      5_000 -> raise "BarkparkCloud.TelemetryTap: registry owner did not start"
    end

    :ok = :telemetry.attach_many({__MODULE__, :tap}, events(), &__MODULE__.dispatch/4, nil)
  end

  @doc """
  Register `fun` for `event` under `id` — the arguments and return values of
  `:telemetry.attach/4`.
  """
  def attach(id, event, fun, config) when is_list(event) and is_function(fun, 4) do
    unless event in events() do
      raise ArgumentError,
            "BarkparkCloud.TelemetryTap is not listening to #{inspect(event)}. " <>
              "Add it to events/0 in test/support/telemetry_tap.ex."
    end

    if :ets.match_object(@table, {:_, id, :_, :_}) == [] do
      true = :ets.insert(@table, {event, id, fun, config})
      :ok
    else
      {:error, :already_exists}
    end
  end

  @doc "Remove the handler registered under `id` — as `:telemetry.detach/1`."
  def detach(id) do
    if :ets.match_object(@table, {:_, id, :_, :_}) == [] do
      {:error, :not_found}
    else
      true = :ets.match_delete(@table, {:_, id, :_, :_})
      :ok
    end
  end

  @doc false
  def dispatch(event, measurements, metadata, _config) do
    for {^event, id, fun, config} <- :ets.lookup(@table, event) do
      try do
        fun.(event, measurements, metadata, config)
      catch
        kind, reason ->
          :ets.match_delete(@table, {:_, id, :_, :_})

          Logger.error(
            "TelemetryTap handler #{inspect(id)} for #{inspect(event)} failed and was removed: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )
      end
    end

    :ok
  end
end
