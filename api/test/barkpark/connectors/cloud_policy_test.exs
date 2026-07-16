defmodule Barkpark.Connectors.CloudPolicyTest do
  @moduledoc """
  The :cloud execution profile's security posture, owned by
  `Barkpark.Connectors.CloudPolicy` (Connectors D116/D117/D118/D120 — the D24
  permission reversal at the POLICY layer).

  Four proof obligations, each proven at the layer it lives:

    1. **Knob 1 — the mode clamp** is a VALIDITY clamp (member verbatim, anything
       else including `bypassPermissions` → `"plan"`), and its valid set is exactly
       the CLI's modes minus bypass (no-drift vs `ClaudeChat.modes()`).
    2. **Knob 2 — the deny belts** are ONE list: the `--disallowedTools` set and
       the `--settings` deny JSON decode to the SAME tools (proven here at the
       source; the argv-vs-settings no-drift is pinned in `claude_chat_test.exs`).
    3. **Knob 3 — the policy half** — `connector_tool_providers/1` reads the real
       cross-schema `chat_bridge.connector_installs` (needs live Postgres) and
       returns ONLY tool-direction installs.

  The clamp is NEVER documented as tool confinement, and no live host-denial is
  faked — that observation rides `connectors-hg-live-isolated-cloud-turn`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Connectors.CloudPolicy
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ClaudeChat

  describe "cloud_permission_mode/1 — knob 1 validity clamp (D116)" do
    test "every Cloud-valid mode passes through verbatim" do
      for mode <- CloudPolicy.cloud_modes() do
        assert CloudPolicy.cloud_permission_mode(mode) == mode
      end
    end

    test "bypassPermissions clamps to plan — the reversal, not a pass-through" do
      assert CloudPolicy.cloud_permission_mode("bypassPermissions") == "plan"
    end

    test "an unknown/garbage/empty mode clamps to plan (fail-closed)" do
      for bad <- ["nonsense", "", "DROP TABLE", "default", nil, :plan, 42] do
        assert CloudPolicy.cloud_permission_mode(bad) == "plan"
      end
    end

    test "bypassPermissions is NOT a member of the Cloud-valid set" do
      refute "bypassPermissions" in CloudPolicy.cloud_modes()
    end

    test "NO-DRIFT — cloud_modes/0 equals ClaudeChat.modes() minus bypassPermissions" do
      assert CloudPolicy.cloud_modes() == ClaudeChat.modes() -- ["bypassPermissions"]
    end
  end

  describe "the deny belts — knob 2 (D117)" do
    test "cloud_disallowed_tools/0 is the host-FS/exec/network built-in set" do
      assert CloudPolicy.cloud_disallowed_tools() ==
               ~w(Bash Edit Write Read NotebookEdit WebFetch WebSearch Task)
    end

    test "settings_deny_json/0 is valid JSON decoding to permissions.deny == the deny list" do
      decoded = Jason.decode!(CloudPolicy.settings_deny_json())
      assert decoded == %{"permissions" => %{"deny" => CloudPolicy.cloud_disallowed_tools()}}
    end

    test "NO-DRIFT at the source — the settings deny list IS cloud_disallowed_tools/0" do
      deny = Jason.decode!(CloudPolicy.settings_deny_json())["permissions"]["deny"]
      assert deny == CloudPolicy.cloud_disallowed_tools()
    end
  end

  describe "connector_tool_providers/1 — knob 3 policy half (D118)" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "cloud-policy-ws", name: "Cloud Policy WS"})
      {:ok, ws: ws}
    end

    # The bridge is the only WRITER in production; tests write raw SQL (no Elixir
    # write path exists — adding one forks ownership of the table).
    defp insert_install(provider, key, ws_id) do
      Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ($1, $2, $3, $4, $5, now())
        """,
        [provider, key, ws_id, "SEALED-CREDENTIAL-BLOB", "SEALED-CHAT-TOKEN-BLOB"]
      )
    end

    test "returns ONLY tool-direction installs, filtering channel installs out", %{ws: ws} do
      # github/linear are direction: :tool; telegram/discord are :channel.
      insert_install("github", "octocat/repo", ws.id)
      insert_install("telegram", "111:aaa", ws.id)
      insert_install("discord", "999888777", ws.id)

      providers =
        ws
        |> CloudPolicy.connector_tool_providers()
        |> Enum.map(& &1.provider)

      assert providers == ["github"]
    end

    test "a workspace with only channel installs yields no tool providers", %{ws: ws} do
      insert_install("telegram", "111:aaa", ws.id)

      assert CloudPolicy.connector_tool_providers(ws) == []
    end

    test "a workspace with no installs yields []", %{ws: ws} do
      assert CloudPolicy.connector_tool_providers(ws) == []
    end

    test "a garbage/nil workspace inherits the fail-safe [] (never a CastError 500)" do
      assert CloudPolicy.connector_tool_providers("not-a-uuid") == []
      assert CloudPolicy.connector_tool_providers(nil) == []
    end
  end
end
