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
        backup: %{ok: boolean | nil, detail: String.t() | nil},
        checks: %{pass: non_neg_integer, total: non_neg_integer, failing: [String.t()]},
        dirty_tree: boolean | nil,
        reported_at: String.t() | nil   # event inserted_at, RFC3339
      }

  The agent-side field contract (verified in `internal/agent/report.go` +
  `internal/cli/setup/healthgate.go`): `disk_used_percent` (int, `-1` when the
  probe was not wired — passed through verbatim; sentinel interpretation is a
  view concern, not the normalizer's), `pg_size_bytes` (int64), `backup_ok`
  (bool) + `backup_detail` (string), `dirty_tree` (bool), and `health_checks`
  (a list of `%{"name","pass","detail"}` `CheckResult`s — note the boolean key
  is `"pass"`, with `"ok"` accepted as a defensive alias).

  Payloads arrive from jsonb with STRING keys (Jason-decoded), which is what
  this module reads. `reported_at` is not in the payload — it is the event's
  own `inserted_at`, so pass a full `%AgentEvent{}` to stamp it; a bare payload
  map normalizes with `reported_at: nil`.
  """

  alias BarkparkCloud.Registry.AgentEvent

  @empty_checks %{pass: 0, total: 0, failing: []}

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

  # Roll the health-gate array up to {pass, total, failing}. A non-list (absent
  # / malformed) yields the zero roll-up — never nil arithmetic downstream.
  defp summarize_checks(checks) when is_list(checks) do
    {pass, failing} =
      Enum.reduce(checks, {0, []}, fn check, {pass, failing} ->
        if check_passed?(check) do
          {pass + 1, failing}
        else
          {pass, [check_name(check) | failing]}
        end
      end)

    %{pass: pass, total: length(checks), failing: Enum.reverse(failing)}
  end

  defp summarize_checks(_), do: @empty_checks

  # A check counts as passing ONLY when its boolean is literally true. The
  # struct's JSON key is "pass" and it is AUTHORITATIVE when present as a
  # boolean; "ok" is a defensive alias consulted only when "pass" is absent or
  # non-boolean — an alias must never overrule an explicit `"pass" => false`.
  # Any non-boolean / missing value → not passing (fail closed).
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
