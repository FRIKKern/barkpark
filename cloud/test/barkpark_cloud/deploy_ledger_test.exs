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
      # never named rises in the tail rather than joining the nearer bucket.
      assert DeployLedger.classify("PLAN", @a_unknown_code) == "UNCLASSIFIED"
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
      "a cause the box DID author (its runner would not spawn), but it arrives on a 500 at the poll phase and folds into BOX_500 with the authorless crash. Naming it in that label would put a specific accusation on rows that mostly are not it. Silent, not wrong — and now written down rather than accidental."
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
    "runner_start_failed" => ~w(spawn start)
  }

  # The producer's own test file, read at runtime. See (a).
  @producer_test "test/barkpark_cloud/sites_deploy_test.exs"
  # `Sites.Deploy.refusal_detail/1` only ever emits a bare snake_case token as a
  # code (`@code_token` in the classifier), so `E_NO_INDEX` — which the producer
  # test also programs — is a MESSAGE-shaped envelope code, not a cause word the
  # taxonomy can key on. The shape is what excludes it, not a skip list.
  @producer_code ~r/"code" => "([a-z][a-z0-9_]*)"/

  # The (phase, status) shapes the producer can actually write. See (b).
  @probe_matrix [
    {:start, 503},
    {:start, 500},
    {:start, 429},
    {:start, 404},
    {:poll, 500},
    {:poll, 503},
    {:abandoned, 409},
    {:deferred, 409}
  ]

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
               ["internal_error", "runner_start_failed"]

      for {word, reason} <- @deliberately_unnamed do
        assert is_binary(reason) and String.length(reason) > 40,
               "#{word} is declared unnamed with no reason — that is not a decision"
      end

      # The declaration is LOAD-BEARING: without it, A reds on both words.
      undeclared = naming_violations(probe_vocabulary(), &DeployLedger.label/1, %{})
      assert Enum.any?(undeclared, &(&1 =~ "internal_error"))
      assert Enum.any?(undeclared, &(&1 =~ "runner_start_failed"))
      # …and the two words are the ONLY silences on this tree — a count would
      # also red for any OTHER violation, which is not what this test is about,
      # so it names them instead.
      assert Enum.all?(
               undeclared,
               &(&1 =~ "internal_error" or &1 =~ "runner_start_failed" or
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

  # class => the set of code words the PRODUCER can drive into it.
  defp probe_vocabulary do
    words = producer_vocabulary()

    for {phase, status} <- @probe_matrix, word <- words, reduce: %{} do
      acc ->
        Map.update(acc, class_of(phase, status, word), MapSet.new([word]), &MapSet.put(&1, word))
    end
  end

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
          "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-06",
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
