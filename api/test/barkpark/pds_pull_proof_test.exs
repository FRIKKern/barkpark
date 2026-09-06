defmodule Barkpark.PdsPullProofTest do
  @moduledoc """
  The door for `scripts/pds-pull-proof_test.sh` — the offline harness that pins
  PDS-D261 / `pds-bl-w16-full-meta-permissive-default`.

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
             "into an always-refuse, which is the same defect with a new mechanism.\n#{out}"

    assert out =~ "pds-pull-proof_test: PASS",
           "the harness exited 0 without printing its PASS line — an exit code that does not " <>
             "descend from the arms is not a receipt.\n#{out}"

    # Non-vacuity: a harness whose fixtures stopped building would print a
    # tidy PASS over zero arms. The count is asserted, not assumed.
    assert out =~
             "PASS (23 arms: 13 refuse, 2 accept, 5 manifest_field, 2 identification, 1 discrimination)",
           "the harness passed with an arm count this door does not recognise. If arms were " <>
             "added or removed deliberately, update this assertion in the same commit — an " <>
             "unpinned count lets a shrinking harness keep printing PASS.\n#{out}"

    ok_lines = out |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "  ok   "))

    assert ok_lines == 23,
           "expected 23 `ok` arm lines, counted #{ok_lines}. A pass prints a real count; a " <>
             "green with no arms means the harness never ran its assertions.\n#{out}"
  end
end
