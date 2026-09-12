# pds-status-only-residue.exs — re-derive the status-only surface (PDS wave 34,
# hardened wave 41)
#
# WHY: two load-bearing facts about the "status-only" population carried no
# re-derivation command:
#   (a) "all put_status(2xx) are inside the json(conn,…) population"  [SUBSUMPTION]
#   (b) a 59/68/77/14 four-way classification of that population      [CLASSIFICATION]
# This script makes both reproducible, AST-first (Code.string_to_quoted), and
# re-cuts the READ bucket by WRITE-REACHABILITY rather than by the def's NAME.
#
# USAGE
#   elixir scripts/pds-status-only-residue.exs [root]     # default root: api/lib
#   elixir scripts/pds-status-only-residue.exs --selftest # arms only, no corpus
#   elixir scripts/pds-status-only-residue.exs --help
#
# EXIT CODES — THIS LENS CAN RED (wave 41; before wave 41 it had NO System.halt
# at all and reported success over an empty corpus)
#   0  clean run, or a green --selftest
#   1  --selftest: at least one arm FAILED
#   2  REFUSED: unknown flag / unreadable root / corpus below the floor
#   3  the corpus contains files this lens could not parse (silently-missing
#      corpus is indistinguishable from a clean tree, so it reds)
#   4  an A3 request-echo CALLSITE appeared that is not on the pinned allowlist
#
# THE MAIN PATH DOES NOT RED ON THE RESIDUE NUMBER ITSELF, deliberately: every
# count below is a FLOOR (see LENS FLOORS), and thresholding a floor manufactures
# exactly the false receipt this epic exists to kill. It reds on refusals, on
# unparsed corpus, and on allowlist drift — all three of which are statements
# about whether the MEASUREMENT happened, not about what it found.
#
# ---------------------------------------------------------------------------
# UNITS — THIS LENS COUNTS CALLSITES; THE RECEIPT CENSUS COUNTS ROUTED ROWS
# ---------------------------------------------------------------------------
# A CALLSITE is one json/2 (or send_resp(conn, 2xx)) node in the source. A ROUTED
# ROW is one route -> action pair in scripts/pds-elixir-receipt-census.exs. The
# two units are DISJOINT: a callsite reached by two routes is ONE callsite and TWO
# rows; a callsite inside an unrouted helper is ONE callsite and ZERO rows.
# So this lens printing 0 CALLSITES on its A3 arm does NOT contradict the census
# printing 3 ROWS, and a builder who tunes a predicate here until it reproduces
# the census's number has manufactured a predicate to hit another instrument's
# figure. Every count printed below carries its unit and its denominator.
#
# ---------------------------------------------------------------------------
# WHAT THE LENS THIS REPLACES GOT WRONG
# ---------------------------------------------------------------------------
# The census's "218 json(conn, …)" came from `git grep 'json(conn,'`, which is
# wrong in BOTH directions, and the run below re-derives both errors live:
#   * NO LEFT TOKEN BOUNDARY — some grep hits are not json/2 calls at all
#     (error_json(, respond_json(, halt_json(, parse_error_json(). Printed under
#     "in GREP but not an AST json/2 node line".
#   * BLIND to the canonical `conn |> put_status(…) |> json(…)` shape. Printed
#     under "in AST but invisible to the grep".
# NO POPULATION NUMBER IS TRANSCRIBED INTO THIS HEADER (wave 41). The wave-34
# header carried "460 json/2 + 3 send_resp = 463" and "HONEST RESIDUE: 19 of 463"
# plus a hand-listed roster of "THE 19" — a transcription inside the instrument,
# already refuted by the instrument's own run, and 8 of the listed rows have since
# been repaired. Run the script; the run is the number.
#
# SUBSUMPTION HOLDS ONLY AT THE AST LENS. The put_status(2xx) nodes all terminate
# in a json/2 call, yet the run prints how many of them are textually invisible to
# `json(conn,`. At the lens the "218" was measured with, the two sets are largely
# DISJOINT.
#
# THE OLD 59/68/77/14 BUCKET DEFINITIONS ARE UNRECOVERABLE and are deliberately
# NOT reconstructed here. A demoted fact loses its meaning, not just its number:
# without the predicate that produced them, those four counts cannot be re-cut
# against a corrected population, and inventing a plausible predicate to make them
# add up again would manufacture exactly the false receipt this epic exists to
# kill.
#
# ---------------------------------------------------------------------------
# LENS FLOORS — EVERY COUNT IS A FLOOR, NOT A SCORE (quote it with its lens or
# do not quote it)
# ---------------------------------------------------------------------------
#   * The A3-echo count is a FLOOR. `payload_class` calls ANY call in the payload
#     :dynamic, and the echo arm requires `not calls?(payload)` — so a payload
#     built from a request param THROUGH A HELPER (`%{deleted: to_string(id)}`)
#     is an A3 echo in reality and invisible here. The arm catches the no-call
#     case only.
#   * write_reachable is a HEURISTIC PARTITION, not a proof: `writes?/1` fires on
#     the @mutate_words vocabulary against the @pure_mods denylist, so a context
#     call named outside that vocabulary (`Foo.bump_counter/2`) is write-reachable
#     in reality and read here. The SELFTEST proves the lens can say no on five
#     probes; it does not bound the error rate.
#   * The enclosing-def attribution is "last def whose line <= site line", which
#     is wrong for a json/2 call inside an anonymous fn defined in one def and
#     executed elsewhere, and for macro-generated code.
#   * send_resp sites are found by REGEX over lines while everything else is AST —
#     a genuine lens mismatch, named here rather than hidden.
#
#   * THE A3 ARM CANNOT SEE A BODY-BOUND PAYLOAD AT ALL. It requires every
#     payload variable to be bound in the def HEAD, so a variable bound by
#     `with … <-`, a `case` clause pattern, or `x = conn.params[…]` is invisible
#     to it BY CONSTRUCTION. The A3b section measures that population and
#     classifies it by bind-site provenance; it is PRINTED and never sets the
#     exit code, because a widened redding relation over a population whose
#     false-positive rate has not been measured is the failure PDS-D554/D566
#     name. See the `Provenance` module header for the three classes and the
#     direction of every error the walk can make.
#
# PAYMENT IS OUT OF SCOPE — filed as pds-bl-status-only-residue-payment. Folding
# the full json/2 population into the ok:true census is the error PDS-D448 caught.

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

# ------------------------------------------------- A3b: BIND-SITE PROVENANCE
# THE BLIND SHAPE THIS ADDRESSES (pds-w40-bl-body-bound-provenance). The A3 arm
# above requires every payload variable to be bound in the def HEAD. A variable
# bound in the def BODY — `with {:ok, label} <- fetch_label(params)`, a `case`
# clause pattern, a plain `=` off `conn.params` — can NEVER satisfy that
# predicate, so an entire species of request echo is invisible to A3 by
# construction. This module MEASURES that population and classifies each site's
# payload variables by where their binding's right-hand side comes from.
#
# IT IS PRINTED, NOT ARMED, AND THAT IS A DELIBERATE CHOICE, NOT AN OVERSIGHT.
# Widening a redding relation over a population whose false-positive rate has
# not been measured is the failure PDS-D554/D566 name and PDS-D560 caught in the
# act. The exit code below is untouched by this section: `Report.exit_code/2`
# still reds only on unparsed corpus (3) and off-allowlist A3 head-bound echoes
# (4). Arming A3b is a SEPARATE decision that must be paid for with a hand-read
# of every site it names.
#
# THE THREE CLASSES, AND WHY THERE ARE THREE AND NOT TWO:
#   REQUEST-ROOTED  every payload variable walks back to a binding whose RHS is
#                   rooted in the request (`conn.params`, `conn.assigns`, a
#                   head-bound argument of a `(conn, …)` def, or a chain of
#                   those) and NO payload variable carries a post-write fact.
#                   This is the accusation class.
#   STORE-FACT      at least one payload variable walks back to a binding whose
#                   RHS reaches a Repo write or a mutate-vocabulary context call
#                   (`{:ok, token} <- Auth.create_token(…)` -> `token.id`). The
#                   payload can differ if the write had gone the other way, so
#                   the site is CLEARED — one store fact is enough.
#   RESIDUAL        the walk could not decide at least one variable and found no
#                   store fact. A residual site is NOT clean and NOT accused; it
#                   is UNDECIDED, printed with the binding that defeated the
#                   walk. No site is ever guessed into REQUEST-ROOTED.
#
# The walk is intra-def and depth-capped (@max_depth). It does not follow calls
# into other functions, so `fetch_label(params)` is request-rooted because its
# ARGUMENT is, not because the callee was read. A helper that launders a request
# value through a module attribute or a process dictionary reads RESIDUAL here.
defmodule Provenance do
  @max_depth 4

  # fields of %Plug.Conn{} that are request data
  @conn_request_fields ~w(params body_params query_params path_params assigns
                          req_headers host method request_path query_string
                          remote_ip scheme port cookies req_cookies)a

  @doc """
  Variables referenced in an AST, with the string-interpolation artifact
  removed. `Scan.vars/1` counts the `::binary` size-modifier atom of an
  interpolation segment as if it were a program variable; that artifact is left
  in place there on purpose (changing it would move the A3 arm's number) and is
  corrected HERE, where the number is new.
  """
  def vars(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:"::", _, [l, {:binary, _, c}]}, a when is_atom(c) -> {l, a}
        {v, _m, c} = n, a when is_atom(v) and is_atom(c) -> {n, [v | a]}
        n, a -> {n, a}
      end)

    acc |> Enum.reject(&(&1 in [:__MODULE__, :conn])) |> Enum.uniq()
  end

  @doc """
  Binding table for one def body: `%{var => [%{line:, kind:, rhs:}]}`.

  Recognized bind sites: `lhs = rhs`, `lhs <- rhs` (with/for clauses), and
  `case subj do pat -> … end` clause patterns (producer = the case subject).
  An `fn`/`try`/`receive` pattern is deliberately NOT recognized: it would put a
  variable in the table with a producer the walk cannot name, and a table entry
  whose RHS is a lie is worse than no entry (an unlisted var reads UNDECIDED).
  """
  def bindings(nil), do: %{}

  def bindings(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:=, m, [lhs, rhs]} = n, a -> {n, entries(lhs, rhs, :match, m) ++ a}
        {:<-, m, [lhs, rhs]} = n, a -> {n, entries(lhs, rhs, :arrow, m) ++ a}
        {:case, _m, [subj, [{:do, clauses} | _]]} = n, a when is_list(clauses) ->
          {n,
           Enum.flat_map(clauses, fn
             {:->, cm, [pats, _]} -> Enum.flat_map(pats, &entries(&1, subj, :case_clause, cm))
             _ -> []
           end) ++ a}

        n, a ->
          {n, a}
      end)

    Enum.group_by(acc, & &1.var)
  end

  defp entries(lhs, rhs, kind, m) do
    line = Keyword.get(m, :line)
    for v <- pattern_vars(lhs), do: %{var: v, line: line, kind: kind, rhs: rhs}
  end

  # variables a PATTERN binds. `^pinned` and `_` bind nothing; a map pattern's
  # KEYS are not bindings, its values are.
  defp pattern_vars(pat) do
    {_, acc} =
      Macro.prewalk(pat, [], fn
        {:^, _, _}, a -> {nil, a}
        {v, _m, c} = n, a when is_atom(v) and is_atom(c) -> {n, [v | a]}
        n, a -> {n, a}
      end)

    acc
    |> Enum.reject(&(&1 == :_ or String.starts_with?(Atom.to_string(&1), "_")))
    |> Enum.uniq()
  end

  @doc "classify a variable against the binding table, following RHS roots"
  def classify(v, table, head_vars, request_head?, depth \\ 0) do
    cond do
      depth > @max_depth ->
        {:undecided, "provenance walk exceeded depth #{@max_depth}"}

      request_head? and v in head_vars ->
        {:request, "bound in the def HEAD"}

      binds = Map.get(table, v) ->
        binds
        |> Enum.map(&classify_binding(&1, table, head_vars, request_head?, depth))
        |> combine()

      true ->
        {:undecided, "no binding for `#{v}` found in this def body"}
    end
  end

  defp classify_binding(b, table, head_vars, request_head?, depth) do
    rhs = b.rhs
    where = "#{b.kind} at line #{b.line}: `#{snip(rhs)}`"

    cond do
      store_producing?(rhs) ->
        {:store, "#{where} — RHS reaches a Repo write / mutate-vocab call"}

      conn_request?(rhs) ->
        {:request, "#{where} — RHS reads conn request data"}

      true ->
        rvs = vars(rhs) |> Enum.reject(&(&1 == b.var))

        if rvs == [] do
          {:undecided, "#{where} — RHS has no variable root this walk can follow"}
        else
          rvs
          |> Enum.map(&classify(&1, table, head_vars, request_head?, depth + 1))
          |> Enum.map(fn {c, why} -> {c, "#{where} <- #{why}"} end)
          |> combine()
        end
    end
  end

  # ONE store fact clears; otherwise an undecided component poisons the whole.
  defp combine([]), do: {:undecided, "no components"}

  defp combine(cs) do
    cond do
      hit = Enum.find(cs, &(elem(&1, 0) == :store)) -> hit
      hit = Enum.find(cs, &(elem(&1, 0) == :undecided)) -> hit
      true -> hd(cs)
    end
  end

  # `Scan.writes?/1` only matches MODULE-QUALIFIED calls, so a bare local
  # `patch_callback(doc, …)` that itself persists reads as a non-write there —
  # which is how the walk first labelled the return of a local write helper
  # REQUEST-ROOTED (media_processing_controller.ex's callback/2, caught by hand-reading
  # the three sites this arm first named). `Scan.writes?/1` is NOT widened:
  # doing so would move `write_reachable` across the whole corpus and silently
  # restate the A3 arm's population. The widening is local to this walk.
  #
  # DIRECTION OF THE ERROR THIS BUYS: a bare local call whose NAME happens to
  # start with a mutate word but which writes nothing will CLEAR a site into
  # :store_fact. That shrinks the accusation class rather than growing it — an
  # echo can hide behind it, but nothing innocent is accused because of it.
  defp store_producing?(ast), do: Scan.writes?(ast) or local_mutate_call?(ast)

  defp local_mutate_call?(ast) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        {f, _m, a} = n, acc when is_atom(f) and is_list(a) and a != [] ->
          {n, acc or (f not in [:%{}, :%, :{}, :<<>>, :__aliases__, :.., :|] and Scan.mutate_word?(f))}

        n, acc ->
          {n, acc}
      end)

    hit
  end

  defp conn_request?(rhs) do
    {_, hit} =
      Macro.prewalk(rhs, false, fn
        {{:., _, [{:conn, _, c}, f]}, _, _} = n, acc when is_atom(c) and is_atom(f) ->
          {n, acc or f in @conn_request_fields}

        # conn.params["x"] / conn.assigns[:x] desugar through Access.get/2
        {{:., _, [Access, :get]}, _, [inner | _]} = n, acc ->
          {n, acc or conn_request?(inner)}

        n, acc ->
          {n, acc}
      end)

    hit
  end

  defp snip(ast) do
    ast |> Macro.to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 100)
  end

  @doc """
  Site verdict for one census row. Returns
  `%{verdict:, body_bound:, vars: [{var, class, why}]}`.

  `body_bound` is the population predicate: at least one payload variable that
  is NOT bound in the def head. A site with body_bound=false is exactly what the
  A3 arm above already adjudicates and is excluded here.
  """
  def site(row) do
    pv = vars(row.payload_ast)
    hv = if row.head_ast, do: vars(Scan.head_of(row.head_ast)), else: []
    request_head? = conn_first_arg?(row.head_ast)
    table = bindings(row.body_ast)

    classified =
      Enum.map(pv, fn v ->
        {c, why} = classify(v, table, hv, request_head?)
        {v, c, why}
      end)

    classes = Enum.map(classified, fn {_, c, _} -> c end)

    # THE PAYLOAD ITSELF CAN BE THE STORE FACT. `%{revoked_count:
    # Auth.revoke_app_tokens_for_email(trimmed, …)}` has exactly one variable
    # (`trimmed`, a trimmed request email) and every variable is request-rooted
    # — yet the emitted NUMBER is the write's own return value. Classifying by
    # variables alone accused it (app_token_controller.ex's revoke/2 email clause, found by
    # hand-reading). A payload that reaches a write carries a post-write fact
    # whether or not a variable holds it.
    payload_writes? = store_producing?(row.payload_ast)

    verdict =
      cond do
        pv == [] -> :no_vars
        payload_writes? -> :store_fact
        :store in classes -> :store_fact
        :undecided in classes -> :residual
        true -> :request_rooted
      end

    %{verdict: verdict, body_bound: pv != [] and Enum.any?(pv, &(&1 not in hv)), vars: classified}
  end

  defp conn_first_arg?(nil), do: false

  defp conn_first_arg?(head) do
    case Scan.head_of(head) do
      {_n, _m, [{:conn, _, c} | _]} when is_atom(c) -> true
      {_n, _m, [{:_conn, _, c} | _]} when is_atom(c) -> true
      _ -> false
    end
  end

  @doc "the body-bound population: write-reachable, 2xx-or-implicit, ≥1 body-bound payload var"
  def population(rows) do
    rows
    |> Enum.filter(&(&1.write_reachable and &1.status != :explicit_non2xx))
    |> Enum.map(fn r -> Map.put(r, :prov, site(r)) end)
    |> Enum.filter(& &1.prov.body_bound)
    |> Enum.sort_by(&{&1.file, &1.line})
  end

  def by_verdict(pop, v), do: Enum.filter(pop, &(&1.prov.verdict == v))
end

# ------------------------------------------------------------------- the census
# Extracted into a function (wave 41) for one reason only: the SELFTEST must be
# able to run the whole pipeline over a fixture the arms actually fire on. On
# origin/main the A3 arm is 0 CALLSITES, so an allowlist pinned against main
# alone is VACUOUSLY GREEN — a pin that has never been observed rejecting
# anything is not a pin.
defmodule Census do
  @ok_statuses [:ok, :created, :accepted, :no_content, :multi_status, :partial_content]

  def ok_statuses, do: @ok_statuses

  def files(root), do: Path.wildcard(Path.join(root, "**/*.ex")) |> Enum.sort()

  @doc """
  Scan `files` under `root`. Returns a map with :rows (one entry per json/2
  CALLSITE), :put_status_2xx, :send_resp (regex lens) and :parse_fails.
  """
  def scan(files, root) do
    init = %{rows: [], put_status_2xx: [], parse_fails: []}

    acc =
      for f <- files, reduce: init do
        acc ->
          src = File.read!(f)

          case Code.string_to_quoted(src, columns: true) do
            {:ok, ast0} ->
              ast = Depipe.run(ast0)
              defs = Scan.defs(ast)
              lines = String.split(src, "\n")
              rel = Path.relative_to(f, root)

              sites = json_sites(ast)
              new = Enum.map(sites, &row(&1, defs, lines, rel))

              ps =
                PutStatus.twoxx(ast, @ok_statuses)
                |> Enum.map(fn {l, s} -> {rel, l, s} end)

              %{acc | rows: new ++ acc.rows, put_status_2xx: acc.put_status_2xx ++ ps}

            {:error, e} ->
              %{acc | parse_fails: [{f, e} | acc.parse_fails]}
          end
      end

    %{
      rows: Enum.sort_by(acc.rows, fn r -> {r.file, r.line} end),
      put_status_2xx: acc.put_status_2xx,
      parse_fails: Enum.reverse(acc.parse_fails),
      send_resp: send_resp_sites(files, root),
      grep_set: grep_set(files, root)
    }
  end

  # the OLD lens, kept so the run can print its own error in both directions
  defp grep_set(files, root) do
    files
    |> Enum.flat_map(fn f ->
      File.read!(f)
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, _} -> String.contains?(l, "json(conn,") end)
      |> Enum.map(fn {_, i} -> "#{Path.relative_to(f, root)}:#{i}" end)
    end)
    |> MapSet.new()
  end

  # index every json/2 call node in a depiped module AST
  defp json_sites(ast) do
    {_, sites} =
      Macro.prewalk(ast, [], fn
        {:json, m, [carg, payload]} = n, a ->
          line = Keyword.get(m, :line)

          status =
            if Enum.any?(Scan.calls(carg), fn {c, _} -> c == :put_status end) do
              # find the literal status argument
              {_, st} =
                Macro.prewalk(carg, nil, fn
                  {:put_status, _, [_c, s]} = nn, _ -> {nn, s}
                  nn, aa -> {nn, aa}
                end)

              st
            else
              :implicit_200
            end

          {n, [{line, status, payload} | a]}

        n, a ->
          {n, a}
      end)

    sites
  end

  defp row({line, status, payload}, defs, lines, rel) do
    # enclosing def = last def whose line <= site line
    {dname, darity, dline, {dbody, dhead}} =
      defs
      |> Enum.filter(fn {_, _, l, _} -> l <= line end)
      |> List.last() || {:__none__, 0, 0, {nil, nil}}

    status_class =
      cond do
        status == :implicit_200 -> :implicit_200
        is_atom(status) and status in @ok_statuses -> :explicit_2xx
        is_integer(status) and status >= 200 and status < 300 -> :explicit_2xx
        true -> :explicit_non2xx
      end

    src_line = Enum.at(lines, line - 1) || ""

    %{
      file: rel,
      line: line,
      fun: "#{dname}/#{darity}",
      fun_line: dline,
      status: status_class,
      status_lit: inspect(status),
      write_reachable: !!(dbody && Scan.writes?(dbody)),
      textual_json_conn: String.contains?(src_line, "json(conn,"),
      payload_class: Scan.payload_class(payload),
      echo_only: echo_only?(payload, dhead),
      # kept for the A3b bind-site provenance walk (Provenance.site/1); never
      # inspect()ed into output — these are whole subtrees.
      payload_ast: payload,
      head_ast: dhead,
      body_ast: dbody,
      payload_src: String.slice(String.trim(src_line), 0, 120)
    }
  end

  defp echo_only?(payload, dhead) do
    pv = Scan.vars(payload)
    hv = if dhead, do: Scan.vars(Scan.head_of(dhead)), else: []
    pv != [] and not Scan.calls?(payload) and Enum.all?(pv, &(&1 in hv))
  end

  # DERIVED, NOT HARDCODED (PDS wave 34 review). This list was printed while the
  # residue total added a literal `+ 3` beside it — so a fourth send_resp(conn,
  # 2xx) would have grown the printed list while leaving the RESIDUE number where
  # it was. The total now counts this list.
  defp send_resp_sites(files, root) do
    Enum.flat_map(files, fn f ->
      File.read!(f)
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, _} -> Regex.match?(~r/send_resp\(\s*conn\s*,\s*2\d\d/, l) end)
      |> Enum.map(fn {l, i} -> {Path.relative_to(f, root), i, String.trim(l)} end)
    end)
  end

  # --- the three adjudication arms, one definition, used by run AND selftest ---

  def violations(rows) do
    rows
    |> Enum.filter(&(&1.write_reachable and &1.payload_class == :literal_only and &1.status != :explicit_non2xx))
    |> Enum.sort_by(&{&1.file, &1.line})
  end

  def echoes(rows) do
    rows
    |> Enum.filter(&(&1.echo_only and &1.write_reachable and &1.status != :explicit_non2xx))
    |> Enum.sort_by(&{&1.file, &1.line})
  end

  def residue(scan) do
    length(Enum.uniq(violations(scan.rows) ++ echoes(scan.rows))) + length(scan.send_resp)
  end

  # total RESPONSE CALLSITES — the denominator every count below is quoted against
  def denominator(scan), do: length(scan.rows) + length(scan.send_resp)
end

# ------------------------------------------------- the pinned A3 allowlist
# THE PIN. Each entry is a "<file>:<line>" CALLSITE, relative to the scanned root,
# that is a KNOWN and ACCEPTED A3 request-echo. An echo callsite NOT on this list
# reds the main path with exit 4.
#
# IT IS EMPTY, AND THAT IS THE HONEST STATE: on origin/main the A3 arm finds 0
# CALLSITES — #9114 repaired the six it used to find. An empty allowlist checked
# only against a tree where the arm finds nothing is VACUOUSLY GREEN, so the
# pin is exercised NON-VACUOUSLY in the selftest instead: the fixture makes the
# arm FIRE, the check is run once with the empty pin (must report the callsite)
# and once with the callsite pinned (must report nothing). See Selftest.
#
# WHY A FIXTURE AND NOT THE HISTORICAL TREE: the arm is also observable firing at
# 8cb75fa5d^ (`git archive 8cb75fa5d^ api/lib` -> 6 echo CALLSITES, residue 19 of
# 465). That tree is a fine one-off proof and was run as one, but it is the wrong
# thing to WIRE IN: it makes the selftest depend on git history being present
# (shallow clones have none), on that sha surviving history rewrites, and it takes
# a full 800-file scan to assert one arm. The fixture is self-contained, parses in
# one file, and can be made to fire ANY arm on demand.
defmodule Pin do
  @request_echo_allowlist []

  def request_echo_allowlist, do: @request_echo_allowlist

  @doc "echo CALLSITES that are not on the given allowlist"
  def unpinned(echoes, allowlist \\ @request_echo_allowlist) do
    Enum.reject(echoes, fn r -> "#{r.file}:#{r.line}" in allowlist end)
  end
end

# ------------------------------------------------------------------------ argv
defmodule Argv do
  @known_flags ~w(--selftest --help -h)

  def parse(argv) do
    {flags, positional} = Enum.split_with(argv, &String.starts_with?(&1, "-"))

    cond do
      unknown = Enum.find(flags, &(&1 not in @known_flags)) ->
        {:refuse, "unknown flag #{unknown}",
         "this script accepts #{Enum.join(@known_flags, " ")} and at most ONE positional ROOT. " <>
           "Before wave 41 argv[0] was taken as the ROOT unconditionally, so #{unknown} was " <>
           "silently scanned as a DIRECTORY NAME and the run printed a clean 0 of 0."}

      Enum.any?(flags, &(&1 in ["--help", "-h"])) ->
        {:help, nil, nil}

      "--selftest" in flags and positional != [] ->
        {:refuse, "--selftest with a positional ROOT (#{Enum.join(positional, " ")})",
         "--selftest runs the arms against a synthetic fixture and never reads a corpus."}

      "--selftest" in flags ->
        {:selftest, nil, nil}

      length(positional) > 1 ->
        {:refuse, "#{length(positional)} positional arguments (#{Enum.join(positional, " ")})",
         "exactly one ROOT may be given."}

      true ->
        {:run, List.first(positional) || "api/lib", nil}
    end
  end
end

# -------------------------------------------------------------------- selftest
defmodule Selftest do
  # A synthetic corpus every arm can fire on. Five actions, chosen so each arm has
  # BOTH a positive and a negative: delete/2 is an A3 echo, update/2 is a
  # literal-only violation, show/2 is honest (dynamic payload, read-only) and must
  # appear in NEITHER, create/2 is an explicit-2xx dynamic payload (subsumption
  # arm), purge/2 is a send_resp(conn, 2xx).
  @fixture ~S'''
  defmodule FixtureWeb.ThingController do
    use FixtureWeb, :controller

    def delete(conn, %{"id" => id}) do
      {:ok, _} = Thing.delete_thing(id)
      json(conn, %{deleted: id})
    end

    def update(conn, %{"id" => id, "attrs" => attrs}) do
      {:ok, _} = Thing.update_thing(id, attrs)
      json(conn, %{ok: true})
    end

    def show(conn, %{"id" => id}) do
      doc = Thing.get_thing(id)
      json(conn, %{doc: doc})
    end

    def create(conn, params) do
      {:ok, rec} = Thing.create_thing(params)
      conn |> put_status(:created) |> json(%{id: rec.id})
    end

    def purge(conn, _params) do
      {:ok, _} = Thing.delete_all_things()
      send_resp(conn, 204, "")
    end
  end
  '''

  # THE A3b MUTANT, BOTH DIRECTIONS. Two fixtures that differ in exactly one
  # payload: `create/2` emits only request-rooted, BODY-bound values in the
  # first and adds `id: rec.id` — a post-write fact — in the second. Neither
  # site can ever be seen by the A3 head-binding arm, which is the whole point:
  # `label` and `kind` are bound by `with … <-` INSIDE the body.
  #
  # `touch/2` is identical in both and is the NON-VACUITY control in two
  # directions at once: it holds the POPULATION at 2 across the repair (so a
  # green "names none" cannot be bought by the population collapsing to zero),
  # and its `tag` is bound from `System.unique_integer/1` — a root the walk
  # cannot follow — so it must land in RESIDUAL and never in the accusation
  # class. A run where `touch/2` reads request_rooted is the lens guessing.
  @body_fixture ~S'''
  defmodule FixtureWeb.BodyController do
    use FixtureWeb, :controller

    def create(conn, params) do
      with {:ok, label} <- fetch_label(params),
           {:ok, kind} <- fetch_kind(params) do
        case Thing.create_thing(label, kind) do
          {:ok, _rec} ->
            conn |> put_status(:created) |> json(%{label: label, kind: kind})

          {:error, _} ->
            conn |> put_status(422) |> json(%{error: "nope"})
        end
      end
    end

    def touch(conn, _params) do
      tag = System.unique_integer([:positive])
      {:ok, _} = Thing.update_thing(tag)
      json(conn, %{tag: tag})
    end

    def sweep(conn, %{"email" => email}) do
      trimmed = String.trim(email)
      json(conn, %{revoked_count: Thing.delete_things_for(trimmed)})
    end
  end
  '''

  @body_fixture_repaired ~S'''
  defmodule FixtureWeb.BodyController do
    use FixtureWeb, :controller

    def create(conn, params) do
      with {:ok, label} <- fetch_label(params),
           {:ok, kind} <- fetch_kind(params) do
        case Thing.create_thing(label, kind) do
          {:ok, rec} ->
            conn |> put_status(:created) |> json(%{id: rec.id, label: label, kind: kind})

          {:error, _} ->
            conn |> put_status(422) |> json(%{error: "nope"})
        end
      end
    end

    def touch(conn, _params) do
      tag = System.unique_integer([:positive])
      {:ok, _} = Thing.update_thing(tag)
      json(conn, %{tag: tag})
    end

    def sweep(conn, %{"email" => email}) do
      trimmed = String.trim(email)
      json(conn, %{revoked_count: Thing.delete_things_for(trimmed)})
    end
  end
  '''

  def run do
    arms = classifier_arms() ++ fixture_arms() ++ body_bound_arms()

    IO.puts("=== SELFTEST: #{length(arms)} arms (no corpus is read) ===")

    Enum.each(arms, fn {label, got, want} ->
      IO.puts("  #{verdict(got, want)}  #{label} (got #{inspect(got)}, want #{inspect(want)})")
    end)

    failed = Enum.count(arms, fn {_, got, want} -> got != want end)
    IO.puts("")
    IO.puts("SELFTEST: #{length(arms) - failed} PASS / #{failed} FAIL of #{length(arms)} arms")

    if failed == 0 do
      IO.puts("SELFTEST GREEN — exit 0")
      0
    else
      IO.puts("SELFTEST RED — #{failed} arm(s) failed; exit 1")
      1
    end
  end

  defp verdict(got, want), do: if(got == want, do: "PASS", else: "FAIL")

  # the five write-classifier probes that wave 34 already had — unreachable by
  # flag and gating nothing until wave 41
  defp classifier_arms do
    w = fn src -> Scan.writes?(Code.string_to_quoted!(src)) end

    [
      {"Repo.update_all => write", w.("Repo.update_all(q, set: [a: 1])"), true},
      {"Map.put => NOT a write", w.("Map.put(m, :a, 1)"), false},
      {"X.record_interaction => write", w.("Search.Intelligence.record_interaction(a, b, c, d)"), true},
      {"Repo.all => NOT a write", w.("Repo.all(q)"), false},
      {"put_status => NOT a write", w.("conn |> Plug.Conn.put_status(:ok)"), false}
    ]
  end

  # the arms that make the pin non-vacuous: run the REAL pipeline over the fixture
  defp fixture_arms do
    {root, scan} = scan_fixture()

    viol = Census.violations(scan.rows)
    echo = Census.echoes(scan.rows)
    funs = fn rs -> rs |> Enum.map(& &1.fun) |> Enum.sort() end
    echo_site = fn -> Enum.map(echo, &"#{&1.file}:#{&1.line}") end

    arms = [
      {"fixture: json/2 CALLSITES of #{Census.denominator(scan)} response callsites", length(scan.rows), 4},
      {"fixture: send_resp(conn,2xx) CALLSITES", length(scan.send_resp), 1},
      {"fixture: put_status(2xx) nodes", length(scan.put_status_2xx), 1},
      {"fixture: parse failures", length(scan.parse_fails), 0},
      {"fixture: A3 request-echo arm FIRES (this is the non-vacuity proof)", funs.(echo), ["delete/2"]},
      {"fixture: literal-only violation arm FIRES", funs.(viol), ["update/2"]},
      {"fixture: the honest show/2 site is in NEITHER arm", "show/2" in funs.(viol ++ echo), false},
      {"fixture: STATUS-ONLY RESIDUE CALLSITES", Census.residue(scan), 3},
      {"pin: an UNPINNED echo callsite is REPORTED (empty allowlist)", length(Pin.unpinned(echo, [])), 1},
      {"pin: the SAME callsite PINNED is NOT reported", length(Pin.unpinned(echo, echo_site.())), 0}
    ]

    File.rm_rf!(root)
    arms
  end

  # A3b arms. `funs` is the SITE ROSTER, not a count: an arm asserting "1 site"
  # would stay green if the arm swapped one site for another.
  defp body_bound_arms do
    funs = fn pop -> pop |> Enum.map(& &1.fun) |> Enum.sort() end
    echo = scan_src(@body_fixture) |> Map.get(:rows) |> Provenance.population()
    fixed = scan_src(@body_fixture_repaired) |> Map.get(:rows) |> Provenance.population()

    [
      {"A3b: the body-bound POPULATION on the echo fixture", funs.(echo),
       ["create/2", "sweep/2", "touch/2"]},
      {"A3b: the body-bound POPULATION is UNCHANGED by the repair (non-vacuity: a green\n        'names none' below cannot be bought by the population collapsing)", funs.(fixed),
       ["create/2", "sweep/2", "touch/2"]},
      {"A3b MUTANT +: the echo fixture's create/2 is NAMED request-rooted",
       funs.(Provenance.by_verdict(echo, :request_rooted)), ["create/2"]},
      {"A3b MUTANT -: the REPAIRED fixture names NO request-rooted site",
       funs.(Provenance.by_verdict(fixed, :request_rooted)), []},
      {"A3b: the repair moves create/2 into store_fact (it did not merely vanish)",
       funs.(Provenance.by_verdict(fixed, :store_fact)), ["create/2", "sweep/2"]},
      # REGRESSION, hand-read: app_token_controller.ex's revoke/2 email clause was ACCUSED by the
      # first cut of this walk. Its only variable is a trimmed request email —
      # but the emitted number is the WRITE'S OWN RETURN. A payload that reaches
      # a write carries a post-write fact even when no variable holds it.
      {"A3b FP-1: a payload whose VALUE is the write's return is store_fact, not accused",
       funs.(Provenance.by_verdict(echo, :store_fact)), ["sweep/2"]},
      # REGRESSION, hand-read: media_processing_controller.ex's callback/2 was ACCUSED
      # because `Scan.writes?/1` only matches module-qualified calls, so the
      # local write helper `patch_callback/5` read as a non-write.
      {"A3b FP-2: a BARE LOCAL mutate-vocab call is a store producer",
       Provenance.classify(:doc, Provenance.bindings(Code.string_to_quoted!("doc = patch_callback(doc, file)")), [:file], true)
       |> elem(0), :store},
      # `combine/1`'s undecided-poisons rule, probed in BOTH argument orders so
      # the arm cannot be satisfied by whichever component happens to come
      # first in the walk's accumulator.
      {"A3b: UNDECIDED poisons a mixed binding (request first)",
       Provenance.classify(:slug, Provenance.bindings(Code.string_to_quoted!("slug = build_slug(id, salt)")), [:id], true)
       |> elem(0), :undecided},
      {"A3b: UNDECIDED poisons a mixed binding (undecided first)",
       Provenance.classify(:slug, Provenance.bindings(Code.string_to_quoted!("slug = build_slug(salt, id)")), [:id], true)
       |> elem(0), :undecided},
      {"A3b: an undecidable bind site lands in RESIDUAL, never in the accusation class",
       funs.(Provenance.by_verdict(echo, :residual)), ["touch/2"]},
      {"A3b: the A3 HEAD-bound arm sees NEITHER fixture site (this is the blind shape)",
       length(Census.echoes(scan_src(@body_fixture).rows)), 0}
    ]
  end

  defp scan_src(src) do
    root = Path.join(System.tmp_dir!(), "pds-residue-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "fixture_web/controllers"))
    File.write!(Path.join(root, "fixture_web/controllers/body_controller.ex"), src)
    scan = Census.scan(Census.files(root), root)
    File.rm_rf!(root)
    scan
  end

  defp scan_fixture do
    root = Path.join(System.tmp_dir!(), "pds-residue-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "fixture_web/controllers"))
    File.write!(Path.join(root, "fixture_web/controllers/thing_controller.ex"), @fixture)
    {root, Census.scan(Census.files(root), root)}
  end
end

# ------------------------------------------------------------------ the report
defmodule Report do
  # THE CORPUS FLOOR. This is a NON-EMPTY-CORPUS guard, not a drift gate: api/lib
  # holds hundreds of modules and hundreds of json/2 callsites, so anything under
  # these floors means the ROOT is wrong, not that the code shrank. A floor set
  # near the live population would red on a legitimate deletion, which is how a
  # guard gets disabled.
  @min_files 50
  @min_json_sites 50

  def min_files, do: @min_files
  def min_json_sites, do: @min_json_sites

  def run(root) do
    cond do
      not File.dir?(root) ->
        refuse("root #{root} is not a readable directory",
          "before wave 41 a bogus root printed 'files parsed: 0' and 'STATUS-ONLY RESIDUE: 0' and exited 0 — " <>
            "a clean bill of health for a corpus that was never read.")

      (files = Census.files(root)) |> length() < @min_files ->
        refuse("root #{root} holds #{length(files)} .ex files, below the floor of #{@min_files}",
          "an under-populated corpus cannot distinguish 'no violations' from 'nothing scanned'.")

      true ->
        files = Census.files(root)
        scan = Census.scan(files, root)
        report(root, files, scan)
    end
  end

  defp refuse(what, why) do
    IO.puts(:stderr, "REFUSED: #{what}")
    IO.puts(:stderr, "  WHY: #{why}")
    2
  end

  # "n CALLSITES of d" — never a bare integer (wave 41)
  defp cs(n, d), do: "#{n} CALLSITES of #{d}"

  defp report(root, files, scan) do
    rows = scan.rows
    total = length(rows)
    den = Census.denominator(scan)

    Enum.each(scan.parse_fails, fn {f, e} -> IO.puts(:stderr, "PARSE FAIL #{f}: #{inspect(e)}") end)

    IO.puts("=== PDS status-only residue census (root=#{root}) ===")
    IO.puts("UNIT: this lens counts CALLSITES in source. The receipt census counts ROUTED ROWS")
    IO.puts("      (route -> action). They are DISJOINT UNITS and their numbers do not compare:")
    IO.puts("      one callsite reached by two routes is 1 CALLSITE and 2 ROWS; a callsite in an")
    IO.puts("      unrouted helper is 1 CALLSITE and 0 ROWS.")
    IO.puts("REDS ON: a refused argv/root/corpus (exit 2), an unparsed file (exit 3), an A3")
    IO.puts("      request-echo callsite off the pinned allowlist (exit 4). The residue COUNT")
    IO.puts("      itself never sets the exit code — every count here is a FLOOR, and")
    IO.puts("      thresholding a floor prints a score the lens cannot back.")
    IO.puts("")
    IO.puts("files parsed: #{length(files) - length(scan.parse_fails)} of #{length(files)} .ex files (floor #{@min_files})")
    IO.puts("json/2 call sites (AST, pipes normalized): #{cs(total, den)}")
    textual = Enum.count(rows, & &1.textual_json_conn)
    IO.puts("  of which line textually matches 'json(conn,': #{cs(textual, total)}")

    if total < @min_json_sites do
      IO.puts(:stderr, "")
      refuse("root #{root} yields #{total} json/2 CALLSITES, below the floor of #{@min_json_sites}",
        "a corpus this thin cannot distinguish 'no violations' from 'nothing scanned'.")
    else
      body(root, rows, scan, total, den)
    end
  end

  defp body(_root, rows, scan, total, den) do
    by_status = Enum.frequencies_by(rows, & &1.status)
    by_write = Enum.frequencies_by(rows, & &1.write_reachable)
    explicit_2xx = Enum.filter(rows, &(&1.status == :explicit_2xx))

    IO.puts("")
    IO.puts("--- STATUS LENS ---")
    for {k, v} <- Enum.sort_by(by_status, &elem(&1, 0)), do: IO.puts("  #{k}: #{cs(v, total)}")

    IO.puts("")
    IO.puts("--- SUBSUMPTION ARM ---")
    all_ps = scan.put_status_2xx
    IO.puts("put_status(2xx) AST nodes in corpus (all):            #{length(all_ps)} NODES (unit: AST nodes, not callsites)")
    IO.puts("put_status(2xx) nodes that terminate in a json/2 call: #{cs(length(explicit_2xx), total)}")
    # a json site records the json node's line; the put_status may be on an earlier
    # line of the same pipeline. Pair by (file, enclosing-def) instead.
    ps_files = Enum.frequencies_by(all_ps, fn {f, _, _} -> f end)
    js_files = Enum.frequencies_by(explicit_2xx, fn r -> r.file end)
    unpaired = for {f, n} <- ps_files, (js_files[f] || 0) < n, do: {f, n, js_files[f] || 0}
    IO.puts("files where put_status(2xx) count > json-terminating count: #{length(unpaired)} FILES")
    Enum.each(unpaired, fn {f, n, j} -> IO.puts("  UNPAIRED #{f}: put_status=#{n} json=#{j}") end)

    IO.puts(
      "SUBSUMPTION VERDICT: #{if length(all_ps) == length(explicit_2xx) and unpaired == [], do: "HOLDS (every put_status(2xx) terminates in json/2)", else: "REFUTED"}"
    )

    IO.puts("")
    IO.puts("--- WRITE-REACHABILITY LENS (enclosing def body reaches Repo write or mutate-vocab call) ---")
    for {k, v} <- Enum.sort_by(by_write, &elem(&1, 0)), do: IO.puts("  write_reachable=#{k}: #{cs(v, total)}")

    IO.puts("")
    IO.puts("--- CROSS (status x write_reachable) ---")

    for s <- [:implicit_200, :explicit_2xx, :explicit_non2xx], w <- [true, false] do
      n = Enum.count(rows, &(&1.status == s and &1.write_reachable == w))
      IO.puts("  #{s} / write=#{w}: #{cs(n, total)}")
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

    IO.puts("name-lens READ-ish sites: #{cs(length(name_read), total)}")
    hidden = Enum.filter(name_read, & &1.write_reachable)
    IO.puts("  ...of which WRITE-REACHABLE (hidden mutations the name lens misses): #{cs(length(hidden), length(name_read))}")
    Enum.each(hidden, fn r -> IO.puts("    #{r.file}:#{r.line}  #{r.fun}") end)

    IO.puts("")
    IO.puts("--- send_resp(conn, 2xx) sites (REGEX lens, not AST) ---")
    Enum.each(scan.send_resp, fn {f, i, l} -> IO.puts("  #{f}:#{i}  #{l}") end)

    IO.puts("")
    IO.puts("CENSUS OK  json/2=#{cs(total, den)}  textual=#{cs(textual_count(rows), total)}  explicit2xx=#{cs(length(explicit_2xx), total)}")

    IO.puts("")
    IO.puts("--- MECHANICAL TEST: literal-only payloads in WRITE-REACHABLE functions ---")
    IO.puts("(payload contains no variable and no call => the printed sentence CANNOT change)")
    viol = Census.violations(rows)
    IO.puts("count: #{cs(length(viol), total)}")

    Enum.each(viol, fn r ->
      IO.puts("  #{r.file}:#{r.line}  #{r.fun}  status=#{r.status_lit}")
      IO.puts("      #{r.payload_src}")
    end)

    IO.puts("")
    IO.puts("--- LENS GAP: textual 'json(conn,' grep vs AST json/2 ---")
    lens_gap(rows, scan)

    n2xx_textual = Enum.count(explicit_2xx, & &1.textual_json_conn)
    IO.puts("")
    IO.puts("of the #{length(explicit_2xx)} put_status(2xx) json sites, textually visible to 'json(conn,': #{cs(n2xx_textual, length(explicit_2xx))}")

    IO.puts(
      "  => the 'they are a subset of the json(conn, population' claim is #{if n2xx_textual == length(explicit_2xx), do: "textually true", else: "textually FALSE (#{length(explicit_2xx) - n2xx_textual} invisible to that grep); true only at the AST lens"}"
    )

    IO.puts("")
    IO.puts("--- A3 REQUEST-ECHO ARM (payload vars all bound in the def HEAD, no calls) ---")
    echo = Census.echoes(rows)
    IO.puts("count: #{cs(length(echo), total)}")
    Enum.each(echo, fn r -> IO.puts("  #{r.file}:#{r.line}  #{r.fun}  #{r.payload_src}") end)
    unpinned = Pin.unpinned(echo)
    IO.puts("pinned allowlist: #{length(Pin.request_echo_allowlist())} CALLSITES; off-allowlist: #{length(unpinned)} CALLSITES")
    Enum.each(unpinned, fn r -> IO.puts("  OFF-ALLOWLIST #{r.file}:#{r.line}  #{r.fun}") end)

    # THE RECONCILIATION BELONGS AT THE NUMBER, NOT ONLY IN THE HEAD (wave-41 review).
    # The receipt census's derivation partition also prints a `request_echo` figure, in
    # ROUTED ROWS. This arm's count is in CALLSITES over a WIDER corpus (every .ex under
    # the root, not only routed controller actions) and a NARROWER predicate (payload vars
    # ALL head-bound, no calls). The two are not the same measurement and must not be
    # reconciled by moving either one: a builder who tunes this predicate until it
    # reproduces the census's integer has manufactured agreement, which is the exact
    # failure this lens exists to catch. Disagreement here is expected and is not a defect.
    IO.puts(
      "  UNIT: #{cs(length(echo), total)} here is CALLSITES. The receipt census's request_echo is"
    )

    IO.puts(
      "  ROUTED ROWS over routed actions only — a different corpus and a different predicate."
    )

    IO.puts(
      "  The two numbers are NOT expected to match, and neither may be tuned toward the other."
    )

    IO.puts("")
    a3b(rows, total)

    IO.puts("")
    IO.puts("--- RESIDUE SUMMARY (denominator #{den} response callsites = #{total} json/2 + #{length(scan.send_resp)} send_resp) ---")
    lit = Enum.count(rows, &(&1.payload_class == :literal_only))
    lit2xx = Enum.count(rows, &(&1.payload_class == :literal_only and &1.status != :explicit_non2xx))
    IO.puts("json/2 sites total:                                   #{cs(total, den)}")
    IO.puts("  literal-only payload (any status):                  #{cs(lit, total)}")
    IO.puts("  literal-only AND 2xx/implicit-200:                  #{cs(lit2xx, total)}")
    IO.puts("  literal-only AND 2xx AND write-reachable:           #{cs(length(viol), total)}")
    IO.puts("  A3 request-echo AND 2xx AND write-reachable:        #{cs(length(echo), total)}")
    IO.puts("send_resp(conn, 2xx) sites:                           #{cs(length(scan.send_resp), den)}")
    IO.puts("STATUS-ONLY RESIDUE (literal-only + A3-echo + send_resp): #{cs(Census.residue(scan), den)}")

    IO.puts("")
    IO.puts("--- REGISTER TSV (file\\tline\\tfun\\tstatus\\twrite\\tpayload_class) ---")

    Enum.each(viol, fn r ->
      IO.puts("REG\t#{r.file}\t#{r.line}\t#{r.fun}\t#{r.status_lit}\t#{r.write_reachable}\t#{r.payload_class}")
    end)

    exit_code(scan, unpinned)
  end

  # --- A3b: the BODY-BOUND population, PRINTED (never sets the exit code) ---
  # The A3 arm above cannot see a payload whose variables are bound in the def
  # BODY. This section measures how big that blind population is and classifies
  # every one of its payload variables by BIND-SITE PROVENANCE, printing the
  # binding that produced each classification. It is PRINTED and not ARMED on
  # purpose — see the header comment on `Provenance`.
  defp a3b(rows, total) do
    IO.puts("--- A3b BODY-BOUND BIND-SITE PROVENANCE (PRINTED — DOES NOT SET THE EXIT CODE) ---")
    pop = Provenance.population(rows)

    IO.puts("population: write-reachable, 2xx-or-implicit-200 json/2 callsites with at least")
    IO.puts("  one payload variable NOT bound in the def head: #{cs(length(pop), total)}")
    IO.puts("  (every one of these is INVISIBLE to the A3 arm above, by construction)")
    IO.puts("")
    IO.puts("VERDICTS — one store fact CLEARS a site; an undecided variable makes it RESIDUAL,")
    IO.puts("  never REQUEST-ROOTED. Nothing here is guessed into the accusation class.")

    for v <- [:request_rooted, :residual, :store_fact] do
      IO.puts("  #{v}: #{cs(length(Provenance.by_verdict(pop, v)), length(pop))}")
    end

    IO.puts("")
    IO.puts("REQUEST-ROOTED SITES (the accusation class — every payload variable request-rooted,")
    IO.puts("  no post-write fact anywhere in the payload):")
    print_sites(Provenance.by_verdict(pop, :request_rooted))

    IO.puts("")
    IO.puts("RESIDUAL SITES (the walk could NOT decide — these are UNDECIDED, not clean):")
    print_sites(Provenance.by_verdict(pop, :residual))

    IO.puts("")
    IO.puts("A3b UNIT + FLOOR: CALLSITES, same unit as the A3 arm, over the same corpus but a")
    IO.puts("  WIDER population (body-bound as well as head-bound) and a walk that is intra-def")
    IO.puts("  and depth-capped. It is a FLOOR in both directions: a laundered request value")
    IO.puts("  reads RESIDUAL, and a mutate-vocab miss in `Scan.writes?/1` can mis-clear a site.")
  end

  defp print_sites([]), do: IO.puts("  (none)")

  defp print_sites(sites) do
    Enum.each(sites, fn r ->
      IO.puts("  #{r.file}:#{r.line}  #{r.fun}  verdict=#{r.prov.verdict}")
      IO.puts("      #{r.payload_src}")

      Enum.each(r.prov.vars, fn {v, c, why} ->
        IO.puts("      var `#{v}` => #{String.upcase(to_string(c))}  #{why}")
      end)
    end)
  end

  defp textual_count(rows), do: Enum.count(rows, & &1.textual_json_conn)

  defp lens_gap(rows, scan) do
    ast_set = MapSet.new(rows, fn r -> "#{r.file}:#{r.line}" end)
    grep_n = MapSet.size(scan.grep_set)
    IO.puts("grep LINES: #{grep_n}   AST CALLSITES: #{MapSet.size(ast_set)}")
    only_grep = MapSet.difference(scan.grep_set, ast_set) |> Enum.sort()
    IO.puts("in GREP but not an AST json/2 node line: #{length(only_grep)} LINES of #{grep_n}")
    Enum.each(only_grep, &IO.puts("    #{&1}"))

    IO.puts(
      "in AST but invisible to the grep: #{cs(MapSet.size(MapSet.difference(ast_set, scan.grep_set)), MapSet.size(ast_set))}"
    )
  end

  defp exit_code(scan, unpinned) do
    cond do
      scan.parse_fails != [] ->
        IO.puts(:stderr, "")
        IO.puts(:stderr, "RED: #{length(scan.parse_fails)} file(s) in the corpus did not parse — this lens")
        IO.puts(:stderr, "     scanned LESS than it claims to have scanned. Exit 3.")
        3

      unpinned != [] ->
        IO.puts(:stderr, "")
        IO.puts(:stderr, "RED: #{length(unpinned)} A3 request-echo CALLSITE(s) are not on the pinned")
        IO.puts(:stderr, "     allowlist in `Pin`. Adjudicate each one, then pin it or repair it. Exit 4.")
        4

      true ->
        0
    end
  end
end

# -------------------------------------------------------------------- dispatch
usage = """
usage: elixir scripts/pds-status-only-residue.exs [ROOT]
       elixir scripts/pds-status-only-residue.exs --selftest
       elixir scripts/pds-status-only-residue.exs --help

  ROOT        directory to scan (default api/lib); must hold at least
              #{Report.min_files()} .ex files and yield #{Report.min_json_sites()} json/2 CALLSITES
  --selftest  run the classifier + fixture arms; exit 0 green / 1 red
  exit codes  0 ok · 1 selftest red · 2 refused · 3 unparsed corpus · 4 A3 echo off the pin
"""

code =
  case Argv.parse(System.argv()) do
    {:help, _, _} ->
      IO.puts(usage)
      0

    {:refuse, what, why} ->
      IO.puts(:stderr, "REFUSED: #{what}")
      IO.puts(:stderr, "  WHY: #{why}")
      IO.puts(:stderr, "")
      IO.puts(:stderr, usage)
      2

    {:selftest, _, _} ->
      Selftest.run()

    {:run, root, _} ->
      Report.run(root)
  end

System.halt(code)
