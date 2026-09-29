defmodule BarkparkCloud.InstanceDeleteContentWebhookDeregisterTest do
  @moduledoc """
  Deleting an INSTANCE must not strand its sites' content-publish webhooks
  (task-e360d05a2708fdb0).

  ## The defect these tests pin

  stw9 closed the leak on the SITE delete path: `delete_site/1` deregisters the
  site's `site-autodeploy-<id>` row from the box before `Repo.delete`. That fix is
  INVISIBLE to the instance delete path, because `sites.barkpark_id` is
  `references(:barkparks, on_delete: :delete_all)` — the DATABASE removes an
  instance's sites and `delete_site/1` never executes. On origin/main before this
  change, `delete_barkpark/1` was two lines: revoke the read tokens (ssw8's second
  door), then `Repo.delete`. Nothing touched the webhooks, so every content-bound
  site on a removed instance left an endpoint delivering 404s to a receiver that no
  longer resolves — re-probed forever by the box's HALF-OPEN auto-disable latch
  (`api/lib/barkpark/webhooks.ex`) — and the instance row that was deleted was the
  last thing that could name the box to reap it.

  This is the SAME defect ssw8 measured for credentials, reached by the same door,
  in the half that was left open. The sibling arm `succeed_deprovision_job/2` is
  deliberately NOT covered here: it is the LIVE teardown, and it runs after the Go
  worker has destroyed the server — there is no box left holding a webhook. That
  asymmetry is why the credential fix needed both arms and this one does not: a
  token orphan lives in the control plane's memory of a scope, a webhook orphan
  lives on a machine.

  ## What is faked

  The box is faked at the ONE transport seam (`:studio_link_http_client`).
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

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(%{
      url: "https://acme.barkpark.cloud",
      host: "10.0.0.1",
      git_commit: "abc123",
      bootstrap_workspace: @ws,
      bootstrap_project: @proj,
      bootstrap_dataset: @ds,
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

  defp program_webhooks(rows) do
    StudioLinkFakeHttpClient.program(%{
      "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => rows})}},
      "/w/#{@ws}/p/#{@proj}/v1/tokens" =>
        {:ok, %{status: 200, body: Jason.encode!(%{"tokens" => []})}}
    })
  end

  defp hook(name, id),
    do: %{"id" => id, "name" => name, "url" => "https://api.barkpark.cloud/x", "active" => true}

  defp deletes_to(path) do
    StudioLinkFakeHttpClient.requests()
    |> Enum.filter(fn r -> r.method == :delete and String.contains?(r.url, path) end)
  end

  describe "delete_barkpark/1 deregisters the webhook of every site it cascades away" do
    test "ONE box :delete per content-bound site, before the row is gone" do
      bp = live_bp()
      program_webhooks([])
      site_a = bound_site(bp)
      site_b = bound_site(bp)

      id_a = Ecto.UUID.generate()
      id_b = Ecto.UUID.generate()

      program_webhooks([
        hook("site-autodeploy-#{site_a.id}", id_a),
        hook("site-autodeploy-#{site_b.id}", id_b)
      ])

      assert {:ok, _} = Registry.delete_barkpark(bp)

      deletes_a = deletes_to("/v1/webhooks/#{@ds}/#{id_a}")
      deletes_b = deletes_to("/v1/webhooks/#{@ds}/#{id_b}")

      # NOT `assert [req] = ..., "msg"` — a match with a custom message raises
      # MatchError before assert/2 runs, and the sentence would be dead text on
      # the one failure it exists to explain.
      assert length(deletes_a) == 1,
             "delete_barkpark/1 must deregister site #{site_a.slug}'s webhook: the FK cascade " <>
               "removes the site row without ever calling delete_site/1, where the only " <>
               "deregister lived. Saw #{length(deletes_a)} :delete of #{id_a}."

      assert length(deletes_b) == 1,
             "the second site's webhook was left on the box — the deregister must run for " <>
               "EVERY content-bound site the cascade removes, not just the first. Saw " <>
               "#{length(deletes_b)} :delete of #{id_b}."

      # The request could only be assembled from columns of the rows being
      # cascaded away: the dataset names the route, the site id names the row.
      refute Repo.get(Barkpark, bp.id)
      refute Registry.get_site(site_a.id)
      refute Registry.get_site(site_b.id)
    end

    test "an UNREACHABLE box does not block the delete, and the leftover is NAMED in the log" do
      bp = live_bp()
      program_webhooks([])
      site = bound_site(bp)

      # The box answers, but not with a webhook list. "I could not look" is not
      # "it is not there" — the row must be assumed live.
      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 503, body: "{}"}},
        "/w/#{@ws}/p/#{@proj}/v1/tokens" =>
          {:ok, %{status: 200, body: Jason.encode!(%{"tokens" => []})}}
      })

      log =
        capture_log(fn ->
          assert {:ok, _} = Registry.delete_barkpark(bp),
                 "a box that is down must not make its instance undeletable — the CP row is the truth"
        end)

      refute Repo.get(Barkpark, bp.id)

      assert log =~ "site-autodeploy-#{site.id}",
             "the warning must name the pointer the deleted rows can no longer hold"

      assert log =~ bp.slug
      assert log =~ "mix barkpark_cloud.content_webhooks"
    end

    test "a site with no content binding never calls the box for a webhook" do
      bp = live_bp()

      {:ok, _site} =
        Registry.create_site(bp, %{
          name: "App",
          slug: "app-#{System.unique_integer([:positive])}",
          kind: "container",
          framework: "nextjs"
        })

      StudioLinkFakeHttpClient.program(%{})

      assert {:ok, _} = Registry.delete_barkpark(bp)
      assert deletes_to("/v1/webhooks/") == []
    end
  end

  describe "the report shape" do
    test "deregister_barkpark_content_webhooks/1 buckets every site of the instance" do
      bp = live_bp()
      program_webhooks([])
      bound = bound_site(bp)
      unbound_slug = "app-#{System.unique_integer([:positive])}"

      {:ok, _} = Registry.create_site(bp, %{name: "App", slug: unbound_slug, kind: "container"})

      program_webhooks([hook("site-autodeploy-#{bound.id}", Ecto.UUID.generate())])

      assert %{ok: [ok_slug], noop: [^unbound_slug], error: []} =
               Registry.deregister_barkpark_content_webhooks(bp)

      assert ok_slug == bound.slug
    end

    test "an unreadable list is :error, never :noop" do
      bp = live_bp()
      program_webhooks([])
      site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 503, body: "{}"}}
      })

      capture_log(fn ->
        assert %{ok: [], noop: [], error: [slug]} =
                 Registry.deregister_barkpark_content_webhooks(bp)

        assert slug == site.slug
      end)
    end

    test "a box that lists no row for this site is :ok — the deregister's whole point" do
      bp = live_bp()
      program_webhooks([])
      site = bound_site(bp)
      program_webhooks([])

      assert %{ok: [slug], noop: [], error: []} =
               Registry.deregister_barkpark_content_webhooks(bp)

      assert slug == site.slug
      assert deletes_to("/v1/webhooks/") == []
    end
  end
end
