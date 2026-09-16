defmodule BarkparkCloud.Web.RouterAuthWrapperRegistryTest do
  @moduledoc """
  THE ANTI-DRIFT ARM over the auth-wrapper set.

  `router_head_fence_census_test.exs` pins four INTEGERS derived through a list
  of wrapper names. This file pins the LIST ITSELF against the router, so the
  list cannot be the thing that is wrong. Charter decision D34 enumerated eight
  wrappers; the router held more, and every number rebuilt from D34's text came
  out wrong with no gate anywhere going red. An enumeration is a snapshot; this
  file is the predicate that replaces it.

  The membership of the set is DERIVED from `router.ex` on every run
  (`RouterAuthWrappers.derive/0`, whose moduledoc states the exact predicate).
  Only the session/machine CLASSIFICATION is hand-written, because no parser can
  make that call.

  BOTH DIRECTIONS FAIL:

    * a wrapper in the router that the registry does not classify -> RED, by
      name (the dangerous direction: an unclassified wrapper makes the routes
      behind it count PUBLIC in the census);
    * a name in the registry that the router no longer contains -> RED, by name
      (the stale direction, which is how a list rots quietly).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Web.RouterAuthWrappers, as: Registry

  test "every auth wrapper in the router is classified by the registry" do
    derived = Registry.derive()
    registered = MapSet.new(Map.keys(Registry.classification()))

    unclassified = MapSet.difference(derived, registered)

    assert MapSet.equal?(unclassified, MapSet.new()), """
    The router contains #{MapSet.size(unclassified)} authentication wrapper(s)
    the registry does not classify:

    #{unclassified |> Enum.sort() |> Enum.map_join("\n", &("  " <> &1))}

    THIS IS THE DANGEROUS DIRECTION. The GET census classifies a route by
    looking for a registered wrapper NAME in its body, so a route gated by an
    unregistered wrapper counts as PUBLIC — the number moves, but it moves in
    the reassuring direction and reads as "a public route was added".

    Fix: add each name to @classification in
    cloud/test/support/router_auth_wrappers.ex with :session (a human or
    session-token identity) or :machine (an agent token or the internal worker
    shared secret), and say in one line what primitive it reaches. Then re-run
    router_head_fence_census_test.exs and move its baseline if the new wrapper
    gates a GET.
    """
  end

  test "every name the registry classifies still exists in the router" do
    derived = Registry.derive()
    registered = MapSet.new(Map.keys(Registry.classification()))

    stale = MapSet.difference(registered, derived)

    assert MapSet.equal?(stale, MapSet.new()), """
    The registry classifies #{MapSet.size(stale)} name(s) the router no longer
    has:

    #{stale |> Enum.sort() |> Enum.map_join("\n", &("  " <> &1))}

    A wrapper was renamed or deleted. Remove or rename the entry in
    cloud/test/support/router_auth_wrappers.ex in the SAME commit — a registry
    that still lists a dead name is how the next reader concludes the census
    counts something it does not.
    """
  end

  test "the derivation still reads the source (guard against a vacuous green)" do
    lines = Registry.source() |> String.split("\n")
    derived = Registry.derive()

    assert length(lines) > 5_000,
           "router.ex is #{length(lines)} lines after comment-stripping; the reader has broken"

    assert length(Registry.route_bodies(lines)) > 100,
           "the route-macro regex has stopped matching router.ex"

    assert length(Registry.definitions(lines)) > 100,
           "the def/defp regex has stopped matching router.ex"

    # A derivation that found only `Auth.*` names would look healthy while
    # having lost the whole local-wrapper half — that half is 9 of the GET
    # census's session routes.
    locals = Enum.reject(derived, &String.starts_with?(&1, "Auth."))

    assert length(locals) >= 4,
           "expected the local-wrapper half of the derivation to survive; got #{inspect(locals)}"

    assert Enum.any?(derived, &String.starts_with?(&1, "Auth.")),
           "expected the Auth.require_* half of the derivation to survive"
  end

  test "every identity primitive the derivation keys on still appears in the router" do
    # The primitive vocabulary is the derivation's one remaining literal. If a
    # primitive is renamed and this list is not, the derivation quietly loses
    # reach and BOTH directions above go green on a shrunken set. This arm turns
    # that into a red.
    src = Registry.source()

    for alt <- Registry.identity_primitive_alternatives() do
      re = Regex.compile!("\\b(?:" <> alt <> ")\\(")

      assert Regex.match?(re, src), """
      The identity primitive `#{alt}` no longer appears in router.ex.

      Either it was renamed — update @identity_primitive_alternatives in
      cloud/test/support/router_auth_wrappers.ex to the new name — or it is
      genuinely gone, in which case delete the alternative and the wrapper that
      used it. Leaving it here makes the derivation look wider than it is.
      """
    end
  end

  test "the registry classifies both kinds, and the machine set is the narrow one" do
    session = Registry.session_wrappers()
    machine = Registry.machine_wrappers()

    assert session != [] and machine != [],
           "both classes must be populated; a one-class registry classifies nothing"

    assert length(machine) < length(session),
           "machine wrappers are expected to stay the narrow set; got #{length(machine)} vs #{length(session)}"

    assert MapSet.disjoint?(MapSet.new(session), MapSet.new(machine)),
           "a wrapper cannot be both classes"
  end
end
