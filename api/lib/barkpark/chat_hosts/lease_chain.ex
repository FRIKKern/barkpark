defmodule Barkpark.ChatHosts.LeaseChain do
  @moduledoc """
  What a resent turn does with a lease its `command_key` already holds
  (task-3c949e2977c56597).

  A chat send under an Idempotency-Key leases its turn under that key's hash,
  so a resend after a lost answer meets the first lease (the unique
  `(host_id, command_key)`) instead of making a second one. The lease is a
  chain of links: `<key>`, `<key>:2`, `<key>:3`, … A resend looks at the
  newest link:

    * the server ended it as NOT SENT, before any host event (the queue did not
      take it, the row could not be stored, the host can no longer serve it):
      the turn never ran, so the resend makes the next link and enqueues it;
    * anything else (still leased or running, run to completion, cancelled,
      expired with the outcome unknown): the turn is that link's. Nothing is
      leased again; a link no host has started goes back on the in-memory
      queue, which a restart empties (`ChatHosts.lease_and_enqueue/3`).

  An expired lease is not "not sent": a host may have taken it from the queue
  without posting an event, so running it again could run it twice. The
  session shows the expiry; a new send under a new key runs it again.
  """

  import Ecto.Query

  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo

  # The server closes whose message says the turn "was not sent": written at
  # cursor 1, before any host event (`Context.end_server_turn/2`,
  # `Context.end_unservable_turn/2`). A closed list: a close missing here keeps
  # the old link (no second run); one wrongly here would run a turn twice.
  @unsent_closes ~w(
    server:turn_not_stored
    server:host_queue_unavailable
    server:host_cannot_use_bot_folder
    server:host_cannot_receive_attachments
  )

  @doc """
  The newest link for `key` on `host_id`, and what a resend does with it:
  `{:reuse, lease}` or `{:next, next_key}`.
  """
  @spec resolve(binary(), String.t()) :: {:reuse, ExecutionLease.t()} | {:next, String.t()}
  def resolve(host_id, key) do
    newest = host_id |> links(key) |> Enum.max_by(&link_number(&1.command_key, key))

    if not_sent?(newest),
      do: {:next, "#{key}:#{link_number(newest.command_key, key) + 1}"},
      else: {:reuse, newest}
  end

  @doc "Every link of `key`: its own lease and `key:N` leases, any status."
  def links_query(key) do
    prefix = key <> ":"
    size = String.length(prefix)

    from(l in ExecutionLease,
      where: l.command_key == ^key or fragment("left(?, ?) = ?", l.command_key, ^size, ^prefix)
    )
  end

  defp links(host_id, key),
    do: Repo.all(from(l in links_query(key), where: l.host_id == ^host_id))

  defp link_number(key, key), do: 1

  defp link_number(command_key, key) do
    case Integer.parse(String.replace_prefix(command_key, key <> ":", "")) do
      {n, ""} -> n
      _ -> 1
    end
  end

  defp not_sent?(%ExecutionLease{status: "completed", last_cursor: 1, id: lease_id}) do
    Repo.exists?(
      from(e in ExecutionEvent,
        where: e.lease_id == ^lease_id and e.cursor == 1 and e.idempotency_key in ^@unsent_closes
      )
    )
  end

  defp not_sent?(_lease), do: false
end
