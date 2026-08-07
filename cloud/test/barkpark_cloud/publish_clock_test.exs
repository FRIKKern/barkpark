defmodule BarkparkCloud.PublishClockTest do
  @moduledoc """
  The publish→web clock — deploy-reliability W12 S2.

  Six properties, each of which the reader is worthless (or dishonest) without:

    1. THE HONESTY GUARD IS NOT DECORATION. A build already in flight when the
       publish arrived is NOT credited with serving it. The control query — the
       same lateral join with `inserted_at >= received_at` deleted — IS run here,
       so the assertion is "the guard changed the answer by 21x", not "the guard
       is present in a string".

    2. THE SEEK BOUND'S PREMISE IS CHECKED, AND THE CHECK CAN LOSE. A deliberately
       impossible row (live before inserted) flips `seek_bound/0` off `safe?`.

    3. AN EMPTY TABLE PRODUCES A CENSOR LINE, NOT A ZERO. No percentile, and the
       line names WHEN the recorder started.

    4. THE CENSOR DATE COMES FROM THE MIGRATION, NOT FROM THE DATA. Pinned
       against a fixture whose `min(received_at)` is a different instant — the
       exact confusion that reads "no publishes yet" as "recorder not running".

    5. FOUR NAMED BUCKETS, and `site_never_live` ships LABELLED structurally
       unreachable rather than as a live bucket.

    6. THE DENOMINATOR IS DELIVERIES. A 5x fan-out fixture, the N:1 invariant
       (`delivered >= distinct matched deployments`), and no `:publishes` key to
       grab by accident.

  `async: true`: every fixture is inside the sandbox transaction and nothing here
  touches process-global config.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, PublishClock, Registry, Repo}
  alias BarkparkCloud.Registry.{ContentPublish, Deployment}

  @password "correct-horse-battery"

  # A pinned window well clear of both `now` and the test DB's migration instant.
  @from ~U[2026-08-01 00:00:00.000000Z]
  @to ~U[2026-08-02 00:00:00.000000Z]
  # "now" for horizon purposes: 3 days after the window, so every unmatched row
  # in it is far outside the 900s horizon unless a test says otherwise.
  @now ~U[2026-08-05 00:00:00.000000Z]

  # The control query: THE SAME lateral join with the honesty guard deleted.
  # Deleting the guard is the whole experiment — if this returns the same rows as
  # the census, the guard is decoration and property 1 is a lie.
  @unguarded_sql """
  SELECT p.id, d.id AS deployment_id, d.became_live_at
  FROM content_publishes p
  LEFT JOIN LATERAL (
    SELECT dd.id, dd.became_live_at
    FROM deployments dd
    WHERE dd.site_id = p.site_id
      AND dd.became_live_at IS NOT NULL
      AND dd.became_live_at >= p.received_at
    ORDER BY dd.became_live_at
    LIMIT 1
  ) d ON TRUE
  WHERE p.received_at >= $1 AND p.received_at < $2
  """

  ## ── 1. The join rule ──────────────────────────────────────────────────────

  describe "the join rule (D176)" do
    test "the query source carries all three predicates, the seek-bound comment, and the order" do
      sql = PublishClock.census_sql()

      assert sql =~ "dd.became_live_at IS NOT NULL"
      assert sql =~ "AND dd.became_live_at >= p.received_at"
      assert sql =~ "AND dd.inserted_at >= p.received_at"
      assert sql =~ "ORDER BY dd.became_live_at"
      assert sql =~ "LIMIT 1"
      # The seek bound is documented as a PERFORMANCE predicate, so a later
      # reader cannot mistake it for the thing that makes the answer correct.
      assert sql =~ "PERFORMANCE PREDICATE ONLY"
      assert sql =~ "THE HONESTY GUARD"
    end

    test "the guard is not decoration: an in-flight build is NOT credited, and without the guard it would be" do
      site = site_fixture()

      # The publish. t0.
      publish_at = ~U[2026-08-01 12:00:00.000000Z]

      # A build ALREADY IN FLIGHT when the publish arrived — inserted 60s before
      # it, live 10s after it. It cannot be carrying this publish's bytes.
      in_flight =
        deployment!(site,
          inserted_at: DateTime.add(publish_at, -60, :second),
          became_live_at: DateTime.add(publish_at, 10, :second)
        )

      # The build this publish actually caused: enqueued after the debounce,
      # live 214.3s after the publish.
      real =
        deployment!(site,
          inserted_at: DateTime.add(publish_at, 61, :second),
          became_live_at: DateTime.add(publish_at, 214_300, :millisecond)
        )

      publish!(site, publish_at)

      census = PublishClock.census(@from, @to, now: @now)

      assert [%{bucket: "delivered", count: 1}, _, _, _] = census.buckets
      assert census.matched_deployments == 1

      # The guarded answer, from the module's OWN query text: it credits the
      # deployment this publish actually caused, at 214.3s.
      %{rows: [[_pid, _sid, _rat, _dt, _enq, guarded_id, guarded_live]]} =
        Repo.query!(PublishClock.census_sql(), [naive(@from), naive(@to)])

      assert uuid(guarded_id) == real.id
      assert wait(publish_at, guarded_live) == 214.3

      # …and the control: with the guard DELETED, the same delivery credits the
      # in-flight build at 10.0s — a 21x understatement of a wait nobody waited,
      # attributed to bytes that build could not have contained.
      %{rows: [[_pid, unguarded_id, unguarded_live]]} =
        Repo.query!(@unguarded_sql, [naive(@from), naive(@to)])

      assert uuid(unguarded_id) == in_flight.id
      refute uuid(unguarded_id) == real.id
      assert wait(publish_at, unguarded_live) == 10.0
    end

    test "seek_bound/0 checks its premise, and the check can LOSE" do
      site = site_fixture()

      deployment!(site,
        inserted_at: ~U[2026-08-01 12:00:00.000000Z],
        became_live_at: ~U[2026-08-01 12:01:00.000000Z]
      )

      assert %{violations: 0, safe?: true, note: note} = PublishClock.seek_bound()
      assert note =~ "drops nothing"

      # An impossible row: live BEFORE it was inserted. If the check cannot see
      # this, it cannot see anything.
      deployment!(site,
        inserted_at: ~U[2026-08-01 13:00:00.000000Z],
        became_live_at: ~U[2026-08-01 12:59:00.000000Z]
      )

      assert %{violations: 1, safe?: false, note: broken} = PublishClock.seek_bound()
      assert broken =~ "no longer implied"

      # …and the census REPORTS it rather than silently changing meaning.
      assert %{safe?: false} = PublishClock.census(@from, @to, now: @now).seek_bound
    end
  end

  ## ── 2. Correct on an empty table ──────────────────────────────────────────

  describe "the censored/empty population" do
    test "zero deliveries produces a censor line naming the recorder start — and NO percentile" do
      site = site_fixture()
      # The window is not empty of DEPLOYS — it is empty of recorded publishes.
      deployment!(site,
        inserted_at: ~U[2026-08-01 09:00:00.000000Z],
        became_live_at: ~U[2026-08-01 09:05:00.000000Z]
      )

      census = PublishClock.census(@from, @to, now: @now)

      assert census.deliveries == 0
      assert census.censor.censored?

      since = census.censor.recorder_live_since
      assert %DateTime{} = since

      # The line names the recorder start and refuses to read "no rows" as zero.
      assert census.censor.line =~ "0 of 1 live deploys"
      assert census.censor.line =~ DateTime.to_iso8601(since)
      assert census.censor.line =~ "censored, not zero"

      # No comforting number anywhere: the percentile is refused, not 0.0.
      assert %{refused: true, p50: nil, p90: nil, p99: nil, max: nil, sample: 0} =
               census.wait_seconds

      assert census.wait_seconds.reason =~ "below min_sample"
    end

    test "a database that never applied the recorder's migration says UNKNOWN, not a data fallback" do
      # Inside the sandbox transaction, so the delete is rolled back with the test.
      Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [20_260_807_130_000])

      site = site_fixture()
      publish!(site, ~U[2026-08-01 05:00:00.000000Z])

      census = PublishClock.census(@from, @to, now: @now)

      assert is_nil(PublishClock.recorder_live_since())
      assert is_nil(census.censor.recorder_live_since)
      assert census.censor.censored?
      assert census.censor.line =~ "recorder start UNKNOWN"
      # The tempting fallback — the earliest row it happens to hold — is absent.
      refute census.censor.line =~ "2026-08-01T05:00:00"
    end

    test "the censor date is the MIGRATION instant, never min(received_at)" do
      site = site_fixture()
      earliest = ~U[2026-08-01 03:00:00.000000Z]
      publish!(site, earliest)
      publish!(site, ~U[2026-08-01 04:00:00.000000Z])

      census = PublishClock.census(@from, @to, now: @now)

      %{rows: [[migrated_at]]} =
        Repo.query!("SELECT inserted_at FROM schema_migrations WHERE version = $1", [
          20_260_807_130_000
        ])

      migrated_at = DateTime.from_naive!(migrated_at, "Etc/UTC")

      assert census.censor.recorder_live_since == migrated_at
      assert census.censor.source =~ "schema_migrations"

      # THE POINT: the two instants are different, so a reader quoting
      # min(received_at) would claim coverage this window does not have.
      refute DateTime.compare(migrated_at, earliest) == :eq

      %{rows: [[min_received]]} =
        Repo.query!("SELECT min(received_at) FROM content_publishes", [])

      assert DateTime.from_naive!(min_received, "Etc/UTC") == earliest
      refute census.censor.recorder_live_since == earliest

      # This window opens before the recorder did, and the line says so.
      assert census.censor.censored?
      assert census.censor.line =~ "censored, not absent"
    end
  end

  ## ── 3. The four buckets ───────────────────────────────────────────────────

  describe "the four named buckets" do
    test "all four are emitted with distinct names, and site_never_live is labelled unreachable" do
      # delivered
      live_site = site_fixture()
      p1 = ~U[2026-08-01 10:00:00.000000Z]

      deployment!(live_site,
        inserted_at: DateTime.add(p1, 30, :second),
        became_live_at: DateTime.add(p1, 90, :second)
      )

      publish!(live_site, p1)

      # never_delivered: same site (it DID go live in the window), a publish far
      # outside the horizon with nothing forward of it.
      publish!(live_site, ~U[2026-08-01 23:00:00.000000Z])

      # site_never_live: a site with no live deployment at all.
      dead_site = site_fixture()
      publish!(dead_site, ~U[2026-08-01 11:00:00.000000Z])

      # waiting_censored: inside the horizon of a `now` pinned just after it.
      waiting_site = site_fixture()
      recent = ~U[2026-08-01 23:59:00.000000Z]
      publish!(waiting_site, recent)

      now = ~U[2026-08-02 00:05:00.000000Z]
      census = PublishClock.census(@from, @to, now: now)

      names = Enum.map(census.buckets, & &1.bucket)
      assert names == ~w(delivered waiting_censored never_delivered site_never_live)
      assert names == Enum.uniq(names)

      assert bucket(census, "delivered").count == 1
      assert bucket(census, "waiting_censored").count == 1
      assert bucket(census, "never_delivered").count == 1
      assert bucket(census, "site_never_live").count == 1

      # Shipped, but never as a live bucket.
      unreachable = bucket(census, "site_never_live")
      assert unreachable.structurally_unreachable
      assert unreachable.note =~ "STRUCTURALLY UNREACHABLE"
      assert unreachable.note =~ "HMAC-verified content-webhook"

      refute bucket(census, "delivered").structurally_unreachable
      refute bucket(census, "never_delivered").structurally_unreachable

      # …and the moduledoc says the same thing, so a reader of the code and a
      # reader of the output get the same warning.
      assert moduledoc(PublishClock) =~ "IS SHIPPED BUT IS STRUCTURALLY UNREACHABLE"
    end

    test "a right-censored delivery is bounded, never folded into a percentile" do
      site = site_fixture()
      recent = ~U[2026-08-01 23:59:00.000000Z]
      publish!(site, recent)

      now = ~U[2026-08-02 00:04:00.000000Z]
      census = PublishClock.census(@from, @to, now: now)

      assert bucket(census, "waiting_censored").count == 1
      # Reported as a LOWER BOUND: 300s and counting.
      assert census.waiting.count == 1
      assert census.waiting.at_least_seconds == 300.0
      assert census.waiting.note =~ ">= 300.0s"
      # …and absent from the percentile sample entirely.
      assert census.wait_seconds.sample == 0
    end
  end

  ## ── 4. Deliveries, not publishes ──────────────────────────────────────────

  describe "the denominator" do
    test "is labelled deliveries, has no :publishes key, and holds the N:1 invariant" do
      # One human publish → five deliveries, one per webhook-bound site. Three of
      # the five sites share nothing; two of them are served by deployments that
      # both go live, so deliveries >= matched deployments, strictly.
      at = ~U[2026-08-01 14:00:00.000000Z]

      sites = for _ <- 1..5, do: site_fixture()

      for site <- sites do
        deployment!(site,
          inserted_at: DateTime.add(at, 60, :second),
          became_live_at: DateTime.add(at, 120, :second)
        )

        publish!(site, at)
      end

      # The SECOND burst: the same five sites publish again 30s later, and each
      # site's still-pending build serves both deliveries. Ten deliveries, five
      # deployments — the N:1 fan-out, exactly as measured on prod.
      for site <- sites, do: publish!(site, DateTime.add(at, 30, :second))

      census = PublishClock.census(@from, @to, now: @now)

      assert census.deliveries == 10
      assert census.denominator_label == "deliveries"
      refute Map.has_key?(census, :publishes)
      refute Map.has_key?(census.fan_out, :publishes)

      assert bucket(census, "delivered").count == 10
      assert census.matched_deployments == 5
      # THE INVARIANT: many deliveries may credit one deployment; never the reverse.
      assert census.fan_out.delivered >= census.matched_deployments
      assert census.fan_out.n_to_1_ok?
      assert census.fan_out.note =~ "one row per webhook-bound site"
    end

    test "percentiles compute above min_sample, and only over delivered rows" do
      site = site_fixture()
      base = ~U[2026-08-01 06:00:00.000000Z]

      # 20 deliveries, waits 1..20 seconds — exactly min_sample.
      for i <- 1..20 do
        at = DateTime.add(base, i * 600, :second)

        deployment!(site,
          inserted_at: DateTime.add(at, 1, :millisecond),
          became_live_at: DateTime.add(at, i, :second)
        )

        publish!(site, at)
      end

      census = PublishClock.census(@from, @to, now: @now)

      assert census.wait_seconds.sample == 20
      assert census.wait_seconds.min_sample == PublishClock.min_sample()
      refute census.wait_seconds.refused
      # Nearest-rank over 1..20.
      assert census.wait_seconds.p50 == 10.0
      assert census.wait_seconds.p90 == 18.0
      assert census.wait_seconds.p99 == 20.0
      assert census.wait_seconds.max == 20.0

      # One more delivery, right-censored, must NOT move the sample.
      publish!(site, ~U[2026-08-01 23:59:30.000000Z])
      later = PublishClock.census(@from, @to, now: ~U[2026-08-02 00:00:30.000000Z])
      assert later.deliveries == 21
      assert later.wait_seconds.sample == 20
      assert later.wait_seconds.p50 == 10.0
    end
  end

  ## ── 5. This slice touched nothing else ────────────────────────────────────

  describe "the module's own boundaries" do
    test "the retention answer and the readership caveat are written down, with numbers" do
      doc = moduledoc(PublishClock)

      assert doc =~ "670 rows/day"
      assert doc =~ "REVISIT TRIGGER"
      assert doc =~ "~50k rows/day"
      # The trap that produces the wrong rate, named so nobody re-derives it.
      assert doc =~ "1,339/day"
      # Queryable law before it is a surface.
      assert doc =~ "PLATFORM_ADMIN_EMAILS"
      assert doc =~ "require_platform_operator"
    end
  end

  ## ── Fixtures ──────────────────────────────────────────────────────────────

  defp site_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Deployments are inserted as STRUCTS: `Deployment.changeset/2` forbids casting
  # `status`, and every instant here must be pinned to the microsecond.
  defp deployment!(site, attrs) do
    inserted_at = attrs |> Keyword.fetch!(:inserted_at) |> usec()

    Repo.insert!(%Deployment{
      site_id: site.id,
      status: "live",
      environment: "production",
      became_live_at: attrs |> Keyword.get(:became_live_at) |> usec(),
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp publish!(site, received_at) do
    {:ok, row} = ContentPublish.record(site.id, usec(received_at), %{doc_type: "paper"})
    row
  end

  defp usec(nil), do: nil
  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp bucket(census, name), do: Enum.find(census.buckets, &(&1.bucket == name))

  defp naive(%DateTime{} = dt), do: DateTime.to_naive(dt)

  # Raw queries hand back the 16-byte uuid, not its text form.
  defp uuid(raw) when is_binary(raw), do: Ecto.UUID.cast!(raw)

  # Seconds between a publish instant and a raw `became_live_at` read straight
  # off a query result (Postgrex hands back NaiveDateTime for `timestamp`).
  defp wait(%DateTime{} = publish_at, %NaiveDateTime{} = live_at) do
    live_at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.diff(publish_at, :microsecond)
    |> Kernel./(1_000_000)
    |> Float.round(1)
  end

  defp moduledoc(module) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    doc
  end
end
