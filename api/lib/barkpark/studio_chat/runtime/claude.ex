defmodule Barkpark.StudioChat.Runtime.Claude do
  @moduledoc "Claude implementation of the provider-neutral Studio Chat runtime contract."

  @behaviour Barkpark.StudioChat.Runtime.Adapter

  alias Barkpark.StudioChat.Probe
  alias Barkpark.StudioChat.Runtime.Capabilities
  alias BarkparkWeb.Studio.ClaudeChat

  @impl true
  def start(opts), do: start_session(opts, false)

  @impl true
  def resume(opts), do: start_session(opts, true)

  @impl true
  def send_turn(session, content), do: ClaudeChat.send_message(session, content)

  @impl true
  def steer(session, %{mode: mode}), do: ClaudeChat.set_permission_mode(session, mode)
  def steer(session, %{model: model}), do: ClaudeChat.set_model(session, model)
  def steer(_session, command), do: {:error, {:unsupported_steer, command}}

  @impl true
  def interrupt(session), do: ClaudeChat.interrupt(session)

  @impl true
  def answer_approval(session, request_id, decision) do
    ClaudeChat.respond_permission(session, request_id, decision)
  end

  @impl true
  def close(session), do: ClaudeChat.close(session)

  @impl true
  def readiness(_opts), do: Probe.probe(:claude)

  @impl true
  def capabilities, do: Capabilities.claude()

  def enabled?, do: ClaudeChat.enabled?()
  def normalize_mode(value), do: ClaudeChat.normalize_mode(value)
  def normalize_model(value), do: ClaudeChat.normalize_model(value)
  def normalize_effort(value), do: ClaudeChat.normalize_effort(value)
  def auth_failure?(event), do: ClaudeChat.auth_failure?(event)
  def result_success?(event), do: ClaudeChat.result_success?(event)
  def worker_id(session_id), do: ClaudeChat.worker_id(session_id)
  def task_hands(session), do: ClaudeChat.task_hands(session)
  def initialize(session), do: ClaudeChat.initialize(session)
  def adopt_sink(session, sink), do: ClaudeChat.adopt_sink(session, sink)
  def auto_approve?(%{tool_name: tool_name}), do: ClaudeChat.mcp_auto_approved?(tool_name)
  def auto_approve?(_), do: false
  def cwd, do: ClaudeChat.cwd()
  def tool_name(name), do: ClaudeChat.mcp_tool_name(name)

  defp start_session(opts, resume?) do
    # Thread the workspace principal the recorder already delivers (recorder.ex:139
    # → runtime_opts top-level) into session_opts — today it is silently dropped.
    # The cloud execution profile hard-fails on a nil/:global workspace (D110); the
    # self-hosted path simply ignores the extra key, so this is inert there.
    session_opts =
      opts
      |> Map.get(:session_opts, %{})
      |> Map.put(:resume, resume?)
      |> Map.put(:workspace_id, Map.get(opts, :workspace_id))
      # The session-scoped Cloud sandbox binding (charter D137/D139), un-dropped
      # exactly like :workspace_id above (D110). The recorder loads it from the
      # Session row; here it reaches ClaudeChat.command/2's session_opts, where the
      # :cloud profile's cloud_build_args (W14-1) reads it to `--resume` the same
      # sandbox. The self-hosted build_args ignore the key — inert cargo there.
      |> Map.put(:cloud_sandbox_id, Map.get(opts, :cloud_sandbox_id))

    ClaudeChat.start_session(%{
      sink: Map.fetch!(opts, :sink),
      mode: Map.get(opts, :mode, "plan"),
      session_opts: session_opts
    })
  end
end
