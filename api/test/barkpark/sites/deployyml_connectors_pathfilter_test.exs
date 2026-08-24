defmodule Barkpark.Sites.DeployymlConnectorsPathfilterTest do
  @moduledoc """
  `.github/workflows/deploy.yml` must both START on and TARGET a merge under
  `scripts/connectors/**` — pinned on a lane that can actually BLOCK the change
  that would break it (charter D275, Connectors W35).

  THE GAP. `instance-deploy.sh` installs the cloud-sandbox-runner FROM
  `scripts/connectors/` onto the content instance. But that tree was listed in
  NEITHER `deploy.yml`'s `on.push.paths` NOR the `changes` job's instance
  regex, so a runner-only merge (a `.mjs` or preflight change) landed on `main`
  and never reached guerrilla — the host kept serving the old runner until an
  unrelated deploy-triggering merge rode by. It was byte-identical to prod only
  by that piggyback, never by its own deploy.

  TWO GUARDS, ONE REQUIRED. `scripts/check-deployyml-filters.sh` (the drift +
  required-path-presence gate) is the fast local half, but it rides
  `doc-gates.yml`, which is NOT a required status check — the required set is
  `Elixir gate`, `PR references an active task`, `Cloud gate`, `Console gate`
  (measured via the branch-protection API 2026-08-17). A shell-only guard is
  therefore advisory and cannot block a merge. This file is the durable half:
  it runs on the REQUIRED Elixir lane, which fires on `api/**` — so a PR that
  strips `scripts/connectors/**` from the workflow AND touches `api/**` still
  reds here. (The precedent is `deploy_runner_stage_names_test.exs`, which pins
  a deploy doctrine on this same lane for the same reason.)

  Every read below is FAIL-CLOSED: a moved workflow, a reshaped `on.push.paths`
  block, or an instance regex that no longer matches `scripts/connectors/…`
  reds this test rather than passing vacuously — that silent skip is exactly
  the failure mode this file exists to end.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @deploy_yml Path.join(@repo_root, ".github/workflows/deploy.yml")
  @required_path "scripts/connectors/**"

  # ── THE LOCATORS, AND WHY THEY ARE DELIBERATELY NOT SPELLING-EXACT ─────────
  #
  # This file pins a BEHAVIOUR: `scripts/connectors/**` must both start the
  # workflow and flip `instance=true`. It proves that by CAPTURING the dispatch
  # ERE and RUNNING it against a sample path — the assertions below compile the
  # regex and match/refute real strings, and none of that changes here.
  #
  # What changes is how the ERE is FOUND. The old locator required the literal
  # `then echo "instance=true"`, so it broke the moment the changes job wrote
  # the same decision as `then instance=true` — assign now, write the outputs
  # once at the end, which is what the `workflow_dispatch` override
  # (task-0c3069135d1b4bfd) needs, because two writes of one key to
  # $GITHUB_OUTPUT is not a contract worth leaning on. The workflow's behaviour
  # was IDENTICAL and this guard still reddened.
  #
  # That is a guard about keystrokes wearing the clothes of a guard about
  # behaviour, and it is the worse kind: it reds on refactors it does not care
  # about, and it teaches the next author that the cure is to reshape the
  # workflow rather than the pin. So both spellings are accepted — they are the
  # same decision.
  #
  # STILL NARROW WHERE NARROWNESS IS THE POINT. `grep -qE '…';\s*then` is
  # required, so the bare `instance=true` / `cp=true` arms of the dispatch
  # override's `case` (which carry no grep) can never answer for a target, and
  # neither can any other job's shell. Widening past this would let a
  # non-dispatching line green the guard for free — the exact disarm
  # scripts/check-deployyml-filters.sh scopes its own extractor against.
  @instance_dispatch ~r/grep -qE '([^']+)';\s*then\s+(?:echo\s+")?instance=true/

  # The `on.push.paths` block only: from the `paths:` key under `on:` up to the
  # next top-level (column 0) key. Mirrors the shell gate's awk boundary so a
  # `paths:` elsewhere in the file cannot widen the set.
  @push_paths_block ~r/^\s+paths:\n(.*?)\n[a-z]/ms

  defp read!(path) do
    assert File.exists?(path),
           "expected #{path} to exist — this test pins its contents, and a missing " <>
             "file must RED here, never silently skip (that silent skip is exactly " <>
             "the defect this file was added to close)"

    File.read!(path)
  end

  # A SCRAPE THAT FINDS NOTHING MUST SAY SO BY NAME.
  #
  # This used to read `assert [_, block] = Regex.run(...), "message"`. `assert/2`
  # evaluates its first argument before it can ever render that second argument,
  # so the match itself blew up first and the carefully written explanation was
  # never printed — the reader got `** (MatchError) no match of right hand side
  # value: nil` and no statement of which file was read or what was looked for.
  # Matching on the result instead is what lets the message exist.
  defp push_paths_block(source) do
    case Regex.run(@push_paths_block, source) do
      [_, block] ->
        block

      nil ->
        flunk("""
        could not locate the on.push.paths block in #{@deploy_yml}.

        This test reads that workflow and pins its contents; a scrape that finds
        nothing is a BROKEN PIN, never a passing one. Either `on:` was reshaped
        (the block no longer starts at an indented `paths:` and end at the next
        column-0 key), or the file moved.

        Looked for: #{inspect(Regex.source(@push_paths_block))}

        If the reshape was deliberate, update this locator deliberately with it —
        do not delete the assertion, and do not let it pass vacuously.
        """)
    end
  end

  # The ERE feeding `instance=true` in the `changes` job — captured back so we
  # can RUN it against a sample path, not just string-match it. Same
  # named-failure reasoning as push_paths_block/1 above.
  defp instance_regex(source) do
    case Regex.run(@instance_dispatch, source) do
      [_, ere] ->
        ere

      nil ->
        flunk("""
        could not find the changes-job dispatch line that sets instance=true in
        #{@deploy_yml}.

        Expected a line shaped like

            ... | grep -qE '<ere>'; then instance=true ...
            ... | grep -qE '<ere>'; then echo "instance=true" ...

        (both spellings are accepted — they are the same decision), inside the
        `changes` job. Nothing matched, so the ERE this test exists to RUN could
        not be captured at all.

        Looked for: #{inspect(Regex.source(@instance_dispatch))}

        This is a BROKEN PIN, not a pass. If the changes job was reshaped
        deliberately, update this locator with it. Do NOT delete the assertion:
        it is the required-lane half of the W35 guard (charter D275), and
        without it a merge can strip scripts/connectors/** from the instance
        filter with nothing able to block it.
        """)
    end
  end

  describe "scripts/connectors/** reaches the instance deploy" do
    test "on.push.paths lists scripts/connectors/** so a runner-only merge STARTS the workflow" do
      block = push_paths_block(read!(@deploy_yml))

      assert block =~ ~r/^\s*-\s*"scripts\/connectors\/\*\*"\s*$/m,
             """
             deploy.yml's on.push.paths no longer lists #{inspect(@required_path)}.

             instance-deploy.sh installs the cloud-sandbox-runner from
             scripts/connectors/, so a merge touching only that tree must START
             this workflow. Without the entry the merge lands on main and never
             deploys — the exact gap Connectors W35 (charter D275) closed.

             Restore the `- "#{@required_path}"` entry under on.push.paths, or, if
             this is intended, update this test and the charter.
             """
    end

    test "the changes-job instance regex TARGETS scripts/connectors/ (behavioural, exact-prefix)" do
      ere = instance_regex(read!(@deploy_yml))

      # The path glob's representative sample — what `git diff --name-only`
      # actually emits and the regex is run against in the workflow.
      {:ok, compiled} = Regex.compile(ere)

      assert Regex.match?(compiled, "scripts/connectors/cloud-sandbox-runner.mjs"),
             """
             the instance regex does not match a scripts/connectors/ change.

             regex: #{ere}

             Starting the workflow (on.push.paths) is only half the fix — the
             changes job's instance filter must also flip instance=true, or the
             run deploys NOTHING and still reports green. Add `scripts/connectors`
             to the alternation, e.g.
             ^(api|internal|deploy|connectors|templates|scripts/connectors)/.
             """

      # Exact-prefix proof: the entry is `scripts/connectors`, not bare
      # `scripts`, so an unrelated scripts/ change must NOT falsely deploy.
      refute Regex.match?(compiled, "scripts/other/thing.sh"),
             """
             the instance regex matches scripts/other/ — the prefix is too broad.

             regex: #{ere}

             It must be the exact prefix `scripts/connectors`, so scripts/other/
             (and any other scripts/ subtree) does NOT flip instance=true.
             """
    end

    test "a scrape that finds nothing FLUNKS by name, never with a bare MatchError" do
      # THE REGRESSION THIS PINS, measured rather than imagined. On run
      # 32732113340 (head cfb1f1b374) the changes job wrote its decision as
      # `then instance=true` instead of `then echo "instance=true"` — the same
      # behaviour, a different spelling — and this file answered with
      #
      #     ** (MatchError) no match of right hand side value: nil
      #
      # naming neither the file it had read nor what it had looked for. Both
      # scrapers now match on the result and `flunk/1` with a real sentence, and
      # this test is what keeps that true: revert either helper to
      # `assert [_, x] = Regex.run(...)` and the raise becomes a MatchError,
      # which is NOT an ExUnit.AssertionError, so assert_raise reds here.
      empty = "jobs:\n  changes:\n    steps:\n      - run: echo nothing to find\n"

      instance_err = assert_raise ExUnit.AssertionError, fn -> instance_regex(empty) end
      assert instance_err.message =~ "instance=true"
      assert instance_err.message =~ ".github/workflows/deploy.yml"
      assert instance_err.message =~ "BROKEN PIN"

      paths_err = assert_raise ExUnit.AssertionError, fn -> push_paths_block(empty) end
      assert paths_err.message =~ "on.push.paths"
      assert paths_err.message =~ ".github/workflows/deploy.yml"
    end

    test "both spellings of the instance dispatch decision are found (same decision, one pin)" do
      # The locator's tolerance is itself pinned, in BOTH directions, so a future
      # narrowing that re-couples this guard to formatting reds here rather than
      # on somebody else's unrelated PR.
      ere = "^(api|internal|deploy|connectors|templates|scripts/connectors)/"

      assign = "if echo \"$changed\" | grep -qE '#{ere}'; then instance=true; else instance=false; fi"
      write = "if echo \"$changed\" | grep -qE '#{ere}'; then echo \"instance=true\" >> \"$GITHUB_OUTPUT\"; fi"

      assert instance_regex(assign) == ere
      assert instance_regex(write) == ere

      # And the narrowness that makes it a DISPATCH pin: a bare assignment with
      # no grep — exactly the shape of the workflow_dispatch override's case arms
      # — must not be harvested as if it were the path filter.
      refute Regex.match?(@instance_dispatch, "              both)     cp=true;  instance=true  ;;")
    end

    test "the shell gate still carries scripts/connectors/** as a required path (both halves present)" do
      # The shell half is the fast local guard. It is unreachable from an
      # api/**-only PR, which is why THIS file exists — but if someone deletes
      # its required-path allowlist, that half is gone and this test should say
      # so rather than let the coverage quietly halve.
      gate = read!(Path.join(@repo_root, "scripts/check-deployyml-filters.sh"))

      assert gate =~ ~r/REQUIRED_PATHS=\([^)]*"scripts\/connectors\/\*\*"/s,
             "scripts/check-deployyml-filters.sh lost scripts/connectors/** from its " <>
               "REQUIRED_PATHS allowlist — the shell half of the W35 guard. Restore " <>
               "it or record the removal."
    end
  end
end
