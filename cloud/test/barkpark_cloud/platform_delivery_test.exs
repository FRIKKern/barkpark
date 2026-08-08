defmodule BarkparkCloud.PlatformDeliveryTest do
  @moduledoc """
  dr-w23-s2 — THE CROWN, CLOUD HALF: the platform's first durable memory of its
  own deploys, written by a machine and readable by a human.

  Everything here is driven through the REAL router (`Router.call/2`) and
  asserted over the RENDERED response bytes, never over the plug list: a test
  that reads "`require_worker` appears above this route" is green against a route
  whose guard result is discarded. The two halves of this slice are different
  credentials ON PURPOSE — the recorder is worker-token (machine-only) and the
  reader is PAT-reachable — and that split is exactly what is pinned below.

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
  end

  ## 2. THE KEY — (sha, delivering_run_id, first_seen_at)

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

    test "the index in the DATABASE names all three columns" do
      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = $1",
          ["platform_deliveries_sha_run_seen_index"]
        )

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "sha"
      assert indexdef =~ "delivering_run_id"
      assert indexdef =~ "first_seen_at"
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
end
