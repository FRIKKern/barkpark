defmodule BarkparkCloud.Notifications.SafeUrlResolverRatchetTest do
  @moduledoc """
  THE RATCHET UNDER `SafeUrl`'s `:resolver` SEAM (cch-w29-bl).

  cch-w29-s2 gave `SafeUrl.check/2` an optional `:resolver` so the hostname
  leg (resolve-then-check) is testable without asking a third party's DNS
  whether the repo may merge. A seam is an affordance: nothing else in the
  repo stops a production caller passing `resolver:` and disabling the SSRF
  resolution wholesale — the exact hole the moduledoc says resolution exists
  to close (DNS rebinding to 169.254.169.254).

  THE RULE: the atom `:resolver` may appear in `cloud/lib` ONLY inside
  `lib/barkpark_cloud/notifications/safe_url.ex` (its own
  `Keyword.get(opts, :resolver, …)` default). Everywhere else — a keyword
  argument (`resolver: fun`), a bare atom (`Keyword.put(opts, :resolver, f)`),
  a map key (`%{resolver: f}`) — reds this census by file:line.

  WHY AN AST WALK AND NOT A GREP: "resolver:" is ordinary prose in this tree
  (`domain_status.ex` narrates "the resolver: a raise, an exit, …"), so a
  textual grep is either noisy on moduledocs or blind once it tries to skip
  them. `Macro.prewalk` over `Code.string_to_quoted!` sees only real syntax:
  prose lives inside string literals the walk treats as opaque values, a
  VARIABLE or function named `resolver` is a `{:resolver, meta, ctx}` 3-tuple
  whose name atom the traversal never visits separately, while a keyword pair
  or a bare atom IS visited. What this cannot see — `String.to_atom/1`
  construction at runtime — is recorded here as out of scope; it has no
  call-site shape a static census can pin.

  THE CHECK CAN LOSE (mutation proof, re-run to reproduce): add a production
  call site, e.g. in `lib/barkpark_cloud/notifications.ex`:

      _probe = SafeUrl.check(url, resolver: fn _, _ -> {:ok, [{1, 2, 3, 4}]} end)

  and this census reds naming that file:line; green again on revert. The
  observed run is quoted in the PR that landed this file.
  """
  use ExUnit.Case, async: true

  @exempt ["lib/barkpark_cloud/notifications/safe_url.ex"]

  test "the :resolver seam is passed nowhere in production cloud/lib code" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reject(&(&1 in @exempt))
      |> Enum.flat_map(&resolver_atom_sites/1)

    assert offenders == [],
           """
           :resolver escaped its fence. The seam exists so cloud/test can drive
           SafeUrl's hostname leg without real DNS; a production caller passing
           it disables SSRF resolution wholesale — the DNS-rebinding hole
           SafeUrl's moduledoc names. Remove the call site, or — if a second
           legitimate in-module default ever exists — widen @exempt here and
           say why in the PR body.

           #{Enum.map_join(offenders, "\n", fn {f, l} -> "  cloud/#{f}:#{l}" end)}
           """
  end

  # Walk the AST tracking the most recent line metadata, collecting
  # {file, line} for every bare `:resolver` atom node. Keyword pairs
  # (`resolver: v`) are 2-tuples the traversal descends into, so their key
  # atom is visited; variables and function heads named `resolver` are
  # 3-tuples whose name atom is not.
  defp resolver_atom_sites(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    {_, {sites, _line}} =
      Macro.prewalk(ast, {[], 1}, fn
        {_, meta, _} = node, {sites, line} when is_list(meta) ->
          {node, {sites, Keyword.get(meta, :line, line)}}

        :resolver, {sites, line} ->
          {:resolver, {[{file, line} | sites], line}}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end
end
