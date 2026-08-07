defmodule BarkparkCloud.Metrics do
  @moduledoc """
  Reduce a WINDOW of the agent's health beats into the time-series envelope the
  console's Metrics tab and `bp cloud instance top` render (charter S12 /
  decisions 30-31). The time-series companion to `BarkparkCloud.Telemetry`,
  which serves the single LATEST beat — this one folds many beats into ordered
  series so the operator sees resource pressure over time.

  Pure OBSERVABILITY over data the agent ALREADY captures: the on-box agent's
  60s beat now carries `cpu_percent`, `mem_used_percent`, `disk_used_percent`
  and `load1` alongside the existing health signals, and the router lands each
  beat append-only as a `"health"` `AgentEvent`. No new store — the durable
  `agent_events` table IS the window (a per-60s beat adds no rows beyond the
  health event that already lands; an ETS ring would empty on every blue/green
  deploy). `Telemetry` and `Usage` are its untouched siblings.

  The window must be fetched TYPE-FILTERED (`Registry.recent_events_of_type(bp,
  "health", points)`), not sliced off the mixed stream: `points` is a count of
  BEATS, and a type-blind limit spends part of it on the box's `space` rows
  (D58), rendering ~188 points of a requested 200. `build/3` filters to health
  again as a second fence, but a fold can only drop rows the fetch already lost.

  `build/3` is PURE and TOTAL: handed a barkpark, a window of that box's events
  (newest-first, exactly as `Registry.recent_events_of_type/3` returns), and the current
  time (injectable for tests), it never raises and never invents a reading. A
  vital that was ABSENT or carried the agent's `-1` "unwired" sentinel in a beat
  becomes a `null` point (the `Telemetry` nil-not-zero doctrine) so a consumer
  never renders a zero dressed as data. The envelope shape is fixed even for a
  never-phoned-home box:

      %{
        ok: true,
        collected_at: String.t(),                 # when the CP folded this, RFC3339
        instance: %{id: ..., host: ..., provider: ...},
        beat: %{
          last_seen_at: String.t() | nil,         # newest beat's inserted_at
          age_seconds: non_neg_integer | nil,
          status: "live" | "stale" | "absent"     # stale keys off the CP-wide threshold
        },
        points: pos_integer,                       # the requested (clamped) window size
        series: %{                                 # each list oldest-to-newest
          cpu:  [%{at: String.t(), value: number | nil}],
          mem:  [...],
          disk: [...],
          load: [...],
          swap: [...],       # swap consumption %
          beam_pss: [...],   # the BEAM's resident footprint, bytes
          beam_swap: [...]   # the BEAM's paged-out bytes
        },
        latest: %{                                 # NEWEST beat only — not a series
          db_size: number | nil,
          top_relations: [%{name: String.t(), bytes: number}] | nil,
          swap: %{used_pct: number | nil, total_bytes: number | nil},
          beam: %{pss_bytes: number | nil, swap_bytes: number | nil}
        },
        service_health: %{pass: non_neg_integer, total: non_neg_integer, failing: [String.t()]}
      }

  `latest` carries the newest beat's SCALAR facts — the ones a trend line cannot
  answer. `db_size` + `top_relations` are "what is taking up space" (a named
  breakdown is what turns 3.5 GB into a diagnosis); `swap.total_bytes` is the
  companion that makes a swap PERCENT interpretable at all (`total 0` is a
  swapless box — measured, and the answer is none; a nil total is "we could not
  measure"). Every scalar takes the SAME nil-not-zero pass as a series point, so
  a `-1` sentinel is nil here too and the renderer never words a sentinel.

  `status` uses `Registry.health_stale_after_seconds/0` — the SAME CP-wide
  degraded threshold (180s) the staleness worker uses, never a new constant.
  `service_health` is the newest beat's health-check roll-up, taken through
  `Telemetry.normalize/1` (public reuse — `Telemetry` stays untouched).
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.AgentEvent
  alias BarkparkCloud.Telemetry

  # series key => the agent Report's jsonb field name (string keys, Jason-decoded).
  # This list DEFINES the rendered series key set (`series/1` is a Map.new over
  # it), and the consumers are keyed maps that DROP an unknown key silently — so
  # adding an entry here is only half a fold: `metricTopSpecs` in
  # internal/cli/cloud_instance_top_cmd.go must gain the same key or the number
  # ships invisibly behind a fully green build.
  @vitals [
    {:cpu, "cpu_percent"},
    {:mem, "mem_used_percent"},
    {:disk, "disk_used_percent"},
    {:load, "load1"},
    # Swap consumption is the vital `mem_used_percent` HIDES: MemAvailable clears
    # the floor precisely BECAUSE the BEAM was paged out, so a box at 99% swap can
    # report a comfortable 58% memory. Trending it is how a swapping box reads as
    # struggling instead of calm.
    {:swap, "swap_used_percent"},
    # The BEAM's own footprint over the window: resident (Pss) and paged-out
    # (Swap) bytes for the one process the kernel OOM-kills.
    {:beam_pss, "beam_pss_bytes"},
    {:beam_swap, "beam_swap_bytes"}
  ]

  @empty_service_health %{pass: 0, total: 0, failing: []}

  # The all-absent `latest` block — the fixed shape a never-phoned-home box (and
  # a pre-upgrade agent that sends none of these keys) still destructures.
  @empty_latest %{
    db_size: nil,
    top_relations: nil,
    swap: %{used_pct: nil, total_bytes: nil},
    beam: %{pss_bytes: nil, swap_bytes: nil}
  }

  @doc """
  Fold a window of `barkpark`'s agent events into the metrics envelope.

  `events` is the window newest-first (as `Registry.recent_events_of_type/3`
  returns); only `"health"` events contribute — a second fence, not the first
  (see the module doc: the LIMIT lives at the fetch). `opts`:

    * `:points` — the requested (already-clamped) window size echoed into the
      envelope. Defaults to `30`.
    * `:now` — the current time for the beat's `age_seconds`/`status`. Defaults
      to `DateTime.utc_now/0`; tests inject a fixed clock.
  """
  @spec build(map(), [AgentEvent.t()], keyword()) :: map()
  def build(barkpark, events, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    points = Keyword.get(opts, :points, 30)

    # Keep only health beats; the window arrives newest-first, series is
    # oldest-to-newest.
    health_newest_first = for %AgentEvent{type: "health"} = e <- events, do: e
    oldest_first = Enum.reverse(health_newest_first)
    newest = List.first(health_newest_first)

    %{
      ok: true,
      collected_at: to_rfc3339(now),
      instance: instance_info(barkpark),
      beat: beat(newest, now),
      points: points,
      series: series(oldest_first),
      latest: latest(newest),
      service_health: service_health(newest)
    }
  end

  defp instance_info(barkpark) when is_map(barkpark) do
    %{
      id: Map.get(barkpark, :id),
      host: Map.get(barkpark, :host),
      provider: Map.get(barkpark, :provider)
    }
  end

  defp instance_info(_), do: %{id: nil, host: nil, provider: nil}

  # No health beat yet → an honest "absent" beat (never a fake 0-age live).
  defp beat(nil, _now), do: %{last_seen_at: nil, age_seconds: nil, status: "absent"}

  defp beat(%AgentEvent{inserted_at: %DateTime{} = at}, now) do
    age = DateTime.diff(now, at)
    # A skewed future timestamp (age < 0) is still "live" — never "stale".
    status = if age > Registry.health_stale_after_seconds(), do: "stale", else: "live"
    %{last_seen_at: to_rfc3339(at), age_seconds: age, status: status}
  end

  # A beat with no usable inserted_at: present but undatable — live, no age.
  defp beat(%AgentEvent{}, _now), do: %{last_seen_at: nil, age_seconds: nil, status: "live"}

  # One list per vital, each carrying one {at, value} point per beat, oldest
  # first. `value` is nil whenever that vital was absent or the -1 sentinel in
  # that beat (nil-not-zero) so consumers never plot a sentinel.
  defp series(oldest_first) do
    Map.new(@vitals, fn {key, field} ->
      points =
        Enum.map(oldest_first, fn e ->
          %{at: to_rfc3339(e.inserted_at), value: vital(e.payload, field)}
        end)

      {key, points}
    end)
  end

  # A vital is real only when it is a non-negative number: the agent stamps -1
  # for an unwired/failed probe, so any negative (and any non-number) is nil.
  # Zero is REAL data (an idle CPU), distinct from the sentinel.
  defp vital(payload, field) when is_map(payload) do
    case Map.get(payload, field) do
      n when is_number(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp vital(_, _), do: nil

  # The newest beat's SCALAR facts, taken through `Telemetry.normalize/1` (public
  # reuse — Telemetry stays untouched) and then put through the SAME nil-not-zero
  # pass the series points get: the agent's `-1` becomes nil, a real `0` survives.
  # That is what lets the renderer tell a swapless box (total 0) apart from an
  # unmeasured one (total nil) without the normalizer minting a word for it.
  defp latest(nil), do: @empty_latest

  defp latest(%AgentEvent{} = event) do
    t = Telemetry.normalize(event)

    %{
      db_size: measured(t.db_size),
      top_relations: t.top_relations,
      swap: %{
        used_pct: measured(t.swap.used_pct),
        total_bytes: measured(t.swap.total_bytes)
      },
      beam: %{
        pss_bytes: measured(t.beam.pss_bytes),
        swap_bytes: measured(t.beam.swap_bytes)
      }
    }
  end

  # A scalar is real only when it is a non-negative number — the `vital/2`
  # doctrine, applied off the series path.
  defp measured(n) when is_number(n) and n >= 0, do: n
  defp measured(_), do: nil

  # The newest beat's health-check roll-up, reusing Telemetry's summarization
  # (public — Telemetry stays untouched). No beat → the empty roll-up.
  defp service_health(nil), do: @empty_service_health
  defp service_health(%AgentEvent{} = e), do: Telemetry.normalize(e).checks

  defp to_rfc3339(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_rfc3339(_), do: nil
end
