defmodule Barkpark.Tenancy.RolePermitsCallsiteCensusTest do
  @moduledoc """
  CALL-SITE CENSUS for the two DOORS onto the workspace-blind role resolver:
  `Barkpark.Tenancy.Auth.role_permits?/3` and
  `Barkpark.Tenancy.Auth.seat_capabilities/3`.

  ## The ruling this file is the durable venue for

  > lead-security-3, 2026-09-03: a call-site pin IS warranted. role_permits?/3
  > answers true for a built-in role name regardless of workspace id by design;
  > that is safe only while every caller holds a loaded %Membership{} row. The
  > Tenancy.Auth moduledoc states this in prose; prose is not a gate. Cost: one
  > census test that reds when a fourth caller lands, forcing the author to read
  > the provenance rule — the same lever the wave-9 public-surface pin
  > (auth_totality_test.exs @public_surface) already uses. Same pattern, same
  > file family, no new mechanism.

  ## Why the predicate needs a call-site pin and not an argument guard

  `role_permits?("admin", "", :admin)` is `true` on `main` and MUST stay true:
  `granted_actions/2` resolves a built-in role name from the compiled-in
  `@builtin_role_actions` map BEFORE any DB read, workspace-id-independently, so
  a tenant can never redefine `admin` to escalate. A cast guard above that lookup
  would flip four rows true -> false — a silent authorization TIGHTENING, pinned
  against by `AuthTotalityTest`'s "the anti-tightening lock" describe block.

  The safety argument is therefore PROVENANCE, not structure: the
  workspace-blind `true` is unreachable only while every caller reaches the
  function holding a role string that came out of a successfully loaded,
  non-nil `%Membership{}` row. A FIFTH caller that passed a raw request param
  straight in — without loading a membership first — would make it reachable.
  This census is that tripwire: it reds on the day such a caller lands and makes
  its author state the provenance.

  ## Why TWO names, since arpss-w10-bl-collapse-the-caps-fork-into-tenancy-auth

  That slice deleted `caps.ex`'s three `role_permits?/3` sites and replaced them
  with `Tenancy.Auth.seat_capabilities/3`, which resolves the role's action set
  ONCE per membership row. Censusing only `role_permits?/3` after that change
  would have SHRUNK the tripwire to a single in-module site while the reachable
  surface stayed the same size — the census would have gone quiet by being
  outrun, the exact failure mode it exists to prevent. So the predicate names
  both doors.

  `seat_capabilities/3` is the safer door and the count says why, but it is not
  free of the hazard: it takes a `%Membership{}` STRUCT, and a struct can be
  hand-built. Its own answer to that is structural rather than census-based —
  the clause heads bind `%Membership{workspace_id: workspace_id}` to the
  `workspace_id` ARGUMENT, so a fabricated row that names no workspace, or names
  a different one, falls to the all-false catch-all. The census still pins WHO
  calls it, because "which membership load produced this row" is a question only
  the call site can answer.

  ## The census, re-derived (see @expected_callsites)

  The row that commissioned this pin claimed THREE `role_permits?/3` sites at
  `auth.ex:186`, `caps.ex:220`, `caps.ex:249`. Re-derived at the time: FOUR, and
  none of those three line numbers survived. `caps.ex` had grown a third site
  (`role_admits_admin?/2`) when arpss-w10/D22 moved the Studio TOKEN arm onto
  the membership seat. The collapse then moved all three `caps.ex` sites onto
  the new arity, leaving FOUR again with a different shape: ONE
  `role_permits?/3` site (the chokepoint's own user arm) and THREE
  `seat_capabilities/3` sites (all in `caps.ex`, all over a row it loaded
  itself). The count stood still while the whole Studio half changed hands —
  which is why the entries below are keyed by FUNCTION and carry PROVENANCE, not
  a count alone.

  ## Mechanism

  Source-read (`Path.wildcard("lib/**/*.ex")` + `File.read!`), the same
  instrument `Barkpark.Receipts.SentinelOkReturnerLensTest` uses. Comments and
  `@doc`/`@moduledoc` heredocs are stripped, so the many PROSE mentions of
  `role_permits?/3` scattered through `caps.ex`, `share_link_controller.ex` and
  `studio_chrome.ex` do not enter the census — only real call expressions do.
  Sites are keyed by `{path, enclosing function name}`, never by line number: a
  line-anchored pin reds on any insertion above it, which trains readers to
  re-baseline instead of to read.
  """
  use ExUnit.Case, async: true

  # {relative path, enclosing def/defp name} => the MEMBERSHIP LOAD that guards
  # this site. Every entry's provenance must name a loaded, non-nil membership
  # row; a site that cannot state one is a live hole, not a census entry.
  @expected_callsites %{
    {"lib/barkpark/tenancy/auth.ex", "authorize_with_reason"} =>
      "authorize_with_reason/3's %User{} arm: `case membership(user, workspace_id) do %Membership{role: role} ->` — " <>
        "the role is destructured out of the loaded struct; the `nil ->` arm returns {:error, :not_a_member} " <>
        "without reaching the predicate. This site was `authorize/3` until the membership/capability arms " <>
        "were reported apart (task-abc2992adeb04fac); authorize/3 is now a collapse of this function and " <>
        "calls no predicate itself, so the site MOVED without the provenance moving.",
    {"lib/barkpark_web/studio/caps.ex", "derive_from_assigns"} =>
      "Caps.derive_from_assigns/1 passes the row it just loaded: `load_memberships(principals, ws_id)` -> " <>
        "Tenancy.Auth.membership/2 per principal, and the SAME ws_id is the third argument, so the " <>
        "clause heads' `%Membership{workspace_id: workspace_id}` binding holds by construction. A nil " <>
        "membership (non-member) takes the all-false catch-all. ws_id is " <>
        "`assigns[:current_workspace].id` — a loaded struct, never a raw param. " <>
        "This site was `derive/1` until pds-w42 (#16585) split the body out so a caller holding ASSIGNS " <>
        "and no socket could ask the same oracle; `derive/1` is now a one-line delegate and calls no " <>
        "predicate itself, so the site MOVED without the provenance moving — the same shape as " <>
        "`authorize_with_reason` above. The load, the ws_id and the pairing are byte-identical; only the " <>
        "enclosing function name changed.",
    {"lib/barkpark_web/studio/caps.ex", "token_admin_seat?"} =>
      "Caps.admin?/1's token arm: `Tenancy.Auth.membership(token, ws_id)` is loaded INLINE at the call " <>
        "and handed straight in with the same ws_id. It is reached only after " <>
        "`Tenancy.Auth.permits?(token, :admin)`, so a read-only token never loads at all; a non-member " <>
        "loads nil and takes the catch-all.",
    {"lib/barkpark_web/studio/caps.ex", "account_admin_seat?"} =>
      "Caps.admin?/1's account arm: same shape — `Tenancy.Auth.membership(user, ws_id)` loaded inline " <>
        "and passed with the same ws_id. Guarded `is_binary(id) and is_binary(ws_id)`, so a nil-id user " <>
        "or an unresolved workspace denies without a load."
  }

  # A second call added INSIDE an already-pinned function would not change the
  # keyed set, so the raw expression count is pinned alongside it.
  @expected_call_count 4

  # The two doors, named once. `role_permits?/3` answers ONE action from the
  # resolver; `seat_capabilities/3` answers all three off one resolution. Both
  # inherit the built-in map's workspace-id-independence, so both need the
  # provenance rule.
  @resolver_doors ~w(role_permits? seat_capabilities)

  describe "role_permits?/3 call-site census" do
    test "the call-site set on lib/ is exactly the pinned set, each with stated membership provenance" do
      assert MapSet.new(callsites(), fn {path, fun, _line} -> {path, fun} end) ==
               MapSet.new(Map.keys(@expected_callsites)),
             """
             The set of functions calling Tenancy.Auth.role_permits?/3 or
             Tenancy.Auth.seat_capabilities/3 changed.

             Found:    #{inspect(Enum.sort(Enum.map(callsites(), fn {p, f, l} -> "#{p}:#{l} in #{f}" end)), pretty: true)}
             Expected: #{inspect(Enum.sort(Map.keys(@expected_callsites)), pretty: true)}

             Both doors answer TRUE for a built-in role name REGARDLESS of the workspace
             id, by design (see the module doc). That is safe only while every caller
             already holds a successfully loaded, non-nil %Membership{} row.

             If you added a caller: state, in @expected_callsites above, WHICH membership
             load guards it. If you cannot — if the role string or the workspace id can
             come from a request param without a membership load in between — you have
             made the workspace-blind `true` reachable. Do not update this pin; fix the
             caller.
             """
    end

    test "the census is non-vacuous — a broken grep must FAIL, not pass empty" do
      # An equality assertion against a non-empty literal already refuses an
      # empty census, but the instrument itself is asserted here so a wildcard
      # that stops matching (a moved test cwd, a renamed lib/) reds with a
      # message that names the instrument rather than the invariant.
      files = source_files()
      assert length(files) > 100, "source scan found only #{length(files)} lib/**/*.ex files"

      assert Enum.any?(files, &String.ends_with?(&1, "lib/barkpark/tenancy/auth.ex")),
             "the scan did not reach auth.ex — the census cannot be trusted"

      refute Enum.empty?(callsites()), "the call-site scan found ZERO sites"
      assert map_size(@expected_callsites) == 4
    end

    test "the raw call-expression count is pinned, so a second call in a pinned function also reds" do
      assert length(callsites()) == @expected_call_count,
             "call expressions: #{inspect(Enum.map(callsites(), fn {p, f, l} -> "#{p}:#{l} in #{f}" end))}"
    end

    test "every pinned site states a membership load in its provenance" do
      for {{path, fun}, provenance} <- @expected_callsites do
        assert provenance =~ ~r/membership/i,
               "#{path} / #{fun} states no membership load: #{provenance}"
      end
    end
  end

  # --- instrument -----------------------------------------------------------

  defp source_files, do: Path.wildcard("lib/**/*.ex")

  # Returns [{relative_path, enclosing_function_name, line}] for every real call
  # expression (definition heads, @spec and prose excluded).
  defp callsites do
    for path <- source_files(),
        {line_text, idx} <- code_lines(path),
        call_expression?(line_text),
        do: {path, enclosing_function(path, idx), idx + 1}
  end

  # File lines with comments and doc heredocs blanked out, keeping the index so
  # line numbers in failure messages stay true.
  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map_reduce(false, fn {line, idx}, in_heredoc? ->
      fence? = heredoc_fence?(line)

      cond do
        in_heredoc? -> {{"", idx}, not fence?}
        fence? -> {{"", idx}, true}
        String.starts_with?(String.trim_leading(line), "#") -> {{"", idx}, false}
        true -> {{line, idx}, false}
      end
    end)
    |> elem(0)
  end

  # `"""` opening or closing a doc/heredoc block. A line with TWO fences is a
  # one-line heredoc and opens nothing.
  defp heredoc_fence?(line) do
    count = length(String.split(line, ~s("""))) - 1
    rem(count, 2) == 1
  end

  defp call_expression?(line) do
    Enum.any?(@resolver_doors, fn door ->
      String.contains?(line, door <> "(") and
        not Regex.match?(~r/^\s*(defp?\s+|@spec\s+)#{Regex.escape(door)}\(/, line)
    end)
  end

  defp enclosing_function(path, idx) do
    path
    |> code_lines()
    |> Enum.take(idx + 1)
    |> Enum.reverse()
    |> Enum.find_value("<toplevel>", fn {line, _} ->
      case Regex.run(~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_]*[?!]?)/, line) do
        [_, name] -> name
        nil -> nil
      end
    end)
  end
end
