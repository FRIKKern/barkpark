defmodule Barkpark.Tenancy.RolePermitsCallsiteCensusTest do
  @moduledoc """
  CALL-SITE CENSUS for `Barkpark.Tenancy.Auth.role_permits?/3`.

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

  ## The census, re-derived from `main` (see @expected_callsites)

  The row that commissioned this pin claimed THREE sites at
  `auth.ex:186`, `caps.ex:220`, `caps.ex:249`. Re-derived here: there are FOUR,
  and none of those three line numbers survives. `caps.ex` grew a third site
  (`role_admits_admin?/2`) when arpss-w10/D22 moved the Studio TOKEN arm onto
  the membership seat. All four still hold a loaded row, so the count moved
  without the invariant moving — which is exactly the drift a prose statement
  cannot detect and this file can.

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
    {"lib/barkpark/tenancy/auth.ex", "authorize"} =>
      "authorize/3's %User{} arm: `case membership(user, workspace_id) do %Membership{role: role} ->` — " <>
        "the role is destructured out of the loaded struct; the `nil ->` arm returns {:error, :forbidden} " <>
        "without reaching the predicate.",
    {"lib/barkpark_web/studio/caps.ex", "membership_authorizes?"} =>
      "Caps.derive/1: `memberships = load_memberships(principals, ws_id)` -> Tenancy.Auth.membership/2 per " <>
        "principal. This clause matches `%{role: role}` and is guarded `when is_binary(role)`; the FIRST " <>
        "clause `membership_authorizes?(_principal, nil, _ws_id, _action), do: false` denies a non-member " <>
        "before it. ws_id is `socket.assigns[:current_workspace].id` — a loaded struct, never a raw param.",
    {"lib/barkpark_web/studio/caps.ex", "account_admin_from"} =>
      "Caps.derive/1 -> admin_from/3 over the SAME load_memberships/2 rows. Clause head is " <>
        "`%Barkpark.Accounts.User{}, %{role: role}, ws_id when is_binary(role) and is_binary(ws_id)`; the " <>
        "catch-all `account_admin_from(_,_,_), do: false` takes a nil membership.",
    {"lib/barkpark_web/studio/caps.ex", "role_admits_admin?"} =>
      "Two feeders, both membership-derived. (a) token_admin_from/3, pattern-matched on `%{role: role}` " <>
        "from load_memberships/2. (b) token_admin_seat?/2 in admin?/1, which passes " <>
        "`Tenancy.Auth.membership_role(token, ws_id)` — a role string that EXISTS only when membership/2 " <>
        "returned a row, and is nil otherwise, which the `when is_binary(role)` guard sends to the " <>
        "`false` catch-all."
  }

  # A second call added INSIDE an already-pinned function would not change the
  # keyed set, so the raw expression count is pinned alongside it.
  @expected_call_count 4

  describe "role_permits?/3 call-site census" do
    test "the call-site set on lib/ is exactly the pinned set, each with stated membership provenance" do
      assert MapSet.new(callsites(), fn {path, fun, _line} -> {path, fun} end) ==
               MapSet.new(Map.keys(@expected_callsites)),
             """
             The set of functions calling Tenancy.Auth.role_permits?/3 changed.

             Found:    #{inspect(Enum.sort(Enum.map(callsites(), fn {p, f, l} -> "#{p}:#{l} in #{f}" end)), pretty: true)}
             Expected: #{inspect(Enum.sort(Map.keys(@expected_callsites)), pretty: true)}

             role_permits?/3 answers TRUE for a built-in role name REGARDLESS of the
             workspace id, by design (see the module doc). That is safe only while every
             caller already holds a successfully loaded, non-nil %Membership{} row.

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
    String.contains?(line, "role_permits?(") and
      not Regex.match?(~r/^\s*(defp?\s+|@spec\s+)role_permits\?\(/, line)
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
