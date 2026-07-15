defmodule Barkpark.StudioChat.Runtime.CapabilitiesTest do
  # Pure struct — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.Runtime.Capabilities
  alias Barkpark.StudioChat.Session, as: ChatSession
  alias BarkparkWeb.Studio.ClaudeChat

  describe "claude/0" do
    test "carries every per-feature field the wave-12 matrix promises" do
      c = Capabilities.claude()

      assert %Capabilities{provider: :claude} = c

      # per-feature fields present and typed as the contract declares
      assert c.thinking == :text
      assert c.plan == :native_gate
      assert c.agent_rail == :full_tree
      assert c.slash_commands == true
      assert c.mode_switch == true
      assert c.images == true
      assert c.mcp_tools == true
      assert c.user_input == true
      assert c.todo_write == true
      # no message-granular rewind UI ships yet (scc-w12-fork-probe writes the verdict)
      assert c.rewind == false
    end

    test "the vocab lists mirror the runtime's OWN source of truth — never a drifting copy" do
      c = Capabilities.claude()

      # If any of these three sources changes vocabulary, this test fails and the
      # matrix must be updated in lock-step. That is the anti-drift contract.
      assert c.modes == ChatSession.modes()
      assert c.models == ClaudeChat.models()
      assert c.efforts == ClaudeChat.efforts()
    end

    test "danger_mode is the one gate-removing mode, and it is a real member of modes" do
      c = Capabilities.claude()
      assert c.danger_mode == "bypassPermissions"
      assert c.danger_mode in c.modes
    end
  end

  describe "agent_spawn_names/1 (the divergence knowledge chat_tool_renderer sources)" do
    test "is exactly the Task/Agent set chat_tool_renderer's @spawn_names now reads" do
      assert Capabilities.agent_spawn_names(Capabilities.claude()) == ~w(Task Agent)
    end

    test "the renderer's compile-time @spawn_names IS this value (no-tax sourcing)" do
      # spawn?/2 dispatches on the sourced names; both known forms classify as spawns.
      assert BarkparkWeb.Studio.ChatToolRenderer.spawn?("Task", nil)
      assert BarkparkWeb.Studio.ChatToolRenderer.spawn?("Agent", nil)
      refute BarkparkWeb.Studio.ChatToolRenderer.spawn?("Bash", nil)
    end
  end

  describe "codex/0 (schema-backed managed app-server)" do
    test "is a codex-tagged matrix distinct from claude" do
      c = Capabilities.codex()
      assert %Capabilities{provider: :codex} = c
      refute c.provider == Capabilities.claude().provider
    end

    test "advertises only schema-backed surfaces and never pretends Claude-only controls" do
      c = Capabilities.codex()

      # Empty vocab lists (no modes/models/efforts offered).
      assert c.modes == []
      assert c.models == []
      assert c.efforts == []
      assert c.danger_mode == nil
      assert c.agent_spawn_names == []

      # Enum fields at their absent tier.
      assert c.thinking == :text
      assert c.plan == :simulated
      assert c.agent_rail == :rows

      # Boolean feature flags all false.
      assert c.slash_commands == false
      assert c.mode_switch == false
      assert c.rewind == false
      assert c.images == true
      assert c.mcp_tools == true
      assert c.todo_write == false
      assert c.user_input == false
    end

    test "agent_spawn_names/1 reads the (empty) codex set without special-casing" do
      assert Capabilities.agent_spawn_names(Capabilities.codex()) == []
    end
  end

  describe "struct discipline" do
    test "provider is enforced — a matrix without a provider is a bug, not a default" do
      assert_raise ArgumentError, fn -> struct!(Capabilities, %{}) end
    end
  end
end
