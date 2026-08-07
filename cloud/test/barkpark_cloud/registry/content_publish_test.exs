defmodule BarkparkCloud.Registry.ContentPublishTest do
  @moduledoc """
  deploy-reliability W11 (charter D162) — THE PUBLISH INSTANT.

  Every latency this epic has ever published starts at a `deployments.inserted_at`,
  i.e. when the control plane ENQUEUED a rebuild. That clock is ≥60s late by
  construction (AutoDeployWorker debounces, D44) and is ABSENT for the 26-35% of
  publishes whose rebuild coalesces onto an in-flight one — those publishes cannot
  be measured as slow because they do not exist in any table.

  `content_publishes` is the row that always exists. These tests hold two things:

    1. It records the population the deployments table cannot — a publish that
       mints no deployment row still lands here.
    2. It CANNOT COST THE 202. The receiver is a webhook: if a bookkeeping write
       can fail a delivery, the box retries a publish the control plane already
       accepted. The recording path is therefore proven byte-identical on both the
       succeeds and the fails path, and the failure is a REAL failure (an invalid
       payload, a missing table) — never a stubbed one.

  Not `async: true` on purpose: the mutation proof renames `content_publishes` away
  inside its own sandbox transaction, which takes an ACCESS EXCLUSIVE lock that a
  concurrent test touching the table would block on.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{ContentPublish, Deployment, Vault}
  alias BarkparkCloud.Sites.AutoDeployWorker
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @instance_host "barkpark.cloud"

  # The exact bytes today's receiver answers with. Every assertion about "the 202
  # is unchanged" compares against this literal, not against a re-encode.
  @accepted_body ~s({"ok":true,"trigger":"content-auto"})

  ## Fixtures (the receiver's own shape — see sites/content_publish_receiver_test.exs)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      # barkparks.url is uniquely indexed and several tests here stand up TWO
      # boxes (a recording-succeeds site and a recording-fails one).
      url: "https://acme-#{n}.#{@instance_host}",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_read_#{n}"
      })

    site
  end

  defp bound_site do
    site = team_fixture() |> live_barkpark() |> static_site()
    {:ok, secret} = Registry.reveal_site_content_secret(site)
    assert is_binary(secret)
    {site, secret}
  end

  defp sign(secret, ts, body) do
    v1 = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{v1}"
  end

  defp deliver(site_id, body, sig) do
    conn(:post, "/v1/sites/webhooks/content-publish/#{site_id}", body)
    |> put_req_header("content-type", "application/json")
    |> maybe_sig(sig)
    |> Router.call(@opts)
  end

  defp maybe_sig(conn, nil), do: conn
  defp maybe_sig(conn, sig), do: put_req_header(conn, "x-barkpark-signature", sig)

  # A signed publish delivery, the way the box's Webhooks.Dispatcher sends one.
  defp publish(site, secret, payload \\ %{}) do
    body =
      Jason.encode!(
        Map.merge(%{"event" => "publish", "type" => "post", "doc_id" => "p42"}, payload)
      )

    deliver(site.id, body, sign(secret, System.system_time(:second), body))
  end

  defp publishes_for(site), do: Repo.all(from p in ContentPublish, where: p.site_id == ^site.id)

  ## ---------------------------------------------------------------------------

  describe "record/3 — total, never raises into its caller" do
    test "an UNKNOWN site id comes back {:error, _} instead of raising" do
      # The webhook's whole safety property rests on this: a write that cannot
      # land must be a VALUE, not an exception travelling up into an HTTP reply.
      assert {:error, %Ecto.Changeset{} = cs} =
               ContentPublish.record(Ecto.UUID.generate(), DateTime.utc_now(), %{
                 doc_type: "post"
               })

      refute cs.valid?
    end

    test "a NON-UUID site id comes back {:error, _} rather than a CastError" do
      # binary_id CastError is the classic way a "safe" helper blows up.
      assert {:error, _} = ContentPublish.record("not-a-uuid", DateTime.utc_now())
    end

    test "the happy path appends the caller's instant verbatim, with the defaults" do
      {site, _secret} = bound_site()
      received_at = DateTime.utc_now() |> DateTime.add(-90, :second)

      assert {:ok, row} = ContentPublish.record(site.id, received_at, %{doc_type: "post"})

      # received_at is the CALLER's clock, not the insert's — that distinction is
      # the entire point of the table.
      assert DateTime.compare(row.received_at, received_at) == :eq
      assert row.received_at != row.inserted_at
      assert row.doc_type == "post"
      assert row.source == "content-webhook"
      assert row.enqueued == false
    end

    test "enqueued?/1 reads Oban's conflict shape: a coalesce is NOT an enqueue" do
      # {:ok, job} is the SAME success shape for a fresh insert and a unique
      # conflict — reading only the :ok is how a coalesced publish goes missing.
      assert ContentPublish.enqueued?({:ok, %{conflict?: false}})
      refute ContentPublish.enqueued?({:ok, %{conflict?: true}})
      refute ContentPublish.enqueued?({:error, :whatever})
    end
  end

  describe "the receiver records the publish instant (D162)" do
    test "a verified delivery appends ONE row, echoing the payload's doc type" do
      {site, secret} = bound_site()
      before = DateTime.utc_now()

      conn = publish(site, secret, %{"type" => "article"})

      assert conn.status == 202
      assert conn.resp_body == @accepted_body

      assert [row] = publishes_for(site)
      assert row.doc_type == "article"
      assert row.source == "content-webhook"
      # The clock started at the delivery, not at some later job.
      assert DateTime.compare(row.received_at, before) in [:gt, :eq]
      assert DateTime.compare(row.received_at, DateTime.utc_now()) in [:lt, :eq]
      # And the enqueue outcome landed on the row.
      assert row.enqueued == true
      assert_enqueued(worker: AutoDeployWorker, args: %{site_id: site.id})
    end

    test "a payload with NO type records a NULL doc_type — never an invented one" do
      {site, secret} = bound_site()

      body = Jason.encode!(%{"event" => "publish"})
      conn = deliver(site.id, body, sign(secret, System.system_time(:second), body))

      assert conn.status == 202
      assert [row] = publishes_for(site)
      assert is_nil(row.doc_type)
    end

    test "a correctly SIGNED body that is not a JSON OBJECT still records the instant" do
      {site, secret} = bound_site()

      # A JSON array has no `type` to echo. (A body that is not JSON at all never
      # reaches the route — Plug.Parsers rejects it at 400, upstream of here.)
      body = Jason.encode!([1, 2, 3])
      conn = deliver(site.id, body, sign(secret, System.system_time(:second), body))

      assert conn.status == 202
      assert [row] = publishes_for(site)
      assert is_nil(row.doc_type)
    end
  end

  describe "the record CANNOT cost the 202 (mutation proof)" do
    test "record FAILS (invalid doc_type) and the receiver still answers a byte-identical 202" do
      {ok_site, ok_secret} = bound_site()
      {bad_site, bad_secret} = bound_site()

      # Baseline: the recording-SUCCEEDS path.
      ok_conn = publish(ok_site, ok_secret)
      assert ok_conn.status == 202
      assert ok_conn.resp_body == @accepted_body
      assert [_] = publishes_for(ok_site)

      # The recording-FAILS path. A real failure, not a stub: doc_type is capped
      # at the column's 255 chars, so this delivery's changeset is invalid and
      # record/3 returns {:error, changeset}. If the router's `case` guard is
      # removed, mark_enqueued/2 gets the {:error, _} tuple and raises
      # FunctionClauseError — a 500 on a delivery the fleet actually accepted.
      bad_conn = publish(bad_site, bad_secret, %{"type" => String.duplicate("x", 300)})

      assert bad_conn.status == ok_conn.status
      assert bad_conn.resp_body == ok_conn.resp_body
      assert bad_conn.resp_body == @accepted_body

      # The row genuinely did not land — the 202 is not hiding a silent success.
      assert [] = publishes_for(bad_site)

      # And the delivery still did its real job: the rebuild is queued.
      assert_enqueued(worker: AutoDeployWorker, args: %{site_id: bad_site.id})
    end

    test "the whole TABLE is gone and the receiver still answers a byte-identical 202" do
      {site, secret} = bound_site()

      # The harshest real failure this write has: the migration has not been
      # applied yet (the lead orders migrations; a deploy does not). Postgrex
      # raises undefined_table; record/3's rescue is the only thing between that
      # and a 500 on an accepted publish. Remove the rescue and this REDS.
      Repo.query!("ALTER TABLE content_publishes RENAME TO content_publishes_absent")

      conn = publish(site, secret)

      assert conn.status == 202
      assert conn.resp_body == @accepted_body
      assert_enqueued(worker: AutoDeployWorker, args: %{site_id: site.id})
    end
  end

  describe "the recorded population includes publishes that mint NO deployment row" do
    test "two publishes inside the debounce window: TWO publish rows, at most ONE deployment" do
      {site, secret} = bound_site()

      assert publish(site, secret).status == 202
      assert publish(site, secret).status == 202

      rows = publishes_for(site) |> Enum.sort_by(& &1.received_at, DateTime)

      # THE POINT OF THE TABLE. The second publish coalesced — before D162 it left
      # no trace anywhere, so it was invisible in both the numerator and the
      # denominator of every time-to-web number this epic has ever published.
      assert length(rows) == 2

      deployments = Repo.aggregate(Deployment, :count, :id)
      assert deployments <= 1

      # And the coalesce is LABELLED, not merely counted: the second publish owns
      # no rebuild of its own.
      assert [first, second] = rows
      assert first.enqueued == true
      refute second.enqueued

      # One debounced job for two publishes (charter D44).
      assert length(all_enqueued(worker: AutoDeployWorker)) == 1
    end
  end

  describe "the table is not an unauthenticated write amplifier" do
    test "a FORGED signature 401s and records NOTHING" do
      {site, _secret} = bound_site()

      body = Jason.encode!(%{"event" => "publish", "type" => "post"})
      forged = "t=#{System.system_time(:second)},v1=#{String.duplicate("0", 64)}"

      conn = deliver(site.id, body, forged)

      assert conn.status == 401
      assert publishes_for(site) == []
      assert Repo.aggregate(ContentPublish, :count, :id) == 0
    end

    test "an EXPIRED but otherwise valid signature 401s and records NOTHING" do
      {site, secret} = bound_site()

      body = Jason.encode!(%{"event" => "publish"})
      stale = System.system_time(:second) - 400

      conn = deliver(site.id, body, sign(secret, stale, body))

      assert conn.status == 401
      assert publishes_for(site) == []
    end

    test "a MISSING signature 401s and records NOTHING" do
      {site, _secret} = bound_site()

      conn = deliver(site.id, Jason.encode!(%{"event" => "publish"}), nil)

      assert conn.status == 401
      assert Repo.aggregate(ContentPublish, :count, :id) == 0
    end

    test "an UNKNOWN site 404s and records NOTHING" do
      body = Jason.encode!(%{"event" => "publish"})

      conn =
        deliver(Ecto.UUID.generate(), body, sign("whatever", System.system_time(:second), body))

      assert conn.status == 404
      assert Repo.aggregate(ContentPublish, :count, :id) == 0
    end

    test "a site with NO content webhook configured 404s and records NOTHING" do
      bp = team_fixture() |> live_barkpark()

      {:ok, container} =
        Registry.create_site(bp, %{name: "App", slug: "app-c", kind: "container"})

      assert {:ok, nil} = Registry.reveal_site_content_secret(container)

      body = Jason.encode!(%{"event" => "publish"})

      conn = deliver(container.id, body, sign("whatever", System.system_time(:second), body))

      assert conn.status == 404
      assert Repo.aggregate(ContentPublish, :count, :id) == 0
    end
  end
end
