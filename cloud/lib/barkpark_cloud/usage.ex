defmodule BarkparkCloud.Usage do
  @moduledoc """
  Compose the console's usage envelope — every meter the Usage tab renders — as
  ONE stable, honest shape (epic charter decision D48: "meters without truth are
  lies"). This module is PURE and TOTAL: it never touches the network or the DB,
  never raises whatever it is handed, and always emits the FULL, fixed meter
  vocabulary so a consumer can always destructure it. The router
  (`BarkparkCloud.Web.Router`) does the IO — telemetry lookup, team-member count,
  the server-side instance count fetch with the vault-stored admin token — and
  hands the resolved (possibly partial / failed) inputs here to be shaped.

  ## The meter vocabulary is FIXED and always fully present

      documents      datasets      webhooks       — instance-sourced inventory counts
      db_size        disk                          — telemetry-sourced (the agent's health beat)
      seats                                         — control-plane-sourced (team members)
      api_requests   bandwidth                     — FLOW meters, D31-sequenced (see below)

  Every meter is the SAME shape:

      %{
        value: number | "unmetered",
        quota: nil,          # quota DISPLAY precedes enforcement — always null in v1 (D48)
        warn_at: nil,        # ditto
        source: String.t(),  # always names where the number does / would come from
        measured_at: String.t() | nil   # RFC3339 snapshot time, or nil for a live/current read
      }

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
     metering does not exist yet (D31 sequencing); pretending otherwise with a
     zero would be a lie. They render as a designed "not yet metered" state, not
     a number, regardless of any input.

  ## Input contract (all keys OPTIONAL — a missing key degrades honestly)

      %{
        telemetry: <`Telemetry.normalize/1` envelope> | nil,
        seats: non_neg_integer | nil,
        pending_invitations: non_neg_integer | nil,
        documents: {:ok, non_neg_integer} | :unmetered | {:error, term} | nil,
        datasets:  {:ok, non_neg_integer} | :unmetered | {:error, term} | nil,
        webhooks:  {:ok, non_neg_integer} | :unmetered | {:error, term} | nil
      }

  `compose/0` (or `compose(%{})`) yields the all-`"unmetered"` envelope — the
  honest shape for a still-provisioning or wholly-unreachable box, where the
  control-plane meters (seats) still return.
  """

  # Source labels — each NAMES where the number does (or would) come from, so a
  # degraded meter still tells the operator which pipe went quiet.
  @src_documents "instance.documents"
  @src_datasets "instance.datasets"
  # The webhook pipe is DATASET-SCOPED — the router counts the instance's
  # `production` dataset list (the same default-dataset view the C5 webhook
  # panel manages). The label says so: a multi-dataset instance's operator is
  # never shown a production-only count posing as a whole-box total. C11's
  # catalog rows are the path to a cross-dataset truth.
  @src_webhooks "instance.webhooks.production"
  @src_db_size "telemetry.pg_size_bytes"
  @src_disk "telemetry.disk_used_percent"
  @src_seats "control-plane.team_members"
  # The flow meters have no source yet — the label is the honest "not built".
  @src_not_metered "not-metered"

  @unmetered "unmetered"

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
        seats: seats_meter(Map.get(inputs, :seats), Map.get(inputs, :pending_invitations)),
        # FLOW meters — always unmetered, whatever anyone passes (D31).
        api_requests: meter(@unmetered, @src_not_metered, nil),
        bandwidth: meter(@unmetered, @src_not_metered, nil)
      }
    }
  end

  # ── Meter builders ──────────────────────────────────────────────────────────

  # An instance inventory count: a landed `{:ok, n}` is the number; a failure,
  # an explicit `:unmetered`, or an absent input all degrade to "unmetered" with
  # the source still named (never a fake zero on an unreachable box).
  defp instance_meter({:ok, n}, source) when is_integer(n) and n >= 0,
    do: meter(n, source, nil)

  defp instance_meter(_other, source), do: meter(@unmetered, source, nil)

  # DB size in bytes, from the agent's latest health beat. Absent telemetry or a
  # non-number → unmetered (with the telemetry event's snapshot time when we have
  # one, so the GUI can still say "as of …" even on a degraded read).
  defp db_size_meter(telemetry, measured_at) do
    case telemetry && Map.get(telemetry, :db_size) do
      n when is_number(n) -> meter(n, @src_db_size, measured_at)
      _ -> meter(@unmetered, @src_db_size, measured_at)
    end
  end

  # Disk used-percent, from the health beat. The agent passes `-1` verbatim when
  # the probe was never wired (Telemetry moduledoc: sentinel interpretation is a
  # view concern) — treat a negative / non-number as "not measured", never a
  # fake 0% that reads as an empty disk.
  defp disk_meter(telemetry, measured_at) do
    case telemetry && get_in(telemetry, [:disk, :used_pct]) do
      n when is_number(n) and n >= 0 -> meter(n, @src_disk, measured_at)
      _ -> meter(@unmetered, @src_disk, measured_at)
    end
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

  # The uniform meter shape. `quota`/`warn_at` are always nil in v1 (display
  # precedes enforcement, D48).
  defp meter(value, source, measured_at) do
    %{value: value, quota: nil, warn_at: nil, source: source, measured_at: measured_at}
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
end
