defmodule BarkparkCloud.Notifications.FleetDigestOutageReplayTest do
  @moduledoc """
  dr-w26 escalation — THE 2026-08-08 OUTAGE, REPLAYED THROUGH THE DIGEST RAIL.

  ## The outage, with its numbers

  Re-measured live on 2026-09-01 with
  `bp cloud deployments --from 2026-08-08T00:00:00Z --to 2026-08-09T00:00:00Z --sites 0`,
  which is the SAME `DeployLedger.census/3` this email reads. The window ran
  2026-08-08T00:00:00Z → 2026-08-09T00:00:00Z, one team (guerrilla):

    * `volume` **758** attempted rows = 238 live + 502 deferred + **18 failed**
    * `failure_rate` **2.37%** of 758 (NOT refused — 758 is above `min_sample` 200)
    * `terminal_failure_rate` 7.03% of 256 terminal rows; `live_rate` 31.4%
    * the 18 failures landed **10:00:14Z → 14:55:28Z** (4h55m) across **five**
      sites, all `trigger=content-auto` / `source=box-build`
    * eight sites deployed at all; per-site volume
      162 / 159 / 146 / 143 / 126 / 18 / 3 / 1, and the failures fell 6 / 4 / 2 /
      5 / 1 / 0 / 0 / 0
    * `deferral_wait` max 3,784.42s, p50 301.794s, p95 1,587.935s over 502
      COVERED rows, 0 pending; both coverage cohorts fully covered (502/502
      deferred, 18/18 failed)

  ## What the filing got wrong about the causes

  The row (and charter D455) say **"3 causes"**: 8× *instance unreachable*, 7×
  *HEALTH gate … bp-doc-id marker is empty*, 3× *deploy process died abnormally*.
  That is the PROSE grouping. The ledger's own classifier splits the middle seven
  into three distinct content-API failure modes, so the taxonomy names **five**:

      BOX_UNREACHABLE 8 · CONTENT_API_UNREACHABLE 4 · PROCESS_DIED 3 ·
      CONTENT_API_500 2 · CONTENT_API_503 1                        (= 18)

  4 + 2 + 1 = the 7 marker-empty rows. `graph 0` (fetch threw before any HTTP
  answer — DNS/TLS/refused) is not `graph 503` (the API answered, overloaded),
  and `DeployLedger.content_api_class/1` refuses to fold them. Quoting three
  causes understates the fan-out of the incident by two.

  ## What this file proves, and what it does not

  It builds that shape as REAL `deployments` rows for a REAL team's five sites
  and drives the REAL rail — `DeployLedger.census/3` → `DigestEmail.deploy_health/1`
  → `DigestEmail.summary/2` → `DigestEmail.build/2`, and in §2 the whole of
  `Notifications.deliver_fleet_digest/1` including the send. The assertions read
  the delivered BYTES, because the bytes are what a human receives.

  THE HONEST LIMIT. Counts, per-site partition, window bounds and class totals
  are the real ones. The per-row INSTANTS inside the window are synthesized (the
  18 failures are spread across the real 10:00:14Z → 14:55:28Z span; deferrals sit
  before the live rows so all 502 come back COVERED, as they really are), and the
  class→site assignment inside the real class totals is synthesized. So nothing
  here asserts the deferral-wait QUANTILES — those would be fixture artefacts.

  AND WHAT "PLATFORM-ADDRESSED" MEANS HERE. Charter D362 rules this digest
  PER-TEAM: the body names instances and sites by name, so a fleet-wide blast is a
  cross-team disclosure. A literal platform recipient does not exist —
  `PLATFORM_ADMIN_EMAILS` is unset on prod and settable by no route, console
  action or User field (`dr-bl-w5-census-is-dark-to-every-human`) — and this file
  invents none. The signal it proves is the one D362 permits: the team that owns
  the five failing sites receives an email that NAMES the failures, where before
  dr-w28-s5 the digest said nothing whatsoever about deploys and before dr-w19-s5
  it was addressed to nobody at all.
  """
  use BarkparkCloud.DataCase, async: true

  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Notifications, Registry, Repo}
  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Notifications.DigestEmail
  alias BarkparkCloud.Registry.Deployment

  # The digest door that would have carried this outage: the 06:00Z cron read on
  # the morning after. Its "last 24h" window is exactly the window measured above.
  @read_at ~U[2026-08-09 00:00:00Z]

  @outage_start ~U[2026-08-08 10:00:14Z]
  @outage_end ~U[2026-08-08 14:55:28Z]

  # The eight sites that deployed, worst-volume first, as {failed, deferred, live}.
  # Sums: failed 18, deferred 502, live 238, volume 758.
  @site_shape [
    {6, 112, 44},
    {4, 112, 43},
    {2, 103, 41},
    {5, 92, 46},
    {1, 81, 44},
    {0, 2, 16},
    {0, 0, 3},
    {0, 0, 1}
  ]

  # The 18 failures, in the ledger's OWN classes, per site (index into @site_shape).
  # Totals: BOX_UNREACHABLE 8, CONTENT_API_UNREACHABLE 4, PROCESS_DIED 3,
  # CONTENT_API_500 2, CONTENT_API_503 1.
  @failure_shape [
    {0, "BOX_UNREACHABLE", 4},
    {0, "CONTENT_API_UNREACHABLE", 2},
    {1, "BOX_UNREACHABLE", 3},
    {1, "CONTENT_API_UNREACHABLE", 1},
    {2, "CONTENT_API_500", 2},
    {3, "BOX_UNREACHABLE", 1},
    {3, "CONTENT_API_UNREACHABLE", 1},
    {3, "PROCESS_DIED", 3},
    {4, "CONTENT_API_503", 1}
  ]

  ## ── 1. The literal window ────────────────────────────────────────────────
  ##
  ##    The rows carry their real 2026-08-08 instants and the reading is pinned
  ##    at the 2026-08-09T00:00Z door, so the census here is measuring the same
  ##    24 hours `bp cloud deployments --from … --to …` measured on prod.

  test "the 2026-08-08 window, replayed: the digest body NAMES 18 failures in 758 attempts" do
    {_user, team} = user_team()
    sites = seed_outage(team, @read_at)

    assert length(sites) == 8

    body = team_body(team, @read_at)

    # THE HEADLINE THE OUTAGE WOULD HAVE PRODUCED. Every number is the real one,
    # computed by `DeployLedger.census/3` over real rows and rendered by the real
    # email — not a fixture map handed to the renderer.
    assert body =~ "758 attempted, of which 502 deferred by a busy box"
    assert body =~ "2.37% failed post-door (18 of 758 attempted)"

    # A DOOR WITH ROWS IN IT IS NAMED AS SUCH, and the window is stated, so the
    # rate can never be read without the hours it was taken over.
    assert body =~ "last 24h (2026-08-08 00:00 UTC to 2026-08-09 00:00 UTC)"

    # The deferral population survives the quantiles (which this file does not
    # assert — see the moduledoc): 502 of 502 covered, nothing left waiting, which
    # is what prod really carried.
    assert body =~ "502 of 502 deferred rows have since rebuilt, 0 are still waiting"

    # NOT the reassuring shapes. Before dr-w28-s5 this block did not exist and the
    # digest's only sentence about a five-site outage was silence.
    refute body =~ "Deploy health: UNMEASURED"
    refute body =~ "this team owns no sites"
    refute body =~ "no deploy rows at all in this window"
  end

  test "the ledger's own classifier names FIVE causes over these 18 rows, not three" do
    {_user, team} = user_team()
    seed_outage(team, @read_at)

    census =
      DeployLedger.census(DateTime.add(@read_at, -86_400, :second), @read_at,
        site_ids: team_site_ids(team),
        site_limit: 0
      )

    assert census.volume == 758
    assert census.failed == 18
    assert census.deferred_total == 502
    assert census.failure_rate.pct == 2.37
    refute census.failure_rate.refused

    classes = Map.new(census.classes, &{&1.class, &1.count})

    # The correction this file exists to record: D455's "3 causes" is the prose
    # grouping; the taxonomy the platform actually reports splits the seven
    # marker-empty rows into three content-API modes.
    assert classes == %{
             "BOX_UNREACHABLE" => 8,
             "CONTENT_API_UNREACHABLE" => 4,
             "PROCESS_DIED" => 3,
             "CONTENT_API_500" => 2,
             "CONTENT_API_503" => 1
           }

    assert classes |> Map.values() |> Enum.sum() == 18
    assert map_size(classes) == 5
  end

  ## ── 2. THE WHOLE RAIL — the outage reaches an inbox ──────────────────────
  ##
  ##    §1 proves the RENDERER names the failures. This proves the SEND does:
  ##    `Notifications.deliver_fleet_digest/1` over the real fleet, resolving the
  ##    real membership rows, mailing the real `Mailer`. `deliver_fleet_digest/1`
  ##    takes its reading at `DateTime.utc_now/0`, so the shape is re-anchored to
  ##    now — the counts, the site partition and the classes are unchanged; only
  ##    the wall-clock is moved, and that is stated rather than hidden.

  test "a five-site outage of this shape reaches the owning team's inbox, naming the failures" do
    {user, team} = user_team()
    {:ok, _bp} = Registry.register_barkpark(team, %{name: "Prod", slug: prod_slug()})

    now = DateTime.utc_now()
    seed_outage(team, now)

    assert {:ok, %{sent: 1, recipients: [recipient]}} =
             Notifications.deliver_fleet_digest(Registry.all_barkparks())

    assert recipient == user.email

    # THE DELIVERED BYTES. Not the summary map, not the builder's return — the
    # email the Swoosh adapter accepted.
    assert_email_sent(fn email ->
      assert Enum.any?(email.to, fn {_name, address} -> address == user.email end)
      assert email.text_body =~ "758 attempted, of which 502 deferred by a busy box"
      assert email.text_body =~ "2.37% failed post-door (18 of 758 attempted)"
    end)

    # And the receipt exists, owned by the team it concerns — the row type that
    # was ZERO in `notification_deliveries` for the whole recorded life of this
    # channel before dr-w19-s5.
    assert [receipt] =
             Notifications.Delivery
             |> Repo.all()
             |> Enum.filter(&(&1.event == "fleet_digest"))

    assert receipt.status == "sent"
    assert receipt.team_id == team.id
  end

  ## ── 3. MUTATION — the numbers are DERIVED, not baked ─────────────────────
  ##
  ##    Without this, §1 would pass against a renderer that printed the string
  ##    "18 of 758" from anywhere at all. Delete the 18 failed rows and the same
  ##    call must produce different bytes.

  test "MUTATION: with the 18 failed rows gone, the same rail reports 0 of 740" do
    {_user, team} = user_team()
    seed_outage(team, @read_at)

    with_failures = team_body(team, @read_at)

    {18, _} = Repo.delete_all(from(d in Deployment, where: d.status == "failed"))

    without = team_body(team, @read_at)

    assert with_failures =~ "2.37% failed post-door (18 of 758 attempted)"
    assert without =~ "0.0% failed post-door (0 of 740 attempted)"
    refute without =~ "18 of 758 attempted"
    refute with_failures == without
  end

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  # Exactly what `Notifications.deliver_fleet_digest/1` does for one team: list
  # that team's sites, narrow the ledger read to them, render the bytes.
  defp team_body(team, now) do
    DigestEmail.body(
      DigestEmail.summary([],
        deploy: DigestEmail.deploy_health(now: now, site_ids: team_site_ids(team))
      )
    )
  end

  defp team_site_ids(team), do: team |> Registry.list_sites_for_team() |> Enum.map(& &1.id)

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "outage-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = Accounts.create_team(%{name: "Outage #{n}", slug: "outage-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp prod_slug, do: "prod-#{System.unique_integer([:positive])}"

  # Seed the 2026-08-08 shape against a window ENDING at `read_at`: eight sites,
  # 758 rows, the 18 failures spread over the real 4h55m span, the 502 deferrals
  # all covered by later live rows.
  defp seed_outage(team, read_at) do
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Fleet", slug: prod_slug()})

    sites =
      for _ <- @site_shape do
        n = System.unique_integer([:positive])
        {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
        site
      end

    # The outage span, re-anchored so it ends inside the 24h door that closes at
    # `read_at`. For the literal @read_at this is the real 10:00:14Z → 14:55:28Z.
    span = DateTime.diff(@outage_end, @outage_start, :second)
    day_end = DateTime.diff(~U[2026-08-09 00:00:00Z], @outage_end, :second)
    fail_to = DateTime.add(read_at, -day_end, :second)
    fail_from = DateTime.add(fail_to, -span, :second)

    # Deferrals sit before the outage; live rows after it, so every deferral is
    # COVERED by a later live build on its own site (as all 502 really were).
    deferred_at = DateTime.add(fail_from, -1800, :second)
    live_at = DateTime.add(fail_to, 600, :second)

    rows =
      sites
      |> Enum.zip(@site_shape)
      |> Enum.flat_map(fn {site, {_failed, deferred, live}} ->
        bulk(site, "deferred", deferred, deferred_at, deferral_reason()) ++
          bulk(site, "live", live, live_at, nil)
      end)

    failures =
      @failure_shape
      |> Enum.flat_map(fn {index, class, count} ->
        site = Enum.at(sites, index)
        for _ <- 1..count, do: {site, class}
      end)
      |> Enum.with_index()
      |> Enum.map(fn {{site, class}, i} ->
        # Spread the 18 across the real span, first row at its start.
        at = DateTime.add(fail_from, div(i * span, 17), :second)
        {stage, reason} = failure_copy(class)
        row(site, "failed", at, reason, stage)
      end)

    Repo.insert_all(Deployment, rows ++ failures)
    sites
  end

  defp bulk(_site, _status, 0, _at, _reason), do: []

  defp bulk(site, status, count, at, reason),
    do: for(_ <- 1..count, do: row(site, status, at, reason, nil))

  defp row(site, status, at, reason, stage) do
    # `insert_all` dumps straight to `:utc_datetime_usec`, which REFUSES a
    # second-precision struct — carry the precision, do not truncate to it.
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    %{
      id: Ecto.UUID.generate(),
      site_id: site.id,
      status: status,
      environment: "production",
      trigger: "content-auto",
      source: "box-build",
      stage: stage,
      failure_reason: reason,
      inserted_at: at,
      updated_at: at
    }
  end

  # The producers' OWN phrases, because `DeployLedger.classify/2` reads the raw
  # `failure_reason` (and, for the content-API modes, the `HEALTH` stage plus the
  # graph status the SSR recorded). A paraphrase would classify UNCLASSIFIED and
  # the class assertion in §1 would say so.
  defp failure_copy("BOX_UNREACHABLE"), do: {nil, "instance guerrilla is unreachable"}
  defp failure_copy("PROCESS_DIED"), do: {nil, "deploy process died abnormally"}

  defp failure_copy("CONTENT_API_UNREACHABLE"),
    do: {"HEALTH", health_reason(0, "fetch failed")}

  defp failure_copy("CONTENT_API_500"),
    do: {"HEALTH", health_reason(500, "internal error")}

  defp failure_copy("CONTENT_API_503"),
    do: {"HEALTH", health_reason(503, "service unavailable")}

  defp health_reason(code, detail),
    do:
      "HEALTH gate failed: the bp-doc-id marker is empty; " <>
        "the SSR could not read a content document: graph #{code}: #{detail}"

  defp deferral_reason,
    do: "the instance refused the deploy (HTTP 409): already_running"
end
