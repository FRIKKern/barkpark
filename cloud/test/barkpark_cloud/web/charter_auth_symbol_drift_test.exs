defmodule BarkparkCloud.Web.CharterAuthSymbolDriftTest do
  @moduledoc """
  Charter prose vs. the router's live auth vocabulary.

  `router_auth_wrapper_registry_test.exs` pins the wrapper SET against
  `router.ex`. This file pins the NAMES THE CHARTER SPELLS against the same
  source, which is the surface a human reads and the one nothing guarded: D896
  states in a sentence that twelve charter citations name symbols #15871
  renamed away, and a sentence reds nothing.

  Every arm here is a predicate over two derived sets plus a declaration block
  that is itself checked against source in both directions. Nothing in this file
  is a name someone has to remember to update.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Web.CharterAuthSymbols, as: Symbols

  test "every auth symbol the charter cites is defined in source, or declared retired" do
    cited = Symbols.cited()
    live = Symbols.live()
    declared = Symbols.retired_names()

    undeclared = cited |> MapSet.difference(live) |> MapSet.difference(declared)

    assert MapSet.equal?(undeclared, MapSet.new()), """
    The charter cites #{MapSet.size(undeclared)} auth symbol(s) that neither
    auth.ex nor router.ex defines, and that the RETIRED-AUTH-SYMBOLS block does
    not declare:

    #{undeclared |> Enum.sort() |> Enum.map_join("\n", &("  " <> &1))}

    A reader who greps the codebase for a name this charter gave them finds
    nothing, and cannot tell whether the charter or the code is the wrong one.

    Fix, in the SAME commit as whatever renamed it: either re-spell the citation
    with the live name, or — if the row is a dated record that should keep the
    name it was written with — add a line to the RETIRED-AUTH-SYMBOLS block in
    .claude/workflows/bp-cloud-console-hardening-charter.md:

        dead_name -> live_name   # one line on what happened

    The replacement is checked against source too, so it cannot point nowhere.
    """
  end

  test "a declared retired symbol is really gone (the ratchet's other direction)" do
    # A ratchet fails in two directions. The arm above catches the charter
    # falling BEHIND the code. This one catches the declaration outliving its
    # reason: if a name declared dead is defined again, the block is now the
    # stale surface, and it is silently excusing a citation that needs no
    # excuse.
    resurrected = MapSet.intersection(Symbols.retired_names(), Symbols.live())

    assert MapSet.equal?(resurrected, MapSet.new()), """
    #{MapSet.size(resurrected)} symbol(s) declared retired are DEFINED in source again:

    #{resurrected |> Enum.sort() |> Enum.map_join("\n", &("  " <> &1))}

    Delete their lines from the RETIRED-AUTH-SYMBOLS block. While they sit
    there, the arm above cannot red on a citation of that name, so the
    declaration is now the thing hiding drift instead of recording it.
    """
  end

  test "every declared replacement is itself a live symbol" do
    live = Symbols.live()

    dangling =
      Symbols.retired()
      |> Enum.reject(fn {_dead, replacement, _why} -> MapSet.member?(live, replacement) end)

    assert dangling == [], """
    #{length(dangling)} retirement(s) point at a name nothing defines:

    #{Enum.map_join(dangling, "\n", fn {d, r, _} -> "  #{d} -> #{r}" end)}

    A pointer to nowhere is the same defect one hop along: it sends the reader
    to a second name that also does not exist. Point each at the symbol that
    actually replaced it, or at the nearest live entry point that does the job.
    """
  end

  test "every retirement says why, in its own words" do
    silent = Symbols.retired() |> Enum.filter(fn {_, _, why} -> why == "" end)

    assert silent == [], """
    #{length(silent)} retirement(s) carry no reason:

    #{Enum.map_join(silent, "\n", fn {d, r, _} -> "  #{d} -> #{r}" end)}

    Write the `# why` comment. A bare rename pair reads as a typo fix; the next
    reader needs to know whether the behaviour moved with the name.
    """
  end

  test "the arms still read their sources (guard against a vacuous green)" do
    # Every assertion above is a difference of two sets. If either extractor
    # stops matching, the differences go empty and all four arms pass on
    # nothing. These floors are far below the measured values (2026-09-17: 10
    # cited, 17 live, 3 declared) and far above zero.
    cited = Symbols.cited()
    live = Symbols.live()

    assert MapSet.size(cited) >= 8,
           "the charter citation regex matched #{MapSet.size(cited)} symbols; the extractor has broken"

    assert MapSet.size(live) >= 10,
           "only #{MapSet.size(live)} require_* definitions found in auth.ex + router.ex; the reader has broken"

    assert Symbols.retired() != [],
           "the RETIRED-AUTH-SYMBOLS block parsed empty — an absent or malformed block would make " <>
             "arm 1 red rather than pass, but arms 2-4 would go vacuous"

    # The citation predicate is NARROW on purpose. `Code.require_file` and the
    # plug atom `[:api, :require_admin]` are in the charter and are not Elixir
    # auth-wrapper citations; if the predicate ever widens to a bare
    # `require_*` scan it sweeps them in and arm 1 reds on prose.
    refute MapSet.member?(cited, "require_file"),
           "the citation predicate has widened and is now matching Code.require_file"

    refute MapSet.member?(cited, "require_admin"),
           "the citation predicate has widened and is now matching the [:api, :require_admin] pipeline atom"

    # The control the whole file rests on: the LIVE half must contain the names
    # the retirements point at, sourced from the definition scan and not from a
    # literal here.
    assert MapSet.member?(live, "require_current_team_admin"),
           "auth.ex no longer defines require_current_team_admin; the rename that motivated this file has moved again"
  end
end
