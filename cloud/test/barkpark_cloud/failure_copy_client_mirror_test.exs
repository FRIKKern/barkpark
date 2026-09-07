defmodule BarkparkCloud.FailureCopyClientMirrorTest do
  @moduledoc """
  task-8bdd2d50a204dab9 — THE CROSS-SURFACE LOCK for the born-failed
  github-push family.

  `BarkparkCloud.FailureCopy` and `cloud/priv/static/app.js` each map a raw
  builder `failure_reason` to human copy, and app.js additionally paints a
  tone. Before this guard they were an UNLOCKED MIRROR: two well-tested copies
  of one truth with no shared fixture. Change either side's token or sentence
  and BOTH suites stay green while a paying operator reads two different
  answers — or, as PR #16766 left it for one whole family, the right words in
  the wrong colour.

  A mirror test whose expected values are a second hand-written copy is a
  TAUTOLOGY that reads exactly like coverage. So NOTHING here is hand-typed as
  an expectation:

    * THE RAW REASON is extracted from `BarkparkCloud.Web.Router`'s
      `@github_push_build_reason` — the producer. Reword the router and this
      guard probes the NEW wording.
    * THE EXPECTED SENTENCE is `FailureCopy.humanize/1` CALLED from this booted
      test BEAM. Reword the server and the expectation moves with it.
    * THE CLIENT ANSWER is the SHIPPED `app.js` evaluated in a node:vm sandbox
      by `test/support/__failure_copy_dump.mjs`, which calls the real
      `failureCopy()` and `failureTone()`. No regex over app.js source text: a
      source scan passes a refactor that keeps the bytes and changes the
      behaviour, and fails a reformat that changes nothing.

  The only hand-written strings below are INPUTS (probes), never expectations.

  WHY IT MUST REFUSE ON AN EMPTY READ. A lock that cannot see one side is
  theatre — it goes quiet the first time somebody renames what it greps for,
  and quiet reads exactly like agreement. Every read here has a POSITIVE
  CONTROL that fails DIFFERENTLY from the comparison: the router extraction
  must find a reason, `humanize/1` must actually MOVE both probes (a server
  that stopped classifying would otherwise make every comparison trivially
  true), the two families' sentences must DIFFER from each other (or the
  discrimination this row exists to add is vacuous), and the dump script exits
  non-zero rather than printing an empty array.

  SCOPE. This guard covers the two arms of the born-failed github-push family
  and nothing else. It does not pin the other `failureCopy` clauses, and it
  says nothing about how the rendered panel is composed — `__app.test.mjs` and
  `__preview__/smoke.mjs` own that.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.FailureCopy

  # An INPUT, not an expectation: a legacy-shaped reason of the family whose
  # rows are already written in the DB and which no producer mints any more.
  # What it should map to is asked of the server, never typed here.
  @legacy_probe "github push builds are not available yet on this site"

  defp router_no_repo_reason do
    path =
      Path.expand(Path.join([__DIR__, "..", "..", "lib", "barkpark_cloud", "web", "router.ex"]))

    src = File.read!(path)

    captured =
      case Regex.run(~r/@github_push_build_reason\s+"((?:[^"\\]|\\.)*)"/, src) do
        [_, literal] -> literal
        _ -> nil
      end

    # POSITIVE CONTROL, and it fails differently from every comparison below:
    # this is the read going blind, not the two sides disagreeing.
    assert is_binary(captured) and String.length(captured) > 20,
           "could not extract @github_push_build_reason from #{path} — the lock cannot see the " <>
             "producer, and a lock that cannot see must RED, not pass (got: #{inspect(captured)})"

    captured
  end

  defp client_answers(reasons) do
    node = System.find_executable("node")

    assert node,
           "node is not on PATH — the cross-surface lock cannot read the console's answer"

    script =
      [__DIR__, "..", "support", "__failure_copy_dump.mjs"]
      |> Path.join()
      |> Path.expand()

    assert File.exists?(script), "the client-half dump script is missing at #{script}"

    {out, status} = System.cmd(node, [script, Jason.encode!(reasons)], stderr_to_stdout: true)

    assert status == 0,
           "the client dump refused (exit #{status}) — read it as UNREADABLE, never as agreement:\n#{out}"

    rows = Jason.decode!(out)

    assert length(rows) == length(reasons),
           "the client dump returned #{length(rows)} answers for #{length(reasons)} probes"

    Map.new(rows, fn %{"reason" => r} = row -> {r, row} end)
  end

  test "app.js and FailureCopy give ONE answer for both arms of the github-push family" do
    no_repo_raw = router_no_repo_reason()

    server_no_repo = FailureCopy.humanize(no_repo_raw)
    server_legacy = FailureCopy.humanize(@legacy_probe)

    # POSITIVE CONTROLS on the server read. Without these, a FailureCopy that
    # had stopped classifying entirely would make every assertion below pass:
    # the client passes unrecognized reasons through verbatim, so identity on
    # both sides would look like perfect agreement.
    assert server_no_repo != no_repo_raw,
           "FailureCopy.humanize/1 did not classify the router's own reason " <>
             "#{inspect(no_repo_raw)} — the server side of this mirror is not speaking"

    assert server_legacy != @legacy_probe,
           "FailureCopy.humanize/1 did not classify the legacy probe #{inspect(@legacy_probe)}"

    # And the two arms must not have collapsed into one sentence — that is the
    # whole discrimination this lock exists to hold.
    assert server_no_repo != server_legacy,
           "the server's two github-push sentences are IDENTICAL " <>
             "(#{inspect(server_no_repo)}) — the no-linked-repo refinement is gone server-side"

    probes = [no_repo_raw, server_no_repo, @legacy_probe, server_legacy]
    answers = client_answers(probes)

    # ── THE NO-LINKED-REPO ARM: correct sentence AND calm tone, both directions.
    raw_row = answers[no_repo_raw]

    assert raw_row["copy"] == server_no_repo,
           "the console REWRITES the server's no-linked-repo sentence.\n" <>
             "  server: #{inspect(server_no_repo)}\n  client: #{inspect(raw_row["copy"])}"

    assert raw_row["tone"] == "blocked",
           "the raw no-linked-repo reason paints #{inspect(raw_row["tone"])}, not blocked"

    # The server humanizes at the JSON boundary, so THIS is the string the
    # browser actually receives; the second pass must be the identity.
    human_row = answers[server_no_repo]

    assert human_row["copy"] == server_no_repo,
           "the console's second pass over the already-human no-linked-repo sentence is not " <>
             "idempotent.\n  in:  #{inspect(server_no_repo)}\n  out: #{inspect(human_row["copy"])}"

    assert human_row["tone"] == "blocked",
           "the server-humanized no-linked-repo sentence paints #{inspect(human_row["tone"])}, " <>
             "not blocked — the console cannot recognize the family in the words the server sends"

    # ── THE LEGACY ARM, the other direction on the same family. Deleting the
    # refinement must red the four assertions above and leave these green.
    legacy_raw_row = answers[@legacy_probe]
    legacy_human_row = answers[server_legacy]

    assert legacy_raw_row["copy"] == server_legacy,
           "the console and the server disagree on the LEGACY sentence.\n" <>
             "  server: #{inspect(server_legacy)}\n  client: #{inspect(legacy_raw_row["copy"])}"

    assert legacy_raw_row["tone"] == "blocked"

    assert legacy_human_row["copy"] == server_legacy,
           "the console's second pass over the already-human LEGACY sentence is not idempotent.\n" <>
             "  in:  #{inspect(server_legacy)}\n  out: #{inspect(legacy_human_row["copy"])}"

    assert legacy_human_row["tone"] == "blocked"
  end

  test "the client half REFUSES rather than passing vacuously when it cannot read a side" do
    # The extractor's own failure mode, asserted directly: an empty probe list
    # must be a non-zero exit, not an empty array that a caller could read as
    # "nothing disagreed". This is what stops the lock rotting into a green.
    node = System.find_executable("node")
    assert node, "node is not on PATH"

    script =
      [__DIR__, "..", "support", "__failure_copy_dump.mjs"] |> Path.join() |> Path.expand()

    {out, status} = System.cmd(node, [script, "[]"], stderr_to_stdout: true)
    assert status != 0, "an EMPTY probe list exited 0 with #{inspect(out)} — a vacuous pass"

    {out2, status2} = System.cmd(node, [script, "not json"], stderr_to_stdout: true)
    assert status2 != 0, "a malformed probe list exited 0 with #{inspect(out2)}"
  end
end
