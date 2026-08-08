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
end
