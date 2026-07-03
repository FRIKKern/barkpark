defmodule BarkparkCloud.UsageTest do
  @moduledoc """
  `Usage.compose/1` is the PURE, TOTAL shaper of the console's usage envelope
  (charter decision D48 — two honesty tiers). These tests exercise it directly,
  no DB, no HTTP:

    * the meter vocabulary is FIXED and ALWAYS fully present (8 meters)
    * every meter is the uniform `{value, quota, warn_at, source, measured_at}`
      shape; quota/warn_at are always nil in v1 (display precedes enforcement)
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

  alias BarkparkCloud.Usage

  @meter_keys ~w(documents datasets webhooks db_size disk seats api_requests bandwidth)a

  # A `Telemetry.normalize/1`-shaped envelope with a snapshot time.
  defp telemetry(overrides \\ %{}) do
    Map.merge(
      %{
        disk: %{used_pct: 42},
        db_size: 123_456_789,
        backup: %{ok: true, detail: "2h ago"},
        checks: %{pass: 3, total: 3, failing: []},
        dirty_tree: false,
        reported_at: "2026-07-03T10:00:00Z"
      },
      overrides
    )
  end

  defp meters(inputs), do: Usage.compose(inputs).meters

  describe "envelope shape — fixed vocabulary, uniform meters" do
    test "ALL eight meters are present, even on empty input" do
      m = meters(%{})
      assert Map.keys(m) |> Enum.sort() == Enum.sort(@meter_keys)
    end

    test "every meter is the uniform shape; quota + warn_at are always nil" do
      m = meters(full_inputs())

      for {_key, meter} <- m do
        assert Map.has_key?(meter, :value)
        assert Map.get(meter, :quota) == nil
        assert Map.get(meter, :warn_at) == nil
        assert is_binary(meter.source)
        assert match?(nil, meter.measured_at) or is_binary(meter.measured_at)
        # value is a number OR the literal "unmetered" — never anything else.
        assert is_number(meter.value) or meter.value == "unmetered"
      end
    end

    test "each meter names its source" do
      m = meters(%{})
      assert m.documents.source == "instance.documents"
      assert m.datasets.source == "instance.datasets"
      assert m.webhooks.source == "instance.webhooks"
      assert m.db_size.source == "telemetry.pg_size_bytes"
      assert m.disk.source == "telemetry.disk_used_percent"
      assert m.seats.source == "control-plane.team_members"
      assert m.api_requests.source == "not-metered"
      assert m.bandwidth.source == "not-metered"
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

  describe "totality — never raises, always honest" do
    test "compose/0 yields the all-unmetered envelope" do
      m = Usage.compose().meters
      assert Enum.sort(Map.keys(m)) == Enum.sort(@meter_keys)

      for key <- @meter_keys -- [], reduce: :ok do
        _ ->
          assert Map.fetch!(m, key).value == "unmetered"
          :ok
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

  # A fully-populated input set for shape assertions.
  defp full_inputs do
    %{
      telemetry: telemetry(),
      seats: 3,
      pending_invitations: 1,
      webhooks: {:ok, 4},
      documents: :unmetered,
      datasets: :unmetered
    }
  end
end
