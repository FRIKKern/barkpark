defmodule Barkpark.Content.Validation.Rules do
  @moduledoc """
  Compiler + runtime cache for cross-field validation rules.

  ## Compilation

  `compile/1` takes the JSON shape declared in `docs/plugins/SCHEMA_V2.md`:

      %{
        "name" => "isbn-required",
        "severity" => "error",
        "message" => "ISBN must be present for epub format",
        "tags" => ["mutate", "export"],
        "when" => %{"path" => "/format", "op" => "eq", "value" => "epub"},
        "then" => %{"path" => "/isbn", "op" => "nonempty"}
      }

  …and returns `{:ok, %Barkpark.Content.Validation.Rule{}}` or
  `{:error, reason}`. Op strings are mapped to atoms (`"containsAll"` →
  `:contains_all`, `"matches:isbn13"` → `{:matches, "isbn13"}`); tags
  fold into a `MapSet`. **No `Code.eval_*`** — rule values are inert
  data the evaluator interprets at run time (decision D7).

  ## Cache

  A single GenServer-backed map keyed by `schema_id` holds the compiled
  rule list per schema. ETS was rejected here in favour of a guarded
  map because (a) the cache is tiny (~tens of schemas × tens of rules),
  (b) writes are extremely rare (only when a `schema_definitions` row
  changes), and (c) keeping all mutation funneled through the GenServer
  guarantees consistent ordering with future PubSub-driven invalidation
  without introducing read/write races. The hot path
  (`Evaluator.run/3`) is a single GenServer.call returning a list — the
  call cost is negligible against 100+ rule evaluations per pass.

  Tests populate the cache with `put/2`. A stub
  `reload_all/0` rebuilds the cache from the `schema_definitions`
  table; until WI2 promotes the `validations` slot to a first-class
  column, `reload_all/0` is a no-op for legacy v1 schemas.
  """

  use GenServer
  require Logger

  alias Barkpark.Content.Validation.Rule
  alias Barkpark.Content.Validation.Rule.Expr

  @name __MODULE__

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec for_schema(any()) :: [Rule.t()]
  def for_schema(schema_id) do
    GenServer.call(@name, {:for_schema, schema_id})
  end

  @spec put(any(), [Rule.t()]) :: :ok
  def put(schema_id, rules) when is_list(rules) do
    GenServer.call(@name, {:put, schema_id, rules})
  end

  @spec invalidate(any()) :: :ok
  def invalidate(schema_id) do
    GenServer.call(@name, {:invalidate, schema_id})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(@name, :clear)

  @spec reload_all() :: :ok
  def reload_all, do: GenServer.call(@name, :reload_all, 60_000)

  # ── Compiler ────────────────────────────────────────────────────────────

  @doc """
  Compile a single rule JSON map into a `%Rule{}` struct.
  """
  @spec compile(map()) :: {:ok, Rule.t()} | {:error, term()}
  def compile(rule_json) when is_map(rule_json) do
    j = stringify(rule_json)

    with {:ok, name} <- fetch_string(j, "name"),
         {:ok, severity} <- parse_severity(Map.get(j, "severity", "error")),
         {:ok, when_expr} <- compile_expr(Map.get(j, "when")),
         {:ok, then_expr} <- compile_expr(Map.get(j, "then")) do
      {:ok,
       %Rule{
         name: name,
         severity: severity,
         message: Map.get(j, "message"),
         when: when_expr,
         then: then_expr,
         tags: parse_tags(Map.get(j, "tags"))
       }}
    end
  end

  def compile(_), do: {:error, :rule_must_be_a_map}

  @doc """
  Compile a list of rule JSON maps. Returns `{:ok, [%Rule{}]}` if every
  rule compiles, otherwise `{:error, {index, reason}}`.
  """
  @spec compile_all([map()]) :: {:ok, [Rule.t()]} | {:error, {non_neg_integer(), term()}}
  def compile_all(rules) when is_list(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, idx}, {:ok, acc} ->
      case compile(raw) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, reason} -> {:halt, {:error, {idx, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    auto_load = Keyword.get(opts, :auto_load, true)
    if auto_load, do: send(self(), :reload)
    {:ok, %{schemas: %{}}}
  end

  @impl true
  def handle_call({:for_schema, id}, _from, state) do
    {:reply, Map.get(state.schemas, id, []), state}
  end

  def handle_call({:put, id, rules}, _from, state) do
    {:reply, :ok, %{state | schemas: Map.put(state.schemas, id, rules)}}
  end

  def handle_call({:invalidate, id}, _from, state) do
    {:reply, :ok, %{state | schemas: Map.delete(state.schemas, id)}}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | schemas: %{}}}
  end

  def handle_call(:reload_all, _from, state) do
    {:reply, :ok, %{state | schemas: load_from_db()}}
  end

  @impl true
  def handle_info(:reload, state) do
    new_schemas =
      try do
        load_from_db()
      rescue
        e ->
          Logger.warning("Barkpark.Content.Validation.Rules: deferred load failed: #{inspect(e)}")

          %{}
      end

    {:noreply, %{state | schemas: new_schemas}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── private ─────────────────────────────────────────────────────────────

  # Pull every `schema_definitions` row and compile its `validations`
  # slot. Until the slot is promoted to a column (WI2), the slot is
  # always empty for legacy schemas, so this returns `%{}`. Wrapped in
  # an `if Repo alive?` guard so the function is safe to call from the
  # init `:reload` message even when the supervisor is still wiring up
  # children.
  defp load_from_db do
    repo_pid = Process.whereis(Barkpark.Repo)

    cond do
      is_nil(repo_pid) ->
        %{}

      not Code.ensure_loaded?(Barkpark.Content.SchemaDefinition) ->
        %{}

      true ->
        try do
          rows = Barkpark.Repo.all(Barkpark.Content.SchemaDefinition)

          Enum.reduce(rows, %{}, fn row, acc ->
            case rules_for_row(row) do
              [] -> acc
              rules -> Map.put(acc, row.id, rules)
            end
          end)
        rescue
          _ -> %{}
        end
    end
  end

  defp rules_for_row(row) do
    raw_validations = extract_validations_slot(row)

    case compile_all(raw_validations) do
      {:ok, list} -> list
      {:error, _} -> []
    end
  end

  # The `schema_definitions` Ecto schema only persists `fields` today.
  # Until WI2 lands a column, we look for an embedded `__validations__`
  # marker map on the fields list as an opt-in escape hatch — not part
  # of the public schema contract, but lets WI4's perf bench seed rules
  # via the normal Repo path.
  defp extract_validations_slot(%{fields: fields}) when is_list(fields) do
    Enum.find_value(fields, [], fn entry ->
      case entry do
        %{"__validations__" => list} when is_list(list) -> list
        %{__validations__: list} when is_list(list) -> list
        _ -> false
      end
    end)
  end

  defp extract_validations_slot(_), do: []

  # ── compile helpers ─────────────────────────────────────────────────────

  defp compile_expr(expr) when is_map(expr) do
    s = stringify(expr)

    with {:ok, path} <- fetch_string(s, "path"),
         {:ok, op} <- parse_op(Map.get(s, "op")) do
      {:ok, %Expr{path: path, op: op, value: Map.get(s, "value")}}
    end
  end

  defp compile_expr(_), do: {:error, :missing_expr}

  defp parse_op("eq"), do: {:ok, :eq}
  defp parse_op("in"), do: {:ok, :in}
  defp parse_op("nonempty"), do: {:ok, :nonempty}
  defp parse_op("containsAll"), do: {:ok, :contains_all}
  defp parse_op("contains_all"), do: {:ok, :contains_all}
  defp parse_op("startsWith"), do: {:ok, :starts_with}
  defp parse_op("starts_with"), do: {:ok, :starts_with}

  defp parse_op("matches:" <> rest) when rest != "" do
    {:ok, {:matches, rest}}
  end

  defp parse_op(other), do: {:error, {:unknown_op, other}}

  defp parse_severity("error"), do: {:ok, :error}
  defp parse_severity("warning"), do: {:ok, :warning}
  defp parse_severity("warn"), do: {:ok, :warning}
  defp parse_severity("info"), do: {:ok, :info}
  defp parse_severity(:error), do: {:ok, :error}
  defp parse_severity(:warning), do: {:ok, :warning}
  defp parse_severity(:info), do: {:ok, :info}
  defp parse_severity(other), do: {:error, {:bad_severity, other}}

  defp parse_tags(nil), do: MapSet.new()
  defp parse_tags([]), do: MapSet.new()

  defp parse_tags(list) when is_list(list) do
    list
    |> Enum.map(&tag_to_atom/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp parse_tags(_), do: MapSet.new()

  defp tag_to_atom("live"), do: :live
  defp tag_to_atom("mutate"), do: :mutate
  defp tag_to_atom("export"), do: :export
  defp tag_to_atom(:live), do: :live
  defp tag_to_atom(:mutate), do: :mutate
  defp tag_to_atom(:export), do: :export
  defp tag_to_atom(_), do: nil

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:missing_or_blank, key}}
    end
  end

  defp stringify(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, v}
    end
  end

  defp stringify(other), do: other
end
