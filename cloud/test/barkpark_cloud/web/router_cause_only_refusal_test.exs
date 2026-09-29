defmodule BarkparkCloud.Web.RouterCauseOnlyRefusalTest do
  @moduledoc """
  Tripwire: EVERY cause-only refusal in `router.ex` must sit under a guard whose
  tier matches the tier its route-table row declares.

  ## The blind spot this exists to close

  `RouterTierLens`'s refusal lens (cch-w40-s5) reads a POST-GUARD ELEVATION off
  one shape and one shape only: `Auth.forbidden(conn, required: "…")`. That is
  correct — the tier is in the bytes, so it can be read. A refusal that names a
  CAUSE instead (`reason: "outranked"`, `reason: "no_team"`) carries no tier at
  all, so the lens cannot read one, and today that is harmless: every cause-only
  site already sits under a guard whose tier is the tier its row declares.

  The residual is structural, and it is the class this file guards:

  > A future post-guard refusal that ELEVATES the tier while reporting only a
  > cause is invisible to the elevation lens. The outer guard says `user`, the
  > row says `user`, the two agree — and the body 403s the member anyway. The
  > row goes green over a lie, which is the exact defect cch-w40-s5 was built to
  > end for the authority-bearing half.

  This file cannot read a tier out of a refusal that states none — nothing can.
  What it CAN do is pin the property that makes their invisibility safe: every
  cause-only site is hosted by a route whose guard tier and whose declared tier
  are the same value. The moment a cause-only refusal appears under a route
  where those two diverge — which is what an elevating cause-only refusal does
  to the row someone then "fixes" — this reds and names the site.

  ## Refusal, never a clear

  Anything the derivation cannot resolve FAILS. Specifically:

    * an `Auth.forbidden(` call that does not close on its own line
      (`:unparsable`) — half-reading a multi-line refusal is how a `required:`
      on the second line gets misfiled as a cause;
    * a refusal carrying neither `required:` nor `reason:` (`:unclassified`) —
      a third shape nobody has ruled on;
    * a cause-only site inside no block at all, or inside a helper that no route
      and no other helper reaches — an unattributable refusal;
    * a hosting route whose guard the lens will not resolve and that is NOT in
      `RouterTierLens.unresolved_consent/0`, or whose row the moduledoc table
      does not give a tier for.

  The only pass this file grants without comparing two tiers is a host route the
  route-table census has ALREADY ruled unresolvable by name (today: `GET
  /v1/events`, which authenticates inline). That ruling is not made here and it
  cannot rot here: `router_moduledoc_table_test.exs` asserts, in both
  directions, that every consented row still exists and is still genuinely
  unresolvable. Nothing else is skipped or defaulted to a pass.

  ## The limit of the claim

  This asserts "guard tier == declared tier at every cause-only site". It does
  NOT assert that either value is the RIGHT one (that ruling is the charter's,
  not a regex's), and it does not execute a single request — it is a pure parse
  of `router.ex` source through `RouterTierLens`, the SAME resolver the route
  table census trusts. The population is DERIVED on every run; no count is
  pinned, because the population has already grown since this residual was filed
  (the filing said two sites; main carries four).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.RouterTierLens, as: Lens

  # Bounded fixpoint for helper attribution. Two hops carries a refusal out of a
  # helper, through a helper that calls it, into the route bodies — the same
  # depth-2 reach `Lens.guard_in/3` walks in the other direction.
  @max_hops 4

  defp sites, do: Lens.refusal_sites()

  defp cause_only, do: Enum.filter(sites(), &(&1.kind == :cause_only))

  defp fmt_sites(list),
    do: Enum.map_join(list, "\n", fn s -> "  router.ex:#{s.line}  #{s.text}" end)

  # ── Positive controls ──────────────────────────────────────────────────────
  #
  # A scan that finds nothing asserts nothing. Both halves of the classifier are
  # pinned non-empty: an empty CAUSE-ONLY population makes this whole file
  # vacuous, and an empty AUTHORITY population means the classifier stopped
  # discriminating and is calling everything a cause.

  test "the scan finds a cause-only population at all (this file is not vacuous)" do
    assert sites() != [],
           "RouterTierLens.refusal_sites/1 found no Auth.forbidden/2 call sites in " <>
             "router.ex. The seam was renamed or the scan stopped matching; every " <>
             "assertion below would be vacuously green."

    assert cause_only() != [], """
    No cause-only refusal was found in router.ex. Either every refusal now names
    an authority — in which case DELETE this file and say so in the commit — or
    the classifier stopped recognising `reason:`. It must not pass by finding
    nothing.

    All refusal sites the scan did find:
    #{fmt_sites(sites())}
    """
  end

  test "the classifier still discriminates: authority-bearing refusals are found too" do
    authority = Enum.filter(sites(), &(&1.kind == :authority))

    assert authority != [], """
    No `Auth.forbidden(conn, required: …)` site was found. A classifier that
    calls every refusal cause-only would make the census below assert something
    much weaker than it claims, and it would silently disarm the elevation lens
    in `RouterTierLens` as well.

    All refusal sites the scan did find:
    #{fmt_sites(sites())}
    """
  end

  test "every refusal site classifies; an unreadable one refuses rather than clears" do
    unreadable = Enum.filter(sites(), &(&1.kind in [:unparsable, :unclassified]))

    assert unreadable == [], """
    #{length(unreadable)} `Auth.forbidden/2` site(s) could not be classified.

    `:unparsable` — the call does not close on its own line, so its keywords
    cannot be read; reading only the first line would misfile a `required:` on
    the second as a cause. `:unclassified` — the call carries neither
    `required:` nor `reason:`, a refusal shape nobody has ruled on.

    Either put the call back on one line, or extend
    `RouterTierLens.refusal_sites/1` to read the new shape. Do not skip it.

    #{fmt_sites(unreadable)}
    """
  end

  # ── The census ─────────────────────────────────────────────────────────────

  test "every cause-only refusal sits under a guard whose tier matches its row" do
    results = Enum.map(cause_only(), &verdict/1)

    failures = Enum.reject(results, & &1.ok?)

    assert failures == [], """
    #{length(failures)} cause-only refusal(s) in router.ex are NOT vouched for by
    a tier-matching guard. A refusal that states only a cause carries no tier in
    its bytes, so the elevation lens cannot see it; the only thing that keeps
    that safe is the route around it enforcing exactly the tier its row
    advertises. Where those diverge, the row is a lie an agent, a CLI author or
    an SDK author will read as truth.

    #{Enum.map_join(failures, "\n\n", & &1.report)}

    The full derived cause-only population this run measured:
    #{fmt_sites(cause_only())}
    """

    # A green states WHAT it measured, never only that it passed: the derived
    # population and the host route each site was vouched for by.
    IO.puts("""

    router.ex cause-only refusal census
      Auth.forbidden/2 call sites : #{length(sites())}
      cause-only (no authority)   : #{length(cause_only())}
    #{Enum.map_join(cause_only(), "\n", &measured/1)}
    """)

    assert length(results) == length(cause_only())
  end

  defp measured(site) do
    hosts =
      case host_routes(site) do
        {:ok, routes} -> Enum.map_join(routes, ", ", fn {m, p} -> "#{m} #{p}" end)
        {:error, why} -> why
      end

    "      router.ex:#{String.pad_trailing(to_string(site.line), 6)} -> #{hosts}"
  end

  # A site's verdict: `%{ok?: boolean, report: binary}`. Every arm that cannot
  # answer returns `ok?: false` with the reason — never a silent pass.
  defp verdict(site) do
    case host_routes(site) do
      {:error, why} ->
        fail(site, why)

      {:ok, []} ->
        fail(site, "attributed to no route at all")

      {:ok, routes} ->
        bad = Enum.flat_map(routes, &route_mismatch/1)

        if bad == [],
          do: %{ok?: true, report: ""},
          else:
            fail(
              site,
              "hosted by #{length(routes)} route(s); these do not check out:\n" <>
                Enum.map_join(bad, "\n", &("      " <> &1))
            )
    end
  end

  defp fail(site, why),
    do: %{ok?: false, report: "  router.ex:#{site.line}  #{site.text}\n    -> #{why}"}

  # `nil` when the route's guard and its declared tier agree; a one-line
  # explanation otherwise — including when either value cannot be had.
  defp route_mismatch({method, path} = key) do
    declared = Lens.declared_tier(method, path)

    # The SAME consent-aware guard the route-table census compares its rows
    # against (`Lens.route_guard/3`), so this file cannot mint a second opinion
    # about a row that census has already ruled on. Both consent lists live in
    # the lens and are asserted in BOTH directions by
    # `router_moduledoc_table_test.exs`, so neither can rot into a free pass.
    case {Lens.censused_tier_of(method, path), declared} do
      {_, nil} ->
        ["#{method} #{path}: no tier-bearing row in the moduledoc route table"]

      {{:ok, guard_tier}, declared} ->
        if guard_tier == Lens.normalize_tier(declared),
          do: [],
          else: [
            "#{method} #{path}: guard enforces #{inspect(guard_tier)}, " <>
              "row declares #{inspect(declared)}"
          ]

      {{:error, reason}, _} ->
        if Map.has_key?(Lens.unresolved_consent(), key),
          do: [],
          else: ["#{method} #{path}: the lens will not resolve a guard (#{inspect(reason)})"]
    end
  end

  # Which ROUTES host a refusal. A site inside a route block is hosted by that
  # route. A site inside a helper is hosted by every route that reaches the
  # helper, directly or through another helper — a bounded fixpoint over the
  # SAME block texts `Lens.blocks/1` returns, so nothing here re-parses the
  # router a second time.
  defp host_routes(site) do
    case Lens.block_at(site.line) do
      nil ->
        {:error, "sits inside no route and no function block — unattributable"}

      {:route, key} ->
        {:ok, [key]}

      {:def, name} ->
        climb(MapSet.new([name]), MapSet.new([name]), MapSet.new(), 0)
    end
  end

  defp climb(frontier, seen, routes, hops) do
    cond do
      MapSet.size(frontier) == 0 and MapSet.size(routes) == 0 ->
        {:error,
         "sits in helper(s) #{inspect(MapSet.to_list(seen))} that no route and no " <>
           "other helper calls — unattributable, so no tier can vouch for it"}

      MapSet.size(frontier) == 0 ->
        {:ok, MapSet.to_list(routes)}

      hops >= @max_hops ->
        {:error,
         "helper chain from #{inspect(MapSet.to_list(seen))} still unresolved after " <>
           "#{@max_hops} hops — refusing rather than guessing a host"}

      true ->
        {new_routes, called_by} = callers_of(frontier)
        next = MapSet.difference(called_by, seen)

        climb(
          next,
          MapSet.union(seen, next),
          MapSet.union(routes, new_routes),
          hops + 1
        )
    end
  end

  # Every route body and every helper clause that CALLS one of `names` with the
  # whole conn. A call, never a mention: full-line comments go first, and the
  # `(?<![\w.])` guard keeps `Foo.no_team(conn)` and `bare_no_team(conn)` from
  # matching `no_team`.
  defp callers_of(names) do
    {routes, defs} = Lens.blocks()

    res = Enum.map(names, &call_re/1)
    hit? = fn text -> Enum.any?(res, &Regex.match?(&1, uncommented(text))) end

    hit_routes =
      routes
      |> Enum.filter(fn {_key, body} -> hit?.(body) end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    hit_defs =
      defs
      |> Enum.reject(fn {name, _clauses} -> MapSet.member?(names, name) end)
      |> Enum.filter(fn {_name, clauses} -> Enum.any?(clauses, hit?) end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    {hit_routes, hit_defs}
  end

  defp call_re(name), do: ~r/(?<![\w.])#{Regex.escape(name)}\(conn\b/

  defp uncommented(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end
end
