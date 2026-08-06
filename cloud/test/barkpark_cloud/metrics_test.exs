defmodule BarkparkCloud.MetricsTest do
  @moduledoc """
  `Metrics.build/3` is a PURE, TOTAL fold of a window of health beats into the
  time-series envelope (charter S12 / decisions 30-31). These tests exercise it
  directly — no DB, no HTTP — with hand-built `%AgentEvent{}`s and an INJECTED
  clock, proving:

    * a full window maps every vital into oldest-to-newest series
    * the agent's `-1` "unwired" sentinel and an absent field both become `null`
      points (nil-not-zero), while a real `0` stays `0`
    * events handed in newest-first come out oldest-to-newest in every series
    * beat.status is live / stale / absent off Registry.health_stale_after_seconds()
    * service_health is the newest beat's check roll-up (reused from Telemetry)
    * non-health events are filtered out of the window
    * garbage / empty / nil-payload inputs never raise (the totality guarantee)
    * `latest` carries the newest beat's scalars (db size + named top relations,
      the swap PAIR, the BEAM footprint) with the same nil-not-zero discipline,
      proven against a REAL captured beat
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Metrics
  alias BarkparkCloud.RealAgentBeats
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.AgentEvent

  # The series key set is DEFINED by Metrics's @vitals; asserting it whole is the
  # tripwire that a key added there is a deliberate contract change (the Go
  # renderer's metricTopSpecs must gain it too or the number ships invisibly).
  @series_keys [:beam_pss, :beam_swap, :cpu, :disk, :load, :mem, :swap]

  defp empty_series, do: Map.new(@series_keys, &{&1, []})

  @now ~U[2026-07-09 12:00:00.000000Z]

  # A health event `secs` seconds before @now with the given vital payload.
  defp health(secs, payload) do
    %AgentEvent{
      type: "health",
      payload: payload,
      inserted_at: DateTime.add(@now, -secs, :second)
    }
  end

  defp full_vitals(overrides \\ %{}) do
    Map.merge(
      %{
        "cpu_percent" => 40,
        "mem_used_percent" => 55,
        "disk_used_percent" => 60,
        "load1" => 1.25
      },
      overrides
    )
  end

  defp bp, do: %{id: "bp-123", host: "203.0.113.9", provider: "azure"}

  defp build(events, opts \\ []) do
    Metrics.build(bp(), events, Keyword.merge([now: @now, points: 30], opts))
  end

  describe "build/3 — envelope shape + instance identity" do
    test "fixed top-level keys and instance identity, even for an empty window" do
      env = build([])

      assert env.ok == true
      assert env.collected_at == "2026-07-09T12:00:00.000000Z"
      assert env.instance == %{id: "bp-123", host: "203.0.113.9", provider: "azure"}
      assert env.points == 30
      assert Map.keys(env.series) |> Enum.sort() == @series_keys
      assert env.series == empty_series()
      assert env.beat == %{last_seen_at: nil, age_seconds: nil, status: "absent"}
      assert env.service_health == %{pass: 0, total: 0, failing: []}

      # A never-phoned-home box still destructures `latest` — all-absent, never
      # a zeroed database or a swap reading nobody took.
      assert env.latest == %{
               db_size: nil,
               top_relations: nil,
               swap: %{used_pct: nil, total_bytes: nil},
               beam: %{pss_bytes: nil, swap_bytes: nil}
             }
    end

    test "points echoes the requested (clamped) window size" do
      assert build([], points: 200).points == 200
    end
  end

  describe "build/3 — series mapping + honesty" do
    test "a full window maps every vital to its series point" do
      env = build([health(10, full_vitals())])

      at = "2026-07-09T11:59:50.000000Z"
      assert env.series.cpu == [%{at: at, value: 40}]
      assert env.series.mem == [%{at: at, value: 55}]
      assert env.series.disk == [%{at: at, value: 60}]
      assert env.series.load == [%{at: at, value: 1.25}]
    end

    test "the -1 sentinel and an absent field become null points; a real 0 stays 0" do
      # disk unwired (-1), load absent entirely, cpu genuinely idle (0).
      payload =
        full_vitals(%{"cpu_percent" => 0, "disk_used_percent" => -1})
        |> Map.delete("load1")

      env = build([health(5, payload)])

      assert env.series.cpu == [%{at: "2026-07-09T11:59:55.000000Z", value: 0}]
      assert [%{value: nil}] = env.series.disk
      assert [%{value: nil}] = env.series.load
      # mem was a real reading and survives.
      assert [%{value: 55}] = env.series.mem
    end

    test "a non-number vital (string / bool) is nil, never passed through or crashed" do
      env = build([health(5, %{"cpu_percent" => "high", "load1" => true})])
      assert [%{value: nil}] = env.series.cpu
      assert [%{value: nil}] = env.series.load
    end

    test "events handed in newest-first come out oldest-to-newest in every series" do
      events = [
        health(10, full_vitals(%{"cpu_percent" => 30})),
        health(70, full_vitals(%{"cpu_percent" => 20})),
        health(130, full_vitals(%{"cpu_percent" => 10}))
      ]

      env = build(events)
      # Oldest (130s ago, cpu 10) first → newest (10s ago, cpu 30) last.
      assert Enum.map(env.series.cpu, & &1.value) == [10, 20, 30]

      ats = Enum.map(env.series.cpu, & &1.at)
      assert ats == Enum.sort(ats), "series must be ascending by timestamp"
    end
  end

  describe "build/3 — the new vitals series (swap + the BEAM)" do
    test "swap and the BEAM's own footprint trend beside the shipped four" do
      events = [
        health(10, %{
          "swap_used_percent" => 55,
          "beam_pss_bytes" => 1_258_798_080,
          "beam_swap_bytes" => 329_543_680
        }),
        health(70, %{
          "swap_used_percent" => 40,
          "beam_pss_bytes" => 1_000_000_000,
          "beam_swap_bytes" => 0
        })
      ]

      env = build(events)

      assert Enum.map(env.series.swap, & &1.value) == [40, 55]
      assert Enum.map(env.series.beam_pss, & &1.value) == [1_000_000_000, 1_258_798_080]
      # A real 0 of paged-out BEAM is data (nothing swapped out yet), not a gap.
      assert Enum.map(env.series.beam_swap, & &1.value) == [0, 329_543_680]
    end

    test "the -1 sentinel is a GAP in the new series too, exactly like the old four" do
      env =
        build([
          health(5, %{
            "swap_used_percent" => -1,
            "swap_total_bytes" => -1,
            "beam_pss_bytes" => -1,
            "beam_swap_bytes" => -1
          })
        ])

      assert [%{value: nil}] = env.series.swap
      assert [%{value: nil}] = env.series.beam_pss
      assert [%{value: nil}] = env.series.beam_swap
    end

    test "a pre-upgrade beat that never sends the keys is all gaps, never zeros" do
      env = build([health(5, RealAgentBeats.pre_upgrade())])

      assert [%{value: nil}] = env.series.swap
      assert [%{value: nil}] = env.series.beam_pss
      assert [%{value: nil}] = env.series.beam_swap
      # The vitals that box DOES report still trend.
      assert [%{value: 12}] = env.series.cpu
      assert [%{value: 95}] = env.series.disk
    end
  end

  describe "build/3 — latest (the newest beat's scalars)" do
    test "a REAL captured beat folds into the storage + swap + BEAM scalars" do
      # Not a hand-built map: the exact jsonb the router landed for guerrilla.
      env = build([health(10, RealAgentBeats.guerrilla()), health(70, %{"cpu_percent" => 1})])

      assert env.latest.db_size == 3_525_639_191
      assert env.latest.swap == %{used_pct: 55, total_bytes: 2_147_479_552}
      assert env.latest.beam == %{pss_bytes: 1_258_798_080, swap_bytes: 329_543_680}

      # The named breakdown answers "what is taking up space", biggest first.
      assert [
               %{name: "mutation_events", bytes: 1_534_328_832},
               %{name: "revisions", bytes: 1_332_666_368} | _
             ] = env.latest.top_relations
    end

    test "latest reads the NEWEST beat only — an older beat never overrules it" do
      events = [
        health(10, %{"pg_size_bytes" => 999, "swap_total_bytes" => 0, "swap_used_percent" => 0}),
        health(70, %{"pg_size_bytes" => 111, "swap_total_bytes" => 2048, "swap_used_percent" => 90})
      ]

      env = build(events)
      assert env.latest.db_size == 999
      assert env.latest.swap == %{used_pct: 0, total_bytes: 0}
    end

    test "a swapless box's honest 0 total SURVIVES — it is the answer, not a gap" do
      env = build([health(5, %{"swap_used_percent" => 0, "swap_total_bytes" => 0})])
      # 0 total is what lets a renderer say "none configured" without the control
      # plane minting a reason word for it.
      assert env.latest.swap == %{used_pct: 0, total_bytes: 0}
    end

    test "the -1 sentinel becomes nil in latest — distinct from a swapless 0" do
      env = build([health(5, %{"swap_used_percent" => -1, "swap_total_bytes" => -1, "pg_size_bytes" => -1})])

      assert env.latest.swap == %{used_pct: nil, total_bytes: nil}
      assert env.latest.db_size == nil
    end

    test "an unmeasured relation list is nil; a measured-empty one stays []" do
      assert build([health(5, %{})]).latest.top_relations == nil
      assert build([health(5, %{"pg_top_relations" => []})]).latest.top_relations == []
    end

    test "a nil-payload beat still yields the fixed latest shape, never raises" do
      env =
        build([%AgentEvent{type: "health", payload: nil, inserted_at: DateTime.add(@now, -5, :second)}])

      assert env.latest == %{
               db_size: nil,
               top_relations: nil,
               swap: %{used_pct: nil, total_bytes: nil},
               beam: %{pss_bytes: nil, swap_bytes: nil}
             }
    end
  end

  describe "build/3 — beat status off the CP-wide threshold" do
    test "a recent beat is live" do
      # 10s ≤ 180s default threshold.
      assert build([health(10, full_vitals())]).beat.status == "live"
      assert build([health(10, full_vitals())]).beat.age_seconds == 10
    end

    test "a beat older than health_stale_after_seconds is stale" do
      stale = Registry.health_stale_after_seconds() + 60
      env = build([health(stale, full_vitals())])
      assert env.beat.status == "stale"
      assert env.beat.age_seconds == stale
    end

    test "no health beat at all is absent" do
      assert build([]).beat.status == "absent"
    end

    test "a beat exactly at the threshold is still live (boundary is inclusive)" do
      at_edge = Registry.health_stale_after_seconds()
      assert build([health(at_edge, full_vitals())]).beat.status == "live"
    end
  end

  describe "build/3 — service_health from the newest beat" do
    test "rolls up the newest beat's health_checks (reused from Telemetry)" do
      newest =
        health(10, %{
          "health_checks" => [
            %{"name" => "websocket", "pass" => true},
            %{"name" => "tls", "pass" => false}
          ]
        })

      # An older beat with different checks must NOT contribute.
      older = health(120, %{"health_checks" => [%{"name" => "x", "pass" => true}]})

      env = build([newest, older])
      assert env.service_health == %{pass: 1, total: 2, failing: ["tls"]}
    end
  end

  describe "build/3 — window filtering + totality" do
    test "non-health events are excluded from the window" do
      events = [
        %AgentEvent{type: "backup", payload: %{"ok" => true}, inserted_at: @now},
        health(20, full_vitals(%{"cpu_percent" => 42})),
        %AgentEvent{type: "verify", payload: %{}, inserted_at: @now}
      ]

      env = build(events)
      assert Enum.map(env.series.cpu, & &1.value) == [42]
      assert env.beat.status == "live"
    end

    test "a nil / non-map payload never raises — its vitals are all null" do
      events = [
        %AgentEvent{type: "health", payload: nil, inserted_at: DateTime.add(@now, -5, :second)}
      ]

      env = build(events)
      assert [%{value: nil}] = env.series.cpu
      assert [%{value: nil}] = env.series.load
      # A payload-less beat still counts as a live beat + empty service health.
      assert env.beat.status == "live"
      assert env.service_health == %{pass: 0, total: 0, failing: []}
    end

    test "an empty / garbage event list yields the fixed all-absent envelope" do
      for junk <- [[], [%{}], ["x"]] do
        env = Metrics.build(bp(), junk, now: @now, points: 5)
        assert env.beat.status == "absent"
        assert env.series == empty_series()
      end
    end
  end
end
