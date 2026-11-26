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
      a resend delivers;
    * a runtime that cannot be reached now (`deliverer/2` returns
      `{:error, _}`): nothing is claimed or sent, the route answers 503, and
      the ask stays pending;
    * nothing left to answer to (a nil `deliver`): the session's pending asks
      are canceled first, as Studio does on reopen (D11,
      task-dc4980982da790c9), and a pending ask is refused as canceled.

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

  alias Barkpark.ChatHosts
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Message, Recorder}

  @claim "answer_claimed_at"
  @claim_ttl_s 60
  @refused %{"cancel_reason" => "asking_run_gone"}

  @type outcome :: :delivered | :noop | {:refused, String.t()} | {:error, term()}

  @doc """
  The `deliver` for `settle/4`, from who can still answer the session's asks
  (task-dc4980982da790c9, rev26731 on #26937):

    * a Recorder hands over its runtime: a deliver that calls `send` with it;
    * a Recorder that does not answer (busy past the call timeout, or exiting),
      or no local Recorder while a host still holds the session's turn (a
      registered host's turn after a restart, still blocked on its ask):
      `{:error, _}`. The ask must stay pending, and a send brings a Recorder
      back to deliver it. "Holds the turn" is `ChatHosts.turn_held?/1`: an open
      lease inside the sweep's grace, or one the expiry sweep can still end
      (a heartbeat revives it until then);
    * no Recorder and no held turn: nil, so `settle/4` cancels (D11).
  """
  @spec deliverer(String.t(), (term() -> any())) :: (-> any()) | nil | {:error, term()}
  def deliverer(session_id, send) when is_function(send, 1) do
    case Recorder.whereis(session_id) do
      pid when is_pid(pid) ->
        case Recorder.session_pid(pid) do
          {:ok, runtime} -> fn -> send.(runtime) end
          {:error, reason} -> {:error, {:runtime_unavailable, reason}}
        end

      nil ->
        if ChatHosts.turn_held?(session_id),
          do: {:error, {:runtime_unavailable, :no_recorder}}
    end
  end

  @doc """
  Claim a pending ask, run `deliver`, then flip it to `status`; any other ask
  is not delivered. A nil `deliver` (nothing left to answer to) cancels the
  session's pending asks (D11), so the store never holds an answer nothing
  received. An `{:error, _}` from `deliverer/2` touches nothing.

  `extra` is merged into the row's metadata with the flip, and only with a
  delivered flip: a question's answer passes `%{"answers" => answers}`, so the
  stored row keeps what was chosen (task-70baa54b6bc7b54f).
  """
  @spec settle(String.t(), String.t(), String.t(), (-> any()) | nil | {:error, term()}, map()) ::
          outcome()
  def settle(session_id, request_id, status, deliver, extra \\ %{})

  def settle(_session_id, _request_id, _status, {:error, _} = unavailable, _extra),
    do: unavailable

  def settle(session_id, request_id, _status, nil, _extra) do
    StudioChat.cancel_pending_approvals(session_id)
    check(session_id, request_id)
  end

  def settle(session_id, request_id, status, deliver, extra)
      when is_function(deliver, 0) and is_map(extra) do
    case claim(session_id, request_id) do
      {:ok, claim} -> deliver(session_id, request_id, {status, extra}, claim, deliver)
      :unclaimed -> check(session_id, request_id)
    end
  end

  @doc """
  Studio's answer (`ChatLive.resolve_permission`), through `settle/5`, so a card
  a tab still shows as pending never delivers to an ask the store has canceled
  or answered (task-52de5429fbdcb68c). Studio ignores the delivery's result, as
  it always has. `decision` is what `deliver` hands the runtime: `{:deny, _}`
  stores "denied", anything else "allowed". A question row answered with
  `{:allow, %{"answers" => answers}}` also keeps `answers` on the row, as the
  HTTP answer does (task-48d523fa9c04c354). `{:ok, status}` when delivered and
  stored as `status`; otherwise `{:settled, stored}` with the stored terminal
  status, so a cancel that commits during the send shows as canceled
  (task-a759f535f818d2cb); and `:noop` while another answer is in flight.
  An ask with no stored row (no store session, or a lost Recorder write) is
  delivered as before, so its card never goes dead.
  """
  @spec resolve(String.t() | nil, String.t(), term(), (-> any())) ::
          {:ok, String.t()} | {:settled, String.t()} | :noop
  def resolve(session_id, request_id, decision, deliver) do
    status = if match?({:deny, _}, decision), do: "denied", else: "allowed"

    with true <- is_binary(session_id),
         %Message{} = ask <- StudioChat.get_needs_you_message(session_id, request_id) do
      send = fn -> {:ok, deliver.()} end
      sent = settle(session_id, request_id, status, send, answers_extra(ask, decision))

      case {sent, stored(session_id, request_id)} do
        {:delivered, {:settled, ^status}} -> {:ok, status}
        {_, stored} -> stored
      end
    else
      _ ->
        deliver.()
        {:ok, status}
    end
  end

  defp answers_extra(%Message{role: "question"}, {:allow, %{"answers" => answers}})
       when is_map(answers),
       do: %{"answers" => answers}

  defp answers_extra(_ask, _decision), do: %{}

  @doc """
  The host refused a delivered answer (task-746c02d760f26ce7): the ask was
  asked by a run that is no longer the session's active run on the host
  (`asked_lease_id`, internal/chathost/answer_lease.go), so the answer reached
  no one. `ask` is that ask's own row (`ChatHosts.RefusedAnswer` finds it from
  the answer's lease), never the newest row with its id: another run can ask
  under the same id. The row is canceled (`cancel_reason: "asking_run_gone"`)
  whether it already reads "allowed"/"denied" or is still pending, and live
  viewers flip its card. An ask already canceled keeps its reason and is not
  broadcast again. Returns `:canceled` or `:unchanged`.
  """
  @spec refused_by_host(String.t(), Message.t()) :: :canceled | :unchanged
  def refused_by_host(session_id, %Message{id: id, metadata: %{"request_id" => request_id}} = ask) do
    result =
      case ask.metadata["approval_status"] do
        "pending" -> cancel_pending(session_id, request_id, id)
        status when status in ~w(allowed denied) -> cancel_answered(id)
        _canceled -> {:error, :not_open}
      end

    case result do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Barkpark.PubSub,
          Barkpark.StudioChat.Recorder.topic(session_id),
          {:chat_permission_resolved, request_id, :canceled}
        )

        :canceled

      _ ->
        :unchanged
    end
  end

  # A pending ask is canceled through `update_approval_status/4` (its count
  # and blocked state), which takes the NEWEST pending row with the id. If that
  # is not this row, nothing is written.
  defp cancel_pending(session_id, request_id, id) do
    Repo.transaction(fn ->
      case StudioChat.update_approval_status(session_id, request_id, "canceled", @refused) do
        {:ok, %Message{id: ^id} = row} -> row
        _other_row -> Repo.rollback(:not_this_ask)
      end
    end)
  end

  # An answered ask flips to canceled under its row lock; the pending count
  # already dropped when it was answered, so it is not touched.
  defp cancel_answered(id) do
    Repo.transaction(fn ->
      Message
      |> where([m], m.id == ^id)
      |> where([m], fragment("?->>'approval_status' IN ('allowed', 'denied')", m.metadata))
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil ->
          Repo.rollback(:not_answered)

        row ->
          write!(
            row,
            row.metadata |> Map.merge(@refused) |> Map.put("approval_status", "canceled")
          )
      end
    end)
  end

  defp stored(session_id, request_id) do
    case StudioChat.get_needs_you_message(session_id, request_id) do
      %{metadata: %{"approval_status" => s}} when s in ~w(allowed denied canceled) ->
        {:settled, s}

      _in_flight ->
        :noop
    end
  end

  defp deliver(session_id, request_id, {status, extra}, claim, deliver) do
    case deliver.() do
      {:error, reason} when reason != :unknown_approval ->
        release(claim)
        {:error, reason}

      _ok_or_gone_upstream ->
        # A cancel that landed during the delivery wins: the flip is pending-only.
        _ = StudioChat.update_approval_status(session_id, request_id, status, extra)
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
