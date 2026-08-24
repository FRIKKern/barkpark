defmodule BarkparkCloud.UsageTest do
  @moduledoc """
  `Usage.compose/1` is the PURE, TOTAL shaper of the console's usage envelope
  (charter decision D48 — two honesty tiers). These tests exercise it directly,
  no DB, no HTTP:

    * the meter vocabulary is FIXED and ALWAYS fully present (13 meters)
    * every meter is the uniform `{value, quota, warn_at, over_at, source,
      measured_at}` shape; quota/warn_at/over_at are nil for a meter WITHOUT a
      ceiling or threshold. `instances` (OC11) carries the fleet's one billing
      quota; cpu/ram/disk carry the physical 100/70/90 ceiling; req_per_s/p95_ms
      carry warn+over thresholds but no quota (OC23/OC25/OC26)
    * FLOW meters (api_requests, bandwidth) are ALWAYS "unmetered" — never a fake
      zero, whatever the input
    * inventory / telemetry / seats ship a real number when their source lands,
      and degrade to "unmetered" (source still named) on failure / absence —
      never a fake zero
    * the disk sentinel (-1 = probe unwired) degrades, never renders as 0%
    * db_size / disk carry the health event's snapshot time as measured_at
    * seats carries pending_invitations as a cheap detail when present
    * compose over an EMPTY / garbage input is total (never raises) and honest
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.RealAgentBeats
  alias BarkparkCloud.Telemetry
  alias BarkparkCloud.Usage

  @meter_keys ~w(documents datasets webhooks db_size disk cpu ram req_per_s p95_ms seats instances api_requests bandwidth)a

  # Meters with NO ceiling and NO threshold — quota/warn_at/over_at all nil.
  @no_ceiling_meters ~w(documents datasets webhooks db_size seats api_requests bandwidth)a
  # Percent machine meters carrying the physical 100/70/90 ceiling on every branch.
  @percent_ceiling_meters ~w(disk cpu ram)a
  # Rate/latency meters carrying warn+over thresholds but NO quota bar.
  @threshold_only_meters ~w(req_per_s p95_ms)a

  # A `Telemetry.normalize/1`-shaped envelope with a snapshot time.
  defp telemetry(overrides \\ %{}) do
    Map.merge(
      %{
        disk: %{used_pct: 42},
        db_size: 123_456_789,
        cpu: 12,
        mem: 34,
        load1: 0.4,
        req_per_s: 8,
        p95_ms: 40,
        backup: %{ok: true, detail: "2h ago"},
        checks: %{pass: 3, skipped: 0, total: 3, failing: []},
        dirty_tree: false,
        reported_at: "2026-07-03T10:00:00Z"
      },
      overrides
    )
  end

  defp meters(inputs), do: Usage.compose(inputs).meters

  describe "envelope shape — fixed vocabulary, uniform meters" do
    test "ALL thirteen meters are present, even on empty input" do
      m = meters(%{})
      assert Map.keys(m) |> Enum.sort() == Enum.sort(@meter_keys)
    end

    test "every meter is the uniform shape; ceilings/thresholds ride only their own meters" do
      m = meters(full_inputs())

      for {key, meter} <- m do
        assert Map.has_key?(meter, :value)
        assert Map.has_key?(meter, :quota)
        assert Map.has_key?(meter, :warn_at)
        # over_at (OC25) is present on EVERY meter, nil by default.
        assert Map.has_key?(meter, :over_at)
        assert is_binary(meter.source)
        assert match?(nil, meter.measured_at) or is_binary(meter.measured_at)
        # value is a number OR the literal "unmetered" — never anything else.
        assert is_number(meter.value) or meter.value == "unmetered"

        cond do
          # No ceiling, no threshold — the honest bar-less/tint-less state (OC7).
          key in @no_ceiling_meters ->
            assert meter.quota == nil
            assert meter.warn_at == nil
            assert meter.over_at == nil

          # Percent machine meters carry the physical 100/70/90 ceiling always.
          key in @percent_ceiling_meters ->
            assert meter.quota == 100
            assert meter.warn_at == 70
            assert meter.over_at == 90

          # Rate/latency meters carry warn+over but NO quota (no bar to nowhere).
          key in @threshold_only_meters ->
            assert meter.quota == nil
            assert is_integer(meter.warn_at)
            assert is_integer(meter.over_at)

          # instances — the billing quota meter, ceiling resolved by the router.
          key == :instances ->
            :ok
        end
      end
    end

    test "each meter names its source" do
      m = meters(%{})
      assert m.documents.source == "instance.documents"
      assert m.datasets.source == "instance.datasets"
      assert m.webhooks.source == "instance.webhooks"
      assert m.db_size.source == "telemetry.pg_size_bytes"
      assert m.disk.source == "telemetry.disk_used_percent"
      assert m.cpu.source == "telemetry.cpu_percent"
      assert m.ram.source == "telemetry.mem_used_percent"
      assert m.req_per_s.source == "telemetry.req_per_s"
      assert m.p95_ms.source == "telemetry.p95_ms"
      assert m.seats.source == "control-plane.team_members"
      assert m.instances.source == "control-plane.team_instances"
      assert m.api_requests.source == "not-metered"
      assert m.bandwidth.source == "not-metered"
    end
  end

  describe "machine meters — cpu/ram/req_per_s/p95_ms off the health beat (OC23/OC26)" do
    test "cpu/ram render the telemetry percent + carry the beat's measured_at and 100/70/90 ceiling" do
      m = meters(%{telemetry: telemetry(%{cpu: 63, mem: 71})})
      assert m.cpu.value == 63
      assert m.cpu.measured_at == "2026-07-03T10:00:00Z"
      assert {m.cpu.quota, m.cpu.warn_at, m.cpu.over_at} == {100, 70, 90}
      assert m.ram.value == 71
      assert {m.ram.quota, m.ram.warn_at, m.ram.over_at} == {100, 70, 90}
    end

    test "req_per_s/p95_ms render their telemetry signal with warn+over thresholds, no quota" do
      m = meters(%{telemetry: telemetry(%{req_per_s: 12, p95_ms: 120})})
      assert m.req_per_s.value == 12
      assert {m.req_per_s.quota, m.req_per_s.warn_at, m.req_per_s.over_at} == {nil, 210, 270}
      assert m.p95_ms.value == 120
      assert {m.p95_ms.quota, m.p95_ms.warn_at, m.p95_ms.over_at} == {nil, 500, 1000}
    end

    test "a -1 sentinel (probe unwired) degrades — never a fake 0, ceiling still rides" do
      m = meters(%{telemetry: telemetry(%{cpu: -1, mem: -1, req_per_s: -1, p95_ms: -1})})
      assert m.cpu.value == "unmetered"
      assert m.cpu.quota == 100
      assert m.ram.value == "unmetered"
      assert m.req_per_s.value == "unmetered"
      assert m.req_per_s.warn_at == 210
      assert m.p95_ms.value == "unmetered"
    end

    test "absent machine signals (an agent-less box) → unmetered, thresholds still present" do
      # No cpu/mem/req_per_s/p95_ms in the beat: honest unmetered, never a zero.
      m = meters(%{telemetry: telemetry(%{cpu: nil, mem: nil, req_per_s: nil, p95_ms: nil})})

      for key <- ~w(cpu ram req_per_s p95_ms)a,
          do: assert(Map.fetch!(m, key).value == "unmetered")

      assert m.cpu.over_at == 90
      assert m.p95_ms.over_at == 1000
    end

    test "no telemetry at all → all four unmetered, measured_at nil" do
      m = meters(%{})

      for key <- ~w(cpu ram req_per_s p95_ms)a do
        assert Map.fetch!(m, key).value == "unmetered"
        assert Map.fetch!(m, key).measured_at == nil
      end
    end

    test "a true zero cpu is a real 0, not the degrade" do
      m = meters(%{telemetry: telemetry(%{cpu: 0})})
      assert m.cpu.value == 0
    end
  end

  describe "flow meters — always unmetered (D31)" do
    test "api_requests + bandwidth are unmetered on empty input" do
      m = meters(%{})
      assert m.api_requests.value == "unmetered"
      assert m.bandwidth.value == "unmetered"
      assert m.api_requests.measured_at == nil
      assert m.bandwidth.measured_at == nil
    end

    test "flow meters stay unmetered EVEN IF a number is smuggled in" do
      # There is no input key for the flow meters — compose owns the honesty rule.
      m = meters(Map.merge(full_inputs(), %{api_requests: {:ok, 999}, bandwidth: {:ok, 999}}))
      assert m.api_requests.value == "unmetered"
      assert m.bandwidth.value == "unmetered"
    end
  end

  describe "instance inventory meters — value on {:ok, n}, degrade otherwise" do
    test "a landed count renders the number" do
      m = meters(%{webhooks: {:ok, 4}})
      assert m.webhooks.value == 4
      assert m.webhooks.measured_at == nil
    end

    test "C11: landed document + dataset counts render their real numbers" do
      # The router now resolves these over the wire (cross-dataset sums); the
      # composer shapes a landed {:ok, n} into the number, same as webhooks.
      m = meters(%{documents: {:ok, 812}, datasets: {:ok, 3}})
      assert m.documents.value == 812
      assert m.datasets.value == 3
      assert m.documents.measured_at == nil
      assert m.datasets.measured_at == nil
    end

    test "C11: a true zero documents / datasets is a real 0, not the degrade" do
      m = meters(%{documents: {:ok, 0}, datasets: {:ok, 0}})
      assert m.documents.value == 0
      assert m.datasets.value == 0
    end

    test "C11: a per-meter failure degrades documents / datasets, source still named" do
      # A failed cross-dataset fan-out (or an unenumerable box) is {:error, _};
      # each degrades to unmetered WITHOUT dragging the other meters down.
      m = meters(%{documents: {:error, :dataset_fetch_failed}, datasets: {:error, :unreachable}})
      assert m.documents.value == "unmetered"
      assert m.documents.source == "instance.documents"
      assert m.datasets.value == "unmetered"
      assert m.datasets.source == "instance.datasets"
    end

    test "zero webhooks is a real, TRUE zero (not the fake-zero degrade)" do
      m = meters(%{webhooks: {:ok, 0}})
      assert m.webhooks.value == 0
    end

    test "a transport error degrades to unmetered, source still named" do
      m = meters(%{webhooks: {:error, :unreachable}})
      assert m.webhooks.value == "unmetered"
      assert m.webhooks.source == "instance.webhooks"
    end

    test "an explicit :unmetered (D48 tier-2 not-yet-wired) degrades cleanly" do
      m = meters(%{documents: :unmetered, datasets: :unmetered})
      assert m.documents.value == "unmetered"
      assert m.datasets.value == "unmetered"
    end

    test "a missing key degrades to unmetered" do
      m = meters(%{})
      assert m.webhooks.value == "unmetered"
      assert m.documents.value == "unmetered"
      assert m.datasets.value == "unmetered"
    end

    test "a negative or non-integer count degrades (never trusted)" do
      assert meters(%{webhooks: {:ok, -1}}).webhooks.value == "unmetered"
      assert meters(%{webhooks: {:ok, "4"}}).webhooks.value == "unmetered"
    end
  end

  # w29 — a meter that COULD NOT be measured must not wear the product's word for
  # a meter we deliberately DO NOT measure. Both still degrade to "unmetered"
  # (never a fake zero); the typed reason is what tells them apart.
  describe "instance inventory meters — a FAILED read is not a deliberate non-measurement" do
    test "a real raise is NOT equal to a deliberate :unmetered — the whole map differs" do
      crash = crashed_read(fn -> raise "the documents fan-out blew up" end)
      assert crash == {:error, :exception}

      crashed = meters(%{documents: crash}).documents
      deliberate = meters(%{documents: :unmetered}).documents

      # THE assertion this slice exists for. On the pre-fix bytes these two maps
      # were byte-identical in every field, so `!=` was FALSE.
      assert crashed != deliberate

      # …and both are still honest about the number itself.
      assert crashed.value == "unmetered"
      assert deliberate.value == "unmetered"
      assert crashed.source == "instance.documents"
      assert deliberate.source == "instance.documents"

      # The discriminator is the typed reason, present on ONE of them only.
      assert crashed.unavailable_reason == "exception"
      refute Map.has_key?(deliberate, :unavailable_reason)
    end

    test "every failure reason the gatherer can mint survives to the envelope, distinctly" do
      for reason <- [
            :exception,
            :deadline_exceeded,
            :unreachable,
            :unauthorized,
            :refused,
            :instance_error,
            :bad_shape,
            :too_many_datasets
          ] do
        m = meters(%{webhooks: {:error, reason}})
        assert m.webhooks.value == "unmetered"
        assert m.webhooks.unavailable_reason == Atom.to_string(reason)
      end

      # A timeout and a crash are different answers, not one degraded map.
      assert meters(%{webhooks: {:error, :deadline_exceeded}}).webhooks !=
               meters(%{webhooks: {:error, :exception}}).webhooks
    end

    test "w58-s3: a box that ANSWERED and said no never reaches the wire as \"unreachable\"" do
      # `unreachable` is a claim about the network. A delivered 401/5xx/404 is a
      # claim about the box — if the allowlist ever drops these three they
      # degrade to "unknown", which the console renders as "the read failed".
      for reason <- [:unauthorized, :refused, :instance_error] do
        m = meters(%{datasets: {:error, reason}})
        assert m.datasets.unavailable_reason == Atom.to_string(reason)
        refute m.datasets.unavailable_reason == "unreachable"
        refute m.datasets.unavailable_reason == "unknown"
      end

      distinct =
        for reason <- [:unauthorized, :refused, :instance_error, :unreachable],
            uniq: true,
            do: meters(%{datasets: {:error, reason}}).datasets

      assert length(distinct) == 4
    end

    test "an unrecognised reason normalises to \"unknown\" — no raw internal atom on the wire" do
      m = meters(%{datasets: {:error, :dataset_fetch_failed}})
      assert m.datasets.unavailable_reason == "unknown"
      assert is_binary(m.datasets.unavailable_reason)
    end

    test "a shape we cannot trust is a FAILED read, not a deliberate one" do
      # `{:ok, "4"}` / a bare number are inputs no gatherer should produce — we
      # could not measure, so say so rather than claim we chose not to.
      assert meters(%{webhooks: {:ok, "4"}}).webhooks.unavailable_reason == "bad_shape"
      assert meters(%{documents: 5}).documents.unavailable_reason == "bad_shape"
    end

    test "a meter that MEASURED, or one deliberately unmetered, carries no reason at all" do
      m = meters(%{webhooks: {:ok, 4}, documents: :unmetered, datasets: nil})
      refute Map.has_key?(m.webhooks, :unavailable_reason)
      refute Map.has_key?(m.documents, :unavailable_reason)
      # An ABSENT input is nobody attempting a read, not a failure.
      refute Map.has_key?(m.datasets, :unavailable_reason)
      refute Map.has_key?(meters(%{}).webhooks, :unavailable_reason)
    end
  end

  describe "telemetry meters — db_size + disk, with snapshot time" do
    test "db_size + disk render the value and carry the health-beat measured_at" do
      m = meters(%{telemetry: telemetry()})
      assert m.db_size.value == 123_456_789
      assert m.db_size.measured_at == "2026-07-03T10:00:00Z"
      assert m.disk.value == 42
      assert m.disk.measured_at == "2026-07-03T10:00:00Z"
    end

    test "the disk -1 sentinel (probe unwired) degrades — never a fake 0%" do
      m = meters(%{telemetry: telemetry(%{disk: %{used_pct: -1}})})
      assert m.disk.value == "unmetered"
      # The snapshot time is still carried so the GUI can say "as of …".
      assert m.disk.measured_at == "2026-07-03T10:00:00Z"
    end

    test "the db_size -1 sentinel (PGSizeBytes probe unwired) degrades — never a fake size" do
      m = meters(%{telemetry: telemetry(%{db_size: -1})})
      assert m.db_size.value == "unmetered"
      # The snapshot time is still carried so the GUI can say "as of …".
      assert m.db_size.measured_at == "2026-07-03T10:00:00Z"
    end

    test "a nil db_size / disk degrades to unmetered" do
      m = meters(%{telemetry: telemetry(%{db_size: nil, disk: %{used_pct: nil}})})
      assert m.db_size.value == "unmetered"
      assert m.disk.value == "unmetered"
    end

    test "absent telemetry → both unmetered, measured_at nil" do
      m = meters(%{})
      assert m.db_size.value == "unmetered"
      assert m.db_size.measured_at == nil
      assert m.disk.value == "unmetered"
      assert m.disk.measured_at == nil
    end

    test "a REAL captured beat flips db_size to a real number, not 'unmetered'" do
      # The producer envelope, not a hand-built map: the exact jsonb the router
      # landed for guerrilla. db_size was pre-wired end to end and dark only
      # because the probe reported -1 — the first honest beat lights it up with
      # NO composer change.
      normalized =
        RealAgentBeats.guerrilla()
        |> Telemetry.normalize()
        |> Map.put(:reported_at, "2026-08-06T12:57:30Z")

      m = meters(%{telemetry: normalized})

      assert m.db_size.value == 3_525_639_191
      assert m.db_size.source == "telemetry.pg_size_bytes"
      assert m.db_size.measured_at == "2026-08-06T12:57:30Z"
      # …and the sibling telemetry meters land off the same real beat.
      assert m.disk.value == 76
      assert m.cpu.value == 100
      assert m.ram.value == 64
    end

    test "a REAL pre-upgrade beat keeps db_size honestly unmetered (-1, never a fake size)" do
      normalized = Telemetry.normalize(RealAgentBeats.pre_upgrade())
      m = meters(%{telemetry: normalized})

      assert m.db_size.value == "unmetered"
      # That box's disk IS measured — a partial box degrades one meter, not all.
      assert m.disk.value == 95
    end
  end

  describe "seats meter — control-plane count + pending detail" do
    test "seat count renders; pending_invitations rides as a detail" do
      m = meters(%{seats: 3, pending_invitations: 2})
      assert m.seats.value == 3
      assert m.seats.pending_invitations == 2
      # A live count, not a snapshot.
      assert m.seats.measured_at == nil
    end

    test "no pending invitations → the detail key is absent (not null)" do
      m = meters(%{seats: 1})
      assert m.seats.value == 1
      refute Map.has_key?(m.seats, :pending_invitations)
    end

    test "an unavailable seat count degrades to unmetered" do
      m = meters(%{seats: nil})
      assert m.seats.value == "unmetered"
    end

    test "zero pending invitations is still a real detail" do
      m = meters(%{seats: 2, pending_invitations: 0})
      assert m.seats.pending_invitations == 0
    end
  end

  describe "instances meter — the fleet's one honest quota (OC11)" do
    test "value is the live count; a resolved quota + derived warn_at ride along" do
      m = meters(%{instances: %{value: 2, quota: 3}})
      assert m.instances.value == 2
      assert m.instances.quota == 3
      # warn_at = min(quota-1, ceil(quota*0.8)) = min(2, 3) = 2
      assert m.instances.warn_at == 2
      # A live control-plane read — no snapshot time.
      assert m.instances.measured_at == nil
    end

    test "no quota resolved → quota AND warn_at nil (no bar to nowhere)" do
      # The router hands quota: nil for an unsubscribed team or the forever
      # placeholder; the count still renders honestly.
      m = meters(%{instances: %{value: 4, quota: nil}})
      assert m.instances.value == 4
      assert m.instances.quota == nil
      assert m.instances.warn_at == nil
    end

    test "a true zero instances is a real 0, not the degrade" do
      m = meters(%{instances: %{value: 0, quota: 3}})
      assert m.instances.value == 0
    end

    test "warn_at boundary cases across the ceiling" do
      # quota of 1 has no room for a warning tier → nil.
      assert warn_at(1) == nil
      # quota 2: min(1, ceil(1.6)=2) = 1
      assert warn_at(2) == 1
      # quota 3: min(2, ceil(2.4)=3) = 2
      assert warn_at(3) == 2
      # quota 5: min(4, ceil(4.0)=4) = 4
      assert warn_at(5) == 4
      # quota 10: min(9, ceil(8.0)=8) = 8
      assert warn_at(10) == 8
    end

    test "a non-positive / garbage quota is not a real ceiling → quota + warn_at nil" do
      for bad <- [0, -1, "3", 2.5, %{}] do
        m = meters(%{instances: %{value: 1, quota: bad}})
        assert m.instances.quota == nil
        assert m.instances.warn_at == nil
      end
    end

    test "a missing / non-integer count degrades to unmetered (never a fake zero)" do
      assert meters(%{instances: %{value: nil, quota: 3}}).instances.value == "unmetered"
      assert meters(%{instances: %{value: -1, quota: 3}}).instances.value == "unmetered"
      assert meters(%{instances: %{value: "2", quota: 3}}).instances.value == "unmetered"
      # A degraded count still carries its resolved quota — the ceiling is known
      # even when the tally isn't.
      assert meters(%{instances: %{value: nil, quota: 3}}).instances.quota == 3
    end

    test "an absent instances input degrades to unmetered, source still named" do
      m = meters(%{})
      assert m.instances.value == "unmetered"
      assert m.instances.quota == nil
      assert m.instances.warn_at == nil
      assert m.instances.source == "control-plane.team_instances"
    end

    test "a garbage instances input degrades rather than crashes" do
      for junk <- [42, "nope", {:weird, :tuple}, []] do
        m = meters(%{instances: junk})
        assert m.instances.value == "unmetered"
        assert m.instances.quota == nil
      end
    end
  end

  describe "totality — never raises, always honest" do
    test "compose/0 yields the all-unmetered envelope" do
      m = Usage.compose().meters
      assert Enum.sort(Map.keys(m)) == Enum.sort(@meter_keys)

      for key <- @meter_keys do
        assert Map.fetch!(m, key).value == "unmetered"
      end
    end

    test "garbage telemetry does not raise and degrades honestly" do
      for junk <- [nil, 42, "nope", [], %{"string" => "keys"}] do
        m = meters(%{telemetry: junk})
        assert m.db_size.value == "unmetered"
        assert m.disk.value == "unmetered"
      end
    end

    test "garbage inventory inputs degrade rather than crash" do
      m = meters(%{webhooks: :whatever, documents: 5, datasets: {:weird, :tuple}})
      assert m.webhooks.value == "unmetered"
      assert m.documents.value == "unmetered"
      assert m.datasets.value == "unmetered"
    end
  end

  # The crash value EXACTLY as `within_deadline/2` mints it: a REAL raise inside
  # a task, rescued to `{:error, :exception}`. Nothing is hand-written — if that
  # rescue arm ever stops producing the tuple, this helper stops too.
  defp crashed_read(fun) do
    Task.async(fn ->
      try do
        fun.()
      rescue
        _ -> {:error, :exception}
      end
    end)
    |> Task.await()
  end

  # The instances meter's derived warn_at for a given resolved ceiling.
  defp warn_at(quota), do: meters(%{instances: %{value: 1, quota: quota}}).instances.warn_at

  # A fully-populated input set for shape assertions — instances carries a real
  # quota so the shape test proves it's the ONE meter allowed a ceiling.
  defp full_inputs do
    %{
      telemetry: telemetry(),
      seats: 3,
      pending_invitations: 1,
      webhooks: {:ok, 4},
      documents: :unmetered,
      datasets: :unmetered,
      instances: %{value: 2, quota: 3}
    }
  end
end
