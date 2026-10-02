defmodule Barkpark.DbUndeclaredIndexCensusTest do
  @moduledoc """
  The rider that wires `deploy/db-undeclared-index-census.sh` — the DETECTION
  half of the read-only-sweep control (charter D614) — to a gate that actually
  runs.

  ## Why the detector needed a rider at all

  A hand-CREATEd index (`tmp_dep_site_live`) was left on cloud-db-1 during a
  read-only sweep. Wave 10 had already WRITTEN the rule down and had VERIFIED
  its own compliance — both halves of the control sat inside the thing being
  controlled. A self-attested control is not a control. The census is the
  reader that is not the actor; but a detector wired to no gate is the same
  shape as the self-report it replaces, only quieter. It landed with
  `deploy/db-undeclared-index-census.sh` (PR #18701) reachable from no workflow
  at all.

  `api/test/**` rides the already-required `Elixir gate`, so shelling the
  census here gates it without inventing a new required context.

  ## THE LIVE-VS-SELFTEST DECISION, MADE AND RECORDED HERE

  **The gated arm is `--selftest` ONLY. CI never runs `--check`.**

  `--check` needs a credentialed read of a production database. No ordinary
  GitHub runner has one, and a gate that needs a credential it does not have
  either fails OPEN (green because it could not look) or flakes — and a
  flapping guard is defeatable by retry. So this rider runs the hermetic arm
  and says so, rather than naming itself after the live check and silently
  degrading to the cheap one. That silent degradation is the exact failure
  mode the honest-gates epic exists to cure.

  What `--selftest` genuinely buys is not nothing, and it is not an
  approximation of the live read either — it is the PARSER, which is where
  both of this detector's real defects lived. The first cut declared
  `tmp_dep_site_live` by reading it out of a migration `@moduledoc`, going
  silent on the one object the census exists to catch (arm j). The second
  called the wave-11 repair's own index UNDECLARED by missing a `name:` on a
  continuation line — a FALSE UNDECLARED against production (arm k). Both
  misses were found by RUNNING it. Both are now arms, and this rider is what
  keeps them running.

  What is therefore NOT covered by any gate, stated so the green is not
  over-read: nothing in CI ever reads `pg_indexes`. A stray index created on
  prod tomorrow is caught by a human or a scheduled job running
  `bash deploy/db-undeclared-index-census.sh --check <psql args>` on a
  credentialed box — never by this test, and never by `Elixir gate`.

  ## What is asserted, and what is deliberately not

  rc ALONE is not a verdict: a gate piped to `tail` reports tail's exit code,
  and a script that dies before printing anything still exits 0 under enough
  shapes to be worth refusing. So the PASS VERDICT PROSE is asserted alongside
  rc.

  The ARM COUNT is deliberately NOT pinned. It drifts every time an arm is
  added — the script already grew from 11 arms to 12 — and a rider that reds on
  its subject improving trains people to edit the rider. What is pinned is the
  shape `=== <n> passed, 0 failed ===` with `<n>` free, plus a refutation of
  any `FAIL` arm line, which is the half that cannot be satisfied by silence.

  `async: false`: the case shells a subprocess that walks the whole migration
  tree with awk, twelve times over, in a temp repo.
  """
  use ExUnit.Case, async: false

  # awk over both migration roots, once per selftest arm, on a loaded runner.
  @moduletag timeout: 300_000

  # BOTH STRING LITERALS BELOW ARE LOAD-BEARING WIRING, not cosmetics.
  #
  # scripts/elixir-path-escape-check.sh resolves exactly these literals out of
  # api/test to derive the path set elixir.yml's `changes` dispatcher gates the
  # mix-test job on. Without the matching ELIXIR_TEST_ONLY_PATHS entry the
  # ratchet REDS (that is leg B's polarity proof); and without the ratchet
  # entry a PR touching ONLY the census would compute
  # changes.outputs.test == 'false', mix-test would be LEGITIMATELY skipped,
  # `Elixir gate` would go green, and this rider would not run on the one PR
  # that changed its subject. #9290 and #9292 are that shape on the record.
  @census_rel "../../../deploy/db-undeclared-index-census.sh"
  @ratchet_rel "../../../scripts/elixir-path-escape-check.sh"

  # The census's own path, spelled as the ratchet declares it (repo-relative).
  @census_declared_as "deploy/db-undeclared-index-census.sh"

  setup_all do
    census = Path.expand(@census_rel, __DIR__)

    unless File.regular?(census) do
      flunk(
        "the gate is pointed at nothing: #{census} does not exist. Do not skip this test — " <>
          "a skip here is a green fixture executed by nothing. Fix the path or delete the " <>
          "instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` on PATH, so the census cannot be run. " <>
            "Failing loud rather than skipping."
        )

    root = Path.expand("../../..", __DIR__)

    {out, rc} =
      System.cmd(bash, [census, "--selftest"], cd: root, stderr_to_stdout: true)

    {:ok, census: census, bash: bash, root: root, out: out, rc: rc}
  end

  test "the census's --selftest exits 0 AND prints its own PASS verdict", ctx do
    assert ctx.rc == 0,
           "expected `bash #{@census_rel} --selftest` to exit 0, got #{ctx.rc}:\n#{ctx.out}"

    # THE VERDICT PROSE, not the exit code, and not the arm count. `<n>` is
    # free on purpose: the arm count moved 11 -> 12 once already.
    assert ctx.out =~ ~r/^=== \d+ passed, 0 failed ===$/m,
           "the census exited 0 without printing its own `=== <n> passed, 0 failed ===` " <>
             "verdict. An exit code is not a verdict — a program that dies before it prints " <>
             "can still hand back a 0.\nOutput:\n#{ctx.out}"

    # The half that silence cannot satisfy: a printed FAIL arm alongside a 0.
    refute ctx.out =~ ~r/^\s+FAIL\s/m,
           "the census printed a FAIL arm while exiting 0 — its exit code did not descend " <>
             "from its arms.\nOutput:\n#{ctx.out}"
  end

  test "the two arms that found this detector's real defects are still running", ctx do
    # Named, not counted. Each of these arms is a defect that SHIPPED in a cut
    # of this script and was found by running it. An arm that can be quietly
    # deleted is an arm the suite cannot miss.
    for arm <- [
          "(j) a CREATE INDEX quoted in a doc comment does NOT enter the manifest",
          "(k) a multi-line create index resolves to its explicit name, not the positional one"
        ] do
      assert ctx.out =~ "ok   " <> arm,
             "the selftest no longer runs a green `#{arm}` arm. That arm reproduces a defect " <>
               "this census actually shipped; without it the selftest proves the wrong " <>
               "things.\nOutput:\n#{ctx.out}"
    end
  end

  test "the REFUSAL arms are green, so the ungated live arm cannot answer a comfortable zero",
       ctx do
    # This is the decision's other half. CI never runs `--check`, so what CI
    # CAN still hold is the property that makes an out-of-band `--check`
    # trustworthy: a failed or empty read exits 2 and prints no table, rather
    # than reporting "0 undeclared indexes" — the precise fraud the detector
    # exists to refuse.
    for arm <- [
          "(e) a failed pg_indexes read exits 2 CANNOT READ and prints no table",
          "(f) a zero-row pg_indexes read exits 2 rather than reporting 0 undeclared"
        ] do
      assert ctx.out =~ "ok   " <> arm,
             "the selftest no longer proves the live arm REFUSES rather than flatters. " <>
               "`--check` runs on a credentialed box and nowhere in CI; this arm is the only " <>
               "standing evidence that its zero would be earned.\nOutput:\n#{ctx.out}"
    end
  end

  test "the derive loop's count identity is proved BOTH ways, and apart from the BLIND SPOT tally",
       ctx do
    # The manifest is the ALLOW side of the census. A derive loop that reads
    # fewer migration files than `find` handed it produces a SHORTER declared
    # set with no error and no non-zero status, and every index the unread
    # migrations declared then reads UNDECLARED against a production database
    # that is entirely correct.
    #
    # Named, not counted, and the pair is load-bearing: (m) alone could be
    # satisfied by a script that refuses always, and (n) is the one that says
    # the pre-existing BLIND SPOT tally is a DIFFERENT quantity — it counts
    # declarations the parser opened and could not NAME, so a file it never
    # opened leaves that number untouched while the manifest shrinks.
    for arm <- [
          "(o) QUIET: an unmutated derive over the same fixture emits the FULL manifest and refuses nothing",
          "(m) RED: a stdin-draining child in the derive loop body makes the count identity refuse, naming 1 of 3, and no manifest is printed",
          "(n) the BLIND SPOT tally does NOT move under that same short read"
        ] do
      assert ctx.out =~ "ok   " <> arm,
             "the selftest no longer runs a green `#{arm}` arm. Without the trio the census " <>
               "can go back to deriving its ALLOW set from a partial migration list and " <>
               "calling correct production indexes UNDECLARED.\nOutput:\n#{ctx.out}"
    end
  end

  test "leg B is present: the census is a path elixir.yml dispatches the test job on" do
    ratchet = Path.expand(@ratchet_rel, __DIR__)

    unless File.regular?(ratchet) do
      flunk("the path ratchet is gone from #{ratchet}; this rider's dispatch cannot be checked.")
    end

    src = File.read!(ratchet)

    assert src =~ ~r/^#{Regex.escape(@census_declared_as)}$/m,
           "`#{@census_declared_as}` is no longer declared in " <>
             "scripts/elixir-path-escape-check.sh. Without that line a PR touching ONLY the " <>
             "census computes changes.outputs.test == 'false', the mix-test job is skipped, " <>
             "`Elixir gate` reports green — and this rider never runs on the one PR that " <>
             "changed its subject. A rider with no path entry is a test nothing runs."
  end
end
