defmodule Barkpark.Plugins.Tickets.InboxPresenter do
  @moduledoc """
  Pure render model for the Studio operator inbox (Tickets epic, Decision 3 +
  5). Takes plain ticket maps (charter Decision 2 field shape) plus `now`, and
  returns the partitioned/formatted view the LiveView renders. NO database, NO
  boot, NO plugin siblings — the whole triage gate is decided here so it can be
  exhaustively unit-tested in isolation.

  ## Why this module is the heart

  Status literally encodes whose turn it is (Decision 3):

    * `open`     — the operator's move  → **needs_answer** (THE list)
    * `answered` — the submitter's move → **waiting_on_them**
    * `closed`   — done                 → **recently_closed** (collapsed)

  A reopened ticket (submitter replied to an `answered`/`closed` thread) is back
  to `open`, so it re-enters `needs_answer` by construction — no special case.

  ## Ordering

    * `needs_answer`     — oldest `waiting_since` FIRST (the operator drains the
      queue from the top; the person who has waited longest is served first).
    * `waiting_on_them`  — newest activity first (most-recently-answered on top).
    * `recently_closed`  — newest activity first.

  ## Row model

      %{
        id:              term,
        key_name:        String.t(),
        subject:         String.t(),
        waiting_age:     "6h" | "2d" | "now" | ...,   # humanized, see humanize_age/2
        message_count:   non_neg_integer,
        has_attachments?: boolean,
        seen:            "seen 2h ago" | "seen just now" | "not seen yet" | nil
      }

  The `seen` signal (Decision 3, the no-push delivery proof) is derived per row:
  when the submitter's `submitter_seen_at` is later than the last operator
  message, they have seen the answer → `"seen <age> ago"`; otherwise
  `"not seen yet"`. With no operator message at all there is nothing to have
  seen → `nil`. It is meaningful (and rendered) only in the `waiting_on_them`
  partition, but the field is computed uniformly.

  ## Field shape tolerance

  Ticket maps may arrive with **string** keys (document JSON) or **atom** keys
  (a sibling struct/map). Every accessor tolerates both so the presenter works
  regardless of which surface produced the map.
  """

  @typedoc "A plain ticket map — string- or atom-keyed (Decision 2 fields)."
  @type ticket :: map()

  @type row :: %{
          id: term(),
          key_name: String.t(),
          subject: String.t(),
          waiting_age: String.t(),
          message_count: non_neg_integer(),
          has_attachments?: boolean(),
          seen: String.t() | nil
        }

  @type model :: %{
          needs_answer: [row()],
          waiting_on_them: [row()],
          recently_closed: [row()],
          badge_count: non_neg_integer()
        }

  @doc """
  Build the inbox render model from a list of ticket maps and the current time.

  `now` is a `DateTime` (injected so the function is pure and time-testable).
  Unknown/other statuses are dropped from all three partitions (fail-quiet — a
  malformed status never lands in the operator's queue).
  """
  @spec build([ticket()], DateTime.t()) :: model()
  def build(tickets, %DateTime{} = now) when is_list(tickets) do
    by_status = Enum.group_by(tickets, &status/1)

    needs_answer =
      by_status
      |> Map.get("open", [])
      |> Enum.sort_by(&waiting_sort_key/1, :asc)
      |> Enum.map(&row(&1, now))

    waiting_on_them =
      by_status
      |> Map.get("answered", [])
      |> Enum.sort_by(&activity_sort_key/1, :asc)
      |> Enum.map(&row(&1, now))

    recently_closed =
      by_status
      |> Map.get("closed", [])
      |> Enum.sort_by(&activity_sort_key/1, :asc)
      |> Enum.map(&row(&1, now))

    %{
      needs_answer: needs_answer,
      waiting_on_them: waiting_on_them,
      recently_closed: recently_closed,
      badge_count: length(needs_answer)
    }
  end

  @doc """
  Humanize the age of a timestamp relative to `now`, compactly: `"now"` under a
  minute, then `"<n>m"`, `"<n>h"`, `"<n>d"`. A `nil` or unparseable timestamp
  yields `"—"`. Negative diffs (clock skew / future stamp) clamp to `"now"`.

  Boundaries (floor division): 59s → "now", 60s → "1m", 3599s → "59m",
  3600s → "1h", 86399s → "23h", 86400s → "1d".
  """
  @spec humanize_age(term(), DateTime.t()) :: String.t()
  def humanize_age(at, %DateTime{} = now) do
    case to_dt(at) do
      nil ->
        "—"

      %DateTime{} = dt ->
        secs = max(DateTime.diff(now, dt, :second), 0)

        cond do
          secs < 60 -> "now"
          secs < 3600 -> "#{div(secs, 60)}m"
          secs < 86_400 -> "#{div(secs, 3600)}h"
          true -> "#{div(secs, 86_400)}d"
        end
    end
  end

  @doc """
  Derive the delivery/seen signal for a ticket (Decision 3). Public so the
  LiveView and tests can assert it directly.

    * `nil`            — no operator message yet (nothing to have seen)
    * `"seen just now"`/`"seen <age> ago"` — `submitter_seen_at` is later than
      the last operator message
    * `"not seen yet"` — an operator answered but the submitter has not read it
      since
  """
  @spec seen_signal(ticket(), DateTime.t()) :: String.t() | nil
  def seen_signal(ticket, %DateTime{} = now) do
    case last_operator_at(ticket) do
      nil ->
        nil

      %DateTime{} = last_op ->
        seen_at = to_dt(field(ticket, :submitter_seen_at))

        if seen_at && DateTime.compare(seen_at, last_op) == :gt do
          secs = max(DateTime.diff(now, seen_at, :second), 0)
          if secs < 60, do: "seen just now", else: "seen #{humanize_age(seen_at, now)} ago"
        else
          "not seen yet"
        end
    end
  end

  # ── Row assembly ──────────────────────────────────────────────────────────

  defp row(ticket, now) do
    msgs = messages(ticket)

    %{
      id: field(ticket, :id),
      key_name: field(ticket, :key_name) || "—",
      subject: subject_or_default(field(ticket, :subject)),
      waiting_age: humanize_age(field(ticket, :waiting_since), now),
      message_count: length(msgs),
      has_attachments?: Enum.any?(msgs, &message_has_attachments?/1),
      seen: seen_signal(ticket, now)
    }
  end

  defp subject_or_default(nil), do: "(no subject)"
  defp subject_or_default(""), do: "(no subject)"
  defp subject_or_default(s) when is_binary(s), do: s
  defp subject_or_default(other), do: to_string(other)

  defp message_has_attachments?(msg) do
    case msg_field(msg, :attachments) do
      list when is_list(list) -> list != []
      _ -> false
    end
  end

  # ── Sort keys ─────────────────────────────────────────────────────────────
  #
  # Both partitions sort ASCENDING on a {present?, seconds} tuple where
  # `present? == 1` marks a nil/unparseable timestamp, so those rows always
  # cluster AFTER real ones (Elixir compares the leading flag first).
  #   * waiting_sort_key  — seconds ascending  → oldest-waiting first.
  #   * activity_sort_key — NEGATED seconds    → newest-activity first.

  defp waiting_sort_key(ticket), do: dt_sort_key(field(ticket, :waiting_since))

  defp activity_sort_key(ticket) do
    # Newest activity = the latest message timestamp, falling back to
    # waiting_since when a ticket somehow has no messages.
    last =
      ticket
      |> messages()
      |> Enum.map(&msg_field(&1, :at))
      |> Enum.map(&to_dt/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> field(ticket, :waiting_since)
        list -> Enum.max_by(list, &DateTime.to_unix/1)
      end

    case dt_sort_key(last) do
      {0, unix} -> {0, -unix}
      nil_key -> nil_key
    end
  end

  defp dt_sort_key(at) do
    case to_dt(at) do
      %DateTime{} = dt -> {0, DateTime.to_unix(dt)}
      nil -> {1, 0}
    end
  end

  # ── Message helpers ───────────────────────────────────────────────────────

  defp messages(ticket) do
    case field(ticket, :messages) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp last_operator_at(ticket) do
    ticket
    |> messages()
    |> Enum.filter(&(msg_field(&1, :author_kind) in ["operator", :operator]))
    |> Enum.map(&msg_field(&1, :at))
    |> Enum.map(&to_dt/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.max_by(list, &DateTime.to_unix/1)
    end
  end

  # ── Dual-key field access (string OR atom keys) ───────────────────────────

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil

  defp msg_field(map, key), do: field(map, key)

  defp status(ticket) do
    case field(ticket, :status) do
      s when is_binary(s) -> s
      s when is_atom(s) and not is_nil(s) -> Atom.to_string(s)
      _ -> "unknown"
    end
  end

  # ── Timestamp coercion (DateTime | NaiveDateTime | ISO8601 | nil) ─────────

  defp to_dt(nil), do: nil
  defp to_dt(%DateTime{} = dt), do: dt
  defp to_dt(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp to_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp to_dt(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp to_dt(_), do: nil
end
