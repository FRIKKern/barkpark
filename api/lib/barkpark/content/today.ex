defmodule Barkpark.Content.Today do
  @moduledoc """
  The `"$today"` token (task-f78a513602faee55): Sanity's
  `initialValue: () => new Date()` and a desk filter's `now()`, as data.

  Only the exact string `"$today"` is the token; `"$todayx"`, `" $today"`, a
  longer string holding it, or another `$name` stay literal text.

    * `"$today"` → today's date, `YYYY-MM-DD`, on any field
    * `"$today.year"` → today's year as a 4-digit string

  "Today" is the date in the workspace's time zone
  (`Barkpark.Tenancy.workspace_time_zone/1`, e.g. `Europe/Oslo`). A workspace
  with no zone, or a name the zone database does not know, reads UTC: the
  answer Barkpark gave before workspaces had a zone.

  Where it resolves: a schema's `initial_values` on create (`Content.Writer`,
  the LiveView new document), and a query filter's operand
  (`{"content.sluttdato": {"gte": "$today"}}`) on every read through
  `Content.Query`, per request. A desk list's filter is therefore stored and
  served as written, and each list read compares with that moment's date.
  Values with no token come back unchanged, and no workspace is read for them.
  """

  alias Barkpark.Tenancy

  @token "$today"
  @year_token "$today.year"
  @tzdb Tz.TimeZoneDatabase

  @typedoc "When and where today is: a UTC instant and an IANA zone."
  @type clock :: %{now: DateTime.t(), zone: String.t()}

  @doc """
  The clock for a workspace: its zone, and `opts[:now]` (tests) or now.
  Pass it to the resolvers as a 0-arity function, so the workspace is read
  only when a value holds the token.
  """
  @spec clock(String.t() | nil, keyword()) :: clock()
  def clock(workspace_id, opts \\ []),
    do: %{now: Keyword.get(opts, :now) || DateTime.utc_now(), zone: zone(workspace_id)}

  @doc "`clock/2` for the first id that is set, as a 0-arity function (read only if needed)."
  @spec later([String.t() | nil], keyword()) :: (-> clock())
  def later(workspace_ids, opts), do: fn -> clock(Enum.find(workspace_ids, & &1), opts) end

  @doc "A query filter map with its tokens resolved in the caller's (`opts[:workspace_id]`) zone."
  @spec in_filter(map(), keyword()) :: map()
  def in_filter(filter_map, opts),
    do: resolve(filter_map, later([Keyword.get(opts, :workspace_id)], opts))

  @doc false
  # The UTC-only resolver Content.Writer had before workspaces had a zone; kept
  # for its callers (`Content.resolve_dynamics/1`).
  def resolve_dynamics(term), do: resolve(term, %{now: DateTime.utc_now(), zone: "Etc/UTC"})

  # One workspace read per request: a list read runs its page, count and facet
  # queries one after another, each resolving the same filter. So the zone is
  # kept in the calling process for a second; a changed zone shows after that.
  @memo_ms 1_000
  defp zone(nil), do: "Etc/UTC"

  defp zone(workspace_id) do
    key = {__MODULE__, workspace_id}
    now = System.monotonic_time(:millisecond)

    case Process.get(key) do
      {zone, at} when now - at < @memo_ms ->
        zone

      _ ->
        zone = Tenancy.workspace_time_zone(Tenancy.get_workspace_by_id(workspace_id)) || "Etc/UTC"
        Process.put(key, {zone, now})
        zone
    end
  end

  @doc "True when `term` holds the exact `\"$today\"` or `\"$today.year\"` anywhere."
  @spec token?(term()) :: boolean()
  def token?(@token), do: true
  def token?(@year_token), do: true
  def token?(%{} = map), do: Enum.any?(map, fn {_k, v} -> token?(v) end)
  def token?(list) when is_list(list), do: Enum.any?(list, &token?/1)
  def token?(_other), do: false

  @doc """
  Today's date in the clock's zone, `YYYY-MM-DD`. A zone the database does
  not know reads UTC; this never raises.
  """
  @spec date(clock()) :: String.t()
  def date(clock), do: clock |> local_date() |> Date.to_iso8601()

  defp local_date(%{now: now, zone: zone}) do
    case DateTime.shift_zone(now, zone, @tzdb) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _} -> now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
    end
  end

  @doc """
  `term` with every token resolved, at any depth. `clock` is a clock or a
  0-arity function returning one, called only when a token is there.
  """
  @spec resolve(term(), clock() | (-> clock())) :: term()
  def resolve(term, clock) do
    if token?(term), do: walk(term, force(clock)), else: term
  end

  defp walk(@token, clock), do: date(clock)
  defp walk(@year_token, clock), do: Integer.to_string(local_date(clock).year)
  defp walk(%{} = map, clock), do: Map.new(map, fn {k, v} -> {k, walk(v, clock)} end)
  defp walk(list, clock) when is_list(list), do: Enum.map(list, &walk(&1, clock))
  defp walk(other, _clock), do: other

  defp force(fun) when is_function(fun, 0), do: fun.()
  defp force(%{} = clock), do: clock
end
