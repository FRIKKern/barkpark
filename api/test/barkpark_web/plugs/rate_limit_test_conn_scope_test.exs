defmodule BarkparkWeb.Plugs.RateLimitTestConnScopeTest do
  @moduledoc """
  THE SECOND TRIPWIRE — and it is a TEST OVER TESTS, on purpose.

  `RateLimitPrincipalCoverageTest` reads the router and refuses a credential
  plug the limiter cannot resolve. It could not see the defect that reverted
  #15677, because THERE WAS NOTHING TO SEE IN `lib/`: the production behaviour
  was correct. A router-derived guard catches production gaps; this one lives in
  test construction, which is why this second guard has to be a test over tests.

  What went wrong. `pipeline :user_auth` mounts `Plugs.RateLimit` BEFORE
  `:fetch_session`, so every caller on `/v1/auth/*` and `/v1/access/claim` is
  metered with no verifiable identity — by design, because the shared per-IP
  budget IS the brute-force control on login. `RateLimit.bucket_key/3` suffixes
  the WHOLE key (the `token:` branch AND the `ip:` fallback) with
  `conn.private[:barkpark_rate_limit_scope]`, which only `ConnCase` stamps. A
  conn from a bare `Phoenix.ConnTest.build_conn/0` carries no scope, so every
  such conn in the run shares ONE `ip:127.0.0.1` bucket. 19 of them across two
  files exhausted the 60/min write budget and 8 tests went 429 on main for 2.5
  hours.

  So: a test module that requests a route metered with no verifiable caller must
  obtain its conns from `BarkparkWeb.ConnCase.scoped_conn/0`. This file reads the
  router's own AST (scope -> pipe_through -> path, no hand-written path list),
  derives that route set from the pipelines themselves, and scans the suite.

  The scan's verdict is "the violation list is EMPTY", and a scanner that had
  gone blind would return that verdict too — the same vacuous green that let the
  original gap survive. `scan/2` is therefore a pure function over
  `{path, source}` pairs, and the POSITIVE CONTROL below runs the REAL scanner
  over a synthetic module that does the wrong thing and asserts it is caught by
  name.
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_web/router.ex", __DIR__)
  @test_root Path.expand("../..", __DIR__)

  # A bare `build_conn()` here is the SUBJECT of the test, not a caller of a
  # metered route: this list must SHRINK, never grow. Adding an entry means you
  # are asserting the conn deliberately carries no scope; say why.
  @exempt %{
    # Defines scoped_conn/0 itself — the one legitimate build_conn/0 in the tree.
    "test/support/conn_case.ex" => "the definition of scoped_conn/0",
    # This file's POSITIVE CONTROL is a synthetic source that MUST contain a
    # bare build_conn/0 on a metered path; the scanner is required to flag it,
    # so the scanner must not flag the file that carries it.
    "test/barkpark_web/plugs/rate_limit_test_conn_scope_test.exs" =>
      "carries the offender fixture the positive control feeds to scan/2"
  }

  # ── router-derived: which pipelines meter a caller they cannot identify ──

  defp metered_pipelines do
    src = File.read!(@router_source)

    Regex.scan(~r/\n  pipeline (:\w+) do\n(.*?)\n  end\n/s, src)
    |> Enum.map(fn [_, name, body] -> {name, body} end)
    |> Enum.filter(fn {_name, body} -> String.contains?(body, "Plugs.RateLimit)") end)
  end

  # A metered pipeline with NO credential plug in it meters callers whose
  # identity nothing has resolved yet — the IP-fallback surface. Same credential
  # vocabulary as RateLimitPrincipalCoverageTest, deliberately.
  defp unidentified_metered_pipelines do
    for {name, body} <- metered_pipelines(),
        not Regex.match?(
          ~r/plug\((?:BarkparkWeb\.Plugs\.)?:?\w*(?:Token|Credential|Host|Auth)\w*[\),]/,
          body
        ),
        do: String.trim_leading(name, ":") |> String.to_atom()
  end

  @verbs [:get, :post, :put, :patch, :delete, :options, :head]

  # `Phoenix.Router.__routes__/0` does NOT carry `pipe_through` (it is compiled
  # away), so the scope->pipeline->path chain is read from the router's own AST.
  # That is still the router deriving the set, not a hand-written list here.
  defp unidentified_metered_paths do
    pipelines = unidentified_metered_pipelines()

    @router_source
    |> File.read!()
    |> Code.string_to_quoted!()
    |> walk_routes("", [])
    |> Enum.filter(fn {_path, pipes} -> Enum.any?(pipes, &(&1 in pipelines)) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&String.contains?(&1, ":"))
    |> Enum.uniq()
  end

  defp walk_routes({:defmodule, _, [_, [do: body]]}, prefix, pipes),
    do: walk_routes(body, prefix, pipes)

  defp walk_routes({:__block__, _, stmts}, prefix, pipes),
    do: Enum.flat_map(stmts, &walk_routes(&1, prefix, pipes))

  defp walk_routes({:scope, _, args}, prefix, pipes) do
    case List.last(args) do
      [{:do, body}] ->
        seg = Enum.find(args, "", &is_binary/1)
        walk_routes(body, join(prefix, seg), pipes ++ scope_pipes(body))

      _ ->
        []
    end
  end

  defp walk_routes({verb, _, [path | _]}, prefix, pipes)
       when verb in @verbs and is_binary(path),
       do: [{join(prefix, path), pipes}]

  defp walk_routes(_other, _prefix, _pipes), do: []

  # `pipe_through` declared directly in THIS scope's block (not a nested one).
  defp scope_pipes({:__block__, _, stmts}), do: Enum.flat_map(stmts, &scope_pipes/1)
  defp scope_pipes({:pipe_through, _, [arg]}), do: List.wrap(pipe_atoms(arg))
  defp scope_pipes(_), do: []

  defp pipe_atoms(list) when is_list(list), do: Enum.filter(list, &is_atom/1)
  defp pipe_atoms(atom) when is_atom(atom), do: [atom]
  defp pipe_atoms(_), do: []

  defp join(prefix, seg), do: String.replace(prefix <> seg, ~r{//+}, "/")

  # ── the scanner, as a pure function so the positive control can run it ──

  @doc false
  # sources :: [{relative_path, source_text}]; paths :: [route path literal]
  def scan(sources, paths) do
    for {path, src} <- sources,
        not Map.has_key?(@exempt, path),
        Enum.any?(paths, &String.contains?(src, "\"" <> &1 <> "\"")),
        bare = length(Regex.scan(~r/(?<![\w.])build_conn\(\)/, src)),
        bare > 0,
        do: {path, bare}
  end

  defp suite_sources do
    Path.wildcard(Path.join(@test_root, "**/*.exs"))
    |> Enum.map(fn abs ->
      {Path.relative_to(abs, Path.expand("..", @test_root)), File.read!(abs)}
    end)
  end

  # ── positive controls: prove every stage can SEE what it is looking for ──

  test "the router parse finds the unidentified-metered pipelines and their paths" do
    pipelines = unidentified_metered_pipelines()

    assert :user_auth in pipelines,
           "pipeline :user_auth mounts RateLimit ahead of :fetch_session and is THE " <>
             "unidentified-metered pipeline; it fell out of the parse, so this file " <>
             "is measuring nothing. Parsed: #{inspect(pipelines)}"

    paths = unidentified_metered_paths()

    assert "/v1/auth/login" in paths
    assert "/v1/auth/register" in paths

    assert "/v1/access/claim" in paths,
           "POST /v1/access/claim is one of the two routes that reddened main; " <>
             "if it is not in the derived set the scan below cannot see its callers"

    assert length(paths) >= 10, "only #{length(paths)} paths derived — the parse has drifted"
  end

  test "the suite walk reaches the files this guard exists for" do
    sources = suite_sources()
    paths = unidentified_metered_paths()

    in_scope =
      for {p, src} <- sources,
          Enum.any?(paths, &String.contains?(src, "\"" <> &1 <> "\"")),
          do: p

    # An empty or tiny walk would make the real assertion vacuously green.
    assert "test/barkpark_web/controllers/webauthn_controller_test.exs" in in_scope
    assert "test/barkpark_web/controllers/access_controller_test.exs" in in_scope

    assert length(in_scope) >= 20,
           "only #{length(in_scope)} in-scope test files found — the wildcard or the " <>
             "path match has drifted and the scan is measuring almost nothing"
  end

  test "POSITIVE CONTROL: the scanner catches a bare build_conn() on a metered route" do
    paths = unidentified_metered_paths()

    offender = """
    defmodule Fixture.OffenderTest do
      use BarkparkWeb.ConnCase, async: false

      test "logs in" do
        build_conn() |> post("/v1/auth/login", "{}")
      end
    end
    """

    clean = String.replace(offender, "build_conn()", "scoped_conn()")

    # The SAME function the real assertion calls, over a source it must flag.
    assert scan([{"fixture/offender_test.exs", offender}], paths) ==
             [{"fixture/offender_test.exs", 1}],
           "the scanner cannot see a bare build_conn() on a metered anonymous route, " <>
             "so its EMPTY verdict below means nothing"

    assert scan([{"fixture/clean_test.exs", clean}], paths) == [],
           "the scanner flags scoped_conn/0, which would make the rule unsatisfiable"

    # And it must not fire on a file that never touches a metered anonymous route.
    unrelated = String.replace(offender, "/v1/auth/login", "/v1/data/query/production/post")
    assert scan([{"fixture/unrelated_test.exs", unrelated}], paths) == []
  end

  # ── the assertion ──

  test "every test module hitting a route metered without a verifiable caller uses ConnCase conns" do
    violations = scan(suite_sources(), unidentified_metered_paths())

    assert violations == [],
           """
           These test modules request a route that `BarkparkWeb.Plugs.RateLimit`
           meters BEFORE any credential plug runs, using a conn from a bare
           `Phoenix.ConnTest.build_conn/0`:

             #{Enum.map_join(violations, "\n  ", fn {p, n} -> "#{p} (#{n} bare build_conn/0)" end)}

           Such a conn carries no `:barkpark_rate_limit_scope`, so it shares ONE
           `ip:127.0.0.1` bucket with every other unscoped conn in the run. That
           is not a limiter bug — the shared per-IP budget IS the brute-force
           control on `/v1/auth/*` and `/v1/access/claim`, and giving those
           callers their own resolver would hand every attacker a private budget
           on exactly the routes where sharing is the defence.

           Use `BarkparkWeb.ConnCase.scoped_conn/0` (imported by `use
           BarkparkWeb.ConnCase`) instead of `build_conn/0`. It is per test
           process, so two conns inside ONE test still share a bucket and a test
           can still prove the limiter limits.

           This exact omission reverted #15677 and held main red for 2.5 hours.
           """
  end
end
