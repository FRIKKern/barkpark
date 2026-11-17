defmodule Barkpark.StudioChat.ApprovalAnswer do
  @moduledoc """
  Settles a `POST /v1/chat/sessions/:id/approval` answer against the stored ask
  before anything reaches the runtime (task-035d3495dae536cf).

  The route used to deliver first and flip the store second. An ask the server
  had already canceled (a newer lease's turn displaced it, or a teardown) still
  went to the host, reached the newer run as an unknown approval, and its close
  could end that run. The store now decides, under the row lock that
  `StudioChat.update_approval_status/3` takes:

    * pending: flipped to the answer, then delivered (`:delivered`);
    * canceled: nothing delivered, and the route answers 409 (`{:refused, _}`);
    * already answered, or no such ask: nothing delivered, and the route keeps
      its 204 no-op (`:noop`, pinned in `chat_controller_test.exs`).
  """

  alias Barkpark.StudioChat

  @type outcome :: :delivered | :noop | {:refused, String.t()}

  @doc """
  Flip a pending ask to `status` and run `deliver`; any other ask is not
  delivered. A nil `deliver` (no live runtime) only checks: the ask is never
  flipped, as before.
  """
  @spec settle(String.t(), String.t(), String.t(), (-> any()) | nil) :: outcome()
  def settle(session_id, request_id, _status, nil), do: check(session_id, request_id)

  def settle(session_id, request_id, status, deliver) when is_function(deliver, 0) do
    case StudioChat.update_approval_status(session_id, request_id, status) do
      {:ok, _message} ->
        _ = deliver.()
        :delivered

      {:error, _not_pending} ->
        check(session_id, request_id)
    end
  end

  defp check(session_id, request_id) do
    case StudioChat.get_needs_you_message(session_id, request_id) do
      %{metadata: %{"approval_status" => "canceled"}} -> {:refused, "canceled"}
      _ -> :noop
    end
  end
end
