defmodule BarkparkCloud.Web.RouterSiteRebindTest do
  @moduledoc """
  site-spawner `site-rebind-content` — PATCH /v1/sites/:id moves a static/node
  site's CONTENT BINDING (workspace/project/dataset) and re-mints the scope-bound
  public-read credential in the same request.

  Before this, the binding was write-once at create: a typo'd dataset, or a
  promotion from staging to production, cost a DELETE + recreate — a new id, a new
  slug, a new URL, and every domain re-bound by hand. The allow-list at the PATCH
  door was `Map.take(["theme", "doc_type", "prebuilt_enabled"])`, so a body naming
  a workspace answered `nothing_to_update`.

  What each test here pins, and why it would not be caught elsewhere:

    * the triple is ONE value — a `dataset`-only PATCH is refused with create's
      OWN copy, because a partial rebind would mint a token scoped to the OLD
      workspace and the NEW dataset;
    * the credential moves WITH the binding — the row's token is the new one, and
      the OLD one is revoked BY ID in the OLD scope;
    * the id, not the label. A dataset-only rebind keeps workspace/project, so for
      a moment TWO live tokens carry `site-read-<slug>` in that one scope and a
      find-by-label revoke could kill the one the site just started using;
    * a refusal changes NOTHING — an unreadable new binding, and an unreadable
      credential inventory, both leave the row exactly as it was.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"
  @instance_admin_token "instance-admin-token-plaintext"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])

    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> BarkparkCloud.Repo.update!()
  end

  defp static_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read_OLD"
        })
      )

    site
  end

  defp container_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "App #{n}",
        slug: "app-#{n}",
        kind: "container",
        framework: "nextjs"
      })

    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp token_list(id, label),
    do: ~s({"tokens":[{"id":"#{id}","label":"#{label}","revoked_at":null}]})

  defp requested?(method, path) do
    Enum.any?(StudioLinkFakeHttpClient.requests(), fn r ->
      r.method == method and URI.parse(r.url).path == path
    end)
  end

  ## ── The rebind ────────────────────────────────────────────────────────────

  describe "PATCH /v1/sites/:id — content rebind" do
    test "a full triple moves the binding, re-mints the token for the NEW scope, and revokes the old one" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      label = Registry.site_read_token_label(site)

      StudioLinkFakeHttpClient.program(%{
        # 1. the incumbent, named in the OLD scope BEFORE anything is minted
        "/w/acme/p/blog/v1/tokens" => {:ok, %{status: 200, body: token_list("tok-old", label)}},
        # 2. the replacement, minted in the NEW scope
        "/w/acme/p/press/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_NEW"})}},
        # 3. the new binding, READ BACK with the new token
        "/w/acme/p/press/v1/data/query/staging/post" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"total":7,"documents":[{}]}})}},
        # 4. the incumbent, revoked by ID in the OLD scope
        "/w/acme/p/blog/v1/tokens/tok-old" => {:ok, %{status: 200, body: ~s({"ok":true})}}
      })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          login_token(user)
        )

      assert conn.status == 200
      body = json_body(conn)

      # THE BINDING MOVED — all three columns, on the row, not just in the reply.
      assert body["site"]["bootstrap_dataset"] == "staging"
      row = Registry.get_site(site.id)
      assert row.bootstrap_workspace == "acme"
      assert row.bootstrap_project == "press"
      assert row.bootstrap_dataset == "staging"

      # THE CREDENTIAL MOVED WITH IT. A rebind that kept the old token would be a
      # site whose next build 403s: the token is scoped to workspace/project/dataset.
      assert Vault.decrypt(row.read_token_encrypted) == {:ok, "bpt_public_read_NEW"}

      # The mint went to the NEW scope, and the site's own token PROVED the new
      # binding readable before the row was written.
      assert requested?(:post, "/w/acme/p/press/v1/tokens")
      assert body["content_binding"] == %{"status" => "bound", "doc_type" => "post", "count" => 7}

      # The OLD credential is dead, BY ID, in the OLD scope — and the route says so.
      assert requested?(:delete, "/w/acme/p/blog/v1/tokens/tok-old")
      assert body["previous_read_token"] == "ok"
      assert row.content_binding_verdict == "bound"
      refute is_nil(row.content_binding_checked_at)
    end

    test "a dataset-only rebind revokes the INCUMBENT id, not the same-label replacement" do
      # THE HAZARD: workspace/project are unchanged, so both the incumbent and the
      # replacement carry `site-read-<slug>` in ONE scope for the width of the
      # write. A find-by-label revoke here is a coin flip on the live credential.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      label = Registry.site_read_token_label(site)

      StudioLinkFakeHttpClient.program(%{
        # ONE body serves the list (GET) and the mint (POST) — the fake is
        # path-keyed, and this is the collision the test is about. The list shows
        # ONLY the incumbent, which is exactly what a pre-mint read sees.
        "/w/acme/p/blog/v1/tokens" =>
          {:ok,
           %{
             status: 200,
             body:
               ~s({"token":"bpt_public_read_NEW","tokens":[{"id":"tok-incumbent","label":"#{label}","revoked_at":null}]})
           }},
        "/w/acme/p/blog/v1/data/query/staging/post" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"total":3,"documents":[{}]}})}},
        "/w/acme/p/blog/v1/tokens/tok-incumbent" => {:ok, %{status: 200, body: ~s({"ok":true})}}
      })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "blog", dataset: "staging"},
          login_token(user)
        )

      assert conn.status == 200
      assert Registry.get_site(site.id).bootstrap_dataset == "staging"
      assert requested?(:delete, "/w/acme/p/blog/v1/tokens/tok-incumbent")
      assert json_body(conn)["previous_read_token"] == "ok"
    end

    test "a rebind may carry theme/doc_type in the SAME write, verified against the NEW pair" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      label = Registry.site_read_token_label(site)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" => {:ok, %{status: 200, body: token_list("tok-old", label)}},
        "/w/acme/p/press/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_NEW"})}},
        # The verify probes `paper`, the type this PATCH is asking for — NOT the
        # `post` the row holds right now. A rebind that checked the old type would
        # green a pair nobody requested.
        "/w/acme/p/press/v1/data/query/staging/paper" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"total":9,"documents":[{}]}})}},
        "/w/acme/p/blog/v1/tokens/tok-old" => {:ok, %{status: 200, body: ~s({"ok":true})}}
      })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{
            workspace: "acme",
            project: "press",
            dataset: "staging",
            doc_type: "paper",
            theme: "ember"
          },
          login_token(user)
        )

      assert conn.status == 200
      assert json_body(conn)["content_binding"]["doc_type"] == "paper"

      row = Registry.get_site(site.id)
      assert row.doc_type == "paper"
      assert row.theme == "ember"
      assert row.bootstrap_dataset == "staging"
    end
  end

  ## ── The refusals ──────────────────────────────────────────────────────────

  describe "PATCH /v1/sites/:id — a partial or impossible rebind" do
    test "dataset alone → 422 content_binding_required, in create's OWN words, nothing changed" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      # `create_site/2` registers this site's content webhook on the box, so the
      # log is non-empty before the PATCH. Reset it: what this test asserts is
      # that the REFUSED rebind made no call of its own.
      StudioLinkFakeHttpClient.program(%{})

      conn =
        call(:patch, "/v1/sites/#{site.id}", %{dataset: "staging"}, login_token(user))

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "content_binding_required"
      assert body["detail"] =~ "missing: workspace, project"
      assert body["detail"] =~ "--dataset <workspace>/<project>/<dataset>"

      # THE ATOMICITY: not one column moved, and no credential was minted.
      row = Registry.get_site(site.id)
      assert row.bootstrap_dataset == "production"
      assert Vault.decrypt(row.read_token_encrypted) == {:ok, "bpt_public_read_OLD"}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "workspace + project without dataset → 422, naming the ONE missing leg" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press"},
          login_token(user)
        )

      assert conn.status == 422
      assert json_body(conn)["detail"] =~ "missing: dataset"
      assert Registry.get_site(site.id).bootstrap_project == "blog"
    end

    test "a container site has no binding to move → 422 content_binding_not_applicable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = container_site(bp)

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          login_token(user)
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "content_binding_not_applicable"
      assert json_body(conn)["detail"] =~ "builds from its own repo"
    end

    test "a rebind onto a dataset the site cannot read → 422 content_binding_empty, row UNCHANGED" do
      # The same door `POST /v1/sites` closed (W8/D73). It must not be reachable
      # through the side door either: a site bound to nothing builds an empty page.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      label = Registry.site_read_token_label(site)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" => {:ok, %{status: 200, body: token_list("tok-old", label)}},
        "/w/acme/p/press/v1/tokens" =>
          {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_NEW"})}},
        # Interpretable, and it shows NOTHING.
        "/w/acme/p/press/v1/data/query/staging/post" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":0,"documents":[]}})}},
        "/w/acme/p/press/v1/data/counts/staging" =>
          {:ok, %{status: 200, body: ~s({"ok":true,"counts":{"paper":11,"post":0}})}},
        "/w/acme/p/press/v1/data/query/staging/paper" =>
          {:ok, %{status: 200, body: ~s({"result":{"count":1,"total":4,"documents":[{}]}})}}
      })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          login_token(user)
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "content_binding_empty"
      assert body["readable_types"] == [%{"type" => "paper", "count" => 4}]

      row = Registry.get_site(site.id)
      assert row.bootstrap_project == "blog"
      assert row.bootstrap_dataset == "production"
      assert Vault.decrypt(row.read_token_encrypted) == {:ok, "bpt_public_read_OLD"}
      # And the incumbent was NOT revoked — the site still has a working credential.
      refute requested?(:delete, "/w/acme/p/blog/v1/tokens/tok-old")
    end

    test "an unreadable credential inventory → 502, and nothing is minted or moved" do
      # "I could not look" is not "there is nothing there". A rebind that cannot
      # name what it replaces would leave a live public-read token in the old
      # scope with no row pointing at it.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" => {:ok, %{status: 503, body: ~s({"error":"down"})}}
      })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          login_token(user)
        )

      assert conn.status == 502
      assert json_body(conn)["error"] == "read_token_inventory_unreadable"
      refute requested?(:post, "/w/acme/p/press/v1/tokens")
      assert Registry.get_site(site.id).bootstrap_project == "blog"
    end

    test "a mint the box refuses → 502 read_token_mint_failed, row untouched" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      label = Registry.site_read_token_label(site)

      StudioLinkFakeHttpClient.program(%{
        "/w/acme/p/blog/v1/tokens" => {:ok, %{status: 200, body: token_list("tok-old", label)}},
        "/w/acme/p/press/v1/tokens" =>
          {:ok, %{status: 403, body: ~s({"error":{"code":"forbidden","message":"nope"}})}}
      })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          login_token(user)
        )

      assert conn.status == 502
      assert json_body(conn)["error"] == "read_token_mint_failed"
      assert Registry.get_site(site.id).bootstrap_dataset == "production"
    end
  end

  ## ── The tier ──────────────────────────────────────────────────────────────

  describe "PATCH /v1/sites/:id — who may rebind" do
    test "a write-only PAT cannot rebind → 403 rebind_ability_required, row untouched" do
      # A rebind MINTS a public-read token in the scope the caller names — the
      # authority `POST /v1/sites` reserves to a SESSION (it has no PAT arm). At
      # plain `write` this route would be the cheaper door onto it.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      StudioLinkFakeHttpClient.program(%{})

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          write_token
        )

      assert conn.status == 403
      assert json_body(conn)["error"] == "rebind_ability_required"
      assert Registry.get_site(site.id).bootstrap_project == "blog"
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a read-only PAT is refused by the route's own write gate, before the rebind arm" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "read-key",
          abilities: ["read"]
        })

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{workspace: "acme", project: "press", dataset: "staging"},
          read_token
        )

      assert conn.status == 403
      refute json_body(conn)["error"] == "rebind_ability_required"
      assert Registry.get_site(site.id).bootstrap_project == "blog"
    end
  end

  ## ── The unchanged half ────────────────────────────────────────────────────

  describe "PATCH /v1/sites/:id — the settings arm is unchanged" do
    test "theme and doc_type still patch at plain write, touching no box and no binding" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      StudioLinkFakeHttpClient.program(%{})

      conn =
        call(
          :patch,
          "/v1/sites/#{site.id}",
          %{theme: "fjord", doc_type: "paper"},
          write_token
        )

      assert conn.status == 200
      assert json_body(conn)["note"] == "settings apply on the next deploy"

      row = Registry.get_site(site.id)
      assert row.theme == "fjord"
      assert row.doc_type == "paper"
      # The binding and its credential are exactly where they were, and no rebind
      # machinery ran: a settings PATCH must never touch the box.
      assert row.bootstrap_dataset == "production"
      assert Vault.decrypt(row.read_token_encrypted) == {:ok, "bpt_public_read_OLD"}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "prebuilt_enabled still needs deploy-or-root, and a write PAT still gets that 403" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: true}, write_token)

      assert conn.status == 403
      assert json_body(conn)["error"] == "deploy_ability_required"
      refute Registry.get_site(site.id).prebuilt_enabled

      conn = call(:patch, "/v1/sites/#{site.id}", %{prebuilt_enabled: true}, login_token(user))
      assert conn.status == 200
      assert Registry.get_site(site.id).prebuilt_enabled
    end

    test "an empty body still 422s nothing_to_update, and the copy now names the binding" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      conn = call(:patch, "/v1/sites/#{site.id}", %{}, login_token(user))

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "nothing_to_update"
      assert body["detail"] =~ "workspace + project + dataset"
    end
  end
end
