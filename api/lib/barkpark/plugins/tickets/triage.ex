defmodule Barkpark.Plugins.Tickets.Triage do
  @moduledoc """
  Pure triage ordering for the operator inbox (charter Decision 3).

  Status IS the turn indicator, so "what needs answering" is a sort, not a
  saved view: `open` tickets first (the operator's move), oldest-`waiting_since`
  first so the person who has waited longest surfaces at the top; then
  `answered` tickets (waiting on the submitter) most-recent first; then
  `closed`, most-recent first.

  Every function here is PURE — it takes plain ticket maps (string OR atom
  keys, `%DateTime{}` OR ISO8601 timestamps) and returns data. No DB, no
  clock read except the `now` the caller passes to `waiting_age/2`. That keeps
  it trivially testable and lets the HTTP layer and the Studio LiveView share
  ONE ordering.
  """

  # Turn buckets: lower sorts first. Anything unknown falls after closed.
  @bucket %{"open" => 0, "answered" => 1, "closed" => 2}
  @bucket_fallback 3

  # Sentinels for a missing timestamp so nil never crashes the comparator and
  # never masquerades as "urgent". `@far_future` pushes a waiting_since-less
  # open ticket to the BOTTOM of the open bucket; `@epoch0` pushes a
  # recency-less answered/closed ticket to the bottom of its bucket.
  @far_future 9_223_372_036_854_775_807
  @epoch0 0

  @doc """
  Order tickets for the operator inbox: open (oldest-waiting first) → answered
  (newest first) → closed (newest first). Stable and total.
  """
  @spec inbox_order([map()]) :: [map()]
  def inbox_order(tickets) when is_list(tickets) do
    Enum.sort_by(tickets, &sort_key/1)
  end

  # The comparator key is a `{bucket, tiebreak}` tuple compared elementwise by
  # `Enum.sort_by`'s default ascending order.
  #
  #   * open     → {0, waiting_since_unix}      ascending ⇒ oldest waiting first
  #   * answered → {1, -recency_unix}           ascending on the negation ⇒ newest first
  #   * closed   → {2, -recency_unix}           same
  defp sort_key(ticket) do
    status = get(ticket, :status) || "open"
    bucket = Map.get(@bucket, status, @bucket_fallback)

    tiebreak =
      case status do
        "open" -> to_unix(get(ticket, :waiting_since), @far_future)
        _ -> -to_unix(recency(ticket), @epoch0)
      end

    {bucket, tiebreak}
  end

  @doc """
  Seconds a ticket has been waiting on the operator, relative to `now`.

  Returns a non-negative integer (clamped at 0 so a slightly-skewed clock can't
  go negative), or `nil` when the ticket carries no `waiting_since` (e.g. it is
  not currently the operator's move). `now` is passed in so the function stays
  pure — the caller reads the clock once.
  """
  @spec waiting_age(map(), DateTime.t()) :: non_neg_integer() | nil
  def waiting_age(ticket, %DateTime{} = now) do
    case parse_dt(get(ticket, :waiting_since)) do
      nil -> nil
      %DateTime{} = since -> max(DateTime.diff(now, since, :second), 0)
    end
  end

  # Recency for the answered/closed buckets: the last time the thread moved.
  # Prefer an explicit `updated_at`, fall back to `waiting_since` so a ticket
  # that never carried an update stamp still orders deterministically.
  defp recency(ticket) do
    get(ticket, :updated_at) || get(ticket, :waiting_since)
  end

  # Read a key that may be spelled as an atom OR a string — the maps come from
  # both hand-built callers (atom keys) and JSON-derived content (string keys).
  defp get(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp to_unix(value, sentinel) do
    case parse_dt(value) do
      nil -> sentinel
      %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
    end
  end

  # Accept a %DateTime{}, an ISO8601 string, or nil. Anything unparseable → nil.
  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil
end
