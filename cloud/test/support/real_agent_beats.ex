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

  And one that is NOT a capture, labelled as such at its own docstring:
  `guerrilla_under_pressure/0` reconstructs the recorded 93%-swap state from
  `task-aa775c3d30287a4b`. It is the pressure verdict's calibration case; it is
  not evidence of what the wire carried.

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

  @doc """
  Guerrilla in the state that MOTIVATED the pressure verdict — and, unlike its
  two siblings here, this one is RECONSTRUCTED, not captured. Read the
  provenance before asserting anything against it.

  The numbers are the ones measured on guerrilla (157.180.90.121, 2 vCPU /
  3.8 GB) on 2026-08-06..08 and recorded verbatim in `task-aa775c3d30287a4b`:

      swap 1904/2047 MB (93%) · free mem 293 MB of 3819 · four concurrent
      builds on two cores, load15 1.89-2.02 per core · disk 75%

  In that state the box answered 6,472 HTTP 500s in eight hours while
  `bp cloud status` called it `ok / rank 8 / healthy`. It is the calibration
  case: whatever else a verdict does, it must not call THIS calm.

  What is real and what is assembled, stated separately:

    * REAL — every number above, measured on the box and recorded in the row.
    * ASSEMBLED — the mapping onto the producer's key names. No beat carrying
      exactly these values was captured off the wire, so this is not a
      `guerrilla/0`-grade artefact and must not be read as one.
    * DERIVED, and the weakest of the three — `mem_used_percent` 92 comes from
      "free 293 MB of 3819" (7.7% free), NOT from an agent reading. The real
      agent computes memory from MemAvailable, which CLEARS precisely because
      the BEAM has been paged out: the verbatim `guerrilla/0` capture reports a
      comfortable 64% while 55% of swap is consumed. So the live agent would
      very likely report memory LOWER than 92 here, and a verdict that leaned on
      this number would be leaning on the softest one available. It does not
      have to: swap and load carry this case on their own, which is the point.

  `load15`/`cpu_cores` are present here and absent from `guerrilla/0` for a
  dull reason worth writing down: that capture is from 2026-08-06 and the beat
  did not carry either key until #9888 merged on 2026-08-07.
  """
  @spec guerrilla_under_pressure() :: map()
  def guerrilla_under_pressure do
    %{
      "agent_status" => "online",
      "cpu_cores" => 2,
      "cpu_percent" => 100,
      "disk_used_percent" => 75,
      "health_checks" => [],
      "health_status" => "up",
      "load1" => 4.11,
      # 2.02 per core x 2 cores — the top of the measured 1.89-2.02 range.
      "load15" => 4.04,
      "mem_used_percent" => 92,
      "swap_total_bytes" => 2_147_479_552,
      "swap_used_percent" => 93,
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
