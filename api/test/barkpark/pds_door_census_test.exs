defmodule Barkpark.PdsDoorCensusTest do
  @moduledoc """
  The PDS door census (`scripts/pds-door-census.sh`) computes the epic's price
  column — how many `scripts/pds-*.{sh,exs}` instruments actually run under a
  required gate, and, for every one that does not, which of PDS-D637's five
  classes (plus HUMAN-GATE) explains the refusal.

  ## Why this case exists at all

  An instrument that counts the ungated instruments and is itself ungated is the
  20th ungated instrument. `api/test/**` rides the already-required `Elixir gate`
  context, so shelling the census here wires it to a required gate without
  touching a byte of `.github/`. Its own row must — and does — appear as THROUGH
  in its own output; that is asserted below, not assumed.

  ## Why the assertion on `--check` is a DESCENT, not a fixed polarity

  `--check` is fail-closed: it exits non-zero while any `scripts/pds-*` program
  is undisposed. Pinning `rc == 0` would be a standing invitation to soften the
  census into greenness; pinning `rc != 0` would be a permanent red that the
  first honest dispositions turn into a lie. So what is asserted is the epic's
  own law — **the exit code DESCENDS from the printed counts**: rc is 0 exactly
  when `UNDISPOSED` and `ERRORS` are both 0, and non-zero otherwise. A receipt
  lies when the value it emits does not descend from the write.

  And a green that costs nothing to produce is not a gate, so the red is proven
  BY MUTATION rather than by hoping for one: a copy of the census with a single
  disposition row deleted must exit non-zero and must say which instrument it
  could not dispose. The mutant is written next to its siblings under `scripts/`
  (dot-prefixed, so the census's own `pds-*` glob does not enumerate it) because
  the census resolves `elixir-path-escape-check.sh` relative to its own
  `BASH_SOURCE` — a copy in `tmp` would have no ratchet to execute for leg B.

  `--check` runs ONCE, in `setup_all`, and every case reads that one output: its
  own price column says the run costs ~1.1 s CPU at load1 3.26 (it read 3.3 s at
  load1 41.63 — not comparable, PDS-D656), and a price printed here is paid.

  ## Why the fraud arm is mandatory

  PDS-D649: a one-line COMMENT naming a real instrument, plus the declaration
  `elixir-path-escape-check.sh`'s own ratchet then demands, buys a FRAUDULENT
  THROUGH from a classifier whose leg A is "`System.cmd` appears somewhere in
  the file". Wave 44's prototype used exactly that predicate and passed the
  fraud. The census's `--selftest` reproduces the mutated shape and asserts the
  comment stays out; this case asserts the arm is present and green rather than
  quietly deleted.

  ## The meter blind spot

  PDS-D633/D646 obliges every meter-derived number in this epic to carry the
  blind-spot sentence in the instrument's `@moduledoc` AND its printed output.
  A green ExUnit case prints nothing, so the printed half can only land on the
  instrument — and it is asserted here so a copy-paste cannot drop it:
  `:erlang.statistics(:runtime)` is blind to port children, and an OS meter
  around a BEAM that fans out to child BEAMs is blind to the whole fan-out. The
  blindness errs in the one direction a price column must not — it makes an
  expensive thing look gate-able.

  `async: false`: the case shells a subprocess that walks the whole
  `api/lib` + `api/test` tree with awk and execs the path ratchet once per
  instrument row. It has no business racing the async lane.
  """
  use ExUnit.Case, async: false

  # The census walks two trees and execs `elixir-path-escape-check.sh --match`
  # once per row; ExUnit's 60 s default is thin headroom on a loaded runner.
  @moduletag timeout: 300_000

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it (and its matching
  # ELIXIR_TEST_ONLY_PATHS entry) a PR touching ONLY the census would compute
  # changes.outputs.test == 'false', mix-test would be LEGITIMATELY skipped, and
  # the instrument's own guard would not run on the very PR that changed it.
  # #9290 and #9292 are the record: each touched ONLY an instrument, and on each
  # head `Test (Elixir …)` concluded `skipped` while `Elixir gate` passed.
  @census_rel "../../../scripts/pds-door-census.sh"

  setup_all do
    census = Path.expand(@census_rel, __DIR__)

    unless File.regular?(census) do
      flunk(
        "the gate is pointed at nothing: #{census} does not exist. " <>
          "Do not skip this test — a skip here is D26 (green fixtures executed by nothing). " <>
          "Fix the path or delete the instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the door census " <>
            "cannot be run. Failing loud rather than skipping."
        )

    root = Path.expand("../../..", __DIR__)

    # ONE `--check`, shared by every case below. `cd: root` is load-bearing: the
    # census enumerates `scripts/` and walks `api/lib` + `api/test` relative to
    # the tree it was invoked from, so a run from elsewhere would census an empty
    # tree and pass vacuously.
    {check_out, check_rc} =
      System.cmd(bash, [census, "--check"], cd: root, stderr_to_stdout: true)

    {:ok, census: census, bash: bash, root: root, check_out: check_out, check_rc: check_rc}
  end

  # Reads one of the census's own printed count lines, e.g. `UNDISPOSED : 0 of 20`.
  # It FLUNKS rather than defaulting when the line is absent: a missing count is
  # a broken instrument, and a helper that answered 0 there would manufacture the
  # exact green this case exists to refuse.
  defp counted!(out, label) do
    case Regex.run(~r/#{label}\s+:\s+(\d+)(?: of (\d+))?/, out) do
      [_, n | _] -> String.to_integer(n)
      nil -> flunk("the census printed no `#{label}` count line at all.\n#{out}")
    end
  end

  test "the door census's --selftest is GREEN, and its fraud arm is one of the arms", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.census, "--selftest"], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0, "expected `bash #{@census_rel} --selftest` to exit 0, got #{rc}:\n#{out}"

    assert out =~ "SELFTEST GREEN — exit 0",
           "the census exited 0 without printing its own green verdict — an exit code alone is " <>
             "not a receipt (the epic's law since wave 22). Output:\n#{out}"

    assert out =~ "THE FRAUD: comment naming a real instrument in a System.cmd file",
           "the comment-mutation arm is gone. That arm is the whole reason leg A carries three " <>
             "predicates instead of one; without it the selftest proves nothing that matters.\n#{out}"

    assert out =~ "the weak predicate would have passed it",
           "the fraud arm no longer asserts that the fixture DOES contain System.cmd, so it can " <>
             "no longer tell a strict leg A from the weak one.\n#{out}"

    # Anchored to the start of an arm line — the summary line legitimately reads
    # "0 FAIL of 8 arms", and a naive substring refute would red on the green.
    refute out =~ ~r/^\s+FAIL\s/m,
           "the selftest printed a FAIL arm while exiting 0 — the exit code did not descend " <>
             "from the arms.\n#{out}"

    assert out =~ ~r/SELFTEST: (\d+) PASS \/ 0 FAIL of \1 arms/,
           "the selftest's PASS count and arm count disagree, so its verdict does not descend " <>
             "from its arms.\n#{out}"

    # WAVE 47's ARMS, named here for the same reason the fraud arm is: an arm
    # that can be quietly deleted is an arm the suite cannot miss. Each of these
    # covers a shape that passed on main in TOTAL SILENCE — rc=0, ERRORS 0, and
    # a COUNTS block byte-identical to the unmutated run.
    for arm <- [
          "ORPHANED PRICE FIRES",
          "CROSS-LEDGER CONTRADICTION",
          "A RETIRE COSTUME DOES NOT EXEMPT AN ORPHANED PRICE",
          "A RETIRED- PRICE IS REFUSED",
          "AN UNANCHORED PREFIX IN FRONT OF CPU= IS REFUSED",
          "THE PARTITION PRINTS THE FULL VOCABULARY INCLUDING ZEROES",
          "THE SUM IS ASSERTED"
        ] do
      assert out =~ arm,
             "the `#{arm}` arm is gone from the selftest. It covers a silence that was live on " <>
               "main — a price row nobody pays, a retire costume on a price, or a class the " <>
               "COUNTS block could not see — and without it the repair has no guard.\n#{out}"
    end
  end

  test "--check's EXIT CODE DESCENDS from its own printed UNDISPOSED and ERRORS counts", ctx do
    out = ctx.check_out
    rc = ctx.check_rc

    undisposed = counted!(out, "UNDISPOSED")
    errors = counted!(out, "ERRORS")

    if undisposed == 0 and errors == 0 do
      assert rc == 0,
             "the census printed UNDISPOSED 0 and ERRORS 0 and then exited #{rc}. The exit code " <>
               "does not descend from the rows — which is the exact defect this epic is named " <>
               "after, landed inside the instrument that measures it.\n#{out}"
    else
      assert rc != 0,
             "the census printed UNDISPOSED #{undisposed} / ERRORS #{errors} and exited 0. A " <>
               "green that costs nothing to produce is not a gate.\n#{out}"
    end

    assert errors == 0,
           "the census reported #{errors} unclassifiable test-side reference(s) or malformed " <>
             "ledger row(s). Those are ERRORS, not UNDISPOSED rows, and they mean the classifier " <>
             "met a shape it does not model — fix the shape or the classifier, never the count." <>
             "\n#{out}"
  end

  test "IT CAN RED: a census with one disposition row deleted exits non-zero and names the row",
       ctx do
    source = File.read!(ctx.census)

    anchor = "pds-window-sentinel.sh\tNOT-YET-BUILT\t"

    assert String.contains?(source, anchor),
           "the mutation anchor #{inspect(anchor)} is gone from the census, so this fail-demo " <>
             "proves nothing. Re-anchor it on a live disposition row rather than deleting the demo."

    mutant_line =
      source
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, anchor))

    # The mutant lives next to its siblings under scripts/, dot-prefixed so the
    # census's own `pds-*` glob cannot enumerate it: the census resolves
    # elixir-path-escape-check.sh from its own BASH_SOURCE, so a copy in tmp
    # would have no ratchet to exec for leg B and would red for the wrong reason.
    mutant =
      Path.join(
        Path.dirname(ctx.census),
        ".pds-door-census-mutant-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(mutant, String.replace(source, mutant_line <> "\n", "", global: false))
    on_exit(fn -> File.rm(mutant) end)

    {out, rc} = System.cmd(ctx.bash, [mutant, "--check"], cd: ctx.root, stderr_to_stdout: true)

    assert rc != 0,
           "a census missing a disposition row exited #{rc}. It cannot tell a disposed inventory " <>
             "from an undisposed one, which makes its green above vacuous.\n#{out}"

    assert out =~ ~r/UNDISPOSED\s+:\s+1 of \d+/,
           "the mutant reddened without counting the row it lost.\n#{out}"

    assert out =~ "UNDISPOSED: pds-window-sentinel.sh",
           "the mutant exited non-zero without naming the instrument it could not dispose — an " <>
             "exit code that does not descend from the rows is not a receipt.\n#{out}"
  end

  test "the denominator is the {sh,exs} glob, and the census PRINTS which convention it used",
       ctx do
    out = ctx.check_out

    assert out =~ "ls -1 scripts/pds-*.sh scripts/pds-*.exs",
           "the census stopped naming its enumeration command. A bare `scripts/pds-*` glob is " <>
             "43 files, 24 of them .md/.txt, and collapses the fraction 2.3x.\n#{out}"

    assert out =~ ~r/CONVENTION USED: (WITH-HARNESSES|PEERS-ONLY)/,
           "the census stopped printing which denominator convention it used. Both 19 " <>
             "(with harnesses) and 16 (peers only) are defensible, so an unprinted choice " <>
             "makes the denominator underivable by a reader (PDS-D650).\n#{out}"

    # SAID ON PURPOSE, and TWO slices landed a harness here. main already carried
    # scripts/pds-window-sentinel_test.sh (PDS-D717's retirement of D193 leg (ii));
    # this slice adds scripts/pds-published-artifact-door_test.sh. Both are real
    # harnesses by the derived *_test.sh rule and both ride a required gate, so
    # both belong in the WITH-HARNESSES denominator rather than being excluded to
    # keep an older number. The count below is RE-DERIVED by running the census on
    # the merged tree — never by adding this slice's delta to main's figure.
    # WITH-HARNESSES denominator rather than being excluded to keep this 3.
    # A THIRD slice lands one: scripts/pds-pull-proof_test.sh, the offline harness
    # for full_meta_ok (PDS-D261). It is a harness by the same derived *_test.sh
    # rule and it rides a required gate through api/test/barkpark/pds_pull_proof_test.exs,
    # so it belongs in the WITH-HARNESSES denominator. Excluding it to keep the 5
    # is the one move this pin exists to refuse. RE-DERIVED by running the census
    # on this tree — it prints `harnesses : 6` and names the file — never by
    # adding this slice's delta to main's figure.
    assert out =~ ~r/harnesses\s+: 6 /,
           "the derived harness count moved off 6. Harness-hood is derived from the " <>
             "*_test.sh / *.test.sh name; if a seventh harness landed, say so on purpose.\n#{out}"

    assert out =~ "pds-pull-proof_test.sh",
           "the census stopped naming pds-pull-proof_test.sh among its derived harnesses. " <>
             "The count above would still read 6 if a DIFFERENT harness had replaced it, so " <>
             "the count alone does not pin which files it counted.\n#{out}"
  end

  test "it RIDES ITS OWN DOOR: its own row is THROUGH in its own output", ctx do
    out = ctx.check_out

    assert out =~ ~r/pds-door-census\.sh\s+yes\s+true\s+THROUGH/,
           "the instrument that counts ungated instruments does not appear THROUGH in its own " <>
             "output — which makes it the 20th ungated instrument. Check that this file still " <>
             "binds #{@census_rel} to an attribute and dereferences it into System.cmd, and " <>
             "that scripts/elixir-path-escape-check.sh still declares the path.\n#{out}"

    # The landed door count is DERIVED from the rows, and it is an Enum.count over
    # the names the census printed — never an addition, and never a number the
    # charter remembers. Before this slice's own door it was 3.
    [_, through, total] = Regex.run(~r/THROUGH a required gate\s+:\s+(\d+) of (\d+)/, out)

    named =
      out
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "    -> "))
      |> String.replace_prefix("    -> ", "")
      |> String.split(" ", trim: true)

    assert Enum.count(named) == String.to_integer(through),
           "the THROUGH count and the list of THROUGH instruments disagree — one of them does " <>
             "not descend from the rows.\n#{out}"

    assert "pds-door-census.sh" in named,
           "this instrument is not in its own THROUGH list.\n#{out}"

    # And the summary must descend from the TABLE, not from a separate counter:
    # the named set is the same set as the rows the column marked THROUGH.
    table_through =
      out
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        # THE COLUMN PRINTS REPO-RELATIVE PATHS SINCE THE DENOMINATOR REACHED
        # tooling/pds (wave 49), so the row no longer begins at `pds-`. The
        # optional directory prefix is OUTSIDE the capture: what is compared
        # against the summary list is still the BASENAME, which is what both
        # ledgers are keyed by. This makes the parser match MORE rows than it
        # did, never fewer — an unprefixed `pds-…` row still matches.
        case Regex.run(~r/^\s+(?:\S*\/)?(pds-\S+)\s+\S+\s+\S+\s+THROUGH\s/, line) do
          [_, name] -> [name]
          nil -> []
        end
      end)

    assert Enum.sort(table_through) == Enum.sort(named),
           "the THROUGH summary line and the THROUGH rows of the table are different sets. " <>
             "The summary is then a transcription, not a derivation.\n#{out}"

    assert String.to_integer(total) >= 19,
           "the population fell below origin/main's 19 scripts/pds-*.{sh,exs} programs — the " <>
             "enumerator is broken, not the repo tidy.\n#{out}"

    # THE DOOR COUNT HAS A FLOOR, and it is the only assertion in this repository
    # that can see it fall. Everything above is SELF-CONSISTENCY: the count agrees
    # with the named list, the named list agrees with the table, this instrument
    # is in it. Replayed against a real census output whose THROUGH count had
    # fallen to 3 of 20, EVERY ONE OF THEM PASSED — 3 named, 3 table rows, own row
    # THROUGH, 2 PRICE rows, population 20. A set that agrees with itself agrees
    # with itself just as well after a door is lost.
    #
    # Where main stands, plus what this slice wires. main reached 5 with
    # pds-window-sentinel_test.sh; this slice adds BOTH the published-artifact
    # door and its selftest, each attribute-bound and executed by
    # api/test/barkpark/pds_published_artifact_door_test.exs. RAISE this number
    # when a slice wires another door; a slice that has to LOWER it is removing a
    # door from a required gate, which is a decision, not a diff. RE-DERIVED on
    # the merged tree by running the census, not by arithmetic on two branches.
    assert String.to_integer(through) >= 7,
           "the THROUGH door count fell to #{through}. Nothing else here can see that: every " <>
             "other assertion in this case is self-consistency, and a smaller set is still " <>
             "consistent with itself. Either a door stopped being gated, or a shape check " <>
             "re-classified one — a malformed price is a fact about the LEDGER and must never " <>
             "move a fact about the WIRING (PDS-D667).\n#{out}"
  end

  test "it PRINTS the D633 meter blind-spot sentence — never as prose a copy-paste can drop",
       ctx do
    out = ctx.check_out

    assert out =~ "METER BLIND SPOT (PDS-D633/D646)",
           "the blind-spot sentence is gone from the census's printed output. D633's own " <>
             "closing clause is that the sentence must ship in the instrument's @moduledoc AND " <>
             "its printed output; prose is what a copy-paste drops.\n#{out}"

    assert out =~ "makes an expensive thing look gate-able",
           "the sentence survived in name but lost the direction of the error, which is the " <>
             "only part a price column has to know.\n#{out}"
  end

  test "every PRICE row carries CPU (user+sys) labelled LOCAL or FOREIGN with the meter named",
       ctx do
    out = ctx.check_out

    price_rows =
      out
      |> String.split("\n")
      |> Enum.filter(&String.match?(&1, ~r/^\s+(?:\S*\/)?pds-\S+\s+\S+\s+\S+\s+PRICE\s/))

    assert length(price_rows) >= 2,
           "fewer than two PRICE rows in the column. PDS-D648's unit ruling is only worth " <>
             "asserting while something is priced.\n#{out}"

    # ZERO DOWNWARD HEADROOM, so the filter's INDEPENDENCE is pinned rather than
    # left to luck. The filter matches any line whose 4th whitespace token is the
    # literal `PRICE`, and wave 47 added an error line that begins with a `pds-*`
    # basename and carries the word PRICE — worded `<basename>: ORPHANED PRICE —`
    # precisely so its 4th token is the em dash and not `PRICE`. Had it been
    # worded `PRICE ORPHAN PRICE row unread`, this filter would have swallowed it
    # into `price_rows` and the CPU= assertion below would have reddened on a
    # message that is not a price row at all.
    orphan_price_line =
      "  pds-fx-shut.sh: ORPHANED PRICE — the price ledger carries a row for it, " <>
        "but this run classed it ENVIRONMENT, not THROUGH."

    assert Enum.filter(
             [orphan_price_line],
             &String.match?(&1, ~r/^\s+(?:\S*\/)?pds-\S+\s+\S+\s+\S+\s+PRICE\s/)
           ) ==
             [],
           "the ORPHANED PRICE error line is captured by this test's own PRICE-row filter, so " <>
             "an error message would be asserted against as though it were a row of the price " <>
             "column. Re-word the message so its 4th whitespace token is not the literal PRICE."

    # THE HOST AXIS HAS TWO LEGAL VALUES SINCE WAVE 48, AND THIS REGEX IS THE
    # HALF OF THE PIN THAT LIVES ON THE REQUIRED GATE. It is deliberately NOT
    # `\S+` in that slot: the census's own `price_shape_error` refuses a price
    # wearing neither token, and a rider that accepted anything there would let
    # a widened-into-a-hole grammar ride green. The dot-radix `[\d.]+` is the
    # other half — it is what rejects the PDS-D691 comma fabrication
    # (`CPU=0+1=1,00s`), which every substring glob in the census accepts.
    for row <- price_rows do
      assert row =~ ~r/CPU=[\d.]+\+[\d.]+=[\d.]+s (?:LOCAL|FOREIGN) meter=/,
             "a PRICE row quotes something other than CPU=user+sys=total, LOCAL or FOREIGN, with " <>
               "the meter named. Wall is not a property of the door on a shared host (a fixed " <>
               "workload swung 5.8x at constant load), user alone understates the hetzner door " <>
               "2.1x because sys exceeds user, and a CPU second with no host axis beside it is " <>
               "not comparable to anything.\nRow: #{row}"

      refute row =~ ~r/\bwall\b.*=/,
             "a PRICE row quotes a wall figure as the price. Wall belongs in the column only " <>
               "as an explicitly non-quotable note.\nRow: #{row}"
    end
  end

  test "the COUNTS block ACCOUNTS FOR every row of the column, zeroes included", ctx do
    out = ctx.check_out

    [_, _through, total] = Regex.run(~r/THROUGH a required gate\s+:\s+(\d+) of (\d+)/, out)
    total = String.to_integer(total)

    # EVERY declared class, INCLUDING THE ONES AT ZERO. HUMAN-GATE is at zero
    # right now and the charter records that as a live finding — a `uniq -c`
    # remedy prints five lines here and silently drops the sixth, which is the
    # one worth printing.
    band_counts =
      for class <-
            ~w(PRICE ENVIRONMENT NOT-YET-BUILT CONTENT-RED RED-BY-DESIGN-REPORTER HUMAN-GATE) do
        case Regex.run(~r/^\s+#{Regex.escape(class)}\s+:\s+(\d+) of (\d+)\s*$/m, out) do
          [_, n, m] ->
            assert String.to_integer(m) == total,
                   "the #{class} band prints a denominator of #{m} against a population of " <>
                     "#{total} — two denominators in one block.\n#{out}"

            {class, String.to_integer(n)}

          nil ->
            flunk("the COUNTS block printed no line for the declared class #{class}.\n#{out}")
        end
      end

    assert {"HUMAN-GATE", 0} in band_counts,
           "HUMAN-GATE is no longer printed at zero. If a door was placed behind a human gate, " <>
             "raise this on purpose; if the line vanished because the class emptied, the block " <>
             "went back to hiding the fact the charter records.\n#{out}"

    accounted =
      case Regex.run(~r/ACCOUNTED FOR\s+:\s+(\d+) of (\d+)/, out) do
        [_, n, m] -> {String.to_integer(n), String.to_integer(m)}
        nil -> flunk("the COUNTS block printed no `ACCOUNTED FOR` line at all.\n#{out}")
      end

    assert accounted == {total, total},
           "the census accounted for #{elem(accounted, 0)} of #{total} rows. Every row lands in " <>
             "exactly one declared band; a row in none is a class the COUNTS block cannot see, " <>
             "which is the silence the partition replaced.\n#{out}"

    # AND THE SUM IS A DERIVATION, not a transcription: the printed ACCOUNTED FOR
    # must equal the printed bands added up, the four computed ones included.
    computed_sum =
      for label <- [
            "THROUGH a required gate",
            "IN-BEAM-REQUIRED",
            "DEAD-DECLARATION",
            # DECLARED IN PDS_DOOR_COMPUTED_BANDS BY WAVE 49, so it is summed
            # here: a band the census prints and this sum ignores would make
            # ACCOUNTED FOR disagree with its own lines by exactly that band.
            "LIBRARY-MODULE",
            "UNDISPOSED",
            "ERROR rows"
          ],
          reduce: 0 do
        acc -> acc + counted!(out, Regex.escape(label))
      end

    ledger_sum = band_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    assert computed_sum + ledger_sum == elem(accounted, 0),
           "the printed band lines add up to #{computed_sum + ledger_sum} but the census printed " <>
             "ACCOUNTED FOR #{elem(accounted, 0)}. The total does not descend from the lines " <>
             "above it, which makes it a transcription.\n#{out}"

    assert out =~ "RESIDUAL (in no declared band): none",
           "the census printed a residual band. A row whose class is in neither " <>
             "PDS_DOOR_CLASSES nor PDS_DOOR_COMPUTED_BANDS is unaccountable by construction — " <>
             "fix the class or declare the band, never the count.\n#{out}"
  end

  test "the class vocabulary is D637's five plus HUMAN-GATE, and 'the fence' is not one", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.census, "--selftest"], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0

    assert out =~
             "the class vocabulary is 6 (D637's five plus HUMAN-GATE) and 'FENCE' is not one",
           "the vocabulary arm is gone. Three classes cannot express CONTENT-RED or " <>
             "RED-BY-DESIGN-REPORTER, and 'the fence' was never an available answer.\n#{out}"
  end
end
