defmodule BarkparkCloud.TelemetryTest do
  @moduledoc """
  `Telemetry.normalize/1` is a PURE, TOTAL normalizer over the agent's captured
  health payload (charter decision 16 — observability from data already
  captured). These tests exercise it directly, no DB, no HTTP:

    * a FULL payload maps every field to the stable envelope
    * a PARTIAL payload (missing disk) fills the gap with `nil`, keeps the rest
    * an ABSENT / empty / garbage payload yields the all-absent envelope and
      NEVER raises (the totality guarantee)
    * `health_checks` rolls up to correct {pass, total, failing}, including the
      some-failing case
    * a full `%AgentEvent{}` stamps `reported_at` from its `inserted_at`
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Telemetry
  alias BarkparkCloud.Registry.AgentEvent

  # Mirrors the real jsonb shape: STRING keys, agent field names, the CheckResult
  # boolean under "pass" (see internal/cli/setup/healthgate.go).
  defp full_payload do
    %{
      "disk_used_percent" => 42,
      "pg_size_bytes" => 123_456_789,
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
               backup: %{ok: true, detail: "daily backup 2h ago"},
               checks: %{pass: 3, total: 3, failing: []},
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
      assert env.checks == %{pass: 3, total: 3, failing: []}
      assert env.dirty_tree == false
    end

    test "an unwired disk probe's -1 sentinel passes through verbatim (not the normalizer's job to reinterpret)" do
      payload = Map.put(full_payload(), "disk_used_percent", -1)
      assert Telemetry.normalize(payload).disk == %{used_pct: -1}
    end
  end

  describe "normalize/1 — absent / empty / garbage payloads never crash" do
    test "empty map → all-absent envelope, fixed shape" do
      assert Telemetry.normalize(%{}) == %{
               disk: %{used_pct: nil},
               db_size: nil,
               backup: %{ok: nil, detail: nil},
               checks: %{pass: 0, total: 0, failing: []},
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
        "backup_ok" => "yes",
        "backup_detail" => 500,
        "dirty_tree" => 1,
        "health_checks" => "not a list"
      }

      assert Telemetry.normalize(payload) == %{
               disk: %{used_pct: nil},
               db_size: nil,
               backup: %{ok: nil, detail: nil},
               checks: %{pass: 0, total: 0, failing: []},
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
               total: 4,
               failing: ["tls", "postgres"]
             }
    end

    test "an empty checks list rolls up to zero, empty failing" do
      assert Telemetry.normalize(%{"health_checks" => []}).checks == %{
               pass: 0,
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
               total: 2,
               failing: ["b"]
             }
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
      assert env.checks == %{pass: 3, total: 3, failing: []}
    end

    test "an event with a nil payload normalizes to all-absent, still stamping reported_at" do
      ts = ~U[2026-07-03 12:00:00.000000Z]
      event = %AgentEvent{type: "health", payload: nil, inserted_at: ts}
      env = Telemetry.normalize(event)

      assert env.db_size == nil
      assert env.checks == %{pass: 0, total: 0, failing: []}
      assert env.reported_at == "2026-07-03T12:00:00.000000Z"
    end

    test "an event with a nil inserted_at leaves reported_at nil, never raises" do
      event = %AgentEvent{type: "health", payload: full_payload(), inserted_at: nil}
      assert Telemetry.normalize(event).reported_at == nil
    end
  end
end
