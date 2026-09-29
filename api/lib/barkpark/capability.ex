defmodule Barkpark.Capability do
  @moduledoc """
  Operator-level on/off switches for the three process-tooling subsystems that
  are not plugins: Studio Chat, CycleFleet and EpicFleet (Barkspark phase 1,
  task-2f59ba23bcad333e).

  They are not registered plugins, so the `BARKPARK_PLUGINS` kill switch cannot
  reach them. This module is the switch that can. It answers one question,
  `enabled?/1`, and three consumers read it:

    * `Barkpark.Capability.Supervisor` starts a subsystem's processes only when
      it is enabled (today only Studio Chat has processes).
    * `BarkparkWeb.Plugs.RequireCapability` answers every HTTP route of a
      disabled subsystem with a plain 404, the same refusal the plugin kill
      switch gives a disabled plugin's routes.
    * The Studio Chat LiveViews refuse to mount when Studio Chat is disabled.

  ## Configuration

  Every capability is ON unless the operator turns it off, so a box that sets
  nothing behaves exactly as before this module existed.

      # config: one boolean per capability, default true
      config :barkpark, Barkpark.Capability, studio_chat: false

      # release: config/runtime.exs reads a comma-separated OFF list
      BARKPARK_CAPABILITIES_OFF=studio_chat,cycle_fleet

  ## Dependencies

  `:cycle_fleet` requires `:epic_fleet`: CycleFleet writes its assignments and
  results into the EpicFleet ledger, and EpicFleet has no routes of its own. So
  turning EpicFleet off also refuses every CycleFleet route.

  This is not `Barkpark.Plugins.Capabilities` (the `/v1/capabilities` manifest)
  or `Barkpark.StudioChat.Runtime.Capabilities` (what a chat provider binary can
  do). Neither of those switches anything on or off.
  """

  @names [:studio_chat, :cycle_fleet, :epic_fleet]
  @requires %{cycle_fleet: [:epic_fleet]}

  @type name :: :studio_chat | :cycle_fleet | :epic_fleet

  @doc "Every capability name this module knows."
  @spec names() :: [name()]
  def names, do: @names

  @doc """
  True when the capability is switched on AND every capability it requires is
  switched on. Unset config means on.
  """
  @spec enabled?(name()) :: boolean()
  def enabled?(name) when name in @names do
    switched_on?(name) and Enum.all?(Map.get(@requires, name, []), &enabled?/1)
  end

  defp switched_on?(name) do
    case :barkpark |> Application.get_env(__MODULE__, []) |> Keyword.get(name, true) do
      false -> false
      _ -> true
    end
  end

  @doc """
  The operator-facing sentence for a refusal because `name` is off. Names the
  switch that turned it off, including a required capability that is off.
  """
  @spec off_message(name()) :: String.t()
  def off_message(name) when name in @names do
    off = Enum.reject([name | Map.get(@requires, name, [])], &switched_on?/1)

    "the #{name} capability is off on this instance (switched off: " <>
      Enum.map_join(off, ", ", &Atom.to_string/1) <>
      "; set by config :barkpark, Barkpark.Capability or BARKPARK_CAPABILITIES_OFF)"
  end

  @doc """
  Parses the `BARKPARK_CAPABILITIES_OFF` value into config for this module.

  Unknown names raise instead of being ignored: a typo in an OFF list would
  otherwise leave the subsystem running while the operator believes it is off.
  """
  @spec parse_off_list(String.t()) :: keyword(boolean())
  def parse_off_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn raw ->
      case Enum.find(@names, &(Atom.to_string(&1) == raw)) do
        nil ->
          raise ArgumentError,
                "BARKPARK_CAPABILITIES_OFF names unknown capability #{inspect(raw)}; " <>
                  "known: #{Enum.map_join(@names, ",", &Atom.to_string/1)}"

        name ->
          {name, false}
      end
    end)
  end
end
