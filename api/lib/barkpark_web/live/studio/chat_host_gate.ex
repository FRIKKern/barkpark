defmodule BarkparkWeb.Studio.ChatHostGate do
  @moduledoc """
  The Studio chat tab's door to `BarkparkWeb.HostExecutionGate`
  (task-6ca882967fd95dda, task-ec484ce3ff311a3a).

  A tab gets a live Session pid two ways: it spawns one (`spawn_session/3`), or
  it co-views one whose runtime is already running (`load_stored_session/2`).
  A co-viewer never spawns, so the gate has to sit on the ACTS that drive the
  runtime, not on how the pid was obtained: every turn and every allow, the
  same checks `POST /v1/chat/sessions/:id/messages` and `/approval` make.

  A deny always passes (the HTTP door lets a deny through too): it stops a host
  turn, it never lets one act.
  """

  alias Barkpark.StudioChat
  alias BarkparkWeb.HostExecutionGate

  @doc """
  `:ok`, or `{:error, :host_execution_not_permitted}` when the tab's principal
  may not take `act` on its session. `act` is `:turn` or a permission decision
  (`:allow | {:allow, input} | {:deny, message}`).

  The session is the stored row when there is one (its provider, target and
  owner are what the runtime was started from), else the tab's own assigns.
  """
  @spec authorize(map(), term()) :: :ok | {:error, :host_execution_not_permitted}
  def authorize(_assigns, {:deny, _message}), do: :ok

  def authorize(assigns, _act),
    do: HostExecutionGate.authorize_turn(principal(assigns), subject(assigns))

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
