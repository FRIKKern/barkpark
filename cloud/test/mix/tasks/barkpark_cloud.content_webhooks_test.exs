defmodule Mix.Tasks.BarkparkCloud.ContentWebhooksTest do
  @moduledoc """
  THE REAP that two registry docstrings promised and nothing implemented
  (task-e360d05a2708fdb0).

  ## The defect these tests pin

  `registry.ex` said, above `delete_site/1` and above `deregister_content_webhook/1`,
  that a box which is down "simply keeps an orphan we can reap later (the same
  reconciler above finds it by name)". Measured on origin/main before this change:
  `reconcile_content_webhooks/1` folds over `list_content_webhook_sites/1`, a query
  over the LIVE `sites` table, and `do_ensure_content_webhook/4` issues only
  `:put`/`:post`. A deleted site has left that table, so the sweep never sees its
  box row — and the only `:delete` against `/v1/webhooks` in the whole tree lived
  inside `deregister_content_webhook/1`, whose one production caller was
  `delete_site/1`. There was no reaper. This module drives the one that now exists.

  ## What is faked

  The box is faked at the ONE transport seam (`:studio_link_http_client`), the same
  seam `site_read_token_revoke_test.exs` and
  `instance_delete_site_read_token_revoke_test.exs` use. What is proven here is the
  control plane's half: which requests it makes, and what it refuses to make.

  The task's testable core (`audit_boxes/1`, `reap_orphan/2`, `reap_all_orphans/1`,
  `audit_lines/1`) is driven directly — no Mix process and no `app.start`, so the
  Ecto sandbox owns the connection (the `CreateAdminTest` precedent).
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias Mix.Tasks.BarkparkCloud.ContentWebhooks

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

  defp hook(name, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, Ecto.UUID.generate()),
      "name" => name,
      "url" => "https://api.barkpark.cloud/v1/sites/webhooks/content-publish/x",
      "active" => Keyword.get(opts, :active, true)
    }
  end

  # Program the box's webhook inventory for the one dataset these sites bind to.
  defp program_webhooks(rows) do
    StudioLinkFakeHttpClient.program(%{
      "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => rows})}},
      "/w/#{@ws}/p/#{@proj}/v1/tokens" =>
        {:ok, %{status: 200, body: Jason.encode!(%{"tokens" => []})}}
    })
  end

  defp deletes_to(path) do
    StudioLinkFakeHttpClient.requests()
    |> Enum.filter(fn r -> r.method == :delete and String.contains?(r.url, path) end)
  end

  # An instance whose box holds one orphan row (a site that no longer exists) and
  # one LIVE row (the site that is still here). Returns {bp, live_site, orphan_id,
  # dead_site_id}.
  defp box_with_one_orphan do
    bp = live_bp()
    program_webhooks([])
    site = bound_site(bp)

    dead_site_id = Ecto.UUID.generate()
    orphan_id = Ecto.UUID.generate()
    live_id = Ecto.UUID.generate()

    program_webhooks([
      hook("site-autodeploy-#{site.id}", id: live_id),
      hook("site-autodeploy-#{dead_site_id}", id: orphan_id)
    ])

    {bp, site, orphan_id, dead_site_id, live_id}
  end

  describe "the audit — enumerate the BOX, keep what the database still owns" do
    test "an orphan row is found, and the live site's row is NOT" do
      {bp, _site, orphan_id, dead_site_id, _live_id} = box_with_one_orphan()

      assert [{found_bp, {:ok, orphans}}] = ContentWebhooks.audit_boxes([bp.slug])
      assert found_bp.id == bp.id

      assert length(orphans) == 1,
             "the sweep must keep exactly the row whose site id is gone from `sites` and drop " <>
               "the one whose site still exists. Saw #{inspect(Enum.map(orphans, & &1.name))}."

      [orphan] = orphans
      assert orphan.id == orphan_id
      assert orphan.site_id == dead_site_id
      assert orphan.name == "site-autodeploy-#{dead_site_id}"
      assert orphan.dataset == @ds
    end

    test "a hook whose name is not site-autodeploy-<uuid> is never ours" do
      bp = live_bp()
      program_webhooks([])
      _site = bound_site(bp)

      program_webhooks([
        hook("deploy-hook-by-hand"),
        hook("site-autodeploy-not-a-uuid"),
        hook("site-autodeploy-")
      ])

      assert [{_bp, {:ok, []}}] = ContentWebhooks.audit_boxes([bp.slug]),
             "a hand-made hook, and a name that does not parse as a site id, must never enter " <>
               "the orphan set — the reap deletes what this list contains"
    end

    test "an UNREADABLE inventory is reported as unreadable, never as 'no orphans'" do
      bp = live_bp()
      program_webhooks([])
      _site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 503, body: "{}"}}
      })

      assert [{_bp, {:error, :unreadable}}] = ContentWebhooks.audit_boxes([bp.slug])
    end

    test "an instance with no dataset to look under is :no_dataset, not a clean bill" do
      {:ok, bp} =
        Registry.register_barkpark(team_fixture(), %{
          name: "Bare",
          slug: "bare-#{System.unique_integer([:positive])}"
        })

      assert [{_bp, {:error, :no_dataset}}] = ContentWebhooks.audit_boxes([bp.slug])
    end

    test "the audit is READ-ONLY — it issues no :delete" do
      {bp, _site, _orphan_id, _dead, _live} = box_with_one_orphan()

      assert [{_bp, {:ok, [_one]}}] = ContentWebhooks.audit_boxes([bp.slug])

      assert deletes_to("/v1/webhooks/") == [],
             "the audit deleted something. It hands a human a list; the reap is a separate verb."
    end

    test "the printed lines name the orphan, its box and the command that reaps it" do
      {bp, _site, orphan_id, dead_site_id, _live} = box_with_one_orphan()

      text =
        bp.slug
        |> List.wrap()
        |> ContentWebhooks.audit_boxes()
        |> ContentWebhooks.audit_lines()
        |> Enum.join("\n")

      assert text =~ "1 ORPHAN site-autodeploy webhook(s)"
      assert text =~ "site-autodeploy-#{dead_site_id}"
      assert text =~ "mix barkpark_cloud.content_webhooks #{bp.slug} --reap #{orphan_id}"
      assert text =~ "1 orphan site-autodeploy webhook(s) across 1 instance(s)"
    end

    test "the summary states the unreadable denominator alongside the count" do
      bp = live_bp()
      program_webhooks([])
      _site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 503, body: "{}"}}
      })

      text =
        bp.slug
        |> List.wrap()
        |> ContentWebhooks.audit_boxes()
        |> ContentWebhooks.audit_lines()
        |> Enum.join("\n")

      assert text =~ "0 orphan site-autodeploy webhook(s) across 1 instance(s)"
      assert text =~ "1 instance(s) could not be read (#{bp.slug})"
    end
  end

  describe "the reap — the :delete this repo did not have" do
    test "--reap issues the box DELETE for exactly that orphan's id" do
      {bp, _site, orphan_id, dead_site_id, _live} = box_with_one_orphan()

      assert :ok = ContentWebhooks.reap_orphan(bp.slug, orphan_id)

      deletes = deletes_to("/v1/webhooks/#{@ds}/#{orphan_id}")

      assert length(deletes) == 1,
             "the reap must issue ONE :delete naming the orphan's dataset and box-side id — " <>
               "this is the request nothing in this repo could make. Saw #{length(deletes)} " <>
               "for #{"site-autodeploy-#{dead_site_id}"}."
    end

    test "--reap REFUSES an id belonging to a site that still exists" do
      {bp, site, _orphan_id, _dead, live_id} = box_with_one_orphan()

      assert {:error, :not_an_orphan} = ContentWebhooks.reap_orphan(bp.slug, live_id)

      assert deletes_to("/v1/webhooks/") == [],
             "the tool deleted the LIVE site #{site.slug}'s trigger by id. The orphan set is " <>
               "re-derived at reap time precisely so a typo cannot do this."
    end

    test "--reap against an UNREADABLE box is refused, not attempted" do
      bp = live_bp()
      program_webhooks([])
      _site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 503, body: "{}"}}
      })

      assert {:error, :unreadable} = ContentWebhooks.reap_orphan(bp.slug, Ecto.UUID.generate())
      assert deletes_to("/v1/webhooks/") == []

      assert ContentWebhooks.reap_error_line(bp.slug, "id", :unreadable) =~
               "could not be derived (unreadable)"
    end

    test "an unknown box ref reaps nothing" do
      assert {:error, :barkpark_not_found} =
               ContentWebhooks.reap_orphan("no-such-box", Ecto.UUID.generate())

      assert deletes_to("/v1/webhooks/") == []
    end

    test "a box that does not confirm the delete reports :reap_failed — never a silent success" do
      {bp, _site, orphan_id, dead_site_id, live_id} = box_with_one_orphan()

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" =>
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "webhooks" => [
                   hook("site-autodeploy-#{dead_site_id}", id: orphan_id),
                   hook("site-autodeploy-live", id: live_id)
                 ]
               })
           }},
        "/v1/webhooks/#{@ds}/#{orphan_id}" => {:ok, %{status: 500, body: "{}"}}
      })

      assert {:error, :reap_failed} = ContentWebhooks.reap_orphan(bp.slug, orphan_id)
      assert length(deletes_to("/v1/webhooks/#{@ds}/#{orphan_id}")) == 1
    end

    test "--reap-all deletes every orphan and leaves the live row alone" do
      bp = live_bp()
      program_webhooks([])
      site = bound_site(bp)

      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      live_id = Ecto.UUID.generate()

      program_webhooks([
        hook("site-autodeploy-#{Ecto.UUID.generate()}", id: a),
        hook("site-autodeploy-#{site.id}", id: live_id),
        hook("site-autodeploy-#{Ecto.UUID.generate()}", id: b)
      ])

      assert {:ok, %{reaped: reaped, failed: []}} = ContentWebhooks.reap_all_orphans(bp.slug)
      assert Enum.sort(reaped) == Enum.sort([a, b])

      assert length(deletes_to("/v1/webhooks/#{@ds}/#{a}")) == 1
      assert length(deletes_to("/v1/webhooks/#{@ds}/#{b}")) == 1

      assert deletes_to("/v1/webhooks/#{@ds}/#{live_id}") == [],
             "--reap-all deleted the live site's trigger. It reaps the ORPHAN SET, not the list."
    end

    test "--reap-all on an UNREADABLE box reaps nothing" do
      bp = live_bp()
      program_webhooks([])
      _site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 503, body: "{}"}}
      })

      assert {:error, :unreadable} = ContentWebhooks.reap_all_orphans(bp.slug)
      assert deletes_to("/v1/webhooks/") == []
    end
  end
end
