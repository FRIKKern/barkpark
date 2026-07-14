defmodule Barkpark.StudioChat.Runtime.Codex do
  @moduledoc "Managed Codex app-server implementation of the Studio Chat runtime contract."

  @behaviour Barkpark.StudioChat.Runtime.Adapter

  alias Barkpark.StudioChat.Probe
  alias Barkpark.StudioChat.Runtime.Capabilities
  alias Barkpark.StudioChat.Runtime.Codex.Readiness
  alias Barkpark.StudioChat.Runtime.Codex.Session

  @impl true
  def start(opts), do: open(Map.put(opts, :provider_session_id, nil))

  @impl true
  def resume(opts) do
    provider_session_id =
      Map.get(opts, :provider_session_id) ||
        get_in(opts, [:session_opts, :provider_session_id]) ||
        get_in(opts, [:session_opts, :session_id])

    open(Map.put(opts, :provider_session_id, provider_session_id))
  end

  @impl true
  def send_turn(runtime, content), do: Session.request(runtime, :send_turn, content)

  @impl true
  def steer(runtime, command), do: Session.request(runtime, :steer, command)

  @impl true
  def interrupt(runtime), do: Session.request(runtime, :interrupt, %{})

  @impl true
  def answer_approval(runtime, approval_id, decision) do
    Session.answer_approval(runtime, approval_id, decision)
  end

  @impl true
  def close(runtime), do: Session.close(runtime)

  @impl true
  def readiness(opts) do
    path = Map.get(opts, :binary)

    if is_binary(path) do
      Readiness.probe(path, opts)
    else
      Probe.probe(:codex)
    end
  end

  @impl true
  def capabilities, do: Capabilities.codex()

  def enabled? do
    binary = configured_binary()

    with {:ok, path} <- Readiness.resolve_binary(binary),
         {:ok, _version} <- Readiness.verify_version(path, 2_000) do
      true
    else
      _ -> false
    end
  end

  def worker_id(session_id) when is_binary(session_id), do: "codex-chat-#{session_id}"
  def worker_id(_), do: nil

  def task_hands(runtime), do: Session.task_hands(runtime)

  defp open(opts) do
    binary = Map.get(opts, :binary) || configured_binary()
    timeout = Map.get(opts, :timeout_ms, 15_000)

    with {:ok, path} <- Readiness.resolve_binary(binary),
         {:ok, _version} <- Readiness.verify_version(path, timeout) do
      Session.start(Map.put(opts, :binary, path))
    end
  end

  defp configured_binary do
    :barkpark
    |> Application.get_env(:codex_app_server, [])
    |> Keyword.get(:binary, "codex")
  end
end
