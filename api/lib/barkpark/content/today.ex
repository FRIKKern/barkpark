defmodule Barkpark.Content.Today do
  @moduledoc """
  The `"$today"` token (task-f78a513602faee55): Sanity's
  `initialValue: () => new Date()` and a desk filter's `now()`, as data.

  Only the exact string `"$today"` is the token. `"$todayx"`, `" $today"`, a
  longer string holding it, or another `$name` stay literal text.

  In `initial_values` (a create), the declared field's type decides:

    * `date` → today's date, `YYYY-MM-DD`, in the workspace time zone
    * `datetime` → the current instant, ISO 8601 UTC with milliseconds
      (`2026-11-20T16:05:28.610Z`), as `new Date()` stores it
    * any other declared type (a string, a text) → the literal `"$today"`
    * a key the schema does not declare → today's date, as before this
      module: the type cannot be known, and that was the old answer

  `"$today.year"` stays the 4-digit year, on any field, in the same zone.

  In a desk list's filter (`{"content.sluttdato": {"gte": "$today"}}`) the
  token is today's date in the workspace time zone; on a `datetime` field it
  is the instant today began there, ISO UTC. Filters compare as text, so a
  document with no value matches neither `gte` nor `lt`, as GROQ's
  comparison with null is false.

  The zone is the workspace's `settings["time_zone"]`
  (`Barkpark.Tenancy.workspace_time_zone/1`). No zone, or a name the zone
  database does not know, is UTC. Values with no token come back unchanged,
  and no workspace is read for them.
  """

  alias Barkpark.Tenancy

  @token "$today"
  @year_token "$today.year"
  @tzdb Tz.TimeZoneDatabase

  @typedoc "When and where today is: a UTC instant and an IANA zone."
  @type clock :: %{now: DateTime.t(), zone: String.t()}

  @doc """
  The clock for a workspace: its zone, and `opts[:now]` (tests) or now.
  Pass it as a 0-arity function to the resolvers so the workspace is read
  only when a value holds the token.
  """
  @spec clock(String.t() | nil, keyword()) :: clock()
  def clock(workspace_id, opts \\ []) do
    zone =
      workspace_id
      |> Tenancy.get_workspace_by_id()
      |> Tenancy.workspace_time_zone()

    %{now: Keyword.get(opts, :now) || DateTime.utc_now(), zone: zone || "Etc/UTC"}
  end

  @doc "True when `term` holds the exact `\"$today\"` or `\"$today.year\"` anywhere."
  @spec token?(term()) :: boolean()
  def token?(@token), do: true
  def token?(@year_token), do: true
  def token?(%{} = map), do: Enum.any?(map, fn {_k, v} -> token?(v) end)
  def token?(list) when is_list(list), do: Enum.any?(list, &token?/1)
  def token?(_other), do: false

  @doc "Today's date in the clock's zone, `YYYY-MM-DD`."
  @spec date(clock()) :: String.t()
  def date(clock), do: clock |> local_date() |> Date.to_iso8601()

  @doc "The clock's instant, ISO 8601 UTC with milliseconds."
  @spec instant(clock()) :: String.t()
  def instant(%{now: now}) do
    %{microsecond: {us, _}} = utc = DateTime.shift_zone!(now, "Etc/UTC")
    DateTime.to_iso8601(%{utc | microsecond: {div(us, 1000) * 1000, 3}})
  end

  @doc "The instant today began in the clock's zone, ISO 8601 UTC with milliseconds."
  @spec start_of_day(clock()) :: String.t()
  def start_of_day(%{zone: zone} = clock) do
    date = local_date(clock)

    midnight =
      case DateTime.new(date, ~T[00:00:00], zone, @tzdb) do
        {:ok, dt} -> dt
        # A zone that skips midnight starts the day at the first instant after.
        {:gap, _before, after_gap} -> after_gap
        {:ambiguous, first, _second} -> first
        {:error, _} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      end

    instant(%{clock | now: midnight})
  end

  @doc """
  `initial_values` with every token resolved by its field's type (see the
  moduledoc). `fields` is the schema's field list; `clock` a clock or a
  0-arity function returning one.
  """
  @spec resolve_initial(term(), list() | nil, clock() | (-> clock())) :: term()
  def resolve_initial(values, fields, clock) do
    if token?(values), do: initial(values, fields, force(clock)), else: values
  end

  defp initial(%{} = map, fields, clock) do
    Map.new(map, fn {k, v} ->
      field = find_field(fields, k)
      {k, initial_value(v, field, clock)}
    end)
  end

  defp initial(other, _fields, clock), do: initial_value(other, nil, clock)

  defp initial_value(@token, field, clock) do
    case field_type(field) do
      "date" -> date(clock)
      "datetime" -> instant(clock)
      nil -> date(clock)
      _declared_other -> @token
    end
  end

  defp initial_value(@year_token, _field, clock),
    do: clock |> local_date() |> Map.fetch!(:year) |> Integer.to_string()

  defp initial_value(%{} = map, field, clock), do: initial(map, subfields(field), clock)

  defp initial_value(list, _field, clock) when is_list(list),
    do: Enum.map(list, &initial_value(&1, nil, clock))

  defp initial_value(other, _field, _clock), do: other

  @doc """
  A query-API filter map (`{path => {op => value}}`, plus `"$or"` groups) with
  each `"$today"` operand resolved for the field it compares. `fields` is the
  filtered type's field list; a path may carry the `content.` prefix.
  """
  @spec resolve_filter(term(), list() | nil, clock() | (-> clock())) :: term()
  def resolve_filter(%{} = filter, fields, clock) do
    if token?(filter), do: filter_map(filter, fields, force(clock)), else: filter
  end

  def resolve_filter(other, _fields, _clock), do: other

  defp filter_map(filter, fields, clock) do
    Map.new(filter, fn
      {"$or", branches} when is_list(branches) ->
        {"$or", Enum.map(branches, &if(is_map(&1), do: filter_map(&1, fields, clock), else: &1))}

      {path, %{} = ops} when is_binary(path) ->
        type = path |> String.replace_prefix("content.", "") |> path_field(fields) |> field_type()
        {path, Map.new(ops, fn {op, v} -> {op, filter_operand(v, type, clock)} end)}

      pair ->
        pair
    end)
  end

  defp filter_operand(@token, "datetime", clock), do: start_of_day(clock)
  defp filter_operand(@token, _type, clock), do: date(clock)
  defp filter_operand(other, _type, _clock), do: other

  defp local_date(%{now: now, zone: zone}) do
    case DateTime.shift_zone(now, zone, @tzdb) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _} -> now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
    end
  end

  defp force(fun) when is_function(fun, 0), do: fun.()
  defp force(%{} = clock), do: clock

  defp path_field(path, fields) do
    case String.split(path, ".") do
      [name] -> find_field(fields, name)
      [name | rest] -> path_field(Enum.join(rest, "."), subfields(find_field(fields, name)))
    end
  end

  defp find_field(fields, name) when is_list(fields),
    do: Enum.find(fields, &(is_map(&1) and attr(&1, :name) == name))

  defp find_field(_fields, _name), do: nil

  defp subfields(%{} = field) do
    case attr(field, :fields) do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp subfields(_field), do: nil

  defp field_type(%{} = field), do: attr(field, :type)
  defp field_type(_field), do: nil

  defp attr(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
