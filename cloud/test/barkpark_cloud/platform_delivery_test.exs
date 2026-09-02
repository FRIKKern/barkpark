defmodule BarkparkCloud.PlatformDeliveryTest do
  @moduledoc """
  dr-w23-s2 — THE CROWN, CLOUD HALF: the platform's first durable memory of its
  own deploys, written by a machine and readable by a human.

  Everything here is driven through the REAL router (`Router.call/2`) and
  asserted over the RENDERED response bytes, never over the plug list: a test
  that reads "`require_worker` appears above this route" is green against a route
  whose guard result is discarded. The two halves of this slice are different
  credentials ON PURPOSE — the recorder is worker-token ONLY (machine-only: a PAT
  and a session are both refused it) and the reader is the wider disjunction
  session-OR-PAT-OR-worker — and that asymmetry is exactly what is pinned below.

  THE READER ADMITS THE WORKER (task-e2acb66e9ed0da09), reversing the pin
  task-f7decfcd5fa0eba8 left in §4. The reversal's whole argument, and the clamp
  that bounds it, are written out at that test — read it before touching either
  side of the split.

  The load-bearing guards, each of which is RED against a plausible mistake:

    * THE KEY. Two rows with the same `sha` and `first_seen_at` but different
      `delivering_run_id` BOTH persist. Narrow the unique index to
      `(sha, first_seen_at)` and this file goes red twice — once on the row
      count, once on the index definition read back out of `pg_indexes`.
    * THE CREDENTIAL SPLIT. A PAT is refused by the recorder and admitted by the
      reader; an unauthenticated call is refused by both.
    * THE MISSING TABLE. The table is DROPPED inside the test's own sandboxed
      transaction and both routes answer a typed 503 — the api-only-merge case,
      which is real (deploy.yml's instance job does not require the `cloud/**`
      merge that carries the migration) and which must never be a 500 or a
      silent success.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.PlatformDelivery
  alias BarkparkCloud.RouterTierLens
  alias BarkparkCloud.Web.Auth
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @worker_token "worker-token-test-fixed"
  @password "correct-horse-battery"

  @sha "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

  ## Fixtures

  defp user_with_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "deliveries-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    {user, team}
  end

  defp pat(user, team, abilities) do
    {:ok, token, _stored} =
      Accounts.create_personal_access_token(user, team, %{
        name: "deliveries-#{System.unique_integer([:positive])}",
        abilities: abilities
      })

    token
  end

  defp session(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          method
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn =
      case token do
        nil -> conn
        t -> put_req_header(conn, "authorization", "Bearer " <> t)
      end

    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "sha" => @sha,
        "delivering_run_id" => "17000000001",
        "first_seen_at" => "2026-08-08T10:00:00.000000Z",
        "merged_at" => "2026-08-08T09:58:00.000000Z",
        "queued_seconds" => 42,
        "build_seconds" => 310,
        "serving_since" => "2026-08-08T10:06:00.000000Z",
        "target" => "cp",
        "carried" => false
      },
      overrides
    )
  end

  ## 1. The table and the schema

  describe "the table" do
    test "platform_deliveries exists as its OWN table, not a row in deployments" do
      # The decisive argument for a separate table, asserted rather than
      # remembered: `deployments.site_id` is NOT NULL with an FK to `sites`, and
      # a platform self-deploy has no site row to point at.
      %{rows: [[nullable]]} =
        Repo.query!(
          "SELECT is_nullable FROM information_schema.columns " <>
            "WHERE table_name = 'deployments' AND column_name = 'site_id'"
        )

      assert nullable == "NO"

      assert {:ok, %{recorded: 1}} = PlatformDelivery.record_all([row()])
      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      assert stored.sha == @sha
      assert stored.delivering_run_id == "17000000001"
      assert stored.queued_seconds == 42
      assert stored.target == "cp"
      refute stored.carried
    end

    test "a numeric run id and a mixed-case sha are normalized, not refused" do
      # The wire is JSON written by a shell script: GitHub renders a run id as a
      # NUMBER, and a sha may arrive upper-case. Refusing either would make the
      # recorder reject every real payload.
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{"delivering_run_id" => 17_000_000_002, "sha" => String.upcase(@sha)})
               ])

      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      assert stored.delivering_run_id == "17000000002"
      assert stored.sha == @sha
    end

    test "an unknown clock stays NULL — never an epoch, never a zero" do
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "merged_at" => nil,
                   "serving_since" => nil,
                   "queued_seconds" => nil,
                   "build_seconds" => nil
                 })
               ])

      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      assert is_nil(stored.merged_at)
      assert is_nil(stored.serving_since)
      assert is_nil(stored.queued_seconds)
      assert is_nil(stored.build_seconds)
    end

    test "an OMITTED `carried` reads UNKNOWN — nil, never a measured false" do
      # D422: `carried` shipped NOT NULL DEFAULT false, so a writer that does not
      # know whether a sha rode another sha's run recorded measured-FALSE. That
      # is the carried-vs-caused lie this epic exists to end.
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([Map.delete(row(), "carried")])

      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      assert is_nil(stored.carried)
      assert is_nil(PlatformDelivery.to_json(stored)[:carried])

      # And the DB agrees: nullable, with no default to fill the silence in.
      %{rows: [[nullable, default]]} =
        Repo.query!(
          "SELECT is_nullable, column_default FROM information_schema.columns " <>
            "WHERE table_name = 'platform_deliveries' AND column_name = 'carried'"
        )

      assert nullable == "YES"
      assert is_nil(default)
    end

    test "an explicit `carried` still means MEASURED, in both directions" do
      # Nullability must not blur the two answers it separates.
      assert {:ok, %{recorded: 1}} = PlatformDelivery.record_all([row(%{"carried" => true})])
      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      assert stored.carried == true
    end

    test "the three queue splits are NULLABLE integers and serialize as unknown" do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name, data_type, is_nullable FROM information_schema.columns " <>
            "WHERE table_name = 'platform_deliveries' " <>
            "AND column_name IN ('queued_self_seconds','queued_pickup_seconds','queued_stall_seconds') " <>
            "ORDER BY column_name"
        )

      assert rows == [
               ["queued_pickup_seconds", "integer", "YES"],
               ["queued_self_seconds", "integer", "YES"],
               ["queued_stall_seconds", "integer", "YES"]
             ]

      # Omitted → UNKNOWN on the wire. A 0 here would read as "the queue was
      # instant", which is the most flattering possible lie about a deploy
      # nobody measured.
      assert {:ok, %{recorded: 1}} = PlatformDelivery.record_all([row()])
      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      json = PlatformDelivery.to_json(stored)

      assert Map.has_key?(json, :queued_self_seconds)
      assert is_nil(json[:queued_self_seconds])
      assert is_nil(json[:queued_pickup_seconds])
      assert is_nil(json[:queued_stall_seconds])
    end

    test "the three queue splits round-trip when the producer DID measure them" do
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "queued_self_seconds" => 9,
                   "queued_pickup_seconds" => 3,
                   "queued_stall_seconds" => 0
                 })
               ])

      assert {:ok, [stored]} = PlatformDelivery.list(sha: @sha)
      json = PlatformDelivery.to_json(stored)
      assert json[:queued_self_seconds] == 9
      assert json[:queued_pickup_seconds] == 3
      # A measured zero is legal — it is the UNMEASURED zero that is the lie.
      assert json[:queued_stall_seconds] == 0
    end

    test "a negative queue split is refused, not stored" do
      assert {:error, {:invalid_row, 0, errors}} =
               PlatformDelivery.record_all([row(%{"queued_stall_seconds" => -1})])

      assert is_list(errors.queued_stall_seconds)
    end
  end

  ## 2. THE KEY — (sha, delivering_run_id, target)

  describe "the unique key" do
    test "the SAME sha delivered by TWO runs at the same first sighting keeps BOTH rows" do
      # ~36% of merged shas have no run of their own — they are CARRIED by a
      # later sha's run. A `(sha, first_seen_at)` key folds exactly those two
      # deliveries into one row. Narrow the index and this assertion goes red:
      # the second insert conflicts (or raises, because the conflict target no
      # longer names an index that exists).
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([row(%{"delivering_run_id" => "run-A"})])

      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{"delivering_run_id" => "run-B", "carried" => true})
               ])

      assert {:ok, rows} = PlatformDelivery.list(sha: @sha)
      assert length(rows) == 2
      assert Enum.map(rows, & &1.delivering_run_id) |> Enum.sort() == ["run-A", "run-B"]
      assert Enum.any?(rows, & &1.carried)
    end

    test "BOTH legs of one deploy — cp AND instance, one sha, ONE run — persist" do
      # THE W23 DATA LOSS, now guarded (charter D422). deploy.yml's
      # `control-plane` and `instance` jobs are two jobs of ONE workflow run, so
      # they share GITHUB_RUN_ID; under the old key
      # (sha, delivering_run_id, first_seen_at) the instance leg conflicted with
      # the cp leg and was DROPPED, and the route still answered 200 with
      # `recorded: 1`. Put `first_seen_at` back into the key and this test goes
      # red on `recorded` and on the stored target set.
      batch = [
        row(%{"delivering_run_id" => "run-shared", "target" => "cp"}),
        row(%{"delivering_run_id" => "run-shared", "target" => "instance"})
      ]

      assert {:ok, %{received: 2, recorded: 2}} = PlatformDelivery.record_all(batch)

      assert {:ok, rows} = PlatformDelivery.list(sha: @sha)
      assert length(rows) == 2
      assert rows |> Enum.map(& &1.target) |> Enum.sort() == ["cp", "instance"]
      # And both legs name the SAME run — the collision is real, not an artifact
      # of the fixture handing them different run ids.
      assert rows |> Enum.map(& &1.delivering_run_id) |> Enum.uniq() == ["run-shared"]
    end

    test "the two legs posted as SEPARATE calls both persist too" do
      # The natural deploy.yml shape: each job posts its own leg. Under the old
      # key the second call answered `%{received: 1, recorded: 0}` — byte-
      # identical to a legitimate idempotent retry, which is why nothing on the
      # cloud side could ever detect the loss.
      assert {:ok, %{received: 1, recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{"delivering_run_id" => "run-split", "target" => "cp"})
               ])

      assert {:ok, %{received: 1, recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{"delivering_run_id" => "run-split", "target" => "instance"})
               ])

      assert {:ok, rows} = PlatformDelivery.list(sha: @sha)
      assert length(rows) == 2
    end

    test "a SECOND post of the same leg is still a retry, not a second row" do
      # The narrowing D422 accepts, pinned so it is a decision and not a
      # surprise: same sha + same run + same target IS a retry, even when the
      # clock moved. Under a per-post clock this would have been three rows.
      leg = row(%{"delivering_run_id" => "run-retry", "target" => "instance"})

      assert {:ok, %{recorded: 1}} = PlatformDelivery.record_all([leg])

      assert {:ok, %{received: 1, recorded: 0}} =
               PlatformDelivery.record_all([
                 Map.put(leg, "first_seen_at", "2026-08-08T10:00:01.000000Z")
               ])

      assert {:ok, [_only_one]} = PlatformDelivery.list(sha: @sha)
    end

    test "the index in the DATABASE names all three key columns" do
      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = $1",
          ["platform_deliveries_sha_run_target_index"]
        )

      assert indexdef =~ "UNIQUE"

      # The COLUMN LIST, not the index name. Asserting `indexdef =~ "target"`
      # would be green against an index merely NAMED …_target_index over the old
      # columns — measured: the key mutation passed that weaker assertion.
      assert [_, columns] = Regex.run(~r/USING btree \(([^)]+)\)/, indexdef)

      assert columns |> String.split(", ") |> Enum.sort() ==
               ["delivering_run_id", "sha", "target"]

      # The old key is GONE, not merely shadowed — a surviving unique on
      # (sha, delivering_run_id, first_seen_at) would keep refusing the retry
      # this table must absorb.
      assert %{rows: []} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes WHERE indexname = $1",
                 ["platform_deliveries_sha_run_seen_index"]
               )
    end

    test "`target` is NOT NULL, because a nullable key column disables the key" do
      # Postgres NULLs never compare equal, so a nullable column in a btree
      # unique key silently switches the constraint OFF for every row that omits
      # it — the collision would return as duplication instead of loss.
      %{rows: [[nullable]]} =
        Repo.query!(
          "SELECT is_nullable FROM information_schema.columns " <>
            "WHERE table_name = 'platform_deliveries' AND column_name = 'target'"
        )

      assert nullable == "NO"
    end

    test "re-posting the SAME batch records nothing and says so" do
      batch = [row(), row(%{"sha" => String.duplicate("b", 40)})]

      assert {:ok, %{received: 2, recorded: 2}} = PlatformDelivery.record_all(batch)
      # A retried deploy job re-posts its whole batch. `recorded: 0` beside
      # `received: 2` is the honest answer; a bare `ok: true` would be a lie.
      assert {:ok, %{received: 2, recorded: 0}} = PlatformDelivery.record_all(batch)

      assert {:ok, rows} = PlatformDelivery.list([])
      assert length(rows) == 2
    end

    test "a duplicate WITHIN one batch is absorbed, not raised" do
      assert {:ok, %{received: 2, recorded: 1}} = PlatformDelivery.record_all([row(), row()])
    end
  end

  ## 3. THE RECORDER — worker token, machine-only

  describe "POST /v1/internal/platform-deliveries" do
    test "no credential is REFUSED 401 over the rendered response" do
      conn = call(:post, "/v1/internal/platform-deliveries", %{deliveries: [row()]})

      assert conn.status == 401
      assert body(conn)["error"] in ["unauthorized", "unauthenticated"]
      # And nothing was written by the refused call.
      assert {:ok, []} = PlatformDelivery.list(sha: @sha)
    end

    test "a PAT is REFUSED — the recorder is machine-only by construction" do
      {user, team} = user_with_team()

      conn =
        call(
          :post,
          "/v1/internal/platform-deliveries",
          %{deliveries: [row()]},
          pat(user, team, ["root"])
        )

      assert conn.status == 401
      assert {:ok, []} = PlatformDelivery.list(sha: @sha)
    end

    test "a session token is REFUSED too" do
      {user, _team} = user_with_team()

      conn =
        call(:post, "/v1/internal/platform-deliveries", %{deliveries: [row()]}, session(user))

      assert conn.status == 401
    end

    test "the worker token records a LIST in one call, idempotently" do
      batch = [
        row(),
        row(%{
          "sha" => String.duplicate("c", 40),
          "carried" => true,
          "target" => "instance"
        })
      ]

      conn =
        call(:post, "/v1/internal/platform-deliveries", %{deliveries: batch}, @worker_token)

      assert conn.status == 200
      assert body(conn) == %{"ok" => true, "received" => 2, "recorded" => 2}

      # The retry: same bytes in, zero new rows, and the response SAYS zero.
      again =
        call(:post, "/v1/internal/platform-deliveries", %{deliveries: batch}, @worker_token)

      assert again.status == 200
      assert body(again) == %{"ok" => true, "received" => 2, "recorded" => 0}
    end

    test "a body without a `deliveries` LIST is 422, not a silent no-op" do
      conn = call(:post, "/v1/internal/platform-deliveries", %{sha: @sha}, @worker_token)

      assert conn.status == 422
      assert body(conn)["error"] == "deliveries_required"
    end

    test "one bad row refuses the WHOLE batch and names its index" do
      batch = [row(), row(%{"sha" => "not-a-sha", "delivering_run_id" => "run-Z"})]

      conn =
        call(:post, "/v1/internal/platform-deliveries", %{deliveries: batch}, @worker_token)

      assert conn.status == 422
      assert %{"error" => "invalid_row", "index" => 1, "errors" => errors} = body(conn)
      assert is_list(errors["sha"])
      # A partially-recorded delivery is worse than a refusal the caller retries.
      assert {:ok, []} = PlatformDelivery.list([])
    end

    test "an explicitly NULL required column is a typed 422, never a 500" do
      # `validate_inclusion/3` skips nil, so an explicit `"target": null` passes
      # the changeset, reaches insert_all/3 and Postgres refuses it. Until W24
      # that fell through `classify/1` to the router's 500 `record_failed` —
      # telling a deploy job the CROWN had failed when its own payload was wrong,
      # and sending it retrying identical bytes forever. Delete the
      # `:not_null_violation` clause in classify/1 and this test goes red with a
      # 500 and `record_failed`.
      conn =
        call(
          :post,
          "/v1/internal/platform-deliveries",
          %{deliveries: [row(%{"target" => nil})]},
          @worker_token
        )

      assert conn.status == 422
      assert %{"error" => "null_column", "column" => "target"} = body(conn)
      assert body(conn)["detail"] =~ "unknown"
      refute body(conn)["error"] == "record_failed"
      assert {:ok, []} = PlatformDelivery.list([])
    end

    test "an out-of-vocabulary target is refused" do
      conn =
        call(
          :post,
          "/v1/internal/platform-deliveries",
          %{deliveries: [row(%{"target" => "moon"})]},
          @worker_token
        )

      assert conn.status == 422
      assert body(conn)["error"] == "invalid_row"
    end
  end

  ## 4. THE READER — PAT-reachable, because a record no script can read is not a record

  describe "GET /v1/deliveries" do
    setup do
      {:ok, %{recorded: 1}} = PlatformDelivery.record_all([row()])
      {user, team} = user_with_team()
      %{user: user, team: team}
    end

    test "a read PAT gets 200 and the recorded row in the RENDERED bytes", %{
      user: user,
      team: team
    } do
      conn = call(:get, "/v1/deliveries?sha=#{@sha}", nil, pat(user, team, ["read"]))

      assert conn.status == 200
      # The bytes on the wire carry the sha — not just a decoded struct.
      assert conn.resp_body =~ @sha

      assert %{
               "deliveries" => [delivery],
               "count" => 1,
               "sha" => @sha,
               "scope" => "platform"
             } = body(conn)

      assert delivery["delivering_run_id"] == "17000000001"
      assert delivery["queued_seconds"] == 42
      assert delivery["build_seconds"] == 310
      assert delivery["target"] == "cp"
      assert delivery["carried"] == false
      assert delivery["first_seen_at"] =~ "2026-08-08T10:00:00"
      assert delivery["recorded_at"]
    end

    test "an UNKNOWN sha is an honest empty list, never a 404", %{user: user, team: team} do
      unknown = String.duplicate("f", 40)
      conn = call(:get, "/v1/deliveries?sha=#{unknown}", nil, pat(user, team, ["read"]))

      assert conn.status == 200

      assert body(conn) == %{
               "deliveries" => [],
               "count" => 0,
               "sha" => unknown,
               "limit" => PlatformDelivery.default_limit(),
               "scope" => "platform"
             }
    end

    test "a session reaches it too (the browser is not locked out)", %{user: user} do
      conn = call(:get, "/v1/deliveries", nil, session(user))

      assert conn.status == 200
      assert body(conn)["count"] == 1
      assert is_nil(body(conn)["sha"])
    end

    test "no credential is refused 401" do
      conn = call(:get, "/v1/deliveries?sha=#{@sha}")

      assert conn.status == 401
      refute conn.resp_body =~ @sha
    end

    # THE WRITER READS ITS OWN RECORD (task-e2acb66e9ed0da09).
    #
    # THIS INVERTS THE PIN task-f7decfcd5fa0eba8 PUT HERE, and the reversal is
    # deliberate, not an accident of a later edit. That pin asserted the 401 and
    # argued the reconciler's SSH+psql fallback was "the LEGITIMATE working
    # path". It was measured wrong by a production run: crown-reconcile run
    # 31311887504 printed "the route answered HTTP 401 to the WORKER principal —
    # read via the control plane's postgres container instead" TWENTY-TWO TIMES,
    # once per sha. The fallback is not a fallback if it is the only path that
    # ever runs; it is the door, and the route was a wall. A fallback that always
    # fires is a broken door with a working window — and because it always fired,
    # the failure rendered as a `note:` and never once as a verdict.
    #
    # THE OLD PIN'S STATED FEAR DOES NOT SURVIVE READING WHAT THE WORKER HOLDS.
    # It called this "a permission widening on a platform-scoped operational
    # record that no tenant should reach". No tenant reaches it now either:
    # `WORKER_TOKEN` is not a tenant credential. It is the faceless off-box
    # shared secret that ALREADY reads the cross-team `GET /v1/internal/barkparks`
    # (every row across every team), already claims and completes every team's
    # provision jobs, and already WRITES the very rows this route returns
    # (`POST /v1/internal/platform-deliveries`, asserted above in this same
    # file). Admitting it to a read of the platform's own deploy record is
    # STRICTLY SUBSUMED by what it holds before this change. What was actually
    # true is the narrower thing the reconciler's own report kept saying: the
    # principal that writes this record could not read it back.
    #
    # THE WIDENING IS CLAMPED, and the next three tests are the clamp: the worker
    # is admitted FACELESSLY (no current_user, no current_team) with abilities
    # `["read"]` and nothing else, and it gains no reach into either TENANT
    # delivery log.
    test "the WORKER token READS the record it wrote — the 401 is gone" do
      conn = call(:get, "/v1/deliveries?sha=#{@sha}", nil, @worker_token)

      assert conn.status == 200,
             "GET /v1/deliveries answered HTTP #{conn.status} to the WORKER principal. " <>
               "The WORKER principal is the one deploy.yml's crown step carries and the " <>
               "only one that WRITES this record (POST /v1/internal/platform-deliveries). " <>
               "A 401 here is the defect task-e2acb66e9ed0da09 closed: it leaves the " <>
               "delivery record with no working API read path for its own writer, sends " <>
               "crown-reconcile down the SSH+psql fallback on the NORMAL path, and turns " <>
               "a route failure into a `note:` instead of a verdict."

      # Not merely admitted — it gets the ROW, in the rendered bytes.
      assert conn.resp_body =~ @sha
      assert %{"count" => 1, "scope" => "platform"} = body(conn)
    end

    test "the worker is admitted FACELESSLY and clamped to read — never root" do
      conn =
        :get
        |> conn("/v1/deliveries")
        |> put_req_header("authorization", "Bearer " <> @worker_token)
        |> Auth.require_user_or_pat_or_worker([])

      refute conn.halted
      assert conn.assigns[:current_principal] == :worker

      # THE CLAMP. `["read"]` and not `["root"]`: a session carries root, and
      # handing the worker root would make this plug a back door onto every
      # write-gated route the moment someone reuses it.
      assert conn.assigns[:current_abilities] == ["read"]
      refute Auth.require_ability(conn, "read").halted
      assert Auth.require_ability(conn, "write").halted
      assert Auth.require_ability(conn, "deploy").halted
      assert Auth.require_ability(conn, "root").halted

      # FACELESS. A worker is not a user and resolves no team, so a route that
      # reads either must not use this plug.
      assert is_nil(conn.assigns[:current_user])
      assert is_nil(conn.assigns[:current_team])
    end

    test "a bearer that is neither worker nor session nor PAT is still 401" do
      conn = call(:get, "/v1/deliveries?sha=#{@sha}", nil, "not-the-worker-token")

      assert conn.status == 401
      refute conn.resp_body =~ @sha
    end

    # THE NEGATIVE ARM. Widening the PLATFORM record must not widen what a worker
    # can SEE. The two neighbouring routes that also end in `/deliveries` are
    # TENANT surfaces — one team's notification sends, one instance's webhook
    # send log — and neither may answer this principal.
    test "the worker gains NO reach into the team notification delivery log" do
      conn = call(:get, "/v1/notifications/deliveries", nil, @worker_token)

      assert conn.status == 401,
             "GET /v1/notifications/deliveries answered #{conn.status} to the WORKER " <>
               "principal. That is a TEAM-scoped tenant log behind `Auth.require_user`; " <>
               "widening /v1/deliveries must not have leaked into it."
    end

    test "the worker gains NO reach into a tenant's webhook delivery log" do
      id = "33333333-3333-3333-3333-333333333333"

      conn =
        call(:get, "/v1/barkparks/#{id}/api/webhooks/wh_1/deliveries", nil, @worker_token)

      assert conn.status == 401,
             "GET /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries answered " <>
               "#{conn.status} to the WORKER principal. That proxy is gated by " <>
               "`proxy_instance_webhook` -> `Auth.require_user`; widening /v1/deliveries " <>
               "must not have leaked into it."
    end

    # The guard is read out of ROUTER SOURCE as well as driven, because the four
    # tests above are all green against a route that accepts EVERYTHING. This one
    # names the plug, so "the 401 went away" can never be satisfied by an
    # accidental removal of the gate.
    test "the route's gate is the CLAMPED disjunction, not an open door" do
      guard = RouterTierLens.raw_route_guard("GET", "/v1/deliveries")

      assert guard == "require_user_or_pat_or_worker",
             "GET /v1/deliveries must be gated by `Auth.require_user_or_pat_or_worker` " <>
               "(session OR read-PAT OR the faceless worker). Found: #{inspect(guard)}."

      assert RouterTierLens.tier_of("GET", "/v1/deliveries") == {:ok, "user(s)+worker"}
    end

    test "the bare list is a PINNED window, and ?limit= is clamped", %{user: user, team: team} do
      conn = call(:get, "/v1/deliveries?limit=9999", nil, pat(user, team, ["read"]))

      assert conn.status == 200
      assert body(conn)["limit"] == PlatformDelivery.max_limit()

      junk = call(:get, "/v1/deliveries?limit=nope", nil, pat(user, team, ["read"]))
      assert body(junk)["limit"] == PlatformDelivery.default_limit()
    end
  end

  ## 5. THE MISSING TABLE — the api-only merge, which is real

  describe "a control plane without the migration" do
    # `deploy.yml`'s instance job fires on `^(api|internal|deploy|connectors|
    # templates)/` and does NOT require the `cloud/**` merge that carries this
    # migration. The table is dropped INSIDE this test's sandboxed transaction,
    # so the schema is restored by the rollback; nothing here leaks.
    test "the recorder answers a typed 503, never a 500 and never a fake success" do
      Repo.query!("DROP TABLE platform_deliveries")

      conn =
        call(
          :post,
          "/v1/internal/platform-deliveries",
          %{deliveries: [row()]},
          @worker_token
        )

      assert conn.status == 503

      assert %{"error" => "unavailable", "reason" => "platform_deliveries_missing"} =
               body(conn)

      assert body(conn)["detail"] =~ "migration"
      # And the caller is told nothing was written — a `|| true` here is the
      # exact blindness this wave exists to end.
      assert body(conn)["detail"] =~ "nothing was recorded"
    end

    test "the reader answers the SAME typed 503" do
      {user, team} = user_with_team()
      read_pat = pat(user, team, ["read"])
      Repo.query!("DROP TABLE platform_deliveries")

      conn = call(:get, "/v1/deliveries?sha=#{@sha}", nil, read_pat)

      assert conn.status == 503
      assert body(conn)["error"] == "unavailable"
      assert body(conn)["reason"] == "platform_deliveries_missing"
    end
  end

  ## 6. THE TRANSITION — W25 (D437): a rollback stops reading as a no-op

  # NOTHING in the three sections below asserts a ROW COUNT, or that "the crown
  # holds a row". The LIVE table already contains junk (a `w25-seam-probe` row
  # and an all-zeros sha with run id "0"), so a count is a fact about whoever
  # posted last, not about this code. Every assertion here keys on SHAPE: the
  # value in a named field, the emitted key set, a changeset verdict, or a
  # column definition read out of the catalog.

  describe "the transition columns" do
    test "previous_sha and transition are NULLABLE with NO default in the DATABASE" do
      # The migration is catalog-only on purpose: a NOT NULL or a DEFAULT would
      # mint a verdict for every pre-migration row, and there is no fact on this
      # control plane from which those rows could be reclassified.
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name, is_nullable, column_default FROM information_schema.columns " <>
            "WHERE table_name = 'platform_deliveries' " <>
            "AND column_name IN ('previous_sha', 'transition') ORDER BY column_name"
        )

      assert [
               ["previous_sha", "YES", nil],
               ["transition", "YES", nil]
             ] = rows
    end

    test "neither new column is indexed — an index with no reader is write cost for nothing" do
      %{rows: indexdefs} =
        Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = 'platform_deliveries'")

      refute Enum.any?(indexdefs, fn [indexdef] -> indexdef =~ "transition" end)
      refute Enum.any?(indexdefs, fn [indexdef] -> indexdef =~ "previous_sha" end)
    end

    test "every word in the vocabulary is accepted and stored verbatim" do
      assert PlatformDelivery.transitions() == ~w(forward rollback diverged noop unknown)

      for {word, n} <- Enum.with_index(PlatformDelivery.transitions()) do
        run = "transition-run-#{n}"

        assert {:ok, %{recorded: 1}} =
                 PlatformDelivery.record_all([
                   row(%{
                     "delivering_run_id" => run,
                     "previous_sha" => String.duplicate("d", 40),
                     "transition" => word
                   })
                 ])

        assert {:ok, stored} = fetch_by_run(run)
        assert stored.transition == word
        assert stored.previous_sha == String.duplicate("d", 40)
      end
    end

    test "a word OUTSIDE the vocabulary fails the changeset — it is never stored" do
      # `rolled_back` is the boolean this design rejected; the rest are
      # `commit_ancestry`'s words, which grade BOX-vs-MAIN and say nothing at
      # all about PREVIOUS-vs-NEW.
      for bogus <- ["rolled_back", "ahead_of_main", "behind", "current", "reverted", "yes"] do
        cs = PlatformDelivery.changeset(%PlatformDelivery{}, row(%{"transition" => bogus}))

        refute cs.valid?
        assert %{transition: ["is invalid"]} = errors_on(cs)
      end
    end

    test "an out-of-vocabulary transition refuses the WHOLE batch, like any bad row" do
      assert {:error, {:invalid_row, 0, errors}} =
               PlatformDelivery.record_all([row(%{"transition" => "rolled_back"})])

      assert is_list(errors[:transition])
    end

    test "a previous_sha that is not a sha is refused, not stored as junk" do
      cs = PlatformDelivery.changeset(%PlatformDelivery{}, row(%{"previous_sha" => "HEAD~1"}))

      refute cs.valid?
      assert %{previous_sha: [msg]} = errors_on(cs)
      assert msg =~ "lowercase hex commit sha"
    end

    test "an upper-cased previous_sha is normalized, not refused" do
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "delivering_run_id" => "prev-case-run",
                   "previous_sha" => String.upcase(String.duplicate("e", 40)),
                   "transition" => "forward"
                 })
               ])

      assert {:ok, stored} = fetch_by_run("prev-case-run")
      assert stored.previous_sha == String.duplicate("e", 40)
    end
  end

  ## 7. FAIL-CLOSED — the whole point of the two columns

  describe "an undecidable transition" do
    test "records `unknown` with NULL counts — never 0, never a fallback to `forward`" do
      # The writer's failure modes are real and measured: a gc'd sha exits 128,
      # an unreachable box answers nothing, a shallow clone cannot walk the
      # range. All of them land HERE. The repo's own `|| echo 0` idiom
      # (scripts/doctor.sh:27-28) would turn every one of them into a confident
      # zero, which then reads as `noop` — a rollback rendered as "nothing
      # happened", the exact disease this epic exists to cure.
      assert PlatformDelivery.unknown_transition() == "unknown"

      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "delivering_run_id" => "undecidable-run",
                   "previous_sha" => nil,
                   "transition" => PlatformDelivery.unknown_transition(),
                   "queued_seconds" => nil,
                   "build_seconds" => nil
                 })
               ])

      assert {:ok, stored} = fetch_by_run("undecidable-run")

      assert stored.transition == "unknown"
      refute stored.transition == "forward"
      refute stored.transition == "noop"

      # NULL, not 0 — and both are asserted, because a laundered zero satisfies
      # neither `is_nil/1` nor a bare "it has a value" check.
      assert is_nil(stored.queued_seconds)
      assert is_nil(stored.build_seconds)
      assert is_nil(stored.previous_sha)
      refute stored.queued_seconds == 0
      refute stored.build_seconds == 0
    end

    test "a writer that says NOTHING leaves transition NULL — it does not become `forward`" do
      # NULL and "unknown" are different sentences. NULL: no verdict was ever
      # attempted (every row written before this migration). "unknown": a
      # verdict was attempted and could not be reached. Neither may decay into a
      # cheerful `forward`.
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([row(%{"delivering_run_id" => "silent-run"})])

      assert {:ok, stored} = fetch_by_run("silent-run")
      assert is_nil(stored.transition)
      assert is_nil(stored.previous_sha)
      refute stored.transition == "forward"
    end

    test "a BLANK transition is NULL (no verdict), never `forward` and never `noop`" do
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{"delivering_run_id" => "blank-run", "transition" => "   "})
               ])

      assert {:ok, stored} = fetch_by_run("blank-run")
      assert is_nil(stored.transition)
      refute stored.transition == "forward"
      refute stored.transition == "noop"
    end

    test "a rollback and a no-op are DISTINGUISHABLE in the record" do
      # The measurement that forced these columns: on guerrilla's live slot pair
      # `git rev-list --count green..blue` read 0 for a REAL two-commit
      # rollback — byte-identical to a no-op. Same delivered sha, different
      # truth; before this slice the two rows had identical shape.
      old = String.duplicate("1", 40)

      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "delivering_run_id" => "rollback-run",
                   "previous_sha" => old,
                   "transition" => "rollback"
                 })
               ])

      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "delivering_run_id" => "noop-run",
                   "previous_sha" => @sha,
                   "transition" => "noop"
                 })
               ])

      assert {:ok, rolled} = fetch_by_run("rollback-run")
      assert {:ok, noop} = fetch_by_run("noop-run")

      assert rolled.sha == noop.sha
      assert rolled.transition == "rollback"
      assert noop.transition == "noop"
      assert rolled.previous_sha == old
      assert noop.previous_sha == noop.sha
    end
  end

  ## 8. THE WIRE — a column nobody can read is not a record

  describe "to_json/1 carries the transition" do
    test "the emitted KEY SET names both new fields" do
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "delivering_run_id" => "json-run",
                   "previous_sha" => String.duplicate("a", 40),
                   "transition" => "rollback"
                 })
               ])

      assert {:ok, stored} = fetch_by_run("json-run")
      json = PlatformDelivery.to_json(stored)

      assert json |> Map.keys() |> Enum.sort() == [
               :build_seconds,
               :carried,
               :delivering_run_id,
               :first_seen_at,
               :merged_at,
               :previous_sha,
               :queued_pickup_seconds,
               :queued_seconds,
               :queued_self_seconds,
               :queued_stall_seconds,
               :recorded_at,
               :serving_since,
               :sha,
               :target,
               :transition
             ]

      assert json.previous_sha == String.duplicate("a", 40)
      assert json.transition == "rollback"
    end

    test "an unclassified row emits both keys as null — present and honestly empty" do
      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([row(%{"delivering_run_id" => "null-json-run"})])

      assert {:ok, stored} = fetch_by_run("null-json-run")
      json = PlatformDelivery.to_json(stored)

      assert Map.has_key?(json, :previous_sha)
      assert Map.has_key?(json, :transition)
      assert is_nil(json.previous_sha)
      assert is_nil(json.transition)
    end

    test "the READER route renders the transition in the response BYTES" do
      {user, team} = user_with_team()

      assert {:ok, %{recorded: 1}} =
               PlatformDelivery.record_all([
                 row(%{
                   "delivering_run_id" => "wire-run",
                   "previous_sha" => String.duplicate("b", 40),
                   "transition" => "diverged"
                 })
               ])

      conn = call(:get, "/v1/deliveries?sha=#{@sha}", nil, pat(user, team, ["read"]))

      assert conn.status == 200
      assert conn.resp_body =~ "diverged"

      delivery =
        conn
        |> body()
        |> Map.fetch!("deliveries")
        |> Enum.find(&(&1["delivering_run_id"] == "wire-run"))

      assert delivery["transition"] == "diverged"
      assert delivery["previous_sha"] == String.duplicate("b", 40)
    end
  end

  # Fetch the ONE row a test wrote, by its own unique run id. Deliberately not
  # `List.first/1` and never a count: the identity is
  # (sha, delivering_run_id, first_seen_at), so the run id is what makes a row
  # this test's own.
  defp fetch_by_run(run_id) do
    {:ok, rows} = PlatformDelivery.list(sha: @sha)

    case Enum.find(rows, &(&1.delivering_run_id == run_id)) do
      nil -> {:error, {:no_row_for_run, run_id}}
      found -> {:ok, found}
    end
  end
end
