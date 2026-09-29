defmodule BarkparkCloud.Web.RouterAuthWrappers do
  @moduledoc """
  THE AUTH-WRAPPER REGISTRY — one classification table for the whole router,
  plus a DERIVATION that re-reads `router.ex` and finds the wrappers itself.

  WHY THIS EXISTS. Charter decision D34 enumerated the router's authentication
  wrappers as a hand-written list of eight names. A list of N names is a
  SNAPSHOT of a moving target: it is correct until somebody writes the N+1th
  wrapper, and nothing anywhere goes red when they do. D34's eight could not
  reproduce the census the guard beside it pins, and by the time that was
  noticed the router held more wrappers again. Correcting 8 -> 12 -> 14 only
  resets the clock.

  So the hand-maintained part is reduced to the ONE judgment a parser cannot
  make — is this wrapper a HUMAN/session identity or a MACHINE identity — and
  the MEMBERSHIP of the set is derived from source by `derive/0`.
  `BarkparkCloud.Web.RouterAuthWrapperRegistryTest` asserts the two agree in
  BOTH directions, so a new wrapper reds by name and a deleted one reds by name.

  WHAT COUNTS AS A WRAPPER, precisely (this is the predicate, stated once):

    1. Any `Auth.require_*/N` CALLED anywhere in `router.ex`. These are the
       module-level entry points; they establish identity themselves.

    2. Any function DEFINED in `router.ex` that (a) is invoked from at least one
       route macro body (`get`/`post`/`put`/`patch`/`delete`/`head`/`options`),
       and (b) reaches an IDENTITY PRIMITIVE in its own body — one of the
       `Auth.require_*` calls above, or the two session-token primitives
       `Accounts.verify_user_session_token` / `Accounts.consume_sse_ticket_binding`
       that `require_user_sse/1` uses instead of an `Auth.require_*`.

  The primitive vocabulary in (2b) is the one remaining literal, and it is NOT
  allowed to go quietly stale either: the registry test asserts every alternative
  in `@identity_primitive_re` still matches `router.ex`, so a rename reds rather
  than silently shrinking the derivation's reach.

  KNOWN AND DELIBERATE LIMITS, so nobody reads more into a green than is there:

    * This is SYNTACTIC. It proves a route NAMES a wrapper, never that the
      wrapper is correct or that the route honours its halt. That boundary is
      already spelled out in `router_head_fence_census_test.exs`.
    * Comment lines are stripped before matching. Without that, a `# ... Auth.require_user ...`
      sentence inside `barkpark_json/2` made a JSON renderer look like an auth
      wrapper (measured).
    * A wrapper reached TWO calls deep from a route body is not derived. None
      exists today; if one is written, the registry test reds on the DIRECT
      caller instead, which still names the right file and the right line.

  ROUTE-SURFACE NOTE. `go_live/1` and `resurrect/1` are session wrappers that
  the pre-existing GET census never saw, because they gate POST routes only
  (`/v1/launch`, `/v1/go-live`, `/v1/resurrect`). They move no number in
  `router_head_fence_census_test.exs` — verified: no GET body mentions either —
  but they belong in the registry, and their absence from it is exactly the
  drift this module is built to make loud. A GET added behind a wrapper the
  registry does not list would classify PUBLIC and move the public count, which
  is the quiet failure.
  """

  @router_source Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)

  @doc "Absolute path of the router this registry is derived from."
  def router_source, do: @router_source

  # THE ONE HAND-MAINTAINED JUDGMENT: session (a human/session-token identity)
  # vs machine (an agent token or the internal worker shared secret).
  #
  # `Auth.require_user_or_pat_or_worker` is MACHINE deliberately, even though it
  # also admits a human: it is a route a machine can reach, and the census
  # checks machine first so "carries both" resolves to machine. See the census
  # test's 2026-09-02 baseline note.
  @classification %{
    # -- module entry points --------------------------------------------------
    "Auth.require_user" => :session,
    "Auth.require_user_or_pat" => :session,
    "Auth.require_team_admin" => :session,
    "Auth.require_team_role" => :session,
    "Auth.require_current_team_admin" => :session,
    "Auth.require_current_team_owner" => :session,
    "Auth.require_platform_operator" => :session,
    "Auth.require_ability" => :session,
    "Auth.require_agent" => :machine,
    "Auth.require_worker" => :machine,
    "Auth.require_user_or_pat_or_worker" => :machine,
    # -- local wrappers defined in router.ex ----------------------------------
    # with_team_role  -> Auth.require_team_role
    # with_team_site  -> Auth.require_user (or require_user_or_pat + require_ability)
    # require_user_sse -> Accounts.verify_user_session_token / consume_sse_ticket_binding
    # proxy_instance_webhook -> Auth.require_user
    # go_live        -> Auth.require_user_or_pat + Auth.require_ability (POST only)
    # resurrect      -> Auth.require_user (POST only)
    "with_team_role" => :session,
    "with_team_site" => :session,
    "require_user_sse" => :session,
    "proxy_instance_webhook" => :session,
    "go_live" => :session,
    "resurrect" => :session
  }

  @identity_primitive_alternatives [
    ~S(Auth\.require_[a-z_0-9]+),
    ~S(Accounts\.verify_user_session_token),
    ~S(Accounts\.consume_sse_ticket_binding)
  ]

  @identity_primitive_re Regex.compile!(
                           "\\b(?:" <> Enum.join(@identity_primitive_alternatives, "|") <> ")\\("
                         )

  @route_macro_re ~r/^\s*(?:get|post|put|patch|delete|head|options)[\s(]+"([^"]+)"/
  @block_end_re ~r/^  end\s*$/
  @def_head_re ~r/^  defp? ([a-z_][a-zA-Z_0-9]*[?!]?)[\s(]/

  @doc "The classification table: wrapper name => :session | :machine."
  def classification, do: @classification

  @doc "Wrapper names that establish a human/session identity."
  def session_wrappers, do: for({n, :session} <- @classification, do: n)

  @doc "Wrapper names that establish a machine identity (agent token / worker secret)."
  def machine_wrappers, do: for({n, :machine} <- @classification, do: n)

  @doc "The identity-primitive alternatives, as raw regex source, for the vacuity arm."
  def identity_primitive_alternatives, do: @identity_primitive_alternatives

  @doc "Router source with whole-line comments removed."
  def source(path \\ @router_source) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  @doc """
  The wrapper set DERIVED from `router.ex`, as a MapSet of names.

  This is the predicate that replaces the hand-written list. See the moduledoc
  for the exact definition of "wrapper".
  """
  def derive(path \\ @router_source) do
    src = source(path)
    lines = String.split(src, "\n")

    entry_points =
      Regex.scan(~r/\bAuth\.(require_[a-z_0-9]+)\(/, src)
      |> Enum.map(fn [_, name] -> "Auth." <> name end)
      |> MapSet.new()

    route_bodies = route_bodies(lines)
    all_route_text = Enum.join(route_bodies, "\n")

    locals =
      lines
      |> definitions()
      |> Enum.filter(fn {name, body} ->
        Regex.match?(@identity_primitive_re, body) and
          Regex.match?(~r/(?<![a-zA-Z_0-9.])#{Regex.escape(name)}\(/, all_route_text)
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    MapSet.union(entry_points, locals)
  end

  @doc "Every route macro body in the router, as strings. Exposed for the vacuity arm."
  def route_bodies(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, i} ->
      if Regex.match?(@route_macro_re, line), do: [block(line, lines, i)], else: []
    end)
  end

  @doc "Every top-level `def`/`defp` in the router as {name, body}. Exposed for the vacuity arm."
  def definitions(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, i} ->
      case Regex.run(@def_head_re, line) do
        [_, name] -> [{name, block(line, lines, i)}]
        _ -> []
      end
    end)
  end

  # A definition or route head may span several lines. Accumulate the head until
  # it either ENDS in ` do` (block form -> body runs to the next `^  end`) or
  # contains `do:` (inline form -> the head IS the body). The 20-line cap stops a
  # malformed head from swallowing the rest of the file; a bare head that never
  # resolves is returned as itself, which can only UNDER-derive, never
  # mis-derive.
  defp block(line, lines, i) do
    {head_lines, form} = head(lines, i, [line], 0)
    head_text = Enum.join(head_lines, "\n")

    case form do
      :inline ->
        head_text

      :block ->
        lines
        |> Enum.drop(i + length(head_lines))
        |> Enum.take_while(&(not Regex.match?(@block_end_re, &1)))
        |> then(&Enum.join([head_text | &1], "\n"))

      :unresolved ->
        head_text
    end
  end

  defp head(_lines, _i, acc, depth) when depth >= 20, do: {Enum.reverse(acc), :unresolved}

  defp head(lines, i, [current | _] = acc, depth) do
    cond do
      String.contains?(current, "do:") -> {Enum.reverse(acc), :inline}
      Regex.match?(~r/\sdo$/, String.trim_trailing(current)) -> {Enum.reverse(acc), :block}
      true -> next_head_line(lines, i, acc, depth)
    end
  end

  defp next_head_line(lines, i, acc, depth) do
    case Enum.at(lines, i + depth + 1) do
      nil -> {Enum.reverse(acc), :unresolved}
      next -> head(lines, i, [next | acc], depth + 1)
    end
  end
end
