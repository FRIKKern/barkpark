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

  It also covers `Telemetry.normalize_space/1` — the pure read half of the
  agent's new space payload, under the same hand-built-payload discipline (the
  route that LANDS it is proven over HTTP in `web/metrics_route_test.exs`).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Metrics
  alias BarkparkCloud.RealAgentBeats
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.AgentEvent
  alias BarkparkCloud.Telemetry

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
      assert env.service_health == %{pass: 0, skipped: 0, total: 0, failing: []}

      # A never-phoned-home box still destructures `latest` — all-absent, never
      # a zeroed database or a swap reading nobody took. `load15`/`cores`/`mem`/
      # `disk` joined it as the scalars the pressure verdict is computed from:
      # they live here so a verdict an operator disputes can be checked against
      # the same envelope that produced it.
      assert env.latest == %{
               db_size: nil,
               top_relations: nil,
               swap: %{used_pct: nil, total_bytes: nil},
               beam: %{pss_bytes: nil, swap_bytes: nil},
               load15: nil,
               cores: nil,
               mem: nil,
               disk: nil
             }

      # And the two blocks that make the envelope answer "is this box in
      # trouble, and what is eating it". A box with no beat is UNKNOWN, never
      # calm — a verdict computed from nothing must not read as a clean bill.
      assert env.pressure.state == "unknown"
      assert env.pressure.measured == 0
      assert env.pressure.of == 4

      # No space row → nil, distinct from "we measured and the disk is empty".
      assert env.space == nil
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
        health(70, %{
          "pg_size_bytes" => 111,
          "swap_total_bytes" => 2048,
          "swap_used_percent" => 90
        })
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
      env =
        build([
          health(5, %{"swap_used_percent" => -1, "swap_total_bytes" => -1, "pg_size_bytes" => -1})
        ])

      assert env.latest.swap == %{used_pct: nil, total_bytes: nil}
      assert env.latest.db_size == nil
    end

    test "an unmeasured relation list is nil; a measured-empty one stays []" do
      assert build([health(5, %{})]).latest.top_relations == nil
      assert build([health(5, %{"pg_top_relations" => []})]).latest.top_relations == []
    end

    test "a nil-payload beat still yields the fixed latest shape, never raises" do
      env =
        build([
          %AgentEvent{type: "health", payload: nil, inserted_at: DateTime.add(@now, -5, :second)}
        ])

      assert env.latest == %{
               db_size: nil,
               top_relations: nil,
               swap: %{used_pct: nil, total_bytes: nil},
               beam: %{pss_bytes: nil, swap_bytes: nil},
               load15: nil,
               cores: nil,
               mem: nil,
               disk: nil
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
      assert env.service_health == %{pass: 1, skipped: 0, total: 2, failing: ["tls"]}
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
      assert env.service_health == %{pass: 0, skipped: 0, total: 0, failing: []}
    end

    test "an empty / garbage event list yields the fixed all-absent envelope" do
      for junk <- [[], [%{}], ["x"]] do
        env = Metrics.build(bp(), junk, now: @now, points: 5)
        assert env.beat.status == "absent"
        assert env.series == empty_series()
      end
    end
  end

  # `Telemetry.normalize_space/1` is the READ half of the space payload the
  # agent now posts to /v1/agent/space — the pure sibling of `normalize/1`, and
  # the counterpart of the `latest` block above ("what is taking up space", but
  # for the whole BOX rather than just Postgres). It lives beside these tests
  # because it is the same pure, hand-built-payload discipline; the route that
  # LANDS the payload is proven over HTTP in web/metrics_route_test.exs.
  # ── The pressure verdict ───────────────────────────────────────────────────
  #
  # The failure these tests exist to prevent is ONE failure, and it already
  # happened: guerrilla read `ok / rank 8 / healthy` while it was 93% into swap
  # and answering 6,472 HTTP 500s in eight hours. Every case below is a way of
  # making sure the word this block prints cannot come apart from the numbers
  # that produced it.

  describe "pressure/1 — the verdict, and what it is allowed to say" do
    defp pressure_for(payload) do
      Metrics.build(%{id: "i", host: "h", provider: "hetzner"}, [health(10, payload)], now: @now).pressure
    end

    defp signal(pressure, key), do: Enum.find(pressure.signals, &(&1.key == key))

    test "THE CALIBRATION CASE: guerrilla's recorded 93%-swap state reads struggling" do
      p = pressure_for(RealAgentBeats.guerrilla_under_pressure())

      assert p.state == "struggling",
             "the box that 500'd 6,472 times in eight hours came out #{p.state}"

      # And the numbers that produced the word travel WITH it — a verdict an
      # operator cannot check is a verdict they learn to ignore.
      assert signal(p, "swap").state == "struggling"
      assert signal(p, "swap").value == 93

      # Load is judged PER CORE: 4.04 over 2 cores is 2.02, not "4.04, which is
      # fine". The divisor is what makes the number mean anything.
      load = signal(p, "load")
      assert load.state == "struggling"
      assert_in_delta load.value, 2.02, 0.001
      assert load.unit == "per_core"
    end

    test "disk at 75% is watch, NOT struggling — the deliberate non-alarm" do
      # Guerrilla was at 75% disk and disk was not what was hurting it. A
      # threshold set so every signal fires on the calibration case is a
      # threshold that only knows how to say "struggling".
      p = pressure_for(RealAgentBeats.guerrilla_under_pressure())
      assert signal(p, "disk").state == "watch"
      assert signal(p, "disk").value == 75
    end

    test "SELF-TEST ON REAL BYTES: the verbatim guerrilla capture is not calm" do
      # `guerrilla/0` is a real stored beat, not a shape invented to pass this.
      # 55% swap and 76% disk are both over their watch lines, so a verdict that
      # returns "calm" here is broken no matter what it does on hand-built input.
      p = pressure_for(RealAgentBeats.guerrilla())

      assert p.state == "watch"
      assert signal(p, "swap").state == "watch"
      assert signal(p, "disk").state == "watch"
      assert signal(p, "mem").state == "calm"

      # That capture predates #9888, so it carries neither load15 nor cpu_cores.
      # The honest reading is "unknown" — and the verdict still stands on the
      # three it COULD read, and says it read three.
      assert signal(p, "load").state == "unknown"
      assert signal(p, "load").value == nil
      assert p.measured == 3
      assert p.of == 4
    end

    test "nothing measured is UNKNOWN, never calm — silence is not health" do
      # This is the whole bug in one assertion. A box that reports no vitals at
      # all must not be rendered as a healthy box.
      p = pressure_for(%{"agent_status" => "online"})

      assert p.state == "unknown"
      assert p.measured == 0
      assert p.of == 4
      refute p.state == "calm"

      # A box that has never beaten at all takes the same path.
      no_beat = Metrics.build(%{id: "i", host: "h", provider: "p"}, [], now: @now).pressure
      assert no_beat.state == "unknown"
      assert no_beat.measured == 0
    end

    test "TOTAL: pressure/1 is public — a bare map, nil or garbage never raises" do
      # `pressure/1` is documented and callable on its own, so it must survive
      # inputs that never came through `latest/1`. Every one of them is
      # "unknown" with the full signal list — never a raise, and never a calm.
      for input <- [%{}, nil, "x", 7, [], %{swap: nil}, %{swap: %{}}] do
        p = Metrics.pressure(input)
        assert p.state == "unknown", "#{inspect(input)} produced #{p.state}"
        assert p.measured == 0
        assert p.of == 4
        assert length(p.signals) == 4
      end
    end

    test "every signal is listed always — including the calm and the unreadable" do
      # A verdict that silently drops the signals it could not read is a verdict
      # whose confidence cannot be judged.
      p = pressure_for(%{"swap_used_percent" => 5})

      assert Enum.map(p.signals, & &1.key) == ["swap", "mem", "load", "disk"]
      assert signal(p, "swap").state == "calm"

      for key <- ["mem", "load", "disk"] do
        assert signal(p, key).state == "unknown", "#{key} vanished instead of reading unknown"
        assert signal(p, key).value == nil
      end

      # Each signal carries the two lines it was judged against, so the verdict
      # is auditable off the payload alone.
      assert signal(p, "swap").watch_at == 50
      assert signal(p, "swap").struggling_at == 80
    end

    test "an unmeasured signal cannot raise the verdict OR talk it down" do
      struggling = %{"swap_used_percent" => 95}

      # Alone, swap decides.
      assert pressure_for(struggling).state == "struggling"

      # Adding three unmeasured signals must not soften it toward their absence,
      # and adding a CALM one must not average it away either.
      assert pressure_for(Map.put(struggling, "disk_used_percent", 3)).state == "struggling"
      assert pressure_for(Map.put(struggling, "mem_used_percent", 1)).state == "struggling"

      # The verdict is the WORST measured signal, not the mean of four.
      p =
        pressure_for(%{
          "swap_used_percent" => 95,
          "mem_used_percent" => 1,
          "disk_used_percent" => 1
        })

      assert p.state == "struggling"
      assert p.measured == 3
    end

    test "the -1 unwired sentinel is unmeasured, never a healthy zero" do
      # The agent stamps -1 for a probe it could not run. Read as a number, -1 is
      # below every threshold and would print as the calmest box in the fleet.
      p =
        pressure_for(%{
          "swap_used_percent" => -1,
          "disk_used_percent" => -1,
          "mem_used_percent" => -1
        })

      assert p.state == "unknown"
      assert p.measured == 0
      assert signal(p, "swap").value == nil
    end

    test "load without its divisor is unknown, not a raw comparison" do
      # 4.04 is two-deep on 2 cores and idle on 16. Without cores it is not a
      # smaller number — it is not a number, and must not be judged as one.
      p = pressure_for(%{"load15" => 4.04})
      assert signal(p, "load").state == "unknown"

      # Same load, different divisors, opposite verdicts — which is exactly why
      # the divisor has to travel in the beat.
      two = pressure_for(%{"load15" => 4.04, "cpu_cores" => 2})
      sixteen = pressure_for(%{"load15" => 4.04, "cpu_cores" => 16})
      assert signal(two, "load").state == "struggling"
      assert signal(sixteen, "load").state == "calm"

      # A zero/absent core count is refused, never divided by.
      assert signal(pressure_for(%{"load15" => 4.04, "cpu_cores" => 0}), "load").state ==
               "unknown"
    end
  end

  # ── The space block: what is eating the disk, without an SSH session ────────

  describe "space/1 — the read half that had no caller" do
    defp space_row(payload) do
      %AgentEvent{type: "space", payload: payload, inserted_at: DateTime.add(@now, -300, :second)}
    end

    defp built_space(event) do
      Metrics.build(%{id: "i", host: "h", provider: "p"}, [], now: @now, space_event: event).space
    end

    test "no space row is nil — distinct from a measured-and-empty disk" do
      assert built_space(nil) == nil
      assert Metrics.build(%{id: "i", host: "h", provider: "p"}, [], now: @now).space == nil
    end

    test "the envelope carries the sites tree, postgres AND the journal" do
      # The three consumers the row named as needing an SSH session to see:
      # sites 4.1G across its slugs, postgres 3.4G, journal 3.7G.
      space =
        built_space(
          space_row(%{
            "type" => "space",
            "root_used_bytes" => 30_000_000_000,
            "root_total_bytes" => 40_000_000_000,
            "journal_bytes" => 3_972_844_748,
            "pg_size_bytes" => 3_650_722_201,
            "pg_top_relations" => [%{"name" => "mutation_events", "bytes" => 1_534_328_832}],
            "sites_dir" => "/opt/barkpark/sites",
            "sites_bytes" => 4_402_341_478,
            "sites_top" => [
              %{"slug" => "search-ember", "bytes" => 699_400_192},
              %{"slug" => "search", "bytes" => 658_505_728}
            ],
            "sites_count" => 8
          })
        )

      assert space.journal_bytes == 3_972_844_748
      assert space.db_size == 3_650_722_201
      assert [%{name: "mutation_events"}] = space.top_relations
      assert space.sites.dir == "/opt/barkpark/sites"
      assert space.sites.bytes == 4_402_341_478
      assert [%{name: "search-ember", bytes: 699_400_192} | _] = space.sites.top
      assert space.root.used_bytes == 30_000_000_000
      assert space.reported_at != nil
    end

    test "the sites count survives so a reader can tell truncated from complete" do
      # Ten slugs and a total read IDENTICALLY whether the tree holds ten or
      # forty. The count is the only thing that separates them, so it has to
      # reach the surface — not just the payload.
      top = for i <- 1..10, do: %{"slug" => "site-#{i}", "bytes" => 1000 - i}

      truncated = built_space(space_row(%{"sites_top" => top, "sites_count" => 37}))
      assert length(truncated.sites.top) == 10
      assert truncated.sites.count == 37

      complete = built_space(space_row(%{"sites_top" => top, "sites_count" => 10}))
      assert complete.sites.count == length(complete.sites.top)

      # An agent too old to send the count, and one whose walk failed, are both
      # "we do not know" — never 0, which claims an empty tree.
      assert built_space(space_row(%{"sites_top" => top})).sites.count == nil
      assert built_space(space_row(%{"sites_count" => -1})).sites.count == -1
    end
  end

  describe "Telemetry.normalize_space/1 — honest absence, and the root PAIR" do
    test "a measured payload names every consumer, and sites_top's `slug` reads as a name" do
      space =
        Telemetry.normalize_space(%{
          "type" => "space",
          "root_used_bytes" => 12_000_000_000,
          "root_total_bytes" => 40_000_000_000,
          "journal_bytes" => 900_000_000,
          "pg_size_bytes" => 3_500_000_000,
          "pg_top_relations" => [
            %{"name" => "documents", "bytes" => 2_100_000_000},
            %{"name" => "agent_events", "bytes" => 400_000_000}
          ],
          "sites_dir" => "/opt/barkpark/sites",
          "sites_bytes" => 4_400_000_000,
          "sites_top" => [%{"slug" => "guerrilla", "bytes" => 3_000_000_000}]
        })

      # THE PAIR SURVIVES: used and total travel together, never collapsed into
      # a percent — 75% cannot tell a 40 GB box from a 400 GB one.
      assert space.root == %{used_bytes: 12_000_000_000, total_bytes: 40_000_000_000}
      assert space.journal_bytes == 900_000_000
      assert space.db_size == 3_500_000_000

      assert space.top_relations == [
               %{name: "documents", bytes: 2_100_000_000},
               %{name: "agent_events", bytes: 400_000_000}
             ]

      assert space.sites.dir == "/opt/barkpark/sites"
      assert space.sites.bytes == 4_400_000_000
      assert space.sites.top == [%{name: "guerrilla", bytes: 3_000_000_000}]
      # A bare payload map is undatable — the event stamps reported_at.
      assert space.reported_at == nil
    end

    test "the -1 sentinel passes through VERBATIM and is never zeroed" do
      space =
        Telemetry.normalize_space(%{
          "root_used_bytes" => -1,
          "root_total_bytes" => -1,
          "journal_bytes" => -1,
          "pg_size_bytes" => -1,
          "sites_bytes" => -1
        })

      assert space.root == %{used_bytes: -1, total_bytes: -1}
      assert space.journal_bytes == -1
      assert space.db_size == -1
      assert space.sites.bytes == -1
    end

    test "an unmeasured list is nil, an honestly EMPTY list stays [] — different facts" do
      unmeasured = Telemetry.normalize_space(%{"pg_top_relations" => nil, "sites_top" => nil})
      assert unmeasured.top_relations == nil
      assert unmeasured.sites.top == nil
      # Absent keys behave the same as an explicit JSON null.
      assert Telemetry.normalize_space(%{}).sites.top == nil

      measured = Telemetry.normalize_space(%{"pg_top_relations" => [], "sites_top" => []})
      assert measured.top_relations == []
      assert measured.sites.top == []
    end

    test "TOTAL: garbage in, the fixed all-absent envelope out — never a raise" do
      for junk <- [nil, "x", 7, [], %{"root_used_bytes" => "lots", "sites_top" => "nope"}] do
        space = Telemetry.normalize_space(junk)
        assert space.root == %{used_bytes: nil, total_bytes: nil}
        assert space.journal_bytes == nil
        assert space.db_size == nil
        assert space.top_relations == nil
        assert space.sites == %{dir: nil, bytes: nil, top: nil, count: nil}
        assert space.reported_at == nil
      end
    end

    test "a root that is NOT ON THIS BOX lands as `absent` with no bytes — never a zero" do
      # The build-plane box's real payload shape, 2026-08-22: it has no
      # /opt/barkpark/sites at all, while 25 GB sits in two roots the sites axis
      # structurally cannot see.
      space =
        Telemetry.normalize_space(%{
          "sites_dir" => "/opt/barkpark/sites",
          "sites_bytes" => -1,
          "consumer_roots" => [
            %{
              "path" => "/var/lib/containerd",
              "status" => "read",
              "bytes" => 15_032_385_536,
              "count" => 11,
              "top" => [
                %{"name" => "io.containerd.snapshotter.v1.overlayfs", "bytes" => 12_884_901_888}
              ]
            },
            %{
              "path" => "/var/lib/barkpark-builder",
              "status" => "read",
              "bytes" => 11_811_160_064,
              "count" => 2,
              "top" => [%{"name" => "images", "bytes" => 11_811_160_064}]
            },
            %{
              "path" => "/opt/barkpark/sites",
              "status" => "absent",
              "bytes" => -1,
              "count" => -1,
              "top" => nil
            }
          ]
        })

      assert length(space.consumer_roots) == 3,
             "the ABSENT root must SURVIVE normalization — a dropped row is indistinguishable " <>
               "from a root that holds nothing, which is the same lie in a quieter form"

      absent = Enum.find(space.consumer_roots, &(&1.path == "/opt/barkpark/sites"))
      assert absent.status == "absent"

      refute absent.bytes == 0,
             "an absent root normalized to 0 bytes claims an empty tree about a directory " <>
               "that is not on the box — the exact reading that let a 100%-full builder rank healthy"

      # Verbatim, like every other number here: the view words the sentinel.
      assert absent.bytes == -1
      assert absent.count == -1
      assert absent.top == nil

      containerd = Enum.find(space.consumer_roots, &(&1.path == "/var/lib/containerd"))
      assert containerd.status == "read"
      assert containerd.bytes == 15_032_385_536

      assert containerd.top == [
               %{name: "io.containerd.snapshotter.v1.overlayfs", bytes: 12_884_901_888}
             ]

      builder = Enum.find(space.consumer_roots, &(&1.path == "/var/lib/barkpark-builder"))

      assert containerd.bytes + builder.bytes == 26_843_545_600,
             "the 25 GiB the sites axis could not see must arrive whole"
    end

    test "consumer_roots: absent list vs. empty list, unknown status, and a pathless row" do
      # No field at all (an agent predating the axis) is NOT MEASURED...
      assert Telemetry.normalize_space(%{}).consumer_roots == nil
      assert Telemetry.normalize_space(%{"consumer_roots" => nil}).consumer_roots == nil
      assert Telemetry.normalize_space(%{"consumer_roots" => "nope"}).consumer_roots == nil

      # ...while an agent told to measure NO roots sends [] and keeps it. An
      # operator resolves those two differently (upgrade the box vs. change the
      # unit file), so they must not collapse.
      assert Telemetry.normalize_space(%{"consumer_roots" => []}).consumer_roots == []

      space =
        Telemetry.normalize_space(%{
          "consumer_roots" => [
            # No path: cannot be rendered, cannot be acted on, dropped.
            %{"status" => "read", "bytes" => 5},
            "garbage",
            # A word this control plane does not know degrades to `unmeasured` —
            # the only safe direction. Coercing toward "read" or "absent" would
            # assert a measurement nobody made.
            %{"path" => "/var/lib/snapd", "status" => "brand-new-word", "bytes" => -1}
          ]
        })

      assert Enum.map(space.consumer_roots, & &1.path) == ["/var/lib/snapd"]
      assert hd(space.consumer_roots).status == "unmeasured"
    end

    test "a malformed consumer row is dropped, never rendered nameless or sizeless" do
      space =
        Telemetry.normalize_space(%{
          "sites_top" => [
            %{"slug" => "ok", "bytes" => 10},
            %{"slug" => "no-bytes"},
            %{"bytes" => 5},
            "garbage"
          ]
        })

      assert space.sites.top == [%{name: "ok", bytes: 10}]
    end

    test "a full %AgentEvent{} stamps reported_at from the row's inserted_at" do
      event = %AgentEvent{
        type: "space",
        payload: %{"root_used_bytes" => 5},
        inserted_at: DateTime.add(@now, -30, :second)
      }

      space = Telemetry.normalize_space(event)
      assert space.root.used_bytes == 5
      assert space.reported_at == "2026-07-09T11:59:30.000000Z"
    end
  end
end
