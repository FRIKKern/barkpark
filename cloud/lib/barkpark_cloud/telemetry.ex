defmodule BarkparkCloud.Telemetry do
  @moduledoc """
  Re-serve the health telemetry the agent ALREADY reports — zero agent change
  (charter decision 16). The on-box agent POSTs a rich health report to
  `/v1/agent/report`; the router lands it append-only as a `"health"`
  `AgentEvent` (`Registry.record_event(barkpark, "health", report)`). This
  module turns that raw, agent-shaped jsonb payload into ONE stable, defensive
  envelope the dashboard's Timeline/Overview panels render, so no consumer has
  to know the agent's field names or cope with a partial box.

  `normalize/1` is PURE and TOTAL: it never raises, whatever it is handed. A
  missing signal becomes `nil` (or an empty roll-up for the checks summary),
  never a crash and never an invented value — the same "phone home with
  whatever it can prove" honesty the agent's own `gatherReport` keeps on the
  other side of the wire. The envelope shape is fixed even for an all-absent
  payload, so a consumer can always destructure it:

      %{
        disk: %{used_pct: number | nil},   # verbatim from the agent (int in practice)
        db_size: number | nil,
        # The biggest named consumers INSIDE db_size (agent `pg_top_relations`).
        # nil — never [] — when the probe was not wired or failed: "we did not
        # measure" is a different fact from "the database has no relations".
        top_relations: [%{name: String.t(), bytes: number}] | nil,
        # Swap travels as a PAIR because a bare percent cannot carry three states:
        # (0, 0) is a swapless box (measured — the answer is "none configured"),
        # (0, >0) is configured-but-idle, (-1, -1) is "could not measure". Both
        # sentinels pass through VERBATIM; disambiguating them is a view concern.
        swap: %{used_pct: number | nil, total_bytes: number | nil},
        # The BEAM's OWN footprint (Pss + Swap from smaps_rollup) — the single
        # largest consumer on a box and the process the kernel OOM-kills. This is
        # the vital `mem_used_percent` HIDES: MemAvailable clears the floor
        # precisely BECAUSE the BEAM was paged out.
        beam: %{pss_bytes: number | nil, swap_bytes: number | nil},
        cpu: number | nil,        # host CPU busy % (agent `cpu_percent`, -1 verbatim)
        mem: number | nil,        # used-memory % (agent `mem_used_percent`, -1 verbatim)
        load1: number | nil,      # 1-minute load average (agent `load1`, -1 verbatim)
        req_per_s: number | nil,  # request rate (instance-exposed; nil until it ships)
        p95_ms: number | nil,     # p95 request latency ms (instance-exposed; nil until it ships)
        backup: %{ok: boolean | nil, detail: String.t() | nil},
        checks: %{
          pass: non_neg_integer,
          skipped: non_neg_integer,
          total: non_neg_integer,
          failing: [String.t()]
        },
        dirty_tree: boolean | nil,
        reported_at: String.t() | nil   # event inserted_at, RFC3339
      }

  The agent-side field contract (verified in `internal/agent/report.go` +
  `internal/cli/setup/healthgate.go`): `disk_used_percent` (int, `-1` when the
  probe was not wired — passed through verbatim; sentinel interpretation is a
  view concern, not the normalizer's), `pg_size_bytes` (int64),
  `pg_top_relations` (a list of `%{"name","bytes"}` `RelationSize`s, or JSON
  null when unmeasured), `swap_used_percent` (int) + `swap_total_bytes` (int64),
  `beam_pss_bytes` + `beam_swap_bytes` (int64), `backup_ok` (bool) +
  `backup_detail` (string), `dirty_tree` (bool), and `health_checks` (a list of
  `%{"name","pass","detail"}` `CheckResult`s — note the boolean key is `"pass"`,
  with `"ok"` accepted as a defensive alias).

  An OLDER agent build simply does not send the newer keys (a real guerrilla
  beat carries all 20; a pre-upgrade box carries 15) — every absent one becomes
  `nil`, so a mixed-version fleet normalizes without a special case.

  Payloads arrive from jsonb with STRING keys (Jason-decoded), which is what
  this module reads. `reported_at` is not in the payload — it is the event's
  own `inserted_at`, so pass a full `%AgentEvent{}` to stamp it; a bare payload
  map normalizes with `reported_at: nil`.
  """

  alias BarkparkCloud.Registry.AgentEvent

  @empty_checks %{pass: 0, skipped: 0, total: 0, failing: []}

  @doc """
  Normalize one captured health report into the stable telemetry envelope.

  Accepts a full `%AgentEvent{}` (stamps `reported_at` from its `inserted_at`),
  a bare payload map (`reported_at: nil`), or anything else at all (an all-nil
  envelope — total, never raises).
  """
  @spec normalize(AgentEvent.t() | map() | nil | any()) :: map()
  def normalize(%AgentEvent{payload: payload, inserted_at: inserted_at}) do
    payload
    |> normalize()
    |> Map.put(:reported_at, to_rfc3339(inserted_at))
  end

  def normalize(payload) when is_map(payload) do
    %{
      disk: %{used_pct: num_or_nil(Map.get(payload, "disk_used_percent"))},
      db_size: num_or_nil(Map.get(payload, "pg_size_bytes")),
      # The named breakdown inside db_size — what turns "3.5 GB" into a
      # diagnosis. A non-list (absent / JSON null / malformed) stays nil so
      # "unmeasured" never collapses into "measured, and it's empty".
      top_relations: relation_sizes(Map.get(payload, "pg_top_relations")),
      # Swap + the BEAM's own footprint, each verbatim (the -1 sentinel included
      # — a swapless box's honest `0` and an unwired probe's `-1` are opposite
      # facts, and only the view is allowed to word them).
      swap: %{
        used_pct: num_or_nil(Map.get(payload, "swap_used_percent")),
        total_bytes: num_or_nil(Map.get(payload, "swap_total_bytes"))
      },
      beam: %{
        pss_bytes: num_or_nil(Map.get(payload, "beam_pss_bytes")),
        swap_bytes: num_or_nil(Map.get(payload, "beam_swap_bytes"))
      },
      # Machine vitals — the host's live resource pressure the agent beats every
      # cycle (report.go: `cpu_percent` / `mem_used_percent` / `load1`, each `-1`
      # when its probe was unwired) plus the request-load signals the instance
      # exposes later (`req_per_s` / `p95_ms`; absent → nil until that runtime
      # ships). num_or_nil like disk: a missing / non-numeric signal is nil, and
      # the `-1` sentinel passes through verbatim — reinterpreting it (a negative
      # is "not measured", never a fake 0) is the meter builder's view concern,
      # not the normalizer's.
      cpu: num_or_nil(Map.get(payload, "cpu_percent")),
      mem: num_or_nil(Map.get(payload, "mem_used_percent")),
      load1: num_or_nil(Map.get(payload, "load1")),
      # `load15` and `cores` travel together and exist for one reason: a bare
      # load average is UNINTERPRETABLE. 2.0 is idle on 16 cores and a queue two
      # deep on 2. Only load-per-core is comparable across a fleet of mixed
      # boxes, and it cannot be computed without the divisor — so the divisor is
      # part of the reading, not a lookup the consumer is trusted to do.
      # load15 (not load1) is the one to judge on: a 60s beat sampling load1
      # catches spikes a build storm produces and drops, and an alarm that
      # flickers is an alarm an operator learns to ignore.
      load15: num_or_nil(Map.get(payload, "load15")),
      cores: num_or_nil(Map.get(payload, "cpu_cores")),
      req_per_s: num_or_nil(Map.get(payload, "req_per_s")),
      p95_ms: num_or_nil(Map.get(payload, "p95_ms")),
      backup: %{
        ok: bool_or_nil(Map.get(payload, "backup_ok")),
        detail: str_or_nil(Map.get(payload, "backup_detail"))
      },
      checks: summarize_checks(Map.get(payload, "health_checks")),
      dirty_tree: bool_or_nil(Map.get(payload, "dirty_tree")),
      reported_at: nil
    }
  end

  # nil / any non-map (a corrupt or absent payload) → the all-absent envelope.
  def normalize(_), do: normalize(%{})

  @doc """
  Normalize one captured SPACE report — the agent's disk-consumption payload
  (`internal/agent/report.go` `SpaceReport`, posted to `/v1/agent/space` on its
  own 15-minute cadence) — into a stable envelope, the sibling of `normalize/1`
  and under exactly the same discipline: PURE, TOTAL, nil-not-zero, and the
  agent's `-1` sentinel passed through VERBATIM (a view decides how to word an
  unmeasured probe; a normalizer that "helpfully" zeroes it has destroyed the
  distinction). A non-list consumer list stays `nil` — "we did not measure" is a
  different fact from "we measured and it is empty", and under-reporting space
  is the exact failure this payload exists to prevent.

      %{
        # The root filesystem as a PAIR, never a percent: 75% cannot tell a
        # 40 GB box needing 10 GB freed from a 400 GB box needing 100 GB, and
        # the operator's next action depends on which it is. Collapsing them
        # throws away the whole reason the payload exists.
        root: %{used_bytes: number | nil, total_bytes: number | nil},
        journal_bytes: number | nil,
        db_size: number | nil,
        top_relations: [%{name: String.t(), bytes: number}] | nil,
        # The RESOLVED sites root the probe actually read (never the configured
        # one — a wrong root must be visible, D59), the tree's total, and its
        # biggest named slugs.
        sites: %{
          dir: String.t() | nil,
          bytes: number | nil,
          top: [%{name: String.t(), bytes: number}] | nil,
          # How many slugs the walk FOUND, which is the only thing that can tell
          # a reader whether `top` is the whole tree or the visible tip of one.
          # The agent caps `top` at ten (a payload bound, `sites_count` in
          # report.go); without the count, ten slugs read identically whether
          # the tree holds ten or forty. nil when unmeasured — never 0, which is
          # the measured claim "this tree is empty".
          count: number | nil
        },
        # The extra disk-consumer roots — the BUILD PLANE's trees, which the
        # sites axis structurally cannot see (a builder box has no
        # /opt/barkpark/sites at all). Each row carries its own `status`, and
        # the three values are a closed set:
        #
        #   "read"       — the walk completed; bytes/count are real
        #   "absent"     — the root is NOT ON THIS BOX. A measurement, not a
        #                  failure, and the reason this field is shaped this
        #                  way: an absent root rendered as 0 bytes claims an
        #                  empty tree about a directory that is not there.
        #   "unmeasured" — we tried and could not read it
        #
        # bytes/count keep the agent's -1 sentinel verbatim for the two
        # non-read states, like every other number here.
        consumer_roots: [
          %{
            path: String.t(),
            status: String.t(),
            bytes: number | nil,
            top: [%{name: String.t(), bytes: number}] | nil,
            count: number | nil
          }
        ] | nil,
        reported_at: String.t() | nil   # the event's inserted_at, RFC3339
      }

  Accepts a full `%AgentEvent{}` (stamps `reported_at`), a bare payload map, or
  anything at all (the all-absent envelope).
  """
  @spec normalize_space(AgentEvent.t() | map() | nil | any()) :: map()
  def normalize_space(%AgentEvent{payload: payload, inserted_at: inserted_at}) do
    payload
    |> normalize_space()
    |> Map.put(:reported_at, to_rfc3339(inserted_at))
  end

  def normalize_space(payload) when is_map(payload) do
    %{
      root: %{
        used_bytes: num_or_nil(Map.get(payload, "root_used_bytes")),
        total_bytes: num_or_nil(Map.get(payload, "root_total_bytes"))
      },
      journal_bytes: num_or_nil(Map.get(payload, "journal_bytes")),
      db_size: num_or_nil(Map.get(payload, "pg_size_bytes")),
      top_relations: relation_sizes(Map.get(payload, "pg_top_relations")),
      sites: %{
        dir: str_or_nil(Map.get(payload, "sites_dir")),
        bytes: num_or_nil(Map.get(payload, "sites_bytes")),
        # `SiteSize` names its key `slug` where `RelationSize` names it `name`;
        # both are "a named consumer and its bytes", so one row shaper serves
        # both and every surface renders one shape.
        top: relation_sizes(Map.get(payload, "sites_top")),
        # Verbatim like every other number here, `-1` sentinel included: an
        # agent too old to send `sites_count` is absent (nil), a failed walk is
        # -1, and only a view is allowed to word either.
        count: num_or_nil(Map.get(payload, "sites_count"))
      },
      consumer_roots: consumer_roots(Map.get(payload, "consumer_roots")),
      reported_at: nil
    }
  end

  def normalize_space(_), do: normalize_space(%{})

  # The consumer-root list. A non-list (an agent predating the axis, a null, a
  # corrupt payload) is nil — NOT MEASURED — while an agent that was told to
  # measure no roots sends `[]` and keeps it, because "this box was configured
  # to look nowhere" and "this box has not been upgraded" are different facts an
  # operator resolves differently.
  defp consumer_roots(rows) when is_list(rows), do: Enum.flat_map(rows, &consumer_root/1)
  defp consumer_roots(_), do: nil

  # One root. The PATH is required: a row that cannot say which root it is
  # cannot be rendered and cannot be acted on, so it is dropped rather than
  # emitted as an anonymous number.
  #
  # `status` is normalized against the closed set and anything unrecognised
  # becomes "unmeasured" — the only safe direction. Passing an unknown word
  # through would let a future agent word invent a state every surface renders
  # by falling off the end of its branch table, and coercing toward "read" or
  # "absent" would assert a measurement nobody made.
  defp consumer_root(row) when is_map(row) do
    case str_or_nil(Map.get(row, "path")) do
      nil ->
        []

      path ->
        [
          %{
            path: path,
            status: consumer_root_status(str_or_nil(Map.get(row, "status"))),
            # Verbatim, -1 sentinel included. The view words it; the normalizer
            # never "helpfully" zeroes an unmeasured tree.
            bytes: num_or_nil(Map.get(row, "bytes")),
            top: relation_sizes(Map.get(row, "top")),
            count: num_or_nil(Map.get(row, "count"))
          }
        ]
    end
  end

  defp consumer_root(_), do: []

  defp consumer_root_status(status) when status in ["read", "absent", "unmeasured"], do: status
  defp consumer_root_status(_), do: "unmeasured"

  # Roll the health-gate array up to {pass, skipped, total, failing}. A non-list
  # (absent / malformed) yields the zero roll-up — never nil arithmetic
  # downstream.
  #
  # `skipped` counts the checks that DID NOT RUN, and it is its own bucket
  # because the alternatives are both lies: counted as passing, the roll-up
  # claims the gate verified a condition nothing probed; counted as failing, a
  # correctly-configured box reads as broken. The gate emits these as
  # `status: "skip"` (see internal/cli/setup/healthgate.go).
  #
  # The invariant is `pass + skipped + length(failing) == total`. It USED to be
  # `pass + length(failing) == total`; a reader deriving a failure count as
  # `total - pass` was already wrong for optional stubs and is now visibly so.
  defp summarize_checks(checks) when is_list(checks) do
    {pass, skipped, failing} =
      Enum.reduce(checks, {0, 0, []}, fn check, {pass, skipped, failing} ->
        case check_status(check) do
          :pass -> {pass + 1, skipped, failing}
          :skip -> {pass, skipped + 1, failing}
          :fail -> {pass, skipped, [check_name(check) | failing]}
        end
      end)

    %{
      pass: pass,
      skipped: skipped,
      total: length(checks),
      failing: Enum.reverse(failing)
    }
  end

  defp summarize_checks(_), do: @empty_checks

  # The agent's `pg_top_relations` rows, kept in the agent's own order (biggest
  # first) and reduced to the two fields the surfaces render. Only a row with a
  # real name AND a real byte count survives — a malformed row is dropped rather
  # than rendered as a nameless or sizeless consumer. A non-list input (absent,
  # JSON null, garbage) is nil: NOT measured, which is not the same as measured
  # and empty (an honestly empty list stays []).
  defp relation_sizes(rows) when is_list(rows) do
    Enum.flat_map(rows, &relation_size/1)
  end

  defp relation_sizes(_), do: nil

  # `RelationSize` names the consumer `name`; the space payload's `SiteSize`
  # names it `slug`. Same fact ("who is consuming this, and how much"), so the
  # row shaper accepts either and always emits `name` — one rendered shape, not
  # two near-identical ones a surface has to branch on.
  defp relation_size(row) when is_map(row) do
    case {str_or_nil(Map.get(row, "name")) || str_or_nil(Map.get(row, "slug")),
          num_or_nil(Map.get(row, "bytes"))} do
      {name, bytes} when is_binary(name) and is_number(bytes) -> [%{name: name, bytes: bytes}]
      _ -> []
    end
  end

  defp relation_size(_), do: []

  # A check counts as passing ONLY when its boolean is literally true. The
  # struct's JSON key is "pass" and it is AUTHORITATIVE when present as a
  # boolean; "ok" is a defensive alias consulted only when "pass" is absent or
  # non-boolean — an alias must never overrule an explicit `"pass" => false`.
  # Any non-boolean / missing value → not passing (fail closed).
  # The three-valued read of one check. An explicit `status` wins when the agent
  # sends one; anything else falls back to the historical two-state `pass`/`ok`
  # bool, so a box running an agent built before `status` existed keeps its
  # previous roll-up exactly. An UNRECOGNISED status string is NOT treated as a
  # skip — a value this control plane cannot interpret must not silently excuse
  # a check from the count — it degrades to the bool fallback.
  defp check_status(check) when is_map(check) do
    case Map.get(check, "status") do
      "pass" -> :pass
      "fail" -> :fail
      "skip" -> :skip
      _ -> if check_passed?(check), do: :pass, else: :fail
    end
  end

  defp check_status(_), do: :fail

  defp check_passed?(check) when is_map(check) do
    case bool_or_nil(Map.get(check, "pass")) do
      nil -> bool_or_nil(Map.get(check, "ok")) == true
      pass -> pass
    end
  end

  defp check_passed?(_), do: false

  # The failing check's name for the `failing` list. Missing/non-string → nil
  # (kept in the list so `total` and `length(failing)` stay consistent).
  defp check_name(check) when is_map(check), do: str_or_nil(Map.get(check, "name"))
  defp check_name(_), do: nil

  defp num_or_nil(n) when is_number(n), do: n
  defp num_or_nil(_), do: nil

  defp bool_or_nil(b) when is_boolean(b), do: b
  defp bool_or_nil(_), do: nil

  defp str_or_nil(s) when is_binary(s), do: s
  defp str_or_nil(_), do: nil

  defp to_rfc3339(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_rfc3339(_), do: nil
end
