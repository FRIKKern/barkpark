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

  ## Why ARM A alone certified nothing (r21j)

  `@exempt` removes `safe_url.ex`, and `safe_url.ex` holds the ONLY `:resolver`
  atom node in all of `cloud/lib`. So ARM A's population is empty BY
  CONSTRUCTION and its green is `[] == []`. If `Macro.prewalk` stopped visiting
  keyword keys, if `Code.string_to_quoted!` started raising, or if the wildcard
  resolved against another cwd, ARM A would stay green with the fence gone.
  Its passing state and its broken state are the same state.

  A negative census cannot prove itself by its own emptiness. Two arms do it
  instead, and both run on every invocation rather than living in a PR body:

    * ARM B — POSITIVE CONTROL. Re-run the same scanner with `exempt = []` and
      assert the files it finds are EXACTLY `@exempt`. That is one assertion
      carrying three facts: the walker still resolves a real `:resolver`
      keyword key (it found something), every exempted path still earns its
      exemption (nothing stale), and nothing outside the exempt set is being
      silently swallowed. It is derived from the source on every run — never a
      hand-written site list beside the test.

    * ARM C — NON-VACUITY FLOOR. `ex_sources/1` RAISES on an empty wildcard
      rather than returning `[]`, in the shape `cancelled_producer_census_test`
      already uses, and ARM C points it at a root that does not exist and
      asserts the raise. A scanner that measures nothing now fails loudly
      instead of reporting the fence intact.

  THE CHECK CAN LOSE (mutation proof, reproducible): add a production call
  site, e.g. in `lib/barkpark_cloud/notifications.ex`:

      _probe = SafeUrl.check(url, resolver: fn _, _ -> {:ok, []} end)

  and ARM A reds naming that file:line; green again on revert.
  """
  use ExUnit.Case, async: true

  @lib_root "lib"
  @exempt ["lib/barkpark_cloud/notifications/safe_url.ex"]

  test "ARM A: the :resolver seam is passed nowhere in production cloud/lib code" do
    offenders = resolver_sites(@lib_root, @exempt)

    assert offenders == [],
           """
           :resolver escaped its fence. The seam exists so cloud/test can drive
           SafeUrl's hostname leg without real DNS; a production caller passing
           it disables SSRF resolution wholesale — the DNS-rebinding hole
           SafeUrl's moduledoc names. Remove the call site, or — if a second
           legitimate in-module default ever exists — widen @exempt here, and
           ARM B will then require the new entry to be a real site.

           #{Enum.map_join(offenders, "\n", fn {f, l} -> "  cloud/#{f}:#{l}" end)}
           """
  end

  test "ARM B: positive control — scanning WITHOUT @exempt finds exactly the exempt files" do
    sites = resolver_sites(@lib_root, [])
    found_files = sites |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    assert sites != [],
           """
           POSITIVE CONTROL LOST. Scanning every .ex under cloud/#{@lib_root} with NO
           exemptions found ZERO :resolver atom nodes — but safe_url.ex's own
           `Keyword.get(opts, :resolver, &:inet.getaddrs/2)` is one. So the walker
           itself is broken (Macro.prewalk no longer visiting keyword keys,
           Code.string_to_quoted! shape change, wrong cwd), and ARM A's green above
           measured nothing. Fix the scanner before trusting the fence.
           """

    assert found_files == Enum.sort(@exempt),
           """
           The exempt set and the actual :resolver sites in cloud/#{@lib_root} disagree.

             @exempt: #{inspect(Enum.sort(@exempt))}
             found:   #{inspect(found_files)}

           An entry in @exempt with no site behind it is a dead exemption that
           silently widens the fence for a path nobody is watching — delete it.
           A found file missing from @exempt should have reddened ARM A; if ARM A
           is green and this is not, the two arms disagree about the same scan and
           the scanner is the suspect.
           """
  end

  test "ARM C: non-vacuity floor — a root with no sources RAISES, it does not pass" do
    absent =
      Path.join(
        System.tmp_dir!(),
        "safe-url-ratchet-no-such-root-#{System.unique_integer([:positive])}"
      )

    refute File.exists?(absent)

    assert_raise RuntimeError, ~r/no \.ex sources under/, fn ->
      resolver_sites(absent, @exempt)
    end

    # And the floor is not merely decorative: the real root DOES clear it.
    assert ex_sources(@lib_root) != []
  end

  # Every .ex file under `root`. RAISES rather than returning [] — an empty
  # scan must fail loudly, never report the fence intact having read nothing.
  defp ex_sources(root) do
    files = root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()

    if files == [] do
      raise "SafeUrlResolverRatchet: no .ex sources under #{root}. " <>
              "The tree moved, or the suite's cwd is not cloud/. " <>
              "Refusing to certify the :resolver fence having measured nothing."
    end

    files
  end

  defp resolver_sites(root, exempt) do
    root
    |> ex_sources()
    |> Enum.reject(&(&1 in exempt))
    |> Enum.flat_map(&resolver_atom_sites/1)
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
