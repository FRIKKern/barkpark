defmodule Barkpark.CapabilityTest do
  @moduledoc """
  task-2f59ba23bcad333e: Studio Chat, CycleFleet and EpicFleet are switched by
  `Barkpark.Capability`, and the Studio Chat processes start from
  `Barkpark.Capability.Supervisor` only when Studio Chat is enabled.

  CycleFleet and EpicFleet are database ledgers with no processes, so their
  switch is proved at the router (`BarkparkWeb.CapabilityGateTest`).

  `async: false` + `on_exit` restore: the capability config is node-global.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Capability
  alias Barkpark.Capability.Supervisor, as: CapabilitySupervisor

  @check_id :studio_chat_titles_endpoint_boot_check

  setup do
    previous = Application.fetch_env(:barkpark, Capability)
    previous_url = Application.fetch_env(:barkpark, :anthropic_api_url)

    on_exit(fn ->
      restore(Capability, previous)
      restore(:anthropic_api_url, previous_url)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:barkpark, key, value)
  defp restore(key, :error), do: Application.delete_env(:barkpark, key)

  defp put_capabilities(kw), do: Application.put_env(:barkpark, Capability, kw)

  defp child_key(%{id: id}), do: id
  defp child_key(mod) when is_atom(mod), do: mod

  describe "enabled?/1" do
    test "every capability is on when nothing is configured (existing boxes unchanged)" do
      Application.delete_env(:barkpark, Capability)

      for name <- [:studio_chat, :cycle_fleet, :epic_fleet] do
        assert Capability.enabled?(name), "#{name} should default ON"
      end
    end

    test "a false entry turns exactly that capability off" do
      put_capabilities(studio_chat: false)

      refute Capability.enabled?(:studio_chat)
      assert Capability.enabled?(:cycle_fleet)
      assert Capability.enabled?(:epic_fleet)
    end

    test "cycle_fleet requires epic_fleet" do
      put_capabilities(epic_fleet: false)

      refute Capability.enabled?(:epic_fleet)
      refute Capability.enabled?(:cycle_fleet)
      assert Capability.enabled?(:studio_chat)
    end

    test "an unknown name is a programming error, not a silent false" do
      assert_raise FunctionClauseError, fn -> Capability.enabled?(:sheets) end
    end
  end

  describe "off_message/1" do
    test "names the switch that is off, including a required capability" do
      put_capabilities(epic_fleet: false)

      assert Capability.off_message(:cycle_fleet) =~ "the cycle_fleet capability is off"
      assert Capability.off_message(:cycle_fleet) =~ "switched off: epic_fleet"
      assert Capability.off_message(:epic_fleet) =~ "switched off: epic_fleet"
    end
  end

  describe "parse_off_list/1 (BARKPARK_CAPABILITIES_OFF)" do
    test "lists the named capabilities as off" do
      assert Capability.parse_off_list("studio_chat, cycle_fleet") ==
               [studio_chat: false, cycle_fleet: false]

      assert Capability.parse_off_list("") == []
    end

    test "an unknown name refuses instead of leaving the subsystem on" do
      assert_raise ArgumentError, ~r/unknown capability "studio_caht"/, fn ->
        Capability.parse_off_list("studio_caht")
      end
    end
  end

  describe "Barkpark.Capability.Supervisor children" do
    test "Studio Chat ON: the title check and the chat tier are children" do
      put_capabilities(studio_chat: true)

      assert Enum.map(CapabilitySupervisor.children(), &child_key/1) ==
               [@check_id, Barkpark.StudioChat.Supervisor]
    end

    test "Studio Chat OFF: no children at all" do
      put_capabilities(studio_chat: false)

      assert CapabilitySupervisor.children() == []
    end

    test "OFF, started for real: the tier starts and holds no process" do
      put_capabilities(studio_chat: false)

      {:ok, sup} = Supervisor.start_link(CapabilitySupervisor.children(), strategy: :one_for_one)
      assert Supervisor.which_children(sup) == []
      Supervisor.stop(sup)
    end

    test "OFF: a malformed ANTHROPIC_API_URL is not checked, because nothing reads it" do
      put_capabilities(studio_chat: false)
      Application.put_env(:barkpark, :anthropic_api_url, "gateway.internal/v1/messages")

      assert {:ok, sup} =
               Supervisor.start_link(CapabilitySupervisor.children(), strategy: :one_for_one)

      Supervisor.stop(sup)
    end

    test "ON: a malformed ANTHROPIC_API_URL refuses the tier, i.e. the boot" do
      put_capabilities(studio_chat: true)
      Application.put_env(:barkpark, :anthropic_api_url, "gateway.internal/v1/messages")

      check = Enum.find(CapabilitySupervisor.children(), &match?(%{id: @check_id}, &1))

      assert_raise ArgumentError, ~r/invalid Anthropic API URL/, fn ->
        CapabilitySupervisor.start_titles_endpoint_check()
      end

      Process.flag(:trap_exit, true)
      assert {:error, _reason} = Supervisor.start_link([check], strategy: :one_for_one)
    end

    test "ON: a valid URL passes the check and leaves no process behind" do
      Application.put_env(:barkpark, :anthropic_api_url, "https://gateway.internal/v1/messages")

      assert CapabilitySupervisor.start_titles_endpoint_check() == :ignore
    end
  end

  describe "the booted application (test env leaves every capability ON)" do
    test "Studio Chat runs under the capability supervisor, which runs under the app" do
      top = Supervisor.which_children(Barkpark.Supervisor)

      assert Enum.any?(
               top,
               &match?({Barkpark.Capability.Supervisor, pid, :supervisor, _} when is_pid(pid), &1)
             )

      chat_pid = Process.whereis(Barkpark.StudioChat.Supervisor)
      assert is_pid(chat_pid)

      assert {Barkpark.StudioChat.Supervisor, ^chat_pid, :supervisor, _} =
               List.keyfind(
                 Supervisor.which_children(Barkpark.Capability.Supervisor),
                 Barkpark.StudioChat.Supervisor,
                 0
               )
    end
  end
end
