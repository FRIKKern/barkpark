defmodule BarkparkCloud.Usage do
  @moduledoc """
  Compose the console's usage envelope — every meter the Usage tab renders — as
  ONE stable, honest shape (epic charter decision D48: "meters without truth are
  lies"). `compose/1` is PURE and TOTAL: it never touches the network or the DB,
  never raises whatever it is handed, and always emits the FULL, fixed meter
  vocabulary so a consumer can always destructure it. The IO that FEEDS it —
  telemetry lookup, team-member count, the server-side instance-inventory
  fan-out with the vault-stored admin token, the fleet-quota read — lives in this
  same module (`gather/1` and friends, below), resolving the (possibly partial /
  failed) inputs before handing them to the pure shaper.

  ## The meter vocabulary is FIXED and always fully present

      documents      datasets      webhooks       — instance-sourced inventory counts
      db_size        disk                          — telemetry-sourced (the agent's health beat)
      cpu            ram                           — telemetry machine meters (0-100 %, 100/70/90 ceiling)
      req_per_s      p95_ms                        — telemetry load meters (rate/latency, warn+over, no bar)
      seats          instances                     — control-plane-sourced (team members / fleet count)
      api_requests   bandwidth                     — FLOW meters, not yet metered (see below)

  Every meter is the SAME shape:

      %{
        value: number | "unmetered",
        quota: non_neg_integer | nil,   # the enforced/physical ceiling when one exists, else nil
        warn_at: non_neg_integer | nil, # the amber threshold, else nil
        over_at: non_neg_integer | nil, # the red threshold (OC25), else nil — over fires here BEFORE quota
        source: String.t(),  # always names where the number does / would come from
        measured_at: String.t() | nil   # RFC3339 snapshot time, or nil for a live/current read
      }

  ## Quotas + thresholds — honest ceilings only (OC7 / OC11 / OC23 / OC25)

  A meter draws a quota BAR only when it carries a real ceiling; drawing a bar
  "to nowhere" for an unlimited meter is the dishonesty the wish forbids. Three
  ceiling/threshold families:

    * **`instances`** — a BILLING quota: the managed-instance count IS enforced
      today (the create-time 402 guard and the quota reconciler both key on
      `Billing.barkpark_limit/1`), so it carries a real `quota` when the router
      resolves one (subscription-backed, non-placeholder). `warn_at` is derived:
      `min(quota - 1, ceil(quota * 0.8))` once `quota >= 2`, else nil. No
      `over_at` — its red line IS the inclusive quota.
    * **`cpu` / `ram` / `disk`** — PHYSICAL percent meters: a fixed `quota: 100`
      (the 0-100 bar ceiling) with `warn_at: 70` / `over_at: 90`. The red state
      fires at `over_at` (90) BELOW the bar ceiling (OC25).
    * **`req_per_s` / `p95_ms`** — RATE/LATENCY meters: `warn_at` + `over_at`
      thresholds but NO `quota` (a rate has no plan wall) → they tint but draw no
      bar.

  Every OTHER meter (inventory counts, db_size, seats, flow) keeps
  `quota`/`warn_at`/`over_at` nil — no invented limits.

  The `seats` meter additionally carries `:pending_invitations` (a non-negative
  integer, or absent when unavailable) — a cheap extra detail beside the seat
  count, never a second meter.

  ## Two honesty tiers (D48)

  1. **Inventory / telemetry / seats** ship a real number the instant their
     source is live. A source that FAILS — the instance is unreachable, the call
     times out, the endpoint isn't served by that (older) box, or the value was
     never captured — degrades to `value: "unmetered"` with its `source` still
     named. Never a fake zero (which reads as "you have nothing"), never a fake
     infinity.

  2. **Flow meters (`api_requests`, `bandwidth`) are ALWAYS `"unmetered"`.** Flow
     metering does not exist yet; pretending otherwise with a
     zero would be a lie. They render as a designed "not yet metered" state, not
     a number, regardless of any input.

  ## Input contract (all keys OPTIONAL — a missing key degrades honestly)

      %{
        telemetry: <`Telemetry.normalize/1` envelope> | nil,
        seats: non_neg_integer | nil,
        pending_invitations: non_neg_integer | nil,
        documents: {:ok, non_neg_integer} | :unmetered | {:error, term} | nil,
        datasets:  {:ok, non_neg_integer} | :unmetered | {:error, term} | nil,
        webhooks:  {:ok, non_neg_integer} | :unmetered | {:error, term} | nil,
        # The fleet meter (OC11). `value` is the live managed-instance count;
        # `quota` is the enforced plan ceiling ONLY when the router resolved a
        # real one (a subscription-backed, non-placeholder limit), else nil. The
        # router owns that policy (it needs the subscription read); this module
        # just shapes what it is handed and derives `warn_at` from the quota.
        instances: %{value: non_neg_integer | nil, quota: non_neg_integer | nil} | nil
      }

  `compose/0` (or `compose(%{})`) yields the all-`"unmetered"` envelope — the
  honest shape for a still-provisioning or wholly-unreachable box, where the
  control-plane meters (seats) still return.

  ## IO gather + cached fleet samples (cloud-console wave 3)

  `compose/1` above stays PURE. The IO that FEEDS it — the instance-API fan-out
  (documents / datasets / webhooks over the vault admin token), the telemetry
  lookup, the seat count, the fleet-quota read — lives here too, in `gather/1`,
  so it has ONE home (the router's `/usage` route delegates; the sampler worker
  and the summary read reuse it). Two disciplines are enforced in this one place:

    * the WHOLE 1+2N inventory fan-out shares ONE monotonic wall-clock deadline
      (`fanout_budget_ms/0`, ~10s) so even a slow / many-dataset box returns a
      degraded envelope well inside the SPA's ~15s skeleton, never ~98s;
    * the decrypted admin token stays in the request `Authorization` header and
      NEVER appears in a return value, a log line, or the composed envelope — so
      it can never reach a response body OR a persisted `usage_samples` row.

  `gather/1` is the LIVE read (an instance fan-out). `record_sample/1` gathers +
  persists a `Usage.Sample` row; `summary/1` is the PURE-READ fleet view — the
  latest cached row per checkable instance, ZERO instance HTTP on the path — so
  the Overview fleet strip never pays the live-fan-out latency.
  """

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo, Telemetry}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Usage.Sample

  # Source labels — each NAMES where the number does (or would) come from, so a
  # degraded meter still tells the operator which pipe went quiet.
  @src_documents "instance.documents"
  @src_datasets "instance.datasets"
  # The webhook pipe is CROSS-DATASET (C11): the router enumerates the instance's
  # datasets and SUMS every dataset's webhook list, so the operator sees a true
  # whole-box total, not a `production`-only count posing as one. The label drops
  # the old `.production` suffix now that the number is honest across datasets;
  # any per-dataset fetch failure degrades the WHOLE meter to "unmetered" (a
  # partial sum would silently undercount — a lie), source still named.
  @src_webhooks "instance.webhooks"
  @src_db_size "telemetry.pg_size_bytes"
  @src_disk "telemetry.disk_used_percent"
  # Machine meters (OC23/OC26): the host's live capacity pressure, sourced from
  # the SAME agent health beat as disk. cpu/ram carry the physical 0-100 ceiling
  # (100 with warn 70 / over 90); req_per_s / p95_ms are RATE/LATENCY signals with
  # no plan wall to draw a bar to (quota nil), just an amber warn + a red over.
  @src_cpu "telemetry.cpu_percent"
  @src_ram "telemetry.mem_used_percent"
  @src_req_per_s "telemetry.req_per_s"
  @src_p95_ms "telemetry.p95_ms"
  @src_seats "control-plane.team_members"
  # The fleet meter is a pure control-plane read (the team's managed-instance
  # count) — it returns even when every instance is down.
  @src_instances "control-plane.team_instances"
  # The flow meters have no source yet — the label is the honest "not built".
  @src_not_metered "not-metered"

  @unmetered "unmetered"

  # The typed reasons a meter read can FAIL — the vocabulary `within_deadline/2`
  # and the fan-outs already mint, carried through to the surfaces instead of
  # being flattened into the deliberate "not metered" state. Anything outside
  # this set normalises to "unknown" (never a raw internal atom on the wire).
  # `unreachable` means the box NEVER ANSWERED (a client-level failure: refused
  # connection, DNS, TLS handshake, socket close). A box that DID answer and said
  # no is a different fact and gets its own word — `unauthorized` (it rejected
  # our admin credential), `instance_error` (it failed on its own side) or
  # `refused` (any other delivered non-2xx). Telling a paying customer "we could
  # not reach your box" about a credential rejection sends them to their network.
  @unavailable_reasons ~w(exception deadline_exceeded unreachable unauthorized refused
                          instance_error bad_shape too_many_datasets)

  # The trailing window `history/2` reads — matches the sampler's 14-day
  # `usage_samples` retention (AgentRetentionWorker prune), so the sparkline is
  # never asking for rows that were pruned away.
  @history_window_days 14
  @history_window_ms @history_window_days * 86_400_000

  @doc """
  Compose the full usage envelope from resolved inputs. Total — never raises.
  """
  @spec compose(map()) :: %{meters: map()}
  def compose(inputs \\ %{}) when is_map(inputs) do
    telemetry = telemetry_or_nil(Map.get(inputs, :telemetry))
    measured_at = telemetry_measured_at(telemetry)

    %{
      meters: %{
        documents: instance_meter(Map.get(inputs, :documents), @src_documents),
        datasets: instance_meter(Map.get(inputs, :datasets), @src_datasets),
        webhooks: instance_meter(Map.get(inputs, :webhooks), @src_webhooks),
        db_size: db_size_meter(telemetry, measured_at),
        disk: disk_meter(telemetry, measured_at),
        # Machine meters (OC23/OC26) — the host's capacity pressure off the same
        # health beat. cpu/ram are percents with the physical 100/70/90 ceiling;
        # req_per_s / p95_ms are rate/latency signals with warn+over thresholds
        # but no quota bar. An unwired probe (-1) / absent signal → "unmetered",
        # never a fake 0 (guard n >= 0). req_per_s / p95_ms stay unmetered until
        # the instance runtime reports them — honest, not a zero.
        cpu: telemetry_threshold_meter(telemetry, :cpu, @src_cpu, measured_at, 100, 70, 90),
        ram: telemetry_threshold_meter(telemetry, :mem, @src_ram, measured_at, 100, 70, 90),
        req_per_s:
          telemetry_threshold_meter(
            telemetry,
            :req_per_s,
            @src_req_per_s,
            measured_at,
            nil,
            210,
            270
          ),
        p95_ms:
          telemetry_threshold_meter(telemetry, :p95_ms, @src_p95_ms, measured_at, nil, 500, 1000),
        seats: seats_meter(Map.get(inputs, :seats), Map.get(inputs, :pending_invitations)),
        instances: instances_meter(Map.get(inputs, :instances)),
        # FLOW meters — always unmetered, whatever anyone passes. req/s is a
        # RATE, not the billing request count — the flow meters stay dark here.
        api_requests: meter(@unmetered, @src_not_metered, nil),
        bandwidth: meter(@unmetered, @src_not_metered, nil)
      }
    }
  end

  # ── Meter builders ──────────────────────────────────────────────────────────

  # An instance inventory count. A landed `{:ok, n}` is the number; everything
  # else degrades to "unmetered" with the source still named (never a fake zero
  # on an unreachable box) — but NOT into one identical map, because the inputs
  # mean two OPPOSITE things:
  #
  #   * `:unmetered` / an absent input — nobody attempted a read (the box is not
  #     live, or carries no admin token). "Not yet metered" is the honest word.
  #   * `{:error, reason}` / a shape we cannot trust — the read WAS attempted and
  #     it FAILED. `within_deadline/2` already mints `{:error, :exception}` for a
  #     real raise, distinct from `{:error, :deadline_exceeded}`; the fan-outs add
  #     `:unreachable`, `:bad_shape`, `:too_many_datasets`. This clause used to
  #     throw all of that away, so a CRASHED meter rendered in the product's own
  #     words for a DELIBERATE non-measurement. The typed reason now rides along
  #     as `:unavailable_reason` so every surface can say "we could not measure
  #     this" instead.
  #
  # `:unavailable_reason` is a CONDITIONAL key (the `seats` meter's
  # `:pending_invitations` precedent): a meter that measured fine, or one that is
  # deliberately unmetered, does not carry it at all.
  defp instance_meter({:ok, n}, source) when is_integer(n) and n >= 0,
    do: meter(n, source, nil)

  defp instance_meter(:unmetered, source), do: meter(@unmetered, source, nil)
  defp instance_meter(nil, source), do: meter(@unmetered, source, nil)
  defp instance_meter({:error, reason}, source), do: unavailable_meter(source, reason)
  defp instance_meter(_other, source), do: unavailable_meter(source, :bad_shape)

  # A meter whose read was attempted and failed: value still degrades to
  # "unmetered" (never a fake zero) with the TYPED reason attached. The reason is
  # normalised to a known string so the envelope can never leak an arbitrary
  # internal atom to the browser — an unrecognised one is honestly "unknown".
  defp unavailable_meter(source, reason) do
    Map.put(meter(@unmetered, source, nil), :unavailable_reason, unavailable_reason(reason))
  end

  defp unavailable_reason(reason) when is_atom(reason) do
    name = Atom.to_string(reason)
    if name in @unavailable_reasons, do: name, else: "unknown"
  end

  defp unavailable_reason(_), do: "unknown"

  # DB size in bytes, from the agent's latest health beat. The agent reports `-1`
  # verbatim until the PGSizeBytes probe lands (report.go:170/194/246), so a bare
  # `is_number` guard would render that sentinel as a fake metered size on every
  # surface. Guard `n >= 0` like disk_meter/telemetry_threshold_meter: absent
  # telemetry, a negative sentinel, or a non-number → unmetered (with the
  # telemetry event's snapshot time when we have one, so the GUI can still say
  # "as of …" even on a degraded read).
  defp db_size_meter(telemetry, measured_at) do
    case telemetry && Map.get(telemetry, :db_size) do
      n when is_number(n) and n >= 0 -> meter(n, @src_db_size, measured_at)
      _ -> meter(@unmetered, @src_db_size, measured_at)
    end
  end

  # Disk used-percent, from the health beat. The agent passes `-1` verbatim when
  # the probe was never wired (Telemetry moduledoc: sentinel interpretation is a
  # view concern) — treat a negative / non-number as "not measured", never a
  # fake 0% that reads as an empty disk.
  # Disk used-percent, retrofitted to the machine-meter thresholds (OC23): a real
  # physical ceiling of 100 with warn 70 / over 90, so a filling disk ambers then
  # reddens on every surface exactly like cpu/ram. A negative / non-number is "not
  # measured" → unmetered (the ceiling still rides, but no bar/state on a sentinel).
  defp disk_meter(telemetry, measured_at) do
    value =
      case telemetry && get_in(telemetry, [:disk, :used_pct]) do
        n when is_number(n) and n >= 0 -> n
        _ -> @unmetered
      end

    meter(value, @src_disk, measured_at, 100, 70, 90)
  end

  # A telemetry-sourced meter carrying warn/over thresholds (OC23/OC26). The value
  # is the beat's signal when it's a real non-negative number, else "unmetered"
  # (an unwired `-1` probe or an absent signal is NEVER a fake 0). The ceiling +
  # thresholds ride on EVERY branch — they are a property of the meter, not the
  # reading — so a still-dark cpu meter already knows its 100% wall.
  defp telemetry_threshold_meter(telemetry, key, source, measured_at, quota, warn_at, over_at) do
    value =
      case telemetry && Map.get(telemetry, key) do
        n when is_number(n) and n >= 0 -> n
        _ -> @unmetered
      end

    meter(value, source, measured_at, quota, warn_at, over_at)
  end

  # Seat count from the team's membership — a control-plane read that returns
  # even when the instance is down. `pending_invitations` rides along as a cheap
  # detail when present.
  defp seats_meter(seats, pending) do
    base =
      case seats do
        n when is_integer(n) and n >= 0 -> meter(n, @src_seats, nil)
        _ -> meter(@unmetered, @src_seats, nil)
      end

    case pending do
      p when is_integer(p) and p >= 0 -> Map.put(base, :pending_invitations, p)
      _ -> base
    end
  end

  # The fleet meter (OC11 — the fleet's one honest quota). `value` is the live
  # managed-instance count (a control-plane read, so no snapshot time); `quota`
  # is whatever ceiling the router resolved — a real, subscription-backed limit,
  # or nil when there is no honest wall to draw (no active subscription, or the
  # "forever" placeholder). `warn_at` is derived from that quota alone. A missing
  # / non-integer count degrades to "unmetered" — never a fake zero on a team we
  # couldn't tally.
  defp instances_meter(%{} = input) do
    quota = valid_quota(Map.get(input, :quota))
    meter(instance_count(Map.get(input, :value)), @src_instances, nil, quota, warn_at_for(quota))
  end

  defp instances_meter(_), do: meter(@unmetered, @src_instances, nil, nil, nil)

  defp instance_count(n) when is_integer(n) and n >= 0, do: n
  defp instance_count(_), do: @unmetered

  # Only a positive integer is a real ceiling; anything else (nil, 0, garbage)
  # means "no honest quota to display" → nil, no bar.
  defp valid_quota(n) when is_integer(n) and n >= 1, do: n
  defp valid_quota(_), do: nil

  # The amber threshold: one below the ceiling, or 80% rounded up, whichever is
  # lower — but only once the ceiling has room for a warning tier (>= 2). `ceil/1`
  # returns an integer, so warn_at is always an integer or nil.
  defp warn_at_for(quota) when is_integer(quota) and quota >= 2,
    do: min(quota - 1, ceil(quota * 0.8))

  defp warn_at_for(_), do: nil

  # The uniform meter shape. `quota`/`warn_at`/`over_at` default to nil — the
  # honest state for a meter with no ceiling and no threshold. `over_at` (OC25) is
  # the red line: state is `over` when (over_at && value >= over_at) OR (quota &&
  # value >= quota), `warn` at warn_at, else `ok`/`live`. A physical meter
  # (cpu/ram/disk) reddens at over_at (90) BELOW its 100 bar ceiling; the
  # `instances` billing meter carries a quota and no over_at, so it reddens at the
  # quota itself (the inclusive create-time guard).
  defp meter(value, source, measured_at, quota \\ nil, warn_at \\ nil, over_at \\ nil) do
    %{
      value: value,
      quota: quota,
      warn_at: warn_at,
      over_at: over_at,
      source: source,
      measured_at: measured_at
    }
  end

  # ── Input coercion (stay total) ─────────────────────────────────────────────

  defp telemetry_or_nil(t) when is_map(t), do: t
  defp telemetry_or_nil(_), do: nil

  defp telemetry_measured_at(nil), do: nil

  defp telemetry_measured_at(telemetry) do
    case Map.get(telemetry, :reported_at) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  # ── IO gather (the router's /usage route + the sampler worker) ───────────────

  @doc """
  Gather every meter's source input for one instance and shape it through the
  pure `compose/1`. Loads the instance's team internally (seats / fleet-quota are
  team-scoped control-plane reads that return even when the box is down). Each
  gatherer is fail-soft: a source that errors degrades its ONE meter to
  "unmetered", never the whole envelope. Never raises; never leaks the admin
  token into the returned envelope.
  """
  @spec gather(Barkpark.t()) :: %{meters: map()}
  def gather(%Barkpark{} = bp) do
    team = Accounts.get_team(bp.team_id)

    # The WHOLE 1+2N inventory gather (list + documents fan-out + webhooks
    # fan-out) shares ONE monotonic deadline so a slow / many-dataset box returns
    # a (degraded) envelope inside the SPA's ~15s skeleton, not 1+2N × 15s ≈ 98s.
    deadline = System.monotonic_time(:millisecond) + fanout_budget_ms()
    datasets = instance_datasets(bp, deadline)
    slugs = fanout_slugs(datasets)

    compose(%{
      telemetry: telemetry(bp),
      seats: seats(team),
      pending_invitations: pending_invitations(team),
      datasets: dataset_count(datasets),
      documents: instance_documents(bp, slugs, deadline),
      webhooks: instance_webhooks(bp, slugs, deadline),
      instances: instances_input(team)
    })
  end

  @doc """
  Gather (a live instance fan-out) + persist a `Usage.Sample` row. The sampler
  worker calls this once per checkable instance per tick, writing a row EVERY
  time — even for an unreachable box, whose instance-sourced meters degrade to
  "unmetered" while `measured_at` stays a real timestamp. Returns the Repo
  insert result.
  """
  @spec record_sample(Barkpark.t()) :: {:ok, Sample.t()} | {:error, Ecto.Changeset.t()}
  def record_sample(%Barkpark{} = bp) do
    %Sample{}
    |> Sample.changeset(%{
      barkpark_id: bp.id,
      envelope: gather(bp),
      measured_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  # ── Pure fleet read (GET /v1/usage/summary) ──────────────────────────────────

  @doc """
  The team's fleet meter strip — a PURE DB read, ZERO instance HTTP. Returns the
  live fleet-quota meter (`team.instances`, an OC11 control-plane read) beside
  the LATEST cached sample per checkable instance. An instance with no sample yet
  serves the honest all-"unmetered" envelope with `measured_at: nil`.
  """
  @spec summary(Accounts.Team.t()) :: %{team: map(), instances: [map()]}
  def summary(team) do
    instances = checkable_barkparks(team)
    latest = latest_samples_by_barkpark(Enum.map(instances, & &1.id))

    %{
      team: %{instances: team_instances_meter(team)},
      instances: Enum.map(instances, &instance_summary(&1, latest))
    }
  end

  @doc """
  The LIVE fleet-quota meter for a team (OC11) — the managed-instance count with
  its enforcement-backed ceiling, shaped through `compose/1`. A control-plane
  read (no instance HTTP), so it stays live on the otherwise-cached summary.
  """
  @spec team_instances_meter(Accounts.Team.t()) :: map()
  def team_instances_meter(team) do
    compose(%{instances: instances_input(team)}).meters.instances
  end

  # ── Pure usage-meter history (GET /v1/barkparks/:id/usage/history) ────────────

  @doc """
  One instance's usage-meter history over the trailing 14-day window — a PURE DB
  read of its cached `usage_samples` rows (ZERO instance HTTP), shaped for
  sparklines. Mirrors `Metrics.build/3`'s series envelope, but over the usage
  meters instead of the vitals.

  The window is split into `points` uniform time buckets (default from the
  route, capped there); each bucket carries the LATEST sample that fell in it. An
  EMPTY bucket → `value: nil`; a meter that was `"unmetered"` (or absent) in the
  winning sample → `nil` too — a GAP, never a fake zero (D48/D51). Each point's
  `at` is the bucket's right edge (RFC3339), so every meter's series shares one
  uniform, oldest→newest x-axis a client can plot directly.

  A never-sampled instance is a normal result: every point in every series is
  nil. Total — never raises (a pure query + arithmetic).
  """
  @spec history(Barkpark.t(), pos_integer()) :: map()
  def history(%Barkpark{} = bp, points) when is_integer(points) do
    points = max(points, 1)
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    start_ms = now_ms - @history_window_ms
    window_start = DateTime.from_unix!(start_ms, :millisecond)

    winners = latest_sample_per_bucket(bp, window_start, start_ms, points)
    meter_names = Map.keys(compose(%{}).meters)

    %{
      ok: true,
      collected_at: DateTime.to_iso8601(now),
      instance: %{id: bp.id, name: bp.name, slug: bp.slug, host: bp.host},
      points: points,
      window_days: @history_window_days,
      series: history_series(meter_names, winners, start_ms, points)
    }
  end

  # Bucket every in-window sample by its position in the [start, now] span and
  # keep the LATEST per bucket. Samples arrive ascending by `measured_at`, so a
  # later sample simply overwrites an earlier one in the same bucket.
  defp latest_sample_per_bucket(bp, window_start, start_ms, points) do
    from(s in Sample,
      where: s.barkpark_id == ^bp.id and s.measured_at >= ^window_start,
      order_by: [asc: s.measured_at]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn s, acc ->
      Map.put(acc, bucket_index(s.measured_at, start_ms, points), s)
    end)
  end

  # Which of the `points` buckets a sample falls in: floor of its fractional
  # position across the span, clamped to 0..points-1 (a boundary sample at `now`
  # lands in the last bucket).
  defp bucket_index(measured_at, start_ms, points) do
    ms = DateTime.to_unix(measured_at, :millisecond)
    idx = div((ms - start_ms) * points, @history_window_ms)
    idx |> max(0) |> min(points - 1)
  end

  # One series per meter: `points` points oldest→newest, each `{at, value|nil}`.
  # `at` is the bucket's right-edge timestamp (uniform x-axis); value comes from
  # that bucket's winning sample, or nil for an empty bucket / non-numeric meter.
  defp history_series(meter_names, winners, start_ms, points) do
    indexed_ats = Enum.with_index(bucket_edges(start_ms, points))

    Map.new(meter_names, fn name ->
      key = Atom.to_string(name)

      pts =
        Enum.map(indexed_ats, fn {at, i} ->
          %{at: at, value: bucket_value(Map.get(winners, i), key)}
        end)

      {name, pts}
    end)
  end

  # The right-edge RFC3339 timestamp of every bucket, oldest→newest. The last
  # edge is `now` (start + points * span/points).
  defp bucket_edges(start_ms, points) do
    Enum.map(1..points, fn i ->
      (start_ms + div(i * @history_window_ms, points))
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.to_iso8601()
    end)
  end

  # A bucket's value for one meter: the winning sample's numeric meter value, or
  # nil (empty bucket, "unmetered", or an absent/non-numeric meter) — a GAP, not
  # a fake zero. The stored envelope has STRING keys (jsonb round-trip).
  defp bucket_value(nil, _key), do: nil

  defp bucket_value(%Sample{envelope: envelope}, key) do
    case get_in(envelope, ["meters", key, "value"]) do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  # The team's checkable instances — the SAME "live + not billing-suspended"
  # predicate the sampler sweeps (`Registry.update_checkable_barkparks/0`),
  # scoped to this team so the summary is team-private. The predicate has ONE
  # home now (`Registry.checkable_scope/1`); this delegates so the fleet scope
  # can never drift between the sweep and the summary.
  defp checkable_barkparks(team), do: Registry.checkable_barkparks(team)

  # One instance's summary row: identity + its latest cached meters + the sample
  # time, read from the pre-fetched `latest` map (one DISTINCT ON query for the
  # whole fleet, not a LIMIT 1 per instance — flag a). No cached row (never
  # sampled) → the honest all-"unmetered" envelope, measured_at nil.
  defp instance_summary(bp, latest) do
    base = %{id: bp.id, name: bp.name, slug: bp.slug, host: bp.host}

    case Map.get(latest, bp.id) do
      %Sample{envelope: %{"meters" => meters}, measured_at: at} ->
        Map.merge(base, %{measured_at: at, meters: meters})

      _ ->
        Map.merge(base, %{measured_at: nil, meters: compose(%{}).meters})
    end
  end

  # The LATEST sample per instance for the whole fleet in ONE query: `DISTINCT ON
  # (barkpark_id)` with `ORDER BY barkpark_id, measured_at DESC` keeps the newest
  # row per box. Replaces the old per-instance `LIMIT 1` N+1 (flag a) — the
  # composite `(barkpark_id, measured_at)` index still backs it. Returns a map
  # keyed by barkpark_id; an empty id list yields an empty map (no query cost
  # concern — Ecto renders `IN ()` as a false predicate).
  defp latest_samples_by_barkpark([]), do: %{}

  defp latest_samples_by_barkpark(ids) do
    from(s in Sample,
      where: s.barkpark_id in ^ids,
      distinct: s.barkpark_id,
      order_by: [asc: s.barkpark_id, desc: s.measured_at]
    )
    |> Repo.all()
    |> Map.new(&{&1.barkpark_id, &1})
  end

  # ── control-plane gatherers (return even when the instance is down) ──────────

  # The latest health beat, normalized — the newest health event in the recent
  # window. Carries `reported_at` for the telemetry meters' `measured_at`. nil
  # when the box has never phoned home.
  defp telemetry(bp) do
    case Enum.find(Registry.recent_events(bp, 100), &(&1.type == "health")) do
      nil -> nil
      event -> Telemetry.normalize(event)
    end
  end

  # Seat count = the team's members. Rescued to nil (→ seats "unmetered") so a
  # transient repo hiccup / missing team degrades one meter, never the envelope.
  defp seats(team) do
    length(Accounts.list_team_members(team))
  rescue
    _ -> nil
  end

  defp pending_invitations(team) do
    length(Accounts.list_invitations(team))
  rescue
    _ -> nil
  end

  # The fleet meter input (OC11). `value` is the team's live managed-instance
  # count; `quota` is the plan ceiling the create-time 402 guard + the quota
  # reconciler both enforce (`Billing.barkpark_limit/1`), but ONLY when it is an
  # honest wall to draw:
  #
  #   * NO active subscription → nil. An unsubscribed team's ceiling is owned by
  #     the ENTITLEMENT gate (the 402), not a quota bar.
  #   * a "forever"-tier placeholder (>= 100_000) → nil. A bar to a million is a
  #     lie.
  #
  # Rescued so a repo hiccup / missing team degrades THIS meter (→ "unmetered"),
  # never the envelope. `compose/1` derives `warn_at` from the quota.
  defp instances_input(team) do
    %{value: Registry.count_barkparks(team), quota: instance_quota(team)}
  rescue
    _ -> %{value: nil, quota: nil}
  end

  defp instance_quota(team) do
    case Billing.active_subscription(team) do
      nil ->
        nil

      %{} ->
        limit = Billing.barkpark_limit(team)
        if is_integer(limit) and limit < 100_000, do: limit
    end
  end

  # ── instance-inventory gatherers (C11 — real documents/datasets/webhooks) ────
  #
  # Every gatherer fetches SERVER-SIDE with the vault-stored admin token over the
  # SAME transport seam the router proxy uses (`instance_api_http_client/0`). In
  # EVERY branch the token stays in the request HEADER and NEVER appears in a
  # return value, a log line, or an error tuple. A not-live / token-less instance
  # has nothing to fetch → `:unmetered`; a transport / shape / deadline failure →
  # `{:error, _}`; both let `instance_meter/2` degrade that ONE meter honestly.

  # Cap on the per-request inventory FAN-OUT. A box with more datasets than this
  # can't be totalled inside the skeleton budget without risking a hang, so the
  # fanned meters degrade to "unmetered" — the datasets COUNT itself still lands.
  @max_fanout_datasets 24

  # How many per-dataset inventory calls run at once inside a fan-out.
  @fanout_concurrency 8

  # Per-CALL ceiling for one dataset's fetch — matches the transport's own 15s
  # total; the aggregate deadline below is the real bound.
  @fanout_call_ms 15_000

  # The AGGREGATE wall-clock budget for the entire 1+2N inventory gather.
  # Overridable (tests drive it down to prove the deadline).
  @fanout_budget_default_ms 10_000

  defp fanout_budget_ms do
    Application.get_env(:barkpark_cloud, :usage_fanout_budget_ms, @fanout_budget_default_ms)
  end

  # Run `fun` bounded by the time remaining until `deadline`. Returns the fun's
  # value, or `{:error, :deadline_exceeded}` when the budget is spent. Crash-safe:
  # a raise / exit inside `fun` becomes `{:error, :exception}` and an overrun task
  # is brutally killed — so a hung / crashing instance NEVER takes the caller
  # down. This is what makes the SHARED deadline real: `Task.async_stream`'s own
  # `:timeout` is per-ELEMENT, so it can't bound a whole fan-out plus the list.
  defp within_deadline(deadline, fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :deadline_exceeded}
    else
      task =
        Task.async(fn ->
          try do
            fun.()
          rescue
            _ -> {:error, :exception}
          catch
            _, _ -> {:error, :exception}
          end
        end)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :deadline_exceeded}
      end
    end
  end

  # The instance's dataset list, fetched once. `{:ok, [slug]}` on success;
  # `:unmetered` when the box is not live / token-less; `{:error, _}` on a
  # transport or shape failure.
  defp instance_datasets(bp, deadline) do
    with {:ok, base} <- instance_base_url(bp),
         {:ok, admin_token} <- instance_admin_token(bp) do
      within_deadline(deadline, fn ->
        request = %{
          method: :get,
          url: base <> "/api/workspaces/default/projects/default/datasets",
          headers: instance_api_headers(admin_token),
          body: ""
        }

        case instance_api_http_client().request(request) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            parse_dataset_slugs(body)

          {:ok, %{status: status}} ->
            {:error, delivered_failure(status)}

          _ ->
            {:error, :unreachable}
        end
      end)
    else
      {:error, _} -> :unmetered
    end
  end

  # The datasets METER count = how many datasets the list returned. A failure /
  # not-live passes through verbatim so `instance_meter/2` degrades it.
  defp dataset_count({:ok, slugs}), do: {:ok, length(slugs)}
  defp dataset_count(other), do: other

  # The slug set the documents + webhooks fan-outs iterate. A successful list
  # within the cap → `{:ok, slugs}`; over the cap → an honest error; a not-live /
  # failed list passes through so both fanned meters degrade in lockstep.
  defp fanout_slugs({:ok, slugs}) when length(slugs) <= @max_fanout_datasets, do: {:ok, slugs}
  defp fanout_slugs({:ok, _slugs}), do: {:error, :too_many_datasets}
  defp fanout_slugs(other), do: other

  # Cross-dataset DOCUMENT total: sum every dataset's `total_documents`. Any
  # per-dataset failure degrades the WHOLE meter (a partial sum undercounts).
  defp instance_documents(bp, {:ok, slugs}, deadline) do
    with {:ok, base} <- instance_base_url(bp),
         {:ok, admin_token} <- instance_admin_token(bp) do
      sum_across_datasets(
        slugs,
        fn slug -> count_documents(base, admin_token, slug) end,
        deadline
      )
    else
      {:error, _} -> :unmetered
    end
  end

  defp instance_documents(_bp, other, _deadline), do: other

  # Cross-dataset WEBHOOK total: sum every dataset's webhook-list length.
  defp instance_webhooks(bp, {:ok, slugs}, deadline) do
    with {:ok, base} <- instance_base_url(bp),
         {:ok, admin_token} <- instance_admin_token(bp) do
      sum_across_datasets(slugs, fn slug -> count_webhooks(base, admin_token, slug) end, deadline)
    else
      {:error, _} -> :unmetered
    end
  end

  defp instance_webhooks(_bp, other, _deadline), do: other

  # Sum a per-dataset count across the set CONCURRENTLY (`@fanout_concurrency` at
  # a time), bounded by the shared `deadline`. SHORT-CIRCUITS to `{:error, _}` the
  # instant ANY element is not a landed `{:ok, n>=0}` — a per-dataset failure, a
  # bad shape, a per-call timeout, or the whole fan-out overrunning the aggregate
  # budget — because a partial cross-dataset total would silently undercount.
  # `ordered: false` lets fast datasets report while a slow one is still in flight.
  #
  # The short-circuit carries the FIRST failing element's OWN reason out
  # (`fanout_failure_reason/1`) instead of flattening it. `count_documents/3` and
  # `count_webhooks/3` already mint the typed vocabulary — `unauthorized`,
  # `instance_error`, `refused`, `unreachable`, `bad_shape` — and squashing them
  # into one unlisted atom made `unavailable_reason/1` normalise every per-dataset
  # failure to "unknown": a 401 on one dataset read the same as a timeout.
  defp sum_across_datasets(slugs, fetch_one, deadline) do
    within_deadline(deadline, fn ->
      slugs
      |> Task.async_stream(fetch_one,
        max_concurrency: @fanout_concurrency,
        timeout: @fanout_call_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce_while({:ok, 0}, fn
        {:ok, {:ok, n}}, {:ok, acc} when is_integer(n) and n >= 0 ->
          {:cont, {:ok, acc + n}}

        other, _acc ->
          {:halt, {:error, fanout_failure_reason(other)}}
      end)
    end)
  end

  # One fan-out element that is not a landed `{:ok, n>=0}`, mapped to the word the
  # surface should say. Every arm lands INSIDE `@unavailable_reasons`, so no new
  # console copy is required and nothing normalises to "unknown":
  #
  #   * the fetch itself returned a typed `{:error, reason}` → carry it verbatim
  #     (`unauthorized` / `instance_error` / `refused` / `unreachable` / `bad_shape`)
  #   * `on_timeout: :kill_task` yields `{:exit, :timeout}` → `deadline_exceeded`,
  #     the same word the aggregate-budget overrun already uses
  #   * any other child exit → `exception`
  #   * an `{:ok, _}` we cannot trust (a non-integer / negative count) → `bad_shape`,
  #     matching what `decode_scalar_total/2` says about a body it cannot read
  defp fanout_failure_reason({:ok, {:error, reason}}) when is_atom(reason), do: reason
  defp fanout_failure_reason({:exit, :timeout}), do: :deadline_exceeded
  defp fanout_failure_reason({:exit, _}), do: :exception
  defp fanout_failure_reason(_), do: :bad_shape

  # One dataset's webhook count — `{"webhooks": [...]}` (instance
  # WebhookController.index). Any other shape is an honest degrade.
  defp count_webhooks(base, admin_token, dataset) do
    request = %{
      method: :get,
      url: base <> "/v1/webhooks/" <> dataset,
      headers: instance_api_headers(admin_token),
      body: ""
    }

    case instance_api_http_client().request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_list_count(body, "webhooks")

      {:ok, %{status: status}} ->
        {:error, delivered_failure(status)}

      _ ->
        {:error, :unreachable}
    end
  end

  # One dataset's document total — `{"total_documents": n, ...}` (instance
  # AnalyticsController.index). A single cheap read per dataset.
  defp count_documents(base, admin_token, dataset) do
    request = %{
      method: :get,
      url: base <> "/v1/data/analytics/" <> dataset,
      headers: instance_api_headers(admin_token),
      body: ""
    }

    case instance_api_http_client().request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_scalar_total(body, "total_documents")

      {:ok, %{status: status}} ->
        {:error, delivered_failure(status)}

      _ ->
        {:error, :unreachable}
    end
  end

  # A DELIVERED non-2xx: the box ANSWERED. Which word it earns is a
  # user-facing judgement, so it is made in ONE place for all three reads —
  # 401/403 is our credential being rejected, a 5xx is the instance failing on
  # its own side, and anything else is a refused read. None of these is
  # `unreachable`: the packets arrived.
  defp delivered_failure(status) when status in [401, 403], do: :unauthorized
  defp delivered_failure(status) when status in 500..599, do: :instance_error
  defp delivered_failure(_status), do: :refused

  # `{"<key>": [...]}` → `{:ok, length}`; any other shape → an honest degrade.
  defp decode_list_count(body, key) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{^key => list}} when is_list(list) -> {:ok, length(list)}
      _ -> {:error, :bad_shape}
    end
  end

  defp decode_list_count(_, _key), do: {:error, :bad_shape}

  # `{"<key>": n}` → `{:ok, n}` for a non-negative integer; else degrade.
  defp decode_scalar_total(body, key) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{^key => n}} when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, :bad_shape}
    end
  end

  defp decode_scalar_total(_, _key), do: {:error, :bad_shape}

  # The datasets-list envelope → a slug list (skipping any malformed row).
  defp parse_dataset_slugs(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"datasets" => list}} when is_list(list) ->
        {:ok, for(%{"slug" => s} <- list, is_binary(s) and s != "", do: s)}

      _ ->
        {:error, :bad_shape}
    end
  end

  defp parse_dataset_slugs(_), do: {:error, :bad_shape}

  # ── instance-API transport primitives (shared with the router proxy) ─────────
  #
  # These are the ONE home for the control plane's instance-API read transport:
  # the router's proxy relay delegates here too (`Router.instance_base_url/1` etc.
  # are thin wrappers), so the base-URL / token-custody / headers / client-seam
  # rules live in a single place.

  @doc "A live instance has a non-empty `url`; trims a trailing slash. `{:error, :not_live}` otherwise."
  @spec instance_base_url(Barkpark.t()) :: {:ok, String.t()} | {:error, :not_live}
  def instance_base_url(%Barkpark{url: url}) when is_binary(url) and url != "",
    do: {:ok, String.trim_trailing(url, "/")}

  def instance_base_url(_), do: {:error, :not_live}

  @doc """
  Decrypt the stored per-instance admin token server-side. `{:ok, nil}` (a
  pre-feature row) is `:no_admin_token`; a tampered ciphertext fails closed.
  """
  @spec instance_admin_token(Barkpark.t()) ::
          {:ok, String.t()} | {:error, :no_admin_token | :decrypt_failed}
  def instance_admin_token(bp) do
    case Registry.reveal_admin_token(bp) do
      {:ok, nil} -> {:error, :no_admin_token}
      {:ok, token} -> {:ok, token}
      :error -> {:error, :decrypt_failed}
    end
  end

  @doc "The instance-API request headers — the admin token rides ONLY here, never in a body/return."
  @spec instance_api_headers(String.t()) :: [{String.t(), String.t()}]
  def instance_api_headers(admin_token) do
    [
      {"Authorization", "Bearer " <> admin_token},
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]
  end

  @doc """
  The instance-API transport seam — the SAME swappable client the studio-link /
  self-update / site-url relays use (`:studio_link_http_client`; tests wire
  `StudioLinkFakeHttpClient`). Default is the verified-TLS :httpc client.
  """
  @spec instance_api_http_client() :: module()
  def instance_api_http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end
end
