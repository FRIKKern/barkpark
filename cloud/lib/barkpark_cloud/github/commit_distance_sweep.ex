defmodule BarkparkCloud.GitHub.CommitDistanceSweep do
  @moduledoc """
  Tick-scoped budget + accounting for the commit-distance arm of
  `BarkparkCloud.Workers.UpdateStatusWorker` (deploy-reliability W21 backlog).

  ## The problem this exists for

  The sweep grades EVERY update-checkable box with one unauthenticated
  `GET /repos/<repo>/compare/<served>...main`. The anonymous GitHub budget is
  **60 requests/hour per SOURCE IP**, shared with anything else calling
  `api.github.com` from the control-plane egress address. At six boxes that is
  6/60. Past ~60 boxes — or with any other caller on that IP — the tail of the
  sweep takes 403s, every 403 lands `commit_ancestry: "unknown"` /
  `commit_distance: NULL`, and the verdict SILENTLY stops existing for the rest
  of the fleet. Fail-closed and honest per row; invisible in aggregate.

  Two mechanisms, both tick-scoped:

    1. **Per-sha memoization.** The compare answer for a sha is a pure function
       of that sha within one tick, and fleets converge on a handful of distinct
       shas (six live boxes today sit on five). N boxes on one `git_commit`
       therefore cost **ONE** compare call, not N. The memo is keyed on the
       request URL — which already encodes repo, served sha and branch — so it
       can never confuse two different comparisons.

    2. **Bucketed accounting + a summary the tick actually says out loud.**
       Every box lands in exactly one bucket and the tick logs the tally and
       emits `[:barkpark_cloud, :commit_distance, :sweep]` telemetry. The
       unmeasured reasons are kept **DISTINCT** — `no_sha` (the agent is
       offline, no HTTP was ever issued) is never folded into `rate_limited`
       (the budget refused us) and neither is folded into `unreachable`
       (transport failure / egress blocked). That distinction is the whole
       diagnostic: a blocked egress and an exhausted budget both read
       "every row unknown" on the fleet surface and are told apart ONLY here.

  ## Buckets

  | bucket                        | cause                                                  |
  |-------------------------------|--------------------------------------------------------|
  | `measured`                    | a real rung (`current` / `behind` / `ahead_of_main` / `diverged`) |
  | `unmeasured_no_sha`           | `git_commit` NULL or blank — no call was made           |
  | `unmeasured_rate_limited`     | HTTP 403 (the shared 60/h budget), plus every box skipped by the halt |
  | `unmeasured_unknown_commit`   | HTTP 404 — GitHub has never seen that sha               |
  | `unmeasured_unreachable`      | transport error, unconfigured client, or any other non-200 |
  | `unmeasured_unusable_body`    | HTTP 200 whose body did not decode into a known status  |
  | `unmeasured_write_failed`     | the verdict was computed but the row write was rejected |

  ## The halt

  `x-ratelimit-remaining` is NOT readable here: the injected transport
  (`BarkparkCloud.Billing.HttpClient.request/1`) returns only `%{status, body}`
  and DISCARDS response headers, so there is no budget gauge to steer by and
  widening that shared transport is not this slice's job. What IS available is
  the refusal itself: the anonymous budget resets on the hour, so once a tick
  has taken one 403 the rest of that tick is refused too. After the first 403
  the sweep therefore stops issuing compares and counts every remaining box
  under `unmeasured_rate_limited` (also reported separately as
  `skipped_after_rate_limit`). Skipped boxes are NOT written: their existing
  verdict and its `commit_distance_checked_at` stay as they were, rather than
  being overwritten with `unknown` and a fresh timestamp that would claim we
  measured. Pass `stop_after_rate_limit: false` to grade every box anyway.

  ## Lifetime

  `new/1` opens a `:private` ETS table owned by the calling process (one Oban
  job process per tick); `close/1` deletes it. The struct is a handle, all
  mutable state lives in the table, and the memoizing client is a plain
  1-arity fun handed to `Registry.refresh_commit_distance/2` via
  `client_opts/1` — so nothing outside this module has to know a memo exists.
  """

  require Logger

  alias BarkparkCloud.GitHub.CommitDistance

  @telemetry_event [:barkpark_cloud, :commit_distance, :sweep]

  @buckets ~w(
    measured
    unmeasured_no_sha
    unmeasured_rate_limited
    unmeasured_unknown_commit
    unmeasured_unreachable
    unmeasured_unusable_body
    unmeasured_write_failed
  )a

  @counters @buckets ++ ~w(boxes compare_calls memo_hits skipped_after_rate_limit)a

  defstruct [:table, :inner, :stop_after_rate_limit]

  @type t :: %__MODULE__{}

  @doc """
  The bucket names, in report order. `measured` first; every other bucket is a
  DISTINCT unmeasured reason and none of them collapse into one another.
  """
  @spec buckets() :: [atom()]
  def buckets, do: @buckets

  @doc "The telemetry event this sweep emits once per tick."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Open a tick-scoped sweep. `opts` are forwarded to
  `CommitDistance.resolve_client/1`, so a test's injected client is wrapped, not
  bypassed. `:stop_after_rate_limit` (default `true`) controls the halt.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    table = :ets.new(:commit_distance_sweep, [:set, :private])
    Enum.each(@counters, &:ets.insert(table, {&1, 0}))

    %__MODULE__{
      table: table,
      inner: CommitDistance.resolve_client(opts),
      stop_after_rate_limit: Keyword.get(opts, :stop_after_rate_limit, true)
    }
  end

  @doc """
  Options to hand `Registry.refresh_commit_distance/2` (and therefore
  `CommitDistance.verdict/2`): the memoizing client for THIS tick.
  """
  @spec client_opts(t()) :: keyword()
  def client_opts(%__MODULE__{} = sweep), do: [http_client: memoizing_client(sweep)]

  @doc """
  Has this tick already been refused by the budget (and is the halt armed)?
  When true the caller must `skip/1` the box instead of grading it.
  """
  @spec halted?(t()) :: boolean()
  def halted?(%__MODULE__{stop_after_rate_limit: false}), do: false

  def halted?(%__MODULE__{table: table}) do
    case :ets.lookup(table, :rate_limited_seen) do
      [{_, true}] -> true
      _ -> false
    end
  end

  @doc """
  Record a box the halt skipped: counted as boxes + `unmeasured_rate_limited` +
  `skipped_after_rate_limit`, and NOT written.
  """
  @spec skip(t()) :: :ok
  def skip(%__MODULE__{table: table}) do
    bump(table, :boxes)
    bump(table, :unmeasured_rate_limited)
    bump(table, :skipped_after_rate_limit)
    :ok
  end

  @doc """
  Record the outcome of grading one box.

  `result` is whatever `Registry.refresh_commit_distance/2` returned. The
  unmeasured REASON is not recoverable from the verdict (every failure returns
  the same `"unknown"` rung), so it is read back from the transport result this
  sweep's own memoizing client recorded for that sha's compare URL.
  """
  @spec observe(t(), String.t() | nil, term()) :: :ok
  def observe(%__MODULE__{table: table} = sweep, served_sha, result) do
    bump(table, :boxes)
    bump(table, bucket(sweep, served_sha, result))
    :ok
  end

  @doc "The tick's counters, as a flat map."
  @spec tally(t()) :: %{atom() => non_neg_integer()}
  def tally(%__MODULE__{table: table}) do
    Map.new(@counters, fn key ->
      {key, :ets.lookup_element(table, key, 2)}
    end)
  end

  @doc """
  Say the tick out loud: one Logger line plus the telemetry event. This is the
  counter the row asked for — a sweep that measured nothing now reports WHY,
  per distinct reason, instead of going silent.
  """
  @spec report(t()) :: %{atom() => non_neg_integer()}
  def report(%__MODULE__{} = sweep) do
    counts = tally(sweep)
    unmeasured = counts.boxes - counts.measured

    Logger.info(
      "CommitDistance sweep: #{counts.boxes} boxes, #{counts.measured} measured, " <>
        "#{unmeasured} UNMEASURED (" <>
        reasons(counts) <>
        ") — " <>
        "#{counts.compare_calls} compare calls, #{counts.memo_hits} memo hits, " <>
        "#{counts.skipped_after_rate_limit} skipped after a rate-limit refusal"
    )

    :telemetry.execute(@telemetry_event, counts, %{unmeasured: unmeasured})

    counts
  end

  @doc "Close the tick and return its final tally."
  @spec close(t()) :: %{atom() => non_neg_integer()}
  def close(%__MODULE__{table: table} = sweep) do
    counts = tally(sweep)
    :ets.delete(table)
    counts
  end

  # ── internals ──

  defp reasons(counts) do
    @buckets
    |> Enum.reject(&(&1 == :measured))
    |> Enum.map_join(", ", fn bucket ->
      "#{bucket |> Atom.to_string() |> String.replace_prefix("unmeasured_", "")}=#{counts[bucket]}"
    end)
  end

  defp memoizing_client(%__MODULE__{table: table, inner: inner}) do
    fn request ->
      url = Map.get(request, :url)

      case :ets.lookup(table, {:memo, url}) do
        [{_, cached}] ->
          bump(table, :memo_hits)
          cached

        [] ->
          result = CommitDistance.invoke(inner, request)
          reason = reason_of(result)

          :ets.insert(table, {{:memo, url}, result})
          :ets.insert(table, {{:reason, url}, reason})
          bump(table, :compare_calls)

          if reason == :rate_limited, do: :ets.insert(table, {:rate_limited_seen, true})

          result
      end
    end
  end

  # No sha means no call was ever issued — it is NEVER a budget refusal.
  defp bucket(_sweep, sha, _result) when not is_binary(sha), do: :unmeasured_no_sha

  defp bucket(sweep, sha, result) do
    case String.trim(sha) do
      "" -> :unmeasured_no_sha
      trimmed -> graded_bucket(sweep, trimmed, result)
    end
  end

  defp graded_bucket(_sweep, _sha, {:error, _changeset}), do: :unmeasured_write_failed

  defp graded_bucket(_sweep, _sha, {:ok, %{commit_ancestry: ancestry}})
       when is_binary(ancestry) and ancestry != "unknown",
       do: :measured

  defp graded_bucket(sweep, sha, _result) do
    case recorded_reason(sweep, sha) do
      :rate_limited -> :unmeasured_rate_limited
      :unknown_commit -> :unmeasured_unknown_commit
      :ok -> :unmeasured_unusable_body
      _ -> :unmeasured_unreachable
    end
  end

  defp recorded_reason(%__MODULE__{table: table}, sha) do
    url = CommitDistance.compare_url(sha)

    case :ets.lookup(table, {:reason, url}) do
      [{_, reason}] -> reason
      [] -> :no_result
    end
  end

  defp reason_of({:ok, %{status: 200}}), do: :ok
  defp reason_of({:ok, %{status: 403}}), do: :rate_limited
  defp reason_of({:ok, %{status: 404}}), do: :unknown_commit
  defp reason_of(_), do: :unreachable

  defp bump(table, key), do: :ets.update_counter(table, key, {2, 1}, {key, 0})
end
