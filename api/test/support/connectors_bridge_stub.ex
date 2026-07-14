defmodule Barkpark.Test.ConnectorsBridgeStub do
  @moduledoc """
  A scriptable `Barkpark.Connectors.Bridge` for the Studio connect-loop tests.

  The REAL bridge is a Node process. What this stub exists to prove is the half
  that is ours and that no Node test can see: that Studio mints the right token
  with the right label, ships it over the seam, REVOKES it when the bridge says
  no, and never renders a Connected card without an install row.

  It records every call (so a test can assert the ticket and the raw token that
  actually crossed the wire) and replays a scripted reply. The seam is swapped in
  via `config :barkpark, Barkpark.Connectors, bridge: __MODULE__`.

  It also WRITES the install row on a successful `connect/3` — the real bridge's
  `upsertInstall` — because otherwise the LiveView's read-back would find nothing
  and the "card flips to Connected" assertion would be testing a lie.
  """

  @behaviour Barkpark.Connectors.Bridge

  alias Barkpark.Repo

  @agent __MODULE__

  @doc """
  Start the stub for one test. `script` maps a call to its reply.

  It STOPS any previous agent and WAITS for the name to be released first. The
  agent is linked to the test process, so the one from the previous test is
  already dying when the next test starts — reusing it (`{:error,
  {:already_started, pid}}`) produced a genuine, low-frequency flake: the next
  `Agent.get` would hit a process that exits mid-call. Kill-and-wait makes the
  handoff deterministic instead of a race.
  """
  def start(script) when is_map(script) do
    stop_existing()
    {:ok, pid} = Agent.start_link(fn -> %{script: script, calls: []} end, name: @agent)
    pid
  end

  defp stop_existing do
    case Process.whereis(@agent) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        # The owner may already be gone — a stop/exit on a dying process must not
        # take the TEST down with it.
        try do
          Agent.stop(pid, :normal, 500)
        catch
          :exit, _ -> Process.exit(pid, :kill)
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> Process.demonitor(ref, [:flush])
        end
    end
  end

  @doc "Every call the LiveView made, oldest first."
  def calls, do: Agent.get(@agent, & &1.calls) |> Enum.reverse()

  @impl true
  def validate(ticket, credential) do
    record({:validate, ticket, credential})
    reply(:validate)
  end

  @impl true
  def connect(ticket, credential, chat_token) do
    record({:connect, ticket, credential, chat_token})

    case reply(:connect) do
      {:ok, %{install_key: key}} = ok ->
        # The real bridge writes the row. Without this the read-back is vacuous.
        upsert(script_workspace(), script_provider(), key)
        ok

      other ->
        other
    end
  end

  @impl true
  def disconnect(ticket, install_key) do
    record({:disconnect, ticket, install_key})

    case reply(:disconnect) do
      {:ok, _} = ok ->
        Repo.query!(
          "DELETE FROM chat_bridge.connector_installs WHERE provider = $1 AND install_key = $2",
          [script_provider(), install_key]
        )

        ok

      other ->
        other
    end
  end

  defp upsert(ws_id, provider, install_key) do
    Repo.query!(
      """
      INSERT INTO chat_bridge.connector_installs
        (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
      VALUES ($1, $2, $3, 'SEALED-CREDENTIAL', 'SEALED-CHAT-TOKEN', now())
      ON CONFLICT (provider, install_key) DO UPDATE
        SET workspace_id = EXCLUDED.workspace_id
      """,
      [provider, install_key, ws_id]
    )
  end

  defp record(call), do: Agent.update(@agent, &%{&1 | calls: [call | &1.calls]})

  defp reply(key) do
    Agent.get(@agent, &Map.fetch!(&1.script, key))
  end

  defp script_workspace, do: Agent.get(@agent, &Map.fetch!(&1.script, :workspace_id))
  defp script_provider, do: Agent.get(@agent, &Map.get(&1.script, :provider, "telegram"))
end
