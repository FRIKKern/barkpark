defmodule Barkpark.PdsWriteVerbSeamTest do
  @moduledoc """
  THE WRITE-VERB SEAM MUST NEVER SIT UNDER `stub_mapping_only`'s CITATION ALLOWLIST.

  ## The hazard, stated exactly

  Every other injection seam in this repo replaces a CALLEE. One replaces the
  Repo WRITE ITSELF: `api/lib/mix/tasks/barkpark.rehydrate_body_html.ex` binds
  `persist_fun = Keyword.get(opts, :persist_fun, &Repo.update/1)` and then calls
  `persist_fun.(changeset)` where the production path would call `Repo.update/1`.

  `scripts/pds-elixir-receipt-census.exs`'s `stub_mapping_only` falsifier is
  INVERTED — a store read REFUTES the basis. Its redding half is a substring
  probe, `@repo_tokens`, over the cited test block and its helpers: "DOES read
  Repo — `stub_mapping_only` understates what the suite proves".

  Put those together and the defect is mechanical, not rhetorical. A test that
  injects `:persist_fun` and then reads a row back through `Repo.` satisfies the
  Repo half of the falsifier while proving NOTHING about the production write —
  the write it "verified" was the injected function's. The falsifier would be
  cleared by a test that never exercised the Repo write at all.

  ## Why this is a guard and not a code change

  At the sha this case was written the hazard is LATENT, not live, and the
  measurement says so: the census's `stub_mapping_only` arm checks
  `@stub_citation_allowlist` FIRST and REDS on any citation from outside it, so
  a row citing a seam-injecting test cannot reach the Repo half at all today.
  Narrowing the seam itself would delete a legitimate error-path test for zero
  measured benefit.

  What is actually fragile is the ALLOWLIST. It is a one-line literal, and the
  natural remedy when the arm reds ("re-measure the probe against this file,
  then widen the allowlist") walks straight into the hazard with no warning
  anywhere in the loop. This case is the warning: it fails the moment the
  allowlist and the set of write-verb-injecting tests intersect.

  ## What each test here carries

  * three POSITIVE CONTROLS, so a scanner that silently finds nothing cannot
    green this file — the seam scan, the injection scan and the allowlist parse
    must each return a non-empty set containing a named, committed member;
  * the GUARD itself, over the real tree;
  * a NEGATIVE CONTROL that runs the same predicate over a fixture tree in
    `tmp_dir` carrying the intersection, proving the predicate can red. Every
    scan here takes its root as an argument precisely so the fixture arm reuses
    the guard's own code rather than a re-implementation of it.

  `async: true`: this case only reads committed files and writes into its own
  `tmp_dir`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # THE ROOT-ANCHOR IDIOM, AND WHY IT IS NOT A `"../../../scripts/pds-…"`
  # LITERAL. scripts/pds-door-census.sh's leg-A classifier reads every quoted
  # `("../")+…pds-…` literal under api/lib + api/test and demands that an
  # ATTRIBUTE-BOUND one be dereferenced into `System.cmd`/`Port.open`; anything
  # else is `BOUND-UNEXEC`, an ERROR ("a door pointed at nothing"). This case
  # READS the census as a source file and must never EXECUTE it, so it cannot
  # satisfy that demand and must not make the claim: binding the full relative
  # literal reclassified scripts/pds-elixir-receipt-census.exs from THROUGH to
  # ERROR and orphaned its price row — 2 error rows from one attribute.
  #
  # The root anchor is the shape scripts/elixir-path-escape-check.sh documents
  # for exactly this (its `-root` door: an anchor bound once, then `Path.join`
  # at each read site), and it carries no `pds-` inside a `"../"` literal for
  # the door census to classify.
  @repo_root Path.expand("../../..", __DIR__)
  @census_rel "scripts/pds-elixir-receipt-census.exs"
  @lib_rel "api/lib"
  @test_rel "api/test"

  # Repo functions that WRITE. A seam whose default is one of these replaces the
  # persistence write verb itself, which is the shape `stub_mapping_only`'s
  # Repo-substring falsifier cannot see through.
  @write_verbs ~w(insert insert! update update! delete delete! insert_or_update
                  insert_or_update! insert_all update_all delete_all)

  # `Keyword.get(<anything>, :<opt>, &Repo.<verb>/<arity>)`. Deliberately narrow:
  # this is a TRIPWIRE for a shape that exists once in the tree, not a taxonomy.
  # A seam spelled some other way (Application.get_env, a Mox, a @behaviour) is
  # out of its scope by construction, and the moduledoc says so rather than the
  # regex pretending otherwise.
  @seam_re ~r/Keyword\.get\([^()]*,\s*:([a-z_][a-zA-Z_0-9]*)\s*,\s*&Repo\.([a-z_]+!?)\/\d+\)/

  # The known, committed members every positive control anchors on. If one of
  # these legitimately moves, this file reds and a human re-anchors it — which is
  # the point: an empty scan must never be indistinguishable from a clean tree.
  @known_seam_file "api/lib/mix/tasks/barkpark.rehydrate_body_html.ex"
  @known_seam_opt "persist_fun"
  @known_injecting_test "api/test/barkpark/papers/body_html_render_version_test.exs"
  @known_allowlist_member "api/test/barkpark_web/controllers/github_webhook_controller_test.exs"

  # The three roots, resolved ONCE against this file's own directory. They are
  # resolved here and not in each test because the first draft of this case
  # joined an already-expanded root to a "../../../" literal a second time and
  # every scan silently returned []. The positive controls caught it; that is
  # what they are for.
  defp census_path, do: Path.join(@repo_root, @census_rel)
  defp lib_root, do: Path.join(@repo_root, @lib_rel)
  defp test_root, do: Path.join(@repo_root, @test_rel)

  describe "positive controls — an empty scan must not look like a clean tree" do
    test "the seam scan finds the committed write-verb seam" do
      seams = write_verb_seams(lib_root())

      assert seams != [],
             "the write-verb seam scan found NOTHING in api/lib. Either the tree changed " <>
               "or @seam_re stopped matching — a silent empty scan would green every other " <>
               "assertion in this file."

      assert Enum.any?(seams, fn s ->
               s.path == @known_seam_file and s.opt == @known_seam_opt
             end),
             "the scan no longer finds #{@known_seam_opt} in #{@known_seam_file}. Found: " <>
               inspect(seams)
    end

    test "the injection scan finds the committed injecting test" do
      files = injecting_test_files(test_root(), [@known_seam_opt])

      assert @known_injecting_test in files,
             "no test file was seen injecting `#{@known_seam_opt}:`. Found: #{inspect(files)}"
    end

    test "the allowlist parse returns the census's real literal" do
      allowlist = stub_citation_allowlist(census_path())

      assert allowlist != [],
             "@stub_citation_allowlist parsed EMPTY out of the census. It was renamed or " <>
               "reshaped; an empty parse makes the guard below vacuous."

      assert @known_allowlist_member in allowlist,
             "the parsed allowlist lost its committed member. Parsed: #{inspect(allowlist)}"
    end
  end

  describe "the guard" do
    test "no test cited by `stub_mapping_only` injects a Repo WRITE verb" do
      assert intersection() == [],
             """
             A test file that injects a Repo WRITE verb is inside
             `stub_mapping_only`'s @stub_citation_allowlist.

             That combination defeats the falsifier: the census's redding half is
             the substring probe @repo_tokens over the cited block, and a test
             that injects the write and then reads a row back through `Repo.`
             satisfies it while proving nothing about the production write. The
             row would be refused for "understating what the suite proves" on the
             strength of a write that never happened.

             Fix it by re-citing the row at a test that exercises the real write
             path, or by narrowing the seam so the write verb is not injectable.
             Widening the allowlist is the wrong move and is what this case exists
             to refuse.

             Offending files: #{inspect(intersection())}
             """
    end
  end

  describe "negative control — the guard can red" do
    test "the same predicate reds on a fixture tree carrying the intersection", %{tmp_dir: tmp} do
      lib = Path.join([tmp, "api", "lib"])
      tst = Path.join([tmp, "api", "test"])
      scripts = Path.join(tmp, "scripts")
      File.mkdir_p!(lib)
      File.mkdir_p!(tst)
      File.mkdir_p!(scripts)

      File.write!(Path.join(lib, "fixture_task.ex"), """
      defmodule FixtureTask do
        def persist(cs, opts) do
          persist_fun = Keyword.get(opts, :persist_fun, &Repo.update/1)
          persist_fun.(cs)
        end
      end
      """)

      File.write!(Path.join(tst, "fixture_test.exs"), """
      defmodule FixtureTest do
        test "stub" do
          FixtureTask.persist(cs, persist_fun: fn _ -> {:ok, nil} end)
          assert Repo.get(Doc, 1)
        end
      end
      """)

      census = Path.join(scripts, "census.exs")

      # THE FIXTURE ALLOWLIST NAMES THE INJECTING TEST. This is the one-token
      # mutation: everything else about the fixture tree is honest.
      File.write!(census, ~s|  @stub_citation_allowlist ["api/test/fixture_test.exs"]\n|)

      seams = write_verb_seams(lib)
      assert Enum.any?(seams, &(&1.opt == "persist_fun")), "fixture seam scan found nothing"

      files = injecting_test_files(tst, ["persist_fun"])
      assert "api/test/fixture_test.exs" in files, "fixture injection scan found nothing"

      allowlist = stub_citation_allowlist(census)
      assert allowlist == ["api/test/fixture_test.exs"]

      offenders = for f <- files, f in allowlist, do: f

      assert offenders == ["api/test/fixture_test.exs"],
             "the guard predicate did NOT red on a tree that plainly carries the intersection — " <>
               "it cannot red on the real tree either"
    end

    test "the fixture without the intersection stays green", %{tmp_dir: tmp} do
      tst = Path.join([tmp, "api", "test"])
      scripts = Path.join(tmp, "scripts")
      File.mkdir_p!(tst)
      File.mkdir_p!(scripts)

      File.write!(Path.join(tst, "fixture_test.exs"), """
      defmodule FixtureTest do
        test "stub" do
          FixtureTask.persist(cs, persist_fun: fn _ -> {:ok, nil} end)
        end
      end
      """)

      census = Path.join(scripts, "census.exs")
      File.write!(census, ~s|  @stub_citation_allowlist ["api/test/somewhere_else_test.exs"]\n|)

      files = injecting_test_files(tst, ["persist_fun"])
      allowlist = stub_citation_allowlist(census)

      assert files == ["api/test/fixture_test.exs"]
      assert for(f <- files, f in allowlist, do: f) == []
    end
  end

  # ------------------------------------------------------------------ the scans

  defp intersection do
    opts =
      lib_root()
      |> write_verb_seams()
      |> Enum.map(& &1.opt)
      |> Enum.uniq()

    files = injecting_test_files(test_root(), opts)
    allowlist = stub_citation_allowlist(census_path())

    for f <- files, f in allowlist, do: f
  end

  # Every `Keyword.get(_, :opt, &Repo.<write verb>/N)` under `dir`, as
  # %{path: <repo-relative>, line: n, opt: "…", verb: "…"}.
  defp write_verb_seams(dir) do
    for path <- ex_files(dir, ".ex"),
        {line, idx} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
        [_, opt, verb] <- Regex.scan(@seam_re, line),
        verb in @write_verbs do
      %{path: repo_relative(path), line: idx, opt: opt, verb: verb}
    end
  end

  # Test files that pass any of `opts` as a keyword. The probe is the keyword
  # spelling `opt:` and it OVER-detects (a map key of the same name counts).
  # That direction is the safe one here: the guard refuses an intersection, so a
  # false positive costs a human a re-citation and a false negative costs the
  # falsifier its teeth.
  defp injecting_test_files(dir, opts) do
    probes = Enum.map(opts, fn o -> ~r/(?<![\w:])#{Regex.escape(o)}:\s/ end)

    for path <- ex_files(dir, ".exs"),
        text = File.read!(path),
        Enum.any?(probes, &Regex.match?(&1, text)),
        do: repo_relative(path)
  end

  # @stub_citation_allowlist's literal, read out of the census SOURCE. Read, not
  # transcribed: a copy here would drift the day the census widens the list,
  # which is the exact event this case exists to catch.
  defp stub_citation_allowlist(census_path) do
    text = File.read!(census_path)

    case Regex.run(~r/@stub_citation_allowlist\s*\[([^\]]*)\]/s, text) do
      [_, inner] -> Regex.scan(~r/"([^"]*)"/, inner) |> Enum.map(fn [_, p] -> p end)
      nil -> []
    end
  end

  # A hand-rolled walk, not `Path.wildcard("**/*.ex")`: that glob misses a file
  # sitting DIRECTLY in the root it is anchored at, which silently emptied the
  # fixture scans in this case's first draft.
  defp ex_files(dir, ext) do
    dir
    |> walk()
    |> Enum.filter(&String.ends_with?(&1, ext))
    |> Enum.sort()
  end

  defp walk(path) do
    cond do
      File.dir?(path) ->
        path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1)))

      File.regular?(path) ->
        [path]

      true ->
        []
    end
  end

  # Paths are compared against the census's own citation strings, which are
  # repo-relative ("api/test/…"). Anchor on the LAST "/api/" segment, not the
  # first: ExUnit's `tmp_dir` lives under `api/tmp/…`, so a fixture tree rooted
  # there contains TWO "/api/" segments and splitting on the first one left the
  # whole tmp path glued to the front.
  defp repo_relative(path) do
    case String.split(path, "/api/") do
      [only] -> only
      parts -> "api/" <> List.last(parts)
    end
  end
end
