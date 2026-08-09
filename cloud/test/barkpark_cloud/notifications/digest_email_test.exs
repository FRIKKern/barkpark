defmodule BarkparkCloud.Notifications.DigestEmailTest do
  @moduledoc """
  dr-w25-s6 — the daily fleet digest email stops calling a stale box `current`.

  The defect this pins: `DigestEmail` counted `update_state == "current"`
  straight into the email SUBJECT, and `update_state` is the box's own
  RELEASE-TAG self-grade. The fleet tag has not moved off `0.2.25` in ~2,500
  builds, so five prod boxes sitting 1 / 268 / 633 / 927 / 2,509 commits behind
  `main` were all reported `current` — drift within a release was invisible by
  construction.

  These tests read the rendered BYTES (subject line, header line, per-box row),
  not just the summary map, because the bytes are what a human receives. The
  MUTATION test at the bottom is the anti-vacuous-green guard: it flips one
  fixture's `commit_ancestry` and proves the counts move, so a future refactor
  that stops reading the measured column cannot keep these tests green.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Notifications.DigestEmail
  alias BarkparkCloud.Registry.Barkpark

  @checked ~U[2026-08-07 14:02:00.000000Z]
  @measured ~U[2026-08-08 03:11:00.000000Z]

  # A box that grades ITSELF current on the unmoved release tag. Every fixture
  # starts here; each test supplies only the measured columns under test.
  defp box(attrs) do
    struct!(
      %Barkpark{
        name: "Prod",
        slug: "prod",
        version: "0.2.25",
        git_commit: "abc1234",
        update_state: "current",
        update_running_release: "v0.2.25",
        update_latest_release: "v0.2.25",
        update_checked_at: @checked,
        autoupdate_enabled: true,
        autoupdate_paused: false,
        pinned_release: nil
      },
      attrs
    )
  end

  defp stale_box(attrs \\ []) do
    box(
      [
        name: "Stale",
        slug: "stale",
        commit_ancestry: "behind",
        commit_distance: 2509,
        commit_distance_checked_at: @measured
      ] ++ attrs
    )
  end

  defp fresh_box(attrs \\ []) do
    box(
      [
        name: "Fresh",
        slug: "fresh",
        commit_ancestry: "current",
        commit_distance: 0,
        commit_distance_checked_at: @measured
      ] ++ attrs
    )
  end

  ## 1. The counts — a measured-behind box is never `current`

  test "a box 2,509 commits behind main lands in the behind bucket, not current" do
    summary = DigestEmail.summary([stale_box(), fresh_box()])

    assert summary.total == 2
    assert summary.behind == 1
    assert summary.current == 1
    assert summary.unmeasured == 0

    # ...and the box's own self-report is untouched: this is the plane
    # DISAGREEING with it, not the column being rewritten.
    assert DigestEmail.freshness(stale_box()) == :behind
    assert stale_box().update_state == "current"
  end

  test "a box whose commit matches main but whose release tag says behind is counted behind" do
    # The self-report can only ever make the verdict WORSE — never launder a
    # box into `current`.
    summary = DigestEmail.summary([fresh_box(update_state: "behind")])

    assert summary.behind == 1
    assert summary.current == 0
  end

  test "a tag-only behind box says WHICH producer called it behind, not '0 commits behind'" do
    # REVIEW ADDITION. `behind` is reachable two ways and only one of them is a
    # measurement. When the compare found NOTHING missing and the box's own
    # release tag is what said `behind`, the measured distance is genuinely 0 —
    # so the row used to read "state: behind | 0 commits behind main", which is
    # a flat contradiction with the reason dropped on the floor. The counting
    # test above already pinned the rung; this pins the BYTES a human reads.
    line = DigestEmail.body(DigestEmail.summary([fresh_box(update_state: "behind")]))

    assert line =~ "state: behind"
    assert line =~ "behind by its own release tag, not by commit"
    refute line =~ "| 0 commits behind main (measured 2026-08-08 03:11 UTC) |"
  end

  test "the five measured rungs partition the fleet" do
    rows = [
      stale_box(),
      fresh_box(),
      box(name: "D", slug: "d", commit_ancestry: "diverged", commit_distance: 4),
      box(name: "A", slug: "a", commit_ancestry: "ahead_of_main", commit_distance: 2),
      box(name: "U", slug: "u", commit_ancestry: nil)
    ]

    s = DigestEmail.summary(rows)

    assert s.current + s.behind + s.diverged + s.ahead + s.unmeasured == s.total
    assert {s.current, s.behind, s.diverged, s.ahead, s.unmeasured} == {1, 1, 1, 1, 1}
  end

  ## 2. The SUBJECT LINE carries the corrected counts

  test "the subject line reports the stale box as behind, not current" do
    subject = DigestEmail.subject(DigestEmail.summary([stale_box(), fresh_box()]))

    assert subject == "Barkpark fleet digest — 1 current / 1 behind / 0 unmeasured / 0 paused"

    # BEFORE this slice the same fixture rendered "2 current / 0 behind /
    # 0 paused" — both boxes self-report `current` on the unmoved tag. That is
    # the exact byte-level lie this asserts is gone.
    refute subject =~ "2 current"
  end

  test "a fleet of five prod boxes behind main never reports a single one current" do
    rows =
      for d <- [1, 268, 633, 927, 2509] do
        box(
          name: "box-#{d}",
          slug: "box-#{d}",
          commit_ancestry: "behind",
          commit_distance: d,
          commit_distance_checked_at: @measured
        )
      end

    subject = DigestEmail.subject(DigestEmail.summary(rows))

    assert subject == "Barkpark fleet digest — 0 current / 5 behind / 0 unmeasured / 0 paused"
  end

  ## 3. UNMEASURED is its own rung, with a named reason

  test "a NULL commit_ancestry is unmeasured with a named reason — never current, never behind" do
    row = box(name: "Never", slug: "never", commit_ancestry: nil)
    s = DigestEmail.summary([row])

    assert {s.current, s.behind, s.unmeasured} == {0, 0, 1}
    assert DigestEmail.subject(s) =~ "0 current / 0 behind / 1 unmeasured"

    body = DigestEmail.body(s)
    assert body =~ "Fleet: 1 instance — 0 current, 0 behind, 1 unmeasured, 0 paused."

    assert body =~
             "- Never (never): v0.2.25 -> v0.2.25 | state: unmeasured (release self-report: current) | commit distance unmeasured (never measured) | checked 2026-08-07 14:02 UTC"
  end

  test "\"unknown\" names WHICH failure mode left it unmeasured" do
    offline =
      box(
        name: "Offline",
        slug: "offline",
        git_commit: nil,
        commit_ancestry: "unknown",
        commit_distance: nil,
        commit_distance_checked_at: @measured
      )

    refused =
      box(
        name: "Refused",
        slug: "refused",
        commit_ancestry: "unknown",
        commit_distance: nil,
        commit_distance_checked_at: @measured
      )

    body = DigestEmail.body(DigestEmail.summary([offline, refused]))

    assert body =~
             "commit distance unmeasured (instance has reported no commit; last asked 2026-08-08 03:11 UTC)"

    assert body =~
             "commit distance unmeasured (no usable answer from the commit compare; last asked 2026-08-08 03:11 UTC)"

    # The unmeasured pair is NOT quietly rounded into either bucket.
    s = DigestEmail.summary([offline, refused])
    assert {s.current, s.behind, s.unmeasured} == {0, 0, 2}
  end

  ## 4. `diverged` gets its own word

  test "diverged is its own word in the counts, the subject and the row" do
    row =
      box(
        name: "Fork",
        slug: "fork",
        commit_ancestry: "diverged",
        commit_distance: 7,
        commit_distance_checked_at: @measured
      )

    s = DigestEmail.summary([row])
    assert {s.current, s.behind, s.diverged} == {0, 0, 1}

    assert DigestEmail.subject(s) ==
             "Barkpark fleet digest — 0 current / 0 behind / 1 diverged / 0 unmeasured / 0 paused"

    assert DigestEmail.body(s) =~
             "- Fork (fork): v0.2.25 -> v0.2.25 | state: diverged (release self-report: current) | diverged from main, 7 commits not on main (measured 2026-08-08 03:11 UTC) | checked 2026-08-07 14:02 UTC"
  end

  test "ahead of main is its own word too, and appears only when a box is on it" do
    ahead =
      box(
        name: "Ahead",
        slug: "ahead",
        commit_ancestry: "ahead_of_main",
        commit_distance: 3,
        commit_distance_checked_at: @measured
      )

    assert DigestEmail.subject(DigestEmail.summary([ahead])) =~ "1 ahead of main"
    refute DigestEmail.subject(DigestEmail.summary([fresh_box()])) =~ "ahead of main"
    assert DigestEmail.body(DigestEmail.summary([ahead])) =~ "3 commits ahead of main"
  end

  ## 5. The distance is measured AT A TIME, never a constant

  test "the per-box row carries the distance together with its checked_at" do
    body = DigestEmail.body(DigestEmail.summary([stale_box()]))

    assert body =~
             "- Stale (stale): v0.2.25 -> v0.2.25 | state: behind (release self-report: current) | 2509 commits behind main (measured 2026-08-08 03:11 UTC) | checked 2026-08-07 14:02 UTC"

    # The SAME box measured again renders a different distance AND a different
    # measured-at — proof the number is presented as a reading, not a constant.
    later =
      stale_box(
        commit_distance: 2609,
        commit_distance_checked_at: ~U[2026-08-09 03:11:00.000000Z]
      )

    assert DigestEmail.body(DigestEmail.summary([later])) =~
             "2609 commits behind main (measured 2026-08-09 03:11 UTC)"
  end

  test "a measured verdict with no recorded clock says so rather than implying now" do
    row = stale_box(commit_distance_checked_at: nil)

    assert DigestEmail.body(DigestEmail.summary([row])) =~
             "2509 commits behind main (measured at an unrecorded time)"
  end

  test "a measured-behind box with no recorded distance never renders as 0" do
    row = stale_box(commit_distance: nil)
    body = DigestEmail.body(DigestEmail.summary([row]))

    assert body =~ "an unrecorded number of commits behind main"
    refute body =~ "0 commits behind main"
  end

  ## 6. MUTATION — the counts actually READ the measured column

  test "MUTATION: flipping commit_ancestry behind -> current moves the box between buckets" do
    behind = DigestEmail.summary([stale_box()])
    assert behind.behind == 1
    assert behind.current == 0

    # The ONLY field that changes is the one the plane measures.
    flipped = DigestEmail.summary([stale_box(commit_ancestry: "current")])
    assert flipped.behind == 0
    assert flipped.current == 1

    # If the counting ever stops reading `commit_ancestry`, these two subjects
    # become identical and this assertion reds.
    refute DigestEmail.subject(behind) == DigestEmail.subject(flipped)
  end

  ## 7. The email struct still renders, and the empty fleet is still honest

  test "build/2 renders the corrected subject into the actual email struct" do
    email = DigestEmail.build(DigestEmail.summary([stale_box(), fresh_box()]), "ops@example.com")

    assert email.subject ==
             "Barkpark fleet digest — 1 current / 1 behind / 0 unmeasured / 0 paused"

    assert email.text_body =~ "2509 commits behind main"
    assert [{_, "ops@example.com"}] = email.to
  end

  test "an empty fleet still renders a clear no-instances digest" do
    s = DigestEmail.summary([])

    assert DigestEmail.subject(s) ==
             "Barkpark fleet digest — 0 current / 0 behind / 0 unmeasured / 0 paused"

    body = DigestEmail.body(s)
    assert body =~ "Fleet: 0 instances."
    assert body =~ "No instances are registered yet"
  end

  test "policy flags still render beside the measured verdict" do
    row = stale_box(autoupdate_paused: true, pinned_release: "v0.2.20", autoupdate_enabled: false)

    body = DigestEmail.body(DigestEmail.summary([row]))

    assert body =~ "| pinned=v0.2.20, paused, autoupdate off | checked"
    assert body =~ "2509 commits behind main"
  end

  ## 8. dr-w27-s8 — THE DIGEST NAMES DEPLOY HEALTH
  ##
  ## The digest reached a human for the first time ever at 2026-08-09T06:00:00Z
  ## (four notification_deliveries rows, event=fleet_digest, status=sent) and
  ## the payload was deploy-blind: it told four people nothing about the fleet's
  ## deploy failures. These tests read the BYTES of the block that fixes that,
  ## and they exist mostly to pin what it is NOT allowed to say.
  ##
  ## `summary/2` takes the reading as an argument, so every case below is
  ## exercised without a database: these are the exact shapes
  ## `deploy_health/1` folds `DeployLedger.census/3` into.

  @read_at ~U[2026-08-09 06:00:00Z]

  defp window(label, door, deferred, failed, rate) do
    %{
      label: label,
      from: DateTime.add(@read_at, -86_400, :second),
      to: @read_at,
      door: door,
      deferred: deferred,
      failed: failed,
      rate: rate
    }
  end

  defp measured_rate(numerator, denominator) do
    %{
      sample: denominator,
      pct: Float.round(numerator * 100 / denominator, 2),
      numerator: numerator,
      min_sample: 200,
      refused: false,
      reason: nil,
      basis: "attempted rows in the window"
    }
  end

  defp refused_rate(denominator, reason) do
    %{
      sample: denominator,
      pct: nil,
      numerator: 0,
      min_sample: 200,
      refused: true,
      reason: reason,
      basis: "attempted rows in the window"
    }
  end

  defp health(windows) do
    %{windows: windows, measured_at: @read_at, unmeasured: false, reason: nil}
  end

  test "the digest body names the deploy doors — and every rate carries its deferred population" do
    deploy =
      health([
        window("last 24h", 852, 564, 53, measured_rate(53, 852)),
        %{
          window("last 7d", 9_156, 3_043, 6_180, measured_rate(6_180, 9_156))
          | from: DateTime.add(@read_at, -604_800, :second)
        }
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "Deploy health (control-plane deploy ledger, read 2026-08-09 06:00 UTC):"

    # THE BINDING SHAPE: door, deferrals and the post-door rate on ONE line.
    assert body =~
             "  last 24h (2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC): 852 attempted, of which 564 deferred by a busy box — 6.22% failed post-door (53 of 852 attempted)."

    assert body =~
             "  last 7d (2026-08-02 06:00 UTC to 2026-08-09 06:00 UTC): 9,156 attempted, of which 3,043 deferred by a busy box — 67.5% failed post-door (6,180 of 9,156 attempted)."
  end

  test "a rate can never be rendered without its door and its deferrals beside it" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    [line] = for l <- String.split(body, "\n"), l =~ "failed post-door", do: l

    # Every number the percentage depends on is on the SAME line as the
    # percentage. A future refactor that splits them apart reds here.
    assert line =~ "852 attempted"
    assert line =~ "564 deferred"
    assert line =~ "6.22%"
  end

  test "a window with no rows renders UNMEASURED — never 0%, never healthy" do
    deploy =
      health([window("last 24h", 0, 0, 0, refused_rate(0, "sample 0 below min_sample 200"))])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "  last 24h (2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC): UNMEASURED — no deploy rows at all in this window. A window with nothing in it is not a healthy fleet."

    # The reassuring readings a zero window must never be able to produce.
    refute body =~ "0% failed"
    refute body =~ "0.0% failed"
    refute body =~ "failed post-door"
    assert body =~ "is not a healthy fleet"
  end

  test "a refused rate keeps its counts and withholds only the ratio" do
    deploy =
      health([window("last 24h", 74, 12, 3, refused_rate(74, "sample 74 below min_sample 200"))])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "  last 24h (2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC): 74 attempted, of which 12 deferred by a busy box — failure rate UNMEASURED (sample 74 below min_sample 200); 3 of 74 attempted are settled failures"

    refute body =~ "% failed post-door"
  end

  test "a send that supplied no reading says so — the omission cannot render as a clean fleet" do
    body = DigestEmail.body(DigestEmail.summary([fresh_box()]))

    assert body =~ "Deploy health: UNMEASURED — this send supplied no deploy-ledger reading."
    refute body =~ "failed post-door"
  end

  test "an unreadable ledger renders UNMEASURED with the failure's own words" do
    deploy = DigestEmail.deploy_health(now: @read_at)

    # No sandbox is checked out in this async case, so the ledger read cannot
    # succeed — which is precisely the production failure mode being pinned: the
    # digest still renders, and it renders UNMEASURED rather than reassuring.
    assert %{unmeasured: true, windows: [], reason: reason} = deploy
    assert reason =~ "the deploy ledger"

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))
    assert body =~ "Deploy health: UNMEASURED — the deploy ledger"
    refute body =~ "failed post-door"
  end

  test "the digest never prints a lifetime deploy rate" do
    deploy =
      health([
        window("last 24h", 852, 564, 53, measured_rate(53, 852)),
        window("last 7d", 9_156, 3_043, 6_180, measured_rate(6_180, 9_156))
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    # The all-time numerator's honest freeze point is 2026-08-08T14:55:28.776961
    # at 18,640 — a number that is stale the moment it is written down. Only
    # windows this send pinned itself may be reported.
    refute body =~ "lifetime"
    refute body =~ "all-time"
    refute body =~ "18,640"
    refute body =~ "18640"

    # ...and every window it DOES report names both of its own bounds.
    assert body =~ "2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC"
  end

  test "the deploy block reaches the actual email struct, not just body/1" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])

    email =
      DigestEmail.build(
        DigestEmail.summary([stale_box()], deploy: deploy),
        "ops@example.com"
      )

    assert email.text_body =~ "852 attempted, of which 564 deferred by a busy box"
  end

  test "an empty fleet still reports deploy health — sites deploy even when no instance is registered" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    body = DigestEmail.body(DigestEmail.summary([], deploy: deploy))

    assert body =~ "No instances are registered yet"
    assert body =~ "852 attempted, of which 564 deferred"
  end

  test "MUTATION: the rendered percentage is DERIVED from the reading, not baked" do
    six = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    sixty = health([window("last 24h", 852, 564, 575, measured_rate(575, 852))])

    six_body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: six))
    sixty_body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: sixty))

    assert six_body =~ "6.22% failed post-door (53 of 852 attempted)"
    assert sixty_body =~ "67.49% failed post-door (575 of 852 attempted)"

    # If the block ever stops reading the reading, these two bodies become
    # identical and this reds.
    refute six_body == sixty_body
  end
end
