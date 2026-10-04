defmodule Barkpark.Content.DeletedPayloadRetention do
  @moduledoc """
  Retention for copies of DELETED content kept in two side tables — owner
  ruling #33 (2026-10-03, task-43179d8d03efe969 item 4): "Expire after 90
  days."

  ## Which rows hold a deleted document's content

    * `mutation_events.document` — every event stores
      `Envelope.render(doc, nil, :internal)`, the full unredacted document as it
      was at that write. A delete event stores the document as it was when it
      was deleted, and every earlier create/update/publish event for the same id
      stores an earlier full copy. Once the document is gone, all of them are
      copies of deleted content.
    * `webhook_deliveries.payload_snapshot` — NIL for document deliveries (they
      rebuild their body from the `mutation_events` row above, so redacting the
      event covers them). Media deliveries snapshot the media file at dispatch
      time (`filename`, `original_name`, CDN urls) together with the endpoint's
      signing secret; for a deleted file that snapshot is the only remaining copy
      of its metadata. Audit, chat_blocked and test snapshots are not document
      content and are out of scope.

  ## Policy: redact the payload, keep the row

  A row is swept when it is older than `days/0` (`inserted_at`, default 90) AND
  its source is gone:

    * an event, when no `documents` row exists for its published or `drafts.`
      id in the same dataset and workspace. A document that still exists keeps
      its whole event trail, whatever its age.
    * a media delivery, when it is terminal (`ok` / `failed_giveup`, never a
      resumable `pending` row) and its `media_file_id` no longer exists in
      `media_files`.

  The payload is REPLACED, the row stays. `mutation_events.document` becomes
  `%{"_id", "_type", "_rev", "_redacted" => "retention", "_redactedAt"}`
  (the column is NOT NULL, and every reader keeps the id and type it needs);
  `payload_snapshot` becomes `%{"_redacted" => "retention", "_redactedAt"}`.
  Deleting rows instead would break features that read them: the task event
  feeds and board activity, SSE Last-Event-ID replay (a delete tombstone must
  still reach a resuming listener), webhook delivery history, and
  `POST .../replay` — and `webhook_deliveries.event_id` cascades on delete, so
  removing an event would also erase its delivery history.

  Redacted rows are never matched again, so a sweep is idempotent and the
  census counts only remaining work.

  ## Switch

  Ships DISABLED. `config :barkpark, :deleted_payload_retention, enabled: false,
  days: 90` (config.exs); runtime overrides
  `BARKPARK_DELETED_PAYLOAD_RETENTION=on` and
  `BARKPARK_DELETED_PAYLOAD_RETENTION_DAYS` (runtime.exs). The daily
  `Barkpark.Content.Workers.DeletedPayloadSweeper` cron is a no-op while the
  switch is off. `mix barkpark.deleted_payload_retention` prints the census
  (dry run by default) and sweeps with `--apply`.

  Every statement is bounded: candidates are selected `batch_size` rows at a
  time on a keyset over `id`, and each UPDATE names exactly those ids.

  Revisions are a separate policy: `Barkpark.Content.Revisions` keeps history,
  including a deleted document's, indefinitely.
  """

  import Ecto.Query

  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Repo
  alias Barkpark.Webhooks.Delivery

  @default_days 90
  @default_batch_size 1_000
  @default_max_passes 100
  @marker "retention"
  @terminal_statuses ~w(ok failed_giveup)

  @type table_census :: %{
          count: non_neg_integer(),
          oldest: DateTime.t() | nil,
          newest: DateTime.t() | nil
        }

  @doc "True when the scheduled sweep is switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "Retention window in days (default #{@default_days})."
  @spec days() :: pos_integer()
  def days do
    case Keyword.get(config(), :days, @default_days) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_days
    end
  end

  defp config do
    case Application.get_env(:barkpark, :deleted_payload_retention, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "The cutoff instant for a window of `days` ending at `now`."
  @spec cutoff(non_neg_integer(), DateTime.t()) :: DateTime.t()
  def cutoff(days, now \\ DateTime.utc_now()), do: DateTime.add(now, -days * 86_400, :second)

  @doc """
  Count the rows a sweep would redact, per table, with the oldest and newest
  `inserted_at` among them. Reads only.

  Options: `:days` (default `days/0`), `:now`, `:batch_size` (media rows are
  decoded in Elixir one batch at a time).
  """
  @spec census(keyword()) :: %{
          days: non_neg_integer(),
          cutoff: DateTime.t(),
          mutation_events: table_census(),
          webhook_deliveries: table_census()
        }
  def census(opts \\ []) do
    {days, cutoff, batch} = window(opts)

    {count, oldest, newest} =
      event_candidates(cutoff)
      |> select([e], {count(e.id), min(e.inserted_at), max(e.inserted_at)})
      |> Repo.one()

    %{
      days: days,
      cutoff: cutoff,
      mutation_events: %{count: count, oldest: oldest, newest: newest},
      webhook_deliveries: media_census(cutoff, batch)
    }
  end

  @doc """
  Redact every eligible payload, in bounded batches. Returns
  `{:ok, %{mutation_events: n, webhook_deliveries: n, passes: n}}`.

  Does NOT read the switch: the scheduled worker checks `enabled?/0`, and the
  mix task's `--apply` is an explicit operator action. Options: `:days`,
  `:now`, `:batch_size` (default #{@default_batch_size}), `:max_passes`
  (default #{@default_max_passes} per table; a larger backlog finishes on the
  next run because each pass takes the oldest remaining rows first).
  """
  @spec sweep(keyword()) ::
          {:ok,
           %{
             mutation_events: non_neg_integer(),
             webhook_deliveries: non_neg_integer(),
             passes: pos_integer()
           }}
  def sweep(opts \\ []) do
    {_days, cutoff, batch} = window(opts)
    max_passes = positive(Keyword.get(opts, :max_passes), @default_max_passes)
    stamp = DateTime.to_iso8601(Keyword.get(opts, :now, DateTime.utc_now()))

    {events, event_passes} = sweep_events(cutoff, batch, max_passes, stamp)
    {deliveries, delivery_passes} = sweep_media(cutoff, batch, max_passes, stamp)

    {:ok,
     %{
       mutation_events: events,
       webhook_deliveries: deliveries,
       passes: max(event_passes, delivery_passes)
     }}
  end

  defp window(opts) do
    days =
      case Keyword.get(opts, :days) do
        d when is_integer(d) and d >= 0 -> d
        _ -> days()
      end

    now = Keyword.get(opts, :now, DateTime.utc_now())
    {days, cutoff(days, now), positive(Keyword.get(opts, :batch_size), @default_batch_size)}
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_n, default), do: default

  # ── mutation_events ──────────────────────────────────────────────────────────

  # Old, not yet redacted, and no `documents` row under either the published or
  # the `drafts.` form of its id in the same dataset + workspace. Matching on
  # either form keeps the trail of a document that still exists in only one of
  # them (a published doc whose draft was discarded, a draft never published).
  defp event_candidates(cutoff) do
    from(e in MutationEvent,
      as: :event,
      where: e.inserted_at < ^cutoff,
      where: is_nil(fragment("?->>'_redacted'", e.document)),
      where:
        not exists(
          from(d in Document,
            where:
              d.dataset == parent_as(:event).dataset and
                fragment(
                  "? IS NOT DISTINCT FROM ?",
                  d.workspace_id,
                  parent_as(:event).workspace_id
                ) and
                (d.doc_id ==
                   fragment("regexp_replace(?, '^drafts\\.', '')", parent_as(:event).doc_id) or
                   d.doc_id ==
                     fragment(
                       "'drafts.' || regexp_replace(?, '^drafts\\.', '')",
                       parent_as(:event).doc_id
                     )),
            select: 1
          )
        )
    )
  end

  defp sweep_events(cutoff, batch, max_passes, stamp),
    do: sweep_events(cutoff, batch, max_passes, stamp, 0, 0, 0)

  defp sweep_events(_cutoff, _batch, max_passes, _stamp, _cursor, total, passes)
       when passes >= max_passes,
       do: {total, passes}

  defp sweep_events(cutoff, batch, max_passes, stamp, cursor, total, passes) do
    ids =
      event_candidates(cutoff)
      |> where([e], e.id > ^cursor)
      |> order_by([e], asc: e.id)
      |> limit(^batch)
      |> select([e], e.id)
      |> Repo.all()

    case ids do
      [] ->
        {total, passes + 1}

      ids ->
        # The predicate rides the UPDATE too, so a document recreated between
        # the select and this statement keeps its trail.
        {n, _} =
          event_candidates(cutoff)
          |> where([e], e.id in ^ids)
          |> update([e],
            set: [
              document:
                fragment(
                  "jsonb_build_object('_id', ?, '_type', ?, '_rev', ?, '_redacted', ?::text, '_redactedAt', ?::text)",
                  e.doc_id,
                  e.type,
                  e.rev,
                  ^@marker,
                  ^stamp
                )
            ]
          )
          |> Repo.update_all([])

        sweep_events(cutoff, batch, max_passes, stamp, List.last(ids), total + n, passes + 1)
    end
  end

  # ── webhook_deliveries (media) ───────────────────────────────────────────────

  defp media_rows(cutoff) do
    from(d in Delivery,
      where: d.source_kind == "media",
      where: d.status in ^@terminal_statuses,
      where: d.inserted_at < ^cutoff,
      where: not is_nil(d.payload_snapshot),
      where: is_nil(fragment("?->>'_redacted'", d.payload_snapshot))
    )
  end

  # One keyset batch of terminal, old media rows, narrowed in Elixir to the ones
  # whose media file is gone. The file id lives inside the snapshot's encoded
  # JSON `body`; decoding it here (not with a SQL cast) means one malformed body
  # is skipped instead of failing the whole statement.
  defp media_batch(cutoff, cursor, batch) do
    rows =
      media_rows(cutoff)
      |> where([d], d.id > ^cursor)
      |> order_by([d], asc: d.id)
      |> limit(^batch)
      |> select([d], {d.id, d.inserted_at, d.payload_snapshot})
      |> Repo.all()

    keyed = for {id, at, snap} <- rows, file_id = media_file_id(snap), do: {id, at, file_id}

    file_ids = keyed |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    live =
      if file_ids == [],
        do: MapSet.new(),
        # Schemaless on purpose: content is a kernel concept and must not
        # depend on the media feature's schema module (boundary gate); this
        # asks only whether the row still exists.
        else:
          from(m in "media_files",
            where: m.id in type(^file_ids, {:array, Ecto.UUID}),
            select: type(m.id, Ecto.UUID)
          )
          |> Repo.all()
          |> MapSet.new()

    gone = for {id, at, file_id} <- keyed, not MapSet.member?(live, file_id), do: {id, at}
    next = if rows == [], do: nil, else: rows |> List.last() |> elem(0)
    {gone, next}
  end

  defp media_file_id(%{"body" => body}) when is_binary(body) do
    with {:ok, %{"media_file_id" => id}} when is_binary(id) <- Jason.decode(body),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      uuid
    else
      _ -> nil
    end
  end

  defp media_file_id(_snapshot), do: nil

  defp media_census(cutoff, batch), do: media_census(cutoff, batch, 0, {0, nil, nil})

  defp media_census(cutoff, batch, cursor, {count, oldest, newest} = acc) do
    case media_batch(cutoff, cursor, batch) do
      {_gone, nil} ->
        %{count: count, oldest: oldest, newest: newest}

      {gone, next} ->
        acc =
          Enum.reduce(gone, acc, fn {_id, at}, {c, o, n} ->
            {c + 1, earliest(o, at), latest(n, at)}
          end)

        media_census(cutoff, batch, next, acc)
    end
  end

  defp earliest(nil, at), do: at
  defp earliest(a, b), do: if(DateTime.compare(b, a) == :lt, do: b, else: a)
  defp latest(nil, at), do: at
  defp latest(a, b), do: if(DateTime.compare(b, a) == :gt, do: b, else: a)

  defp sweep_media(cutoff, batch, max_passes, stamp),
    do: sweep_media(cutoff, batch, max_passes, stamp, 0, 0, 0)

  defp sweep_media(_cutoff, _batch, max_passes, _stamp, _cursor, total, passes)
       when passes >= max_passes,
       do: {total, passes}

  defp sweep_media(cutoff, batch, max_passes, stamp, cursor, total, passes) do
    case media_batch(cutoff, cursor, batch) do
      {_gone, nil} ->
        {total, passes + 1}

      {gone, next} ->
        ids = Enum.map(gone, &elem(&1, 0))

        n =
          if ids == [] do
            0
          else
            {n, _} =
              media_rows(cutoff)
              |> where([d], d.id in ^ids)
              |> Repo.update_all(
                set: [payload_snapshot: %{"_redacted" => @marker, "_redactedAt" => stamp}]
              )

            n
          end

        sweep_media(cutoff, batch, max_passes, stamp, next, total + n, passes + 1)
    end
  end
end
