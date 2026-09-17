defmodule BarkparkCloud.Web.CharterAuthSymbols do
  @moduledoc """
  THE CHARTER-SIDE HALF OF THE AUTH-WRAPPER ANTI-DRIFT ARM.

  `RouterAuthWrappers` (#18618) stopped the router's wrapper SET from being a
  hand-written list. D896 then removed D34's stale enumeration from the charter
  and named that derivation as the authority. Neither touched the third surface,
  and it is the one a human actually reads: the charter's PROSE still spells
  auth-wrapper symbols by name, 40+ times, and nothing anywhere checks that the
  names it spells are names `router.ex`/`auth.ex` still contain.

  It had already rotted. The two `require_primary_team_*` gates were renamed
  `require_current_team_admin`/`_owner` in #15871; D896 says so in one sentence
  and twelve charter citations kept the dead spelling regardless, because a
  sentence is not a gate. A reader who greps the codebase for a name the charter
  gave them finds nothing and has to guess whether the charter or the code is
  wrong.

  THE SIBLING GUARD, AND WHY THIS FILE IS NOT IT.
  `auth_gate_name_census_test.exs` already bans those retired identifiers — but
  it scans `cloud/lib`, `cloud/priv/static` and `cloud/test`, and its moduledoc
  puts `.claude/workflows/` DELIBERATELY out of scope, because rewriting a dated
  record falsifies it. That exemption is correct and this file keeps it: the
  charter is allowed to carry the old name, on condition that it declares what
  replaced it. The two halves are complementary — one forbids the name in live
  code, the other requires an explanation for it in the log.

  (This module therefore never spells either retired identifier literally, or
  the sibling census would red on this very file.)

  WHAT COUNTS AS A CITATION, precisely (this is the predicate, stated once):

      a token matching `require_[a-z_0-9]+` in the charter that is written
      EITHER qualified as `Auth.<name>` OR with an Elixir arity suffix
      `<name>/N`.

  That is how this charter cites an Elixir function, and the qualifier is what
  keeps the rule off unrelated prose: `Code.require_file` and the plug-pipeline
  atom `[:api, :require_admin]` both appear in the charter, are neither
  `Auth.`-qualified nor arity-suffixed, and are correctly not citations.
  (Measured: the narrow predicate yields 10 distinct symbols; a bare
  `require_*` scan yields 18 and sweeps in both of those.)

  LIVE means DEFINED IN SOURCE — a `def`/`defp require_*` head in `auth.ex` or
  `router.ex` — not merely called. A citation naming something nothing defines
  is the defect regardless of who calls it.

  THE RETIRED-SYMBOL DECLARATION. A charter is a dated decision log, so a row
  written in 2026-07 may legitimately name the symbol that existed THEN. The
  allowance is therefore not a skip list but a declaration that carries its own
  replacement, parsed out of the charter's `RETIRED-AUTH-SYMBOLS` block:

      <!-- RETIRED-AUTH-SYMBOLS
      dead_name -> live_name   # why
      -->

  and every field of it is checked against source in BOTH directions by
  `CharterAuthSymbolDriftTest` — a declared dead name that the router DEFINES
  again reds (the ratchet's other direction: the block may not outlive its
  reason), and a replacement that is not itself live reds (a pointer to nowhere
  is the same defect one hop along).
  """

  @charter Path.expand(
             "../../../.claude/workflows/bp-cloud-console-hardening-charter.md",
             __DIR__
           )
  @auth_source Path.expand("../../lib/barkpark_cloud/web/auth.ex", __DIR__)
  @router_source Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)

  @citation_re ~r/(?:\bAuth\.(require_[a-z_0-9]+)|\b(require_[a-z_0-9]+)\/\d)/
  @definition_re ~r/\bdefp? (require_[a-z_0-9]+)/
  @block_re ~r/<!--\s*RETIRED-AUTH-SYMBOLS\s*\n(.*?)-->/s
  @entry_re ~r/^\s*([a-z_0-9]+)\s*->\s*([a-z_0-9]+)\s*(?:#(.*))?$/

  def charter_path, do: @charter
  def auth_source, do: @auth_source
  def router_source, do: @router_source

  @doc "The charter, verbatim."
  def charter, do: File.read!(@charter)

  @doc """
  Every auth-wrapper symbol the charter CITES, as a MapSet of bare names.
  See the moduledoc for the exact citation predicate.
  """
  def cited(text \\ nil) do
    (text || charter())
    |> then(&Regex.scan(@citation_re, &1))
    |> Enum.map(fn
      [_, "", name] -> name
      [_, name] -> name
      [_, name, _] -> name
    end)
    |> MapSet.new()
  end

  @doc """
  Every `require_*` symbol DEFINED in `auth.ex` or `router.ex`, as a MapSet.
  This is the live vocabulary a citation is checked against.
  """
  def live(sources \\ nil) do
    (sources || [@auth_source, @router_source])
    |> Enum.flat_map(fn path ->
      @definition_re |> Regex.scan(File.read!(path)) |> Enum.map(fn [_, n] -> n end)
    end)
    |> MapSet.new()
  end

  @doc """
  The declared retired symbols, as `[{dead, replacement, why}]`, parsed from the
  charter's `RETIRED-AUTH-SYMBOLS` block. `[]` when the block is absent — the
  drift test treats that as a red, not as "nothing to check".
  """
  def retired(text \\ nil) do
    case Regex.run(@block_re, text || charter(), capture: :all_but_first) do
      [body] ->
        body
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(@entry_re, line, capture: :all_but_first) do
            [dead, live_name] -> [{dead, live_name, ""}]
            [dead, live_name, why] -> [{dead, live_name, String.trim(why)}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  @doc "Declared dead names only."
  def retired_names(text \\ nil), do: text |> retired() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
end
