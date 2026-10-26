defmodule Barkpark.Groq.Evaluator do
  @moduledoc """
  Evaluates a tree from `Barkpark.Groq.Parser` over a document source.

  Semantics follow the GROQ specification and groq-js, Sanity's reference
  engine: `null` propagates through operators, `==` compares only scalars,
  `order()` uses the specification's total ordering, and `^` skips the hidden
  scopes that mapping over an array creates.

  Documents come from a source, a `{module, state}` pair implementing
  `Barkpark.Groq.Source`. The evaluator asks it for `*` with the constraints
  `Barkpark.Groq.Pushdown` reads off the filter, and for one document per `->`.
  A source may batch: `Barkpark.Groq.DocumentSource` answers from a per-query
  cache and records what it still has to load (see its moduledoc).

  `evaluate/2` must run in a process of its own (the HTTP path uses a Task with
  a timeout), because evaluation keeps per-query caches in the process
  dictionary.
  """

  alias Barkpark.Groq.{Pushdown, Source, Values}

  defmodule EvalError do
    @moduledoc "A query that parses but cannot be evaluated (an unsupported function, a tuple)."
    defexception [:message]
  end

  defstruct [:source, now: nil, identity: nil, project_id: nil, dataset: nil]

  @type t :: %__MODULE__{}

  @doc """
  Evaluates `tree`. Options: `:source` (required), `:now` (`DateTime`, default
  the current time), `:identity`, `:project_id`, `:dataset`.
  """
  @spec evaluate(tuple(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def evaluate(tree, opts) do
    ctx = %__MODULE__{
      source: Keyword.fetch!(opts, :source),
      now: Keyword.get(opts, :now) || DateTime.utc_now(),
      identity: Keyword.get(opts, :identity),
      project_id: Keyword.get(opts, :project_id),
      dataset: Keyword.get(opts, :dataset)
    }

    Process.put(:groq_memo, %{})
    {:ok, tree |> eval(%{value: nil, parent: nil, hidden: false}, ctx) |> Values.to_json()}
  rescue
    e in EvalError -> {:error, e.message}
  end

  # ── Scopes ───────────────────────────────────────────────────────────────

  defp nested(%{hidden: true, parent: parent}, value),
    do: %{value: value, parent: parent, hidden: false}

  defp nested(scope, value), do: %{value: value, parent: scope, hidden: false}

  defp hidden(scope, value), do: %{nested(scope, value) | hidden: true}

  # ── Nodes ────────────────────────────────────────────────────────────────

  @doc false
  def eval({:this}, scope, _ctx), do: scope.value

  # A closed subquery (see Parser.memoize_closed/1) is evaluated once per query.
  def eval({:memo, node}, _scope, ctx) do
    memo = Process.get(:groq_memo, %{})

    case Map.fetch(memo, node) do
      {:ok, value} ->
        value

      :error ->
        value = eval(node, %{value: nil, parent: nil, hidden: false}, ctx)
        Process.put(:groq_memo, Map.put(Process.get(:groq_memo, %{}), node, value))
        value
    end
  end

  def eval({:value, v}, _scope, _ctx), do: v
  def eval({:everything}, _scope, ctx), do: Source.fetch(ctx.source, Pushdown.empty())

  def eval({:parent, n}, scope, _ctx), do: parent_value(scope, n)

  def eval({:group, base}, scope, ctx), do: eval(base, scope, ctx)

  def eval({:attr, base, name}, scope, ctx) do
    case eval_base(base, scope, ctx) do
      %{} = obj -> Map.get(obj, name)
      _ -> nil
    end
  end

  def eval({:elem, base, index}, scope, ctx) do
    with :error <- elem_from_source(base, index, scope, ctx),
         :error <- elem_through_map(base, index, scope, ctx) do
      elem_of(base, index, scope, ctx)
    else
      {:ok, value} -> value
    end
  end

  def eval({:slice, base, left, right, inclusive?}, scope, ctx) do
    with :error <- slice_from_source(base, left, right, inclusive?, scope, ctx),
         :error <- slice_through_map(base, left, right, inclusive?, scope, ctx) do
      case eval(base, scope, ctx) do
        list when is_list(list) -> slice(list, left, right, inclusive?)
        _ -> nil
      end
    else
      {:ok, list} -> list
    end
  end

  def eval({:filter, {:everything}, expr}, scope, ctx) do
    # `^` inside the filter is this scope; the resolver evaluates such values
    # so the source can narrow its read per parent document.
    resolve = fn outer_expr -> eval(outer_expr, nested(scope, nil), ctx) end

    case root?(scope) && fetch_exact(expr, :all, resolve, ctx) do
      {:ok, docs} ->
        docs

      _ ->
        ctx.source
        |> Source.fetch(Pushdown.constraints(expr, resolve))
        |> Enum.filter(fn doc -> eval(expr, nested(scope, doc), ctx) === true end)
    end
  end

  def eval({:filter, base, expr}, scope, ctx) do
    case eval(base, scope, ctx) do
      list when is_list(list) -> Enum.filter(list, &(eval(expr, nested(scope, &1), ctx) === true))
      _ -> nil
    end
  end

  def eval({:projection, base, obj}, scope, ctx) do
    case eval(base, scope, ctx) do
      %{} = value -> eval(obj, nested(scope, value), ctx)
      _ -> nil
    end
  end

  # `->` follows Sanity's `{_ref}` and also Barkpark's own reference shape, a plain id
  # string (post.author = "author-alan", as the studio and the seed write it), so a join
  # over Barkpark-written content resolves instead of answering null
  # (task-b85cf70ca346260a). A string that names no document in the source reads null,
  # as before: `Source.get/2` is the same scoped lookup a `{_ref}` takes.
  def eval({:deref, base}, scope, ctx) do
    case eval(base, scope, ctx) do
      %{"_ref" => id} when is_binary(id) -> Source.get(ctx.source, id)
      id when is_binary(id) and id != "" -> Source.get(ctx.source, id)
      _ -> nil
    end
  end

  def eval({:map, base, expr}, scope, ctx) do
    list =
      case map_from_source(base, expr, scope, ctx) do
        {:ok, docs} -> docs
        :error -> eval(base, scope, ctx)
      end

    case list do
      list when is_list(list) -> Enum.map(list, &eval(expr, hidden(scope, &1), ctx))
      _ -> nil
    end
  end

  def eval({:flat_map, base, expr}, scope, ctx) do
    case eval(base, scope, ctx) do
      list when is_list(list) ->
        Enum.flat_map(list, fn item ->
          case eval(expr, hidden(scope, item), ctx) do
            inner when is_list(inner) -> inner
            inner -> [inner]
          end
        end)

      _ ->
        nil
    end
  end

  def eval({:array_coerce, base}, scope, ctx) do
    case eval(base, scope, ctx) do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  def eval({:object, attrs}, scope, ctx) do
    Enum.reduce(attrs, %{}, fn
      {:attr_value, name, expr}, acc ->
        Map.put(acc, name, eval(expr, scope, ctx))

      {:splat, expr}, acc ->
        case eval(expr, scope, ctx) do
          %{} = obj -> Map.merge(acc, obj)
          _ -> acc
        end

      {:cond_splat, cond_expr, expr}, acc ->
        if eval(cond_expr, scope, ctx) === true do
          case eval(expr, scope, ctx) do
            %{} = obj -> Map.merge(acc, obj)
            _ -> acc
          end
        else
          acc
        end
    end)
  end

  def eval({:array, elems}, scope, ctx) do
    Enum.flat_map(elems, fn
      {expr, true} ->
        case eval(expr, scope, ctx) do
          list when is_list(list) -> list
          _ -> []
        end

      {expr, false} ->
        [eval(expr, scope, ctx)]
    end)
  end

  def eval({:tuple, _}, _scope, _ctx), do: raise(EvalError, "tuples can not be evaluated")

  def eval({:and, l, r}, scope, ctx) do
    case eval(l, scope, ctx) do
      false ->
        false

      left ->
        case eval(r, scope, ctx) do
          false -> false
          right when is_boolean(left) and is_boolean(right) -> true
          _ -> nil
        end
    end
  end

  def eval({:or, l, r}, scope, ctx) do
    case eval(l, scope, ctx) do
      true ->
        true

      left ->
        case eval(r, scope, ctx) do
          true -> true
          right when is_boolean(left) and is_boolean(right) -> false
          _ -> nil
        end
    end
  end

  def eval({:not, base}, scope, ctx) do
    case eval(base, scope, ctx) do
      b when is_boolean(b) -> not b
      _ -> nil
    end
  end

  def eval({:neg, base}, scope, ctx) do
    case eval(base, scope, ctx) do
      n when is_number(n) -> Values.num(-n)
      _ -> nil
    end
  end

  def eval({:pos, base}, scope, ctx) do
    case eval(base, scope, ctx) do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  def eval({kind, _}, _scope, _ctx) when kind in [:asc, :desc], do: nil

  def eval({:select, alts, fallback}, scope, ctx) do
    Enum.find_value(alts, :none, fn {c, v} ->
      if eval(c, scope, ctx) === true, do: {:hit, eval(v, scope, ctx)}
    end)
    |> case do
      {:hit, value} -> value
      :none -> if fallback, do: eval(fallback, scope, ctx), else: nil
    end
  end

  def eval({:in_range, base, l, r, inclusive?}, scope, ctx) do
    value = eval(base, scope, ctx)

    with lc when is_integer(lc) <- Values.partial_compare(value, eval(l, scope, ctx)),
         rc when is_integer(rc) <- Values.partial_compare(value, eval(r, scope, ctx)) do
      if inclusive?, do: lc >= 0 and rc <= 0, else: lc >= 0 and rc < 0
    else
      _ -> nil
    end
  end

  def eval({:op, op, l, r}, scope, ctx), do: op(op, eval(l, scope, ctx), eval(r, scope, ctx))

  def eval({:pipe, base, name, args}, scope, ctx) do
    case eval(base, scope, ctx) do
      list when is_list(list) -> pipe(name, list, args, scope, ctx)
      _ -> nil
    end
  end

  def eval({:func, ns, name, args}, scope, ctx), do: func(ns, name, args, scope, ctx)

  defp elem_of(base, index, scope, ctx) do
    with list when is_list(list) <- eval(base, scope, ctx),
         i when is_integer(i) <- Values.num(index) do
      i = if i < 0, do: i + length(list), else: i
      if i >= 0, do: Enum.at(list, i), else: nil
    else
      _ -> nil
    end
  end

  defp eval_base(nil, scope, _ctx), do: scope.value
  defp eval_base(base, scope, ctx), do: eval(base, scope, ctx)

  defp parent_value(scope, 0), do: scope.value
  defp parent_value(%{parent: nil}, _n), do: nil
  defp parent_value(%{parent: parent}, n), do: parent_value(parent, n - 1)

  defp slice(list, left, right, inclusive?) do
    len = length(list)
    l = if left < 0, do: len + left, else: left
    r = if right < 0, do: len + right, else: right
    r = if inclusive?, do: r + 1, else: r
    l = max(trunc_index(l), 0)
    r = max(trunc_index(r), 0)
    if r > l, do: Enum.slice(list, l, r - l), else: []
  end

  # Array#slice truncates fractional indices toward zero.
  defp trunc_index(n) when is_float(n), do: trunc(n)
  defp trunc_index(n), do: n

  # ── Operators ────────────────────────────────────────────────────────────

  defp op("==", a, b), do: Values.equal?(a, b)
  defp op("!=", a, b), do: not Values.equal?(a, b)
  defp op(">", a, b), do: compare(a, b, &(&1 > 0))
  defp op(">=", a, b), do: compare(a, b, &(&1 >= 0))
  defp op("<", a, b), do: compare(a, b, &(&1 < 0))
  defp op("<=", a, b), do: compare(a, b, &(&1 <= 0))

  defp op("in", {:path, a, _}, {:path, _, regex}), do: Regex.match?(regex, a)

  defp op("in", a, {:path, _, regex}) do
    if is_binary(a), do: Regex.match?(regex, a), else: nil
  end

  defp op("in", a, list) when is_list(list), do: Enum.any?(list, &Values.equal?(a, &1))
  defp op("in", _a, _b), do: nil
  defp op("match", a, b), do: Barkpark.Groq.Match.match?(a, b)
  defp op(arith, a, b), do: Values.arith(arith, a, b)

  defp compare(a, b, pred) do
    case Values.partial_compare(a, b) do
      nil -> nil
      c -> pred.(c)
    end
  end

  # ── Pipe functions ───────────────────────────────────────────────────────

  defp pipe("order", list, args, scope, ctx) do
    specs =
      Enum.map(args, fn
        {:desc, e} -> {e, :desc}
        {:asc, e} -> {e, :asc}
        e -> {e, :asc}
      end)

    list
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      item_scope = nested(scope, item)
      {item, idx, Enum.map(specs, fn {e, dir} -> {eval(e, item_scope, ctx), dir} end)}
    end)
    |> Enum.sort(fn {_, ia, ka}, {_, ib, kb} -> order_le?(ka, kb, ia, ib) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp pipe("score", list, args, scope, ctx) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      item_scope = nested(scope, item)
      base = if is_number(item["_score"]), do: item["_score"], else: 0
      score = Enum.reduce(args, base, fn arg, acc -> acc + score_of(arg, item_scope, ctx) end)
      {Map.put(item, "_score", Values.num(score)), idx}
    end)
    |> Enum.sort(fn {a, ia}, {b, ib} ->
      cond do
        a["_score"] > b["_score"] -> true
        a["_score"] < b["_score"] -> false
        true -> ia <= ib
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp order_le?([], [], ia, ib), do: ia <= ib

  defp order_le?([{a, dir} | ra], [{b, _} | rb], ia, ib) do
    c = Values.total_compare(a, b)
    c = if dir == :desc, do: -c, else: c

    cond do
      c < 0 -> true
      c > 0 -> false
      true -> order_le?(ra, rb, ia, ib)
    end
  end

  defp score_of({:op, "match", l, r}, scope, ctx),
    do: Barkpark.Groq.Match.score(eval(l, scope, ctx), eval(r, scope, ctx))

  defp score_of({:func, "global", "boost", [inner, boost]}, scope, ctx) do
    inner_score = score_of(inner, scope, ctx)

    case eval(boost, scope, ctx) do
      b when is_number(b) and inner_score > 0 -> inner_score + b
      _ -> 0
    end
  end

  defp score_of({:or, l, r}, scope, ctx), do: score_of(l, scope, ctx) + score_of(r, scope, ctx)

  defp score_of({:and, l, r}, scope, ctx) do
    left = score_of(l, scope, ctx)
    right = score_of(r, scope, ctx)
    if left == 0 or right == 0, do: 0, else: left + right
  end

  defp score_of(expr, scope, ctx), do: if(eval(expr, scope, ctx) === true, do: 1, else: 0)

  # ── Functions ────────────────────────────────────────────────────────────

  defp func("global", "coalesce", args, scope, ctx) do
    Enum.reduce_while(args, nil, fn arg, _ ->
      case eval(arg, scope, ctx) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  defp func("global", "count", [arg], scope, ctx) do
    case source_count(arg, scope, ctx) do
      {:ok, n} ->
        n

      :error ->
        case eval(arg, scope, ctx) do
          list when is_list(list) -> length(list)
          _ -> nil
        end
    end
  end

  defp func(ns, "dateTime", [arg], scope, ctx) when ns == "global" do
    case eval(arg, scope, ctx) do
      {:datetime, _} = dt -> dt
      s when is_binary(s) -> Values.parse_datetime(s)
      _ -> nil
    end
  end

  defp func("global", "defined", [arg], scope, ctx), do: eval(arg, scope, ctx) != nil
  defp func("global", "identity", [], _scope, ctx), do: ctx.identity || "anonymous"

  defp func("global", "length", [arg], scope, ctx) do
    case eval(arg, scope, ctx) do
      s when is_binary(s) -> utf16_length(s)
      list when is_list(list) -> length(list)
      _ -> nil
    end
  end

  defp func("global", "path", [arg], scope, ctx) do
    case eval(arg, scope, ctx) do
      s when is_binary(s) -> {:path, s, path_regex(s)}
      _ -> nil
    end
  end

  defp func("global", "string", [arg], scope, ctx) do
    case Values.stringify(eval(arg, scope, ctx)) do
      {:ok, s} -> s
      :error -> nil
    end
  end

  defp func("global", "references", args, scope, ctx) do
    ids =
      args
      |> Enum.flat_map(fn arg ->
        case eval(arg, scope, ctx) do
          s when is_binary(s) -> [s]
          list when is_list(list) -> Enum.filter(list, &is_binary/1)
          _ -> []
        end
      end)

    case ids do
      [] -> false
      _ -> references?(scope.value, MapSet.new(ids))
    end
  end

  defp func("global", "round", [value | prec], scope, ctx) do
    num = eval(value, scope, ctx)
    precision = Enum.map(prec, &eval(&1, scope, ctx))

    case {num, precision} do
      {n, []} when is_number(n) ->
        round_half_away(n, 0)

      {n, [p]} when is_number(n) and is_integer(p) and p >= 0 ->
        round_half_away(n, p)

      {n, [p]} when is_number(n) and is_float(p) and p >= 0 and p == trunc(p) ->
        round_half_away(n, trunc(p))

      _ ->
        nil
    end
  end

  defp func("global", "now", [], _scope, ctx) do
    ctx.now |> DateTime.truncate(:millisecond) |> iso_millis()
  end

  defp func("global", "boost", _args, _scope, _ctx), do: raise(EvalError, "unexpected boost call")

  defp func(ns, "lower", [arg], scope, ctx) when ns in ["global", "string"] do
    case eval(arg, scope, ctx) do
      s when is_binary(s) -> String.downcase(s)
      _ -> nil
    end
  end

  defp func(ns, "upper", [arg], scope, ctx) when ns in ["global", "string"] do
    case eval(arg, scope, ctx) do
      s when is_binary(s) -> String.upcase(s)
      _ -> nil
    end
  end

  defp func("string", "split", [str, sep], scope, ctx) do
    case {eval(str, scope, ctx), eval(sep, scope, ctx)} do
      {"", s} when is_binary(s) -> []
      {s, ""} when is_binary(s) -> String.codepoints(s)
      {s, d} when is_binary(s) and is_binary(d) -> String.split(s, d)
      _ -> nil
    end
  end

  defp func("string", "startsWith", [str, prefix], scope, ctx) do
    case {eval(str, scope, ctx), eval(prefix, scope, ctx)} do
      {s, p} when is_binary(s) and is_binary(p) -> String.starts_with?(s, p)
      _ -> nil
    end
  end

  defp func("array", "join", [arr, sep], scope, ctx) do
    with list when is_list(list) <- eval(arr, scope, ctx),
         s when is_binary(s) <- eval(sep, scope, ctx) do
      Enum.reduce_while(list, {:ok, []}, fn elem, {:ok, acc} ->
        case Values.stringify(elem) do
          {:ok, str} -> {:cont, {:ok, [str | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, parts} -> parts |> Enum.reverse() |> Enum.join(s)
        :error -> nil
      end
    else
      _ -> nil
    end
  end

  defp func("array", "compact", [arr], scope, ctx) do
    case eval(arr, scope, ctx) do
      list when is_list(list) -> Enum.reject(list, &is_nil/1)
      _ -> nil
    end
  end

  defp func("array", "unique", [arr], scope, ctx) do
    case eval(arr, scope, ctx) do
      list when is_list(list) ->
        {out, _} =
          Enum.reduce(list, {[], MapSet.new()}, fn item, {acc, seen} ->
            if is_nil(item) or is_binary(item) or is_number(item) or is_boolean(item) do
              key = if is_number(item), do: {:n, Values.num(item * 1.0)}, else: item

              if MapSet.member?(seen, key),
                do: {acc, seen},
                else: {[item | acc], MapSet.put(seen, key)}
            else
              {[item | acc], seen}
            end
          end)

        Enum.reverse(out)

      _ ->
        nil
    end
  end

  defp func("array", "intersects", [a, b], scope, ctx) do
    case {eval(a, scope, ctx), eval(b, scope, ctx)} do
      {l1, l2} when is_list(l1) and is_list(l2) ->
        Enum.any?(l1, fn x -> Enum.any?(l2, &Values.equal?(x, &1)) end)

      _ ->
        nil
    end
  end

  defp func("math", name, [arr], scope, ctx) when name in ["min", "max", "sum", "avg"] do
    case eval(arr, scope, ctx) do
      list when is_list(list) -> math(name, Enum.reject(list, &is_nil/1))
      _ -> nil
    end
  end

  defp func("dateTime", "now", [], _scope, ctx),
    do: {:datetime, DateTime.truncate(ctx.now, :millisecond)}

  defp func("pt", "text", [arg], scope, ctx),
    do: Barkpark.Groq.PortableText.text(eval(arg, scope, ctx))

  defp func("sanity", "projectId", _args, _scope, ctx), do: ctx.project_id
  defp func("sanity", "dataset", _args, _scope, ctx), do: ctx.dataset

  defp func("sanity", "versionOf", [arg], scope, ctx) do
    with base when is_binary(base) <- eval(arg, scope, ctx),
         %{"_id" => id} when is_binary(id) <- scope.value do
      case String.split(id, ".") do
        _ when id == base -> true
        ["drafts" | rest] when rest != [] -> Enum.join(rest, ".") == base
        ["versions", _release | rest] when rest != [] -> Enum.join(rest, ".") == base
        _ -> false
      end
    else
      _ -> nil
    end
  end

  defp func("sanity", "partOfRelease", [arg], scope, ctx) do
    with release when is_binary(release) <- eval(arg, scope, ctx),
         %{"_id" => id} when is_binary(id) <- scope.value do
      match?(["versions", ^release, _ | _], String.split(id, "."))
    else
      _ -> nil
    end
  end

  # Sanity's `documents::get(ref)` reads the document a global document
  # reference names: an object whose `_ref` is `dataset:<project>.<dataset>:<id>`
  # (task-13790b478beeee4d). It reads like `->` does, so perspective, scope and
  # redaction apply. Only this query's own project and dataset resolve here;
  # another dataset, another project, a bare id or any other value is null.
  defp func("documents", "get", [arg], scope, ctx) do
    with %{"_ref" => "dataset:" <> location} <- eval(arg, scope, ctx),
         [place, id] when id != "" <- String.split(location, ":", parts: 2),
         [project, dataset] <- String.split(place, ".", parts: 2),
         true <- project == ctx.project_id and dataset == ctx.dataset do
      Source.get(ctx.source, id)
    else
      _ -> nil
    end
  end

  defp func("releases", "all", [], _scope, ctx) do
    ctx.source
    |> Source.fetch(%{Pushdown.empty() | types: ["system.release"]})
    |> Enum.filter(&match?(%{"_type" => "system.release"}, &1))
  end

  defp func(ns, name, _args, _scope, _ctx) do
    label = if ns == "global", do: name, else: "#{ns}::#{name}"
    raise EvalError, "the function #{label}() is not supported by this endpoint"
  end

  # groq-js skips nulls, answers null for any other non-number, and gives
  # sum([]) = 0 but min/max/avg([]) = null.
  defp math(name, list) do
    cond do
      not Enum.all?(list, &is_number/1) -> nil
      list == [] and name == "sum" -> 0
      list == [] -> nil
      name == "min" -> Values.num(Enum.min(list))
      name == "max" -> Values.num(Enum.max(list))
      name == "sum" -> Values.num(Enum.sum(list))
      name == "avg" -> Values.num(Enum.sum(list) / length(list))
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # groq-js counts code points (UTF-16 units minus high surrogates).
  defp utf16_length(s), do: s |> String.to_charlist() |> length()

  # Precision 0 rounds half away from zero, as groq-js does with
  # `-Math.round(-n)` for negatives; other precisions follow `toFixed`.
  defp round_half_away(n, 0) when is_integer(n), do: n
  defp round_half_away(n, 0), do: Values.num(Float.round(n * 1.0))
  defp round_half_away(n, p) when is_integer(n) and p >= 0, do: n
  defp round_half_away(n, p), do: Values.num(Float.round(n * 1.0, min(p, 15)))

  defp iso_millis(dt) do
    {micro, _} = dt.microsecond
    millis = div(micro, 1000)

    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <>
      "." <> String.pad_leading(Integer.to_string(millis), 3, "0") <> "Z"
  end

  defp path_regex(pattern) do
    body =
      pattern
      |> String.split(".")
      |> Enum.map_join("\\.", fn
        "*" -> "[^.]+"
        "**" -> ".*"
        part -> Regex.escape(part)
      end)

    Regex.compile!("^" <> body <> "$", "u")
  end

  # `count(*[...])` whose filter SQL matches exactly is counted by the source,
  # without loading the documents. Any other filter is counted by a scan that
  # holds one chunk of documents at a time, so the per-fetch limits, which
  # protect memory, do not apply to it. A closed subquery (`{:memo, _}`) gives
  # the same count in every scope, so the source may keep its result.
  defp source_count({:memo, inner}, scope, ctx), do: source_count(inner, scope, ctx, inner)
  defp source_count(arg, scope, ctx), do: source_count(arg, scope, ctx, nil)

  defp source_count({:filter, {:everything}, expr}, scope, ctx, cache) do
    resolve = fn outer_expr -> eval(outer_expr, nested(scope, nil), ctx) end

    with :error <- exact_count(expr, resolve, ctx) do
      Source.scan_count(ctx.source, Pushdown.constraints(expr, resolve), cache, fn doc ->
        kept = eval(expr, nested(scope, doc), ctx) === true
        # references?/2 caches per document; a scanned one is not seen again.
        Process.delete({:groq_refs, doc["_id"]})
        kept
      end)
    end
  end

  defp source_count(_arg, _scope, _ctx, _cache), do: :error

  defp exact_count(expr, resolve, ctx) do
    case Pushdown.exact(expr, resolve) do
      {:ok, constraints} -> Source.count(ctx.source, constraints)
      :error -> :error
    end
  end

  # A `*[...]` whose filter SQL matches exactly (`Pushdown.exact/2`) is read
  # by the source alone, and its documents are kept without testing the
  # filter again. As for a slice, only a `*[...]` that gives the same
  # documents in every scope qualifies, so the read happens once per query.
  # Mapped over by a projection of plain keys (`{a, "b": c}`) or one key
  # (`.a`), it needs only those keys of each document. The memo is skipped
  # then, because another use of the same subquery may read other keys.
  defp root?(scope), do: scope.value == nil and scope.parent == nil

  defp fetch_exact(expr, fields, resolve, ctx) do
    case Pushdown.exact(expr, resolve) do
      {:ok, constraints} -> Source.fetch_exact(ctx.source, constraints, fields)
      :error -> :error
    end
  end

  defp map_from_source({:memo, {:filter, {:everything}, _expr} = inner}, mapped, _scope, ctx),
    do: map_from_source(inner, mapped, %{value: nil, parent: nil, hidden: false}, ctx)

  defp map_from_source({:filter, {:everything}, expr}, mapped, scope, ctx) do
    with true <- root?(scope),
         {:ok, fields} <- mapped_fields(mapped) do
      fetch_exact(expr, fields, fn outer -> eval(outer, nested(scope, nil), ctx) end, ctx)
    else
      _ -> :error
    end
  end

  defp map_from_source(_base, _mapped, _scope, _ctx), do: :error

  # The top-level keys `mapped` reads of each element, when it reads nothing
  # else of it.
  defp mapped_fields({:attr, base, key}) when base in [nil, {:this}], do: {:ok, [key]}

  defp mapped_fields({:projection, {:this}, {:object, attrs}}) do
    Enum.reduce_while(attrs, {:ok, []}, fn
      {:attr_value, _name, {:attr, base, key}}, {:ok, acc} when base in [nil, {:this}] ->
        {:cont, {:ok, [key | acc]}}

      _attr, _acc ->
        {:halt, :error}
    end)
  end

  defp mapped_fields(_mapped), do: :error

  # A slice of `*[...]` or of `*[...] | order(...)` asks the source for the
  # documents it needs instead of loading every match. An exact filter
  # (`Pushdown.exact/2`) with sort keys SQL can order by is answered by one
  # read with LIMIT and OFFSET. Any other is scanned in chunks that keep only
  # the documents the slice needs. Only a query whose `*[...]` gives the same
  # documents in every scope qualifies: a closed subquery (`{:memo, _}`) or a
  # query at the root. A subquery that reads `^` is still read once for all
  # parents. A negative index needs the length, so it loads.
  defp elem_from_source(base, index, scope, ctx) do
    case is_number(index) and Values.num(index) do
      i when is_integer(i) and i >= 0 ->
        case source_slice(base, i, i + 1, scope, ctx) do
          {:ok, [doc | _]} -> {:ok, doc}
          {:ok, []} -> {:ok, nil}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp slice_from_source(base, left, right, inclusive?, scope, ctx)
       when is_number(left) and is_number(right) and left >= 0 and right >= 0 do
    from = trunc(left)
    to = trunc(right) + if(inclusive?, do: 1, else: 0)
    source_slice(base, from, to, scope, ctx)
  end

  defp slice_from_source(_base, _left, _right, _inclusive?, _scope, _ctx), do: :error

  # A projection (or `.key`) before the slice, `*[...]{a, b}[0...10]` or
  # `*[...] | order(x){a}[3]`: a map is element by element, so the slice of the
  # mapped list is the map of the sliced list. The source then reads only the
  # documents the slice needs instead of every match, and the projection runs
  # on those alone.
  defp slice_through_map(base, left, right, inclusive?, scope, ctx) do
    with {:map, list_base, mapped} <- unmemo(base),
         {:ok, docs} <- slice_from_source(list_base, left, right, inclusive?, scope, ctx) do
      {:ok, Enum.map(docs, &eval(mapped, hidden(scope, &1), ctx))}
    else
      _ -> :error
    end
  end

  defp elem_through_map(base, index, scope, ctx) do
    with {:map, list_base, mapped} <- unmemo(base),
         {:ok, doc} <- elem_from_source(list_base, index, scope, ctx) do
      {:ok, if(doc == nil, do: nil, else: eval(mapped, hidden(scope, doc), ctx))}
    else
      _ -> :error
    end
  end

  defp unmemo({:memo, inner}), do: unmemo(inner)
  defp unmemo(other), do: other

  defp source_slice(base, from, to, scope, ctx) do
    root? = scope.value == nil and scope.parent == nil

    case slice_base(base, root?) do
      {:ok, _expr, _order} when to <= from ->
        {:ok, []}

      {:ok, expr, order} ->
        resolve = fn outer_expr -> eval(outer_expr, nested(scope, nil), ctx) end

        with :error <- exact_slice(expr, order, resolve, from, to, ctx) do
          scan_slice(base, expr, order, from, to, scope, ctx, resolve)
        end

      :error ->
        :error
    end
  end

  defp slice_base({:memo, inner}, _closed?), do: slice_base(inner, true)
  defp slice_base({:group, inner}, closed?), do: slice_base(inner, closed?)
  defp slice_base({:filter, {:everything}, expr}, true), do: {:ok, expr, []}

  defp slice_base({:pipe, base, "order", args}, closed?) do
    case slice_base(base, closed?) do
      {:ok, expr, []} -> {:ok, expr, args}
      _ -> :error
    end
  end

  defp slice_base(_base, _closed?), do: :error

  defp exact_slice(expr, order, resolve, from, to, ctx) do
    with {:ok, constraints} <- Pushdown.exact(expr, resolve),
         {:ok, keys} <- Pushdown.order_keys(order) do
      Source.slice(ctx.source, constraints, keys, from, to)
    end
  end

  defp scan_slice(base, expr, order, from, to, scope, ctx, resolve) do
    keep? = fn doc ->
      kept = eval(expr, nested(scope, doc), ctx) === true
      # references?/2 caches per document; a scanned one is not seen again.
      Process.delete({:groq_refs, doc["_id"]})
      kept
    end

    rank = if order != [], do: &rank(&1, order, scope, ctx)

    case Source.scan_slice(
           ctx.source,
           Pushdown.constraints(expr, resolve),
           {base, to},
           keep?,
           rank,
           to
         ) do
      {:ok, docs} -> {:ok, Enum.drop(docs, from)}
      :error -> :error
    end
  end

  # `order()` over documents in any order: ties fall back to `_id`, the order
  # `*[...]` gives them before `order()` sorts.
  defp rank(docs, order, scope, ctx) do
    specs =
      Enum.map(order, fn
        {:desc, e} -> {e, :desc}
        {:asc, e} -> {e, :asc}
        e -> {e, :asc}
      end)

    docs
    |> Enum.map(fn doc ->
      doc_scope = nested(scope, doc)
      {doc, doc["_id"], Enum.map(specs, fn {e, dir} -> {eval(e, doc_scope, ctx), dir} end)}
    end)
    |> Enum.sort(fn {_, ia, ka}, {_, ib, kb} -> order_le?(ka, kb, ia, ib) end)
    |> Enum.map(&elem(&1, 0))
  end

  # `references()` walks the whole value. A document straight from the source
  # is walked once per query and its id set reused, which matters for the
  # common `*[_type == "x" && references(^._id)]` inside a projection.
  defp references?(%{"_id" => id} = doc, ids) when is_binary(id) do
    refs =
      case Process.get({:groq_refs, id}) do
        {^doc, set} ->
          set

        _ ->
          set = collect_refs(doc, MapSet.new())
          Process.put({:groq_refs, id}, {doc, set})
          set
      end

    not MapSet.disjoint?(refs, ids)
  end

  defp references?(value, ids), do: has_reference?(value, ids)

  defp has_reference?(list, ids) when is_list(list), do: Enum.any?(list, &has_reference?(&1, ids))

  defp has_reference?(%{"_ref" => ref}, ids) when is_binary(ref) and ref != "",
    do: MapSet.member?(ids, ref)

  defp has_reference?(%{} = map, ids),
    do: Enum.any?(map, fn {_k, v} -> has_reference?(v, ids) end)

  defp has_reference?(_, _ids), do: false

  # Mirrors has_reference?/2: an object with a truthy `_ref` contributes that
  # ref and is not descended into.
  defp collect_refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_refs/2)

  defp collect_refs(%{"_ref" => ref}, acc) when is_binary(ref) and ref != "",
    do: MapSet.put(acc, ref)

  defp collect_refs(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_k, v}, a -> collect_refs(v, a) end)

  defp collect_refs(_, acc), do: acc
end
