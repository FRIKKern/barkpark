defmodule Barkpark.PdsPullProofTest do
  @moduledoc """
  The door for `scripts/pds-pull-proof_test.sh` — the offline harness that pins
  PDS-D261 / `pds-bl-w16-full-meta-permissive-default`.

  It also pins the two preconditions added alongside it — step 1's live read of
  the target's `documents_task_lifecycle_status_check` and step 4's discovery of
  a maintenance PostgreSQL for the secret scanner's own firing control — and the
  fact that the harness is NOT relocatable, which is what its published
  rehearsal recipe rests on.

  `full_meta_ok()` decides whether the ONE full-fidelity export bundle parked at
  `$FULL_TAR` may be reused as the control that steps 3 and 4 take their
  differentials off. Before this rider it was `[ -s "$FULL_TAR" ]` plus a
  `case "$p" in ""|full` on a manifest field whose reader returns the empty
  string on EVERY failure it has — so an HTML error page, a JSON error body, a
  gzip, a truncated download, a tar with no members and a tar whose members are
  all empty were all ACCEPTED as full bundles. A check that cannot fail on the
  shapes it exists to catch is not a check; it is a green nobody earned.

  This test is what makes the harness a GATE rather than a script someone might
  remember to run. The harness is credential-free, network-free and sub-second:
  it builds fixture tars in a temp dir and drives the SHIPPED predicate, loaded
  through the script's own documented `PDS_PROOF_LIB=1` library mode. None of
  the door census's reasons an instrument cannot be gated (PRICE, ENVIRONMENT,
  NOT-YET-BUILT, CONTENT-RED, RED-BY-DESIGN-REPORTER) is true here.
  """
  use ExUnit.Case, async: true

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it a PR touching ONLY
  # pds-pull-proof.sh or its harness would compute changes.outputs.test ==
  # 'false' and mix-test would be LEGITIMATELY skipped on the very PR that
  # changed the predicate this test exists to pin.
  @harness_rel "../../../scripts/pds-pull-proof_test.sh"

  setup_all do
    harness = Path.expand(@harness_rel, __DIR__)

    unless File.regular?(harness) do
      flunk(
        "the gate is pointed at nothing: #{harness} does not exist. Do not skip this test — " <>
          "a skip here is a green fixture executed by nothing. Fix the path or delete the " <>
          "instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the full_meta_ok " <>
            "harness cannot be run. Failing loud rather than skipping."
        )

    {:ok, harness: harness, bash: bash, root: Path.expand("../../..", __DIR__)}
  end

  test "full_meta_ok refuses every malformed bundle shape and still accepts a real one", ctx do
    {out, rc} = System.cmd(ctx.bash, [ctx.harness], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0,
           "expected `bash #{@harness_rel}` to exit 0, got #{rc}. Its arms are two-sided by " <>
             "construction: thirteen REFUSE arms (ten of which origin/main ACCEPTED as valid " <>
             "full bundles — an HTML proxy page, a JSON error body, a gzip, a truncated tar, a " <>
             "member-less tar, an empty manifest, an unparseable manifest, a JSON-array " <>
             "manifest, and two bundles with no usable tables/documents.copy), two ACCEPT arms " <>
             "(a genuine full bundle and the legacy pre-profile engine), and one arm asserting " <>
             "the refusals name FOUR DIFFERENT expectations, plus five pinning
             manifest_field's three return paths (key present / key absent /
             nothing readable) — the conflation that made the permissive default
             possible. A red in the first group means the " <>
             "permissive default came back; a red in the second means the tightening turned " <>
             "into an always-refuse, which is the same defect with a new mechanism. " <>
             "Seventeen further arms cover the harness's two other preconditions and its own " <>
             "portability: four drive `lifecycle_missing_values` against REAL " <>
             "`pg_get_constraintdef` output for the pre- and post-widening " <>
             "`documents_task_lifecycle_status_check` (the catalog prints `= ANY (ARRAY[...])`, " <>
             "never the migration's `IN (...)`, so a matcher written off the migration file " <>
             "would match nothing), ten drive `control_pg_verdict` — step 4's maintenance-PG " <>
             "discovery, which accepts a candidate only on the SERVER's own answers and must " <>
             "refuse a remote server, an unprivileged role, a production database and a probe " <>
             "it cannot parse — and three relocate the shipped script to a temp directory and " <>
             "assert it still dies at load, because the published rehearsal recipe rests on " <>
             "that being true. Seventeen more pin the cross-invocation and honesty wording: " <>
             "seven drive `pin_triple_line` (the PDS-PIN-TRIPLE line a reader chains across " <>
             "invocations — one run's `sha_8` against the next run's `sha_0a`, including the " <>
             "redeploy shape where the two genuinely differ), five drive " <>
             "`rss_reuse_attribution` (a reuse invocation measured no RSS of its own and must " <>
             "credit the parked peak to the run that DID measure it), and five pin the " <>
             "banner/sidecar/comment sentences themselves — the RSS peak labelled " <>
             "WHOLE-PROCESS rather than export-exclusive, the THE 34 block's real reason " <>
             "`tag` is out of the sentinel scope, and step 8 naming the gap between " <>
             "invocations it does not vouch for. NINE MORE ARRIVED WITH THE PDS-D742/PDS-D743/PDS-D744 \
             thaw and are the demos PDS-D744 requires: they drive the shipped \
             `moved_column_counts` / `moved_columns_where` / `columns_intersect` / \
             `columns_where` against an ALL-PRIVATE fixture roster — the target shape \
             `pds-bl-legb-visibility-control-n3` was filed about, where the sentinel's \
             constant `visibility = 'private'` is a no-op on every row — and show the \
             pre-fix shape PASSING (`columns_where same` finds nothing to complain \
             about on a full clobber, so rung 6 went green with one of its eight \
             controls proving nothing) while the new per-column measurement REDS it by \
             name (`visibility=0`). Two more show a deliberately partial revert naming \
             `icon desk_groups`, one shows scoping leg B to the measured moved set \
             dropping nothing, one shows the new red is two-sided on a healthy roster, \
             and one shows a shifted row set refused by exit code rather than folded \
             into the counts. TEN MORE ARRIVED WITH THE PDS-D746 thaw and are the \
             two-sided demo it requires: they drive the shipped \
             `deploy_run_instance_verdict` / `gate_d_verdict` against fixture job \
             graphs, because `deploy.yml` runs TWO independent deploy jobs behind one \
             `changes` job — `control-plane` ships to CP_HOST, `instance` ships to \
             GUERRILLA_HOST — and only `instance` can swap the slot under an export. \
             A cloud-only run (instance `skipped`) must NOT abort and an \
             instance-targeting run MUST, with the undecided, unreadable and \
             nonzero-gh shapes all staying UNKNOWN so the gate keeps failing CLOSED \
             (PDS-D98). SIX MORE ARRIVED WITH task-adad29e7487ed2b6 and pin cond_d's \
             COUNT IDENTITY: the per-run descent reads the in-flight listing on fd 0 \
             and runs `gh run view` in the loop body, so a body child that reads stdin \
             ends the loop early with no error and no non-zero status, and \
             `gate_d_verdict` — worst-case over the pairs it is HANDED — cannot \
             represent a run nobody examined. Three arms drive the intact loop (a \
             complete 3-run scan still aborts by id, a 1-of-1 cloud-only scan still \
             passes, an empty listing is still the quiet OK), one SPLICES \
             `cat >/dev/null` into the shipped loop body at its MUT anchor and asserts \
             the refusal fires naming 1 pair of 3 runs, one additionally CUTS the \
             identity between its MUT markers and shows that same drained loop CLEARING \
             over one run of three without ever mentioning the instance-targeting run \
             — the RED-WITHOUT this gate exists to make impossible — and one pins that \
             a blank line is counted on neither side. `gh` is stubbed on PATH: no \
             network, no token, no live target is touched (PDS-D31).\n#{out}"

    assert out =~ "pds-pull-proof_test: PASS",
           "the harness exited 0 without printing its PASS line — an exit code that does not " <>
             "descend from the arms is not a receipt.\n#{out}"

    # Non-vacuity: a harness whose fixtures stopped building would print a
    # tidy PASS over zero arms. The count is asserted, not assumed.
    assert out =~
             "PASS (82 arms: 13 refuse, 2 accept, 5 manifest_field, 2 identification, 1 discrimination, 4 lifecycle precondition, 10 control-PG verdict, 3 non-relocatable, 7 pin triple, 5 rss attribution, 5 honesty wording, 9 rung-6 sentinel coverage, 10 cond_d job discrimination, 6 cond_d short-run identity)",
           "the harness passed with an arm count this door does not recognise. If arms were " <>
             "added or removed deliberately, update this assertion in the same commit — an " <>
             "unpinned count lets a shrinking harness keep printing PASS.\n#{out}"

    ok_lines = out |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "  ok   "))

    assert ok_lines == 82,
           "expected 82 `ok` arm lines, counted #{ok_lines}. A pass prints a real count; a " <>
             "green with no arms means the harness never ran its assertions.\n#{out}"
  end
end
