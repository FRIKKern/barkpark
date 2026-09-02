defmodule BarkparkWeb.Live.Studio.SheetGrid.JsHarnessTest do
  @moduledoc """
  pds-w43-bl-sheetgrid-hook-harness-ungated — THE SHEET-GRID JS HARNESSES,
  WIRED TO A REQUIRED GATE.

  Four zero-dependency node harnesses live in `api/assets/sheet-grid/`. They are
  the only automated proof the Studio sheet-grid client has: `__hook` (175
  checks, including the read-mode `_push` seam that is the ENTIRE derived-denylist
  argument), `__formula` (51), `__palette` (18 contrast checks) and `__pointing`
  (22 groups). Until this case, none of them could refuse a merge.

  `.github/workflows/sheet-grid-js.yml` runs them, but it says so itself in its
  own header: it "only *gates* a PR once it is registered as a required check in
  the repo's branch-protection settings (a human GitHub step)". Nobody has taken
  that step. So a PR reintroducing a raw `pushEventTo` that bypasses the `_push`
  seam turns that workflow red on the PR page and merges anyway.

  ## Why this file, and not a line of `.github/`

  `api/test/**` rides the already-REQUIRED `Test (Elixir 1.18.1 / OTP 27.0)`
  context. `scripts/elixir-path-escape-check.sh` declares
  `ELIXIR_COMPILE_PATHS='api/**'`, and `api/assets/sheet-grid/**` is inside it,
  so elixir.yml's dispatcher computes `test=true` on a PR that touches ONLY a
  harness or only the shipped bundle. An ExUnit case that shells node therefore
  wires all four instruments to a required gate with zero bytes of `.github/`.
  This mirrors `api/test/barkpark/pds_record_parity_test.exs`, which did the same
  for the record-parity arm, and `cloud/test/barkpark_cloud/billing_client_mirror_test.exs`,
  which shells node the same way.

  Registering `sheet-grid-js.yml` itself as required is NOT the alternative and
  was proven wrong before this slice: it is `paths:`-filtered, and a required
  context whose workflow never triggers is never reported, which deadlocks every
  PR that does not touch its paths.

  ## THE HONEST SENTENCE, WITH ITS DENOMINATOR

  **This slice puts 4 of the 4 sheet-grid JS harnesses under a required gate, on
  every PR that could affect them — NOT on every PR.**

  It does NOT raise the charter's instrument count, and saying that it did would
  be false in two separate ways. PDS-D637 fixes that denominator as *exactly*
  `scripts/pds-*.{sh,exs}`, and no sheet-grid harness is one of them — they live
  in `api/assets/`. The charter names the sheet-grid harness only as a RELATED
  class, HUMAN-GATE: refused not for price and not for environment, but because
  the last step was a GitHub settings change nobody made. THAT is the class this
  file closes, and it closes all of it.

  The second way is the base itself. The charter says that column is 19 (17
  `.sh` + 2 `.exs`). Counted on origin/main while writing this, it is **23** (21
  `.sh` + 2 `.exs`) — D637's denominator has drifted by four, so a fresh
  "N of 19" sentence would cite a stale base on top of the wrong population. The
  `scripts/pds-*` column is untouched here either way: this slice gates no
  `pds-*` script.

  And the second clause of the honest sentence is load-bearing, not a footnote.
  These harnesses are HERMETIC: `__hook`, `__formula` and `__pointing` load the
  shipped `api/priv/static/assets/*.js` into a `node:vm` sandbox and pin its
  logic; `__palette` reads committed CSS/token sources. A green here means "the
  shipped client's event routing, formula rebasing, pointing reducer and contrast
  tokens still behave as pinned". It does NOT mean the Studio renders correctly
  in a browser. Nothing in CI checks that.

  ## Why this case does NOT take the repo's `:requires_node` tag

  `api/test/test_helper.exs` already excludes `:requires_node` by default, for
  `plugin_types_test.exs`'s `tsc --noEmit` check. Tagging this case the same way
  would be the obvious-looking move and it would undo the entire slice: an
  excluded tag never runs in the default lane, so the instruments would be back
  to riding no gate at all — with a green ExUnit run as cover, which is strictly
  worse than today's honest advisory workflow. The tag is right for `tsc`, an
  optional dev toolchain nobody claims CI depends on. It is wrong here, where
  the whole point is that CI must depend on node. That is also why the missing-node
  path below is a `flunk` rather than a `@tag :skip`.

  ## Why a COUNT floor, and why the floor is not today's count

  A verdict line alone is not enough: `__hook` and `__formula` printed
  "all … checks PASS" with NO number, so a harness whose runner degraded into
  running zero checks was word-for-word indistinguishable from a healthy one.
  This slice added `${passed}` to both verdict lines — a count line only; not one
  byte of what the harnesses check changed.

  The floors below are set at roughly 90% of today's measured count, rounded
  down. That is a deliberate compromise and its limit should be quoted honestly:
  a floor pinned AT today's count reds on every honest new fixture, and
  `pds-w28-census-check-count-citations-stale` is the standing lesson that a
  count which reds for innocent reasons gets deleted within a day. So the floor
  catches CATASTROPHIC loss — a runner that ran nothing, a deleted section, an
  early `return` — and NOT the removal of a single check. The prose half of each
  assertion is the contract for the rest.

  ## Cost, in USER CPU (charter D605 — never wall clock)

  Measured in this worktree, node v22.22.0, `/usr/bin/time -p`, 7 runs of all
  four harnesses back to back:

      run   real   user    sys
       1    0.45   0.25   0.06
       2    0.36   0.22   0.05
       3    0.40   0.19   0.05
       4    0.33   0.22   0.05
       5    0.29   0.19   0.04
       6    0.29   0.20   0.04
       7    0.29   0.19   0.04

  **All four cost 0.19–0.25 s USER CPU; `__hook` alone is 0.06 s, five runs, zero
  spread.** Per harness: `__hook` 0.06, `__palette` 0.05–0.07, `__pointing`
  0.05–0.06, `__formula` 0.03–0.04.

  The host was NOT quiet — 1-minute load average 26.8–31.8 across the
  measurement — and that is why the measure is USER CPU and the table prints
  `real` beside it. Wall clock moved 0.29→0.45 s (a 55% spread) over the same
  seven runs that moved user CPU 0.19→0.25. The load-insensitive column is the
  one that prices the gate; the row's "quiet host" instruction is satisfied in
  substance by measuring the column load cannot move, and the contrast is shown
  rather than asserted. Against the Elixir suite's own measured 9m31s–16m29s,
  this is ~0.03% of the job.

  `async: false` per the row: four node subprocesses have no business racing the
  async lane.
  """
  use ExUnit.Case, async: false

  # ~0.25 s USER CPU, but four subprocess spawns: on a loaded CI runner it is
  # WALL time that moves (0.29→0.45 s here at load ~30), and ExUnit's default is
  # 60 s. Headroom is cheaper than a runner-speed flake.
  @moduletag timeout: 300_000

  # The string literal is load-bearing, not cosmetic: scripts/elixir-path-escape-check.sh
  # resolves exactly these literals to prove elixir.yml dispatches on everything
  # the suite reads. This one resolves to `api/assets/sheet-grid`, which
  # ELIXIR_COMPILE_PATHS covers as `api/**` — so no ELIXIR_TEST_ONLY_PATHS entry
  # is needed and none was added.
  @harness_dir_rel "../../../../../assets/sheet-grid"

  # floor = ~90% of the count measured on this branch, rounded down. See the
  # moduledoc for why it is not today's count. `measured` is recorded so a
  # future reader can see how far the floor sits from the real number without
  # re-running anything.
  @harnesses [
    %{
      file: "__hook.test.mjs",
      verdict: ~r/all bp-sheet-grid hook checks PASS \x{2014} (\d+) checks/u,
      floor: 160,
      measured: 175,
      subject:
        "the sheet-grid client hook — keyboard routing, clipboard TSV, fill, " <>
          "drag-to-select, and the read-mode `_push` seam that is the whole " <>
          "derived-denylist argument"
    },
    %{
      file: "__formula.test.mjs",
      verdict: ~r/all bp-sheet-formula kernel checks PASS \x{2014} (\d+) checks/u,
      floor: 45,
      measured: 51,
      subject: "the formula kernel — caret context, ref rebasing, #REF! collapse"
    },
    %{
      file: "__palette.test.mjs",
      verdict: ~r/__palette\.test\.mjs OK \x{2014} (\d+) contrast checks/u,
      floor: 16,
      measured: 18,
      subject: "WCAG contrast of the sheet palette against both theme backgrounds"
    },
    %{
      file: "__pointing.test.mjs",
      verdict: ~r/bp-sheet-pointing: (\d+) groups passed/u,
      floor: 20,
      measured: 22,
      subject: "the pointing/ghost-range reducer"
    }
  ]

  setup_all do
    dir = Path.expand(@harness_dir_rel, __DIR__)

    unless File.dir?(dir) do
      flunk(
        "the gate is pointed at nothing: #{dir} does not exist. Do not skip this test — " <>
          "a skip here is charter D26 (green fixtures executed by nothing). Fix the path " <>
          "or delete the instruments, but never both quietly."
      )
    end

    node =
      System.find_executable("node") ||
        flunk("""
        node is not on PATH, so the sheet-grid JS harnesses cannot run.

        THIS TEST DOES NOT SKIP. A skip inside the required `Test (Elixir 1.18.1 / OTP 27.0)`
        context is a green that measured nothing, which is the exact shape this instrument
        exists to refuse.

        Said with its denominator: this gate covers 4 of the 4 sheet-grid JS harnesses,
        on every PR that could affect them — NOT on every PR. Right now ZERO of those 4
        ran, because node is absent. (The denominator is the sheet-grid harness set, NOT
        the charter's `scripts/pds-*` column — see the moduledoc.)

        THE FIX IS THREE LINES IN .github/workflows/elixir.yml, in the
        `Test (Elixir …)` job, after the Setup BEAM step:

            - name: Setup Node
              uses: actions/setup-node@v4
              with:
                node-version: "20"

        `.github/workflows/cloud.yml` already carries exactly this, for exactly this
        reason, and says so in a comment: its mirror guard "ASSERTS on a missing node
        rather than skipping. So node is a hard dependency of this job, pinned here
        rather than inherited from whatever the runner image happens to ship." elixir.yml
        pins no node at all (`grep -i node` over it returns nothing), so today these
        harnesses run only because `ubuntu-latest` happens to ship a node. That is luck,
        not configuration.
        """)

    {:ok, dir: dir, node: node}
  end

  for h <- @harnesses do
    @h h

    test "#{h.file} is GREEN and ran at least #{h.floor} checks", ctx do
      path = Path.join(ctx.dir, @h.file)

      assert File.regular?(path),
             "#{@h.file} is missing from #{ctx.dir} — the instrument covering #{@h.subject} " <>
               "is gone, and this gate would otherwise report green for an absent harness."

      {out, rc} = System.cmd(ctx.node, [@h.file], cd: ctx.dir, stderr_to_stdout: true)

      assert rc == 0,
             "`node #{@h.file}` exited #{rc}, expected 0. This harness covers #{@h.subject}.\n\n#{out}"

      # An exit code alone is not a receipt (the epic's law since wave 22): a
      # runner that fell off the end of the file exits 0 having asserted nothing.
      captured =
        Regex.run(@h.verdict, out) ||
          flunk("""
          `node #{@h.file}` exited 0 WITHOUT printing its verdict line.

          Expected to match: #{inspect(@h.verdict.source)}

          An exit code is not a receipt. A harness that threw before its runner, or
          returned early, or had its verdict line reworded, lands here — and every one
          of those is a harness that stopped measuring #{@h.subject}.

          Output:
          #{out}
          """)

      count = captured |> Enum.at(1) |> String.to_integer()

      assert count >= @h.floor,
             "#{@h.file} reported #{count} checks, below the floor of #{@h.floor} " <>
               "(#{@h.measured} when this gate was written). A count this low means checks " <>
               "were deleted or never ran: the harness is green because it stopped " <>
               "measuring, not because the code is correct. What stopped being " <>
               "measured — #{@h.subject}.\n\n#{out}"
    end
  end

  # The four tests above each prove ONE harness. Nothing in them proves the SET
  # is still four: deleting a map entry from @harnesses deletes a test, and a
  # suite with fewer tests is still a green suite. This pins the roster against
  # the directory, so adding a fifth harness without wiring it here reds, and so
  # does quietly dropping one from the list.
  test "every __*.test.mjs in the directory is wired to this gate", ctx do
    on_disk =
      ctx.dir |> Path.join("__*.test.mjs") |> Path.wildcard() |> Enum.map(&Path.basename/1)

    wired = Enum.map(@harnesses, & &1.file)

    assert Enum.sort(on_disk) == Enum.sort(wired),
           "the harness roster drifted from the directory.\n" <>
             "  on disk: #{inspect(Enum.sort(on_disk))}\n" <>
             "  wired:   #{inspect(Enum.sort(wired))}\n" <>
             "A harness on disk but not wired here runs under NO required gate — which is " <>
             "the exact condition pds-w43-bl-sheetgrid-hook-harness-ungated exists to close."
  end
end
