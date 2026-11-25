defmodule BarkparkWeb.ChatHostRefusal do
  @moduledoc """
  The chat HTTP 403 for a turn `BarkparkWeb.HostExecutionGate.authorize_turn/2`
  refuses: the reason's code and sentence (`HostExecutionGate.refusal/1`).

  A managed turn on the INSTANCE host is the instance owner's alone
  (task-6ca882967fd95dda); a registered host's turn is a workspace owner's or
  admin's (task-7efaf895e8bc88e4). Permanent, so never a retryable 503.
  """

  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.HostExecutionGate

  @doc "Answer `conn` with the 403 for `reason`, one of `HostExecutionGate.refusals/0`."
  @spec emit(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def emit(conn, reason) do
    {code, message} = HostExecutionGate.refusal(reason)
    ErrorResponse.emit_custom(conn, 403, code, message)
  end
end
