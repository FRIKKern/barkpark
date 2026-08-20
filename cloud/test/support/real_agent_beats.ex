defmodule BarkparkCloud.RealAgentBeats do
  @moduledoc """
  REAL stored agent beats, captured VERBATIM from the control plane — the
  producer envelope, not a hand-built map.

  Both were read on 2026-08-06 from `GET /v1/barkparks/:id/events`, which
  serializes `payload: e.payload` UNFILTERED, so these are exactly the jsonb
  bytes the router landed via `Registry.record_event(barkpark, "health", …)`.
  Ingest applies no whitelist, which is why a fold over new fields is
  retroactive over the whole retained window.

  Two shapes, because the fleet is MIXED and that is the normal case:

    * `guerrilla/0` — the current agent build: 20 keys, including the swap pair,
      the BEAM's own footprint, and the named `pg_top_relations` breakdown.
      Real numbers: a 3.52 GB database whose two biggest relations
      (mutation_events 1.53 GB + revisions 1.33 GB) are 81.3% of it, 55% of a
      2 GB swap consumed, and 1.26 GB of BEAM resident with 330 MB paged out.
    * `pre_upgrade/0` — the OTHER five boxes, still on the pre-swap build: 15
      keys, none of the four new ones, and `pg_size_bytes` at the `-1`
      "not wired" sentinel.

  A test that asserts against these is asserting against what the producer
  actually sends. `health_checks` is trimmed to two of guerrilla's seven entries
  (the roll-up arithmetic is proven directly elsewhere); every other key is
  untouched.
  """

  @doc "The current agent build's beat (guerrilla, b2b81e69-…-84507d15b925)."
  @spec guerrilla() :: map()
  def guerrilla do
    %{
      "agent_status" => "online",
      "backup_detail" => "no backup probe wired",
      "backup_ok" => false,
      "beam_pss_bytes" => 1_258_798_080,
      "beam_swap_bytes" => 329_543_680,
      "cpu_percent" => 100,
      "dirty_tree" => true,
      "disk_used_percent" => 76,
      "git_commit" => "070c7584b820745e1ac8377ca6926edef6d2f257",
      "health_checks" => [
        %{
          "detail" => "GET /v1/capabilities returned 200 (API up)",
          "name" => "capabilities",
          "pass" => true
        },
        %{
          "detail" => "TLS cert for guerrilla.barkpark.cloud verified",
          "name" => "tls",
          "pass" => true
        }
      ],
      "health_status" => "up",
      "load1" => 5.27,
      "mem_used_percent" => 64,
      "p95_ms" => 15_292,
      "pg_size_bytes" => 3_525_639_191,
      "pg_top_relations" => [
        %{"bytes" => 1_534_328_832, "name" => "mutation_events"},
        %{"bytes" => 1_332_666_368, "name" => "revisions"},
        %{"bytes" => 268_132_352, "name" => "documents"},
        %{"bytes" => 111_181_824, "name" => "audit_events"},
        %{"bytes" => 68_460_544, "name" => "oban_jobs"}
      ],
      "req_per_s" => 2.98,
      "swap_total_bytes" => 2_147_479_552,
      "swap_used_percent" => 55,
      "version" => "0.1.0"
    }
  end

  @doc "A pre-upgrade box's beat (jarl, 9fb839d6-…) — none of the new keys."
  @spec pre_upgrade() :: map()
  def pre_upgrade do
    %{
      "agent_status" => "online",
      "backup_detail" => "no backup probe wired",
      "backup_ok" => false,
      "cpu_percent" => 12,
      "dirty_tree" => false,
      "disk_used_percent" => 95,
      "git_commit" => "070c7584b820745e1ac8377ca6926edef6d2f257",
      "health_checks" => [],
      "health_status" => "up",
      "load1" => 0.04,
      "mem_used_percent" => 68,
      "p95_ms" => -1,
      "pg_size_bytes" => -1,
      "req_per_s" => -1,
      "version" => "0.1.0"
    }
  end
end
