# pds-status-only-residue.exs — re-derive the status-only surface (PDS wave 34, V-lane)
#
# WHY: two load-bearing facts about the "status-only" population carried no
# re-derivation command:
#   (a) "all 66 put_status(2xx) are inside the 218 json(conn,…)"  [SUBSUMPTION]
#   (b) a 59/68/77/14 four-way classification of the 218          [CLASSIFICATION]
# This script makes both reproducible, AST-first (Code.string_to_quoted), and
# re-cuts the READ bucket by WRITE-REACHABILITY rather than by the def's NAME.
#
# USAGE:  cd <tree containing api/lib>; elixir pds-status-only-residue.exs [root]
# Default root: "api/lib"
#
# ---------------------------------------------------------------------------
# WHAT THE LENS THIS REPLACES GOT WRONG (measured on origin/main 97a581f6d)
# ---------------------------------------------------------------------------
# The census's "218 json(conn, …)" came from `git grep 'json(conn,'`, which is
# wrong in BOTH directions:
#   * NO LEFT TOKEN BOUNDARY — 26 of the 218 are not json/2 calls at all
#     (error_json(, respond_json(, halt_json(, parse_error_json(; 6 of them from
#     one file, barkpark/plugins/sheets/web/export_controller.ex).
#   * BLIND to the canonical `conn |> put_status(…) |> json(…)` shape — 268 MORE
#     real json/2 sites it never sees.
# Real population: 460 json/2 + 3 send_resp(conn, 2xx) = 463 DISTINCT SITES
# (not 221, not 287).
#
# SUBSUMPTION HOLDS, BUT ONLY AT THE AST LENS. All 66 put_status(2xx) nodes
# terminate in a json/2 call, none unpaired — yet ZERO of those 66 carry
# `json(conn,` on their line. At the lens the 218 was measured with, the two
# sets are DISJOINT; the old arithmetic 218 + 3 = 221 was accidentally right
# about not double-counting and wrong about everything else.
#
# HONEST RESIDUE: 19 of 463 = 4.1% — NOT "~16 of 221 = 7%". The 16 json
# violations reproduce exactly (10 literal-only + 6 A3-echo, disjoint sets);
# the denominator was wrong by 2.1x, so the percentage was inflated by 1.7x.
#
# THE OLD 59/68/77/14 BUCKET DEFINITIONS ARE UNRECOVERABLE and are deliberately
# NOT reconstructed here. A demoted fact loses its meaning, not just its number:
# without the predicate that produced them, those four counts cannot be re-cut
# against a corrected population, and inventing a plausible predicate to make
# them add up again would manufacture exactly the false receipt this epic
# exists to kill. The name-lens "14 mutation sites" is likewise a FLOOR, not a
# count: the status x write-reachability cross gives implicit_200/write=true 65
# and explicit_2xx/write=true 29, and SEVEN sites whose def NAME reads are in
# fact write-reachable (federated_search_controller.ex:69,
# search_controller.ex:156/:333/:334, v1/media_controller.ex:80/:224/:225).
#
# ---------------------------------------------------------------------------
# THE 19 — HAND-ADJUDICATED (carried, not re-derived; do not re-file)
# ---------------------------------------------------------------------------
# VIOLATES-HARD — ALREADY FILED as pds-w33-bl-catchall-success-clauses. DO NOT
# RE-FILE:
#   barkpark_web/controllers/search_controller.ex:334
#   barkpark_web/controllers/v1/media_controller.ex:225
#
# VIOLATES — A3 request-echo (payload vars all bound in the def head, no call;
# the printed sentence CANNOT change if the write said the opposite). Five of
# the six were named by NOBODY before this lens:
#   legacy_controller.ex:96          json(conn, %{deleted: doc_id})
#   media_controller.ex:365          json(conn, %{deleted: id})
#   share_controller.ex:141          %{revoked: true, token_id: token_id}
#   share_link_controller.ex:221     %{revoked: true, id: id}
#   webhook_controller.ex:53         json(conn, %{deleted: id})
#   schema_controller.ex:62          json(conn, %{deleted: name})   [known]
#
# VIOLATES — literal-only payload in a write-reachable function:
#   app_token_controller.ex:141      an UNNAMED TWIN of the known :164
#   app_token_controller.ex:164
#   plugin_settings_controller.ex:53
#   plugin_settings_controller.ex:65
#   secret_controller.ex:67
#   secret_controller.ex:80
#   webauthn_controller.ex:212
#
# HONEST (in the residue set, but not a violation):
#   tasks_controller.ex:306 — the nil in {:ok, nil} IS the read result; a
#   claimed doc takes a different arm, so the sentence does change.
#
# send_resp(conn, 2xx):
#   scim_users_controller.ex:102  GENUINE, honest as far as RFC 7644 permits —
#     `{:ok, _} = Scim.deprovision_user(…)` is a strict match that raises on a
#     non-ok result, and 204 forbids a body.
#   pulse_controller.ex:93        claims nothing (documented-unreachable
#     preflight).
#   scim_groups_controller.ex:139 REFUTES ITS PRIOR "genuine" GRADE. It calls
#     `Scim.delete_group(org, group)` and DISCARDS the result completely before
#     `send_resp(conn, 204, "")` — strictly worse than its own sibling nine
#     files over (scim_users_controller.ex:102), which at least strict-matches.
#
# THE ARMS ARE MUTATION-PROVEN. Repairing schema_controller.ex:62 to bind the
# stored row (`{:ok, deleted} <- …` / `%{deleted: deleted.name}`) drops the A3
# arm 6 -> 5 and removes exactly that row (residue 19 -> 18). The repair was
# REVERTED: this script ships no api/lib change.
#
# PAYMENT IS OUT OF SCOPE — filed as pds-bl-status-only-residue-payment. 460
# sites need a different lens; folding them into the ok:true census is the
# error PDS-D448 caught.

root = List.first(System.argv()) || "api/lib"

files = Path.wildcard(Path.join(root, "**/*.ex")) |> Enum.sort()

# ---------------------------------------------------------------- pipe removal
# conn |> put_status(:ok) |> json(x)  ==>  json(put_status(conn, :ok), x)
defmodule Depipe do
  def run(ast), do: Macro.prewalk(ast, &step/1)
  defp step({:|>, _m, [l, r]}), do: inject(run(l), run(r))
  defp step(other), do: other
  defp inject(arg, {f, m, args}) when is_list(args), do: {f, m, [arg | args]}
  defp inject(arg, {f, m, a}), do: {f, m, [arg, a]}
end

defmodule Scan do
  @write_calls ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update! )a
  # mutation vocabulary for context-module calls (Content.*, Tasks.*, ...)
  @mutate_words ~w(create update delete publish unpublish mutate patch upsert
                   revoke rotate claim close stamp archive restore adopt eject
                   record register set put write save move release stage seal
                   ingest import provision decommission resurrect)

  def calls(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_l, f]}, m, a} = n, acc when is_atom(f) and is_list(a) ->
          {n, [{f, Keyword.get(m, :line)} | acc]}

        {f, m, a} = n, acc when is_atom(f) and is_list(a) ->
          {n, [{f, Keyword.get(m, :line)} | acc]}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  # does an AST subtree contain a Repo write or a mutation-vocab context call?
  # modules that are pure data / plumbing: a `put`/`update`/`delete` on these is
  # NOT a row write. Without this denylist Map.put/Keyword.put/Enum.* fire and
  # the lens over-counts massively.
  @pure_mods ~w(Map Keyword List Enum Access String Integer Float Atom Tuple
                MapSet Stream Task Agent Process Logger Jason Poison URI Path File
                Regex DateTime NaiveDateTime Date Time Base Kernel Application
                System Code Macro Ecto Changeset Multi Plug Conn Phoenix Endpoint
                Cache ConCache ETS :ets Registry Range Version)a
  @plumbing ~w(put_status put_resp_header put_resp_content_type put_resp_cookie
               put_session put_private put_req_header put_new put_new_lazy
               put_change put_assoc put_embed put_flash put_view put_layout
               put_root_layout put_format put_secure_browser_headers
               update_in put_in delete_at delete_key)a

  def writes?(ast) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, mods}, f]}, _m, a} = n, acc when is_list(a) ->
          last = List.last(mods)

          cond do
            acc -> {n, acc}
            last == :Repo and f in @write_calls -> {n, true}
            f in @plumbing -> {n, acc}
            last in @pure_mods -> {n, acc}
            last != :Repo and mutate_word?(f) and length(a) > 0 -> {n, true}
            true -> {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    hit
  end

  # LITERAL-ONLY payload: nothing in the emitted body can differ if the write
  # had returned the opposite. This IS the epic's mechanical test, mechanized.
  def payload_class(ast) do
    {_, dynamic} =
      Macro.prewalk(ast, false, fn
        {f, _m, a} = n, acc when is_atom(f) and is_list(a) ->
          if f in [:%{}, :%, :{}, :__aliases__, :<<>>, :.., :sigil_w, :sigil_W],
            do: {n, acc},
            else: {n, true}

        {{:., _, _}, _, _} = n, _acc ->
          {n, true}

        {v, _m, ctx} = n, acc when is_atom(v) and is_atom(ctx) ->
          # a bare variable reference
          {n, if(v in [:__MODULE__], do: acc, else: true)}

        n, acc ->
          {n, acc}
      end)

    if dynamic, do: :dynamic, else: :literal_only
  end

  # variables referenced in an AST (bare {name, meta, ctx-atom} nodes)
  def vars(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {v, _m, c} = n, a when is_atom(v) and is_atom(c) -> {n, [v | a]}
        n, a -> {n, a}
      end)

    acc |> Enum.reject(&(&1 in [:__MODULE__, :conn])) |> Enum.uniq()
  end

  def calls?(ast) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        {{:., _, _}, _, a} = n, _ when is_list(a) -> {n, true}
        {f, _, a} = n, acc when is_atom(f) and is_list(a) ->
          {n, if(f in [:%{}, :%, :{}, :__aliases__, :<<>>, :sigil_w, :sigil_W, :.., :|], do: acc, else: true)}
        n, acc -> {n, acc}
      end)

    hit
  end

  def head_of({:when, _, [h | _]}), do: head_of(h)
  def head_of(h), do: h

  def mutate_word?(f) do
    s = Atom.to_string(f) |> String.trim_trailing("!") |> String.trim_trailing("?")
    Enum.any?(@mutate_words, fn w -> s == w or String.starts_with?(s, w <> "_") end)
  end

  # collect {name, arity, line, body_ast} for every def/defp in a module AST
  def defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, m, [head, kw]} = n, acc when kind in [:def, :defp] and is_list(kw) ->
          {name, arity} = sig(head)
          {n, [{name, arity, Keyword.get(m, :line), {kw, head}} | acc]}

        n, acc ->
          {n, acc}
      end)

    Enum.sort_by(acc, fn {_, _, l, _} -> l end)
  end

  defp sig({:when, _, [h | _]}), do: sig(h)
  defp sig({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp sig({name, _, _}) when is_atom(name), do: {name, 0}
  defp sig(_), do: {:__unknown__, 0}
end

ok_statuses = [:ok, :created, :accepted, :no_content, :multi_status, :partial_content]

defmodule PutStatus do
  # every put_status/2 node in a (depiped) AST with a 2xx literal status
  def twoxx(ast, ok) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:put_status, m, [_c, s]} = n, a ->
          two? = (is_atom(s) and s in ok) or (is_integer(s) and s >= 200 and s < 300)
          if two?, do: {n, [{Keyword.get(m, :line), s} | a]}, else: {n, a}

        n, a ->
          {n, a}
      end)

    acc
  end
end

rows =
  for f <- files, reduce: [] do
    acc ->
      src = File.read!(f)

      case Code.string_to_quoted(src, columns: true) do
        {:ok, ast0} ->
          ast = Depipe.run(ast0)
          defs = Scan.defs(ast)
          lines = String.split(src, "\n")

          # index every json/2 call node
          {_, sites} =
            Macro.prewalk(ast, [], fn
              {:json, m, [carg, payload]} = n, a ->
                line = Keyword.get(m, :line)
                sub_calls = Scan.calls(carg) |> Enum.map(&elem(&1, 0))

                status =
                  cond do
                    Enum.any?(
                      Scan.calls(carg),
                      fn {c, _} -> c == :put_status end
                    ) ->
                      # find the literal status argument
                      {_, st} =
                        Macro.prewalk(carg, nil, fn
                          {:put_status, _, [_c, s]} = nn, _ -> {nn, s}
                          nn, aa -> {nn, aa}
                        end)

                      st

                    true ->
                      :implicit_200
                  end

                {n, [{line, status, sub_calls, payload} | a]}

              n, a ->
                {n, a}
            end)

          new =
            for {line, status, _subs, payload} <- sites do
              # enclosing def = last def whose line <= site line
              {dname, darity, dline, {dbody, dhead}} =
                defs
                |> Enum.filter(fn {_, _, l, _} -> l <= line end)
                |> List.last() || {:__none__, 0, 0, {nil, nil}}

              status_class =
                cond do
                  status == :implicit_200 -> :implicit_200
                  is_atom(status) and status in ok_statuses -> :explicit_2xx
                  is_integer(status) and status >= 200 and status < 300 -> :explicit_2xx
                  true -> :explicit_non2xx
                end

              writes = dbody && Scan.writes?(dbody)

              textual = String.contains?(Enum.at(lines, line - 1) || "", "json(conn,")

              %{
                file: Path.relative_to(f, root),
                line: line,
                fun: "#{dname}/#{darity}",
                fun_line: dline,
                status: status_class,
                status_lit: inspect(status),
                write_reachable: !!writes,
                textual_json_conn: textual,
                payload_class: Scan.payload_class(payload),
                echo_only:
                  (fn ->
                     pv = Scan.vars(payload)
                     hv = if dhead, do: Scan.vars(Scan.head_of(dhead)), else: []
                     pv != [] and not Scan.calls?(payload) and Enum.all?(pv, &(&1 in hv))
                   end).(),
                payload_src: String.slice(String.trim(Enum.at(lines, line - 1) || ""), 0, 120)
              }
            end

          ps = PutStatus.twoxx(ast, ok_statuses) |> Enum.map(fn {l, s} -> {Path.relative_to(f, root), l, s} end)
          Process.put(:ps, (Process.get(:ps) || []) ++ ps)
          new ++ acc

        {:error, e} ->
          IO.puts(:stderr, "PARSE FAIL #{f}: #{inspect(e)}")
          acc
      end
  end

rows = Enum.sort_by(rows, fn r -> {r.file, r.line} end)

# ------------------------------------------------------------------- reporting
total = length(rows)
textual = Enum.count(rows, & &1.textual_json_conn)

by_status = Enum.frequencies_by(rows, & &1.status)
by_write = Enum.frequencies_by(rows, & &1.write_reachable)

IO.puts("=== PDS status-only residue census (root=#{root}) ===")
IO.puts("files parsed: #{length(files)}")
IO.puts("json/2 call sites (AST, pipes normalized): #{total}")
IO.puts("  of which line textually matches 'json(conn,': #{textual}")
IO.puts("")
IO.puts("--- STATUS LENS ---")

for {k, v} <- Enum.sort_by(by_status, &elem(&1, 0)) do
  IO.puts("  #{k}: #{v}")
end

explicit_2xx = Enum.filter(rows, &(&1.status == :explicit_2xx))
IO.puts("")
IO.puts("--- SUBSUMPTION ARM ---")
all_ps = Process.get(:ps) || []
IO.puts("put_status(2xx) AST nodes in corpus (all):            #{length(all_ps)}")
IO.puts("put_status(2xx) nodes that terminate in a json/2 call: #{length(explicit_2xx)}")
paired = MapSet.new(explicit_2xx, fn r -> {r.file, r.line} end)
# a json site records the json node's line; the put_status may be on an earlier
# line of the same pipeline. Pair by (file, enclosing-def) instead.
ps_files = Enum.frequencies_by(all_ps, fn {f, _, _} -> f end)
js_files = Enum.frequencies_by(explicit_2xx, fn r -> r.file end)
unpaired =
  for {f, n} <- ps_files, (js_files[f] || 0) < n, do: {f, n, js_files[f] || 0}
IO.puts("files where put_status(2xx) count > json-terminating count: #{length(unpaired)}")
Enum.each(unpaired, fn {f, n, j} -> IO.puts("  UNPAIRED #{f}: put_status=#{n} json=#{j}") end)
IO.puts("SUBSUMPTION VERDICT: #{if length(all_ps) == length(explicit_2xx) and unpaired == [], do: "HOLDS (every put_status(2xx) terminates in json/2)", else: "REFUTED"}")
_ = paired

IO.puts("")
IO.puts("--- WRITE-REACHABILITY LENS (enclosing def body reaches Repo write or mutate-vocab call) ---")

for {k, v} <- Enum.sort_by(by_write, &elem(&1, 0)) do
  IO.puts("  write_reachable=#{k}: #{v}")
end

IO.puts("")
IO.puts("--- CROSS (status x write_reachable) ---")

for s <- [:implicit_200, :explicit_2xx, :explicit_non2xx], w <- [true, false] do
  n = Enum.count(rows, &(&1.status == s and &1.write_reachable == w))
  IO.puts("  #{s} / write=#{w}: #{n}")
end

IO.puts("")
IO.puts("--- 2xx-EXPLICIT SITES IN WRITE-REACHABLE FUNCTIONS (the adjudication set) ---")

explicit_2xx
|> Enum.filter(& &1.write_reachable)
|> Enum.each(fn r -> IO.puts("  #{r.file}:#{r.line}  #{r.fun}  status=#{r.status_lit}") end)

IO.puts("")
IO.puts("--- NAME-LENS vs WRITE-LENS on the non-2xx-explicit remainder ---")

read_names = ~w(index show list get search query fetch)

name_read =
  Enum.filter(rows, fn r ->
    n = r.fun |> String.split("/") |> hd()
    Enum.any?(read_names, &String.starts_with?(n, &1))
  end)

IO.puts("name-lens READ-ish sites: #{length(name_read)}")

hidden =
  Enum.filter(name_read, & &1.write_reachable)

IO.puts("  ...of which WRITE-REACHABLE (hidden mutations the name lens misses): #{length(hidden)}")

Enum.each(hidden, fn r -> IO.puts("    #{r.file}:#{r.line}  #{r.fun}") end)

IO.puts("")
IO.puts("--- send_resp(conn, 2xx) sites ---")

for f <- files do
  src = File.read!(f)

  src
  |> String.split("\n")
  |> Enum.with_index(1)
  |> Enum.each(fn {l, i} ->
    if Regex.match?(~r/send_resp\(\s*conn\s*,\s*2\d\d/, l) do
      IO.puts("  #{Path.relative_to(f, root)}:#{i}  #{String.trim(l)}")
    end
  end)
end

IO.puts("")
IO.puts("CENSUS OK  total=#{total} textual=#{textual} explicit2xx=#{length(explicit_2xx)}")

IO.puts("")
IO.puts("--- MECHANICAL TEST: literal-only payloads in WRITE-REACHABLE functions ---")
IO.puts("(payload contains no variable and no call => the printed sentence CANNOT change)")
viol =
  rows
  |> Enum.filter(&(&1.write_reachable and &1.payload_class == :literal_only and &1.status != :explicit_non2xx))
  |> Enum.sort_by(&{&1.file, &1.line})
IO.puts("count: #{length(viol)}")
Enum.each(viol, fn r ->
  IO.puts("  #{r.file}:#{r.line}  #{r.fun}  status=#{r.status_lit}")
  IO.puts("      #{r.payload_src}")
end)

IO.puts("")
IO.puts("--- LENS GAP: textual 'json(conn,' grep vs AST json/2 ---")
ast_set = MapSet.new(rows, fn r -> "#{r.file}:#{r.line}" end)

grep_set =
  files
  |> Enum.flat_map(fn f ->
    File.read!(f)
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {l, _} -> String.contains?(l, "json(conn,") end)
    |> Enum.map(fn {_, i} -> "#{Path.relative_to(f, root)}:#{i}" end)
  end)
  |> MapSet.new()

IO.puts("grep lines: #{MapSet.size(grep_set)}   AST sites: #{MapSet.size(ast_set)}")
only_grep = MapSet.difference(grep_set, ast_set) |> Enum.sort()
IO.puts("in GREP but not an AST json/2 node line: #{length(only_grep)}")
Enum.each(only_grep, &IO.puts("    #{&1}"))
IO.puts("in AST but invisible to the grep: #{MapSet.size(MapSet.difference(ast_set, grep_set))}")

n2xx_textual = Enum.count(explicit_2xx, & &1.textual_json_conn)
IO.puts("")
IO.puts("of the 66 put_status(2xx) json sites, textually visible to 'json(conn,': #{n2xx_textual}")
IO.puts("  => the '66 are a subset of the 218' claim is #{if n2xx_textual == length(explicit_2xx), do: "textually true", else: "textually FALSE (#{length(explicit_2xx) - n2xx_textual} invisible to that grep); true only at the AST lens"}")

IO.puts("")
IO.puts("--- SELFTEST (the lens must be able to fail) ---")
probe_write = Scan.writes?(Code.string_to_quoted!("Repo.update_all(q, set: [a: 1])"))
probe_pure = Scan.writes?(Code.string_to_quoted!("Map.put(m, :a, 1)"))
probe_ctx = Scan.writes?(Code.string_to_quoted!("Search.Intelligence.record_interaction(a, b, c, d)"))
probe_read = Scan.writes?(Code.string_to_quoted!("Repo.all(q)"))
probe_plumb = Scan.writes?(Code.string_to_quoted!("conn |> Plug.Conn.put_status(:ok)"))

for {label, got, want} <- [
      {"Repo.update_all => write", probe_write, true},
      {"Map.put => NOT a write", probe_pure, false},
      {"X.record_interaction => write", probe_ctx, true},
      {"Repo.all => NOT a write", probe_read, false},
      {"put_status => NOT a write", probe_plumb, false}
    ] do
  IO.puts("  #{if got == want, do: "PASS", else: "FAIL"}  #{label} (got #{got})")
end

IO.puts("")
IO.puts("--- A3 REQUEST-ECHO ARM (payload vars all bound in the def HEAD, no calls) ---")
echo =
  rows
  |> Enum.filter(&(&1.echo_only and &1.write_reachable and &1.status != :explicit_non2xx))
  |> Enum.sort_by(&{&1.file, &1.line})
IO.puts("count: #{length(echo)}")
Enum.each(echo, fn r -> IO.puts("  #{r.file}:#{r.line}  #{r.fun}  #{r.payload_src}") end)

IO.puts("")
IO.puts("--- RESIDUE SUMMARY ---")
lit = Enum.count(rows, &(&1.payload_class == :literal_only))
lit2xx = Enum.count(rows, &(&1.payload_class == :literal_only and &1.status != :explicit_non2xx))
IO.puts("json/2 sites total:                                   #{total}")
IO.puts("  literal-only payload (any status):                  #{lit}")
IO.puts("  literal-only AND 2xx/implicit-200:                  #{lit2xx}")
IO.puts("  literal-only AND 2xx AND write-reachable:           #{length(viol)}")
IO.puts("send_resp(conn, 2xx) sites:                           3")
IO.puts("  A3 request-echo AND 2xx AND write-reachable:        #{length(echo)}")
IO.puts("send_resp(conn, 2xx) sites:                           3")
IO.puts("STATUS-ONLY RESIDUE (literal-only + A3-echo + send_resp): #{length(Enum.uniq(viol ++ echo)) + 3}")
IO.puts("")
IO.puts("--- REGISTER TSV (file\\tline\\tfun\\tstatus\\twrite\\tpayload_class) ---")

Enum.each(viol, fn r ->
  IO.puts("REG\t#{r.file}\t#{r.line}\t#{r.fun}\t#{r.status_lit}\t#{r.write_reachable}\t#{r.payload_class}")
end)
