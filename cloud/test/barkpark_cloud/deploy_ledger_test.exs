defmodule BarkparkCloud.DeployLedgerTest do
  @moduledoc """
  The fleet deploy ledger — deploy-reliability W1 S2.

  Four properties, each of which the ledger is worthless without:

    1. THE TAXONOMY IS KEYED ON THE RAW COLUMN AND ON (stage, prefix). Every
       fixture string below is a VERBATIM sample re-derived from the control
       plane on 2026-08-05 (`cloud-db-1`, 26,671 rows / 17,395 failed), not an
       invented one — including the bare pre-2026-07-30 `HTTP 409` with no
       `already_running` clause, which is 3,814 of 8,970 409-rows and which a
       classifier keyed on the code word silently loses.

    2. UNCLASSIFIED CAN GO UP. An unrecognised reason lands in UNCLASSIFIED, not
       in the nearest bucket, and the census COUNTS it there.

    3. EVERY RATE CARRIES ITS DENOMINATOR, and below `min_sample/0` there is no
       percentage at all — the refusal is behaviour, asserted here, not a
       docstring. `GITHUB_PUSH_UNBUILDABLE` is out of the denominator entirely.

    4. THE CURSOR REACHES PAST 200. Two pages, non-overlapping, over a 250-row
       site — the read `?offset=200` could never do.

  `async: false`: the operator allowlist is process-global Application config
  (`:platform_admin_emails`), mirroring RouterOperatorTest.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # ── Verbatim corpus samples (2026-08-05 re-derivation) ────────────────────

  # 5,147 rows. The post-fe264a35b shape, with the machine-readable code.
  @r409_coded "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight"
  # 3,814 rows (43% of all 409s). The BARE pre-2026-07-30 shape: no code word at
  # all. This string is the whole reason BOX_BUSY keys on "HTTP 409".
  @r409_bare "the instance refused the deploy (HTTP 409)"
  @r500 "the instance refused the deploy (HTTP 500)"
  @r503 "the instance refused the deploy (HTTP 503): feature_not_configured"
  # 265 rows — EVERY BOX_UNAVAILABLE_503 row on cloud-db-1, all-time (first
  # 2026-07-30 14:24:47Z, last 2026-08-07 03:19:21Z). Byte-verbatim from the
  # column: the box named its own code word and said what it meant.
  @r503_disabled "the instance refused the deploy (HTTP 503): feature_not_configured — site deploys are not enabled on this instance (set BARKPARK_SITE_DEPLOY_APPLY=1)"
  # The SECOND cause on the same status (dr-w8-s2 / #10015): a wedged runner,
  # with the box's request-id stamped INSIDE the first ` — ` segment exactly as
  # `Sites.Deploy.box_refusal/3` writes it, plus the grace note the failing beat
  # appends. Opposite operator instruction to the one above.
  @r503_runner "the instance refused the deploy (HTTP 503): deploy_runner_unavailable — the deploy runner did not answer in time [box request_id: F9tPXq2A] (after tolerating 3 transient box 5xx; the last was: the deploy runner did not answer in time)"
  # A 503 whose code word this ledger has never named, and a 503 whose detail is
  # bare prose. Neither may be promoted to a named cause.
  @r503_unknown "the instance refused the deploy (HTTP 503): shard_draining — the region is being drained"
  @r503_prose "the instance refused the deploy (HTTP 503): everything is on fire right now"
  @r429 "the instance refused the deploy (HTTP 429): rate_limited — try again shortly"
  # An HTTP status the ledger has never named: 2 rows. Must be UNCLASSIFIED.
  @r404 "the instance refused the deploy (HTTP 404)"
  @doc_id "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty"
  @doc_id_alt "HEALTH failed — bp-doc-id marker is empty — the SSR rendered nothing"
  @health_slot "HEALTH gate failed — not switched (exit 14): slot a on :8404 returned 502"
  # 1,082 rows: the site build fetched its corpus from the Barkpark API and was
  # refused. Real 0x1B bytes, exactly as captured from the build PTY.
  @build_403 "BUILD failed (exit 12): \e[31m\e[1m04:34:24\e[22m [ERROR] [build]\e[39m Caught error rendering /graph.json: Error: graph corpus fetch failed: 403"
  @build_plain "BUILD failed (exit 12): at async #getPathsForRoute (file:///opt/barkpark/sites/demo/node_modules/astro/dist/core/build.js:12:3)"
  # ── The CONTENT API's own status, in BOTH dialects (dr-w15 S2 / D238) ─────
  #
  # 277 graph-coded rows on cloud-db-1: 500/HEALTH 132, 0/HEALTH 62, 503/HEALTH
  # 62, 500/BUILD 10, 403/HEALTH 8, 403/BUILD 3. Every BUILD row is
  # `astro-search-starter` and every HEALTH row is `search-starter`, because the
  # two templates fail DIFFERENTLY on the same read:
  #
  #   HEALTH — Next's `fetchCorpusGraph` DEGRADES and records the cause in the
  #   `bp-corpus-status` marker; `deploy/site-deploy-node.sh` `health_gate_node()` reads it back.
  #   BUILD  — Astro's `graphCorpus` THROWS (`src/lib/bp.ts:94`), so the same
  #   sentence arrives inside an ANSI-escaped Astro stack trace at exit 12.
  #
  # A HEALTH-only split leaves the whole astro/static fleet in BUILD_FAILED, so
  # both shapes are fixtures here and both are re-derived from their producers in
  # "both anchors are the PRODUCERS' own bytes" below.
  @g500_health "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — the SSR could not read a content document: graph 500: internal server error"
  @g503_health "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — the SSR could not read a content document: graph 503: service unavailable"
  # Status 0 is the fetch that never got an HTTP answer at all (`graph.ts:246`).
  @g0_health "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — the SSR could not read a content document: graph 0: fetch failed"
  # The API's own sentence, verbatim from `public_read.ex:134` — the eleven-row
  # visibility window of 2026-08-05 20:53-21:13.
  @g403_health "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — the SSR could not read a content document: graph 403: public-read tokens may only read published public documents"
  # Zero rows all-time (D244): the corpus read SUCCEEDED and had nothing to
  # anchor. Unnamed on purpose — it rises in UNCLASSIFIED (D8).
  @g200_health "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — the SSR could not read a content document: graph 200: corpus read OK but carried 0 node(s), none usable as a content anchor"
  # The astro arm, with the real 0x1B bytes exactly as captured from the build
  # PTY (same shape as @build_403 below, which is the LEGACY pre-shared-sentence
  # wording and must keep its own class).
  @g500_build "BUILD failed (exit 12): \e[31m\e[1m04:34:24\e[22m [ERROR] [build]\e[39m Caught error rendering /graph.json: Error: graph 500: internal server error"
  @g403_build "BUILD failed (exit 12): \e[31m\e[1m21:02:11\e[22m [ERROR] [build]\e[39m Caught error rendering /graph.json: Error: graph 403: public-read tokens may only read published public documents"
  # The em-dash BUILD prefix: 2 rows, which sat in UNCLASSIFIED because the arm
  # only read `BUILD failed (exit`.
  @g500_build_emdash "BUILD failed — \e[31m\e[1m04:34:24\e[22m [ERROR] [build]\e[39m Caught error rendering /graph.json: Error: graph 500: internal server error"
  @build_emdash "BUILD failed — the site build exited non-zero before any log was captured"
  # The RESIDUE, byte-shaped from `deploy/site-deploy-node.sh:494`: an empty
  # marker with no `bp-corpus-status` beside it. 3,617 rows, and structurally the
  # whole static-engine fleet from here on (D112).
  @doc_id_no_marker "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — the SSR rendered no content document (no bp-corpus-status marker: this build predates the corpus-status contract, so the upstream cause went unrecorded)"

  @unreachable "instance guerrilla is unreachable — the deploy could not be delivered; check instance health"
  @timeout "the build did not finish in time — the box is still working, or it stalled; deploy again to retry"
  @stale_lease "exceeded max deploy claim attempts (stale builder lease)"
  @died "deploy process died abnormally"
  @artifact_empty "artifact: artifact_url is empty (P6 bp deploy must populate it)"
  @gh_push "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy"
  # 2 rows: nixpacks. Genuinely unnamed — the honest tail.
  @nixpacks "nixpacks build: exit status 1"

  # ── The DEFERRED corpus (dr-w3 S3) ────────────────────────────────────────
  # What `Sites.Deploy.defer/3` actually writes: the box's own refusal, plus the
  # driver's promise clause appended after an em-dash separator.
  @requeued " — deferred: a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes"
  @d_busy @r409_coded <> @requeued
  @d_busy_bare @r409_bare <> @requeued
  # The concurrent-build CAP's refusal: a box that is not busy with THIS site at
  # all, refusing a slot so it stops swapping itself to death.
  @d_capacity "the instance refused the deploy (HTTP 409): box_at_capacity — 4 of 4 build slots are in use" <>
                @requeued
  # A deferral shape the ledger has never seen — not a box refusal at all.
  @d_novel "the boxcar shim deferred the handshake (code BLERG-7)" <> @requeued
  # …and the nearer miss: a real anchored 409, refusing with a code the ledger has
  # never named. This is the one an "absorb it into the busy bucket" tail would
  # silently eat, so the taxonomy would keep looking complete.
  @d_unknown_code "the instance refused the deploy (HTTP 409): slot_reservation_denied — the runner would not reserve a slot" <>
                    @requeued
  # The pre-dr-w3 lost publish that wore a `deferred` status while its own words
  # said the opposite.
  @d_requeue_broken @r409_bare <>
                      " — and the rebuild could NOT be re-queued; publish again to retry"

  # ── The STAMPED deferrals (dr-w4 S6) ──────────────────────────────────────
  # `Sites.Deploy.box_refusal/3` appends the box's own request id AFTER the
  # detail — `"#{base} [box request_id: #{rid}]"` — and `refusal_detail/1`
  # returns the BARE code when the envelope carries no message. So on a
  # code-only refusal the stamp lands INSIDE the first ` — ` segment, which is
  # exactly the segment the classifier reads the code out of.
  @rid " [box request_id: F9tPXq2A]"
  @d_capacity_stamped "the instance refused the deploy (HTTP 409): box_at_capacity" <>
                        @rid <> @requeued
  # The SHIPPING class, live since W1 — the same break, on the busy slug.
  @d_busy_stamped "the instance refused the deploy (HTTP 409): already_running" <>
                    @rid <> @requeued
  # …and the stamped shape that already worked, because the message pushed the
  # stamp past the ` — ` boundary. Pinned so the strip does not regress it.
  @d_capacity_msg_stamped "the instance refused the deploy (HTTP 409): box_at_capacity — 4 of 4 build slots are in use" <>
                            @rid <> @requeued

  # A CODELESS envelope — `%{"error" => %{"message" => "…"}}` with no `code` key
  # — whose PROSE merely begins with a code word. `refusal_detail/1` returns the
  # bare message, so nothing in the persisted string is a code at all; the box
  # never named one.
  @d_spoof_padded "the instance refused the deploy (HTTP 409): box_at_capacity  — the operator says the box is idle" <>
                    @requeued
  @d_spoof_prose "the instance refused the deploy (HTTP 409): box_at_capacity was blamed by the shim, wrongly" <>
                   @requeued

  # ── The ABANDONED corpus (dr-w9 S2) ───────────────────────────────────────
  # The LAST round of a bounded refusal chain does NOT defer — it settles the row
  # `failed`, and `Sites.Deploy.abandonment_reason/3` appends the driver's
  # admission that it has stopped retrying this publish. These are the most
  # severe rows the fleet produces: a publish that never happened and never will.
  #
  # Four such rows exist in production as of 2026-08-07 and every one of them
  # classified as `BOX_BUSY_409`, label "the box was already deploying (HTTP
  # 409)" — affirmatively FALSE for the three capacity rows, where the box was
  # not deploying this site at all and had no free slot.
  #
  # Written as LITERALS (the bytes a prod row carries) and re-derived from the
  # real producer in "the producer's own sentence is what the classifier
  # anchors on" below, so a reword there reds instead of degrading silently.
  @abandon_cap " — and it has now refused 12 rebuilds in a row for this site, so the instance has been at its concurrent-build cap for that entire run; check for builds holding slots without finishing, or raise the cap"
  @abandon_busy " — and it has now refused 6 rebuilds in a row for this site, so the instance is not busy but stuck; check its deploy runner"

  # 2026-08-07 01:20:14Z, 01:37:41Z, 02:33:55Z — three 12-cap abandonments, all
  # `box_at_capacity`, in the three refusal shapes the box actually sends: code
  # only, code + request-id stamp, code + message.
  @a_capacity "the instance refused the deploy (HTTP 409): box_at_capacity" <> @abandon_cap
  @a_capacity_stamped "the instance refused the deploy (HTTP 409): box_at_capacity" <>
                        @rid <> @abandon_cap
  @a_capacity_msg "the instance refused the deploy (HTTP 409): box_at_capacity — 4 of 4 build slots are in use" <>
                    @abandon_cap
  # 2026-08-05 22:57:53Z — the one 6-cap abandonment, the busy slug.
  @a_busy "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight" <>
            @abandon_busy
  # D7's codeless 409 predates the concurrent-build cap entirely, so an
  # abandonment carrying no code can only be the busy slug.
  @a_bare @r409_bare <> @abandon_busy
  # A terminal 409 refusing with a code the ledger has never named: it must NOT
  # be absorbed by whichever abandonment bucket it most resembles (D8).
  @a_unknown_code "the instance refused the deploy (HTTP 409): slot_reservation_denied — the runner would not reserve a slot" <>
                    @abandon_busy
  # The OTHER terminal 409 `defer/3` writes — a prebuilt deploy, which is never
  # deferred because its bytes cannot be rebuilt. It is not an abandoned chain,
  # and must keep the ordinary name.
  @prebuilt_terminal @r409_coded <> " — re-run the upload once the in-flight deploy finishes"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Deployments are inserted as STRUCTS on purpose: `Deployment.changeset/2`
  # forbids casting `status` (transition_changeset is the sole status mutator)
  # and the census needs rows pinned to an exact `inserted_at`.
  defp deployment!(site, attrs) do
    # `timestamps(type: :utc_datetime_usec)` — a `~U[…Z]` sigil is second
    # precision and Ecto refuses it, so every pinned instant is widened here.
    now = attrs |> Map.get(:inserted_at, DateTime.utc_now()) |> usec()

    Repo.insert!(
      struct(
        %Deployment{
          site_id: site.id,
          status: "failed",
          environment: "production",
          inserted_at: now,
          updated_at: now
        },
        Map.drop(attrs, [:inserted_at])
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      )
    )
  end

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
  defp maybe_usec(nil), do: nil
  defp maybe_usec(%DateTime{} = dt), do: usec(dt)

  # BULK rows for the delivery fixtures. The estimator refuses below
  # `min_sample` 200, so its fixtures are 1,000 rows — and 1,000 `Repo.insert!`
  # round-trips would be seconds of test time for no extra truth.
  defp deployments!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(r.inserted_at)

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.get(r, :status, "failed"),
          environment: Map.get(r, :environment, "production"),
          content_rev: Map.get(r, :content_rev),
          became_live_at: r |> Map.get(:became_live_at) |> maybe_usec(),
          inserted_at: at,
          updated_at: at
        }
      end)

    Repo.insert_all(Deployment, entries)
  end

  # ── The delivery fixtures ────────────────────────────────────────────────
  #
  # `@dw_as_of` is PINNED like the window is: a still-waiting lower bound is
  # `as_of - inserted_at`, so a floating clock would make the same fixture
  # answer differently on every run — the exact defect the epic found live (the
  # same pinned window returned stranded 3 → 2 → 0 in five minutes).
  @dw_from ~U[2026-08-01 00:00:00Z]
  @dw_to ~U[2026-08-02 00:00:00Z]
  @dw_as_of ~U[2026-08-02 00:00:00Z]

  # 600 DELIVERED rows (waits 30-90s, all inside the window's first 700s) and
  # 400 STILL WAITING rows inserted 10,000s later — after the last live mark, so
  # nothing can resolve them. 40.0% censored: the shape the live corpus shows at
  # EVERY window width, which is why narrowing the window is not the fix.
  defp delivery_40pct!(site) do
    delivered =
      for i <- 1..600 do
        at = DateTime.add(@dw_from, i, :second)

        %{
          status: "live",
          inserted_at: at,
          became_live_at: DateTime.add(at, delivered_wait(i), :second)
        }
      end

    waiting =
      for i <- 1..400 do
        %{status: "failed", inserted_at: DateTime.add(@dw_from, 10_000 + i, :second)}
      end

    deployments!(site, delivered ++ waiting)
  end

  defp delivered_wait(i), do: 30 + rem(i, 61)

  # The seconds the fixture ABOVE puts in front of the estimator, rebuilt here so
  # a test can compute the floored and the DROPPED answer from the same numbers
  # the ledger sees.
  defp delivery_40pct_seconds do
    delivered = Enum.sort(for i <- 1..600, do: delivered_wait(i) * 1.0)
    # as_of - (from + 10_000 + i) for i in 1..400 → 76,399 down to 76,000.
    waiting = Enum.sort(for i <- 1..400, do: (86_400 - 10_000 - i) * 1.0)
    {delivered, waiting}
  end

  # The MUTANT: the estimator this slice exists to refuse — it drops the
  # still-waiting rows and reports a confident number off what is left.
  defp drop_quantile(delivered_sorted, q) do
    n = length(delivered_sorted)
    Enum.at(delivered_sorted, min(n, max(trunc(Float.ceil(n * q)), 1)) - 1)
  end

  defp floor_quantile(all_sorted, q) do
    n = length(all_sorted)
    Enum.at(all_sorted, min(n, max(trunc(Float.ceil(n * q)), 1)) - 1)
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## ── 1. The taxonomy ──────────────────────────────────────────────────────

  describe "classify/2 — the named taxonomy over (stage, RAW failure_reason)" do
    test "BOX_BUSY_409 keys on HTTP 409, NEVER on already_running" do
      # The whole point: both shapes are one class. 43% of the largest class
      # carries no code word at all.
      assert DeployLedger.classify("PLAN", @r409_coded) == "BOX_BUSY_409"
      assert DeployLedger.classify("PLAN", @r409_bare) == "BOX_BUSY_409"
      refute String.contains?(@r409_bare, "already_running")
    end

    # dr-w9 S2. GIVING UP ON A PUBLISH WORE THE MILDEST NAME IN THE TAXONOMY.
    # All four real cap-terminal prod rows classified as BOX_BUSY_409 — "the box
    # was already deploying (HTTP 409)" — which for the three capacity rows is
    # not merely vague but false, and sends an operator to the wrong place.
    test "a chain-terminal 409 is an ABANDONED publish, split by the box's own code word" do
      # The three 12-cap rows, in all three shapes the box sends them.
      assert DeployLedger.classify("PLAN", @a_capacity) == "ABANDONED_AT_CAPACITY"
      assert DeployLedger.classify("PLAN", @a_capacity_stamped) == "ABANDONED_AT_CAPACITY"
      assert DeployLedger.classify("PLAN", @a_capacity_msg) == "ABANDONED_AT_CAPACITY"

      # The one 6-cap row: the box is not busy, it is stuck.
      assert DeployLedger.classify("PLAN", @a_busy) == "ABANDONED_BOX_STUCK"

      # …and through the row-shaped arm the census actually folds over.
      assert DeployLedger.classify(%{
               status: "failed",
               stage: "PLAN",
               failure_reason: @a_capacity_stamped
             }) == "ABANDONED_AT_CAPACITY"

      assert DeployLedger.classify(%{status: "failed", stage: "PLAN", failure_reason: @a_busy}) ==
               "ABANDONED_BOX_STUCK"

      # Never the mild name, in any shape.
      for reason <- [@a_capacity, @a_capacity_stamped, @a_capacity_msg, @a_busy] do
        refute DeployLedger.classify("PLAN", reason) == "BOX_BUSY_409"
      end

      # D7's codeless 409 predates the cap, so an abandonment with no code is the
      # busy slug — read exactly as the deferred arm reads it.
      assert DeployLedger.classify("PLAN", @a_bare) == "ABANDONED_BOX_STUCK"

      # …and D8 holds on this arm too: a terminal 409 whose code the ledger has
      # never named rises in the tail rather than joining the nearer bucket —
      # but it rises INSIDE the abandoned cohort (dr-w28-s4). It answered
      # "UNCLASSIFIED" until then, which made the ABANDONED COUNT FALL the day
      # the box learned a new code word. See "the D8 INVERSION" below.
      assert DeployLedger.classify("PLAN", @a_unknown_code) == "ABANDONED_UNCLASSIFIED"
    end

    test "an ordinary 409 is untouched by the split — only a chain-terminal one promotes" do
      # The two shapes that are 100% of the live 409 mass.
      assert DeployLedger.classify("PLAN", @r409_coded) == "BOX_BUSY_409"
      assert DeployLedger.classify("PLAN", @r409_bare) == "BOX_BUSY_409"

      # A DEFERRED round of the very chain that later abandons is still a
      # deferral, and still not a failure.
      assert DeployLedger.classify("PLAN", @d_capacity_stamped) == "BOX_BUSY_409"

      assert DeployLedger.classify(%{
               status: "deferred",
               stage: "PLAN",
               failure_reason: @d_capacity_stamped
             }) == "BOX_AT_CAPACITY_DEFERRED"

      # The other terminal 409 `defer/3` writes — the prebuilt refusal — is not
      # an abandoned chain and keeps the ordinary name.
      assert DeployLedger.classify("PLAN", @prebuilt_terminal) == "BOX_BUSY_409"
      # It really does carry a terminal clause, so this is not a fixture that
      # quietly dropped the thing under test.
      assert String.contains?(@prebuilt_terminal, "re-run the upload")
    end

    test "both ABANDONED classes are named, labelled, and counted as failures" do
      for class <- ["ABANDONED_AT_CAPACITY", "ABANDONED_BOX_STUCK"] do
        assert class in DeployLedger.classes()
        # A label the taxonomy did not write is `label/1`'s own fallback: the
        # class name. A class registered without one would pass unnoticed.
        refute DeployLedger.label(class) == class
        assert DeployLedger.label(class) =~ "given up on"
        # They ARE failures: attempted, terminal, in the numerator.
        refute DeployLedger.deferred?(class)
        refute DeployLedger.not_attempted?(class)
      end

      # The two names say different things — a split that collapses in the UI is
      # not a split.
      refute DeployLedger.label("ABANDONED_AT_CAPACITY") ==
               DeployLedger.label("ABANDONED_BOX_STUCK")
    end

    # THE GUARD THAT CAN LOSE. The classifier anchors on PROSE written in
    # `Sites.Deploy` — reword that sentence and every abandoned row silently
    # degrades back to BOX_BUSY_409 with nothing failing anywhere, which is this
    # epic's own disease. So the fixtures above are re-derived from the REAL
    # producer here: an edit to the sentence reds at edit time.
    test "the producer's own sentence is what the classifier anchors on" do
      cap =
        Deploy.abandonment_reason(
          "the instance refused the deploy (HTTP 409): box_at_capacity",
          12,
          "BOX_AT_CAPACITY_DEFERRED"
        )

      busy =
        Deploy.abandonment_reason(
          "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight",
          6,
          "BOX_BUSY_DEFERRED"
        )

      # Byte-identical to the pinned prod rows…
      assert cap == @a_capacity
      assert busy == @a_busy

      # …and classified from the producer's own output, not only from a literal.
      assert DeployLedger.classify("PLAN", cap) == "ABANDONED_AT_CAPACITY"
      assert DeployLedger.classify("PLAN", busy) == "ABANDONED_BOX_STUCK"

      # The chain bound really is what the producer counts to, so a bound change
      # cannot quietly stop producing abandoned rows in the shape pinned here.
      assert cap =~ "refused 12 rebuilds in a row"
      assert busy =~ "refused 6 rebuilds in a row"
    end

    test "the box-refusal statuses each get their own name; an unnamed one does not" do
      assert DeployLedger.classify("BUILD", @r500) == "BOX_500"
      assert DeployLedger.classify("HEALTH", @r500) == "BOX_500"
      # WAS `BOX_UNAVAILABLE_503`, and that assertion is what pinned the lie: the
      # box that sent this was UP — it named the code word `feature_not_configured`
      # in the same breath. The 503 now reads that word (see the 503 describe
      # below), so a code-carrying 503 gets the cause's name, not the status'.
      assert DeployLedger.classify("PLAN", @r503) == "BOX_DEPLOY_DISABLED_503"
      assert DeployLedger.classify("BUILD", @r429) == "BOX_RATE_LIMITED_429"
      # An unnamed refusal status is UNCLASSIFIED, not a catch-all BOX_REFUSED.
      assert DeployLedger.classify("PLAN", @r404) == "UNCLASSIFIED"
    end

    test "the refusal prefix is ANCHORED — a build log that merely prints 500 is not a box 500" do
      log = "BUILD failed (exit 12): request to /api returned 500 after 3 retries"
      assert DeployLedger.classify("BUILD", log) == "BUILD_FAILED"

      # …and the same string with the refusal prefix in the MIDDLE is not a
      # refusal either: only the producer's own template at position 0 counts.
      quoted = "BUILD failed (exit 12): the instance refused the deploy (HTTP 409)"
      assert DeployLedger.classify("BUILD", quoted) == "BUILD_FAILED"
    end

    test "DOC_ID_EMPTY needs the HEALTH stage — the same text elsewhere stays UNCLASSIFIED" do
      assert DeployLedger.classify("HEALTH", @doc_id) == "DOC_ID_EMPTY"
      assert DeployLedger.classify("HEALTH", @doc_id_alt) == "DOC_ID_EMPTY"
      assert DeployLedger.classify("HEALTH", @health_slot) == "HEALTH_GATE_FAILED"

      # Every one of the 3,584 doc-id rows is HEALTH. If that stops being true,
      # the ledger says UNCLASSIFIED rather than quietly widening the class.
      assert DeployLedger.classify("BUILD", @doc_id) == "UNCLASSIFIED"
    end

    test "a BUILD failure splits on what the build could not READ" do
      assert DeployLedger.classify("BUILD", @build_403) == "FORBIDDEN_403"
      assert DeployLedger.classify("BUILD", @build_plain) == "BUILD_FAILED"
    end

    test "the long tail is named too" do
      assert DeployLedger.classify("PLAN", @unreachable) == "BOX_UNREACHABLE"
      assert DeployLedger.classify("HEALTH", @timeout) == "DEPLOY_TIMEOUT"
      assert DeployLedger.classify("BUILD", @stale_lease) == "STALE_LEASE"
      assert DeployLedger.classify("RETIRE", @died) == "PROCESS_DIED"
      assert DeployLedger.classify(nil, @artifact_empty) == "SOURCE_UNFETCHABLE"
      assert DeployLedger.classify(nil, @gh_push) == "GITHUB_PUSH_UNBUILDABLE"
    end

    test "UNCLASSIFIED CAN GO UP: an unrecognised reason is NOT absorbed by the nearest bucket" do
      novel = "the boxcar shim refused the handshake (code BLERG-7)"
      assert DeployLedger.classify("PLAN", novel) == "UNCLASSIFIED"
      assert DeployLedger.classify("BUILD", @nixpacks) == "UNCLASSIFIED"
      assert DeployLedger.classify("STAGE", nil) == "UNCLASSIFIED"

      # And it is not merely "not the biggest class" — it is the sentinel name,
      # so a taxonomy that stops covering the corpus SAYS SO.
      assert "UNCLASSIFIED" in DeployLedger.classes()
    end

    test "classify/1 over a row is nil for anything that did not fail" do
      assert DeployLedger.classify(%{status: "live", stage: "SWITCH", failure_reason: nil}) == nil

      assert DeployLedger.classify(%{status: "failed", stage: "PLAN", failure_reason: @r409_bare}) ==
               "BOX_BUSY_409"
    end

    # dr-w3 S3. This clause used to be `def classify(%{status: "deferred"}), do:
    # "BOX_BUSY_DEFERRED"` — status alone, reason never read. A probe asserting
    # that FOUR distinct causes all answered BOX_BUSY_DEFERRED PASSED, and the
    # label it stamped on a CAPACITY refusal ("the box was busy") was simply
    # false: a box at its build cap is not busy with this site at all.
    test "a DEFERRAL is classified by its REASON, not by its status alone" do
      deferred = fn reason ->
        DeployLedger.classify(%{status: "deferred", stage: "PLAN", failure_reason: reason})
      end

      # The busy slug — including D7's bare 409, which carries no code word and
      # predates the cap entirely, so it can only be `already_running`.
      assert deferred.(@d_busy) == "BOX_BUSY_DEFERRED"
      assert deferred.(@d_busy_bare) == "BOX_BUSY_DEFERRED"

      # The concurrent-build cap: its OWN class, because it is its own cause and
      # its own operator action.
      assert deferred.(@d_capacity) == "BOX_AT_CAPACITY_DEFERRED"

      # …and the three shapes that are not a named deferral: a refusal that is
      # not the box's, a 409 whose CODE the ledger has never seen, and nothing.
      assert deferred.(@d_novel) == "DEFERRED_UNCLASSIFIED"
      assert deferred.(@d_unknown_code) == "DEFERRED_UNCLASSIFIED"
      assert deferred.(nil) == "DEFERRED_UNCLASSIFIED"

      # A row whose re-queue BROKE is a lost publish, so it must not answer with
      # a class whose label promises "re-queued, not lost". (dr-w3 S3 settles
      # these `failed` at the source; this arm covers the rows already written.)
      assert deferred.(@d_requeue_broken) == "DEFERRED_UNCLASSIFIED"

      # And the labels are three DISTINCT sentences, not one lie reused.
      labels = Enum.map(DeployLedger.deferred_classes(), &DeployLedger.label/1)
      assert length(Enum.uniq(labels)) == 3
      assert DeployLedger.label("BOX_AT_CAPACITY_DEFERRED") =~ "cap"
    end

    # dr-w4 S6. The request-id stamp ATE THE CODE. `box_refusal/3` appends
    # " [box request_id: X]" after the detail and `refusal_detail/1` returns the
    # bare code when the envelope has no message, so the first ` — ` segment of
    # the persisted reason was `box_at_capacity [box request_id: F9tPXq2A]` and
    # the `==` comparison could not match. This is NOT only the unbuilt capacity
    # class: the identical break hits `already_running`, shipping since W1, and
    # by D43's logic a DEFERRED_UNCLASSIFIED row falls back to the generic chain
    # bound and produces the false accusation "refusing this site persistently
    # for a cause the ledger cannot name" — against a runner working as designed.
    test "the request-id stamp does not eat the deferral code" do
      deferred = fn reason ->
        DeployLedger.classify(%{status: "deferred", stage: "PLAN", failure_reason: reason})
      end

      # Code, no message, WITH the stamp — the broken shape, both classes.
      assert deferred.(@d_capacity_stamped) == "BOX_AT_CAPACITY_DEFERRED"
      assert deferred.(@d_busy_stamped) == "BOX_BUSY_DEFERRED"

      # Code AND message and stamp: already worked, because the message pushed
      # the stamp past the ` — ` boundary. It must keep working.
      assert deferred.(@d_capacity_msg_stamped) == "BOX_AT_CAPACITY_DEFERRED"

      # The stamp really is in the persisted string — this is not a fixture that
      # quietly dropped the thing under test.
      assert String.contains?(@d_capacity_stamped, "[box request_id: F9tPXq2A]")
      assert String.contains?(@d_busy_stamped, "[box request_id: F9tPXq2A]")

      # A stamp does not INVENT a code either: an unnamed code stays unnamed.
      stamped_unknown =
        "the instance refused the deploy (HTTP 409): slot_reservation_denied" <>
          @rid <> @requeued

      assert deferred.(stamped_unknown) == "DEFERRED_UNCLASSIFIED"
    end

    # dr-w4 S6, the opposite direction: the classifier read the first ` — `
    # segment of whatever PROSE the box sent and treated it as a code. A codeless
    # envelope whose message merely begins with a code word was therefore
    # promoted to a capacity refusal with no code involved anywhere.
    #
    # The close stays on the RAW column (moduledoc): a code must LOOK like a code
    # — a bare snake_case token, exactly as `refusal_detail/1` emits one — and
    # prose that does not is prose, which is NOT the same thing as "the box named
    # no code". D7's codeless 409 still means the busy slug; unreadable prose
    # rises in the tail instead of collapsing into it.
    test "prose that merely BEGINS with a code word is not read as a code" do
      deferred = fn reason ->
        DeployLedger.classify(%{status: "deferred", stage: "PLAN", failure_reason: reason})
      end

      # `String.trim/1` on the split segment made padded prose byte-equal to the
      # code the producer template can never emit padded.
      assert deferred.(@d_spoof_padded) == "DEFERRED_UNCLASSIFIED"
      assert deferred.(@d_spoof_prose) == "DEFERRED_UNCLASSIFIED"

      # …and it must NOT fall the other way either: unreadable prose is not a
      # codeless 409, so it must not be absorbed by the busy bucket that D7's
      # bare-409 fallback fills.
      refute deferred.(@d_spoof_padded) == "BOX_BUSY_DEFERRED"
      refute deferred.(@d_spoof_prose) == "BOX_BUSY_DEFERRED"

      # The genuine codeless 409 — no detail at all after the status — is still
      # the busy slug (D7's 43%).
      assert deferred.(@d_busy_bare) == "BOX_BUSY_DEFERRED"
    end

    # The DEFERRED-SIDE MIRROR of "UNCLASSIFIED CAN GO UP" (D8) — which did not
    # exist: D8 was honoured for failed rows and violated for deferred ones,
    # because the deferred arm had exactly one answer and could not be wrong.
    #
    # The sentinel is DEFERRED_UNCLASSIFIED and NOT UNCLASSIFIED, deliberately:
    # UNCLASSIFIED lives in `classes/0`, and those rows ARE the failure
    # numerator. Routing a healthy capacity refusal there would inflate the
    # deploy-failure rate with the fleet working as designed — vacuous RED.
    test "DEFERRED_UNCLASSIFIED CAN GO UP: an unnamed deferral is not absorbed, and is NOT a failure" do
      row = %{status: "deferred", stage: "PLAN", failure_reason: @d_novel}
      assert DeployLedger.classify(row) == "DEFERRED_UNCLASSIFIED"

      # The NEAR miss matters more than the far one: a genuine 409 refusing with
      # a code nobody has named must rise in the tail, not be absorbed by the
      # busy bucket it most resembles.
      near = %{status: "deferred", stage: "PLAN", failure_reason: @d_unknown_code}
      assert DeployLedger.classify(near) == "DEFERRED_UNCLASSIFIED"

      # It is the sentinel name, in the deferred cohort…
      assert "DEFERRED_UNCLASSIFIED" in DeployLedger.deferred_classes()
      assert DeployLedger.deferred?("DEFERRED_UNCLASSIFIED")
      assert DeployLedger.deferred?("BOX_AT_CAPACITY_DEFERRED")

      # …and NOT in the failure taxonomy, under any of its names.
      refute "DEFERRED_UNCLASSIFIED" in DeployLedger.classes()
      refute "BOX_AT_CAPACITY_DEFERRED" in DeployLedger.classes()
      refute "BOX_BUSY_DEFERRED" in DeployLedger.classes()
      refute DeployLedger.not_attempted?("DEFERRED_UNCLASSIFIED")
    end

    test "GITHUB_PUSH_UNBUILDABLE is not in the ordinary taxonomy at all" do
      refute "GITHUB_PUSH_UNBUILDABLE" in DeployLedger.classes()
      assert DeployLedger.not_attempted?("GITHUB_PUSH_UNBUILDABLE")
      refute DeployLedger.not_attempted?("BOX_BUSY_409")
    end
  end

  ## ── 1a2. The content API's own status, in BOTH dialects (D238) ────────────
  #
  # `classify/2`'s HEALTH arm matched "bp-doc-id marker is empty" FIRST and
  # answered DOC_ID_EMPTY, throwing away the upstream status sitting in the same
  # string — the status the producer had already gone to the trouble of reading
  # back out of the SSR's `bp-corpus-status` marker. The number-one failure class
  # on the fleet was therefore both silent (nobody could see the cause) and
  # mis-reported (the row named a symptom).
  #
  # And the BUILD arm was the same defect wearing a different template: astro's
  # `graphCorpus` THROWS the identical `graph <status>: <message>` sentence, so
  # thirteen rows carrying a fully-readable content-API cause wore BUILD_FAILED,
  # "the site build exited non-zero" — which blames the site owner for an
  # instance-side condition.

  # THE STATUS SET IS DECLARED, NOT SCRAPED (D244). The honest scrape target,
  # `templates/search-starter/lib/markers.corpus-status.test.ts`, yields exactly
  # graph 0/200/401/403/500 — it MISSES 503, which is 62 live rows and the
  # second-largest status. Both producers interpolate a pass-through
  # `res.status` (`graph.ts:92`, `bp.ts:94`), so the vocabulary is UNBOUNDED and
  # a scrape cannot fail closed the way the snake_case producer scrape does.
  #
  # {status, live rows, class} — counts re-measured on cloud-db-1 2026-08-07
  # across BOTH arms. They are pinned so a re-measurement is a diff, not a
  # rewrite, and so `@graph_population` below cannot drift away from them.
  @graph_statuses [
    {"500", 142, "CONTENT_API_500"},
    {"503", 62, "CONTENT_API_503"},
    {"0", 62, "CONTENT_API_UNREACHABLE"},
    {"403", 11, "CONTENT_API_403"},
    # Zero rows all-time: the read succeeded and had nothing to anchor. Unnamed
    # on purpose (D8) — it must RISE rather than be named on speculation.
    {"200", 0, "UNCLASSIFIED"}
  ]

  # The per-arm split, which is what makes a HEALTH-only fix visibly incomplete.
  @graph_population %{
    {"500", "HEALTH"} => 132,
    {"0", "HEALTH"} => 62,
    {"503", "HEALTH"} => 62,
    {"500", "BUILD"} => 10,
    {"403", "HEALTH"} => 8,
    {"403", "BUILD"} => 3
  }

  # Read at runtime so a producer reflow reds HERE instead of silently degrading
  # every row back to DOC_ID_EMPTY / BUILD_FAILED.
  @health_producer "../deploy/site-deploy-node.sh"
  @build_producer "../templates/astro-search-starter/src/lib/bp.ts"
  @scrape_target "../templates/search-starter/lib/markers.corpus-status.test.ts"

  describe "classify/2 — the content API's own status stops being thrown away" do
    test "BOTH arms split on the row's own graph code" do
      # HEALTH — the Next template's degraded render, exit 14.
      assert DeployLedger.classify("HEALTH", @g500_health) == "CONTENT_API_500"
      assert DeployLedger.classify("HEALTH", @g503_health) == "CONTENT_API_503"
      assert DeployLedger.classify("HEALTH", @g0_health) == "CONTENT_API_UNREACHABLE"
      assert DeployLedger.classify("HEALTH", @g403_health) == "CONTENT_API_403"

      # BUILD — the astro template's throw, ANSI escapes and all. These are the
      # thirteen rows a HEALTH-only split would have left in BUILD_FAILED.
      assert DeployLedger.classify("BUILD", @g500_build) == "CONTENT_API_500"
      assert DeployLedger.classify("BUILD", @g403_build) == "CONTENT_API_403"

      # The escapes really are in the fixture — this is not a sanitised string
      # that quietly dropped the thing under test.
      assert String.contains?(@g500_build, "\e[31m")

      # …and through the arm the census actually folds over.
      assert DeployLedger.classify(%{
               status: "failed",
               stage: "BUILD",
               failure_reason: @g403_build
             }) == "CONTENT_API_403"
    end

    test "the declared status set is COMPLETE over the live population, and the scrape is not" do
      # Every declared status classifies to its declared class, in whichever arm
      # can produce it — the declaration and the classifier cannot drift apart.
      for {status, _count, class} <- @graph_statuses do
        assert DeployLedger.classify("HEALTH", health_graph_line(status)) == class
        assert DeployLedger.classify("BUILD", build_graph_line(status)) == class
      end

      # The counts add up to the measured population, per arm and in total.
      assert Enum.sum(Map.values(@graph_population)) == 277

      for {status, count, _class} <- @graph_statuses do
        arms =
          @graph_population
          |> Enum.filter(fn {{s, _stage}, _n} -> s == status end)
          |> Enum.map(fn {_k, n} -> n end)
          |> Enum.sum()

        assert arms == count, "#{status}: per-arm rows #{arms} but declared #{count}"
      end

      # WHY DECLARED AND NOT SCRAPED: the scrape target omits 503 outright — 62
      # live rows, the second-largest status. If this stops being true the
      # declaration can be revisited; until then a scrape would fail OPEN.
      scraped =
        @scrape_target
        |> File.read!()
        |> then(&Regex.scan(~r/graph (\d+)/, &1))
        |> Enum.map(fn [_, s] -> s end)
        |> MapSet.new()

      refute "503" in scraped
      assert "403" in scraped
      # …and it also carries a status the ledger does not name, which is exactly
      # why the unnamed arm must rise rather than absorb.
      assert "401" in scraped
      assert DeployLedger.classify("HEALTH", health_graph_line("401")) == "UNCLASSIFIED"
    end

    test "both anchors are the PRODUCERS' own bytes, read from the producers" do
      # `deploy/site-deploy-node.sh` `health_gate_node()` writes the HEALTH sentence. Reword it and
      # this reds instead of every HEALTH row silently degrading.
      health = File.read!(@health_producer)

      assert health =~
               "bp-doc-id marker is empty — the SSR could not read a content document: $got_corpus"

      # `templates/astro-search-starter/src/lib/bp.ts:94` throws the BUILD one.
      build = File.read!(@build_producer)
      assert build =~ "throw new Error(`graph ${res.status}: ${upstreamMessage(body, res)}`)"

      # And the fixtures really are built on those shapes.
      assert @g500_health =~ "could not read a content document: graph 500:"
      assert @g500_build =~ "Error: graph 500:"
    end

    test "an unnamed graph status RISES (D8) — it is not absorbed by the nearest class" do
      assert DeployLedger.classify("HEALTH", @g200_health) == "UNCLASSIFIED"
      assert DeployLedger.classify("HEALTH", health_graph_line("418")) == "UNCLASSIFIED"
      assert DeployLedger.classify("BUILD", build_graph_line("418")) == "UNCLASSIFIED"
      # Not DOC_ID_EMPTY: the cause WAS recorded, the ledger simply has no name
      # for it, and those are different facts (D112).
      refute DeployLedger.classify("HEALTH", @g200_health) == "DOC_ID_EMPTY"
    end

    test "the split PARTITIONS DOC_ID_EMPTY — the coded rows LEAVE it" do
      # A coded row is no longer in the class at all…
      refute DeployLedger.classify("HEALTH", @g500_health) == "DOC_ID_EMPTY"

      # …and what stays is exactly the rows that recorded no cause: the fleet
      # that runs `deploy/site-deploy.sh`, which has ZERO bp-corpus-status
      # readers. 3,617 "the SSR rendered no content document" rows and 3 "the
      # build rendered no content document" rows, with no residue.
      assert DeployLedger.classify("HEALTH", @doc_id) == "DOC_ID_EMPTY"
      assert DeployLedger.classify("HEALTH", @doc_id_alt) == "DOC_ID_EMPTY"

      assert DeployLedger.classify("HEALTH", @doc_id_no_marker) == "DOC_ID_EMPTY"
      assert File.read!(@health_producer) =~ "no bp-corpus-status marker: this build predates"
      refute File.read!("../deploy/site-deploy.sh") =~ "bp-corpus-status"

      # D112: the LABEL says what the class now means. "the marker was empty" is
      # true of every class in this family; "and the cause went unrecorded" is
      # true only of what is left.
      assert DeployLedger.label("DOC_ID_EMPTY") =~ "unrecorded"

      # PARTITION, not an addition beside it (D43/D241): every new name is in
      # `@classes`, which IS the failure numerator, so the rows moved rather than
      # being counted twice.
      for {_status, _count, class} <- @graph_statuses do
        assert class in DeployLedger.classes()
        refute DeployLedger.deferred?(class)
        refute DeployLedger.not_attempted?(class)
      end
    end

    test "FORBIDDEN_403 is untouched — @corpus_403's 1,095 rows do not move (D239)" do
      # The LEGACY astro wording (`graph corpus fetch failed: 403`) is what
      # `@corpus_403` matches, and it keeps its class. The new anchor requires
      # digits immediately after `graph `, so the two shapes cannot collide.
      assert DeployLedger.classify("BUILD", @build_403) == "FORBIDDEN_403"
      assert @build_403 =~ "fetch failed: 403"
      refute @build_403 =~ ~r/graph \d+:/
      assert DeployLedger.classify("BUILD", @build_plain) == "BUILD_FAILED"

      # …and the two 403 classes are DIFFERENT names with different owners: one
      # is a site's own read token, one is a fleet-wide API-side condition.
      refute DeployLedger.classify("BUILD", @g403_build) ==
               DeployLedger.classify("BUILD", @build_403)

      assert DeployLedger.agency("FORBIDDEN_403") == :site
      assert DeployLedger.agency("CONTENT_API_403") == :ambiguous
    end

    test "the graph code is ANCHORED — a build log that merely prints one is not one" do
      # The HEALTH phrase belongs to one producer branch. A row that quotes those
      # bytes at another stage is a shape this ledger has never seen.
      assert DeployLedger.classify("BUILD", @g500_health) == "UNCLASSIFIED"
      assert DeployLedger.classify("PLAN", @g500_health) == "UNCLASSIFIED"

      # A BUILD capture that prints `graph 500` WITHOUT the thrown-Error prefix
      # is a log line, not a corpus failure.
      printed = "BUILD failed (exit 12): fetched graph 500 nodes in 1.2s, then OOMed"
      assert DeployLedger.classify("BUILD", printed) == "BUILD_FAILED"

      # And the BUILD anchor only fires inside a capture the driver declared
      # failed — the same discipline every other rule here has.
      assert DeployLedger.classify("BUILD", "Error: graph 500: internal server error") ==
               "UNCLASSIFIED"
    end

    # ZERO-POPULATION TRIPWIRE (D251). `build_class/1` was reached only through
    # `String.starts_with?(reason, "BUILD failed (exit")`, so the two live
    # `BUILD failed — …` rows never reached it and sat in the tail with a
    # readable cause in the string.
    test "the em-dash BUILD prefix reaches build_class too" do
      assert DeployLedger.classify("BUILD", @build_emdash) == "BUILD_FAILED"
      assert DeployLedger.classify("BUILD", @g500_build_emdash) == "CONTENT_API_500"
      # The fixture really is the em-dash shape and not the paren one.
      refute @build_emdash =~ "BUILD failed (exit"
      assert @build_emdash =~ "BUILD failed — "

      # Still anchored: only at position 0, and only at BUILD.
      assert DeployLedger.classify("HEALTH", @build_emdash) == "UNCLASSIFIED"

      assert DeployLedger.classify("BUILD", "a log line quoting BUILD failed — nope") ==
               "UNCLASSIFIED"
    end
  end

  # The producer sentences, parameterised, so a declared status can be driven
  # through BOTH arms without a fixture per status.
  defp health_graph_line(status) do
    "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty — " <>
      "the SSR could not read a content document: graph #{status}: upstream said so"
  end

  defp build_graph_line(status) do
    "BUILD failed (exit 12): \e[31m\e[1m04:34:24\e[22m [ERROR] [build]\e[39m " <>
      "Caught error rendering /graph.json: Error: graph #{status}: upstream said so"
  end

  ## ── 1a3. The agency map (D148/D242) ──────────────────────────────────────
  #
  # `@agency` exists nowhere on origin/main; it is minted here, in the same
  # commit as the four classes above, because a class that lands without an
  # agency key is exactly how an 18-class taxonomy and a 17-key map merged past
  # each other with a green suite.

  describe "agency/1 — who a class accuses, and the map that cannot go stale" do
    # THE ASSERTION IS KEYED OFF THE ENUM, NEVER A HAND-LIST. A hand-listed set
    # is a second place to forget: add a class upstream, forget the key here, and
    # the suite stays green while `agency/1` silently answers `:ambiguous` for a
    # class somebody meant to be `:box`.
    test "the map is EXHAUSTIVE over classes/0 ++ not_attempted_classes/0" do
      for class <- DeployLedger.classes() ++ DeployLedger.not_attempted_classes() do
        assert Map.has_key?(DeployLedger.agency_map(), class),
               "#{class} has no agency — the map is not exhaustive"

        assert DeployLedger.agency(class) in [:box, :site, :ambiguous]
      end

      # …and nothing EXTRA: a key for a class that no longer exists is a stale
      # opinion the enum cannot correct.
      known = MapSet.new(DeployLedger.classes() ++ DeployLedger.not_attempted_classes())

      for class <- Map.keys(DeployLedger.agency_map()) do
        assert MapSet.member?(known, class), "#{class} has an agency but is not a class"
      end

      # The gauge must be able to lose: if the enum were empty the loop above
      # would assert nothing at all.
      assert length(DeployLedger.classes()) >= 18
    end

    test "an unknown class is :ambiguous, NEVER :site" do
      # Failing to `:site` would shrink a box numerator — the comforting
      # direction, and therefore the forbidden one (D148).
      assert DeployLedger.agency("A_CLASS_NOBODY_HAS_NAMED") == :ambiguous
      assert DeployLedger.agency(nil) == :ambiguous
    end

    test "the content API classes accuse the instance, and the 403 accuses nobody" do
      assert DeployLedger.agency("CONTENT_API_500") == :box
      assert DeployLedger.agency("CONTENT_API_503") == :box
      assert DeployLedger.agency("CONTENT_API_UNREACHABLE") == :box

      # D239: eleven rows, three sites, two templates, one 20-minute window, two
      # sites' first rows 0.25s apart. That is not eleven misconfigured tokens
      # and it is not one sick box.
      assert DeployLedger.agency("CONTENT_API_403") == :ambiguous

      # DOC_ID_EMPTY now MEANS "no cause was recorded", and a class defined by
      # the absence of a cause cannot name an owner.
      assert DeployLedger.agency("DOC_ID_EMPTY") == :ambiguous
      assert DeployLedger.label("DOC_ID_EMPTY") =~ "unrecorded"
    end
  end

  ## ── 1b. The 503 reads the box's own code word ─────────────────────────────
  #
  # `BOX_UNAVAILABLE_503` was labelled "the box was unavailable (HTTP 503)" and
  # had EXACTLY ONE distinct failure_reason all-time on cloud-db-1 — 265 rows,
  # every one `feature_not_configured`, every one written by a box that was UP
  # (in the 2026-08-06 13:00Z hour, 15 deploys went LIVE on that same box while
  # 44 were refused as "not enabled", a live deploy and a refusal four seconds
  # apart). The label was not mostly wrong, it was wrong of every row it named.
  #
  # And dr-w8-s2 put a SECOND cause on the same status deliberately — a wedged
  # runner — so the class became a union with opposite operator instructions
  # behind one name that fits neither. The status alone cannot say which; the
  # box's own code word can, and the 409 arm already reads it.
  describe "classify/2 — the 503 splits on the box's code word" do
    test "the 265-row prod string names the CONFIG cause, not the box's health" do
      # Byte-verbatim from the column — not a paraphrase of it.
      assert DeployLedger.classify("PLAN", @r503_disabled) == "BOX_DEPLOY_DISABLED_503"
      # …and the code-only shape, with no message after the word, is the same cause.
      assert DeployLedger.classify("PLAN", @r503) == "BOX_DEPLOY_DISABLED_503"

      # The name is registered, labelled, and a real failure in the numerator.
      assert "BOX_DEPLOY_DISABLED_503" in DeployLedger.classes()
      refute DeployLedger.label("BOX_DEPLOY_DISABLED_503") == "BOX_DEPLOY_DISABLED_503"
      refute DeployLedger.deferred?("BOX_DEPLOY_DISABLED_503")
      refute DeployLedger.not_attempted?("BOX_DEPLOY_DISABLED_503")

      # THE POINT: neither new label may repeat the false claim the old one made.
      refute DeployLedger.label("BOX_DEPLOY_DISABLED_503") =~ "unavailable"
      refute DeployLedger.label("BOX_RUNNER_UNAVAILABLE_503") =~ "the box was unavailable"
    end

    test "a wedged runner is a DIFFERENT cause on the same status" do
      assert DeployLedger.classify("PLAN", @r503_runner) == "BOX_RUNNER_UNAVAILABLE_503"

      # The split must survive into the UI: two names that render the same
      # sentence are not a split.
      refute DeployLedger.label("BOX_RUNNER_UNAVAILABLE_503") ==
               DeployLedger.label("BOX_DEPLOY_DISABLED_503")

      assert "BOX_RUNNER_UNAVAILABLE_503" in DeployLedger.classes()
      refute DeployLedger.label("BOX_RUNNER_UNAVAILABLE_503") == "BOX_RUNNER_UNAVAILABLE_503"

      # The request-id stamp lands INSIDE the first ` — ` segment on this shape,
      # and the grace note lands after it. Neither is part of the box's word.
      assert @r503_runner =~ "[box request_id: F9tPXq2A]"
      assert @r503_runner =~ "after tolerating 3 transient box 5xx"
    end

    test "MUTATION — the arm can REFUSE: an unnamed 503 is not promoted" do
      # A code word this ledger has never named stays on the status-only name.
      assert DeployLedger.classify("PLAN", @r503_unknown) == "BOX_UNAVAILABLE_503"
      # Bare prose after the colon is not a code word either.
      assert DeployLedger.classify("PLAN", @r503_prose) == "BOX_UNAVAILABLE_503"
      # And a 503 with no detail at all — the shape that predates any code word.
      assert DeployLedger.classify("PLAN", "the instance refused the deploy (HTTP 503)") ==
               "BOX_UNAVAILABLE_503"

      # The fixtures really do carry what they claim to, so this is not three
      # assertions passing on three strings that lost the thing under test.
      assert @r503_unknown =~ "shard_draining"
      assert @r503_prose =~ "everything is on fire"
    end

    test "MUTATION — widening the code reader's status capture moves NO 409 row" do
      # `deferral_code/1`'s prefix was hard-pinned to 409; the 503 arm reads
      # through the SAME parser, so the capture had to widen to any status. If
      # that widening were wrong — a literal `\\d{3}`, a dropped `(?:HTTP )?`, a
      # lost anchor — these 409 rows would move, and they are the fleet's two
      # largest classes. BOTH 409 shapes, coded and bare:
      assert DeployLedger.classify("PLAN", @r409_coded) == "BOX_BUSY_409"
      assert DeployLedger.classify("PLAN", @r409_bare) == "BOX_BUSY_409"

      # …and the two arms that actually CALL the reader on a 409: the abandoned
      # split (which keys on the code word) and the deferred split.
      assert DeployLedger.classify("PLAN", @a_capacity) == "ABANDONED_AT_CAPACITY"
      assert DeployLedger.classify("PLAN", @a_busy) == "ABANDONED_BOX_STUCK"

      assert DeployLedger.classify(%{
               status: "deferred",
               stage: "PLAN",
               failure_reason: @d_capacity
             }) == "BOX_AT_CAPACITY_DEFERRED"

      assert DeployLedger.classify(%{
               status: "deferred",
               stage: "PLAN",
               failure_reason: @d_busy_bare
             }) == "BOX_BUSY_DEFERRED"

      # The BUSY-side near miss stays where it was: a 409 code the ledger has
      # never named must still rise in the deferred tail, not inherit a 503 arm.
      assert DeployLedger.classify(%{
               status: "deferred",
               stage: "PLAN",
               failure_reason: @d_unknown_code
             }) == "DEFERRED_UNCLASSIFIED"
    end
  end

  ## ── 1b. The label gauge: a class wears the cause its rows earn ───────────
  #
  # THIS IS A ROT GUARD, NOT A DETECTOR. Both assertions below are GREEN on the
  # tree that ships them: #10300 really did split the 503 and the taxonomy is
  # label-consistent today. What is NOT true is that anything guarded it. Set
  # `BOX_DEPLOY_DISABLED_503`'s entry in `@labels` to the collapse sentence the
  # unnamed bucket wears — "the box refused with a 503 it did not name a cause
  # for" — and run the pre-gauge version of THIS file: 50 tests, 0 failures.
  # GREEN. The class names still differ, the classifier arms still fire, the
  # three hand-written `refute label(...) =~ "unavailable"` lines still pass, and
  # an operator now reads the same causeless sentence for a switched-OFF deploy
  # flag as for a 503 nobody could name. The 265-row disease was never "the class
  # name was wrong"; it was "the SENTENCE was wrong", and nothing but three
  # `refute`s pinning one word stood between the repair and its silent undoing.
  #
  # FOUR DESIGN FACTS, each of which cost a red or a false positive:
  #
  #   (a) THE VOCABULARY DOES NOT COME FROM THE CLASSIFIER. Scraping the
  #       `{:code, "…"}` literals out of `deploy_ledger.ex` is vacuous BY
  #       CONSTRUCTION — a mutation that deletes an arm deletes its literal, so
  #       the gauge goes green on the exact change it exists to catch. The
  #       vocabulary is scraped from the PRODUCER's own test file instead, which
  #       is the box's proven wire vocabulary and which no classifier edit can
  #       shrink.
  #   (b) ONLY PRODUCER-WRITABLE (phase, status) SHAPES ARE PROBED.
  #       `Sites.Deploy` DEFERS every 409 (`defer/3` on `box_refusal(409, …)`),
  #       so a TERMINAL plain 409 is a row that cannot exist; probing one
  #       manufactures a finding against `BOX_BUSY_409` no operator will ever
  #       see. A 409 is therefore probed only in the two shapes the producer
  #       does write: chain-terminal (through the PUBLIC producer, never a
  #       literal) and deferred.
  #   (c) WHOLE TOKENS, NEVER SUBSTRINGS. A first run red on a false positive:
  #       `BOX_500`'s "the box errored on the deploy" was read as claiming
  #       `internal_error`, because "errored" contains "error".
  #   (d) "GENERIC" IS DERIVED, NEVER LISTED. A token carried by two labels whose
  #       causes are DISJOINT cannot be pointing at a cause ("box", "deploy",
  #       "instance"). That set is computed from `@labels` at runtime — a
  #       hand-list would be a third place someone must remember to edit — and a
  #       fixture pins that "unavailable" is NOT in it today, because the whole
  #       historical red depends on that word still carrying a claim.

  # WORDS THE BOX SAYS THAT THE LEDGER DELIBERATELY DOES NOT NAME, with the
  # reason written down. Both were found by RUNNING the gauge with this map
  # empty; neither was a decision anyone had made out loud. Emptying it reds
  # assertion A naming both, which is the point: the day the box learns a new
  # code word, someone must either give it a class or write down why not.
  @deliberately_unnamed %{
    "internal_error" =>
      "the AUTHORLESS crash constant. `Barkpark.Content.Errors` collapses ANY unhandled fault to it (Sites.Deploy's own grace arm keys on that), so it names a fault nobody chose and BOX_500's status-only label is the honest report of it.",
    "runner_start_failed" =>
      "a cause the box DID author (its runner would not spawn), but it arrives on a 500 at the poll phase and folds into BOX_500 with the authorless crash. Naming it in that label would put a specific accusation on rows that mostly are not it. Silent, not wrong — and now written down rather than accidental.",
    "graph_200" =>
      "the corpus read SUCCEEDED and carried nothing anchorable — ZERO rows all-time (D244), and the only graph status that is not an upstream failure at all. D8 governs: it rises in UNCLASSIFIED rather than being given a name on speculation, and this entry is the decision that says so out loud.",
    "no_previous" =>
      "a ROLLBACK-verb refusal, not a delivery cause. cch-w62-bl taught the producer test the box's nested no_previous exit (Sites.Deploy.rollback promotes it to a typed wire code for the console), which put the word into this scrape — but classify/2 is fed delivery attempts only, and a site rollback refusal never becomes a ledger row, so no class here can ever earn it. The console's own reader (siteRollbackFailure) is where the word gets its sentence."
  }

  # What it takes for a LABEL to name a cause: the code word itself, or a
  # declared synonym. A synonym list is not a loophole — it is the only way a
  # sentence a human reads ("site deploys are switched off on this instance") can
  # be checked against a wire word (`feature_not_configured`) at all. Every word
  # the producer scrape finds must appear here or the scrape test reds.
  @code_claims %{
    "already_running" => ~w(running busy deploying),
    "box_at_capacity" => ~w(capacity cap slots),
    "feature_not_configured" => ~w(configured switched disabled enabled off),
    "deploy_runner_unavailable" => ~w(runner unavailable),
    # NOT "error"/"errored" — see (c). "internal" is the discriminating token.
    "internal_error" => ~w(internal),
    # NOT "runner" — that word belongs to the wedged-runner cause, and letting it
    # count here would make BOX_RUNNER_UNAVAILABLE_503 "claim" a cause it is
    # never fed, which is a red the gauge would have deserved to be deleted for.
    "runner_start_failed" => ~w(spawn start),
    # The stage-axis causes. NOT the bare status digits: "500" is already in
    # BOX_500's label and "403" in FORBIDDEN_403's, so a digit cannot say WHICH
    # 500 a sentence is about — the generic-token derivation would strip it, and
    # rightly. Each label must earn its cause with a word only it uses.
    "graph_500" => ~w(faulted),
    "graph_503" => ~w(overloaded shut),
    "graph_0" => ~w(dns tls),
    "graph_403" => ~w(forbidden judged),
    "graph_200" => ~w(anchor anchorable),
    "no_corpus_status_marker" => ~w(unrecorded),
    # A rollback-verb word (see @deliberately_unnamed) — the claim token exists
    # so the scrape stays total, not because any delivery label may use it.
    "no_previous" => ~w(previous)
  }

  # The producer's own test file, read at runtime. See (a).
  @producer_test "test/barkpark_cloud/sites_deploy_test.exs"
  # `Sites.Deploy.refusal_detail/1` only ever emits a bare snake_case token as a
  # code (`@code_token` in the classifier), so `E_NO_INDEX` — which the producer
  # test also programs — is a MESSAGE-shaped envelope code, not a cause word the
  # taxonomy can key on. The shape is what excludes it, not a skip list.
  @producer_code ~r/"code" => "([a-z][a-z0-9_]*)"/

  # The (phase, status) shapes the producer can actually write. See (b).
  #
  # THE STAGE AXIS (D243). Everything above this line drives `classify/2` through
  # PLAN and BUILD box refusals only, so `label/1` was NEVER CALLED on any
  # stage-guarded class. Measured on origin/main: relabelling `DOC_ID_EMPTY` with
  # `BOX_RUNNER_UNAVAILABLE_503`'s sentence VERBATIM left 60 tests / 0 failures —
  # the gauge could not catch a class wearing another class's words. The control
  # that makes that a finding and not a broken harness: mutating
  # `BOX_DEPLOY_DISABLED_503`'s label reds ASSERTION A by name, then and now.
  #
  # So the matrix grows a second axis over STAGES. Its vocabulary is not the
  # producer scrape — graph statuses are an unbounded pass-through vocabulary
  # (D244) and are DECLARED in `@graph_statuses` — so each declared status enters
  # the gauge as its own cause word, driven through BOTH arms.
  @probe_matrix [
    {:start, 503},
    {:start, 500},
    {:start, 429},
    {:start, 404},
    {:poll, 500},
    {:poll, 503},
    {:abandoned, 409},
    {:deferred, 409},
    # The stage axis: the same declared status through each dialect.
    {:health, :graph},
    {:build, :graph},
    # …and the residue, whose whole cause is that no cause was recorded.
    {:health, :no_marker}
  ]

  # The stage-axis cause words. A graph status is a cause the same way a
  # snake_case code word is: `graph_503` is the box's answer, read off the row.
  defp graph_word(status), do: "graph_#{status}"
  @no_marker_word "no_corpus_status_marker"

  describe "the label gauge — a class must wear a name its rows earn" do
    test "the wire vocabulary is scraped from the PRODUCER, never from the classifier" do
      words = producer_vocabulary()

      # The six words the box is proven to send. Scraping the classifier's own
      # `{:code, "…"}` literals would find FOUR — and would find zero after a
      # mutation that deleted the arms, which is (a) in one sentence.
      for word <- ~w(already_running box_at_capacity feature_not_configured
                     deploy_runner_unavailable runner_start_failed internal_error) do
        assert word in words, "the producer scrape lost #{word} — the gauge is measuring nothing"
      end

      # FAIL CLOSED: the corpus must not be able to go silent. If the producer
      # test is moved or its envelope shape changes, this reds instead of the
      # gauge quietly passing over an empty vocabulary.
      assert MapSet.size(words) >= 6

      # Every word the box says must be a word the gauge knows how to check.
      for word <- words do
        assert Map.has_key?(@code_claims, word),
               "the box learned a new code word (#{word}) — decide what naming it looks like"
      end

      # The shape excludes the message-shaped envelope code, and the producer
      # really does program one, so this is not a filter passing over nothing.
      refute "E_NO_INDEX" in words
      assert File.read!(@producer_test) =~ ~s|"code" => "E_NO_INDEX"|
    end

    test "ASSERTION A — a cause with a class to itself is NAMED there, or its silence is declared" do
      assert naming_violations(probe_vocabulary(), &DeployLedger.label/1, @deliberately_unnamed) ==
               []
    end

    test "ASSERTION B — a class fed two or more causes names NONE of them" do
      assert collapse_violations(probe_vocabulary(), &DeployLedger.label/1) == []
    end

    # ASSERTION C (dr-w15 S2). A and B both reason about which CAUSE a sentence
    # points at, so neither of them notices two classes wearing the SAME
    # sentence: measured on origin/main, giving `DOC_ID_EMPTY` the
    # `BOX_RUNNER_UNAVAILABLE_503` label verbatim left 60 tests / 0 failures.
    # A split that collapses in the UI is not a split — the operator reads the
    # sentence, not the class name.
    test "ASSERTION C — no two classes the gauge reaches wear the SAME sentence" do
      assert duplicate_labels(probe_vocabulary(), &DeployLedger.label/1) == []
    end

    # …and C can lose: two classes handed one sentence red BY NAME.
    test "the gauge can LOSE: one sentence on two classes reds C, naming both" do
      collision = fn
        "DOC_ID_EMPTY" -> DeployLedger.label("BOX_RUNNER_UNAVAILABLE_503")
        class -> DeployLedger.label(class)
      end

      [dup] = duplicate_labels(probe_vocabulary(), collision)
      assert dup =~ "BOX_RUNNER_UNAVAILABLE_503"
      assert dup =~ "DOC_ID_EMPTY"
      assert dup =~ DeployLedger.label("BOX_RUNNER_UNAVAILABLE_503")

      # The reconstruction is honest: the same inputs on the REAL labels are
      # clean, so the red is the collision and not the harness.
      assert duplicate_labels(probe_vocabulary(), &DeployLedger.label/1) == []
    end

    # THE STAGE AXIS REACHES WHAT IT CLAIMS TO (D243). Without this the axis
    # could be quietly dropped — every assertion above would keep passing over a
    # smaller world, which is how the gauge got blind in the first place.
    test "the gauge REACHES every class this split mints, plus the residue" do
      reached = probe_vocabulary() |> Map.keys() |> MapSet.new()

      for class <- ~w(CONTENT_API_500 CONTENT_API_503 CONTENT_API_UNREACHABLE
                      CONTENT_API_403 DOC_ID_EMPTY) do
        assert MapSet.member?(reached, class),
               "#{class} is never probed — label/1 is not called on it and its sentence is unguarded"
      end

      # And it reaches them THROUGH BOTH ARMS: a HEALTH-only axis would leave the
      # astro fleet's sentences unguarded exactly as its rows were unnamed.
      assert class_of(:health, :graph, graph_word("500")) == "CONTENT_API_500"
      assert class_of(:build, :graph, graph_word("500")) == "CONTENT_API_500"
    end

    # THE GAUGE CAN LOSE. Both assertions are replayed against the pre-#10300
    # taxonomy, reconstructed here as data: the status-only 503 arm (every 503
    # cause landing in ONE class) wearing the label that class carried for its
    # entire 265-row life. This is the shipped half of the proof; the PR body
    # carries the same red produced by mutating the real module.
    test "the gauge can LOSE: the pre-#10300 503 reds under BOTH assertions" do
      {vocab, label_fun} = pre_10300_taxonomy()

      [collapse] = collapse_violations(vocab, label_fun)
      assert collapse =~ ~s|BOX_UNAVAILABLE_503 ("the box was unavailable (HTTP 503)")|
      assert collapse =~ ~s|claims "unavailable"|
      assert collapse =~ "deploy_runner_unavailable"
      assert collapse =~ "feature_not_configured"

      # …and A loses too, from the other side: the two causes no longer have a
      # class that can report them at all.
      naming = naming_violations(vocab, label_fun, @deliberately_unnamed)
      assert Enum.any?(naming, &(&1 =~ "feature_not_configured"))
      assert Enum.any?(naming, &(&1 =~ "deploy_runner_unavailable"))

      # And the reconstruction is honest: on the REAL taxonomy the same inputs
      # are clean, so the red above is the historical label, not the harness.
      assert collapse_violations(probe_vocabulary(), &DeployLedger.label/1) == []
    end

    test "whole TOKENS, never substrings — and generic filler is DERIVED, never listed" do
      vocab = probe_vocabulary()
      generic = generic_tokens(vocab, &DeployLedger.label/1)

      # (c) BOX_500's label contains "errored". A substring reader calls that a
      # claim on `internal_error`; a token reader does not.
      label500 = DeployLedger.label("BOX_500")
      assert String.contains?(label500, "error")
      assert "errored" in tokens(label500)
      refute "error" in tokens(label500)
      refute "internal_error" in claimed_words(label500, generic)

      # (d) Filler is derived from the labels themselves…
      assert "box" in generic
      assert "the" in generic
      # …and the word the whole historical red hangs on is NOT filler today. If a
      # future label makes it filler, the red above stops firing — silently,
      # unless this line reds first.
      refute "unavailable" in generic
      runner_label = DeployLedger.label("BOX_RUNNER_UNAVAILABLE_503")
      assert "deploy_runner_unavailable" in claimed_words(runner_label, generic)
      # …and the gauge can say WHICH word did the claiming, which is what an
      # operator reads off the screen.
      assert claim_token(runner_label, generic, "deploy_runner_unavailable") == "runner"
    end

    test "@deliberately_unnamed carries a REASON per entry, and emptying it reds A" do
      assert Map.keys(@deliberately_unnamed) |> Enum.sort() ==
               ["graph_200", "internal_error", "no_previous", "runner_start_failed"]

      for {word, reason} <- @deliberately_unnamed do
        assert is_binary(reason) and String.length(reason) > 40,
               "#{word} is declared unnamed with no reason — that is not a decision"
      end

      # The declaration is LOAD-BEARING: without it, A reds on both words.
      undeclared = naming_violations(probe_vocabulary(), &DeployLedger.label/1, %{})
      assert Enum.any?(undeclared, &(&1 =~ "internal_error"))
      assert Enum.any?(undeclared, &(&1 =~ "runner_start_failed"))
      assert Enum.any?(undeclared, &(&1 =~ "graph_200"))
      assert Enum.any?(undeclared, &(&1 =~ "no_previous"))
      # …and the two words are the ONLY silences on this tree — a count would
      # also red for any OTHER violation, which is not what this test is about,
      # so it names them instead.
      assert Enum.all?(
               undeclared,
               &(&1 =~ "internal_error" or &1 =~ "runner_start_failed" or &1 =~ "graph_200" or
                   &1 =~ "no_previous" or
                   &1 =~ "feature_not_configured" or &1 =~ "deploy_runner_unavailable")
             )
    end
  end

  # ── The gauge itself ──────────────────────────────────────────────────────

  # The box's proven wire vocabulary, from the producer's own test file.
  defp producer_vocabulary do
    @producer_test
    |> File.read!()
    |> then(&Regex.scan(@producer_code, &1))
    |> Enum.map(fn [_, word] -> word end)
    |> MapSet.new()
  end

  # class => the set of cause words the PRODUCERS can drive into it. Two
  # vocabularies, and they are sourced differently ON PURPOSE (D244): the
  # snake_case wire codes are SCRAPED from the producer's own test file (a closed
  # set the box emits), while the graph statuses are DECLARED (an unbounded
  # pass-through set a scrape cannot fail closed over).
  defp probe_vocabulary do
    wire = producer_vocabulary()

    for {phase, status} <- @probe_matrix, word <- probe_words(status, wire), reduce: %{} do
      acc ->
        Map.update(acc, class_of(phase, status, word), MapSet.new([word]), &MapSet.put(&1, word))
    end
  end

  defp probe_words(:graph, _wire), do: for({s, _n, _c} <- @graph_statuses, do: graph_word(s))
  defp probe_words(:no_marker, _wire), do: [@no_marker_word]
  defp probe_words(_status, wire), do: wire

  defp graph_status(word), do: String.replace_prefix(word, "graph_", "")

  # THE STAGE AXIS, driven through the real producer sentences of both dialects —
  # so `label/1` is called on every class this split mints, and on the residue.
  defp class_of(:health, :graph, word),
    do: DeployLedger.classify("HEALTH", health_graph_line(graph_status(word)))

  defp class_of(:build, :graph, word),
    do: DeployLedger.classify("BUILD", build_graph_line(graph_status(word)))

  defp class_of(:health, :no_marker, _word),
    do: DeployLedger.classify("HEALTH", @doc_id_no_marker)

  # A chain-terminal 409, built through the PUBLIC producer with the cause the
  # driver itself derives — never a literal, so a reworded verdict reds here.
  defp class_of(:abandoned, 409, word) do
    line = refusal_line("deploy", 409, word)
    cause = DeployLedger.classify(%{status: "deferred", stage: "PLAN", failure_reason: line})
    DeployLedger.classify("PLAN", Deploy.abandonment_reason(line, 12, cause))
  end

  defp class_of(:deferred, 409, word) do
    DeployLedger.classify(%{
      status: "deferred",
      stage: "PLAN",
      failure_reason: refusal_line("deploy", 409, word)
    })
  end

  defp class_of(:start, status, word),
    do: DeployLedger.classify("PLAN", refusal_line("deploy", status, word))

  defp class_of(:poll, status, word),
    do: DeployLedger.classify("BUILD", refusal_line("build poll", status, word))

  # `Sites.Deploy.box_refusal/3`'s own shape, both phases.
  defp refusal_line(noun, status, nil), do: "the instance refused the #{noun} (HTTP #{status})"

  defp refusal_line(noun, status, word),
    do: refusal_line(noun, status, nil) <> ": #{word} — the box said so"

  defp tokens(label) do
    label |> String.downcase() |> String.split(~r/[^a-z0-9_]+/, trim: true) |> MapSet.new()
  end

  # Which causes a label CLAIMS: a declared word or synonym, as a whole token,
  # that is not generic filler.
  defp claimed_words(label, generic) do
    said = MapSet.difference(tokens(label), generic)

    for {word, synonyms} <- @code_claims,
        Enum.any?([word | synonyms], &MapSet.member?(said, &1)),
        into: MapSet.new(),
        do: word
  end

  # Which word in the label did the claiming — the declared code word itself, or
  # the synonym that stood in for it.
  defp claim_token(label, generic, word) do
    said = MapSet.difference(tokens(label), generic)
    Enum.find([word | Map.fetch!(@code_claims, word)], &MapSet.member?(said, &1))
  end

  # (d): a token two DISJOINT-cause labels share cannot be pointing at a cause.
  # Only labels of classes the producer actually reaches take part — a label no
  # probe can produce makes no claim about any row.
  defp generic_tokens(vocab, label_fun) do
    labelled =
      for {class, words} <- vocab, MapSet.size(words) > 0, do: {tokens(label_fun.(class)), words}

    for {t1, w1} <- labelled,
        {t2, w2} <- labelled,
        MapSet.disjoint?(w1, w2),
        reduce: MapSet.new() do
      acc -> MapSet.union(acc, MapSet.intersection(t1, t2))
    end
  end

  # ASSERTION A. Every code word either has a class that holds it ALONE and a
  # label there that names it, or is a declared silence.
  defp naming_violations(vocab, label_fun, unnamed) do
    generic = generic_tokens(vocab, label_fun)
    words = vocab |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    for word <- Enum.sort(words), not Map.has_key?(unnamed, word), reduce: [] do
      acc ->
        sole = for {class, held} <- vocab, MapSet.equal?(held, MapSet.new([word])), do: class

        cond do
          sole == [] ->
            shared = for {class, held} <- vocab, MapSet.member?(held, word), do: class

            [
              ~s|#{word} never gets a class to itself — it is always folded in with other causes | <>
                ~s|#{inspect(Enum.sort(shared))}, so no label can report it. Give it a class, or | <>
                ~s|declare it in @deliberately_unnamed with a reason.|
              | acc
            ]

          Enum.any?(sole, &MapSet.member?(claimed_words(label_fun.(&1), generic), word)) ->
            acc

          true ->
            [
              ~s|#{word} is the ONLY cause of #{inspect(Enum.sort(sole))}, but no label there names | <>
                ~s|it: #{inspect(Enum.map(Enum.sort(sole), label_fun))}|
              | acc
            ]
        end
    end
  end

  # ASSERTION B. A class fed two or more causes may not name one of them — that
  # is the 265-row lie in the other direction, and it is what stops someone
  # "fixing" A by renaming a label and then quietly widening its class.
  defp collapse_violations(vocab, label_fun) do
    generic = generic_tokens(vocab, label_fun)

    for {class, held} <- vocab,
        MapSet.size(held) >= 2,
        claimed = MapSet.intersection(claimed_words(label_fun.(class), generic), held),
        MapSet.size(claimed) > 0 do
      word = claimed |> Enum.sort() |> hd()
      others = held |> MapSet.delete(word) |> Enum.sort()

      # The offending TOKEN, not just the cause it stands for: "unavailable" is
      # what an operator actually reads off the screen.
      ~s|#{class} ("#{label_fun.(class)}") claims "#{claim_token(label_fun.(class), generic, word)}" | <>
        ~s|(the label's word for #{word}) — but also holds | <>
        ~s|#{Enum.join(others, ", ")} and #{length(others)} other cause(s)|
    end
  end

  # ASSERTION C. Two classes the gauge reaches may not carry the same sentence.
  # Only reached classes take part, for the same reason B only counts reached
  # ones: a label no probe can produce makes no claim about any row.
  defp duplicate_labels(vocab, label_fun) do
    for {label, classes} <- Enum.group_by(Map.keys(vocab), label_fun),
        length(classes) >= 2 do
      ~s|#{Enum.join(Enum.sort(classes), " and ")} wear the SAME sentence ("#{label}") — | <>
        ~s|a split the operator cannot see is not a split|
    end
  end

  # The pre-#10300 taxonomy as DATA: the 503 arm keyed on the status alone, so
  # every 503 cause landed in one class wearing the label it carried for all 265
  # of its rows. `git show f89140090^:cloud/lib/barkpark_cloud/deploy_ledger.ex`
  # is where both come from.
  defp pre_10300_taxonomy do
    {split, rest} =
      Map.split(probe_vocabulary(), ["BOX_DEPLOY_DISABLED_503", "BOX_RUNNER_UNAVAILABLE_503"])

    collapsed =
      split
      |> Map.values()
      |> Enum.reduce(Map.get(rest, "BOX_UNAVAILABLE_503", MapSet.new()), &MapSet.union/2)

    vocab = Map.put(rest, "BOX_UNAVAILABLE_503", collapsed)

    label_fun = fn
      "BOX_UNAVAILABLE_503" -> "the box was unavailable (HTTP 503)"
      class -> DeployLedger.label(class)
    end

    {vocab, label_fun}
  end

  ## ── 1c. The POLL phase writes prose the anchors can read (D218) ──────────
  #
  # `Sites.Deploy.box_refusal/3` writes TWO captions from one helper. The
  # classifier's two anchors read only the START one, so a poll refusal matched
  # NEITHER — doubly blind — and landed in UNCLASSIFIED with its status and its
  # code word sitting unread in the string. That path is live: an untyped 5xx
  # that never clears burns `site_deploy_poll_grace` and falls out of the graced
  # arm wearing this caption (`sites_deploy_test.exs` drives it end to end and
  # asserts the class from the row the driver wrote).
  #
  # ZERO poll rows exist on cloud-db-1 all-time, against 14,753 start-phase
  # refusals. This is a TRIPWIRE for the first one, not a claim that any row is
  # mis-reported today. And no poll-409 arm is added, because a poll 409 cannot
  # happen: `poll/4` has no 409 arm and no `defer/3` call anywhere in the loop,
  # and the producer's `SiteDeployController.status/2` answers only 200/400/404
  # (both `put_status(:conflict)` sites live in `trigger/2`).

  # Byte-verbatim from a run: an untyped poll 500 that outlived the grace.
  @poll500 "the instance refused the build poll (HTTP 500): internal_error — unknown error [box request_id: PB-1] (after tolerating 3 transient box 5xx; the last was: the instance refused the build poll (HTTP 500): internal_error — unknown error [box request_id: PB-1])"
  @poll503_runner "the instance refused the build poll (HTTP 503): deploy_runner_unavailable — the deploy runner did not answer in time [box request_id: F9-poll]"
  @poll404 "the instance refused the build poll (HTTP 404)"

  describe "classify/2 — the POLL phase is read, not lost" do
    test "a poll refusal classifies by the same status and code word as a start refusal" do
      assert DeployLedger.classify("BUILD", @poll500) == "BOX_500"
      assert DeployLedger.classify("BUILD", @poll503_runner) == "BOX_RUNNER_UNAVAILABLE_503"

      # The same rows through the arm the census actually folds over.
      assert DeployLedger.classify(%{
               status: "failed",
               stage: "BUILD",
               failure_reason: @poll500
             }) == "BOX_500"
    end

    test "D8 holds on the poll caption too — an unnamed poll status is not absorbed" do
      assert DeployLedger.classify("BUILD", @poll404) == "UNCLASSIFIED"
    end

    test "the PHASE stays readable — the taxonomy does not split on it, so something must" do
      assert DeployLedger.refusal_phase(@poll500) == :poll
      assert DeployLedger.refusal_phase(@r503_runner) == :start
      assert DeployLedger.refusal_phase(@r409_bare) == :start
      # Not a refusal at all, and not a guess.
      assert DeployLedger.refusal_phase("BUILD failed (exit 12): boom") == nil
      assert DeployLedger.refusal_phase(nil) == nil
    end

    test "the anchor is still ANCHORED — a build log that QUOTES the poll caption is not one" do
      quoted = "BUILD failed (exit 12): the instance refused the build poll (HTTP 500)"
      assert DeployLedger.classify("BUILD", quoted) == "BUILD_FAILED"
      # …and the start-phase mass does not move, which is what widening risks.
      assert DeployLedger.classify("PLAN", @r409_coded) == "BOX_BUSY_409"
      assert DeployLedger.classify("PLAN", @r409_bare) == "BOX_BUSY_409"
      assert DeployLedger.classify("PLAN", @r503_disabled) == "BOX_DEPLOY_DISABLED_503"
      assert DeployLedger.classify("PLAN", @a_capacity) == "ABANDONED_AT_CAPACITY"
    end
  end

  ## ── 2. The census: rate with volume, over a pinned window ────────────────

  describe "census/3 — the rate always carries its denominator" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      %{user: user, team: team, site: site}
    end

    test "REFUSES a percentage below min_sample, and says why", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..10 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      assert census.volume == 10
      assert census.failed == 10
      # The number a naive implementation would print here is 100% off n=10.
      assert census.failure_rate.pct == nil
      assert census.failure_rate.refused
      assert census.failure_rate.sample == 10
      assert census.failure_rate.min_sample == DeployLedger.min_sample()
      assert census.failure_rate.reason =~ "below min_sample"
    end

    test "reports the rate WITH its sample once the window is big enough", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      # 150 failed + 100 live = 250 attempted → 60.00%.
      for i <- 1..150 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..100 do
        deployment!(site, %{
          status: "live",
          stage: "SWITCH",
          failure_reason: nil,
          inserted_at: DateTime.add(from, 1000 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      refute census.failure_rate.refused
      assert census.failure_rate.pct == 60.0
      # The denominator rides IN the node — a caller cannot print the pct alone.
      assert census.failure_rate.sample == 250
      assert census.failure_rate.numerator == 150
      assert census.volume == 250
      assert census.failed == 150

      # D43, AS AN ASSERTION AND NOT A PROMISE. Naming the success cohort must
      # not move the numbers that already existed: `live` is a FILTER over the
      # SAME `settled` cohort `failed_rows` comes from, so no row changes side.
      # A fourth `Enum.split_with` over `attempted` would have — and this is the
      # window that would have caught it.
      assert census.live == 100
      assert census.live_rate.pct == 40.0
      assert census.live_rate.sample == 250
      assert census.live_rate.numerator == 100
      refute census.live_rate.refused

      # …and the whole population is named: 150 failed + 100 live, nothing left
      # over and nothing in flight.
      assert census.in_flight == 0
      assert census.cancelled == 0
      assert census.residual == 0
    end

    # THE SUCCESS COUNT IS POSITIVE, PROVEN BY MUTATION (charter D257/D258).
    #
    # An arithmetic proof is worthless here: a fixture whose cohorts sum
    # correctly passes against a SUBTRACTIVE `live` (volume minus everything
    # else) just as happily as against a positive one — and the subtractive
    # definition is the bug, because every row that enters the window in a state
    # the census does not name would be reported as a deploy that WORKED.
    #
    # So this test mutates instead: it inserts a row in each of the four states
    # that are neither failed nor live and asserts `live` DOES NOT MOVE. Under a
    # subtractive definition every one of those four inserts raises `live`.
    test "MUTATION: a queued/building/pushing/cancelled row does NOT raise `live`", %{
      team: team,
      site: site
    } do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..4 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..6 do
        deployment!(site, %{
          status: "live",
          stage: "SWITCH",
          failure_reason: nil,
          inserted_at: DateTime.add(from, 100 + i, :second)
        })
      end

      before = DeployLedger.census(from, to)
      assert before.volume == 10
      assert before.failed == 4
      assert before.live == 6
      # EVERY attempt is in a named state: this fixture has no residue at all.
      assert before.residual == 0

      # One row per unnamed-until-now state. Each gets its OWN site: the partial
      # unique index `deployments_active_site_env_index` permits exactly one
      # in-flight production row per (site, environment), so a fixture that
      # stacked them on one site would raise Ecto.ConstraintError and this proof
      # would never run.
      for {status, i} <- Enum.with_index(~w(queued building pushing cancelled)) do
        deployment!(site_fixture(team), %{
          status: status,
          stage: "PLAN",
          failure_reason: nil,
          inserted_at: DateTime.add(from, 200 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      # THE ASSERTION THE WHOLE TEST EXISTS FOR. Four more attempted rows, and
      # not one of them is a deploy that worked.
      assert census.live == 6
      assert census.live_rate.numerator == 6

      # They ARE counted — they were real attempts — and each lands in the state
      # it is actually in.
      assert census.volume == 14
      assert census.failed == 4
      assert census.in_flight == 3
      assert census.cancelled == 1
      assert census.residual == 0
    end

    # THE RESIDUE CAN GO UP — the D8 discipline applied to statuses.
    # `deployments.status` is a CHECK-less varchar (pg_constraint contype='c'
    # returns zero rows for this table), so a producer can invent a status
    # tomorrow. The honest answer is a number that RISES and says "the census
    # does not name this", never a success count that quietly absorbs it.
    test "an UNKNOWN status is residue, loudly — it is not folded into `live`", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..4 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..6 do
        deployment!(site, %{
          status: "live",
          stage: "SWITCH",
          failure_reason: nil,
          inserted_at: DateTime.add(from, 100 + i, :second)
        })
      end

      # A status no arm of this census has ever been taught.
      for i <- 1..3 do
        deployment!(site, %{
          status: "quarantined",
          stage: "SWITCH",
          failure_reason: nil,
          inserted_at: DateTime.add(from, 200 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      assert census.volume == 13
      assert census.failed == 4
      assert census.live == 6
      assert census.residual == 3

      # And the residue does not leak into the failure rate either: an unnamed
      # status is not a failure any more than it is a success.
      assert census.failure_rate.numerator == 4
      assert census.failure_rate.sample == 13
    end

    test "the window is PINNED — rows outside the bound are not counted", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      deployment!(site, %{stage: "PLAN", failure_reason: @r409_bare, inserted_at: from})

      deployment!(site, %{
        stage: "PLAN",
        failure_reason: @r409_bare,
        inserted_at: ~U[2026-07-25 23:59:59Z]
      })

      # `to` is EXCLUSIVE — a half-open window is the only shape two adjacent
      # windows can tile without double-counting the boundary row.
      deployment!(site, %{stage: "PLAN", failure_reason: @r409_bare, inserted_at: to})

      assert DeployLedger.census(from, to).volume == 1
    end

    # ZERO-POPULATION TRIPWIRE (D251). `classify/1`'s `%{status: _other}` arm
    # answers `nil`, which is the "did not fail" default — so a status the ledger
    # has never seen lands in the DENOMINATOR and outside the numerator, and the
    # published failure rate falls with nothing having improved. There are zero
    # `cancelled` rows today; this pins the arithmetic so the FIRST one is
    # arithmetic somebody chose rather than a rate that quietly got better.
    test "a cancelled row is never scored as a success — it is not in the numerator, and it is visible",
         %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..3 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      deployment!(site, %{
        status: "cancelled",
        stage: "PLAN",
        failure_reason: "the operator cancelled the deploy",
        inserted_at: DateTime.add(from, 100, :second)
      })

      census = DeployLedger.census(from, to)

      # It is NOT a failure — the taxonomy must not invent one for a status it
      # has never been told about…
      assert DeployLedger.classify(%{
               status: "cancelled",
               stage: "PLAN",
               failure_reason: "the operator cancelled the deploy"
             }) == nil

      refute Enum.any?(census.classes, &(&1.count == 4))
      assert census.failed == 3

      # …and it is NOT counted as a deploy that worked either: it appears in no
      # class row at all, so no line of this census reports it as a success.
      assert Enum.sum(Enum.map(census.classes, & &1.count)) == 3
      refute Enum.any?(census.deferred, &(&1.class == "UNCLASSIFIED"))

      # THE HOLE, PINNED: it does sit in `volume`, so it dilutes the rate. 4
      # attempted, 3 failed = 75%, not 100%. The day cancelled rows appear, this
      # number moves and this assertion is what says so.
      assert census.volume == 4
      assert census.failure_rate.numerator == 3
      assert census.failure_rate.sample == 4
    end

    test "GITHUB_PUSH_UNBUILDABLE is OUT of the denominator and in its own bucket", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..10 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..7 do
        deployment!(site, %{
          stage: nil,
          failure_reason: @gh_push,
          inserted_at: DateTime.add(from, 100 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      # 17 rows exist; 10 were attempts. A denominator of 17 would report a rate
      # this epic can never move (only the human-gated gh-1 can).
      assert census.volume == 10
      assert census.failed == 10
      assert census.failure_rate.sample == 10

      assert [%{class: "GITHUB_PUSH_UNBUILDABLE", count: 7}] =
               Enum.map(census.not_attempted, &Map.take(&1, [:class, :count]))

      refute Enum.any?(census.classes, &(&1.class == "GITHUB_PUSH_UNBUILDABLE"))
    end

    # THE CROSS-SLICE PROOF. W1 S3 turns a box-busy 409 into a `deferred` row
    # instead of a terminal `failed` one — 51.4% of the fleet's failed rows
    # changing status in one merge. If the ledger answered `nil` for that status
    # (the "did not fail" default), the failure rate would halve because rows
    # STOPPED BEING COUNTED, which is the one outcome this epic's charter
    # forbids outright. This test is that tripwire: the mass must be visibly
    # RELOCATED, never deleted.
    test "a DEFERRAL is relocated, not deleted: out of the numerator, still in volume, on its own line",
         %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      # 6 genuine failures…
      for i <- 1..6 do
        deployment!(site, %{
          stage: "HEALTH",
          failure_reason: @doc_id,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      # …and 14 box-busy rows that, post-S3, settle `deferred`.
      for i <- 1..14 do
        deployment!(site, %{
          status: "deferred",
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, 100 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      # STILL COUNTED: a deferral was a real attempt against a real box, so it
      # stays in the denominator. A census that dropped it would report 6/6 =
      # 100% and call a halved fleet healthy.
      assert census.volume == 20
      # NOT A FAILURE: the box said "not now" and a rebuild was re-queued.
      assert census.failed == 6
      assert census.failure_rate.numerator == 6
      assert census.failure_rate.sample == 20

      # VISIBLE, on its own line, with a label that says what happened.
      assert [%{class: "BOX_BUSY_DEFERRED", count: 14}] =
               Enum.map(census.deferred, &Map.take(&1, [:class, :count]))

      assert DeployLedger.label("BOX_BUSY_DEFERRED") =~ "re-queued"

      # …and NOT smuggled into the failure taxonomy under another name.
      refute Enum.any?(census.classes, &(&1.class == "BOX_BUSY_DEFERRED"))
      refute Enum.any?(census.classes, &(&1.class == "BOX_BUSY_409"))

      # The per-site row tells the same story, so a site whose 409s became
      # deferrals cannot read as a site that got healthy.
      assert [row] = census.sites
      assert row.volume == 20
      assert row.failed == 6
      assert row.deferred == 14
    end

    # THE NUMERATOR JUDGMENT, as behaviour. An unnamed DEFERRAL is honest
    # ignorance about a refusal, not a failed deploy: it must be VISIBLE (its own
    # line, its own count) and must NOT move the failure rate. A tail routed into
    # `UNCLASSIFIED` instead would have inflated the numerator by every capacity
    # refusal the fleet's new build cap produces — vacuous RED, and it would
    # corrupt the very before/after this epic exists to measure.
    test "an UNNAMED deferral is counted and visible, and does NOT enter the failure numerator",
         %{
           site: site
         } do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..6 do
        deployment!(site, %{
          stage: "HEALTH",
          failure_reason: @doc_id,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..2 do
        deployment!(site, %{
          status: "deferred",
          stage: "PLAN",
          failure_reason: @d_busy,
          inserted_at: DateTime.add(from, 50 + i, :second)
        })
      end

      before = DeployLedger.census(from, to)
      assert before.volume == 8
      assert before.failure_rate.numerator == 6

      # Now a deferral for a cause the ledger cannot name, plus a capacity
      # refusal — the two shapes the old status-only arm folded into BOX_BUSY.
      deployment!(site, %{
        status: "deferred",
        stage: "PLAN",
        failure_reason: @d_novel,
        inserted_at: DateTime.add(from, 100, :second)
      })

      deployment!(site, %{
        status: "deferred",
        stage: "PLAN",
        failure_reason: @d_capacity,
        inserted_at: DateTime.add(from, 101, :second)
      })

      census = DeployLedger.census(from, to)

      # UNCHANGED numerator: neither row is a failure.
      assert census.failure_rate.numerator == before.failure_rate.numerator
      assert census.failed == 6
      # …and still COUNTED: both were real attempts against a real box.
      assert census.volume == 10

      deferred = Map.new(census.deferred, &{&1.class, &1.count})

      assert deferred == %{
               "BOX_BUSY_DEFERRED" => 2,
               "DEFERRED_UNCLASSIFIED" => 1,
               "BOX_AT_CAPACITY_DEFERRED" => 1
             }

      # Three causes, three lines — not one bucket wearing one label.
      refute Enum.any?(census.classes, &(&1.class in DeployLedger.deferred_classes()))
      assert [row] = census.sites
      assert row.failed == 6
      assert row.deferred == 4
    end

    test "counts per class and per site, with an unrecognised reason visibly in UNCLASSIFIED", %{
      team: team,
      site: site
    } do
      other = site_fixture(team)
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..5 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      deployment!(site, %{
        stage: "HEALTH",
        failure_reason: @doc_id,
        inserted_at: DateTime.add(from, 60, :second)
      })

      deployment!(other, %{
        stage: "PLAN",
        failure_reason: "a brand new refusal nobody has named yet",
        inserted_at: DateTime.add(from, 90, :second)
      })

      census = DeployLedger.census(from, to)
      by_class = Map.new(census.classes, &{&1.class, &1.count})

      assert by_class["BOX_BUSY_409"] == 5
      assert by_class["DOC_ID_EMPTY"] == 1
      # The tail rose because the corpus changed — which is the signal.
      assert by_class["UNCLASSIFIED"] == 1

      # Per-class share is a rate node too, so it also carries its denominator.
      busy = Enum.find(census.classes, &(&1.class == "BOX_BUSY_409"))
      assert busy.share.sample == 7
      assert busy.label =~ "already deploying"

      sites = Map.new(census.sites, &{&1.site_id, &1})
      assert sites[site.id].volume == 6
      assert sites[site.id].failed == 6
      assert sites[site.id].top_class == "BOX_BUSY_409"
      assert sites[other.id].volume == 1
      # A one-row site gets a refusal, not a 100%.
      assert sites[other.id].failure_rate.refused
    end

    # ── dr-w18-s2: per-site live, read POSITIVELY ──────────────────────────
    test "a site's live count is a FILTER on status, so an unfinished build is never success", %{
      site: site
    } do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..3,
          do:
            deployment!(site, %{
              stage: "PLAN",
              failure_reason: @r409_bare,
              inserted_at: DateTime.add(from, i, :second)
            })

      for i <- 1..2,
          do:
            deployment!(site, %{
              status: "live",
              stage: "SWITCH",
              failure_reason: nil,
              inserted_at: DateTime.add(from, 100 + i, :second)
            })

      # The row that kills a SUBTRACTIVE definition: attempted, not failed, not
      # deferred — and NOT live. `volume - failed - deferred` would report 3.
      deployment!(site, %{
        status: "building",
        stage: "BUILD",
        failure_reason: nil,
        inserted_at: DateTime.add(from, 200, :second)
      })

      row = DeployLedger.census(from, to).sites |> hd()

      assert row.volume == 6
      assert row.failed == 3
      assert row.deferred == 0
      assert row.live == 2, "a positive status filter answers 2; a subtraction answers 3"
    end

    # ── dr-w18-s2: the boundary LIST and the refusal it enables ────────────
    test "the census emits a boundary LIST, commit-derived, with the row-derived twin labelled" do
      c = DeployLedger.census(~U[2026-07-26 00:00:00Z], ~U[2026-07-27 00:00:00Z])

      assert is_list(c.boundaries)

      for b <- c.boundaries do
        assert Enum.sort(Map.keys(b)) == [:instant, :method, :source, :subject, :voids]
        assert %DateTime{} = b.instant
        assert b.voids != ""
      end

      commit =
        Enum.find(
          c.boundaries,
          &(&1.method == "schema_commit" and &1.subject =~ "deferred settle")
        )

      assert commit.instant == ~U[2026-08-05 21:13:50Z]
      assert commit.source == "#9615"

      # The min()-derived twin rides ONLY as a corroborator, and it says out
      # loud that a site DELETE can slide it — the measured cascade is +28m15s
      # and 444 of 2,206 deferred rows.
      twin =
        Enum.find(
          c.boundaries,
          &(&1.method == "first_observed_row" and &1.subject =~ "deferred settle")
        )

      assert twin.instant == ~U[2026-08-05 21:27:11.413210Z]
      assert twin.voids =~ "UPPER BOUND"
      assert twin.voids =~ "delete"

      # The SECOND schema event is on the list too — this is why it is a list.
      assert Enum.any?(
               c.boundaries,
               &(&1.subject =~ "deferral_cause" and &1.method == "schema_commit" and
                   &1.source == "#10248")
             )
    end

    test "a window that STRADDLES the vocabulary boundary refuses failure_rate and classes — and NOT live_rate",
         %{site: site} do
      # Wholly BEFORE the boundary: a real, internally consistent answer.
      before_from = ~U[2026-08-04 00:00:00Z]
      before_to = ~U[2026-08-05 00:00:00Z]

      for i <- 1..3,
          do:
            deployment!(site, %{
              stage: "PLAN",
              failure_reason: @r409_bare,
              inserted_at: DateTime.add(before_from, i, :second)
            })

      inside = DeployLedger.census(before_from, before_to)
      refute inside.failure_rate.reason =~ "STRADDLES"
      assert is_list(inside.classes)

      # A STRADDLING window with a real sample in it — n must clear min_sample
      # or every rate refuses for the ordinary reason and the boundary proves
      # nothing. 150 failed + 100 live = 250 attempted.
      for i <- 1..147,
          do:
            deployment!(site, %{
              stage: "PLAN",
              failure_reason: @r409_bare,
              inserted_at: DateTime.add(before_from, 1_000 + i, :second)
            })

      for i <- 1..100,
          do:
            deployment!(site, %{
              status: "live",
              stage: "SWITCH",
              failure_reason: nil,
              inserted_at: DateTime.add(before_from, 20_000 + i, :second)
            })

      # STRADDLING: the same physical box refusal is `failed` on one side and
      # `deferred` on the other, so the ratio is a blend of two taxonomies.
      straddle = DeployLedger.census(~U[2026-08-04 00:00:00Z], ~U[2026-08-06 00:00:00Z])

      assert straddle.failure_rate.refused
      assert is_nil(straddle.failure_rate.pct)
      assert straddle.failure_rate.reason =~ "STRADDLES"
      assert straddle.failure_rate.reason =~ "2026-08-05T21:13:50Z"
      assert straddle.failure_rate.reason =~ "schema_commit"
      assert straddle.failure_rate.reason =~ "#9615"

      # `classes` STAYS A LIST — the wire shape does not switch under a
      # straddling window, because the only reader of this envelope declares
      # `Classes []DeployCensusClass` and an object there is a decode ERROR, not
      # a refusal (w18 review). The counts are real rows and stay; the SHARES
      # refuse, carrying the boundary verbatim, exactly as `failure_rate` does
      # one level up.
      assert is_list(straddle.classes)
      assert straddle.classes != [], "the class rows are real counts and must not vanish"

      for row <- straddle.classes do
        assert row.count > 0
        assert row.share.refused, "every class share must refuse across the boundary"
        assert is_nil(row.share.pct)
        assert row.share.reason =~ "STRADDLES"
        assert row.share.reason =~ "2026-08-05T21:13:50Z"
        assert row.share.reason =~ "#9615"
      end

      # AND NOTHING IN THE ENVELOPE MAY BE A MAP WHERE A LIST IS DECLARED. This
      # is the assertion that would have caught the shape switch: the three
      # cohort keys are lists on EVERY path this census can take.
      for key <- [:classes, :deferred, :not_attempted, :sites] do
        assert is_list(Map.fetch!(straddle, key)),
               "#{key} must be a list on every path — the Go reader declares a slice"
      end

      # AND THE HALF THAT MUST NOT REFUSE (D229). A comparator that refuses
      # everything is an outage a reader routes around; `live_rate`'s numerator
      # and denominator are both label-independent.
      refute straddle.live_rate.refused
      assert straddle.live_rate.pct == 40.0
      assert is_nil(straddle.live_rate.reason)
      # The counts themselves are real rows and stay — only the RATIO goes.
      assert straddle.volume == 250
      assert straddle.failed == 150
      assert straddle.live == 100
    end

    # ── dr-w18-s2: the coalesced gauge and its REFUSING coverage floor ─────
    test "coalesced_attempts rides BESIDE volume and REFUSES below the counter's own floor", %{
      site: site
    } do
      from = ~U[2026-08-06 00:00:00Z]
      to = ~U[2026-08-07 00:00:00Z]

      for i <- 1..3,
          do:
            deployment!(site, %{
              stage: "PLAN",
              failure_reason: @r409_bare,
              coalesced_attempts: 5,
              inserted_at: DateTime.add(from, i, :second)
            })

      # This window opens BEFORE the migration instant, so a SUM would be a
      # confident number over rows that could not have counted. Measured on
      # prod: the sum over 2026-08-06 is 0 while the day's true coalesced
      # volume was ~1,563.
      refused = DeployLedger.census(from, to)

      assert refused.coalesced_attempts.refused
      assert is_nil(refused.coalesced_attempts.value)
      assert refused.coalesced_attempts.reason =~ "2026-08-07T10:02:23Z"
      assert refused.coalesced_attempts.basis =~ "minted NO deployment row"
      # It is never folded into volume — the two populations are disjoint.
      assert refused.volume == 3

      # THE FLOOR CAN LOSE: move the constant back and the SAME window answers a
      # number instead of refusing. This is the mutation, run in-suite rather
      # than described in a comment.
      Application.put_env(:barkpark_cloud, :coalesced_counter_since, ~U[2026-08-05 00:00:00Z])
      on_exit(fn -> Application.delete_env(:barkpark_cloud, :coalesced_counter_since) end)

      moved = DeployLedger.census(from, to)
      refute moved.coalesced_attempts.refused
      assert moved.coalesced_attempts.value == 15
    end

    test "every rate on the envelope NAMES its basis", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..3,
          do:
            deployment!(site, %{
              stage: "PLAN",
              failure_reason: @r409_bare,
              inserted_at: DateTime.add(from, i, :second)
            })

      c = DeployLedger.census(from, to)

      assert c.failure_rate.basis =~ "attempted rows"
      assert c.live_rate.basis =~ "attempted rows"
      # A class share is denominated on `failed`, not on the attempted
      # population — and it says so rather than borrowing the default sentence.
      assert hd(c.classes).share.basis =~ "failure numerator"
      assert hd(c.classes).share.sample == 3
    end

    # ── dr-w18-s2: the completeness audit, in the code ─────────────────────
    test "census/3 carries a SECOND INDEPENDENT COUNT reconciled against volume + not_attempted",
         %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..4,
          do:
            deployment!(site, %{
              stage: "PLAN",
              failure_reason: @r409_bare,
              inserted_at: DateTime.add(from, i, :second)
            })

      # A D19 tombstone: born failed, never attempted, OUTSIDE volume on
      # purpose. Reconciling against `volume` alone would make this a permanent
      # false red on the real corpus (7 rows all-time).
      deployment!(site, %{
        stage: "PLAN",
        failure_reason: "github push builds require a build runner this CP does not have",
        inserted_at: DateTime.add(from, 50, :second)
      })

      # A PREVIEW-ENVIRONMENT row. It belongs to the census population (nothing
      # in `scoped` narrows on environment) and it is what makes this test
      # DISCRIMINATING: inject `where: d.environment == "production"` into the
      # grouped query and the partition guard stays 4/4 green while THIS audit
      # reds, because the second count still sees the row the fold lost.
      deployment!(site, %{
        stage: "PLAN",
        environment: "preview",
        failure_reason: @r409_bare,
        inserted_at: DateTime.add(from, 70, :second)
      })

      c = DeployLedger.census(from, to)

      # THE AUDIT FIRST — it is the assertion that must be able to lose, and a
      # volume assertion above it would red first and hide which guard caught
      # the loss.
      assert c.completeness.balanced,
             "the audit lost rows: #{c.completeness.reason}"

      assert c.completeness.unaccounted == 0
      assert c.completeness.audited == 6
      assert c.completeness.accounted == 6
      assert is_nil(c.completeness.reason)

      assert c.volume == 5
      assert Enum.sum(Enum.map(c.not_attempted, & &1.count)) == 1
      assert c.completeness.method =~ "no GROUP BY"
      # The blind spot is NAMED on the wire, not only in the moduledoc.
      assert c.completeness.method =~ "both shapes inherit `scoped`"
    end

    # ── dr-w18-s2: the truncation marker ──────────────────────────────────
    # UNFALSIFIABLE BY LIVE DATA — the fleet has 13 sites and the cut is 50, so
    # only a CONSTRUCTED population can make this marker fire. A live-data
    # assertion here would be vacuous green.
    test "51 sites against the default 50-cut sets `truncated` on BOTH the census and delivery nodes",
         %{team: team} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for _ <- 1..51 do
        s = site_fixture(team)

        deployments!(s, [
          %{
            status: "live",
            inserted_at: DateTime.add(from, 10, :second),
            became_live_at: DateTime.add(from, 40, :second)
          }
        ])
      end

      c = DeployLedger.census(from, to)
      assert c.total_sites == 51
      assert c.truncated
      assert length(c.sites) == 50

      d = DeployLedger.delivery(from, to, as_of: to)
      assert d.total_sites == 51
      assert d.truncated
      assert length(d.sites) == 50

      # …and the marker is FALSE when nothing was cut, so it is a fact and not a
      # constant. 51 sites under a 60-cut is the same population, uncut.
      wide = DeployLedger.census(from, to, site_limit: 60)
      refute wide.truncated
      assert wide.total_sites == 51
      assert length(wide.sites) == 51
    end
  end

  ## ── 4b. The deferral WAIT, and the D8 inversion ──────────────────────────
  #
  # "Re-queued, not lost" is a claim about TIME, and until dr-w28-s4 the census
  # carried no time dimension for it at all: a fleet that relabels every 409
  # `deferred` reads as a fleet that got better even if the rebuild lands
  # fourteen hours later. These tests are that number, plus the two ways it
  # could lie — a rev-keyed join that manufactures a loss, and a quantile
  # printed over a population too small or too unresolved to name one.

  describe "census/3 — the deferral WAIT is TIME-keyed, with its population beside it" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team), team: team}
    end

    @dwait_from ~U[2026-08-01 00:00:00Z]
    @dwait_to ~U[2026-08-08 00:00:00Z]

    # One deferral every 1,000s, each covered by its OWN live build minted
    # `wait` seconds later — so every gap is unambiguous and the sorted sample
    # is exactly the wait list. 240 rows clears `min_sample` 200, which is the
    # only way a quantile is allowed to be a number at all.
    defp covered_deferrals!(site, waits, opts \\ []) do
      rev = Keyword.get(opts, :content_rev, "rev-deferred")
      live_rev = Keyword.get(opts, :live_content_rev, "rev-live")

      rows =
        waits
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {wait, i} ->
          at = DateTime.add(@dwait_from, 1_000 * i, :second)

          [
            %{status: "deferred", content_rev: rev, inserted_at: at},
            %{
              status: "live",
              content_rev: live_rev,
              inserted_at: DateTime.add(at, wait, :second),
              became_live_at: DateTime.add(at, wait, :second)
            }
          ]
        end)

      deployments!(site, rows)
    end

    test "p50/p95/max are seconds, and the POPULATION rides in the same node", %{site: site} do
      waits = List.duplicate(60, 120) ++ List.duplicate(300, 108) ++ List.duplicate(900, 12)
      covered_deferrals!(site, waits)

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      # THE POPULATION, whole and accounted: nothing was silently dropped out of
      # the denominator to make the percentiles prettier.
      assert wait.population == %{deferred: 240, covered: 240, pending: 0, unreadable: 0}

      assert wait.population.covered + wait.population.pending + wait.population.unreadable ==
               wait.population.deferred

      # THE NUMBERS. ceil(n*q), 1-based: p50 → the 120th, p95 → the 228th,
      # max → the 240th of the sorted waits.
      assert %{seconds: 60.0, refused: false, sample: 240} = wait.p50
      assert %{seconds: 300.0, refused: false, sample: 240} = wait.p95
      assert %{seconds: 900.0, refused: false, sample: 240} = wait.max

      # D3: no percentile travels without what it is a percentile OF.
      for node <- [wait.p50, wait.p95, wait.max] do
        assert node.sample == 240
        assert node.min_sample == 200
        assert node.basis =~ "site has since rebuilt"
      end

      # …and the clock says WHICH two instants it subtracted.
      assert wait.clock =~ "inserted_at"
      assert wait.as_of == @dwait_to
    end

    # THE FORBIDDEN IMPLEMENTATION, refused as behaviour (D478 / D170(a)).
    # `content_rev` is `sha256([doc_type, published_count, published_events])`
    # over a dataset-wide window: it is not a revision, it is not injective
    # across sites, and it recurs. A census that joined on it would call this
    # deferral LOST — the fixture gives it a rev that appears on no live row
    # anywhere — while the clock says the site rebuilt 300s later.
    test "the outcome is decided by the CLOCK, never by a content_rev join", %{site: site} do
      deployments!(site, [
        %{
          status: "deferred",
          content_rev: "rev-that-never-reaches-a-live-row",
          inserted_at: DateTime.add(@dwait_from, 100, :second)
        },
        %{
          status: "live",
          content_rev: "an-entirely-different-rev",
          inserted_at: DateTime.add(@dwait_from, 400, :second),
          became_live_at: DateTime.add(@dwait_from, 400, :second)
        }
      ])

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      assert wait.population.covered == 1
      assert wait.population.pending == 0
      # A rev-keyed census reads the SAME two rows as a loss. That is the
      # 52.1%-never-reached-live number this slice exists to refuse.
      assert wait.max.sample == 1
    end

    test "the vocabulary is COVERED / PENDING / UNREADABLE, and COVERED claims only the SITE",
         %{site: site} do
      deployments!(site, [
        # COVERED — a later live build was minted for this site.
        %{
          status: "deferred",
          content_rev: "rev-a",
          inserted_at: DateTime.add(@dwait_from, 100, :second)
        },
        %{
          status: "live",
          content_rev: "rev-a",
          inserted_at: DateTime.add(@dwait_from, 220, :second),
          became_live_at: DateTime.add(@dwait_from, 220, :second)
        },
        # PENDING — nothing has been minted after it.
        %{
          status: "deferred",
          content_rev: "rev-b",
          inserted_at: DateTime.add(@dwait_from, 300, :second)
        },
        # UNREADABLE — the producer's own fail-open for a box it could not read.
        %{
          status: "deferred",
          content_rev: "",
          inserted_at: DateTime.add(@dwait_from, 400, :second)
        }
      ])

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      assert Enum.map(wait.outcomes, & &1.outcome) == ~w(COVERED PENDING UNREADABLE)

      assert Map.new(wait.outcomes, &{&1.outcome, &1.count}) == %{
               "COVERED" => 1,
               "PENDING" => 1,
               "UNREADABLE" => 1
             }

      # THE WORDING IS THE FINDING. Cumulativity has one unmeasured hole — an
      # unpublish makes `published_count` fall — so COVERED may claim the SITE
      # rebuilt and may never claim the operator's own edit shipped.
      covered = Enum.find(wait.outcomes, &(&1.outcome == "COVERED"))
      assert covered.label =~ "the site has since rebuilt"

      # And the two words that must not ship, anywhere in this node: `delivered`
      # claims a precision a non-injective hash cannot support, `superseded`
      # names an inference no column on the row can prove.
      rendered = inspect(wait)
      refute rendered =~ "delivered"
      refute rendered =~ "superseded"
      refute rendered =~ "your edit"

      # A PENDING row is not a mystery — it is a row that has waited THIS long
      # already, floored on the window's own pinned `as_of`.
      assert wait.oldest_pending_seconds > 0
    end

    test "below min_sample the QUANTILES refuse and the COUNTS survive", %{site: site} do
      covered_deferrals!(site, List.duplicate(120, 3))

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      # The refusal, exactly as `rate/2` writes it at the same threshold.
      for node <- [wait.p50, wait.p95, wait.max] do
        assert node.refused
        assert is_nil(node.seconds)
        assert node.reason == "sample 3 below min_sample 200"
        assert node.sample == 3
      end

      # …and the counts are REAL ROWS, so they stay. A refusal that also blanked
      # the population would read as "no deferrals", which is the opposite fact.
      assert wait.population == %{deferred: 3, covered: 3, pending: 0, unreadable: 0}
      assert wait.sample == 3
    end

    # THE SECOND REFUSAL, and it is not a duplicate of the first: this sample
    # clears `min_sample` and still cannot name a p95, because a quantile needs
    # `1 - q` of the mass above it and 20% of the population has not finished.
    test "a p95 REFUSES when more of the population is unresolved than its headroom", %{
      site: site
    } do
      covered_deferrals!(site, List.duplicate(60, 240))

      # 60 deferrals with nothing after them — 60 of 300 = 20.0% unresolved.
      deployments!(
        site,
        for i <- 1..60 do
          %{
            status: "deferred",
            content_rev: "rev-pending",
            inserted_at: DateTime.add(@dwait_from, 500_000 + i, :second)
          }
        end
      )

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      assert wait.population.deferred == 300
      assert wait.population.pending == 60
      assert wait.unresolved == 60

      assert wait.p95.refused
      assert is_nil(wait.p95.seconds)
      assert wait.p95.unresolved_fraction == 0.2
      assert wait.p95.reason =~ "UNIDENTIFIABLE"
      assert wait.p95.reason =~ "20.0%"

      # …and the guard is a FACT, not a blanket: p50 has 50% of headroom and is
      # still nameable over the same population.
      refute wait.p50.refused
      assert wait.p50.seconds == 60.0
    end

    # THE ZERO-HEADROOM LAW, which nothing pinned until now: `max` is the q=1.0
    # quantile, so its headroom is `1.0 - 1.0 = 0.0` and ONE unresolved row is
    # already more of the population than it can carry. Deleting the law
    # entirely — `deferral_wait_quantile(seconds, 1.0, "max", unresolved, ...)`
    # → `..., 0, ...` — passed the whole file before this test existed.
    #
    # `live_marks/1` is bounded BELOW and not above, so a merely-past window has
    # `pending: 0` and `max` prints. The fixture therefore mints a genuinely
    # PENDING row: 240 covered deferrals that clear `min_sample` on their own,
    # plus one deferral that nothing was minted after.
    test "max REFUSES on a single unresolved row — a q=1.0 quantile has no headroom at all",
         %{site: site} do
      covered_deferrals!(site, List.duplicate(60, 240))

      deployments!(site, [
        %{
          status: "deferred",
          content_rev: "rev-still-waiting",
          inserted_at: DateTime.add(@dwait_from, 500_000, :second)
        }
      ])

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      # The sample is big enough that `min_sample` is NOT what refuses here —
      # otherwise this test would pass with the law deleted.
      assert wait.population == %{deferred: 241, covered: 240, pending: 1, unreadable: 0}
      assert wait.max.sample == 240
      assert wait.max.sample >= DeployLedger.min_sample()

      assert wait.max.refused
      assert is_nil(wait.max.seconds)
      assert wait.max.reason =~ "UNIDENTIFIABLE"
      assert wait.max.headroom == 0.0
      assert wait.max.unresolved == 1

      # …and it is the ZERO-HEADROOM law that refused, not the sample floor.
      refute wait.max.reason =~ "below min_sample"

      # The guard is a FACT about q=1.0 and not a blanket over the node: p95 has
      # 5% of headroom, 0.41% is unresolved, and it still names a number over
      # the same population.
      refute wait.p95.refused
      assert wait.p95.seconds == 60.0
    end

    # THE RIGHT-EDGE LAW, ON THE DEFERRAL SIDE — WHERE IT HAD NO EXERCISE
    # SURFACE AT ALL (dr-w34-s1).
    #
    # `live_marks/1` is bounded BELOW and deliberately not above, and D555
    # measured the mutation that bounds it: promote it to `live_marks/2` with a
    # `where: d.inserted_at <= ^as_of` and thread `as_of` from BOTH call sites.
    # Applied at the coverage site (:1521) alone it reds one test — the pair
    # `coverage_cohorts` already carries. Applied at the DEFERRAL site (:1349)
    # ALONE it redded NOTHING, because every `@dwait_*` fixture in this block
    # mints its covering live row INSIDE the window (`covered_deferrals!/3` puts
    # it at `at + wait`), so the law was pinned on one of its two sites and
    # unpinned on the other. This pair is the deferral side's positive offset.
    test "a DEFERRED row is COVERED by a live build minted AFTER the window's `to` — the deferral clock is not right-bounded either",
         %{site: site} do
      deferred_at = DateTime.add(@dwait_from, 1_000, :second)
      # POSITIVE offset from @dwait_to: outside the window, and the ONLY row in
      # the table that can cover the deferral.
      live_at = DateTime.add(@dwait_to, 3_600, :second)

      deployments!(site, [
        %{status: "deferred", content_rev: "rev-deferred", inserted_at: deferred_at},
        %{
          status: "live",
          content_rev: "rev-live",
          inserted_at: live_at,
          became_live_at: live_at
        }
      ])

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      # The covering row is OUTSIDE the population — it is only ever a mark.
      assert wait.population == %{deferred: 1, covered: 1, pending: 0, unreadable: 0}
      assert wait.unresolved == 0
      assert is_nil(wait.oldest_pending_seconds)

      # AND THE FIXTURE CANNOT PASS BY ACCIDENT. If the covering row were inside
      # the window, a right-bounded `live_marks` would still see it and this
      # test would green on the mutated implementation. Asserting the offset
      # itself is what makes the exercise surface real.
      assert DateTime.compare(live_at, wait.as_of) == :gt
    end

    # THE MIRROR, so the assertion above cannot pass vacuously: identical
    # fixture with the post-window live build REMOVED. This is where a
    # right-bounded implementation would put the row WITH the live build
    # present — PENDING at the window's own edge, an artefact of where the
    # reader drew the boundary, reported as a fleet that never re-queued.
    test "the same deferral with the post-window live build removed is PENDING — the law above is not vacuous",
         %{site: site} do
      deferred_at = DateTime.add(@dwait_from, 1_000, :second)

      deployments!(site, [
        %{status: "deferred", content_rev: "rev-deferred", inserted_at: deferred_at}
      ])

      wait = DeployLedger.census(@dwait_from, @dwait_to).deferral_wait

      assert wait.population == %{deferred: 1, covered: 0, pending: 1, unreadable: 0}
      assert wait.unresolved == 1
      assert wait.as_of == @dwait_to

      # THE EXACT FLOOR, computed and not placeholdered: the window is
      # @dwait_from ~U[2026-08-01] -> @dwait_to ~U[2026-08-08], i.e. 604_800s,
      # and the row was written 1_000s into it. A bound that drifts with the
      # fixture would let the number mean nothing.
      assert DateTime.diff(@dwait_to, @dwait_from) == 604_800
      assert wait.oldest_pending_seconds == 603_800.0

      # `deferral_wait` publishes `oldest_pending_seconds`. The lower bound over
      # in `delivery/3` is a DIFFERENT node with a different name, and conflating
      # the two is how a reader ends up asserting against a key that is not here.
      refute Map.has_key?(wait, :still_waiting_at_least_seconds)
    end
  end

  ## ── 4b-bis. THE COVERAGE PARTITION, OVER BOTH NEVER-LIVE COHORTS ──────────

  describe "census/3 — coverage_cohorts sees the FAILED tail the deferral clock cannot" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team), team: team}
    end

    @cov_from ~U[2026-08-01 00:00:00Z]
    @cov_to ~U[2026-08-08 00:00:00Z]

    # THE MEASURED PARTITION, REPRODUCED IN SHAPE (dr-w32-s3).
    #
    # The corpus this key was built from reads, all-time and on rows older than
    # 24h: DEFERRED 0 never-covered of 2,816, FAILED 5 never-covered of 18,640,
    # and TWO of those five are the only two `environment: "preview"` rows in the
    # table — so PRODUCTION never-covered, all-time, is THREE. Those totals are a
    # production measurement (cloud-db-1) and cannot be re-derived inside a test
    # database; what a test can pin, and what this one does pin, is the
    # ARITHMETIC and the ENVIRONMENT SPLIT that turn five into three. The
    # cohort sizes below are scaled; the never-covered numbers are the measured
    # ones, verbatim.
    defp measured_partition!(site) do
      # Every DEFERRED row covered — 0 never-covered, the measured deferred side.
      deferred =
        Enum.flat_map(1..24, fn i ->
          at = DateTime.add(@cov_from, 1_000 * i, :second)

          [
            %{status: "deferred", content_rev: "rev-d", inserted_at: at},
            %{
              status: "live",
              content_rev: "rev-live",
              inserted_at: DateTime.add(at, 120, :second),
              became_live_at: DateTime.add(at, 120, :second)
            }
          ]
        end)

      # FAILED rows that a later live build DID cover — the ordinary shape, and
      # the reason the failed cohort is not simply "damage".
      covered_failures =
        Enum.flat_map(1..40, fn i ->
          at = DateTime.add(@cov_from, 100_000 + 1_000 * i, :second)

          [
            %{status: "failed", inserted_at: at},
            %{
              status: "live",
              inserted_at: DateTime.add(at, 300, :second),
              became_live_at: DateTime.add(at, 300, :second)
            }
          ]
        end)

      # THE FIVE. Three production, two preview — and the preview pair is
      # covered by NOTHING because the live builds above are all `production`,
      # which is the whole point of keying the clock on {site, environment}.
      never_covered =
        for {env, n} <- [{"production", 3}, {"preview", 2}],
            i <- 1..n,
            do: %{
              status: "failed",
              environment: env,
              inserted_at: DateTime.add(@cov_from, 300_000 + i, :second)
            }

      deployments!(site, deferred ++ covered_failures ++ never_covered)
    end

    test "the failed cohort is reported BESIDE the deferred one, never pooled with it",
         %{site: site} do
      measured_partition!(site)

      census = DeployLedger.census(@cov_from, @cov_to)
      [deferred, failed] = census.coverage_cohorts.cohorts

      assert deferred.cohort == "deferred"
      assert failed.cohort == "failed"

      # THE DEFERRED SIDE, as measured: nothing never-covered.
      assert deferred.population == 24
      assert deferred.covered == 24
      assert deferred.never_covered == 0

      # THE FAILED SIDE: five never-covered, which is the number the deferral
      # clock structurally cannot see.
      assert failed.population == 45
      assert failed.covered == 40
      assert failed.never_covered == 5

      # …and the split that turns five into three.
      assert failed.never_covered_by_environment == [
               %{environment: "production", never_covered: 3},
               %{environment: "preview", never_covered: 2}
             ]

      # THE BLINDNESS THIS KEY EXISTS FOR, asserted rather than asserted-about:
      # the deferral wait, over the SAME window and the SAME rows, reports a
      # population of 24 and cannot name one of the five.
      assert census.deferral_wait.population == %{
               deferred: 24,
               covered: 24,
               pending: 0,
               unreadable: 0
             }
    end

    # THE MATURITY FENCE, PROVEN IN BOTH DIRECTIONS. A test that only asserted
    # "too young rows are not never-covered" would pass on an implementation
    # that never counts anything: the same row, aged past the fence, must flip.
    test "a PENDING row younger than the fence is too_young, and the same row older is never_covered",
         %{site: site} do
      young = DateTime.add(@cov_to, -3_600, :second)
      old = DateTime.add(@cov_to, -172_800, :second)

      deployments!(site, [
        %{status: "failed", inserted_at: young},
        %{status: "failed", inserted_at: old}
      ])

      [_deferred, failed] = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts.cohorts

      assert failed.population == 2
      assert failed.pending == 2
      assert failed.too_young == 1
      assert failed.never_covered == 1
      assert failed.matured == 1
      assert failed.oldest_pending_seconds == 172_800.0

      # The fence is the census's own number, published beside the counts — a
      # reader can never be handed "1 never covered" without being told what
      # bar it cleared.
      assert DeployLedger.census(@cov_from, @cov_to).coverage_cohorts.maturity_seconds == 86_400
    end

    # THE RIGHT-EDGE LAW, WHICH NOTHING IN THIS FILE EXERCISED UNTIL NOW.
    #
    # `live_marks/1` is bounded BELOW (`inserted_at > ^earliest`) and
    # deliberately NOT bounded on the right, and `deploy_ledger.ex` spends nine
    # lines saying why: the build that covers a row inside the window is very
    # often minted after `to`, and refusing to see it would manufacture PENDING
    # at the window's own edge — the reader's choice of boundary, reported as a
    # stalled fleet.
    #
    # Before this test the law had an EMPTY exercise surface. Adding
    # `where: d.inserted_at <= ^as_of` to `live_marks` left all 3,592 cloud
    # tests green, while on the real corpus 32.6% of the July failed rows
    # (3,918 of 12,025) are COVERED solely by a mark minted after the window —
    # so the mutation swings the epic's headline number from 3 to ~3,921. Every
    # other never_covered fixture in this file mints its covering mark INSIDE
    # the window, and the maturity-fence test above uses only NEGATIVE offsets
    # from @cov_to. This pair is the POSITIVE offset.
    test "a row is COVERED by a live build minted AFTER the window's `to` — the covering query is not right-bounded",
         %{site: site} do
      failed_at = DateTime.add(@cov_from, 1_000, :second)
      # POSITIVE offset from @cov_to: outside the window, and the ONLY thing in
      # the table that can cover the failed row.
      live_at = DateTime.add(@cov_to, 3_600, :second)

      deployments!(site, [
        %{status: "failed", inserted_at: failed_at},
        %{status: "live", inserted_at: live_at, became_live_at: live_at}
      ])

      [_deferred, failed] = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts.cohorts

      # The live row is OUTSIDE the window, so it is never part of the
      # population — it is only ever a covering mark.
      assert failed.population == 1
      assert failed.covered == 1
      assert failed.pending == 0
      assert failed.never_covered == 0
      assert failed.too_young == 0
      assert failed.never_covered_by_environment == []

      # …and nothing never-covered names NOBODY. An empty list is the same
      # honest zero the counts report, and it still carries its population, so
      # "no sites are stuck" can never be confused with "the list was cut".
      cohorts = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts
      assert cohorts.never_covered_sites == []
      assert cohorts.never_covered_sites_total == 0
      refute cohorts.never_covered_sites_truncated
    end

    # THE MIRROR, so the assertion above cannot pass vacuously. Identical
    # fixture with the post-window live build REMOVED: the row is old enough to
    # clear the maturity fence, so it lands in never_covered — which is where
    # the bounded implementation would put it WITH the live build present.
    test "the same row with the post-window live build removed is never_covered — the law above is not vacuous",
         %{site: site} do
      failed_at = DateTime.add(@cov_from, 1_000, :second)

      deployments!(site, [%{status: "failed", inserted_at: failed_at}])

      [_deferred, failed] = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts.cohorts

      assert failed.population == 1
      assert failed.covered == 0
      assert failed.pending == 1
      assert failed.never_covered == 1
      assert failed.too_young == 0

      # And the row is ATTRIBUTED, not just counted. This is the quantity the
      # morning digest renders (dr-w33-s3) and the only discriminating half of
      # the gauge — a never-covered count that cannot say which environment it
      # came from is the anonymity this epic exists to kill.
      assert failed.never_covered_by_environment == [
               %{environment: "production", never_covered: 1}
             ]
    end

    # UNREADABLE ROWS SIT BESIDE BOTH SIDES, never inside either. A row whose
    # box could not be read at write time is not a covered site and it is not a
    # stuck one — folding it into either is the reassuring lie or the
    # manufactured alarm, depending on which way you fold.
    test "an UNREADABLE row is counted beside covered and never_covered, not inside them",
         %{site: site} do
      deployments!(site, [
        %{
          status: "failed",
          content_rev: "",
          inserted_at: DateTime.add(@cov_from, 1_000, :second)
        }
      ])

      [_deferred, failed] = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts.cohorts

      assert failed.population == 1
      assert failed.unreadable == 1
      assert failed.covered == 0
      assert failed.never_covered == 0
      assert failed.pending == 0
      assert failed.covered + failed.pending + failed.unreadable == failed.population
    end

    # A cohort with no rows says NOTHING, and says it in counts. Zero of zero is
    # not full coverage.
    test "an empty cohort reports zeroes and no environment rows", %{site: site} do
      deployments!(site, [
        %{status: "deferred", inserted_at: DateTime.add(@cov_from, 1_000, :second)}
      ])

      [deferred, failed] = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts.cohorts

      assert deferred.population == 1
      assert failed.population == 0
      assert failed.covered == 0
      assert failed.never_covered == 0
      assert failed.never_covered_by_environment == []
      assert failed.oldest_pending_seconds == nil
    end

    # THE NON-ZERO NAMES ITS SITES (dr-w34-s1). A never-covered COUNT tells an
    # operator that something is sitting dark and refuses to say what — and
    # `coverage_cohorts/2` already SELECTED `site_id` and then threw it away in
    # the merge, which is the single omission that made the split buildable by
    # environment and never by site.
    test "the never-covered tail is NAMED — site_id, name, slug and environment, pooled across BOTH cohorts",
         %{site: site, team: team} do
      other = site_fixture(team)
      old = DateTime.add(@cov_to, -172_800, :second)

      # Two production rows on one site, in the FAILED cohort.
      deployments!(site, [
        %{status: "failed", inserted_at: old},
        %{status: "failed", inserted_at: DateTime.add(old, 60, :second)}
      ])

      # …and one preview row on another site, in the DEFERRED cohort. Pooled on
      # purpose: a site is stuck or it is not, and which cohort stranded it is
      # the cohorts' question, not this list's.
      deployments!(other, [
        %{status: "deferred", environment: "preview", inserted_at: old}
      ])

      cohorts = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts

      assert cohorts.never_covered_sites == [
               %{
                 site_id: site.id,
                 name: site.name,
                 slug: site.slug,
                 environment: "production",
                 never_covered: 2
               },
               %{
                 site_id: other.id,
                 name: other.name,
                 slug: other.slug,
                 environment: "preview",
                 never_covered: 1
               }
             ]

      # The list reconciles with the counts it is a naming of: 2 + 1 == the two
      # cohorts' never-covered totals.
      [deferred, failed] = cohorts.cohorts
      assert failed.never_covered == 2
      assert deferred.never_covered == 1
      assert cohorts.never_covered_sites_total == 2
      refute cohorts.never_covered_sites_truncated

      # A row TOO YOUNG to be never-covered is not named either — the list and
      # the count answer to the SAME maturity fence, or the naming would accuse
      # a site the count does not.
      deployments!(site, [%{status: "failed", inserted_at: DateTime.add(@cov_to, -60, :second)}])
      after_young = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts
      assert after_young.never_covered_sites == cohorts.never_covered_sites
    end

    # THE LIST IS A TAIL, AND A TAIL HAS NO NATURAL SIZE. `census/3` learned
    # this for `sites` at :1204 — "a reader who cannot tell a 50-site fleet from
    # the top 50 of a larger one is reading a number with no population" — and a
    # list that cut silently HERE would reproduce the exact anonymity this key
    # exists to kill, one level down.
    test "the named list is BOUNDED and says so, with its unbounded total beside it",
         %{site: site} do
      old = DateTime.add(@cov_to, -172_800, :second)

      # 21 distinct {site_id, environment} groups — the key is the pair, so one
      # site with 21 environments is 21 rows in the tail.
      deployments!(
        site,
        for i <- 1..21 do
          %{
            status: "failed",
            environment: "env-#{String.pad_leading(to_string(i), 2, "0")}",
            inserted_at: DateTime.add(old, i, :second)
          }
        end
      )

      cohorts = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts

      assert length(cohorts.never_covered_sites) == 20
      assert cohorts.never_covered_sites_total == 21
      assert cohorts.never_covered_sites_truncated

      # The cut is on the LIST and never on the COUNT: the cohort still reports
      # all 21 rows, so a truncated naming can never shrink the number it names.
      [_deferred, failed] = cohorts.cohorts
      assert failed.never_covered == 21
    end

    # THE COVERING QUERY'S BOUND, AS A TOKEN — and on the RIGHT NODE.
    test "covering_bound rides on coverage_cohorts and NEVER on the window, which is bounded on both sides",
         %{site: site} do
      deployments!(site, [
        %{status: "failed", inserted_at: DateTime.add(@cov_from, 1_000, :second)}
      ])

      census = DeployLedger.census(@cov_from, @cov_to)

      assert census.coverage_cohorts.covering_bound == "left_only"

      # `census/3`'s window is genuinely half-open [from, to) and bounded on
      # BOTH sides. A bound key there would be a machine-readable falsehood, so
      # the window carries no such key at all.
      assert census.window == %{from: @cov_from, to: @cov_to}

      # And the human sentence still ships beside the token — the prose is what
      # says WHY the bound is one-sided, which a token cannot.
      assert census.coverage_cohorts.basis =~ "bounded on the LEFT only"
    end

    # ONE `as_of` PER ENVELOPE. The operator route builds its body as
    # `census(from, to) |> Map.put(:delivery, delivery(from, to))` — two calls
    # that used to read two different clocks, measured 15.7s apart on the live
    # control plane at `--days 23`. Same window in, one instant out.
    test "coverage_cohorts.as_of and delivery.as_of are the SAME instant — the window's own pinned edge",
         %{site: site} do
      deployments!(site, [
        %{status: "failed", inserted_at: DateTime.add(@cov_from, 1_000, :second)}
      ])

      census = DeployLedger.census(@cov_from, @cov_to)
      delivery = DeployLedger.delivery(@cov_from, @cov_to)

      assert census.coverage_cohorts.as_of == delivery.as_of
      assert census.deferral_wait.as_of == delivery.as_of
      assert delivery.censored.as_of == delivery.as_of
      assert delivery.as_of == @cov_to

      # ON THE WIRE, which is where an operator compares them. Equal instants
      # are not enough: `DateTime.truncate/2` on the window edge would widen
      # "…T00:00:00Z" to "…T00:00:00.000000Z", and a reader diffing two stamps
      # would still see two different strings under one envelope.
      body = Jason.encode!(Map.put(census, :delivery, delivery)) |> Jason.decode!()
      assert body["coverage_cohorts"]["as_of"] == body["delivery"]["as_of"]
      assert body["coverage_cohorts"]["as_of"] == body["window"]["to"]
      assert body["deferral_wait"]["as_of"] == body["delivery"]["censored"]["as_of"]
    end

    # D478'S WORDING FENCE, ON THE WIRE. The key ships COVERAGE and the three
    # sanctioned outcome words; it must never ship a claim that an operator's
    # own edit reached the web. `delivered`, `superseded` and `publish reach`
    # are struck BY NAME, and this asserts against the SERIALIZED node rather
    # than against the source, because the source may discuss the refusal (it
    # does) while the payload may not make it.
    test "the emitted node carries COVERAGE and none of the struck words", %{site: site} do
      measured_partition!(site)

      node = DeployLedger.census(@cov_from, @cov_to).coverage_cohorts
      wire = Jason.encode!(node) |> String.downcase()

      refute wire =~ "delivered"
      refute wire =~ "superseded"
      refute wire =~ "publish reach"

      # And what it DOES say: the site rebuilt, which is a fact about the site.
      assert wire =~ "coverage"
      assert node.basis =~ "THE SITE has since rebuilt"
      assert node.clock =~ "the SAME clock as `deferral_wait`"
    end
  end

  ## ── 4c. THE D8 INVERSION: a new cause must not shrink the abandoned count ──

  describe "abandonment with an unnamed cause — the count can no longer go DOWN" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team)}
    end

    @d8_from ~U[2026-08-01 00:00:00Z]
    @d8_to ~U[2026-08-02 00:00:00Z]

    # The pre-dr-w28-s4 fallthrough, reconstructed AS DATA — the same arm that
    # shipped, so the mutation below is the real one and not a strawman.
    defp pre_w28_class("ABANDONED_UNCLASSIFIED"), do: "UNCLASSIFIED"
    defp pre_w28_class(class), do: class

    test "the abandoned count HOLDS when the box learns a new code word — and used to FALL", %{
      site: site
    } do
      for {reason, i} <- Enum.with_index([@a_capacity, @a_busy, @a_unknown_code]) do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: reason,
          inserted_at: DateTime.add(@d8_from, i + 1, :second)
        })
      end

      counts =
        DeployLedger.census(@d8_from, @d8_to).classes
        |> Map.new(&{&1.class, &1.count})

      abandoned = fn map ->
        map
        |> Enum.filter(fn {class, _} -> String.starts_with?(class, "ABANDONED_") end)
        |> Enum.reduce(0, fn {_, n}, acc -> n + acc end)
      end

      # AFTER: all three abandonments are counted as abandonments, and the one
      # with an unnamed cause says so on its own line.
      assert abandoned.(counts) == 3
      assert counts["ABANDONED_UNCLASSIFIED"] == 1
      refute Map.has_key?(counts, "UNCLASSIFIED")

      # BEFORE, on the identical rows: the new code word walked out of the
      # abandoned cohort and the count FELL to 2 while UNCLASSIFIED rose to 1 —
      # D8 honoured in shape, inverted in effect. An operator reading
      # "abandonments fell" would have been reading a taxonomy gap as a fix.
      before = Map.new(counts, fn {class, n} -> {pre_w28_class(class), n} end)
      assert abandoned.(before) == 2
      assert before["UNCLASSIFIED"] == 1

      # The row is still in the failure numerator either way — the fix moves a
      # LABEL, never a row, so no rate changes underneath it.
      assert DeployLedger.census(@d8_from, @d8_to).failed == 3
    end

    test "the unnamed abandonment is a first-class class, and its label accuses nobody" do
      assert "ABANDONED_UNCLASSIFIED" in DeployLedger.classes()
      refute DeployLedger.deferred?("ABANDONED_UNCLASSIFIED")
      refute DeployLedger.not_attempted?("ABANDONED_UNCLASSIFIED")

      label = DeployLedger.label("ABANDONED_UNCLASSIFIED")
      assert label =~ "given up on"
      assert label =~ "has not named"

      # It is fed EVERY cause the ledger has not learned yet, so it may not
      # claim one — the label gauge's assertion B, restated where it is easy to
      # see. `slot_reservation_denied` is the live example.
      for word <- ~w(slot_reservation capacity cap slots running busy deploying) do
        refute label =~ word
      end
    end
  end

  ## ── 4c. The terminal denominator, and abandonment as an absolute count ───

  describe "census/3 — the rate names its TERMINAL denominator beside itself (dr-w12-s8)" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team)}
    end

    # FIVE windows, one calendar day each, all of them a month clear of
    # `@deferred_status_boundary` (2026-08-05) so nothing here is refused for
    # straddling a vocabulary change. The CONTROL comes first and carries no
    # deferrals at all; the four after it hold failures at 120 and live at 120
    # and move NOTHING but the deferred cohort.
    #
    # That is the whole design: if the published rate falls across rows where
    # the failure count, the success count and every outcome are byte-identical,
    # the fall is not a fleet getting healthier. It is the denominator growing.
    @dil_control {~U[2026-07-01 00:00:00Z], ~U[2026-07-02 00:00:00Z], 0}
    @dil_rising [
      {~U[2026-07-02 00:00:00Z], ~U[2026-07-03 00:00:00Z], 60},
      {~U[2026-07-03 00:00:00Z], ~U[2026-07-04 00:00:00Z], 240},
      {~U[2026-07-04 00:00:00Z], ~U[2026-07-05 00:00:00Z], 760},
      {~U[2026-07-05 00:00:00Z], ~U[2026-07-06 00:00:00Z], 1560}
    ]

    @dil_failed 120
    @dil_live 120

    # HELD CONSTANT, and inserted through `Repo.insert_all` because the smallest
    # window carries 240 rows and the largest 1,800 — 4,860 `Repo.insert!` round
    # trips would be seconds of test time for no extra truth. The failures carry
    # a REAL reason (`@doc_id`), never a nil one: a nil-reason failure is a row
    # the abandonment predicate cannot be run on, and it would land in
    # `abandoned_unreadable` and quietly contaminate the cohort this fixture is
    # not about.
    defp dilution_window!(site, from, deferred) do
      rows =
        Enum.map(1..@dil_failed, fn i ->
          {"failed", "HEALTH", @doc_id, i}
        end) ++
          Enum.map(1..@dil_live, fn i ->
            {"live", nil, nil, 2_000 + i}
          end) ++
          Enum.map(1..deferred//1, fn i ->
            {"deferred", "PLAN", @r409_bare, 20_000 + i}
          end)

      entries =
        Enum.map(rows, fn {status, stage, reason, offset} ->
          at = usec(DateTime.add(from, offset, :second))

          %{
            id: Ecto.UUID.generate(),
            site_id: site.id,
            status: status,
            stage: stage,
            failure_reason: reason,
            environment: "production",
            inserted_at: at,
            updated_at: at
          }
        end)

      Repo.insert_all(Deployment, entries)
    end

    defp dilution_reading!(site, {from, to, deferred}) do
      dilution_window!(site, from, deferred)
      census = DeployLedger.census(from, to)

      %{
        deferred: deferred,
        volume: census.volume,
        failed: census.failed,
        live: census.live,
        deferred_total: census.deferred_total,
        published: census.failure_rate.pct,
        published_sample: census.failure_rate.sample,
        terminal: census.terminal_failure_rate.pct,
        terminal_sample: census.terminal_failure_rate.sample,
        terminal_basis: census.terminal_failure_rate.basis
      }
    end

    defp dilution_series(readings) do
      Enum.map_join(readings, "\n", fn r ->
        "  deferred=#{String.pad_leading(to_string(r.deferred), 5)}  " <>
          "failed=#{r.failed}  live=#{r.live}  " <>
          "published=#{r.published}% of #{r.published_sample} attempted  " <>
          "terminal=#{r.terminal}% of #{r.terminal_sample} terminal"
      end)
    end

    # THE HEADLINE. This is the defect the whole slice exists for, as a
    # measurement rather than as an argument.
    test "the published rate FALLS on rising deferrals while the terminal rate stays FLAT", %{
      site: site
    } do
      control = dilution_reading!(site, @dil_control)
      rising = Enum.map(@dil_rising, &dilution_reading!(site, &1))
      all = [control | rising]

      # THE EVIDENCE, PRINTED. A rate series argued in prose is a rate series
      # nobody can check; this one is on stdout of every green run.
      IO.puts(
        "\n[dr-w12-s8 dilution series] failures and live HELD CONSTANT:\n" <> dilution_series(all)
      )

      # NOTHING MOVED BUT THE DEFERRALS. Asserted, not assumed — a fixture that
      # let `failed` or `live` drift would make the falling rate honest and this
      # whole test vacuous.
      for r <- all do
        assert r.failed == @dil_failed
        assert r.live == @dil_live
        assert r.deferred_total == r.deferred
        assert r.volume == @dil_failed + @dil_live + r.deferred
      end

      # THE CONTROL: with no deferrals the two denominators ARE the same
      # population, so the two rates converge exactly. Any divergence here would
      # mean the terminal rate is measuring something other than what it says.
      assert control.deferred_total == 0
      assert control.published == control.terminal
      assert control.published_sample == control.terminal_sample

      # STRICTLY FALLING, published. Pairwise, so the message names the pair.
      published = Enum.map(rising, & &1.published)

      for {a, b} <- Enum.zip(published, tl(published)) do
        assert b < a,
               "the published rate did not fall from #{a}% to #{b}% — the dilution this " <>
                 "slice measures has stopped happening, and the terminal rate beside it is " <>
                 "answering a question nobody has\n" <> dilution_series(all)
      end

      # FLAT, terminal — the same number in every window, control included,
      # because failures and live never moved.
      assert Enum.uniq(Enum.map(all, & &1.terminal)) == [50.0]

      # …and the two are the SAME arithmetic where the cohorts agree, so the
      # terminal rate is not a second, drifting definition of failure.
      assert control.terminal == 50.0

      # THE GAP IS THE DEFERRAL MASS, said on the wire. `basis` is what stops a
      # reader taking the smaller number for the better one.
      assert List.last(rising).published < 10.0
      assert List.last(rising).terminal == 50.0
      assert List.last(rising).terminal_basis =~ "TERMINAL rows only: failed + live"

      assert DeployLedger.census(@dil_control |> elem(0), @dil_control |> elem(1)).failure_rate.basis =~
               "attempted rows in the window"
    end

    # THE PER-SITE TWIN. A fleet pair with no per-site pair sends the reader who
    # asks "which site?" straight back to the diluted number.
    test "the per-site row carries the same pair, and its two rates differ by that site's deferrals",
         %{site: site} do
      {from, to, deferred} = {~U[2026-07-08 00:00:00Z], ~U[2026-07-09 00:00:00Z], 760}
      dilution_window!(site, from, deferred)

      assert [row] = DeployLedger.census(from, to).sites

      assert row.failed == @dil_failed
      assert row.live == @dil_live
      assert row.deferred == deferred
      assert row.volume == @dil_failed + @dil_live + deferred

      assert row.failure_rate.pct == 12.0
      assert row.failure_rate.sample == @dil_failed + @dil_live + deferred
      assert row.terminal_failure_rate.pct == 50.0
      assert row.terminal_failure_rate.sample == @dil_failed + @dil_live
      assert row.terminal_failure_rate.basis =~ "TERMINAL rows only: failed + live"

      # The two denominators differ by EXACTLY the deferrals, which is the one
      # relationship a reader has to be able to reconstruct.
      assert row.failure_rate.sample - row.terminal_failure_rate.sample == row.deferred
    end

    # THE ADDITION IS ADDITIVE, asserted rather than trusted. D9's ruling is that
    # a deferral is RELOCATED, never deleted — so `volume` must still count it
    # and `failure_rate` must be byte-identical to what it was before this slice.
    test "volume still counts deferrals and the published rate is untouched", %{site: site} do
      {from, to, deferred} = {~U[2026-07-10 00:00:00Z], ~U[2026-07-11 00:00:00Z], 240}
      dilution_window!(site, from, deferred)
      census = DeployLedger.census(from, to)

      assert census.volume == @dil_failed + @dil_live + deferred
      assert census.failure_rate.sample == census.volume
      assert census.failure_rate.basis =~ "failed + deferred + live"
      assert census.deferred_total == deferred

      # The deferrals are still on their own line, with their share over the
      # ATTEMPTED population — untouched by the new key beside them.
      assert [%{class: "BOX_BUSY_DEFERRED", count: ^deferred}] =
               Enum.map(census.deferred, &Map.take(&1, [:class, :count]))
    end

    ## ── Abandonment: an absolute count, with its own blind spot beside it ──

    @ab_from ~U[2026-07-15 00:00:00Z]
    @ab_to ~U[2026-07-16 00:00:00Z]

    # THE BOX'S OWN REFUSAL LINES, DERIVED from the deferred corpus above by
    # stripping the shared re-queue clause — never re-typed. The abandonment
    # sentence and the deferral sentence are the SAME box refusal with different
    # tails, and typing the head twice is how the two corpora drift apart.
    @fence_capacity String.replace_suffix(@d_capacity, @requeued, "")
    @fence_busy @r409_coded
    @fence_bare @r409_bare
    @fence_unknown String.replace_suffix(@d_unknown_code, @requeued, "")

    # THE FENCE FIRING, BUILT THROUGH THE PUBLIC PRODUCER. `abandonment_reason/3`
    # is the only place in the tree that writes the terminal sentence, and the
    # classifier's only handle on an abandoned row is that prose — so a fixture
    # built from a literal would keep passing through a reword that silently
    # degraded every abandoned row back to `BOX_BUSY_409`.
    defp fence_firing!(site, cause_line, rounds, offset) do
      cause =
        DeployLedger.classify(%{status: "deferred", stage: "PLAN", failure_reason: cause_line})

      deployment!(site, %{
        stage: "PLAN",
        failure_reason: Deploy.abandonment_reason(cause_line, rounds, cause),
        inserted_at: DateTime.add(@ab_from, offset, :second)
      })
    end

    test "a fence firing MOVES the abandonment count, and it is a COUNT and not a rate", %{
      site: site
    } do
      # BEFORE: ordinary failures and deferrals, no chain terminal anywhere.
      for i <- 1..6 do
        deployment!(site, %{
          stage: "HEALTH",
          failure_reason: @doc_id,
          inserted_at: DateTime.add(@ab_from, i, :second)
        })
      end

      before = DeployLedger.census(@ab_from, @ab_to)

      assert before.abandoned == 0
      # A REAL ZERO, and it says so: nothing here was illegible.
      assert before.abandoned_unreadable == 0

      # THE FIRINGS — one per shape the box actually sends, each a publish given
      # up on after its chain hit the bound.
      fence_firing!(site, @fence_capacity, 12, 100)
      fence_firing!(site, @fence_busy, 6, 200)
      fence_firing!(site, @fence_bare, 6, 300)

      after_firing = DeployLedger.census(@ab_from, @ab_to)

      IO.puts(
        "\n[dr-w12-s8 abandonment] count moved #{before.abandoned} -> #{after_firing.abandoned} " <>
          "(unreadable #{before.abandoned_unreadable} -> #{after_firing.abandoned_unreadable}, " <>
          "failed #{before.failed} -> #{after_firing.failed})"
      )

      # IT MOVED, and by the number of publishes that were abandoned.
      assert after_firing.abandoned == 3
      assert after_firing.abandoned > before.abandoned

      # Each firing landed in the failure numerator too — a given-up publish IS a
      # failure. The COUNT is the crown because it is the one quantity a bucket
      # swap cannot touch: three publishes are gone whatever the fleet relabels.
      assert after_firing.failed == before.failed + 3

      # AND IT IS A COUNT. No abandonment RATE is emitted anywhere — D142's
      # refusal, as a property of the payload rather than as a promise.
      refute Map.has_key?(after_firing, :abandonment_rate)
      refute Map.has_key?(after_firing, :abandoned_rate)
      assert is_integer(after_firing.abandoned)
    end

    # THE ARM THE WHOLE EPIC KEEPS RE-LEARNING: absent and zero are different
    # worlds. A failed row that recorded no reason at all cannot be TESTED for
    # abandonment — the marker is prose in `failure_reason` — so the predicate
    # does not answer "no", it does not run. If that row were counted as "not
    # abandoned", the count would be a confident understatement with nothing
    # anywhere saying so.
    test "an illegible failed row raises `abandoned_unreadable`, never lowers `abandoned`", %{
      site: site
    } do
      fence_firing!(site, @fence_capacity, 12, 10)

      legible = DeployLedger.census(@ab_from, @ab_to)
      assert legible.abandoned == 1
      assert legible.abandoned_unreadable == 0

      # Four failed rows with NOTHING recorded about why.
      for i <- 1..4 do
        deployment!(site, %{
          stage: nil,
          failure_reason: nil,
          inserted_at: DateTime.add(@ab_from, 500 + i, :second)
        })
      end

      blinded = DeployLedger.census(@ab_from, @ab_to)

      # THE COUNT DOES NOT MOVE — those rows said nothing, so they are not
      # evidence of an abandonment and they are not evidence against one.
      assert blinded.abandoned == 1
      # …and the size of the blind spot is on the wire beside it, so `1` reads as
      # "at least 1" rather than as "exactly 1".
      assert blinded.abandoned_unreadable == 4

      # The distinction this pair exists for, stated as the three-way it is:
      #   0 / 0  — none happened
      #   0 / N  — nothing legible said so; 0 is a LOWER BOUND
      # (the third, "the control plane does not count them at all", is the Go
      # pointer's nil and is asserted in internal/cli's own suite.)
      empty = DeployLedger.census(~U[2026-07-20 00:00:00Z], ~U[2026-07-21 00:00:00Z])
      assert empty.abandoned == 0
      assert empty.abandoned_unreadable == 0

      refute {blinded.abandoned, blinded.abandoned_unreadable} ==
               {empty.abandoned, empty.abandoned_unreadable}
    end

    # THE COHORT IS DERIVED, NOT HAND-LISTED — and this is what proves the
    # derivation covers the producer. A fourth `ABANDONED_*` class minted by
    # `abandoned_class/1` and forgotten in a hand-list would make the count FALL
    # while the fleet abandoned more, which is the inversion `abandoned_class/1`
    # was itself fixed to refuse.
    test "every class the abandonment producer can mint is INSIDE the count", %{site: site} do
      lines = [@fence_capacity, @fence_busy, @fence_bare, @fence_unknown]

      minted =
        for {line, i} <- Enum.with_index(lines) do
          fence_firing!(site, line, 12, 1_000 + i * 10)

          cause =
            DeployLedger.classify(%{status: "deferred", stage: "PLAN", failure_reason: line})

          DeployLedger.classify("PLAN", Deploy.abandonment_reason(line, 12, cause))
        end

      # The producer really does mint more than one class here, or this test
      # would be a green that proves nothing.
      assert length(Enum.uniq(minted)) >= 3

      census = DeployLedger.census(@ab_from, @ab_to)

      # EVERY minted class is in the count, and the count is exactly their sum —
      # so a class that fell out of the cohort reds here rather than shrinking a
      # number nobody is watching.
      counted =
        census.classes
        |> Enum.filter(&(&1.class in minted))
        |> Enum.reduce(0, fn c, acc -> acc + c.count end)

      assert counted == length(lines)
      assert census.abandoned == length(lines)
    end
  end

  ## ── 5. The delivery clock ────────────────────────────────────────────────

  describe "delivery/3 — a percentile that can refuse, and a cohort still waiting" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team)}
    end

    test "every percentile node is INSEPARABLE: value, window width, sample and censored count in ONE map",
         %{site: site} do
      delivery_40pct!(site)
      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      assert d.window.width_seconds == 86_400
      assert d.sample == 1000

      for node <- [d.p50, d.p95, d.max] do
        # No caller can lift the number out of the map and leave the population
        # behind: the width, the denominator and the still-waiting count are IN
        # the same node as `seconds`.
        assert node.window_seconds == 86_400
        assert node.sample == 1000
        assert node.censored == 400
        assert node.censored_fraction == 0.4
        assert node.basis =~ "floored"
        assert Map.has_key?(node, :seconds)
      end
    end

    test "p95 REFUSES an unidentifiable percentile — 40% still waiting exceeds its 5% headroom",
         %{site: site} do
      delivery_40pct!(site)
      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      assert d.p95.refused
      assert d.p95.seconds == nil
      assert d.p95.headroom == 0.05

      assert d.p95.reason ==
               "p95 is UNIDENTIFIABLE: 40.0% are still waiting, exceeding the 5.0% headroom p95 needs"

      # THE STEP FUNCTION AT 1 - q. p50 needs 50% of headroom and has it, so it
      # answers — with a floored number. The refusal is about identifiability,
      # not about the window being wide or the sample being small: n = 1,000,
      # ten times min_sample, and the same window answers p50.
      refute d.p50.refused
      assert d.p50.seconds > 0
      assert d.p50.sample == 1000
    end

    test "MUTATION: dropping the still-waiting rows publishes a confident number where the guard refuses",
         %{site: site} do
      delivery_40pct!(site)
      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      {delivered, waiting} = delivery_40pct_seconds()
      all = delivered ++ waiting

      # What the DROPPER would publish, off the same corpus.
      drop_p95 = drop_quantile(delivered, 0.95)
      drop_p50 = drop_quantile(delivered, 0.5)
      floor_p95 = floor_quantile(all, 0.95)
      floor_p50 = floor_quantile(all, 0.5)

      # The dropper is not merely wrong — it is CONFIDENT: it has a number for
      # the very quantile the guard says nobody can know.
      assert drop_p95 == 87.0
      assert floor_p95 == 76_349.0
      assert Float.round(floor_p95 / drop_p95, 1) == 877.6

      # …and it CANNOT be caught by watching p50: below 50% censoring the two
      # estimators land in the same delivered mass, so the divergence is a step
      # function at exactly 1 - q. A fixture aimed at p50 could never satisfy a
      # >10x spec.
      assert drop_p50 == 60.0
      assert floor_p50 == 80.0
      assert Float.round(floor_p50 / drop_p50, 2) == 1.33

      # THE STRUCTURAL TELL, asserted separately from the reason string: a
      # dropping estimator's own SAMPLE shrinks to the delivered rows. The
      # refusal string could be faked; a sample of 1,000 with 400 censored
      # cannot be, and this assertion is what fails when the estimator is
      # mutated to drop.
      assert d.p95.sample == 1000
      assert d.p95.censored == 400
      assert d.p95.refused
      assert length(delivered) == 600
      assert d.p95.sample != length(delivered)
    end

    test "FLOOR NEVER DROP: a still-waiting row contributes its lower bound and moves the quantile position",
         %{site: site} do
      # 800 delivered with distinct waits 1s..800s, then 200 still waiting with
      # bounds far above them. 20% censored — inside p50's 50% headroom, so p50
      # ANSWERS, and the answer proves the censored rows are in the sample.
      delivered =
        for i <- 1..800 do
          at = DateTime.add(@dw_from, i, :second)
          %{status: "live", inserted_at: at, became_live_at: DateTime.add(at, i, :second)}
        end

      waiting =
        for i <- 1..200 do
          %{status: "failed", inserted_at: DateTime.add(@dw_from, 5_000 + i, :second)}
        end

      deployments!(site, delivered ++ waiting)
      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      refute d.p50.refused
      assert d.p50.sample == 1000
      assert d.p50.censored == 200
      # Position 500 of 1,000 — the 500th delivered wait. A dropping estimator
      # would take position 400 of 800 and answer 400.0s, 20% lower, off a
      # corpus where one row in five has not been delivered at all.
      assert d.p50.seconds == 500.0
      assert drop_quantile(Enum.sort(for(i <- 1..800, do: i * 1.0)), 0.5) == 400.0

      # The lower bounds themselves are real seconds, not zeros: as_of is
      # 86,400s into the window and the oldest waiter arrived at 5,001s.
      assert d.censored.count == 200
      assert d.censored.as_of == @dw_as_of
      assert d.censored.still_waiting_at_least_seconds == 81_399.0
    end

    test "max refuses while ANYONE is still waiting, and the cohort says how long, as of when",
         %{site: site} do
      delivery_40pct!(site)
      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      # max is q = 1.0: its headroom is zero, so a single unfinished row makes
      # the maximum unknowable. The honest answer is the still-waiting bound.
      assert d.max.refused
      assert d.max.reason =~ "UNIDENTIFIABLE"
      assert d.censored.count == 400
      assert d.censored.still_waiting_at_least_seconds == 76_399.0
      assert d.censored.as_of == @dw_as_of

      # Never a bare zero: the count travels with the instant it was taken.
      site_row = Enum.find(d.sites, &(&1.site_id == site.id))
      assert site_row.still_waiting
      assert site_row.oldest_waiting_seconds == 76_399.0
      assert site_row.as_of == @dw_as_of
    end

    test "production only, and rows the clock cannot reach are UNMETERED — never filtered away",
         %{site: site} do
      {_user, team} = user_team()
      jarl = site_fixture(team)

      # The jarl-website shape: live deliveries, ZERO non-null content_rev. A
      # census keyed on the revision would omit this customer site entirely;
      # keying on the deployment ROW keeps it visible.
      deployments!(jarl, [
        %{
          status: "live",
          content_rev: nil,
          inserted_at: DateTime.add(@dw_from, 10, :second),
          became_live_at: DateTime.add(@dw_from, 70, :second)
        },
        %{status: "failed", content_rev: nil, inserted_at: DateTime.add(@dw_from, 80, :second)},
        %{
          status: "live",
          content_rev: nil,
          inserted_at: DateTime.add(@dw_from, 90, :second),
          became_live_at: DateTime.add(@dw_from, 150, :second)
        }
      ])

      deployments!(site, [
        # A preview row: out of scope, and it must not enter any denominator.
        %{
          status: "live",
          environment: "preview",
          inserted_at: DateTime.add(@dw_from, 10, :second),
          became_live_at: DateTime.add(@dw_from, 20, :second)
        },
        # A row OUTSIDE the pinned window.
        %{status: "failed", inserted_at: DateTime.add(@dw_to, 10, :second)},
        # UNKEYABLE: live, but the ledger cannot name when it went live. Counted
        # and reported — never a WHERE clause.
        %{status: "live", became_live_at: nil, inserted_at: DateTime.add(@dw_from, 30, :second)},
        %{
          status: "live",
          inserted_at: DateTime.add(@dw_from, 40, :second),
          became_live_at: DateTime.add(@dw_from, 100, :second)
        }
      ])

      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      assert d.environment == "production"
      # 3 jarl rows + 1 in-window production row with a live mark = 4 metered;
      # the preview row and the out-of-window row are out of scope entirely.
      assert d.sample == 4
      assert d.unmetered == 1

      ids = Enum.map(d.sites, & &1.site_id)
      assert jarl.id in ids, "a site with live deliveries and no content_rev must still appear"
      assert site.id in ids

      jarl_row = Enum.find(d.sites, &(&1.site_id == jarl.id))
      assert jarl_row.sample == 3
      # The failed attempt is DELIVERED by the site's next live mark (60s later),
      # not dropped and not counted as zero.
      assert jarl_row.delivered == 3
      refute jarl_row.still_waiting
      assert jarl_row.oldest_waiting_seconds == nil

      site_row = Enum.find(d.sites, &(&1.site_id == site.id))
      assert site_row.sample == 1
      assert site_row.unmetered == 1

      # Under min_sample, so every quantile refuses on the SAMPLE — the first
      # policy, still carrying its denominator.
      assert d.p50.refused
      assert d.p50.reason == "sample 4 below min_sample 200"
    end

    test "the failed row's wait is the site's NEXT live mark, not zero", %{site: site} do
      # D142 reports 0.0s for site d8e9c2c7's 6h17m outage because a failed row
      # CLOSES a run. Here the failed attempt waits until content actually
      # reached the web — one long wait, not 80 singletons at 0.0s.
      deployments!(site, [
        %{status: "failed", inserted_at: DateTime.add(@dw_from, 100, :second)},
        %{status: "failed", inserted_at: DateTime.add(@dw_from, 200, :second)},
        %{
          status: "live",
          inserted_at: DateTime.add(@dw_from, 300, :second),
          became_live_at: DateTime.add(@dw_from, 22_938, :second)
        }
      ])

      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      assert d.sample == 3
      assert d.censored.count == 0
      # The floored max would be 22,838s (the first failed attempt's wait) — but
      # every row is delivered here, so nothing is censored and the refusal is
      # the sample policy alone.
      assert d.max.refused
      assert d.max.reason =~ "below min_sample"
      assert d.sites |> hd() |> Map.get(:delivered) == 3
    end

    test "THE THIRD REFUSAL FIRES ALONE: the row AT the quantile is itself still waiting",
         %{site: site} do
      # The two headline fixtures both trip the censored-fraction policy first, so
      # the empirical policy — "the row at ceil(n*q) is itself censored" — was
      # implemented, reachable, and never actually exercised. It is the arm that
      # survives when the fraction test AGREES the sample is identifiable, which is
      # exactly the case a future re-key onto the publish clock will produce, so it
      # must not merge unproven.
      #
      # The construction: 200 rows (min_sample passes), only TWO still waiting
      # (1.0% against p50's 50.0% headroom, so the fraction policy does NOT fire) —
      # but their bounds sit at 100s and 101s, right where p50 lands, because the
      # censored rows here are SHORT waits rather than the long tail. Sorted
      # ascending the 100th of 200 is a censored 100.0s.
      delivered =
        for i <- 1..198 do
          at = DateTime.add(@dw_from, i, :second)
          wait = if i <= 99, do: i, else: 101 + i

          %{status: "live", inserted_at: at, became_live_at: DateTime.add(at, wait, :second)}
        end

      # as_of - inserted_at = 100s and 101s. Inserted last, after every live mark,
      # so nothing can resolve them.
      waiting =
        for bound <- [100, 101] do
          %{status: "failed", inserted_at: DateTime.add(@dw_as_of, -bound, :second)}
        end

      deployments!(site, delivered ++ waiting)

      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      assert d.sample == 200
      assert d.censored.count == 2

      # The fraction policy is SATISFIED — this is not the arm under test.
      assert d.p50.censored_fraction == 0.01
      assert d.p50.headroom == 0.5
      refute d.p50.reason =~ "UNIDENTIFIABLE"

      # …and p50 still refuses, on the empirical policy alone, naming the position
      # and the lower bound rather than printing the 100s it cannot vouch for.
      assert d.p50.refused
      assert is_nil(d.p50.seconds)
      assert d.p50.reason =~ "lands ON a still-waiting row (position 100 of 200)"
      assert d.p50.reason =~ "at least 100.0s"
    end

    test "the emitted key set is PINNED — the Go reader decodes every key", %{site: site} do
      delivery_40pct!(site)
      d = DeployLedger.delivery(@dw_from, @dw_to, as_of: @dw_as_of)

      assert Enum.sort(Map.keys(d)) == [
               :as_of,
               :censored,
               :clock,
               :delivered,
               :environment,
               :max,
               :min_sample,
               :p50,
               :p95,
               :sample,
               :sites,
               :total_sites,
               :truncated,
               :unmetered,
               :window
             ]

      assert Enum.sort(Map.keys(d.window)) == [:from, :to, :width_seconds]
      assert Enum.sort(Map.keys(d.censored)) == [:as_of, :count, :still_waiting_at_least_seconds]

      assert Enum.sort(Map.keys(d.p95)) == [
               :basis,
               :censored,
               :censored_fraction,
               :headroom,
               :label,
               :min_sample,
               :quantile,
               :reason,
               :refused,
               :sample,
               :seconds,
               :window_seconds
             ]

      assert Enum.sort(Map.keys(hd(d.sites))) == [
               :as_of,
               :censored,
               :delivered,
               :oldest_waiting_seconds,
               :sample,
               :site_id,
               :still_waiting,
               :unmetered
             ]

      # The clock NAMES itself in the payload — a latency number whose t0 is not
      # printed beside it cannot be audited.
      assert d.clock =~ "inserted_at"
      assert d.clock =~ "became_live_at"
    end
  end

  describe "parse_window/2 — the window is required, never floating" do
    test "both bounds required" do
      assert {:error, detail} = DeployLedger.parse_window(nil, "2026-08-01")
      assert detail =~ "from is required"
      assert {:error, detail} = DeployLedger.parse_window("2026-08-01", nil)
      assert detail =~ "to is required"
    end

    test "accepts a bare date or a full instant, and rejects an inverted window" do
      assert {:ok, ~U[2026-07-26 00:00:00Z], ~U[2026-08-06 00:00:00Z]} =
               DeployLedger.parse_window("2026-07-26", "2026-08-06")

      assert {:ok, ~U[2026-07-26 12:30:00Z], _} =
               DeployLedger.parse_window("2026-07-26T12:30:00Z", "2026-08-06")

      assert {:error, "from must be earlier than to"} =
               DeployLedger.parse_window("2026-08-06", "2026-07-26")

      assert {:error, detail} = DeployLedger.parse_window("last tuesday", "2026-08-06")
      assert detail =~ "ISO-8601"
    end
  end

  ## ── 3. The cursor ────────────────────────────────────────────────────────

  describe "list_page/2 — reading past the 200-row cap" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      base = ~U[2026-08-01 00:00:00Z]

      # 250 rows: more than the hard cap, so the second page is only reachable
      # with a cursor. Newest is i = 250.
      for i <- 1..250 do
        deployment!(site, %{
          stage: "PLAN",
          git_ref: "ref-#{i}",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      %{user: user, site: site}
    end

    test "two pages, non-overlapping, covering all 250 rows", %{site: site} do
      assert {:ok, %{deployments: page1, next_cursor: cursor}} =
               DeployLedger.list_page(site, limit: 200)

      assert length(page1) == 200
      assert cursor

      assert {:ok, %{deployments: page2, next_cursor: nil}} =
               DeployLedger.list_page(site, limit: 200, before: cursor)

      assert length(page2) == 50

      refs1 = Enum.map(page1, & &1.git_ref)
      refs2 = Enum.map(page2, & &1.git_ref)

      # NON-overlapping (the `?offset=200` bug returned page one again) …
      assert MapSet.disjoint?(MapSet.new(refs1), MapSet.new(refs2))
      # … and COMPLETE: every row is reachable.
      assert length(Enum.uniq(refs1 ++ refs2)) == 250
      # Newest-first is preserved across the page boundary.
      assert hd(refs1) == "ref-250"
      assert List.last(refs2) == "ref-1"
    end

    test "the last page hands back no cursor even when it is exactly `limit` long", %{site: site} do
      # 250 rows, two pages of exactly 125. The second page is EXACTLY `limit`
      # long, which is the case a naive `length(page) == limit` cursor rule gets
      # wrong — it hands back a cursor to an empty page.
      assert {:ok, %{deployments: page1, next_cursor: cursor}} =
               DeployLedger.list_page(site, limit: 125)

      assert length(page1) == 125
      assert cursor

      assert {:ok, %{deployments: page2, next_cursor: nil}} =
               DeployLedger.list_page(site, limit: 125, before: cursor)

      assert length(page2) == 125
    end

    test "a garbage cursor is an error, never a silent page one", %{site: site} do
      assert {:error, :invalid_cursor} = DeployLedger.list_page(site, before: "not-a-cursor")
      assert :error = DeployLedger.decode_cursor("!!!!")
      assert {:ok, nil} = DeployLedger.decode_cursor(nil)
    end

    test "limit is clamped to the 200 cap", %{site: site} do
      assert {:ok, %{deployments: rows}} = DeployLedger.list_page(site, limit: 5000)
      assert length(rows) == 200
    end
  end

  ## ── 4. The routes ────────────────────────────────────────────────────────

  describe "GET /v1/sites/:id/deployments — the cursor over HTTP" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      %{user: user, site: site, token: login_token(user)}
    end

    test "?before= walks past 200 rows", %{site: site, token: token} do
      base = ~U[2026-08-01 00:00:00Z]

      for i <- 1..250 do
        deployment!(site, %{
          stage: "PLAN",
          git_ref: "ref-#{i}",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      conn = call(:get, "/v1/sites/#{site.id}/deployments?limit=200", token)
      assert conn.status == 200
      body1 = json_body(conn)
      assert length(body1["deployments"]) == 200
      cursor = body1["next_cursor"]
      assert is_binary(cursor)

      conn2 = call(:get, "/v1/sites/#{site.id}/deployments?limit=200&before=#{cursor}", token)
      assert conn2.status == 200
      body2 = json_body(conn2)
      assert length(body2["deployments"]) == 50
      assert body2["next_cursor"] == nil

      ids1 = MapSet.new(body1["deployments"], & &1["id"])
      ids2 = MapSet.new(body2["deployments"], & &1["id"])
      assert MapSet.disjoint?(ids1, ids2)
      assert MapSet.size(MapSet.union(ids1, ids2)) == 250
    end

    test "a garbage cursor is 422, not a silent first page", %{site: site, token: token} do
      deployment!(site, %{stage: "PLAN", failure_reason: @r409_bare})
      conn = call(:get, "/v1/sites/#{site.id}/deployments?before=zzz!!", token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_cursor"
    end
  end

  describe "deployment_json/1 — the honest payload" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      %{site: site, token: login_token(user)}
    end

    test "emits stage + failure_class, and a RAW reason that is scrubbed AND ANSI-free", %{
      site: site,
      token: token
    } do
      # A real astro BUILD-exit-12 capture (0x1B bytes) with a credential spliced
      # into it — the two hazards this field must survive at once.
      reason = @build_403 <> " (authorization: Bearer sk-live-AbC123dEf456GhI789jkl)"
      deployment!(site, %{stage: "BUILD", failure_reason: reason})

      conn = call(:get, "/v1/sites/#{site.id}/deployments", token)
      assert conn.status == 200
      [row] = json_body(conn)["deployments"]

      assert row["stage"] == "BUILD"
      assert row["failure_class"] == "FORBIDDEN_403"

      raw = row["failure_reason_raw"]
      # RAW of the REWRITE, not raw of the SECRETS: the box's own words survive…
      assert raw =~ "graph corpus fetch failed: 403"
      # …the credential does not…
      refute raw =~ "sk-live-AbC123dEf456GhI789jkl"
      assert raw =~ "[redacted]"
      # …and no ESC byte reaches the screen, in either field.
      refute String.contains?(raw, "\e")
      refute String.contains?(row["failure_reason"], "\e")
    end

    test "failure_class is nil on a row that did not fail", %{site: site, token: token} do
      deployment!(site, %{status: "live", stage: "SWITCH", failure_reason: nil})

      conn = call(:get, "/v1/sites/#{site.id}/deployments", token)
      [row] = json_body(conn)["deployments"]

      assert row["failure_class"] == nil
      assert row["failure_reason_raw"] == nil
    end
  end

  describe "GET /v1/operator/deploy-ledger/census — the cross-site read" do
    setup do
      prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
      on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)

      {user, team} = user_team()
      site = site_fixture(team)
      %{user: user, team: team, site: site}
    end

    test "no session → 401; a non-operator session → 403", %{user: user} do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [])

      conn =
        conn(:get, "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-06")
        |> Router.call(@opts)

      assert conn.status == 401

      conn =
        call(
          :get,
          "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-06",
          login_token(user)
        )

      assert conn.status == 403
    end

    # The window ends BEFORE the refusal-vocabulary boundary (2026-08-05
    # 21:13:50Z) on purpose: a window that straddles it gets a REFUSAL node for
    # `classes` instead of a list, which is the correct answer and is asserted
    # in its own test. Reading class counts here requires a window whose rows
    # were all labelled by one taxonomy.
    test "an operator gets counts per class and per site in ONE call", %{user: user, site: site} do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
      base = ~U[2026-07-26 00:00:00Z]

      for i <- 1..3 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      conn =
        call(
          :get,
          "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-05",
          login_token(user)
        )

      assert conn.status == 200
      body = json_body(conn)

      assert body["volume"] == 3
      assert body["failed"] == 3
      # Three rows is not a rate, and the payload says so rather than printing 100%.
      assert body["failure_rate"]["pct"] == nil
      assert body["failure_rate"]["refused"] == true
      assert body["failure_rate"]["sample"] == 3
      assert body["min_sample"] == DeployLedger.min_sample()

      assert [%{"class" => "BOX_BUSY_409", "count" => 3}] =
               Enum.map(body["classes"], &Map.take(&1, ["class", "count"]))

      assert [%{"site_id" => sid, "volume" => 3}] =
               Enum.map(body["sites"], &Map.take(&1, ["site_id", "volume"]))

      assert sid == site.id
      assert body["window"]["from"] =~ "2026-07-26"
    end

    test "a missing window is 422 — there is no default", %{user: user} do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])

      conn = call(:get, "/v1/operator/deploy-ledger/census", login_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_window"
      assert json_body(conn)["detail"] =~ "pinned, never floating"
    end
  end
end
