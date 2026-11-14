defmodule BarkparkWeb.Studio.ChatHostGate do
  @moduledoc """
  The Studio chat tab's door to `BarkparkWeb.HostExecutionGate`
  (task-6ca882967fd95dda, task-ec484ce3ff311a3a).

  A tab gets a live Session pid two ways: it spawns one (`spawn_session/3`), or
  it co-views one whose runtime is already running (`load_stored_session/2`).
  A co-viewer never spawns, so the gate has to sit on the ACTS that drive the
  runtime, not on how the pid was obtained: every turn and every allow, the
  same checks `POST /v1/chat/sessions/:id/messages` and `/approval` make, and
  every change of the session's permission mode or model
  (task-14e61a60450c4678), live or saved: the next spawn starts from the row's
  mode and model, so writing them while the runtime is offline is a host act
  too (task-242dea9cceb7dd7e). The check keys on the session, never on whether
  this tab holds a pid: a tab that opened offline never learns the pid of a
  runtime that came up elsewhere.

  A deny always passes (the HTTP door lets a deny through too): it stops a host
  turn, it never lets one act. A steer to a stricter mode does NOT pass: a deny
  only answers an ask the runtime raised, a steer is an act of its own, and
  modes have no order across providers (a model switch has no direction).
  """

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Runtime
  alias BarkparkWeb.HostExecutionGate

  @doc """
  `:ok`, or `{:error, :host_execution_not_permitted}` when the tab's principal
  may not take `act` on its session. `act` is `:turn`, `:steer` (a mode or model
  change, steered live or saved to the row; a brand-new tab with no row and no
  pid passes: it holds the choice in its assigns, and the row that would carry
  it is created only past `create_session/3`) or a permission decision
  (`:allow | {:allow, input} | {:deny, message}`).

  The session is the stored row when there is one (its provider, target and
  owner are what the runtime was started from), else the tab's own assigns.
  """
  @spec authorize(map(), term()) :: :ok | {:error, :host_execution_not_permitted}
  def authorize(_assigns, {:deny, _message}), do: :ok

  def authorize(assigns, act) do
    if act == :steer and is_nil(assigns[:session]) and is_nil(assigns[:store_session_id]),
      do: :ok,
      else: HostExecutionGate.authorize_turn(principal(assigns), subject(assigns))
  end

  @doc """
  Create the row a brand-new tab's first send needs, in `scope`, only when the
  spawn that follows may run (task-7321bf17168e60ff). The row takes the tab's
  mode, and every later spawn on it starts from that mode, whoever takes the
  turn: a principal the spawn would refuse must leave no row for the
  operator's next turn to spawn from.
  """
  @spec create_session(map(), Ecto.UUID.t(), {:workspace, binary()} | :global) ::
          {:ok, StudioChat.Session.t()} | {:error, term()}
  def create_session(assigns, id, scope) do
    owner =
      case scope do
        {:workspace, ws_id} -> ws_id
        :global -> nil
      end

    with :ok <- authorize_spawn(assigns, %{owner_workspace_id: owner}) do
      StudioChat.create_session(
        %{
          id: id,
          provider: assigns.provider,
          execution_target: assigns.execution_target,
          execution_host_id: assigns.execution_host_id,
          cwd: Runtime.cwd(assigns.provider),
          mode: assigns.mode
        },
        scope
      )
    end
  end

  @doc """
  The spawn-time check: `store_session` is the row the spawn is for (or nil
  for a row the tab could not load), the provider and target are the tab's.
  """
  @spec authorize_spawn(map(), map() | nil) :: :ok | {:error, :host_execution_not_permitted}
  def authorize_spawn(assigns, store_session) do
    HostExecutionGate.authorize_turn(principal(assigns), %{
      provider: assigns[:provider],
      execution_target: assigns[:execution_target],
      owner_workspace_id: store_session && store_session.owner_workspace_id
    })
  end

  defp principal(assigns), do: assigns[:api_token] || assigns[:current_user]

  defp subject(assigns) do
    case assigns[:store_session_id] && StudioChat.get_session(assigns[:store_session_id], :global) do
      %StudioChat.Session{} = row ->
        row

      _ ->
        %{
          provider: assigns[:provider],
          execution_target: assigns[:execution_target],
          owner_workspace_id: nil
        }
    end
  end
end
