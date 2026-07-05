defmodule Barkpark.Pulse do
  @moduledoc """
  Pulse — core machinery for public, anonymous, rate-limited event channels
  (the Shared Storm substrate; design paper `shared-storm`).

  A **channel** is a named, explicitly-configured public inbox for tiny
  schema-validated events. Anyone on the internet may POST an event to a
  configured channel and poll its recent feed — the abuse posture is caps,
  not auth: strict per-field validation, a byte ceiling, per-IP token
  buckets, and a per-channel daily ceiling. Events are EPHEMERAL (TTL-swept
  by `Barkpark.Pulse.SweepWorker`); the per-channel counter row is DURABLE —
  the feed forgets, the total-ever count never does.

  This module is core (reusable machinery, the `Barkpark.Tasks` precedent);
  the thin `Barkpark.Plugins.Pulse` plugin contributes the routes and the
  sweep cron. Plugin off = zero routes; the tables sit dark.

  ## Channel configuration

  `config :barkpark, :pulse_channels, %{"jarl-card" => %{...}}` — nothing is
  open by default; an unknown channel is a 404. In prod the map comes from
  the `BARKPARK_PULSE_CHANNELS` env JSON (see `runtime.exs`). Per-channel
  keys (all optional except `fields`):

    * `fields`       — `%{"name" => spec}` event schema; specs are
      `["int", min, max]`, `["float", min, max]`, or `["bool"]`
      (JSON-friendly so the env var can carry them)
    * `max_bytes`    — encoded-payload ceiling (default 200)
    * `rate_per_min` — per-IP sustained events/minute (default 10; burst 3)
    * `daily_cap`    — per-channel global ceiling per UTC day (default 5000)
    * `ttl_hours`    — event row lifetime before the sweep (default 24)
  """

  import Ecto.Query

  alias Barkpark.Repo

  @defaults %{
    "max_bytes" => 200,
    "rate_per_min" => 10,
    "daily_cap" => 5_000,
    "ttl_hours" => 24
  }

  defmodule Event do
    @moduledoc false
    use Ecto.Schema

    schema "pulse_events" do
      field :channel, :string
      field :payload, :map
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  # ── Channel config ────────────────────────────────────────────────────

  @doc "The configured channel map — `%{}` unless explicitly configured."
  def channels, do: Application.get_env(:barkpark, :pulse_channels, %{})

  @doc "Fetch one channel's config (defaults merged), or `:error` if not configured."
  def channel(name) when is_binary(name) do
    case Map.fetch(channels(), name) do
      {:ok, cfg} when is_map(cfg) -> {:ok, Map.merge(@defaults, cfg)}
      _ -> :error
    end
  end

  # ── Validation ────────────────────────────────────────────────────────

  @doc """
  Validate a raw params map against the channel's field specs.

  Fail-closed: unknown keys are rejected, every declared field is required,
  and the encoded payload must fit `max_bytes`. Returns `{:ok, clean_map}`
  (only declared fields, coerced) or `{:error, reason_string}`.
  """
  def validate_payload(cfg, params) when is_map(params) do
    fields = Map.fetch!(cfg, "fields")

    with :ok <- no_unknown_keys(params, fields),
         {:ok, clean} <- coerce_fields(fields, params),
         :ok <- within_byte_cap(clean, Map.fetch!(cfg, "max_bytes")) do
      {:ok, clean}
    end
  end

  def validate_payload(_cfg, _params), do: {:error, "payload must be a JSON object"}

  defp no_unknown_keys(params, fields) do
    case Map.keys(params) -- Map.keys(fields) do
      [] -> :ok
      extra -> {:error, "unknown fields: #{Enum.join(extra, ", ")}"}
    end
  end

  defp coerce_fields(fields, params) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case coerce_field(spec, Map.fetch(params, name)) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, name, v)}}
        {:error, why} -> {:halt, {:error, "#{name}: #{why}"}}
      end
    end)
  end

  defp coerce_field(_spec, :error), do: {:error, "is required"}

  defp coerce_field(["int", min, max], {:ok, v}) when is_integer(v) and v >= min and v <= max,
    do: {:ok, v}

  defp coerce_field(["int", min, max], {:ok, _}),
    do: {:error, "must be an integer in #{min}..#{max}"}

  defp coerce_field(["float", min, max], {:ok, v}) when is_number(v) do
    if v >= min and v <= max,
      do: {:ok, v * 1.0},
      else: {:error, "must be a number in #{min}..#{max}"}
  end

  defp coerce_field(["float", _min, _max], {:ok, _}), do: {:error, "must be a number"}
  defp coerce_field(["bool"], {:ok, v}) when is_boolean(v), do: {:ok, v}
  defp coerce_field(["bool"], {:ok, _}), do: {:error, "must be a boolean"}
  defp coerce_field(spec, _), do: {:error, "unsupported field spec #{inspect(spec)}"}

  defp within_byte_cap(clean, max_bytes) do
    if byte_size(Jason.encode!(clean)) <= max_bytes,
      do: :ok,
      else: {:error, "payload exceeds #{max_bytes} bytes"}
  end

  # ── Ingest ────────────────────────────────────────────────────────────

  @doc """
  Record one validated event: insert the row and atomically bump the
  channel's durable counter in the same transaction.

  Returns `{:ok, %{id: event_id, total: new_total}}`.
  """
  def record_event(channel, clean_payload) do
    Repo.transaction(fn ->
      {1, [%{id: id}]} =
        Repo.insert_all(
          Event,
          [
            %{
              channel: channel,
              payload: clean_payload,
              inserted_at: DateTime.utc_now()
            }
          ],
          returning: [:id]
        )

      # Atomic upsert-increment: the durable total survives the TTL sweep.
      {1, [%{total: total}]} =
        Repo.insert_all(
          "pulse_counters",
          [%{channel: channel, total: 1, updated_at: DateTime.utc_now()}],
          on_conflict: [inc: [total: 1], set: [updated_at: DateTime.utc_now()]],
          conflict_target: :channel,
          returning: [:total]
        )

      %{id: id, total: total}
    end)
  end

  @doc "How many events the channel ingested in the current UTC day (the daily-cap gauge)."
  def count_today(channel) do
    midnight = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.one(
      from e in Event,
        where: e.channel == ^channel and e.inserted_at >= ^midnight,
        select: count(e.id)
    )
  end

  # ── Feed ──────────────────────────────────────────────────────────────

  @max_batch 100

  @doc """
  Events after `since_id` (the monotonic cursor), oldest first, capped at
  #{@max_batch}. Returns `%{events: [...], total: n, next: cursor}` — one
  poll = one indexed query + one counter read.
  """
  def recent(channel, since_id, limit \\ @max_batch) do
    limit = min(max(limit, 1), @max_batch)

    events =
      Repo.all(
        from e in Event,
          where: e.channel == ^channel and e.id > ^since_id,
          order_by: [asc: e.id],
          limit: ^limit,
          select: %{id: e.id, payload: e.payload, at: e.inserted_at}
      )

    next = if events == [], do: since_id, else: List.last(events).id
    %{events: events, total: total(channel), next: next}
  end

  @doc "The channel's durable total-ever counter (0 if nothing was ever ingested)."
  def total(channel) do
    Repo.one(
      from c in "pulse_counters",
        where: c.channel == ^channel,
        select: c.total
    ) || 0
  end

  @doc "Stats: total ever (durable), today and last-hour (from retained rows)."
  def stats(channel) do
    hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    last_hour =
      Repo.one(
        from e in Event,
          where: e.channel == ^channel and e.inserted_at >= ^hour_ago,
          select: count(e.id)
      )

    %{total: total(channel), today: count_today(channel), last_hour: last_hour}
  end

  # ── Sweep ─────────────────────────────────────────────────────────────

  @doc """
  Delete events older than each configured channel's TTL. Idempotent; safe
  with concurrent ingest (a plain range DELETE — new rows are untouchable
  by the cutoff, and the counter table is never touched). Returns the
  per-channel deleted counts.
  """
  def sweep do
    Map.new(channels(), fn {name, _cfg} ->
      {:ok, cfg} = channel(name)
      cutoff = DateTime.add(DateTime.utc_now(), -cfg["ttl_hours"] * 3600, :second)

      {deleted, _} =
        Repo.delete_all(
          from e in Event,
            where: e.channel == ^name and e.inserted_at < ^cutoff
        )

      {name, deleted}
    end)
  end
end
