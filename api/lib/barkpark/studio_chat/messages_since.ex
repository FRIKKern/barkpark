defmodule Barkpark.StudioChat.MessagesSince do
  @moduledoc """
  A session's messages with `seq > since`, filtered in SQL (task-cb021c3fefa4bef4).

  `GET /v1/chat/sessions/:id?since=` and the event stream's Last-Event-ID
  replay used to read EVERY message of the session and drop the old ones in
  memory. A client that asks for the session only — BarkBot checks up to 50
  sessions per page load with a past-the-end `?since=9223372036854775807` —
  paid for the whole transcript to get `messages: []`. Here `seq > since` is a
  SQL predicate on the `(session_id, seq)` unique index: a tail read loads only
  the tail, and that past-the-end read loads none.

  `since = nil` is the full read and goes straight to
  `StudioChat.list_messages/2`, unchanged. A `since` at or past 2_147_483_647
  answers `[]` without a query. `chat_messages.seq` is a 32-bit `integer`
  (migration 20260709120000, `add :seq, :integer`), so no row can be newer,
  and Postgrex refuses to encode a larger parameter for that column
  (`DBConnection.EncodeError`). `?since=` accepts up to the bigint max and the
  event stream's Last-Event-ID parse has no upper bound, so both reach here
  with such values; on the old in-memory filter they answered `[]`, and they
  still do.

  The scope gate is `StudioChat.list_messages/2`'s, restated: `:global` reads;
  a workspace reads only when `StudioChat.get_session/2` sees the session in
  that scope, else `[]`. There is no default scope and any other scope term is
  a `FunctionClauseError` (drafts.task-bb38ed88099c9723).
  """

  import Ecto.Query, only: [where: 3, order_by: 3]

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Message

  # The largest value `chat_messages.seq` (Postgres `integer`) can hold.
  @seq_max 2_147_483_647

  @spec list(String.t(), non_neg_integer() | nil, :global | binary()) :: [Message.t()]
  def list(session_id, nil, scope), do: StudioChat.list_messages(session_id, scope)

  def list(_session_id, since, scope)
      when is_integer(since) and since >= @seq_max and (scope == :global or is_binary(scope)),
      do: []

  def list(session_id, since, :global) when is_integer(since), do: read(session_id, since)

  def list(session_id, since, ws) when is_integer(since) and is_binary(ws) do
    if StudioChat.get_session(session_id, ws), do: read(session_id, since), else: []
  end

  defp read(session_id, since) do
    Message
    |> where([m], m.session_id == ^session_id and m.seq > ^since)
    |> order_by([m], asc: m.seq)
    |> Repo.all()
  end
end
