defmodule Barkpark.StudioChat.HostExecution do
  @moduledoc """
  Which chat turns run ON THE INSTANCE HOST, and which sessions may
  (task-6ca882967fd95dda).

  A `managed` chat session under the `:self_hosted` execution profile (the
  default) runs the host `claude` binary — and a `codex` session always runs
  the host `codex` binary — as the barkpark service user, with no sandbox:
  `CloudPolicy`'s belts apply only under `:cloud`, and its moduledoc says
  self-hosted grants full host trust. That trust is right for the INSTANCE
  OWNER. It was also reachable from a tenant: sign up, create a workspace (you
  own it), mint its chat token, open a managed session, send a shell prompt,
  approve it. The service user reads the instance's `.env` — every tenant's
  data.

  This NARROWS the recorded design (connectors D205: the per-workspace profile
  wins both ways); it does not overturn it. Host execution needs BOTH:

    * a session owned by the DEFAULT workspace (the instance owner's) or an
      instance-global (`nil`-owned) one — `workspace_may_host_exec?/1`, the
      backstop `Runtime.open/2` applies to every managed spawn; and
    * an instance principal at the door — `BarkparkWeb.HostExecutionGate`.

  `:cloud` execution (sandboxed) and `registered_host` sessions (a machine the
  workspace enrolled itself) are untouched: tenants keep chat; they lose the
  instance host.
  """

  alias Barkpark.StudioChat.Provider.Claude
  alias Barkpark.Tenancy

  @reason "host_execution_not_permitted"

  @doc "The machine reason every refusal carries."
  def reason, do: @reason

  @doc "The human sentence every refusal carries."
  def message do
    "Running chat on this instance's own host is reserved for the instance owner " <>
      "(the platform operator, or an owner/admin of the Default workspace when no operator " <>
      "allowlist is set). Switch this workspace's chat to the cloud execution profile, " <>
      "or use a registered host."
  end

  @doc """
  True when a session owned by `workspace_id` may execute on the host at all —
  the runtime backstop, independent of who asks.
  """
  @spec workspace_may_host_exec?(term()) :: boolean()
  def workspace_may_host_exec?(nil), do: true
  def workspace_may_host_exec?(ws_id) when is_binary(ws_id), do: ws_id == default_workspace_id()
  def workspace_may_host_exec?(_), do: false

  @doc """
  True when a managed turn of `provider` for a session owned by `workspace_id`
  would run ON THE INSTANCE HOST: a `codex` turn always does; a `claude` turn
  does under the `:self_hosted` profile effective for that workspace.
  """
  @spec host_exec?(term(), term()) :: boolean()
  def host_exec?(provider, workspace_id) do
    case to_string(provider) do
      "claude" ->
        opts = Claude.resolve_workspace_execution_profile(%{workspace_id: workspace_id})
        Claude.execution_profile(opts) == :self_hosted

      _host_local ->
        true
    end
  end

  defp default_workspace_id do
    case Tenancy.get_default_workspace() do
      %{id: id} -> id
      _ -> nil
    end
  end
end
