#!/usr/bin/env bash
# test-env-leak-gate.sh — an ExUnit test that mutates GLOBAL state and never
# restores it does not fail. It makes some OTHER test fail, later, at random.
#
# THE INCIDENT THIS GATE IS BUILT FROM
# ------------------------------------
# api/test/barkpark_web/write_hotpath_telemetry_test.exs calls
#
#     Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
#
# in two tests, with NO `on_exit` restore. `Application` is VM-global: the value
# survives the test, the module, and the whole file. `DataCase` happens to reset
# `:plugins` in its own setup — but BEFORE its own tests, which protects DataCase
# from the leak and protects nobody else. Any bare `use ExUnit.Case` module that
# the scheduler happens to run next inherits `[SlowGatePlugin]` and fails on
# `declared == []`.
#
# CI pins no `--seed`, so ExUnit reshuffles every run. The failure therefore
# appears in a file that is not broken, in a PR that did not touch it, on some
# runs and not others. The fleet spent a full diagnosis on it. That cost is the
# whole argument for this gate: the leak is cheap to SEE statically and
# expensive to DEBUG dynamically.
#
# WHAT IT DETECTS (and what it deliberately does not)
# ---------------------------------------------------
# IN SCOPE — process-independent, VM-global stores with an obvious paired
# restore, where a static reading is honest:
#   * Application.put_env/3,4   and Application.put_all_env/1,2
#   * :persistent_term.put/2
# FIVE restore idioms are recognised, every one added only after it produced a
# MEASURED false positive on this tree: `on_exit` (module-wide); `try … after`
# (scoped to the enclosing test/setup/def block); a `def`/`defp` helper an
# on_exit calls; a CASE TEMPLATE's on_exit, credited to whoever `use`s it; and a
# SUPPORT MODULE's writes, credited to whoever calls it from a restore context.
#
# A site is a LEAK when its module registers no matching restore: an `on_exit`
# (or `ExUnit.Callbacks.on_exit`) callback anywhere in the module whose body
# calls `Application.put_env` / `Application.delete_env` /
# `Application.put_all_env` / `:persistent_term.put` / `:persistent_term.erase`
# for the SAME app and key.
#
# OUT OF SCOPE, STATED PLAINLY RATHER THAN SHIPPED NOISY:
#   * NAMED-PROCESS mutation (`Process.register/2`, `GenServer.start_link(name:
#     …)`, `Agent.start_link(name: …)`, `Registry` writes, ETS tables owned by a
#     named process). The static signal does not separate "registers a global
#     name and leaks it" from "starts a supervised child ExUnit tears down with
#     the test process", and `start_supervised!/1` — the correct idiom, which
#     self-restores — is indistinguishable from `start_link` at the call site
#     without type information. A detector that cannot tell those apart reds
#     honest tests, gets waived, and the waiver file becomes the real policy.
#     NOT SHIPPED. If it is wanted later it needs a DIFFERENT instrument (a
#     runtime probe diffing the registered-name set around each module), not a
#     wider regex here.
#   * `System.put_env/2` — genuinely global, but every current use in api/test
#     sits inside a `setup` that also restores. Add it when a leak is measured,
#     not before.
#
# KNOWN BLIND SPOT, NAMED RATHER THAN LEFT FOR SOMEONE TO DISCOVER
# ----------------------------------------------------------------
# This gate reads "an on_exit that restores this key EXISTS in the module" and
# stops there. It does NOT model on_exit/2's REF semantics: the first argument
# is a KEY, and a second `on_exit(ref, fun)` with the same ref REPLACES the
# first registration rather than adding to it. So
#
#     on_exit(ctx, fn -> …restore :plugins… end)
#     on_exit(ctx, fn -> …something else…    end)   # silently unregisters it
#
# reads as CLEAN here while `:plugins` escapes the module — the exact failure
# this gate was built for, wearing the shape of its own fix. That was measured
# in api/test/barkpark/plugins/hooks_test.exs and is tracked separately as
# task-2ff85d0297f4aeea. Catching it needs ref-identity tracking across
# registrations, which is a real extension of the walk, not a tightening of it.
# Until then: a green from this gate means "a restore is written", NOT "a
# restore runs".
#
# WHY AN AST WALK AND NOT A REGEX
# -------------------------------
# `Application.put_env` appears ~820 times across 226 files in api/test. The vast
# majority are correctly paired. A grep cannot tell a MUTATION from its own
# RESTORE — the restore is a `put_env` too, just inside `on_exit` — so a regex
# gate would flag most of the well-behaved tree. This parses with
# `Code.string_to_quoted/2` and walks carrying "am I inside an on_exit callback",
# which makes the mutation/restore distinction exact.
#
# REFUSE, NEVER DEGRADE
# ---------------------
#   * a file the parser cannot read is a HARD FAILURE, named, not a silent skip;
#   * a population of ZERO scanned files is a HARD FAILURE. A gate whose input
#     tree moved or vanished must say so, never print OK over an empty scan.
#
# NEVER-WORSE, NOT CLEAN-TREE
# ---------------------------
# Leaks exist today. Demanding zero would red main on day one and get the gate
# disabled, and a disabled gate still looks like coverage.
# scripts/test-env-leak-allowlist.txt holds LITERAL, reviewed, hand-committed
# rows — never a floor computed from the tree, which agrees with a gutted tree by
# construction. Each row carries a REASON; a row without one is REFUSED, because
# an allowlist whose rows nobody had to justify is a mute button.
#
# The row key is (count, file, app/key) and deliberately NOT file:line. A
# line-anchored pin slides the moment anyone inserts a line above it, and the
# gate then names files the PR never touched.
#
# Usage:
#   scripts/test-env-leak-gate.sh             # check (CI)
#   scripts/test-env-leak-gate.sh --list      # every leak site, file:line
#   scripts/test-env-leak-gate.sh --baseline  # emit allowlist rows (reason = TODO)
#   scripts/test-env-leak-gate.sh --selftest  # prove the gate can fail
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so --selftest and the companion harness drive synthetic trees in a
# temp dir and plant nothing in the real source.
SCANDIR="${TEST_ENV_LEAK_SCANDIR:-$ROOT/api/test}"
ALLOWLIST="${TEST_ENV_LEAK_ALLOWLIST:-$ROOT/scripts/test-env-leak-allowlist.txt}"
# The shortest string that can carry an actual justification. A row reading "x"
# or "todo" is a bare row wearing a costume.
MIN_REASON=12

command -v elixir >/dev/null 2>&1 || {
  echo "test-env-leak-gate: elixir is not on PATH — REFUSING." >&2
  echo "  This gate parses Elixir with Code.string_to_quoted/2; without it the" >&2
  echo "  scanner inspects nothing, and reporting a clean tree it never read is" >&2
  echo "  precisely the failure it exists to prevent." >&2
  exit 3
}

SCANNER="$(mktemp -t telg-scan-XXXXXX).exs"
WORKD="$(mktemp -d)"
cleanup() { rm -f "$SCANNER"; rm -rf "$WORKD"; }
trap cleanup EXIT

cat > "$SCANNER" <<'ELIXIR'
# Emits, tab-separated:
#   HIT\t<relpath>\t<line>\t<app/key>     one unrestored global mutation
#   PARSE_FAIL\t<relpath>                 a file the parser could not read
#   PARSE_FAILURES\t<n>
#   SCANNED\t<n>
root = System.get_env("TELG_SCANDIR")
files = Path.wildcard(Path.join(root, "**/*.{ex,exs}")) |> Enum.sort()

defmodule Sig do
  # A literal key renders to its own text and matches exactly. A NON-literal key
  # (a variable, a module attribute, a call) renders to a WILDCARD for its app:
  # a helper like `defp with_env(k, v), do: on_exit(fn -> put_env(:app, k, …) end)`
  # is a real restore whose key this scanner cannot resolve, and guessing wrong
  # would red an honest module. Conservative toward false NEGATIVES on purpose —
  # a ratchet that cries wolf gets turned off, and then it measures nothing.
  #
  # A MODULE ATTRIBUTE counts as literal, by TEXT. `@snapshot_key` denotes the
  # same value everywhere inside one module, so `:persistent_term/@snapshot_key`
  # is an exact key and matches its restore exactly. Without this the whole
  # `:persistent_term` family collapsed to one app-wide wildcard and two tests
  # that genuinely never restore (the two tests under `describe "register/2
  # invalidates the cache"` in registry_cache_test.exs) were pardoned by a
  # sibling test's restore — a measured false NEGATIVE.
  def literal?(x) when is_atom(x) or is_binary(x) or is_integer(x), do: true
  def literal?({:__aliases__, _, parts}), do: Enum.all?(parts, &is_atom/1)
  def literal?({:__block__, _, [v]}), do: literal?(v)
  def literal?({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: true
  def literal?(_), do: false

  def render({:__block__, _, [v]}), do: render(v)
  def render({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: "@" <> Atom.to_string(name)
  def render(x), do: if(literal?(x), do: Macro.to_string(x), else: "*")

  def of(app, key), do: render(app) <> "/" <> render(key)
end

defmodule Cover do
  # Does `restores` pardon `sig`? Shared by the module-wide on_exit check and by
  # the lexically-scoped try/after check, so the two cannot drift apart.
  #
  #   * exact match — the ordinary, precise case;
  #   * "*" — a put_all_env restore names no key, so it covers everything;
  #   * "<app>/*" — a restore whose KEY the scanner could not resolve (a plain
  #     variable, e.g. a helper's parameter). Conservative toward false
  #     NEGATIVES on purpose: a ratchet that cries wolf gets turned off.
  def covered?(sig, restores) do
    app = sig |> String.split("/") |> hd()

    MapSet.member?(restores, sig) or MapSet.member?(restores, "*") or
      MapSet.member?(restores, app <> "/*")
  end
end

defmodule Helpers do
  # PASS A — which LOCAL functions does an on_exit callback call?
  #
  # The dominant restore idiom in api/test is NOT an inline put_env. It is a
  # module-local helper:
  #
  #     defp set_or_delete(k, nil), do: Application.delete_env(:barkpark, k)
  #     defp set_or_delete(k, v),   do: Application.put_env(:barkpark, k, v)
  #     …
  #     on_exit(fn -> set_or_delete(:webhook_max_attempts, prev) end)
  #
  # A one-pass walk reads that helper's BODY as a top-level mutation (it is not
  # lexically inside on_exit) and reports the module as leaking — measured, that
  # was 21 of the first 162 hits, including the two largest. So pass A collects
  # the names an on_exit callback invokes, and pass B treats the bodies of
  # def/defp clauses with those names as restore context.
  def collect(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:on_exit, _m, args} = n, acc when is_list(args) -> {n, locals(args, acc)}
        {{:., _, [{:__aliases__, _, [:ExUnit, :Callbacks]}, :on_exit]}, _m, args} = n, acc
        when is_list(args) ->
          {n, locals(args, acc)}

        # …and the same for a `try … after <restore> end` clause, which can call
        # a helper just as readily as an on_exit callback can.
        {:try, _m, [clauses]} = n, acc when is_list(clauses) ->
          if Keyword.keyword?(clauses),
            do: {n, locals(Keyword.get(clauses, :after, []), acc)},
            else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    names
  end

  defp locals(subtree, acc) do
    {_t, acc} =
      Macro.prewalk(subtree, acc, fn
        {name, _m, args} = n, acc when is_atom(name) and is_list(args) ->
          # Only real function-call names; operators and special forms are atoms
          # too (`:=`, `:->`, `:__block__`) and must not be harvested.
          if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*[?!]?$/, Atom.to_string(name)),
            do: {n, MapSet.put(acc, name)},
            else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    acc
  end
end

defmodule Walk do
  # ── after_sigs/1 ──────────────────────────────────────────────────────────
  # Every restore signature written in a `try … after <restore> end` clause
  # anywhere inside a subtree.
  #
  # `try/after` is the third real restore idiom in api/test, alongside on_exit
  # and the on_exit-called helper:
  #
  #     original = :persistent_term.get(@snapshot_key)
  #     :persistent_term.put(@snapshot_key, poisoned)     # the mutation
  #     try do  … assertions …
  #     after   :persistent_term.put(@snapshot_key, original)   # the restore
  #     end
  #
  # Note the mutation sits BEFORE the `try`, not inside it — so pardoning only
  # what is lexically inside the try block misses the real pairing. The scope
  # that matches the idiom is the enclosing ExUnit BLOCK (`test`, `setup`,
  # `setup_all`), which is what Walk unions this into.
  #
  # It is deliberately NOT module-wide, unlike on_exit: an `after:` clause runs
  # for its own block only. Measured — scoping it module-wide silently pardoned
  # both tests under `describe "register/2 invalidates the cache"` in
  # registry_cache_test.exs, which poison `@snapshot_key` and never put it back,
  # because three OTHER tests in the file each restore it in their own
  # try/after. Pardoning a leak because a NEIGHBOUR cleans up is precisely
  # the cross-test coupling this gate exists to catch.
  defp after_sigs(node) do
    {_n, acc} =
      Macro.prewalk(node, MapSet.new(), fn
        {:try, _m, [clauses]} = n, acc when is_list(clauses) ->
          if Keyword.keyword?(clauses) do
            case Keyword.fetch(clauses, :after) do
              {:ok, body} -> {n, MapSet.union(acc, restore_sigs(body))}
              :error -> {n, acc}
            end
          else
            {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    acc
  end

  @app_mutate [:put_env, :put_all_env]
  @app_restore [:put_env, :put_all_env, :delete_env]
  @pt_mutate [:put]
  @pt_restore [:put, :erase]

  # Blocks that bound a `try/after` restore's reach.
  #
  # `def`/`defp` are in this list because the tree factors the idiom into a
  # helper as often as it writes it inline — measured, twice byte-for-byte:
  #
  #     defp with_failing_persist(fun) do
  #       prior = Application.fetch_env(:barkpark, :plugins)
  #       Application.put_env(:barkpark, :plugins, [HaltingPersist])
  #       try do fun.() after …restore prior… end
  #     end
  #
  # The mutation and its restore live together in one synchronously-called
  # function. Scoping only to test/setup/setup_all flagged four sites in
  # session_hardening_test.exs and sheets_ops_route_test.exs — two of them the
  # restore STATEMENT itself, which is the fix, not the bug.
  @blocks [:test, :setup, :setup_all, :def, :defp]

  # acc   = {mutations :: [{line, sig}], restores :: MapSet.t(sig)}  — module-wide
  # hs    = pass-A helper names: a def/defp so named is a restore body
  # local = try/after restores in scope for the enclosing ExUnit block

  # Every restore-shaped signature in a subtree, read as a restore. Used by
  # AfterSigs to read an `after:` clause without disturbing the main walk.
  defp restore_sigs(node), do: elem(go(node, true, MapSet.new(), MapSet.new(), {[], MapSet.new()}), 1)

  # on_exit(fn -> … end) / on_exit(ref, fn -> … end) / ExUnit.Callbacks.on_exit(…)
  # MODULE-WIDE, unlike try/after: an on_exit registered in `setup` runs after
  # every test in the module, and the idiom is common enough that scoping it
  # tighter would red honest files.
  def go({:on_exit, _m, args}, _in_restore, hs, local, acc) when is_list(args),
    do: Enum.reduce(args, acc, &go(&1, true, hs, local, &2))

  def go({{:., _, [{:__aliases__, _, [:ExUnit, :Callbacks]}, :on_exit]}, _m, args}, _ir, hs, local, acc)
      when is_list(args),
      do: Enum.reduce(args, acc, &go(&1, true, hs, local, &2))

  # def/defp NAME(…) — TWO things at once, so this clause must precede the
  # generic block clause below (which also matches :def/:defp):
  #   * if an on_exit (or try/after) callback invokes NAME, the whole body is a
  #     restore, wherever in the file it is written;
  #   * otherwise it is an ordinary block, and its own try/after restores scope
  #     to it.
  def go({kind, _m, [head | rest]} = node, ir, hs, local, acc) when kind in [:def, :defp] do
    if fname(head) != nil and MapSet.member?(hs, fname(head)) do
      Enum.reduce(rest, acc, &go(&1, true, hs, local, &2))
    else
      descend(node, ir, hs, MapSet.union(local, after_sigs(node)), acc)
    end
  end

  # An ExUnit block: widen `local` with every try/after restore written inside
  # it, so a mutation anywhere in the block is pardoned by a restore anywhere in
  # the same block — and by no restore outside it.
  def go({kind, _m, args} = node, ir, hs, local, acc) when kind in @blocks and is_list(args),
    do: descend(node, ir, hs, MapSet.union(local, after_sigs(node)), acc)

  def go({{:., _, [{:__aliases__, _, mod}, fun]}, meta, args} = node, ir, hs, local, acc)
      when is_list(args) do
    acc = classify(:app, List.last(mod), fun, meta, args, ir, local, acc)
    descend(node, ir, hs, local, acc)
  end

  def go({{:., _, [:persistent_term, fun]}, meta, args} = node, ir, hs, local, acc)
      when is_list(args) do
    acc = classify(:pt, :persistent_term, fun, meta, args, ir, local, acc)
    descend(node, ir, hs, local, acc)
  end

  def go(other, ir, hs, local, acc), do: descend(other, ir, hs, local, acc)

  defp fname({:when, _, [head | _]}), do: fname(head)
  defp fname({name, _, _}) when is_atom(name), do: name
  defp fname(_), do: nil

  defp descend({form, _meta, args}, ir, hs, local, acc) do
    acc = go(form, ir, hs, local, acc)
    if is_list(args), do: Enum.reduce(args, acc, &go(&1, ir, hs, local, &2)), else: acc
  end

  defp descend({a, b}, ir, hs, local, acc), do: go(b, ir, hs, local, go(a, ir, hs, local, acc))
  defp descend(l, ir, hs, local, acc) when is_list(l), do: Enum.reduce(l, acc, &go(&1, ir, hs, local, &2))
  defp descend(_, _ir, _hs, _local, acc), do: acc

  # Application.put_env(app, key, …) is arity 3+. put_all_env/1,2 names no single
  # key, so it renders as the total wildcard on both the mutate and restore side.
  defp classify(:app, :Application, fun, meta, args, ir, local, {muts, rests}) do
    sig =
      case {fun, args} do
        {:put_env, [app, key | _]} -> Sig.of(app, key)
        {:delete_env, [app, key | _]} -> Sig.of(app, key)
        {:put_all_env, _} -> "*"
        _ -> nil
      end

    record(sig, fun, meta, ir, local, {muts, rests}, @app_restore, @app_mutate)
  end

  defp classify(:app, _other_module, _fun, _meta, _args, _ir, _local, acc), do: acc

  defp classify(:pt, :persistent_term, fun, meta, args, ir, local, acc) do
    sig =
      case args do
        [key | _] -> ":persistent_term/" <> Sig.render(key)
        _ -> nil
      end

    record(sig, fun, meta, ir, local, acc, @pt_restore, @pt_mutate)
  end

  defp classify(:pt, _m, _f, _meta, _a, _ir, _local, acc), do: acc

  defp record(sig, fun, meta, ir, local, {muts, rests}, restore_funs, mutate_funs) do
    cond do
      is_nil(sig) -> {muts, rests}
      ir and fun in restore_funs -> {muts, MapSet.put(rests, sig)}
      # A mutation the enclosing block's own `after:` puts back is not a leak.
      # This also absorbs the restore call INSIDE that `after:`, which is
      # textually a put_env and would otherwise be read as a mutation itself.
      not ir and fun in mutate_funs and Cover.covered?(sig, local) -> {muts, rests}
      not ir and fun in mutate_funs -> {[{meta[:line] || 0, sig} | muts], rests}
      true -> {muts, rests}
    end
  end
end

defmodule Writes do
  # Every global-state signature a file WRITES, in any context.
  #
  # This is what a support module LENDS when a restore context calls it. Using
  # the on_exit-recorded set instead would be wrong, and was: the real
  # api/test/support/plugin_env.ex passed only because an UNRELATED `with_plugins/2`
  # happens to contain an on_exit, so the credit arrived by luck. `restore/1`
  # itself is a plain `def` body — `Application.delete_env(:barkpark, :plugins)`
  # / `Application.put_env(:barkpark, :plugins, prior)` — and that is exactly the
  # thing being lent, so that is what must be read.
  def of(ast) do
    {_a, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [{:__aliases__, _, mod}, fun]}, _m, args} = n, acc when is_list(args) ->
          if List.last(mod) == :Application do
            case {fun, args} do
              {f, [app, key | _]} when f in [:put_env, :delete_env] ->
                {n, MapSet.put(acc, Sig.of(app, key))}

              {:put_all_env, _} ->
                {n, MapSet.put(acc, "*")}

              _ ->
                {n, acc}
            end
          else
            {n, acc}
          end

        {{:., _, [:persistent_term, fun]}, _m, [key | _]} = n, acc when fun in [:put, :erase] ->
          {n, MapSet.put(acc, ":persistent_term/" <> Sig.render(key))}

        n, acc ->
          {n, acc}
      end)

    acc
  end
end

defmodule RestoreCalls do
  # Which MODULES does a restore context CALL?
  #
  # The fifth idiom, and the one #14414 introduced across the tree:
  #
  #     prior = Barkpark.PluginEnv.capture()
  #     Application.put_env(:barkpark, :plugins, [HaltingPlugin])
  #     on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)
  #
  # The restore is a REMOTE call into api/test/support/plugin_env.ex, whose
  # `restore/1` is literally `Application.delete_env(:barkpark, :plugins)` /
  # `Application.put_env(:barkpark, :plugins, prior)`. Reading only the calling
  # file, the on_exit body contains no Application call at all and the module
  # looks unrestored — measured, that flagged 12 sites across three files that
  # are not merely correct but BETTER than the inline idiom, because
  # `capture/0` distinguishes an absent `:plugins` from an explicit `[]` (the
  # discovery kill switch).
  #
  # Baselining twelve correctly-written tests is exactly how a waiver file
  # becomes the real policy, so the scanner learns the idiom instead. Same
  # machinery as the case-template credit below — a module defined in the
  # scanned population lends its restores — with a different trigger: CALLED
  # from a restore context rather than `use`d.
  def of(ast) do
    {_a, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:on_exit, _m, args} = n, acc when is_list(args) ->
          {n, mods(args, acc)}

        {{:., _, [{:__aliases__, _, [:ExUnit, :Callbacks]}, :on_exit]}, _m, args} = n, acc
        when is_list(args) ->
          {n, mods(args, acc)}

        {:try, _m, [clauses]} = n, acc when is_list(clauses) ->
          if Keyword.keyword?(clauses),
            do: {n, mods(Keyword.get(clauses, :after, []), acc)},
            else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  defp mods(subtree, acc) do
    {_t, acc} =
      Macro.prewalk(subtree, acc, fn
        {{:., _, [{:__aliases__, _, parts}, _fun]}, _m, args} = n, acc
        when is_list(parts) and is_list(args) ->
          {n, MapSet.put(acc, Enum.join(Enum.map(parts, &Atom.to_string/1), "."))}

        n, acc ->
          {n, acc}
      end)

    acc
  end
end

defmodule Modules do
  # Which modules does this file DEFINE, and which does it `use`?
  #
  # A CASE TEMPLATE is the fourth restore idiom, and the one a per-file scanner
  # is structurally blind to. `Barkpark.RegistryCase` ends its `using` quote
  # with a real, after-each-test restore:
  #
  #     on_exit(fn ->
  #       Application.delete_env(:barkpark, :plugins)
  #       Barkpark.Plugins.Registry.reset()
  #     end)
  #
  # so every module that writes `use Barkpark.RegistryCase` genuinely gets
  # `:barkpark/:plugins` put back after every test — and flagging those is a
  # false positive. The credit is derived, never hardcoded: the template lives
  # under api/test/support, which is inside the scanned population, so its
  # on_exit restores are read exactly like any other module's and attributed to
  # whoever `use`s it.
  #
  # This is precisely NOT extended to a template that merely RESETS in `setup`.
  # `Barkpark.DataCase` and `BarkparkWeb.ConnCase` call `reset_plugins_env/0`
  # BEFORE each of their own tests and register no on_exit, which protects their
  # own suite and protects nobody else — that asymmetry IS the incident. They
  # contribute no restore sigs here, by construction rather than by exception:
  # a `setup` body is not a restore context, so there is nothing to collect.
  def scan(ast) do
    {_a, defined} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _m, [{:__aliases__, _, parts} | _]} = n, acc when is_list(parts) ->
          {n, [Enum.join(Enum.map(parts, &Atom.to_string/1), ".") | acc]}

        n, acc ->
          {n, acc}
      end)

    {_a, used} =
      Macro.prewalk(ast, [], fn
        {:use, _m, [{:__aliases__, _, parts} | _]} = n, acc when is_list(parts) ->
          {n, [Enum.join(Enum.map(parts, &Atom.to_string/1), ".") | acc]}

        n, acc ->
          {n, acc}
      end)

    {defined, used}
  end
end

# PASS 1 — read every file once: its mutations, its own restores, the modules it
# defines and the modules it uses.
scanned =
  Enum.map(files, fn file ->
    rel = Path.relative_to(file, root)

    with {:ok, src} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(src) do
      {muts, rests} = Walk.go(ast, false, Helpers.collect(ast), MapSet.new(), {[], MapSet.new()})
      {defined, used} = Modules.scan(ast)
      {:ok, rel, muts, rests, defined, used, RestoreCalls.of(ast), Writes.of(ast)}
    else
      _ -> {:parse_fail, rel}
    end
  end)

# The restores each DEFINED module contributes to anyone who `use`s it.
# Indexed by the FULL module name and, separately, by its LAST SEGMENT. A test
# writes `alias Barkpark.PluginEnv` and then calls `PluginEnv.restore(prior)`,
# so the call site carries only the last segment; resolving aliases properly
# would mean tracking `alias` scope, and the last-segment key buys the same
# answer. It can over-credit two same-named modules — conservative in the same
# direction as every other rule here, and preferred over reddening honest tests.
index = fn acc, names, sigs ->
  Enum.reduce(names, acc, fn name, acc ->
    last = name |> String.split(".") |> List.last()

    acc
    |> Map.update(name, sigs, &MapSet.union(&1, sigs))
    |> Map.update(last, sigs, &MapSet.union(&1, sigs))
  end)
end

# `use`-credit: a CASE TEMPLATE lends what its on_exit restores.
template_restores =
  Enum.reduce(scanned, %{}, fn
    {:ok, _rel, _muts, rests, defined, _used, _calls, _writes}, acc -> index.(acc, defined, rests)
    _, acc -> acc
  end)

# call-credit: a SUPPORT MODULE lends what its function bodies write.
call_credit =
  Enum.reduce(scanned, %{}, fn
    {:ok, _rel, _muts, _rests, defined, _used, _calls, writes}, acc -> index.(acc, defined, writes)
    _, acc -> acc
  end)

# Modules that some restore context, anywhere in the population, CALLS. Their
# own writes are restore machinery, not leaks: `def restore(prior), do:
# Application.put_env(…)` in a support module is the FIX, and flagging it would
# invert the gate's meaning.
restore_helpers =
  Enum.reduce(scanned, MapSet.new(), fn
    {:ok, _rel, _muts, _rests, _defined, _used, calls, _writes}, acc -> MapSet.union(acc, calls)
    _, acc -> acc
  end)

# PASS 2 — judge each file against its own restores PLUS its case templates'.
{lines, fails} =
  Enum.reduce(scanned, {[], []}, fn
    {:ok, rel, muts, rests, defined, used, calls, writes}, {lines, fails} ->
      effective =
        rests
        |> then(fn acc ->
          Enum.reduce(used, acc, &MapSet.union(&2, Map.get(template_restores, &1, MapSet.new())))
        end)
        |> then(fn acc ->
          Enum.reduce(calls, acc, &MapSet.union(&2, Map.get(call_credit, &1, MapSet.new())))
        end)
        |> then(fn acc ->
          # This file IS a restore helper someone calls from an on_exit.
          if Enum.any?(defined, fn n ->
               MapSet.member?(restore_helpers, n) or
                 MapSet.member?(restore_helpers, n |> String.split(".") |> List.last())
             end),
             do: MapSet.union(acc, writes),
             else: acc
        end)

      leaked =
        muts
        |> Enum.reject(fn {_l, sig} -> Cover.covered?(sig, effective) end)
        |> Enum.sort()
        |> Enum.map(fn {l, sig} -> "HIT\t#{rel}\t#{l}\t#{sig}" end)

      {leaked ++ lines, fails}

    {:parse_fail, rel}, {lines, fails} ->
      {lines, [rel | fails]}
  end)

Enum.each(Enum.reverse(lines), &IO.puts/1)
Enum.each(Enum.sort(fails), &IO.puts("PARSE_FAIL\t" <> &1))
IO.puts("PARSE_FAILURES\t#{length(fails)}")
IO.puts("SCANNED\t#{length(files)}")
ELIXIR

run_scan() {
  TELG_SCANDIR="$SCANDIR" elixir "$SCANNER"
}

# --- selftest ---------------------------------------------------------------
# Five arms against synthetic trees in a TEMP dir. Arm (0) is what stops the
# rest passing vacuously: a scanner that always reports "clean" would satisfy a
# naive can-it-red test while measuring nothing.
#
# The DEEPER proof — that a gutted copy of this gate fails its own harness — is
# scripts/test-env-leak-gate.test.sh, which CI runs first.
if [ "${1:-}" = "--selftest" ]; then
  T="$WORKD/selftest"
  mkdir -p "$T/tree"
  fails=0
  arm() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fails=$((fails + 1)); return 0; }

  echo "test-env-leak-gate --selftest"
  echo

  # (0) A RESTORED mutation must NOT be flagged. Without this arm a scanner
  #     that flagged every put_env would satisfy every can-it-red arm below.
  cat > "$T/tree/clean_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case

  setup do
    prev = Application.get_env(:barkpark, :plugins)
    Application.put_env(:barkpark, :plugins, [P])
    on_exit(fn -> Application.put_env(:barkpark, :plugins, prev) end)
    :ok
  end

  test "restored" do
    assert Application.get_env(:barkpark, :plugins) == [P]
  end
end
EX
  : > "$T/allow"
  if TEST_ENV_LEAK_SCANDIR="$T/tree" TEST_ENV_LEAK_ALLOWLIST="$T/allow" \
    bash "$0" > "$T/out0" 2>&1; then
    arm "ok" "(0) a paired put_env/on_exit passes — the scanner does not flag every mutation"
  else
    arm "FAIL" "(0) a RESTORED mutation reddened — the scanner over-matches; every arm below is meaningless"
    sed 's/^/        /' "$T/out0"
  fi

  # (a) an UNRESTORED mutation must RED, naming file and line.
  cat > "$T/tree/leak_test.exs" <<'EX'
defmodule LeakTest do
  use ExUnit.Case

  test "leaks" do
    Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
    assert true
  end
end
EX
  out="$(TEST_ENV_LEAK_SCANDIR="$T/tree" TEST_ENV_LEAK_ALLOWLIST="$T/allow" bash "$0" 2>&1 || true)"
  if grep -q "leak_test.exs:5" <<<"$out"; then
    arm "ok" "(a) an unrestored put_env reds, naming leak_test.exs:5"
  else
    arm "FAIL" "(a) an unrestored put_env did NOT red — the gate is asleep"
  fi

  # (b) the same site AT the allowlist must PASS (never-worse, not clean-tree).
  printf '1\tleak_test.exs\t:barkpark/:plugins\tselftest fixture, deliberately baselined\n' > "$T/allow2"
  if TEST_ENV_LEAK_SCANDIR="$T/tree" TEST_ENV_LEAK_ALLOWLIST="$T/allow2" \
    bash "$0" >/dev/null 2>&1; then
    arm "ok" "(b) an allowlisted site passes — the ratchet grandfathers, it does not demand zero"
  else
    arm "FAIL" "(b) an allowlisted site reddened — this gate would red main on day one and get disabled"
  fi

  # (c) an allowlist row with NO reason must RED. A row nobody had to justify is
  #     a mute button, and this is the only thing stopping the file becoming one.
  printf '1\tleak_test.exs\t:barkpark/:plugins\n' > "$T/allow3"
  out="$(TEST_ENV_LEAK_SCANDIR="$T/tree" TEST_ENV_LEAK_ALLOWLIST="$T/allow3" bash "$0" 2>&1 || true)"
  if grep -qi "reason" <<<"$out"; then
    arm "ok" "(c) a bare allowlist row is REFUSED — every waiver must carry a reason"
  else
    arm "FAIL" "(c) a reasonless allowlist row was accepted — the allowlist is a mute button"
  fi

  # (d) an EMPTY population must RED, never print OK over a scan of nothing.
  mkdir -p "$T/empty"
  out="$(TEST_ENV_LEAK_SCANDIR="$T/empty" TEST_ENV_LEAK_ALLOWLIST="$T/allow" bash "$0" 2>&1 || true)"
  if grep -qi "scanned ZERO\|zero file" <<<"$out"; then
    arm "ok" "(d) a population of ZERO files REFUSES — an empty scan is a failure, not a pass"
  else
    arm "FAIL" "(d) an empty population printed a verdict — the gate greens over a tree it never read"
  fi

  # (e) an UNPARSEABLE file must RED by name, not be silently skipped.
  printf 'defmodule Broken do\n  test "x" do\n    assert (((\n' > "$T/tree/broken_test.exs"
  out="$(TEST_ENV_LEAK_SCANDIR="$T/tree" TEST_ENV_LEAK_ALLOWLIST="$T/allow2" bash "$0" 2>&1 || true)"
  if grep -q "broken_test.exs" <<<"$out"; then
    arm "ok" "(e) an unparseable file REFUSES by name — never a silent skip"
  else
    arm "FAIL" "(e) an unparseable file was skipped silently — the scanner reports a tree it never read"
  fi

  echo
  if [ "$fails" -gt 0 ]; then
    echo "SELFTEST FAILED: $fails of 6 arms failed" >&2
    exit 1
  fi
  echo "SELFTEST PASSED: 6 of 6 arms"
  exit 0
fi

# --- scan -------------------------------------------------------------------
SCAN_OUT="$(run_scan)"

# Every read below is from a VARIABLE, never a pipeline whose status is read.
# `printf … | grep -q` returns 141 under SIGPIPE and `set -o pipefail` promotes
# that over grep's success, so a match reads as a miss under load.
PARSE_FAILS="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="PARSE_FAIL"{print $2}')"
SCANNED="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="SCANNED"{print $2}')"
NFAIL="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="PARSE_FAILURES"{print $2}')"

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{printf "%s:%s\t%s\n", $2, $3, $4}'
  printf '\nscanned %s file(s), %s parse failure(s)\n' "${SCANNED:-0}" "${NFAIL:-0}"
  exit 0
fi

if [ "${1:-}" = "--baseline" ]; then
  cat <<'HDR'
# test-env-leak-allowlist.txt — reviewed waivers for scripts/test-env-leak-gate.sh
#
# FORMAT (TAB-separated, exactly four fields):
#   <count>	<path relative to api/test>	<app>/<key>	<reason>
#
# A row with fewer than four fields, or a reason under 12 characters, is
# REFUSED — an allowlist whose rows nobody had to justify is a mute button.
# Counts may only FALL; a stale row (count now lower) reds until it is lowered.
HDR
  printf '%s\n' "$SCAN_OUT" |
    awk -F'\t' '$1=="HIT"{c[$2 FS $4]++} END{for (k in c) printf "%d\t%s\tTODO: state why this leak is tolerated\n", c[k], k}' |
    sort -t"$(printf '\t')" -k2,2 -k3,3
  exit 0
fi

# ── population: ZERO scanned files is a FAILURE, never a pass ───────────────
if [ ! -d "$SCANDIR" ]; then
  echo "test-env-leak-gate: REFUSING — the scan population $SCANDIR does not exist." >&2
  echo "  A gate whose input tree has moved must say so. Reporting OK here would" >&2
  echo "  certify a tree that was never read." >&2
  exit 1
fi

if [ "${SCANNED:-0}" -eq 0 ]; then
  echo "test-env-leak-gate: REFUSING — scanned ZERO files under $SCANDIR." >&2
  echo "  An empty population is a failure, not a clean tree. Either the path is" >&2
  echo "  wrong or the suite has vanished; both are worse than a leak." >&2
  exit 1
fi

# ── unreadable input: REFUSE, never degrade ─────────────────────────────────
if [ "${NFAIL:-0}" != "0" ]; then
  echo "test-env-leak-gate: REFUSING — $NFAIL file(s) could not be parsed:" >&2
  printf '%s\n' "$PARSE_FAILS" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  A scanner that skips what it cannot read reports a clean tree it never" >&2
  echo "  inspected. Fix the syntax, or fix the scanner — do not let it degrade." >&2
  exit 1
fi

# ── allowlist: literal committed rows, each carrying a reason ───────────────
[ -f "$ALLOWLIST" ] || {
  echo "test-env-leak-gate: allowlist $ALLOWLIST is missing — REFUSING." >&2
  echo "  The floor is COMMITTED ROWS, never a count derived from the tree at" >&2
  echo "  runtime: a computed floor agrees with a gutted tree by construction." >&2
  exit 3
}

TAB="$(printf '\t')"
rc=0

# Reason enforcement runs BEFORE any comparison: a malformed allowlist must red
# on its own terms, not silently pardon or silently fail to pardon.
lineno=0
: > "$WORKD/allow"
while IFS= read -r row || [ -n "$row" ]; do
  lineno=$((lineno + 1))
  case "$row" in '' | '#'*) continue ;; esac

  nfields="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
  cnt="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
  pth="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
  sig="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
  reason="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
  # Trim, so a row of blanks cannot masquerade as a justification.
  reason="$(printf '%s' "$reason" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  if [ "$nfields" -lt 4 ] || [ -z "$reason" ]; then
    echo "RED  $ALLOWLIST:$lineno — allowlist row carries NO reason." >&2
    echo "       row: $row" >&2
    echo "       Every waiver must state why the leak is tolerated. Format:" >&2
    echo "       <count><TAB><path><TAB><app>/<key><TAB><reason>" >&2
    rc=1
    continue
  fi

  if [ "${#reason}" -lt "$MIN_REASON" ]; then
    echo "RED  $ALLOWLIST:$lineno — reason is $((${#reason})) chars; at least $MIN_REASON required." >&2
    echo "       row: $row" >&2
    echo "       \"x\" and \"todo\" are bare rows wearing a costume." >&2
    rc=1
    continue
  fi

  # A PLACEHOLDER is the length check's blind spot, and `--baseline` writes one
  # on purpose. Regenerate the baseline, commit it unread, and every row carries
  # a 38-character "reason" that justifies nothing — the requirement defeated by
  # the tool that is supposed to serve it. The placeholder is deliberately
  # long enough to pass MIN_REASON so that ONLY this check can clear it: you
  # cannot ship a generated baseline without reading each row and replacing the
  # text.
  case "$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')" in
    todo* | fixme* | tbd* | xxx* | 'n/a'* | none* | '?'*)
      echo "RED  $ALLOWLIST:$lineno — reason is a PLACEHOLDER, not a reason." >&2
      echo "       row: $row" >&2
      echo "       \`--baseline\` writes 'TODO: state why this leak is tolerated' into" >&2
      echo "       every row precisely so a generated baseline cannot be committed" >&2
      echo "       unread. Read the site, then say why the leak is tolerated." >&2
      rc=1
      continue
      ;;
  esac

  case "$cnt" in
    '' | *[!0-9]*)
      echo "RED  $ALLOWLIST:$lineno — first field must be a count, got '$cnt'." >&2
      rc=1
      continue
      ;;
  esac

  printf '%s\t%s\t%s\n' "$cnt" "$pth" "$sig" >> "$WORKD/allow"
done < "$ALLOWLIST"

if [ "$rc" != 0 ]; then
  echo "" >&2
  echo "test-env-leak-gate: the allowlist itself is malformed — refusing to judge" >&2
  echo "  the tree through it." >&2
  exit "$rc"
fi

printf '%s\n' "$SCAN_OUT" |
  awk -F'\t' '$1=="HIT"{c[$2 FS $4]++} END{for (k in c) printf "%d\t%s\n", c[k], k}' |
  sort -t"$TAB" -k2,2 -k3,3 > "$WORKD/now"
sort -t"$TAB" -k2,2 -k3,3 "$WORKD/allow" > "$WORKD/base"

# NEW or GROWN — the direction that matters.
while IFS="$TAB" read -r n f s; do
  [ -z "${f:-}" ] && continue
  b="$(awk -F'\t' -v p="$f" -v k="$s" '$2==p && $3==k{print $1}' "$WORKD/base")"
  b="${b:-0}"
  if [ "$n" -gt "$b" ]; then
    echo "RED  $f — $n unrestored mutation(s) of $s, allowlisted $b" >&2
    printf '%s\n' "$SCAN_OUT" |
      awk -F'\t' -v p="$f" -v k="$s" '$1=="HIT" && $2==p && $4==k{printf "       %s:%s\n", $2, $3}' >&2
    rc=1
  fi
done < "$WORKD/now"

# FELL — a ratchet nobody tightens rusts at a number nobody re-earns.
while IFS="$TAB" read -r n f s; do
  [ -z "${f:-}" ] && continue
  c="$(awk -F'\t' -v p="$f" -v k="$s" '$2==p && $3==k{print $1}' "$WORKD/now")"
  c="${c:-0}"
  if [ "$c" -lt "$n" ]; then
    echo "RATCHET  $f ($s) — now $c, allowlisted $n. Lower or delete the row:" >&2
    echo "         counts may only fall. $ALLOWLIST" >&2
    rc=1
  fi
done < "$WORKD/base"

TOTAL="$(awk -F'\t' '{s+=$1} END{print s+0}' "$WORKD/now")"
if [ "$rc" = 0 ]; then
  echo "test-env-leak-gate: OK — $TOTAL unrestored global mutation(s) at or below the allowlist, $SCANNED file(s) scanned, 0 parse failures"
else
  echo "" >&2
  echo "  FIX: capture the previous value and restore it, so the mutation cannot" >&2
  echo "  outlive the test that made it:" >&2
  echo "" >&2
  echo "       prev = Application.get_env(:barkpark, :plugins)" >&2
  echo "       Application.put_env(:barkpark, :plugins, [MyPlugin])" >&2
  echo "       on_exit(fn -> Application.put_env(:barkpark, :plugins, prev) end)" >&2
  echo "" >&2
  echo "  Application state is VM-GLOBAL. Without the on_exit the value survives" >&2
  echo "  the test, the module and the file, and the next module the (unseeded)" >&2
  echo "  scheduler happens to run inherits it — a failure in a file nobody" >&2
  echo "  touched, on some runs and not others." >&2
  echo "" >&2
  echo "  If a leak is genuinely unavoidable, add a row WITH A REASON to" >&2
  echo "  $ALLOWLIST" >&2
fi
exit "$rc"
