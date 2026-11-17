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

  A delivery that fails or exits after the flip reopens the ask (`reopen/2`), so
  it is pending again and a resend delivers it; the route answers 503. Only
  codex's `{:error, :unknown_approval}` keeps the flip: the ask is already gone
  upstream (the double-answer race), and a pending row nothing can answer
  would block the session for good.
  """

  import Ecto.Query, only: [where: 3, lock: 2]

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Message, Session}

  @type outcome :: :delivered | :noop | {:refused, String.t()} | {:error, term()}

  @doc """
  Flip a pending ask to `status` and run `deliver`; any other ask is not
  delivered. A nil `deliver` (no live runtime) only checks: the ask is never
  flipped, as before.
  """
  @spec settle(String.t(), String.t(), String.t(), (-> any()) | nil) :: outcome()
  def settle(session_id, request_id, _status, nil), do: check(session_id, request_id)

  def settle(session_id, request_id, status, deliver) when is_function(deliver, 0) do
    case StudioChat.update_approval_status(session_id, request_id, status) do
      {:ok, message} -> deliver(message, status, deliver)
      {:error, _not_pending} -> check(session_id, request_id)
    end
  end

  defp deliver(message, status, deliver) do
    case deliver.() do
      {:error, :unknown_approval} ->
        :delivered

      {:error, reason} ->
        reopen(message, status)
        {:error, reason}

      _ok ->
        :delivered
    end
  catch
    :exit, reason ->
      reopen(message, status)
      {:error, {:exit, reason}}

    kind, reason ->
      reopen(message, status)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Compare-and-set back to pending: only while the row still holds the answer
  # this request wrote. A cancel or another answer that landed since stands.
  # The counter and the blocked state are put back as the flip took them.
  defp reopen(%Message{id: id, session_id: session_id}, status) do
    Repo.transaction(fn ->
      stored =
        Message
        |> where([m], m.id == ^id)
        |> where([m], fragment("?->>'approval_status' = ?", m.metadata, ^status))
        |> lock("FOR UPDATE")
        |> Repo.one()

      if stored do
        meta = Map.put(stored.metadata, "approval_status", "pending")
        stored |> Ecto.Changeset.change(metadata: meta) |> Repo.update!()
        now = DateTime.utc_now()

        Session
        |> where([s], s.id == ^session_id)
        |> Repo.update_all(inc: [pending_approvals: 1], set: [updated_at: now])

        # Through the D80h choke point: corroborated by the count just restored.
        StudioChat.set_agent_state(session_id, "blocked", :ask, now)
      end
    end)
  end

  defp check(session_id, request_id) do
    case StudioChat.get_needs_you_message(session_id, request_id) do
      %{metadata: %{"approval_status" => "canceled"}} -> {:refused, "canceled"}
      _ -> :noop
    end
  end
end
