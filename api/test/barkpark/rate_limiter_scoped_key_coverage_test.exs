defmodule Barkpark.RateLimiterScopedKeyCoverageTest do
  @moduledoc """
  THE RATCHET FOR `RateLimiter.scoped_key/2` — a test over `lib/`, not over
  behaviour.

  `Barkpark.RateLimiter` keeps its buckets in `:barkpark_rate_limiter`, a
  `:named_table`. That is WHOLE-NODE state no Ecto sandbox owns, so a bucket key
  derived only from the client IP is the SAME key in every test process in the
  run. Under `--max-cases 8` the suite bills its own parallel cases against one
  budget and 429s itself — which is how the required Elixir gate went red on
  main at random, twice in one hour on 09-03/04.

  `Plugs.RateLimit` had a per-test scope suffix and was the ONLY metered surface
  that honoured it. The other SEVEN `check/2` call sites were scope-blind. That
  asymmetry is not something a reader can see from any one file, and nothing
  stopped an eighth site from being added the same way tomorrow — the class is
  structural, so the guard has to be too.

  THE RULE: the first argument of every `RateLimiter.check/1,2` call in
  `lib/` is a `RateLimiter.scoped_key/2` call, syntactically, AT the call site.
  Not "a variable that was scoped earlier" — that is unreviewable at a glance
  and lets a rebase quietly re-blind a site while the shape still reads right.

  Why this is safe to demand: `scoped_key/2` is the IDENTITY function on every
  request that carries no `:barkpark_rate_limit_scope`, and nothing outside
  `test/` ever sets one. `Barkpark.RateLimiterScopedKeyTest` asserts that
  no-op over every key shape in the tree. So the rule costs production nothing
  and it is never a reason to raise a limit, widen a bucket or disable a meter.

  ANTI-VACUITY. "The violation list is empty" is also what a scanner that had
  gone blind would report. Three defences: the census below names the exact
  eight sites (a site that disappears reds), `scan/1` is a pure function over
  `{path, source}` pairs, and the POSITIVE CONTROL runs the REAL scanner over a
  source that bypasses the helper and requires it to be caught by name.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib", __DIR__)

  # Call sites permitted to reach `check/2` without `scoped_key/2`. EMPTY, and
  # that is the point: every site routes through the one helper, so there is no
  # second definition of "scoped" to drift. An entry here must name the file AND
  # say why that surface cannot carry a scope — "it was easier" is not a reason.
  @allowed %{}

  # The tree as it stands. This is a CENSUS, not an allow-list: every one of
  # these is required to be compliant. It exists so the scan cannot go green by
  # finding nothing — if a site is renamed away, fix this list deliberately.
  @known_sites [
    "lib/barkpark_web/channels/user_socket.ex",
    "lib/barkpark_web/controllers/app_token_controller.ex",
    "lib/barkpark_web/controllers/bulldocs_form_controller.ex",
    "lib/barkpark_web/controllers/pulse_controller.ex",
    "lib/barkpark_web/plugs/auth_write_rate_limit.ex",
    "lib/barkpark_web/plugs/rate_limit.ex",
    "lib/barkpark_web/plugs/ticket_rate_limit.ex"
  ]

  # ── the scanner, pure so the positive control can run the REAL one ──

  @doc false
  # sources :: [{relative_path, source_text}] -> [{path, line, rendered_arg}]
  def scan(sources) do
    for {path, src} <- sources,
        not Map.has_key?(@allowed, path),
        {line, arg} <- check_call_keys(src),
        not scoped?(arg),
        do: {path, line, Macro.to_string(arg)}
  end

  @doc false
  def check_call_keys(src) do
    src
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn node, acc ->
      case node do
        {{:., _, [mod, :check]}, meta, [key | _]} ->
          if rate_limiter?(mod), do: {node, [{meta[:line], key} | acc]}, else: {node, acc}

        _ ->
          {node, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # `RateLimiter.check(...)` or `Barkpark.RateLimiter.check(...)`. The alias is
  # matched on its LAST segment so an `alias Barkpark.RateLimiter` and a
  # fully-qualified call are the same site to this scan.
  defp rate_limiter?({:__aliases__, _, segments}), do: List.last(segments) == :RateLimiter
  defp rate_limiter?(_), do: false

  defp scoped?({{:., _, [mod, :scoped_key]}, _, [_source, _key]}), do: rate_limiter?(mod)
  defp scoped?(_), do: false

  defp lib_sources do
    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
    |> Enum.filter(&(File.read!(&1) =~ "RateLimiter.check("))
    |> Enum.map(fn abs ->
      {Path.relative_to(abs, Path.expand("..", @lib_root)), File.read!(abs)}
    end)
    |> Enum.sort()
  end

  # ── anti-vacuity ──

  test "the walk finds every known call site (a blind scanner reds here first)" do
    found = lib_sources() |> Enum.map(&elem(&1, 0))

    assert found == @known_sites,
           """
           The set of files calling `RateLimiter.check/1,2` has moved.

             found:   #{inspect(found)}
             census:  #{inspect(@known_sites)}

           A file that DISAPPEARED means the scan below is measuring less than it
           was written to measure. A file that APPEARED is a new metered surface —
           make sure it scopes its key, then add it here.
           """
  end

  test "the AST walk actually extracts key arguments (not an empty list per file)" do
    counts =
      for {path, src} <- lib_sources(), do: {path, length(check_call_keys(src))}

    refute Enum.any?(counts, fn {_p, n} -> n == 0 end),
           "a file matched the text `RateLimiter.check(` but the AST walk found no " <>
             "call in it — the matcher has drifted: #{inspect(counts)}"

    # pulse_controller carries two (write bucket + read bucket).
    assert Enum.sum(Enum.map(counts, &elem(&1, 1))) == 8,
           "expected the 8 call sites the row names, found #{inspect(counts)}"
  end

  test "POSITIVE CONTROL: the scanner catches a call site that bypasses the helper" do
    bypassing = """
    defmodule Fixture.Bypass do
      alias Barkpark.RateLimiter

      def call(conn) do
        RateLimiter.check({:probe, RateLimiter.client_ip(conn)}, capacity: 1)
      end
    end
    """

    fixed = """
    defmodule Fixture.Fixed do
      alias Barkpark.RateLimiter

      def call(conn) do
        key = {:probe, RateLimiter.client_ip(conn)}
        RateLimiter.check(RateLimiter.scoped_key(conn, key), capacity: 1)
      end
    end
    """

    assert scan([{"lib/fixture/bypass.ex", bypassing}]) ==
             [{"lib/fixture/bypass.ex", 5, "{:probe, RateLimiter.client_ip(conn)}"}],
           "the scanner cannot see an unscoped key, so its EMPTY verdict below means nothing"

    assert scan([{"lib/fixture/fixed.ex", fixed}]) == [],
           "the scanner flags a COMPLIANT site, which would make the rule unsatisfiable"

    # The variable-indirection shape is DELIBERATELY refused: it reads compliant
    # and is not. This is the assertion that keeps the rule syntactic.
    indirect = String.replace(fixed, "RateLimiter.scoped_key(conn, key)", "key")

    assert scan([{"lib/fixture/indirect.ex", indirect}]) == [
             {"lib/fixture/indirect.ex", 6, "key"}
           ],
           "a key scoped on an EARLIER line and passed by variable must still be refused — " <>
             "that shape reads compliant and is not"
  end

  # ── the assertion ──

  test "every RateLimiter.check/2 call site in lib/ keys through scoped_key/2" do
    violations = scan(lib_sources())

    assert violations == [],
           """
           These `Barkpark.RateLimiter.check/1,2` call sites build their bucket key
           without `RateLimiter.scoped_key/2`:

             #{Enum.map_join(violations, "\n  ", fn {p, l, a} -> "#{p}:#{l} — #{a}" end)}

           `:barkpark_rate_limiter` is a :named_table, so an IP-keyed bucket is ONE
           bucket for the whole test run and the suite throttles itself under
           `--max-cases 8`. Wrap the key:

               key = {:your_bucket, RateLimiter.client_ip(conn)}
               RateLimiter.check(RateLimiter.scoped_key(conn, key), opts)

           `scoped_key/2` is the identity function whenever no test scope is set,
           so production behaviour is unchanged. Do NOT instead raise the limit,
           widen the bucket or disable the meter in test — that removes the
           control this call site exists to be.
           """
  end
end
