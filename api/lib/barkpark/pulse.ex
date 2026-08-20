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
      (JSON-friendly so the env var can carry them). A 4th element makes the
      field OPTIONAL with that default (`["float", 0, 1, 0]`) — how a schema
      grows without breaking already-deployed clients
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

  @doc """
  Fetch one channel's config (defaults merged), or `:error` if not configured
  or misconfigured — a channel entry missing `"fields"` (or whose `"fields"`
  isn't a non-empty map) is treated as not-configured, fail-closed, so a
  typo'd env channel 404s instead of crashing the first POST. `rate_per_min`
  is clamped to a positive integer, falling back to the default (10) when
  the configured value is `<= 0` or non-integer.
  """
  def channel(name) when is_binary(name) do
    case Map.fetch(channels(), name) do
      {:ok, cfg} when is_map(cfg) ->
        merged = Map.merge(@defaults, cfg)

        with fields when is_map(fields) and map_size(fields) > 0 <- Map.get(merged, "fields") do
          {:ok, %{merged | "rate_per_min" => sane_rate(merged["rate_per_min"])}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp sane_rate(rate) when is_integer(rate) and rate > 0, do: rate
  defp sane_rate(_), do: @defaults["rate_per_min"]

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

  # a 4-element spec is optional-with-default — absent means the default,
  # so a channel schema can grow without rejecting older clients
  defp coerce_field([_t, _min, _max, default], :error), do: {:ok, default}
  defp coerce_field(_spec, :error), do: {:error, "is required"}

  defp coerce_field(["int", min, max | _], {:ok, v}) when is_integer(v) and v >= min and v <= max,
    do: {:ok, v}

  defp coerce_field(["int", min, max | _], {:ok, _}),
    do: {:error, "must be an integer in #{min}..#{max}"}

  defp coerce_field(["float", min, max | _], {:ok, v}) when is_number(v) do
    if v >= min and v <= max,
      do: {:ok, v * 1.0},
      else: {:error, "must be a number in #{min}..#{max}"}
  end

  defp coerce_field(["float", _min, _max | _], {:ok, _}), do: {:error, "must be a number"}
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

  # ── CITED SAFE — class A, and the most REACHABLE clock-derived bound in the
  # repo (clock-semantics wave, 2026-08-19). Read this before re-sourcing the
  # clock; it was previously UNCENSUSED.
  #
  # Why it hid: there is no `div(`, no `on_conflict`, no bucket key here, so
  # every mechanical sweep for the #12628 shape (8598c4efe7 — a wall-clock
  # window used as a bucket key; atomicity precedent #12579, e45f1377bb) walks
  # straight past it. You only find it by following `count_today/1` to its
  # SECOND caller.
  #
  # CONSUMER CENSUS — two callers, and they are not equally interesting:
  #   * `stats/1` in this module — display only.
  #   * `BarkparkWeb.PulseController.check_daily_cap/2` (pulse_controller.ex:127)
  #     — this ENFORCES the per-channel `daily_cap` (default 5_000) on a route
  #     whose own moduledoc reads "Auth posture: NONE, by design". An
  #     unauthenticated caller reaches this bound.
  # `grep -rn count_today api/lib` returns nothing else.
  #
  # (a) STRUCTURAL, before any consequence argument: this is a range COUNT over
  #     the persisted `inserted_at` column, re-derived from scratch on every
  #     request. Nothing stores a bucket key, nothing sweeps by one, and there
  #     is nothing for a stale reader to delete — so #12628's mechanism is
  #     absent and this is class A (an absolute instant compared against stored
  #     instants), not class C.
  #
  # (b) CLOCK STEP, both directions, and the caller influences neither — no
  #     request value feeds this read, `count_today/1` takes no `now` argument:
  #     * FORWARD across UTC midnight: the window restarts early and the full
  #       anonymous 5_000 budget is refreshed — FAIL-OPEN, bounded at one extra
  #       cap per step.
  #     * BACKWARD across UTC midnight: the window widens and rows from up to
  #       two days are counted against one cap — FAIL-CLOSED.
  #
  # And the decisive point: a monotonic rewrite here is IMPOSSIBLE, not merely
  # wrong. The column being compared (`inserted_at`) is wall clock and persists
  # across restarts, and "per UTC day" IS the specification of the cap
  # (`daily_cap`, documented in this module's moduledoc and in the pulse plugin
  # card). `System.monotonic_time` cannot express a UTC-day boundary at all.
  #
  # WHAT THIS VERDICT DOES NOT REST ON: the fact that the pulse surface already
  # carries per-IP token buckets and a green abuse-drill suite. Those bound a
  # DIFFERENT thing (per-IP rate) and none of them exercises a clock step
  # against this window. The grounds above are the structural shape and a
  # caller census.
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
  The durable "cost so far": total accrued compute cost since telemetry
  started, in EUROS (read from the nano-euro meter). Survives restarts.
  """
  def cost_so_far, do: cost_nanos() / 1_000_000_000

  @doc "Raw nano-euro meter value (integer), 0 if never accrued."
  def cost_nanos do
    Repo.one(from m in "pulse_meters", where: m.name == "cost", select: m.nanos) || 0
  end

  @doc "Atomically add `nanos` nano-euros to the durable cost meter."
  def add_cost_nanos(nanos) when is_integer(nanos) and nanos > 0 do
    Repo.insert_all(
      "pulse_meters",
      [%{name: "cost", nanos: nanos, updated_at: DateTime.utc_now()}],
      on_conflict: [inc: [nanos: nanos], set: [updated_at: DateTime.utc_now()]],
      conflict_target: :name
    )

    :ok
  end

  def add_cost_nanos(_), do: :ok

  @doc """
  On-disk cost of the pulse tables (events + counters), in bytes — the real
  `pg_total_relation_size`, and the retained event-row count. The events side
  breathes with the TTL sweep; the counters side is a handful of rows forever.
  """
  def storage do
    %{rows: [[ev_bytes, ct_bytes]]} =
      Repo.query!(
        "SELECT pg_total_relation_size('pulse_events'), pg_total_relation_size('pulse_counters')"
      )

    events = Repo.one(from e in Event, select: count(e.id))
    %{events_bytes: ev_bytes, counters_bytes: ct_bytes, event_rows: events}
  end

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
