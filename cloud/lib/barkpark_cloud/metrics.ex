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
          beam: %{pss_bytes: number | nil, swap_bytes: number | nil},
          load15: number | nil,
          cores: number | nil
        },
        pressure: %{                               # the VERDICT — see `pressure/1`
          state: "struggling" | "watch" | "calm" | "unknown",
          measured: non_neg_integer,
          of: pos_integer,
          signals: [%{key: ..., state: ..., value: ..., unit: ..., watch_at: ..., struggling_at: ...}]
        },
        space: %{                                  # newest SPACE row — see `space/1`
          root: %{used_bytes: ..., total_bytes: ...},
          journal_bytes: number | nil,
          db_size: number | nil,
          top_relations: [...] | nil,
          sites: %{dir: ..., bytes: ..., top: [...] | nil, count: number | nil},
          # The build plane's roots. Each carries a status of "read" | "absent"
          # | "unmeasured" — a root that is not on this box says ABSENT and
          # keeps the -1 sentinel, never 0 bytes.
          consumer_roots: [%{path: ..., status: ..., bytes: ..., top: [...] | nil, count: ...}] | nil,
          reported_at: String.t() | nil
        } | nil,
        service_health: %{
          pass: non_neg_integer,
          skipped: non_neg_integer,
          total: non_neg_integer,
          failing: [String.t()]
        }
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

  `pressure` and `space` are the two blocks that answer "is this box in
  trouble, and what is eating it" WITHOUT an SSH session. Both are computed
  HERE, once, so the console and `bp cloud instance top` render one verdict
  rather than each inventing its own threshold and drifting apart. `space` is
  the newest `"space"` AgentEvent through `Telemetry.normalize_space/1` — that
  row rides its OWN 15-minute cadence on its own route, so it is passed in
  separately (`:space_event`) and is `nil` on a box that has never sent one.
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

  @empty_service_health %{pass: 0, skipped: 0, total: 0, failing: []}

  # The all-absent `latest` block — the fixed shape a never-phoned-home box (and
  # a pre-upgrade agent that sends none of these keys) still destructures.
  @empty_latest %{
    db_size: nil,
    top_relations: nil,
    swap: %{used_pct: nil, total_bytes: nil},
    beam: %{pss_bytes: nil, swap_bytes: nil},
    load15: nil,
    cores: nil,
    mem: nil,
    disk: nil
  }

  # The pressure signals, their thresholds, and WHOSE JUDGEMENT THEY ARE.
  #
  # These four numbers decide whether a box reads "struggling", so they are
  # written down with their evidence rather than left as constants nobody
  # re-measures. The calibration case is guerrilla (157.180.90.121, 2 vCPU /
  # 3.8 GB) as measured 2026-08-06..08, which is the case that motivated this
  # whole surface:
  #
  #     swap 1904/2047 MB (93%) · free mem 293 MB of 3819 · load15 1.89-2.02
  #     per core on 2 cores · disk 75% · four concurrent site builds
  #
  # In that state the box answered 6,472 HTTP 500s in eight hours (76 of them
  # the DBConnection-timeout-under-swap-thrash class) while `bp cloud status`
  # reported it `ok / healthy`. So the ONE hard requirement these thresholds
  # have to meet is: that state must not read as calm. That requirement is a
  # test — metrics_test.exs "THE CALIBRATION CASE", against the recorded state
  # in RealAgentBeats.guerrilla_under_pressure/0, with the console's twin in
  # __app.test.mjs under the same name.
  #
  # What is measured and what is judged, stated separately so a later reader can
  # tell them apart:
  #
  #   * MEASURED — swap at 93% coincided with the 500s; swap at rest did not.
  #     Swap is also the signal `mem_used_percent` actively HIDES (MemAvailable
  #     clears the floor precisely BECAUSE the BEAM was paged out, so a box at
  #     99% swap can report a comfortable 58% memory). It is the causal one.
  #   * JUDGED — the exact boundaries. One calibrated sick point (93%) and one
  #     calibrated well point (0%) cannot locate a threshold between them; 50/80
  #     is a judgement, made here, on the reasoning that ANY sustained swap on a
  #     box whose working set is a BEAM means paging the thing that serves
  #     requests. Move it with evidence, not with taste.
  #   * DELIBERATELY NOT ALARMING — disk 75% is `watch`, not `struggling`.
  #     Guerrilla was at 75% and disk was not what was hurting it. A threshold
  #     tuned so every signal fires on the calibration case is a threshold tuned
  #     to say "struggling" always.
  #
  # `load` is judged PER CORE (load15 / cores), never raw: 2.0 is idle on 16
  # cores and a queue two deep on 2. Its divisor travels in the same beat.
  @pressure_signals [
    %{key: "swap", unit: "pct", watch_at: 50, struggling_at: 80},
    %{key: "mem", unit: "pct", watch_at: 85, struggling_at: 92},
    %{key: "load", unit: "per_core", watch_at: 1.0, struggling_at: 1.5},
    %{key: "disk", unit: "pct", watch_at: 75, struggling_at: 90}
  ]

  # Severity order, worst LAST. "unknown" is not on this ladder on purpose: an
  # unmeasured signal must never be able to win the verdict in either
  # direction — it can neither raise an alarm nor talk one down.
  @pressure_ladder ["calm", "watch", "struggling"]

  @doc """
  Fold a window of `barkpark`'s agent events into the metrics envelope.

  `events` is the window newest-first (as `Registry.recent_events_of_type/3`
  returns); only `"health"` events contribute — a second fence, not the first
  (see the module doc: the LIMIT lives at the fetch). `opts`:

    * `:points` — the requested (already-clamped) window size echoed into the
      envelope. Defaults to `30`.
    * `:now` — the current time for the beat's `age_seconds`/`status`. Defaults
      to `DateTime.utc_now/0`; tests inject a fixed clock.
    * `:space_event` — the newest `"space"` `%AgentEvent{}`, or nil. It is NOT
      taken from `events`: the space row rides its own 15-minute cadence on its
      own route, and `events` is the health window (type-filtered at the fetch,
      D58). Absent → `space: nil`, which is the honest "this box has not sent a
      space report", never an all-zero breakdown.
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

    # Folded ONCE and shared: `pressure` is computed from exactly the scalars
    # the envelope publishes as `latest`, so an operator who disputes the
    # verdict can check it against the same numbers in the same response.
    # Two calls could not drift today, but they are two places to edit.
    latest = latest(newest)

    %{
      ok: true,
      collected_at: to_rfc3339(now),
      instance: instance_info(barkpark),
      beat: beat(newest, now),
      points: points,
      series: series(oldest_first),
      latest: latest,
      pressure: pressure(latest),
      space: space(Keyword.get(opts, :space_event)),
      service_health: service_health(newest)
    }
  end

  @doc """
  The newest SPACE row as a stable envelope, or `nil` when the box has never
  sent one.

  This is `Telemetry.normalize_space/1`'s production caller. The agent has
  measured root/journal/postgres/per-slug space and POSTed it to
  `/v1/agent/space` since #9889; until this call existed the row landed in
  `agent_events` and no read surface ever served it, so "what is eating the
  disk" was still an SSH question with the answer already in the database.

  `nil` (not an all-nil envelope) is deliberate: a renderer must be able to say
  "no space report yet" differently from "we measured and found nothing",
  which is the same nil-not-zero doctrine one level up.
  """
  @spec space(AgentEvent.t() | nil) :: map() | nil
  def space(nil), do: nil
  def space(%AgentEvent{} = event), do: Telemetry.normalize_space(event)
  def space(_), do: nil

  @doc """
  The pressure VERDICT for one box, from its newest beat's scalars.

  Answers the question the four sparklines never did: *is this box in trouble
  right now?* — in a word an operator can scan a fleet by, with the numbers that
  produced the word travelling beside it so the word is checkable.

  Computed in the control plane, once, because it has two consumers (the
  console's Metrics tab and `bp cloud instance top`) and a threshold duplicated
  per surface is a threshold that drifts per surface.

  ## The shape

      %{
        state: "struggling" | "watch" | "calm" | "unknown",
        measured: 3,          # signals that produced a reading
        of: 4,                # signals considered
        signals: [%{
          key: "swap", state: "struggling", value: 93.0, unit: "pct",
          watch_at: 50, struggling_at: 80
        }, ...]
      }

  ## Rules that keep it from lying

    * **The verdict is the WORST measured signal.** Not an average — averaging
      four signals is how a box at 93% swap comes out "moderate" and reads calm.
    * **EVERY signal is listed, always**, including the calm ones and the ones
      that could not be measured (`state: "unknown"`, `value: nil`). A verdict
      that silently drops the signals it could not read is a verdict whose
      confidence you cannot judge.
    * **An unmeasured signal never decides anything.** It cannot raise the
      state and it cannot talk it down.
    * **Nothing measured → `"unknown"`, never `"calm"`.** This is the whole
      failure mode this block exists to end: guerrilla read `ok / healthy` while
      it was 500ing, because absence of a reading was rendered as a good
      reading. Silence is not health.
    * **`measured`/`of` always travel**, so `"calm"` computed from one of four
      signals is legible as the weak claim it is rather than a clean bill.

  Thresholds and their evidence: see `@pressure_signals`.
  """
  @spec pressure(map()) :: map()
  def pressure(latest) when is_map(latest) do
    signals = Enum.map(@pressure_signals, &signal(&1, latest))
    measured = Enum.reject(signals, &(&1.state == "unknown"))

    # The verdict is the worst MEASURED signal — never an average, which is how
    # a box at 93% swap comes out "moderate". Nothing measured is "unknown", the
    # one state that must never collapse into "calm".
    state =
      case measured do
        [] -> "unknown"
        rows -> rows |> Enum.map(& &1.state) |> Enum.max_by(&severity/1)
      end

    %{
      state: state,
      measured: length(measured),
      of: length(@pressure_signals),
      signals: signals
    }
  end

  def pressure(_), do: pressure(@empty_latest)

  # One signal: its reading, and where that reading falls against its two
  # thresholds. An absent reading is "unknown" with a nil value — never a 0 that
  # would read as a healthy floor.
  defp signal(%{key: key} = spec, latest) do
    value = pressure_value(key, latest)

    base = %{
      key: key,
      unit: spec.unit,
      watch_at: spec.watch_at,
      struggling_at: spec.struggling_at,
      value: value
    }

    Map.put(base, :state, band(value, spec))
  end

  # Rank on the ladder. An unlisted state sorts to the floor rather than raising
  # (a nil index would crash the comparison); "unknown" never reaches here — it
  # is filtered out before the max.
  defp severity(state), do: Enum.find_index(@pressure_ladder, &(&1 == state)) || -1

  defp band(nil, _spec), do: "unknown"
  defp band(v, %{struggling_at: at}) when is_number(v) and v >= at, do: "struggling"
  defp band(v, %{watch_at: at}) when is_number(v) and v >= at, do: "watch"
  defp band(v, _spec) when is_number(v), do: "calm"
  defp band(_, _), do: "unknown"

  # Each signal's reading, pulled from the SAME normalized scalars the envelope
  # already publishes — so a value the operator disputes can be read straight off
  # `latest` and checked against the verdict.
  defp pressure_value("swap", %{swap: %{used_pct: pct}}), do: measured(pct)
  defp pressure_value("mem", latest), do: measured(Map.get(latest, :mem))
  defp pressure_value("disk", latest), do: measured(Map.get(latest, :disk))

  # Load is per core, and it is nil unless BOTH halves are real: a load average
  # divided by an unknown core count is not a smaller number, it is not a number.
  # `cores <= 0` is refused for the same reason (and never divided by).
  defp pressure_value("load", latest) do
    with l when is_number(l) <- measured(Map.get(latest, :load15)),
         c when is_number(c) and c > 0 <- measured(Map.get(latest, :cores)) do
      l / c
    else
      _ -> nil
    end
  end

  defp pressure_value(_, _), do: nil

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
      },
      # load15 + its divisor, and the two percents the verdict reads. `cores` is
      # not a vital anyone charts — it is the number without which `load15` is
      # uninterpretable, so it rides here beside it rather than being looked up
      # elsewhere by each consumer.
      load15: measured(t.load15),
      cores: measured(t.cores),
      mem: measured(t.mem),
      disk: measured(t.disk.used_pct)
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
