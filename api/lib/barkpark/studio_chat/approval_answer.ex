defmodule Barkpark.StudioChat.ApprovalAnswer do
  @moduledoc """
  Settles a `POST /v1/chat/sessions/:id/approval` answer against the stored ask
  before anything reaches the runtime (task-035d3495dae536cf).

  The route used to deliver first and flip the store second, with no check. An
  ask the server had already canceled (a newer lease's turn displaced it, or a
  teardown) still went to the host, reached the newer run as an unknown
  approval, and its close could end that run. Now:

      claim the pending ask (row lock, compare-and-set; commits at once)
        → deliver, holding no lock and no transaction
            ok   → flip pending → answer (`update_approval_status/3`)
            fail → drop the claim; the ask never left "pending"

    * pending and unclaimed: claimed, delivered, flipped (`:delivered`);
    * canceled: nothing delivered, and the route answers 409 (`{:refused, _}`);
    * already answered, unknown, or claimed by an answer in flight: nothing
      delivered, and the route keeps its 204 no-op (`:noop`, pinned in
      `chat_controller_test.exs`);
    * a delivery that fails or exits: `{:error, _}`, the route answers 503, and
      a resend delivers.

  The ask stays "pending" until its answer is delivered, so both server
  cancels, which touch only pending rows (`cancel_pending_approvals/1` and
  `DisplacedAsks` through `update_approval_status/4`), still cancel it during a
  delivery, and that cancel stands (rev26731's probes C7 and C2 on #26895).
  The claim is `metadata.answer_claimed_at`. It expires after 60 seconds, so a request process killed mid-delivery cannot block the ask,
  and after a delivery it stays on the row as the time the answer was sent.

  Codex's `{:error, :unknown_approval}` is the double-answer race: the ask is
  already gone upstream, so it counts as delivered and the ask is flipped.
  """

  import Ecto.Query, only: [where: 3, lock: 2]

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Message

  @claim "answer_claimed_at"
  @claim_ttl_s 60

  @type outcome :: :delivered | :noop | {:refused, String.t()} | {:error, term()}

  @doc """
  Claim a pending ask, run `deliver`, then flip it to `status`; any other ask
  is not delivered. A nil `deliver` (no live runtime) only checks: the ask is
  never claimed or flipped, as before.
  """
  @spec settle(String.t(), String.t(), String.t(), (-> any()) | nil) :: outcome()
  def settle(session_id, request_id, _status, nil), do: check(session_id, request_id)

  def settle(session_id, request_id, status, deliver) when is_function(deliver, 0) do
    case claim(session_id, request_id) do
      {:ok, claim} -> deliver(session_id, request_id, status, claim, deliver)
      :unclaimed -> check(session_id, request_id)
    end
  end

  defp deliver(session_id, request_id, status, claim, deliver) do
    case deliver.() do
      {:error, reason} when reason != :unknown_approval ->
        release(claim)
        {:error, reason}

      _ok_or_gone_upstream ->
        # A cancel that landed during the delivery wins: the flip is pending-only.
        _ = StudioChat.update_approval_status(session_id, request_id, status)
        :delivered
    end
  catch
    :exit, reason ->
      release(claim)
      {:error, {:exit, reason}}

    kind, reason ->
      release(claim)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Compare-and-set under the row lock: a pending ask with no claim, or with
  # one older than the TTL. The transaction ends before the delivery starts.
  defp claim(session_id, request_id) do
    with %Message{id: id} <- StudioChat.get_needs_you_message(session_id, request_id) do
      now = DateTime.utc_now()
      stale = DateTime.add(now, -@claim_ttl_s, :second)
      claim = DateTime.to_iso8601(now)

      Repo.transaction(fn ->
        Message
        |> where([m], m.id == ^id)
        |> where([m], fragment("?->>'approval_status' = 'pending'", m.metadata))
        |> where(
          [m],
          fragment(
            "(?->>?) IS NULL OR (?->>?)::timestamptz < ?",
            m.metadata,
            @claim,
            m.metadata,
            @claim,
            ^stale
          )
        )
        |> lock("FOR UPDATE")
        |> Repo.one()
        |> case do
          nil -> Repo.rollback(:unclaimed)
          row -> write!(row, Map.put(row.metadata, @claim, claim))
        end
      end)
      |> case do
        {:ok, _row} -> {:ok, {id, claim}}
        {:error, :unclaimed} -> :unclaimed
      end
    else
      nil -> :unclaimed
    end
  end

  # Drop this request's own claim. A stale takeover's newer claim, or any
  # status a cancel wrote meanwhile, is left as it is.
  defp release({id, claim}) do
    Repo.transaction(fn ->
      Message
      |> where([m], m.id == ^id)
      |> where([m], fragment("?->>? = ?", m.metadata, @claim, ^claim))
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil -> :ok
        row -> write!(row, Map.delete(row.metadata, @claim))
      end
    end)
  end

  defp write!(row, metadata),
    do: row |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

  defp check(session_id, request_id) do
    case StudioChat.get_needs_you_message(session_id, request_id) do
      %{metadata: %{"approval_status" => "canceled"}} -> {:refused, "canceled"}
      _ -> :noop
    end
  end
end
