# _probe_d498_head_hash_corpus.exs — PDS-D498's head_hash figures, RE-DERIVED IN PROCESS.
#
# WHY IT EXISTS. The census (scripts/pds-elixir-receipt-census.exs) carries the
# corpus-wide head_hash collision figure as a COMMENT and computes it nowhere at run
# time, so PDS-D498's header fact had no derivation command to quote and was being
# transcribed from wave to wave. This probe is that command. It is READ-ONLY: it
# parses api/lib and prints; it writes nothing and it does not touch the census.
#
# WHAT IT MIRRORS, by name and not by line (PDS-D299): the census's `defs/4` walker,
# `head_sig/1`, `label/1`, `tree_population/0` (`Path.wildcard("api/lib/**/*.ex")`),
# its `Code.string_to_quoted/2` opts, and the SHIPPED key normaliser
# `total-meta-drop/phash2-term/v1` — `drop_meta/1` (`{f, _meta, a} -> {f, [], a}`)
# followed by `:erlang.phash2` of the TERM. Those are all `defp` in the census, which
# is why this is a mirror and not a call.
#
# HOW IT IS KNOWN TO BE THE CENSUS'S WALKER AND NOT A LOOKALIKE — run it from a
# worktree detached at 29cb76e60, the sha PDS-D498's header facts were derived at, and
# it prints the census's own numbers EXACTLY: 17,620 defs; 3 within-{path,mfa}
# collision buckets over 6 defs at the same three sites and the same lines;
# capabilities.ex visible?/2 = 52289869; `def all()` = 1339030 in 7 modules; 912
# corpus-wide groups over 2,543 defs; widest groups init/1 at 53 and call/2 at 39.
# A mirror that reproduces six independent figures at a foreign sha is the walker.
#
# THE CONTROL LINES BELOW ARE THE POINT. A run that prints a def count nowhere near
# the tree's own `git grep -cE '^[[:space:]]*(def|defp|defmacro|defmacrop|defdelegate)[[:space:]]'`
# over api/lib has a broken population, and its collision figures mean nothing.
#
#   Usage: elixir tooling/grip/ledger/_probe_d498_head_hash_corpus.exs   (from the repo root)
defmodule Probe do
  def parse_opts,
    do: [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      emit_warnings: false,
      unescape: false
    ]

  def drop_meta(ast),
    do: Macro.prewalk(ast, fn {f, m, a} when is_list(m) -> {f, [], a}; n -> n end)

  def fp(nil), do: "-"
  def fp(node), do: node |> drop_meta() |> :erlang.phash2() |> to_string()

  def head_sig({:when, _, [h | _]}), do: head_sig(h)
  def head_sig({name, meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), meta}
  def head_sig({name, meta, _}) when is_atom(name), do: {name, 0, meta}
  def head_sig(_), do: {:__unknown__, 0, []}

  def defs(node, mod, path, acc) do
    case node do
      {:defmodule, _, [{:__aliases__, _, segs}, body]} ->
        defs(body, mod ++ segs, path, acc)

      {op, meta, [head | _rest]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        {name, arity, hmeta} = head_sig(head)
        [%{module: mod, name: name, arity: arity, path: path,
           line: meta[:line] || hmeta[:line] || 0, head: head} | acc]

      {:defdelegate, meta, [head, _opts]} ->
        {name, arity, _} = head_sig(head)
        [%{module: mod, name: name, arity: arity, path: path, line: meta[:line] || 0, head: head} | acc]

      list when is_list(list) -> Enum.reduce(list, acc, &defs(&1, mod, path, &2))
      {a, b} -> acc |> then(&defs(a, mod, path, &1)) |> then(&defs(b, mod, path, &1))
      {_f, _, args} when is_list(args) -> Enum.reduce(args, acc, &defs(&1, mod, path, &2))
      _ -> acc
    end
  end

  def label(d), do: "#{Enum.join(d.module, ".")}.#{d.name}/#{d.arity}"
end

all =
  Path.wildcard("api/lib/**/*.ex")
  |> Enum.sort()
  |> Enum.flat_map(fn path ->
    case Code.string_to_quoted(File.read!(path), Probe.parse_opts()) do
      {:ok, ast} -> Probe.defs(ast, [], path, []) |> Enum.reverse()
      {:error, _} -> []
    end
  end)
  |> Enum.map(&Map.put(&1, :hh, Probe.fp(&1.head)))

IO.puts("defs                     #{length(all)}   (CONTROL: census header says 17,620)")

# within {path, mfa} groups
wg =
  all
  |> Enum.group_by(&{&1.path, Probe.label(&1)})
  |> Enum.flat_map(fn {k, ds} ->
    ds |> Enum.group_by(& &1.hh) |> Enum.filter(fn {_, v} -> length(v) > 1 end)
       |> Enum.map(fn {h, v} -> {k, h, Enum.map(v, & &1.line)} end)
  end)

IO.puts("within-{path,mfa} buckets #{length(wg)} over #{wg |> Enum.map(fn {_,_,l} -> length(l) end) |> Enum.sum()} defs   (CONTROL: 3 buckets / 6 defs)")
Enum.each(wg, fn {{p, m}, h, lines} -> IO.puts("    #{p}  #{m}  hash=#{h}  lines=#{Enum.join(lines, ",")}") end)

# corpus-wide: ignore path and mfa
cw = all |> Enum.group_by(& &1.hh) |> Enum.filter(fn {_, v} -> length(v) > 1 end)
IO.puts("CORPUS-WIDE collision groups #{length(cw)} over #{cw |> Enum.map(fn {_, v} -> length(v) end) |> Enum.sum()} defs")

# controls
vis = Enum.filter(all, &(&1.path =~ "plugins/capabilities.ex" and &1.name == :visible? and &1.arity == 2))
IO.puts("CONTROL capabilities.ex visible?/2 hashes: #{inspect(Enum.map(vis, &{&1.line, &1.hh}))}   (expect 52289869)")
allz = Enum.filter(all, &(&1.name == :all and &1.arity == 0))
byh = Enum.group_by(allz, & &1.hh)
IO.puts("CONTROL `def all()` arity-0: #{length(allz)} defs, hash buckets #{inspect(Enum.map(byh, fn {h, v} -> {h, length(v)} end))}   (expect hash 1339030 in 7 modules)")
widest = cw |> Enum.sort_by(fn {_, v} -> -length(v) end) |> Enum.take(3)
IO.puts("widest corpus-wide groups: " <> Enum.map_join(widest, ", ", fn {h, v} -> "#{hd(v).name}/#{hd(v).arity}(#{h})=#{length(v)}" end))
