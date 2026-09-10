defmodule BarkparkCloud.FailureCopyScrubRegisterTest do
  @moduledoc """
  THE REGISTER: `BarkparkCloud.FailureCopy.scrub/1` has exactly one caller —
  `failure_copy.ex` itself. Every display boundary calls `FailureCopy.raw/1`
  (`strip_ansi |> scrub`) or `FailureCopy.humanize/1`, never the scrub directly.

  ## Why this exists, and why it is not the order tripwire

  `scripts/failure-copy-scrub-order-check.sh` (dr-w22-bl-scrub-order-tripwire)
  reds when a boundary calls `scrub` BEFORE `strip_ansi`. It is a good gate and
  it stays. But it is a gate on how a hand-rolled boundary is SPELLED, and this
  epic has now hand-fixed that spelling three times (dr-w22-s1's three
  `scrub_entry/2` sites, its review's fourth in `deployment_json/1`, and the
  four collapsed by dr-w23-bl). A rule about how to spell a two-step composition
  is only ever as good as the next author's attention.

  This test asks a question that has no spelling: is the composition being
  hand-rolled AT ALL? Post-collapse the answer is no, everywhere, and that is a
  property a grep can hold forever. A boundary that cannot name `scrub` cannot
  order it wrongly — the order tripwire's failure mode is unreachable through
  any site this register admits.

  ## Why the selector is `scrub(` and not `strip_ansi(`

  Two legitimate `FailureCopy.strip_ansi/1` callers survive the collapse on
  purpose (`event_email.ex`'s `cause_then_capture/1` and `router.ex`'s
  `class_then_capture/1` both bind `stripped` to feed `humanize/1`, and their
  own comments say why). A `strip_ansi`-based register would red on correct
  code, and a gate that reds on correct code gets relaxed — the relaxation is
  what lets the next hand-rolled boundary in.

  ## Why a module-qualified match is sound here

  It is sound only while nothing `import`s the module — an import makes a bare
  `scrub(x)` legal and invisible to a qualified match. So the import ban is
  asserted below as a PRECONDITION of the register, not as a separate nicety,
  and `alias …FailureCopy, as: X` is resolved per file so `X.scrub(` is caught
  under whatever name it was given.

  ## Comments are in scope, deliberately

  Same doctrine as the order tripwire: prose that spells the banned call is the
  same defect one step upstream, and stripping comments before matching is a
  hole an offender walks through by adding a `#`. The fixtures below live under
  `cloud/test`, which the register does not scan, so this module is honestly
  clean under its own predicate without any self-exclusion by filename.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib", __DIR__)
  @exempt "failure_copy.ex"

  defmodule Scan do
    @moduledoc false

    @doc """
    Names every `FailureCopy.scrub(` call site in `sources` (a
    `%{path => text}` map), resolving per-file `alias …FailureCopy, as: X`.
    Returns `{offenders, hits}` where `hits` is the raw match count — the
    denominator, so an empty scan cannot pass for a clean one.
    """
    def offenders(sources) do
      Enum.flat_map(sources, fn {path, text} ->
        # Resolve the names ONCE per file. Calling `names(text)` inside the
        # per-line filter re-ran the alias Regex.scan over the whole file for
        # EVERY line — quadratic in file size, and on a loaded CI runner the
        # whole-tree scan blew ExUnit's 60 s timeout (Cloud gate flapped twice
        # on main on 2026-09-10 with this test as the single failure).
        needles = Enum.map(names(text), &(&1 <> ".scrub("))

        text
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          Enum.any?(needles, &String.contains?(line, &1))
        end)
        |> Enum.map(fn {line, n} -> {path, n, String.trim(line)} end)
      end)
    end

    @doc "The module names `FailureCopy.scrub/1` is reachable under in this file."
    def names(text) do
      aliased =
        Regex.scan(~r/alias\s+[\w.]*FailureCopy\s*,\s*as:\s*([A-Z][\w.]*)/, text)
        |> Enum.map(fn [_, as] -> as end)

      ["FailureCopy" | aliased]
    end

    @doc "A file that `import`s FailureCopy defeats a module-qualified match."
    def importers(sources) do
      for {path, text} <- sources,
          Regex.match?(~r/^\s*import\s+[\w.]*FailureCopy\b/m, text),
          do: path
    end

    def explain(offenders) do
      body =
        Enum.map_join(offenders, "\n", fn {p, n, line} -> "  #{p}:#{n}\n    > #{line}" end)

      """
      A file in cloud/lib other than failure_copy.ex names FailureCopy.scrub( :

      #{body}

      A display boundary must not hand-roll `strip_ansi |> scrub`. Call
      `FailureCopy.raw/1` — it IS that composition, in that order, and it is the
      one place the order can be got wrong. If you need the stripped value for
      something else too (`humanize/1`), bind `strip_ansi/1` separately and still
      take the redacted bytes from `raw/1`.
      """
    end
  end

  setup_all do
    sources =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, @lib_root), File.read!(&1)})

    {exempt, scanned} = Map.split(sources, [Path.relative_to(exempt_path(), @lib_root)])
    %{scanned: scanned, exempt: exempt, all: sources}
  end

  defp exempt_path, do: Path.join([@lib_root, "barkpark_cloud", @exempt])

  describe "the register over cloud/lib" do
    test "no file but failure_copy.ex names FailureCopy.scrub(", %{
      scanned: scanned,
      exempt: exempt
    } do
      # ── controls, before the verdict ──────────────────────────────────────
      # 1. the scan root exists and was really walked
      assert map_size(scanned) > 100,
             "scanned #{map_size(scanned)} .ex files under #{@lib_root} — the register is not covering cloud/lib"

      # 2. the exemption resolved to a REAL file. A typo'd exemption path makes
      #    `scanned` a superset and the test stricter, which is safe; a typo'd
      #    SELECTOR makes it vacuous, which is not. So:
      assert map_size(exempt) == 1, "the failure_copy.ex exemption did not resolve to a file"

      # 3. THE ANTI-VACUITY CONTROL, in two halves. A selector that matches
      #    nothing reports a clean tree, which is the failure mode this whole
      #    register exists to avoid reproducing.
      #
      #    (a) the selector is LIVE: it fires on a string this test builds, so a
      #        typo in it fails here rather than greening cloud/lib.
      assert Scan.offenders(%{"control.ex" => "  x = FailureCopy.scrub(y)"}) != [],
             "the selector `FailureCopy.scrub(` did not fire on a literal call — it is measuring nothing"

      #    (b) the ban has a SUBJECT: `failure_copy.ex` still defines the
      #        function. Note it never names itself module-qualified, which is
      #        exactly why (a) cannot be sourced from it — a control read off the
      #        exempt file would be a control that flips for the wrong reason.
      assert exempt |> Map.values() |> hd() =~ "def scrub(",
             "#{@exempt} no longer defines scrub/1 — this register is banning calls to a function that is gone"

      # 4. the module-qualified match is only sound while nothing imports the
      #    module, so that is a precondition, not a footnote.
      assert Scan.importers(Map.merge(scanned, exempt)) == [],
             "a file imports FailureCopy, which makes a bare `scrub(` legal and invisible to this register"

      # ── the verdict ───────────────────────────────────────────────────────
      offenders = Scan.offenders(scanned)
      assert offenders == [], Scan.explain(offenders)
    end
  end

  describe "the predicate is able to fail" do
    test "names a plain module-qualified call" do
      src = "defmodule Boundary do\n  def a(d), do: FailureCopy.scrub(d)\nend\n"
      assert [{"boundary.ex", 2, _}] = Scan.offenders(%{"boundary.ex" => src})
    end

    test "names an ALIASED-AS call under the name it was given" do
      src = """
      defmodule Boundary do
        alias BarkparkCloud.FailureCopy, as: FC

        def a(d), do: d |> FC.strip_ansi() |> FC.scrub()
      end
      """

      assert [{"boundary.ex", 4, _}] = Scan.offenders(%{"boundary.ex" => src})
    end

    test "names it in a COMMENT too — prose is the defect one step upstream" do
      src = "defmodule B do\n  # do it like FailureCopy.scrub(x)\nend\n"
      assert [{"b.ex", 2, _}] = Scan.offenders(%{"b.ex" => src})
    end

    test "passes the collapsed shape: raw/1, plus a surviving strip_ansi binding" do
      src = """
      defmodule Boundary do
        def a(d), do: FailureCopy.raw(d)

        def b(v) do
          stripped = FailureCopy.strip_ansi(v)
          capture = FailureCopy.raw(v)
          {stripped, capture}
        end
      end
      """

      assert Scan.offenders(%{"boundary.ex" => src}) == []
    end

    test "does not fire on prose naming the ARITY form the doc uses" do
      src =
        "defmodule B do\n  @moduledoc \"raw/1 = strip_ansi/1 THEN FailureCopy.scrub/1\"\nend\n"

      assert Scan.offenders(%{"b.ex" => src}) == []
    end

    test "the import precondition is able to fail" do
      assert Scan.importers(%{
               "b.ex" => "defmodule B do\n  import BarkparkCloud.FailureCopy\nend\n"
             }) ==
               ["b.ex"]
    end
  end
end
