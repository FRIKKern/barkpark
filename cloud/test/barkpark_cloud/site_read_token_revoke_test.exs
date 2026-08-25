defmodule BarkparkCloud.SiteReadTokenRevokeTest do
  @moduledoc """
  ssw8 — a deleted site must not leave a live read credential behind.

  ## The defect these tests pin

  `Registry.delete_site/1` was exactly

      _ = deregister_content_webhook(site); Repo.delete(site)

  and `grep -n revoke registry.ex` hit only the agent-token and app-token
  surfaces. Nothing in the control plane had ever revoked a site's public-read
  content token, so every site ever spawned and deleted left a never-expiring
  read grant into a live dataset. Measured on guerrilla 2026-07-28: 18 live
  `site-read-*` rows against 12 sites, six of them for sites that no longer
  existed.

  ## Two obligations, and why both are here

    * **The FIX** — a delete revokes, is safe to re-run, and never claims a clean
      teardown it did not get. The last clause is the one a naive fix drops: a
      best-effort revoke that logs and shrugs leaves the credential live AND
      (once the row is gone) unfindable, which is strictly worse than the defect
      because it now looks handled.
    * **The CLEANUP PATH** — `orphan_site_read_tokens/1`, the read that finds the
      credentials already orphaned. A fix that only helps future deletions leaves
      today's six live forever.

  ## What is faked and what is not

  The box is faked at the ONE transport seam (`:studio_link_http_client`), so
  what these tests prove is the control plane's half: which requests it makes,
  in what order, and what it concludes from each answer the box can give. The
  box-side half — that a revoked token actually stops authenticating — is pinned
  in `api/test/barkpark_web/controllers/member_controller_test.exs`
  ("a revoked site-read token STOPS AUTHENTICATING …") against the same two
  routes this module drives.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @ws "acme"
  @proj "blog"
  @ds "production"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Enum.into(attrs, %{
        url: "https://acme.barkpark.cloud",
        git_commit: "abc123",
        admin_token_encrypted: Vault.encrypt("instance-admin-token")
      })
    )
    |> Repo.update!()
  end

  defp bound_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: @ws,
          bootstrap_project: @proj,
          bootstrap_dataset: @ds,
          read_token: "bpt_read_#{n}"
        })
      )

    site
  end

  defp tokens_path, do: "/w/#{@ws}/p/#{@proj}/v1/tokens"

  # Program the box's token inventory for the one scope these sites bind to.
  # The webhook list is programmed alongside so the (unrelated) webhook
  # deregistration in `delete_site/1` cannot be mistaken for a token call.
  defp program_inventory(rows) do
    StudioLinkFakeHttpClient.program(%{
      tokens_path() => {:ok, %{status: 200, body: Jason.encode!(%{"tokens" => rows})}},
      "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
    })
  end

  defp token_row(label, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, Ecto.UUID.generate()),
      "label" => label,
      "revoked_at" => Keyword.get(opts, :revoked_at),
      "inserted_at" => "2026-07-18T09:00:00Z",
      "last_used_at" => Keyword.get(opts, :last_used_at)
    }
  end

  defp requests_to(method, path) do
    StudioLinkFakeHttpClient.requests()
    |> Enum.filter(fn r -> r.method == method and String.contains?(r.url, path) end)
  end

  describe "the fix: delete_site/1 revokes the site's read token" do
    test "the delete issues the box revoke for THIS site's label, and reports :ok" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      id = Ecto.UUID.generate()
      program_inventory([token_row("site-read-#{site.slug}", id: id)])

      assert {:ok, deleted, %{read_token: :ok}} = Registry.delete_site(site)
      assert deleted.id == site.id

      assert [_req] = requests_to(:delete, "#{tokens_path()}/#{id}"),
             "the delete must revoke the credential its own site's label names"

      # And the CP row is gone — the revoke is part of the delete, not instead of it.
      refute Registry.get_site(site.id)
    end

    test "ORDER: the revoke happens BEFORE the row is deleted" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      id = Ecto.UUID.generate()
      program_inventory([token_row("site-read-#{site.slug}", id: id)])

      assert {:ok, _, %{read_token: :ok}} = Registry.delete_site(site)

      # The proof is not the timestamp — it is that the request could be BUILT at
      # all. Its URL is assembled from three columns of the row being deleted
      # (bootstrap_workspace, bootstrap_project) plus the label derived from
      # `slug`. A revoke attempted after `Repo.delete/1` has no row to read them
      # from, so a request naming all three IS the ordering assertion.
      assert [%{url: url}] = requests_to(:delete, "#{tokens_path()}/#{id}")
      assert String.contains?(url, "/w/#{@ws}/p/#{@proj}/v1/tokens/#{id}")
    end

    test "RE-RUNNABLE: a site whose token is already revoked reports :ok and issues no revoke" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      program_inventory([
        token_row("site-read-#{site.slug}", revoked_at: "2026-07-20T10:00:00Z")
      ])

      assert {:ok, _, %{read_token: :ok}} = Registry.delete_site(site)

      assert requests_to(:delete, "#{tokens_path()}/") == [],
             "an already-revoked credential must not be revoked again — a second DELETE would " <>
               "404 and (correctly) be read as a failure, turning a clean re-run into an error"
    end

    test "RE-RUNNABLE: a label the box does not list at all is :ok, not an error" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      # Somebody else's credential, and nothing of this site's.
      program_inventory([token_row("site-read-some-other-site")])

      assert {:ok, _, %{read_token: :ok}} = Registry.delete_site(site)
      assert requests_to(:delete, "#{tokens_path()}/") == []
    end

    test "a site with NO content binding is :noop — the box is never called about it" do
      bp = team_fixture() |> live_bp()
      program_inventory([])

      {:ok, site} =
        Registry.create_site(bp, %{
          name: "App",
          slug: "app-#{System.unique_integer([:positive])}",
          kind: "container",
          framework: "nextjs"
        })

      StudioLinkFakeHttpClient.program(%{})

      assert {:ok, _, %{read_token: :noop}} = Registry.delete_site(site)
      assert requests_to(:get, "/v1/tokens") == []
    end

    test "an UNREADABLE inventory is :error — never :ok — and the delete still completes" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      # The box answers, but not with a token list. "I could not look" must not
      # render as "it is not there": that is precisely the collapse that would
      # let a live credential be reported as revoked.
      StudioLinkFakeHttpClient.program(%{
        tokens_path() => {:ok, %{status: 503, body: "{}"}},
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
      })

      assert {:ok, _, %{read_token: :error}} = Registry.delete_site(site)

      # A box that is down must not make its sites undeletable — the CP row is
      # the truth. The honesty obligation is discharged by the :error, which the
      # router turns into a 200 that names the leftover.
      refute Registry.get_site(site.id)
    end

    test "a box that REFUSES the revoke is :error, and a 404 is NOT read as 'already gone'" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp)

      id = Ecto.UUID.generate()

      StudioLinkFakeHttpClient.program(%{
        tokens_path() =>
          {:ok,
           %{
             status: 200,
             body: Jason.encode!(%{"tokens" => [token_row("site-read-#{site.slug}", id: id)]})
           }},
        "#{tokens_path()}/#{id}" => {:ok, %{status: 404, body: "{}"}},
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
      })

      # A 404 here has two readings and only one of them is safe: the token holds
      # no seat (gone), OR this box predates the revoke route entirely (very much
      # alive). We refuse to guess in the credential's favour.
      assert {:ok, _, %{read_token: :error}} = Registry.delete_site(site)
    end

    test "the label the revoke looks for is the SAME one the mint writes" do
      # One definition or the leak reopens silently: the CP stores only the
      # ciphertext, never the token's box-side id, so the label IS the pointer.
      bp = team_fixture() |> live_bp()
      program_inventory([])
      site = bound_site(bp, %{slug: "brochure-#{System.unique_integer([:positive])}"})

      assert Registry.site_read_token_label(site) == "site-read-#{site.slug}"
      assert Registry.site_read_token_label(site.slug) == Registry.site_read_token_label(site)

      # And the router's mint sends exactly this string (mint_site_read_token/3
      # calls site_read_token_label/1 — asserted at the source so a literal
      # cannot creep back in).
      router = File.read!(Path.join([__DIR__, "..", "..", "lib/barkpark_cloud/web/router.ex"]))

      assert router =~ "Registry.site_read_token_label(slug)",
             "the mint must derive the label from the ONE definition"

      refute router =~ "Registry.mint_public_read_token(bp, ws, proj, ds, \"",
             "the mint must not pass a locally-built label literal"
    end
  end

  describe "the cleanup path: orphan_site_read_tokens/1" do
    test "reports the credential of a site that no longer exists" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      live_site = bound_site(bp)

      orphan_id = Ecto.UUID.generate()

      program_inventory([
        # a credential for a site that still exists — NOT an orphan
        token_row("site-read-#{live_site.slug}"),
        # already revoked — NOT an orphan (it cannot authenticate)
        token_row("site-read-proof-20260718-27956", revoked_at: "2026-08-01T00:00:00Z"),
        # not a site credential at all — NOT an orphan
        token_row("studio-admin"),
        # the real thing
        token_row("site-read-proof-20260718-30897", id: orphan_id, last_used_at: nil)
      ])

      assert {:ok, [orphan]} = Registry.orphan_site_read_tokens(bp)
      assert orphan.id == orphan_id
      assert orphan.label == "site-read-proof-20260718-30897"
      assert orphan.site_slug == "proof-20260718-30897"
      assert orphan.workspace == @ws
      assert orphan.project == @proj
      assert orphan.barkpark_slug == bp.slug
    end

    test "an UNREADABLE inventory is an error, NEVER an empty list" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      _site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{
        tokens_path() => {:ok, %{status: 500, body: "nope"}}
      })

      # `{:ok, []}` here would render as "this box is clean" in the audit — the
      # exact false green the row is about.
      assert {:error, :unreadable} = Registry.orphan_site_read_tokens(bp)
    end

    test "a box with no workspace scope to look under says so" do
      bp = team_fixture() |> live_bp()
      StudioLinkFakeHttpClient.program(%{})

      assert {:error, :no_scope} = Registry.orphan_site_read_tokens(bp)
    end

    test "the sweep REVOKES NOTHING" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      _site = bound_site(bp)
      program_inventory([token_row("site-read-proof-20260718-86717")])

      assert {:ok, [_]} = Registry.orphan_site_read_tokens(bp)

      assert requests_to(:delete, "/v1/tokens/") == [],
             "identifying an orphan is a read; killing a live credential is an owner decision"
    end
  end

  describe "the cleanup path's safety rail" do
    test "--revoke REFUSES an id that is not in the orphan set" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      live_site = bound_site(bp)

      live_id = Ecto.UUID.generate()
      program_inventory([token_row("site-read-#{live_site.slug}", id: live_id)])

      # The credential of a site that STILL EXISTS. Typing its id must not kill it.
      assert {:error, :not_an_orphan} =
               Mix.Tasks.BarkparkCloud.SiteReadTokens.revoke_orphan(bp.slug, live_id)

      assert requests_to(:delete, "/v1/tokens/") == []
    end

    test "an unresolvable instance is refused before any box call" do
      assert {:error, :barkpark_not_found} =
               Mix.Tasks.BarkparkCloud.SiteReadTokens.revoke_orphan(
                 "no-such-box",
                 Ecto.UUID.generate()
               )
    end

    test "the audit carries per-box errors instead of dropping them" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      _site = bound_site(bp)

      StudioLinkFakeHttpClient.program(%{tokens_path() => {:ok, %{status: 500, body: "nope"}}})

      assert [{audited, {:error, :unreadable}}] =
               Mix.Tasks.BarkparkCloud.SiteReadTokens.audit_boxes([bp.slug])

      assert audited.id == bp.id
    end

    test "a real orphan CAN be revoked once it is named, and the box call is the scoped DELETE" do
      bp = team_fixture() |> live_bp()
      program_inventory([])
      _site = bound_site(bp)

      orphan_id = Ecto.UUID.generate()

      StudioLinkFakeHttpClient.program(%{
        tokens_path() =>
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "tokens" => [token_row("site-read-proof-20260718-93370", id: orphan_id)]
               })
           }},
        "#{tokens_path()}/#{orphan_id}" => {:ok, %{status: 200, body: "{}"}}
      })

      assert :ok = Mix.Tasks.BarkparkCloud.SiteReadTokens.revoke_orphan(bp.slug, orphan_id)
      assert [_] = requests_to(:delete, "#{tokens_path()}/#{orphan_id}")
    end
  end

  describe "the wire: DELETE /v1/sites/:id states the credential half" do
    @router_opts Router.init([])

    defp user_with_team do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Accounts.register_user(%{
          email: "srt-#{n}@example.com",
          password: "correct-horse-battery"
        })

      {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {user, team}
    end

    defp delete_site_call(user, site) do
      {:ok, token} = Accounts.create_user_session_token(user)

      conn(:delete, "/v1/sites/#{site.id}")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@router_opts)
    end

    test "a confirmed revoke answers read_token: \"revoked\" and adds NO warning" do
      {user, team} = user_with_team()
      bp = live_bp(team)
      program_inventory([])
      site = bound_site(bp)

      program_inventory([token_row("site-read-#{site.slug}")])

      resp = delete_site_call(user, site)
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["ok"] == true
      assert body["status"] == "deleted"
      assert body["read_token"] == "revoked"
      refute Map.has_key?(body, "warning")
    end

    test "an UNCONFIRMED revoke still deletes, but the 200 says so and NAMES the leftover" do
      {user, team} = user_with_team()
      bp = live_bp(team)
      program_inventory([])
      site = bound_site(bp)

      # The box cannot be read, so the credential's state is unknown.
      StudioLinkFakeHttpClient.program(%{
        tokens_path() => {:ok, %{status: 503, body: "{}"}},
        "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
      })

      resp = delete_site_call(user, site)
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      # The delete DID happen — a box that is down must not make a site undeletable.
      assert body["ok"] == true
      assert body["status"] == "deleted"
      refute Registry.get_site(site.id)

      # …and it does NOT claim a clean teardown it did not get.
      assert body["read_token"] == "not_revoked"

      # The warning must carry the pointer the deleted row can no longer hold:
      # which box, which workspace scope, which label. Without all three the
      # credential is live AND unfindable.
      warning = body["warning"]
      assert is_binary(warning)
      assert warning =~ bp.slug
      assert warning =~ Registry.site_read_token_label(site)
      assert warning =~ "#{@ws}/#{@proj}"
      assert warning =~ "mix barkpark_cloud.site_read_tokens"
    end

    test "a site with no content binding answers read_token: \"none\", not a false \"revoked\"" do
      {user, team} = user_with_team()
      bp = live_bp(team)
      StudioLinkFakeHttpClient.program(%{})

      {:ok, site} =
        Registry.create_site(bp, %{
          name: "App",
          slug: "app-#{System.unique_integer([:positive])}",
          kind: "container",
          framework: "nextjs"
        })

      body = delete_site_call(user, site) |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert body["read_token"] == "none"
      refute Map.has_key?(body, "warning")
    end
  end
end
