defmodule BarkparkCloud.InstanceDeleteSiteReadTokenRevokeTest do
  @moduledoc """
  Deleting an INSTANCE must not strand its sites' read credentials.

  ## The defect these tests pin

  ssw8 (PR #13875) closed the leak on the SITE delete path: `delete_site/1`
  revokes the site's public-read content token on the box before `Repo.delete`.
  That fix is INVISIBLE to the instance delete path, because
  `sites.barkpark_id` is `references(:barkparks, on_delete: :delete_all)`
  (migration `20260627150000_create_sites.exs`) — the DATABASE removes an
  instance's sites and `delete_site/1` never executes. Every site on a removed
  instance left a live, never-expiring public-read grant on a box the control
  plane no longer tracks.

  ## THE SET OF DELETE SITES, DERIVED NOT ASSUMED

  `grep -n 'Repo.delete\\|delete_all\\|Multi.delete' cloud/lib` over this tree
  yields exactly TWO reachable Barkpark-row deletes, both in `registry.ex`:
  `delete_barkpark/1` (the non-live arm, six router call sites) and
  `succeed_deprovision_job/2` (the LIVE teardown, which calls `Repo.delete(bp)`
  DIRECTLY and does NOT route through `delete_barkpark/1`). Everything else
  deletes some other schema. A fix in only one arm would leave the other open,
  so BOTH are driven below — separately, on purpose: one test covering "an
  instance delete" through whichever arm the fix happened to land in is the
  failure mode this module exists to prevent.

  `succeed_deprovision_job/2` is the arm that matters: it is the path that tears
  down a LIVE box, and a live box is where sites exist.

  ## WHAT IS FAKED

  The box is faked at the ONE transport seam (`:studio_link_http_client`), the
  same seam `site_read_token_revoke_test.exs` uses. What is proven here is the
  control plane's half: which requests it makes, when, and what it concludes.

  `async: false` — the ordering test swaps that seam's module app-wide for a
  probe that records `Repo.in_transaction?/0` at call time, and restores it.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @ws "acme"
  @proj "blog"
  @ds "production"

  # The transport probe: it answers exactly like the fake it delegates to, and
  # records whether the caller was inside a database transaction at the moment
  # the box was called. The revoke runs synchronously in the calling process, so
  # the process dictionary reaches the test process that reads it back.
  defmodule InTransactionProbeClient do
    def request(req) do
      seen = Process.get(:revoke_in_transaction, [])
      Process.put(:revoke_in_transaction, [BarkparkCloud.Repo.in_transaction?() | seen])
      BarkparkCloud.StudioLinkFakeHttpClient.request(req)
    end
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(%{
      url: "https://acme.barkpark.cloud",
      host: "10.0.0.1",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    })
    |> Repo.update!()
  end

  defp bound_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: @ws,
        bootstrap_project: @proj,
        bootstrap_dataset: @ds,
        read_token: "bpt_read_#{n}"
      })

    site
  end

  defp tokens_path, do: "/w/#{@ws}/p/#{@proj}/v1/tokens"

  defp program_inventory(rows) do
    StudioLinkFakeHttpClient.program(%{
      tokens_path() => {:ok, %{status: 200, body: Jason.encode!(%{"tokens" => rows})}},
      "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
    })
  end

  defp token_row(label, id) do
    %{
      "id" => id,
      "label" => label,
      "revoked_at" => nil,
      "inserted_at" => "2026-08-18T09:00:00Z",
      "last_used_at" => nil
    }
  end

  defp requests_to(method, path) do
    StudioLinkFakeHttpClient.requests()
    |> Enum.filter(fn r -> r.method == method and String.contains?(r.url, path) end)
  end

  # A live instance carrying one content-bound site whose credential the box
  # lists as live. Returns {bp, site, token_id}.
  defp instance_with_live_credential do
    bp = team_fixture() |> live_bp()
    # The create mints through the same seam; program an empty inventory first so
    # the mint cannot be mistaken for the revoke's lookup.
    program_inventory([])
    site = bound_site(bp)

    token_id = Ecto.UUID.generate()
    program_inventory([token_row("site-read-#{site.slug}", token_id)])

    {bp, site, token_id}
  end

  describe "ARM 1 — succeed_deprovision_job/2 (the LIVE teardown)" do
    test "the deprovision revokes every site's read token and then deletes the row" do
      {bp, site, token_id} = instance_with_live_credential()
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id)

      revokes = requests_to(:delete, "#{tokens_path()}/#{token_id}")

      # NOT `assert [req] = ..., "msg"` — a match with a custom message raises
      # MatchError before assert/2 runs, and the sentence below would be dead
      # text on the one failure it exists to explain.
      assert length(revokes) == 1,
             "the deprovision must revoke the credential its own site's label names — " <>
               "the FK cascade deletes the site row without ever calling delete_site/1. " <>
               "Saw #{length(revokes)} revokes of #{token_id}."

      [%{url: url}] = revokes

      assert String.contains?(url, "/w/#{@ws}/p/#{@proj}/v1/tokens/#{token_id}"),
             "the revoke URL is assembled from columns of the site row being cascaded away " <>
               "(bootstrap_workspace, bootstrap_project) plus the label derived from its slug — " <>
               "a request naming all three could only be built BEFORE the delete"

      refute Repo.get(Barkpark, bp.id)
      refute Registry.get_site(site.id)
    end

    test "ORDERING: the box is called with NO transaction open — the FOR UPDATE lock is never held across it" do
      # The claim-fence transaction opens with `lock_provision_job/1` (FOR
      # UPDATE). A revoke placed inline would hold that row lock across one HTTP
      # round-trip PER SITE, including against a box that only answers on the
      # client timeout. This is the runtime proof it does not: the transport
      # itself records `Repo.in_transaction?/0` at call time.
      previous = Application.get_env(:barkpark_cloud, :studio_link_http_client)
      Application.put_env(:barkpark_cloud, :studio_link_http_client, InTransactionProbeClient)
      on_exit(fn -> Application.put_env(:barkpark_cloud, :studio_link_http_client, previous) end)

      {bp, _site, token_id} = instance_with_live_credential()
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      Process.put(:revoke_in_transaction, [])
      assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id)

      flags = Process.get(:revoke_in_transaction, [])

      # NON-VACUITY FIRST: a probe that saw no call at all would satisfy
      # "nothing ran inside a transaction" while proving nothing.
      assert flags != [],
             "the probe recorded no box call during the deprovision — this assertion would be " <>
               "vacuously green, and the revoke is not happening at all"

      assert length(requests_to(:delete, "#{tokens_path()}/#{token_id}")) == 1

      refute Enum.any?(flags),
             "the box was called from INSIDE a transaction (#{inspect(flags)}) — the deprovision " <>
               "is holding its FOR UPDATE lock on provision_jobs across an HTTP round-trip"
    end

    test "an UNREACHABLE box does not block the delete, and the leftover is REPORTED on the trail" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)
      team_id = bp.team_id

      # The box answers, but not with a token list. "I could not look" is not
      # "it is not there" — the credential must be assumed live.
      StudioLinkFakeHttpClient.program(%{
        tokens_path() => {:ok, %{status: 503, body: "{}"}},
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
      })

      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      log =
        capture_log(fn ->
          assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id),
                 "a box that is down must not make its instance undeletable — the CP row is the truth"
        end)

      refute Repo.get(Barkpark, bp.id)

      # NOT SWALLOWED, part 1: the warning names the pointer the deleted rows can
      # no longer hold.
      assert log =~ "site-read-#{site.slug}"
      assert log =~ bp.slug

      # NOT SWALLOWED, part 2 — the honesty contract delete_site/1 discharges by
      # returning the outcome to its caller. This arm has no caller to tell (the
      # worker is a Go process posting a success), so the outcome goes somewhere
      # DURABLE instead: the audit event that records the removal.
      team = Accounts.get_team(team_id)
      events = Accounts.list_audit_events(team)

      assert length(events) == 1,
             "the deprovision wrote #{length(events)} audit events, not one — the trail this " <>
               "arm's honesty contract rides on has moved"

      [ev] = events
      assert ev.action == "barkpark.deleted"
      assert ev.metadata["read_tokens"]["error"] == [site.slug]
      assert ev.metadata["read_tokens"]["ok"] == []
    end

    test "a REFUSED deprovision (terminal 'failed' job) revokes nothing" do
      # The preflight runs unlocked, so it must apply the same refusals the
      # locked body applies: a call that is about to be fenced out must not kill
      # a live site's credential on a box that is staying up.
      {bp, _site, token_id} = instance_with_live_credential()
      {:ok, job} = Registry.enqueue_deprovision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      assert {:error, :conflict} = Registry.succeed_deprovision_job(job.id)

      assert requests_to(:delete, "#{tokens_path()}/#{token_id}") == [],
             "a refused deprovision revoked a credential for an instance it then left standing"

      assert %Barkpark{} = Repo.get(Barkpark, bp.id)
    end

    test "a STALE claim revokes nothing" do
      {bp, _site, token_id} = instance_with_live_credential()
      {:ok, job} = Registry.enqueue_deprovision_job(bp)
      assert {claimed, _} = Registry.claim_next_deprovision_job("tok-B")
      assert claimed.id == job.id

      assert {:error, :stale_claim} =
               Registry.succeed_deprovision_job(job.id, claim_token: "tok-A")

      assert requests_to(:delete, "#{tokens_path()}/#{token_id}") == []
      assert %Barkpark{} = Repo.get(Barkpark, bp.id)
    end
  end

  describe "ARM 2 — delete_barkpark/1 (the non-live arm)" do
    test "the delete revokes every site's read token and then deletes the row" do
      {bp, site, token_id} = instance_with_live_credential()

      assert {:ok, _} = Registry.delete_barkpark(bp)

      revokes = requests_to(:delete, "#{tokens_path()}/#{token_id}")

      assert length(revokes) == 1,
             "delete_barkpark/1 is the OTHER Barkpark-row delete — a revoke installed only in " <>
               "the deprovision arm leaves this door open. Saw #{length(revokes)} revokes " <>
               "of #{token_id}."

      [%{url: url}] = revokes
      assert String.contains?(url, "/w/#{@ws}/p/#{@proj}/v1/tokens/#{token_id}")

      refute Repo.get(Barkpark, bp.id)
      refute Registry.get_site(site.id)
    end

    test "an UNREACHABLE box does not block the delete, and the leftover is NAMED in the log" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        tokens_path() => {:ok, %{status: 503, body: "{}"}},
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
      })

      log = capture_log(fn -> assert {:ok, _} = Registry.delete_barkpark(bp) end)

      refute Repo.get(Barkpark, bp.id)
      assert log =~ "site-read-#{site.slug}"
      assert log =~ bp.slug
    end

    test "an instance whose sites have no content binding never calls the box" do
      bp = team_fixture() |> live_bp()

      {:ok, _site} =
        Registry.create_site(bp, %{
          name: "App",
          slug: "app-#{System.unique_integer([:positive])}",
          kind: "container",
          framework: "nextjs"
        })

      StudioLinkFakeHttpClient.program(%{})

      assert {:ok, _} = Registry.delete_barkpark(bp)
      assert requests_to(:get, "/v1/tokens") == []
    end
  end

  describe "the report shape" do
    test "revoke_barkpark_site_read_tokens/1 buckets every site of the instance" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      revoked = bound_site(bp)
      unbound_slug = "app-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Registry.create_site(bp, %{name: "App", slug: unbound_slug, kind: "container"})

      id = Ecto.UUID.generate()
      program_inventory([token_row("site-read-#{revoked.slug}", id)])

      assert %{ok: [revoked_slug], noop: [^unbound_slug], error: []} =
               Registry.revoke_barkpark_site_read_tokens(bp)

      assert revoked_slug == revoked.slug
    end
  end
end
