defmodule BarkparkCloud.TelemetryTest do
  @moduledoc """
  `Telemetry.normalize/1` is a PURE, TOTAL normalizer over the agent's captured
  health payload (charter decision 16 — observability from data already
  captured). These tests exercise it directly, no DB, no HTTP:

    * a FULL payload maps every field to the stable envelope
    * a PARTIAL payload (missing disk) fills the gap with `nil`, keeps the rest
    * an ABSENT / empty / garbage payload yields the all-absent envelope and
      NEVER raises (the totality guarantee)
    * `health_checks` rolls up to correct {pass, skipped, total, failing},
      including the some-failing case and the three-state `status` field
    * a full `%AgentEvent{}` stamps `reported_at` from its `inserted_at`
    * a REAL stored beat (captured verbatim from the control plane, not a
      hand-built map) folds into the envelope — see `real_guerrilla_beat/0`
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.RealAgentBeats
  alias BarkparkCloud.Telemetry
  alias BarkparkCloud.Registry.AgentEvent

  # Mirrors the real jsonb shape: STRING keys, agent field names, the CheckResult
  # boolean under "pass" (see internal/cli/setup/healthgate.go).
  defp full_payload do
    %{
      "disk_used_percent" => 42,
      "pg_size_bytes" => 123_456_789,
      "pg_top_relations" => [
        %{"name" => "mutation_events", "bytes" => 80_000_000},
        %{"name" => "revisions", "bytes" => 30_000_000}
      ],
      "swap_used_percent" => 51,
      "swap_total_bytes" => 2_147_479_552,
      "beam_pss_bytes" => 1_843_045_376,
      "beam_swap_bytes" => 12_345_678,
      "cpu_percent" => 37,
      "mem_used_percent" => 58,
      "load1" => 0.42,
      "load15" => 1.07,
      "cpu_cores" => 2,
      "req_per_s" => 12,
      "p95_ms" => 140,
      "backup_ok" => true,
      "backup_detail" => "daily backup 2h ago",
      "dirty_tree" => false,
      "health_checks" => [
        %{"name" => "websocket", "pass" => true, "detail" => "not 403"},
        %{"name" => "tls", "pass" => true, "detail" => "valid 60d"},
        %{"name" => "capabilities", "pass" => true, "detail" => "200"}
      ]
    }
  end

  describe "normalize/1 — full payload" do
    test "maps every field into the stable envelope" do
      assert Telemetry.normalize(full_payload()) == %{
               disk: %{used_pct: 42},
               db_size: 123_456_789,
               top_relations: [
                 %{name: "mutation_events", bytes: 80_000_000},
                 %{name: "revisions", bytes: 30_000_000}
               ],
               swap: %{used_pct: 51, total_bytes: 2_147_479_552},
               beam: %{pss_bytes: 1_843_045_376, swap_bytes: 12_345_678},
               cpu: 37,
               mem: 58,
               load1: 0.42,
               # load15 + its divisor: a load average without the core count is
               # not a comparable number at all (2.0 is idle on 16 cores and a
               # queue two deep on 2), so the divisor is part of the reading.
               load15: 1.07,
               cores: 2,
               req_per_s: 12,
               p95_ms: 140,
               backup: %{ok: true, detail: "daily backup 2h ago"},
               checks: %{pass: 3, skipped: 0, total: 3, failing: []},
               dirty_tree: false,
               reported_at: nil
             }
    end
  end

  describe "normalize/1 — partial payload (missing disk)" do
    test "the missing signal becomes nil; present signals are preserved" do
      payload = Map.delete(full_payload(), "disk_used_percent")
      env = Telemetry.normalize(payload)

      assert env.disk == %{used_pct: nil}
      assert env.db_size == 123_456_789
      assert env.backup == %{ok: true, detail: "daily backup 2h ago"}
      assert env.checks == %{pass: 3, skipped: 0, total: 3, failing: []}
      assert env.dirty_tree == false
    end

    test "an unwired disk probe's -1 sentinel passes through verbatim (not the normalizer's job to reinterpret)" do
      payload = Map.put(full_payload(), "disk_used_percent", -1)
      assert Telemetry.normalize(payload).disk == %{used_pct: -1}
    end

    test "machine vitals map through num_or_nil; -1 sentinels pass through verbatim, absent → nil" do
      env =
        full_payload()
        |> Map.merge(%{"cpu_percent" => -1, "load1" => -1})
        |> Map.delete("req_per_s")
        |> Map.delete("p95_ms")
        |> Telemetry.normalize()

      # -1 rides verbatim (the meter builder, not the normalizer, reads it as "not
      # measured") …
      assert env.cpu == -1
      assert env.load1 == -1
      # … a still-reported signal is preserved …
      assert env.mem == 58
      # … and an absent signal (an older instance runtime) is honestly nil.
      assert env.req_per_s == nil
      assert env.p95_ms == nil
    end
  end

  describe "normalize/1 — absent / empty / garbage payloads never crash" do
    test "empty map → all-absent envelope, fixed shape" do
      assert Telemetry.normalize(%{}) == %{
               disk: %{used_pct: nil},
               db_size: nil,
               top_relations: nil,
               swap: %{used_pct: nil, total_bytes: nil},
               beam: %{pss_bytes: nil, swap_bytes: nil},
               cpu: nil,
               mem: nil,
               load1: nil,
               load15: nil,
               cores: nil,
               req_per_s: nil,
               p95_ms: nil,
               backup: %{ok: nil, detail: nil},
               checks: %{pass: 0, skipped: 0, total: 0, failing: []},
               dirty_tree: nil,
               reported_at: nil
             }
    end

    test "nil payload → same all-absent envelope" do
      assert Telemetry.normalize(nil) == Telemetry.normalize(%{})
    end

    test "a non-map garbage payload (list / string / number) → all-absent envelope, never raises" do
      for garbage <- [[], ["x"], "not a map", 42, :atom, {:a, :b}] do
        assert Telemetry.normalize(garbage) == Telemetry.normalize(%{})
      end
    end

    test "wrong-typed fields are coerced to nil, not passed through or crashed" do
      payload = %{
        "disk_used_percent" => "high",
        "pg_size_bytes" => nil,
        "cpu_percent" => "hot",
        "mem_used_percent" => nil,
        "load1" => "busy",
        "load15" => "busy",
        "cpu_cores" => "two",
        "req_per_s" => [],
        "p95_ms" => "slow",
        "backup_ok" => "yes",
        "backup_detail" => 500,
        "dirty_tree" => 1,
        "health_checks" => "not a list",
        "pg_top_relations" => "not a list",
        "swap_used_percent" => "lots",
        "swap_total_bytes" => nil,
        "beam_pss_bytes" => %{},
        "beam_swap_bytes" => "big"
      }

      assert Telemetry.normalize(payload) == %{
               disk: %{used_pct: nil},
               db_size: nil,
               top_relations: nil,
               swap: %{used_pct: nil, total_bytes: nil},
               beam: %{pss_bytes: nil, swap_bytes: nil},
               cpu: nil,
               mem: nil,
               load1: nil,
               load15: nil,
               cores: nil,
               req_per_s: nil,
               p95_ms: nil,
               backup: %{ok: nil, detail: nil},
               checks: %{pass: 0, skipped: 0, total: 0, failing: []},
               dirty_tree: nil,
               reported_at: nil
             }
    end
  end

  describe "normalize/1 — health_checks roll-up" do
    test "some failing → correct pass/total/failing names in order" do
      payload = %{
        "health_checks" => [
          %{"name" => "websocket", "pass" => true},
          %{"name" => "tls", "pass" => false},
          %{"name" => "studio", "pass" => true},
          %{"name" => "postgres", "pass" => false}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 2,
               skipped: 0,
               total: 4,
               failing: ["tls", "postgres"]
             }
    end

    test "an empty checks list rolls up to zero, empty failing" do
      assert Telemetry.normalize(%{"health_checks" => []}).checks == %{
               pass: 0,
               skipped: 0,
               total: 0,
               failing: []
             }
    end

    test "a check with no boolean fails closed and rides in total + failing" do
      payload = %{
        "health_checks" => [
          %{"name" => "websocket", "pass" => true},
          %{"name" => "mystery"},
          %{"pass" => false}
        ]
      }

      env = Telemetry.normalize(payload).checks
      assert env.pass == 1
      assert env.total == 3
      # nameless failing check contributes a nil name, keeping total consistent.
      assert env.failing == ["mystery", nil]
    end

    test "an explicit \"pass\" => false is authoritative — the \"ok\" alias cannot overrule it" do
      payload = %{
        "health_checks" => [
          # Conflicting keys: the authoritative "pass" wins in both directions.
          %{"name" => "conflict-fail", "pass" => false, "ok" => true},
          %{"name" => "conflict-pass", "pass" => true, "ok" => false},
          # A non-boolean "pass" is treated as absent → the alias decides.
          %{"name" => "alias-rescue", "pass" => "yes", "ok" => true}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 2,
               skipped: 0,
               total: 3,
               failing: ["conflict-fail"]
             }
    end

    test "\"ok\" is accepted as a defensive alias for the \"pass\" boolean" do
      payload = %{
        "health_checks" => [
          %{"name" => "a", "ok" => true},
          %{"name" => "b", "ok" => false}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 1,
               skipped: 0,
               total: 2,
               failing: ["b"]
             }
    end

    test "a \"skip\" status is counted apart from pass AND from failing" do
      # The point of the third bucket. Counted as passing, this roll-up would
      # claim the gate verified an agent connection and a backup schedule that
      # nothing probed; counted as failing, a correctly-configured box would
      # read as broken — which is how every online instance once reported down.
      payload = %{
        "health_checks" => [
          %{"name" => "capabilities", "pass" => true, "status" => "pass"},
          %{"name" => "tls", "pass" => true, "status" => "pass"},
          %{"name" => "agent-connected-stub", "pass" => true, "status" => "skip"},
          %{"name" => "backup-scheduled-stub", "pass" => true, "status" => "skip"}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 2,
               skipped: 2,
               total: 4,
               failing: []
             }
    end

    test "a skip never rescues a genuine failure" do
      # The negative arm at the control-plane layer: skips must not be able to
      # empty the failing list. If they could, no box could ever read broken.
      payload = %{
        "health_checks" => [
          %{"name" => "capabilities", "pass" => true, "status" => "pass"},
          %{"name" => "websocket", "pass" => false, "status" => "fail"},
          %{"name" => "agent-connected-stub", "pass" => true, "status" => "skip"}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 1,
               skipped: 1,
               total: 3,
               failing: ["websocket"]
             }
    end

    test "an explicit status overrules the legacy pass bool it ships beside" do
      # A skip carries `pass: true` on the wire ONLY so agents and control
      # planes can be deployed in either order. Once a reader understands
      # `status`, the bool must stop deciding.
      payload = %{
        "health_checks" => [
          %{"name" => "skipped-but-pass-true", "pass" => true, "status" => "skip"},
          %{"name" => "failed-but-pass-true", "pass" => true, "status" => "fail"}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 0,
               skipped: 1,
               total: 2,
               failing: ["failed-but-pass-true"]
             }
    end

    test "an unrecognised status degrades to the pass bool, never to a skip" do
      # Version skew in the other direction: a status string this control plane
      # does not know must not silently excuse a check from the count. Letting
      # an unknown word mean "abstain" would make every future gate value a
      # blind spot.
      payload = %{
        "health_checks" => [
          %{"name" => "future-a", "pass" => true, "status" => "degraded"},
          %{"name" => "future-b", "pass" => false, "status" => "degraded"}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 1,
               skipped: 0,
               total: 2,
               failing: ["future-b"]
             }
    end

    test "an old agent with no status field keeps its exact previous roll-up" do
      # The deploy-order guarantee: this control plane ships before every box
      # has the new agent, so a status-less payload must be byte-for-byte the
      # roll-up it produced yesterday, with the new bucket simply empty.
      payload = %{
        "health_checks" => [
          %{"name" => "capabilities", "pass" => true},
          %{"name" => "agent-connected-stub", "pass" => true},
          %{"name" => "websocket", "pass" => false}
        ]
      }

      assert Telemetry.normalize(payload).checks == %{
               pass: 2,
               skipped: 0,
               total: 3,
               failing: ["websocket"]
             }
    end

    test "the three buckets always partition total" do
      payload = %{
        "health_checks" => [
          %{"name" => "a", "pass" => true, "status" => "pass"},
          %{"name" => "b", "pass" => false, "status" => "fail"},
          %{"name" => "c", "pass" => true, "status" => "skip"},
          %{"name" => "d", "pass" => true},
          %{"name" => "e"}
        ]
      }

      c = Telemetry.normalize(payload).checks
      assert c.pass + c.skipped + length(c.failing) == c.total
      assert c.total == 5
    end
  end

  describe "normalize/1 — swap / BEAM / top relations (the new vitals)" do
    test "the -1 sentinel pair passes through VERBATIM — the normalizer never words it" do
      payload =
        Map.merge(full_payload(), %{
          "swap_used_percent" => -1,
          "swap_total_bytes" => -1,
          "beam_pss_bytes" => -1,
          "beam_swap_bytes" => -1
        })

      env = Telemetry.normalize(payload)

      # NOT nil, NOT "unmeasured" — the raw sentinel. Deciding what -1 MEANS is a
      # view concern (Metrics.latest/1 nils it; the CLI words it), never here.
      assert env.swap == %{used_pct: -1, total_bytes: -1}
      assert env.beam == %{pss_bytes: -1, swap_bytes: -1}
    end

    test "a swapless box's honest 0 pair survives — it is data, not a sentinel" do
      payload = Map.merge(full_payload(), %{"swap_used_percent" => 0, "swap_total_bytes" => 0})
      assert Telemetry.normalize(payload).swap == %{used_pct: 0, total_bytes: 0}
    end

    test "an absent pg_top_relations is nil, an EMPTY list stays [] — different facts" do
      # nil: the probe never ran (a pre-upgrade agent, or a failed read).
      assert Telemetry.normalize(Map.delete(full_payload(), "pg_top_relations")).top_relations ==
               nil

      # A JSON null lands the same way.
      assert Telemetry.normalize(Map.put(full_payload(), "pg_top_relations", nil)).top_relations ==
               nil

      # []: it DID run and found nothing to report. Never collapsed into nil.
      assert Telemetry.normalize(Map.put(full_payload(), "pg_top_relations", [])).top_relations ==
               []
    end

    test "malformed relation rows are dropped; the agent's biggest-first order is kept" do
      rows = [
        %{"name" => "mutation_events", "bytes" => 3},
        %{"name" => "nameless"},
        %{"bytes" => 9},
        "junk",
        %{"name" => 42, "bytes" => 1},
        %{"name" => "revisions", "bytes" => 2}
      ]

      assert Telemetry.normalize(%{"pg_top_relations" => rows}).top_relations == [
               %{name: "mutation_events", bytes: 3},
               %{name: "revisions", bytes: 2}
             ]
    end
  end

  describe "normalize/1 — a REAL stored beat (the producer envelope, not a hand-built map)" do
    test "the real beat's new vitals fold through verbatim" do
      env = Telemetry.normalize(RealAgentBeats.guerrilla())

      assert env.swap == %{used_pct: 55, total_bytes: 2_147_479_552}
      assert env.beam == %{pss_bytes: 1_258_798_080, swap_bytes: 329_543_680}
      assert env.db_size == 3_525_639_191

      # The named breakdown is what turns "3.5 GB" into a diagnosis: the two
      # biggest relations alone are most of the database.
      assert [%{name: "mutation_events", bytes: 1_534_328_832} | _] = env.top_relations
      assert length(env.top_relations) == 5

      named = env.top_relations |> Enum.map(& &1.bytes) |> Enum.sum()
      assert named / env.db_size > 0.9
    end

    test "the real PRE-upgrade beat degrades honestly — nil, never a fabricated zero" do
      env = Telemetry.normalize(RealAgentBeats.pre_upgrade())

      assert env.swap == %{used_pct: nil, total_bytes: nil}
      assert env.beam == %{pss_bytes: nil, swap_bytes: nil}
      assert env.top_relations == nil
      # The signals that box DOES report still land.
      assert env.disk == %{used_pct: 95}
      assert env.cpu == 12
      # …and its sentinels ride verbatim, as ever.
      assert env.db_size == -1
    end
  end

  describe "normalize/1 — %AgentEvent{} stamps reported_at from inserted_at" do
    test "a full event carries an RFC3339 reported_at from its inserted_at" do
      ts = ~U[2026-07-03 12:00:00.000000Z]
      event = %AgentEvent{type: "health", payload: full_payload(), inserted_at: ts}
      env = Telemetry.normalize(event)

      assert env.reported_at == "2026-07-03T12:00:00.000000Z"
      # payload still normalizes exactly as the bare-map path.
      assert env.disk == %{used_pct: 42}
      assert env.checks == %{pass: 3, skipped: 0, total: 3, failing: []}
    end

    test "an event with a nil payload normalizes to all-absent, still stamping reported_at" do
      ts = ~U[2026-07-03 12:00:00.000000Z]
      event = %AgentEvent{type: "health", payload: nil, inserted_at: ts}
      env = Telemetry.normalize(event)

      assert env.db_size == nil
      assert env.checks == %{pass: 0, skipped: 0, total: 0, failing: []}
      assert env.reported_at == "2026-07-03T12:00:00.000000Z"
    end

    test "an event with a nil inserted_at leaves reported_at nil, never raises" do
      event = %AgentEvent{type: "health", payload: full_payload(), inserted_at: nil}
      assert Telemetry.normalize(event).reported_at == nil
    end
  end
end
