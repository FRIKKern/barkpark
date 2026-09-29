defmodule BarkparkCloud.Web.RouterSiteFormsTest do
  @moduledoc """
  task-71082f5541c13b53 (N-08 criterion 2) — the control-plane half of the
  forms inbox: `GET|PUT /v1/sites/:id/forms`,
  `PATCH /v1/sites/:id/forms/submissions/:sub_id`,
  `POST /v1/sites/:id/forms/export`, and the deploy payload's
  `BARKPARK_FORMS_URL` opt-in.

  The box is faked at the ONE transport seam (`:studio_link_http_client`), so
  these tests prove which requests the control plane makes, with which scope
  and body, and what it concludes from each answer. The box-side half — that
  the intake stores only into the bound dataset and that its contract refuses
  out-of-set `state`/`spam` values — is pinned in
  `api/test/barkpark_web/controllers/forms_submission_controller_test.exs` and
  `api/test/barkpark/plugins/forms_contract_test.exs`.

  The arms that matter most:

    * TEAM SCOPING — every route answers a wrong-team caller the SAME 404 as a
      nonexistent id, and makes ZERO box requests doing it;
    * SITE SCOPING INSIDE A SHARED DATASET — a submission whose `site` is not
      this site's slug is a 404 on PATCH, and no mutate is sent;
    * THE STATE FLIP — the patch names the document the box returned, sets
      exactly the requested keys, and carries the read revision.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Sites.{Deploy, FakeBoxRelay, Forms}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"

  @plugins_path "/v1/plugins"
  @query_path "/w/acme/p/blog/v1/data/query/production/form_submission"
  @mutate_path "/w/acme/p/blog/v1/data/mutate/production"

  ## ── fixtures ─────────────────────────────────────────────────────────────────

  defp user_with_team(role \\ "owner") do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
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
          read_token: "bpt_public_read_xyz"
        })
      )

    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp req(method, path, token, body \\ nil) do
    c =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    c
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp box_json(status, body), do: {:ok, %{status: status, body: Jason.encode!(body)}}

  defp plugins_with_forms,
    do: box_json(200, %{"plugins" => [%{"name" => "forms"}, %{"name" => "media"}]})

  defp submission_doc(site_slug, attrs \\ %{}) do
    id = Map.get(attrs, :id, Ecto.UUID.generate())

    Map.merge(
      %{
        "_id" => "drafts." <> id,
        "_publishedId" => id,
        "_type" => "form_submission",
        "_rev" => "rev-" <> String.slice(id, 0, 8),
        "_draft" => true,
        "site" => site_slug,
        "endpoint_id" => "form-endpoint-" <> site_slug,
        "received_at" => "2026-09-25T10:00:00Z",
        "state" => "new",
        "spam" => "clean",
        "spam_reasons" => [],
        "fields" => %{"name" => "Kari", "email" => "kari@example.com", "message" => "Hei"},
        "source" => %{"origin" => @instance_url}
      },
      Map.drop(attrs, [:id])
    )
  end

  defp endpoint_path(site),
    do: "/w/acme/p/blog/v1/data/doc/production/form_endpoint/form-endpoint-#{site.slug}"

  defp doc_path(id), do: "/w/acme/p/blog/v1/data/doc/production/form_submission/#{id}"

  defp requests_to(method, path) do
    Enum.filter(StudioLinkFakeHttpClient.requests(), fn r ->
      r.method == method and URI.parse(r.url).path == path
    end)
  end

  defp program_inbox(site, docs, opts \\ []) do
    StudioLinkFakeHttpClient.program(
      Map.merge(
        %{
          @plugins_path => Keyword.get(opts, :plugins, plugins_with_forms()),
          endpoint_path(site) =>
            Keyword.get(
              opts,
              :endpoint,
              box_json(200, %{
                "result" => %{
                  "_id" => "form-endpoint-#{site.slug}",
                  "site" => site.slug,
                  "enabled" => true,
                  "allowed_origins" => [@instance_url],
                  "fields" => ~w(name email message)
                }
              })
            ),
          @query_path =>
            Keyword.get(
              opts,
              :query,
              box_json(200, %{"result" => %{"documents" => docs, "hasMore" => false}})
            ),
          @mutate_path => Keyword.get(opts, :mutate, box_json(200, %{"transactionId" => "t1"}))
        },
        Keyword.get(opts, :extra, %{})
      )
    )
  end

  ## ── TEAM SCOPING ─────────────────────────────────────────────────────────────

  describe "team scoping" do
    test "every forms route answers a wrong-team caller the same 404 as a nonexistent id, and never calls the box" do
      {_owner, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      sub = submission_doc(site.slug)

      program_inbox(site, [sub],
        extra: %{doc_path(sub["_publishedId"]) => box_json(200, %{"result" => sub})}
      )

      {stranger, _other} = user_with_team()
      token = login_token(stranger)

      calls = [
        {:get, "/forms", nil},
        {:put, "/forms", %{"enabled" => true}},
        {:patch, "/forms/submissions/#{sub["_publishedId"]}", %{"state" => "seen"}},
        {:post, "/forms/export", %{"ids" => [sub["_publishedId"]], "format" => "json"}}
      ]

      for {method, suffix, body} <- calls do
        wrong_team = req(method, "/v1/sites/#{site.id}#{suffix}", token, body)
        absent = req(method, "/v1/sites/#{Ecto.UUID.generate()}#{suffix}", token, body)

        assert wrong_team.status == 404,
               "#{method} #{suffix}: expected 404, got #{wrong_team.status}"

        assert decode(wrong_team) == %{"error" => "not_found"}
        assert absent.resp_body == wrong_team.resp_body, "#{method} #{suffix} leaks existence"
      end

      assert StudioLinkFakeHttpClient.requests() == [],
             "a wrong-team caller reached the box: #{inspect(Enum.map(StudioLinkFakeHttpClient.requests(), & &1.url))}"

      refute Registry.get_site(site.id).forms_enabled
    end

    test "a read-only PAT may read the inbox but may not change or export it" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      sub = submission_doc(site.slug)
      program_inbox(site, [sub])

      {:ok, pat, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ci-read", abilities: ["read"]})

      assert req(:get, "/v1/sites/#{site.id}/forms", pat).status == 200

      # Export copies visitors' personal data out in bulk: `write`, not `read`.
      assert req(:post, "/v1/sites/#{site.id}/forms/export", pat, %{
               "ids" => [sub["_publishedId"]],
               "format" => "json"
             }).status == 403

      put = req(:put, "/v1/sites/#{site.id}/forms", pat, %{"enabled" => true})
      assert put.status == 403

      patch =
        req(:patch, "/v1/sites/#{site.id}/forms/submissions/#{sub["_publishedId"]}", pat, %{
          "state" => "seen"
        })

      assert patch.status == 403
      assert requests_to(:post, @mutate_path) == []
    end
  end

  ## ── GET: the inbox ───────────────────────────────────────────────────────────

  describe "GET /v1/sites/:id/forms" do
    test "lists this site's submissions from its bound scope, newest first, and keeps a neighbour's out" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      mine = submission_doc(site.slug, %{"state" => "seen", "spam" => "suspected"})
      # A neighbour bound to the SAME dataset. The box filter is the first line;
      # the control plane drops a stray row as the second.
      neighbour = submission_doc("someone-else")
      program_inbox(site, [mine, neighbour])

      conn = req(:get, "/v1/sites/#{site.id}/forms", login_token(user))
      assert conn.status == 200
      body = decode(conn)

      assert [only] = body["submissions"]
      assert only["id"] == mine["_publishedId"]
      assert only["state"] == "seen"
      assert only["spam"] == "suspected"
      assert only["fields"]["message"] == "Hei"
      assert body["has_more"] == false

      assert body["forms"]["accepting"] == true
      assert body["forms"]["enabled"] == false

      assert body["forms"]["endpoint_url"] ==
               "#{@instance_url}/v1/plugins/forms/w/acme/p/blog/d/production/sites/#{site.slug}/submissions"

      assert [list_req] = requests_to(:get, @query_path)
      query = URI.decode_query(URI.parse(list_req.url).query)
      assert query["filter[site]"] == site.slug
      assert query["perspective"] == "drafts"
      assert query["order"] == "received_at:desc"
      # The admin credential rides the relay, never the site's read token.
      assert {"Authorization", "Bearer instance-admin-token"} in list_req.headers
    end

    test "a box without the forms plugin is a 409 forms_unsupported, not an empty inbox" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      program_inbox(site, [], plugins: box_json(200, %{"plugins" => [%{"name" => "media"}]}))

      conn = req(:get, "/v1/sites/#{site.id}/forms", login_token(user))
      assert conn.status == 409
      assert decode(conn) == %{"error" => "forms_unsupported"}
    end

    test "a site with no content binding is a 422 no_content_binding and the box is never called" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      {:ok, site} =
        Registry.create_site(bp, %{
          name: "Container",
          slug: "container-#{System.unique_integer([:positive])}",
          kind: "container",
          framework: "nextjs"
        })

      StudioLinkFakeHttpClient.program(%{})
      conn = req(:get, "/v1/sites/#{site.id}/forms", login_token(user))
      assert conn.status == 422
      assert decode(conn) == %{"error" => "no_content_binding"}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "an unreachable box is a 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      program_inbox(site, [], plugins: {:error, :econnrefused})

      conn = req(:get, "/v1/sites/#{site.id}/forms", login_token(user))
      assert conn.status == 502
      assert decode(conn) == %{"error" => "instance_unreachable"}
    end
  end

  ## ── PUT: turning the endpoint on and off ─────────────────────────────────────

  describe "PUT /v1/sites/:id/forms" do
    test "enabling writes the endpoint document AND publishes it, then sets the control plane's bit" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp, %{domains: ["Blog.Example.com"]})
      program_inbox(site, [])

      conn = req(:put, "/v1/sites/#{site.id}/forms", login_token(user), %{"enabled" => true})
      assert conn.status == 200
      body = decode(conn)
      assert body["forms"]["enabled"] == true
      assert body["forms"]["accepting"] == true
      assert body["redeploy_needed"] == true

      assert [write] = requests_to(:post, @mutate_path)

      %{"mutations" => [%{"createOrReplace" => doc}, %{"publish" => publish}]} =
        Jason.decode!(write.body)

      assert doc["_id"] == "form-endpoint-#{site.slug}"
      assert doc["_type"] == "form_endpoint"
      assert doc["content"]["site"] == site.slug
      assert doc["content"]["enabled"] == true
      assert doc["content"]["fields"] == Forms.default_fields()
      # The box's own origin (sites are served at <box>/sites/<slug>/) plus every
      # custom domain, lowercased — the exact strings the intake compares.
      assert doc["content"]["allowed_origins"] == [@instance_url, "https://blog.example.com"]
      assert publish == %{"id" => "form-endpoint-#{site.slug}", "type" => "form_endpoint"}

      assert Registry.get_site(site.id).forms_enabled
    end

    test "disabling writes enabled:false and publishes it, and clears the bit" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      {:ok, site} = Registry.set_site_forms_enabled(site, true)
      program_inbox(site, [])

      conn = req(:put, "/v1/sites/#{site.id}/forms", login_token(user), %{"enabled" => false})
      assert conn.status == 200
      assert decode(conn)["forms"]["enabled"] == false

      assert [write] = requests_to(:post, @mutate_path)

      %{"mutations" => [%{"createOrReplace" => doc}, %{"publish" => _}]} =
        Jason.decode!(write.body)

      assert doc["content"]["enabled"] == false
      refute Registry.get_site(site.id).forms_enabled
    end

    test "a box that refuses the write leaves the control plane's bit where it was" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      program_inbox(site, [],
        mutate: box_json(422, %{"error" => %{"code" => "validation_failed"}})
      )

      conn = req(:put, "/v1/sites/#{site.id}/forms", login_token(user), %{"enabled" => true})
      assert conn.status == 502
      assert decode(conn) == %{"error" => "instance_refused", "status" => 422}
      refute Registry.get_site(site.id).forms_enabled
    end

    test "a box without the plugin is refused before anything is written" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      program_inbox(site, [], plugins: box_json(200, %{"plugins" => []}))

      conn = req(:put, "/v1/sites/#{site.id}/forms", login_token(user), %{"enabled" => true})
      assert conn.status == 409
      assert decode(conn) == %{"error" => "forms_unsupported"}
      assert requests_to(:post, @mutate_path) == []
      refute Registry.get_site(site.id).forms_enabled
    end

    test "a non-boolean `enabled` is a 422 and nothing reaches the box" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      StudioLinkFakeHttpClient.program(%{})

      conn = req(:put, "/v1/sites/#{site.id}/forms", login_token(user), %{"enabled" => "yes"})
      assert conn.status == 422
      assert StudioLinkFakeHttpClient.requests() == []
    end
  end

  ## ── PATCH: the state flip ────────────────────────────────────────────────────

  describe "PATCH /v1/sites/:id/forms/submissions/:sub_id" do
    test "marking seen patches the document the box returned, with exactly the requested key and its revision" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      sub = submission_doc(site.slug)

      program_inbox(site, [],
        extra: %{doc_path(sub["_publishedId"]) => box_json(200, %{"result" => sub})}
      )

      conn =
        req(
          :patch,
          "/v1/sites/#{site.id}/forms/submissions/#{sub["_publishedId"]}",
          login_token(user),
          %{
            "state" => "seen"
          }
        )

      assert conn.status == 200
      assert decode(conn)["submission"]["state"] == "seen"
      assert decode(conn)["submission"]["id"] == sub["_publishedId"]

      assert [write] = requests_to(:post, @mutate_path)

      assert Jason.decode!(write.body) == %{
               "mutations" => [
                 %{
                   "patch" => %{
                     "id" => sub["_id"],
                     "type" => "form_submission",
                     "set" => %{"state" => "seen"},
                     "ifRevisionID" => sub["_rev"]
                   }
                 }
               ]
             }
    end

    test "marking spam and back to new travel as one set" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      sub = submission_doc(site.slug, %{"state" => "seen"})

      program_inbox(site, [],
        extra: %{doc_path(sub["_publishedId"]) => box_json(200, %{"result" => sub})}
      )

      conn =
        req(
          :patch,
          "/v1/sites/#{site.id}/forms/submissions/#{sub["_publishedId"]}",
          login_token(user),
          %{
            "state" => "new",
            "spam" => "spam"
          }
        )

      assert conn.status == 200
      assert [write] = requests_to(:post, @mutate_path)

      assert %{"mutations" => [%{"patch" => %{"set" => %{"state" => "new", "spam" => "spam"}}}]} =
               Jason.decode!(write.body)
    end

    test "a submission belonging to another site in the same dataset is a 404 and nothing is written" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      neighbours = submission_doc("someone-else")

      program_inbox(site, [],
        extra: %{doc_path(neighbours["_publishedId"]) => box_json(200, %{"result" => neighbours})}
      )

      conn =
        req(
          :patch,
          "/v1/sites/#{site.id}/forms/submissions/#{neighbours["_publishedId"]}",
          login_token(user),
          %{
            "state" => "seen"
          }
        )

      assert conn.status == 404
      assert decode(conn) == %{"error" => "not_found"}
      assert requests_to(:post, @mutate_path) == []
    end

    test "an out-of-contract state or spam value is a 422 before any box call" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      StudioLinkFakeHttpClient.program(%{})
      id = Ecto.UUID.generate()

      for body <- [%{"state" => "archived"}, %{"spam" => "ham"}, %{}, %{"title" => "x"}] do
        conn =
          req(:patch, "/v1/sites/#{site.id}/forms/submissions/#{id}", login_token(user), body)

        assert conn.status == 422, "#{inspect(body)} → #{conn.status}"
      end

      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a stale revision on the box is a 409 conflict" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      sub = submission_doc(site.slug)

      program_inbox(site, [],
        mutate: box_json(412, %{"error" => %{"code" => "precondition_failed"}}),
        extra: %{doc_path(sub["_publishedId"]) => box_json(200, %{"result" => sub})}
      )

      conn =
        req(
          :patch,
          "/v1/sites/#{site.id}/forms/submissions/#{sub["_publishedId"]}",
          login_token(user),
          %{
            "state" => "seen"
          }
        )

      assert conn.status == 409
      assert decode(conn) == %{"error" => "conflict"}
    end
  end

  ## ── POST export ──────────────────────────────────────────────────────────────

  describe "POST /v1/sites/:id/forms/export" do
    test "JSON export returns exactly the selected rows and names the ids it could not find" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      a = submission_doc(site.slug)
      b = submission_doc(site.slug)
      program_inbox(site, [a, b])
      ghost = Ecto.UUID.generate()

      conn =
        req(:post, "/v1/sites/#{site.id}/forms/export", login_token(user), %{
          "ids" => [b["_publishedId"], ghost],
          "format" => "json"
        })

      assert conn.status == 200
      body = decode(conn)
      assert Enum.map(body["submissions"], & &1["id"]) == [b["_publishedId"]]
      assert body["missing"] == [ghost]
    end

    test "CSV export is an attachment with one column per field and formula-safe cells" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)

      a =
        submission_doc(site.slug, %{
          "fields" => %{"name" => "=HYPERLINK(\"x\")", "message" => "line one, and \"two\""}
        })

      program_inbox(site, [a])

      conn =
        req(:post, "/v1/sites/#{site.id}/forms/export", login_token(user), %{
          "ids" => [a["_publishedId"]],
          "format" => "csv"
        })

      assert conn.status == 200
      assert [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "text/csv"
      assert [cd] = get_resp_header(conn, "content-disposition")
      assert cd =~ ~s(filename="#{site.slug}-submissions.csv")
      assert get_resp_header(conn, "x-barkpark-missing") == ["0"]

      [header, row, ""] = String.split(conn.resp_body, "\r\n")
      assert header == "id,received_at,state,spam,message,name,origin"
      assert row =~ ~s("line one, and ""two""")
      assert row =~ ~S|"'=HYPERLINK(""x"")"|
    end

    test "an empty or oversized selection is a 422" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      StudioLinkFakeHttpClient.program(%{})
      token = login_token(user)

      assert req(:post, "/v1/sites/#{site.id}/forms/export", token, %{"ids" => []}).status == 422

      assert req(:post, "/v1/sites/#{site.id}/forms/export", token, %{
               "ids" => ["a"],
               "format" => "xml"
             }).status == 422

      assert StudioLinkFakeHttpClient.requests() == []
    end
  end

  ## ── the deploy payload: the template's opt-in ────────────────────────────────

  describe "deploy payload" do
    test "a site with forms on hands the build BARKPARK_FORMS_URL; one without deploys without the key" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      off = static_site(bp)
      {:ok, d_off} = Deploy.enqueue(off, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(Deploy.stages())])
      assert {:ok, :live} = Deploy.run(d_off.id)
      assert [{:start_deploy, payload_off} | _] = FakeBoxRelay.calls()
      refute Map.has_key?(payload_off.env, :BARKPARK_FORMS_URL)

      {:ok, on} = Registry.set_site_forms_enabled(static_site(bp), true)
      {:ok, d_on} = Deploy.enqueue(on, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(Deploy.stages())])
      assert {:ok, :live} = Deploy.run(d_on.id)
      assert [{:start_deploy, payload_on} | _] = FakeBoxRelay.calls()

      assert payload_on.env[:BARKPARK_FORMS_URL] ==
               "#{@instance_url}/v1/plugins/forms/w/acme/p/blog/d/production/sites/#{on.slug}/submissions"
    end
  end
end
