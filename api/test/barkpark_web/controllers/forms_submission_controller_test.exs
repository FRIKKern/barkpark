defmodule BarkparkWeb.FormsSubmissionControllerTest do
  @moduledoc """
  c1 of task-71082f5541c13b53: the public, site-scoped form endpoint stores a
  submission only in the bound workspace/project/dataset, and refuses —
  storing nothing anywhere — on a cross-tenant URL, a foreign origin, an
  unknown or oversized payload, and a spent rate budget. Every request is
  anonymous: no credential is needed and none is ever returned.
  """
  # sync: the RateLimiter's :named_table is whole-node state (see bulldocs_form test)
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  setup :reset_rate_limiter!

  # One dataset string for every tenant, on purpose: isolation must come from
  # the workspace/project ids, never from the dataset leaf.
  @dataset "test"
  @site "blog"
  @origin "https://blog.example.com"

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  defp form_path(ws, proj, dataset \\ @dataset, site \\ @site),
    do: "/v1/plugins/forms/w/#{ws.slug}/p/#{proj.slug}/d/#{dataset}/sites/#{site}/submissions"

  defp enable!(ws, proj, overrides \\ %{}) do
    content =
      Map.merge(
        %{
          "site" => @site,
          "enabled" => true,
          "allowed_origins" => [@origin],
          "fields" => ["name", "email", "message"]
        },
        overrides
      )

    {:ok, doc} =
      Content.create_document(
        "form_endpoint",
        %{
          "doc_id" => "form-endpoint-#{content["site"]}",
          "title" => "endpoint",
          "content" => content
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc
  end

  defp submissions do
    from(d in Document, where: d.type == "form_submission") |> Repo.all()
  end

  defp submissions_in(ws) do
    from(d in Document, where: d.type == "form_submission" and d.workspace_id == ^ws.id)
    |> Repo.all()
  end

  defp post_form(path, body, origin \\ @origin) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    post(conn, path, Jason.encode!(body))
  end

  describe "the bound dataset" do
    test "a valid post lands in the bound workspace/project/dataset only", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      resp =
        post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "Kari", "message" => "Hei"})
        |> json_response(201)

      assert resp["ok"] == true
      assert [doc] = submissions()
      assert doc.doc_id == resp["id"]
      assert doc.workspace_id == ctx.ws_a.id
      assert doc.project_id == ctx.proj_a.id
      assert doc.dataset == @dataset
      assert doc.content["site"] == @site
      assert doc.content["fields"] == %{"name" => "Kari", "message" => "Hei"}
      assert doc.content["state"] == "new"
      assert doc.content["spam"] == "clean"
      assert doc.content["source"]["origin"] == @origin
      assert {:ok, _, _} = DateTime.from_iso8601(doc.content["received_at"])
      assert [] == submissions_in(ctx.ws_b)
    end

    test "an HTML form post (urlencoded) is accepted the same way", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      resp =
        build_conn()
        |> put_req_header("origin", @origin)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(form_path(ctx.ws_a, ctx.proj_a), "name=Kari&message=Hei+der")
        |> json_response(201)

      assert [doc] = submissions()
      assert doc.doc_id == resp["id"]
      assert doc.content["fields"] == %{"name" => "Kari", "message" => "Hei der"}
    end
  end

  describe "cross-tenant NEGATIVES" do
    test "an endpoint in workspace A does not open workspace B's URL", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      conn = post_form(form_path(ctx.ws_b, ctx.proj_b), %{"name" => "x"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
      assert [] == submissions()
    end

    test "workspace B claiming the same site slug cannot capture A's posts", ctx do
      enable!(ctx.ws_a, ctx.proj_a)
      enable!(ctx.ws_b, ctx.proj_b)

      post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "for A"}) |> json_response(201)

      assert [a] = submissions_in(ctx.ws_a)
      assert a.content["fields"] == %{"name" => "for A"}
      assert [] == submissions_in(ctx.ws_b)
    end

    test "a mixed URL — A's workspace with B's project — is a 404 and writes nothing", ctx do
      enable!(ctx.ws_a, ctx.proj_a)
      enable!(ctx.ws_b, ctx.proj_b)

      conn = post_form(form_path(ctx.ws_a, ctx.proj_b), %{"name" => "x"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
      assert [] == submissions()
    end

    test "another dataset of the SAME project is not bound", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      conn = post_form(form_path(ctx.ws_a, ctx.proj_a, "staging"), %{"name" => "x"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
      assert [] == submissions()
    end

    test "another site slug in the same dataset is not bound", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      conn = post_form(form_path(ctx.ws_a, ctx.proj_a, @dataset, "shop"), %{"name" => "x"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
      assert [] == submissions()
    end

    test "a disabled endpoint and an archived workspace are both 404", ctx do
      enable!(ctx.ws_a, ctx.proj_a, %{"enabled" => false})
      assert post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x"}).status == 404

      enable!(ctx.ws_b, ctx.proj_b)
      {:ok, _} = Barkpark.Tenancy.archive_workspace(ctx.ws_b)
      assert post_form(form_path(ctx.ws_b, ctx.proj_b), %{"name" => "x"}).status == 404

      assert [] == submissions()
    end
  end

  describe "origin binding" do
    test "a foreign or missing Origin is a 403 and writes nothing", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      for origin <- ["https://evil.example.com", "http://blog.example.com", nil] do
        conn = post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x"}, origin)
        assert json_response(conn, 403)["error"]["code"] == "forbidden", inspect(origin)
      end

      assert [] == submissions()
    end

    test "an operator bearer token does not bypass the origin check", ctx do
      enable!(ctx.ws_a, ctx.proj_a)
      raw = "bp_forms_admin_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Barkpark.Auth.create_token(
          raw,
          "forms-admin",
          "test",
          ["read", "write", "admin"],
          ctx.ws_a.id
        )

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("origin", "https://evil.example.com")
        |> post(form_path(ctx.ws_a, ctx.proj_a), Jason.encode!(%{"name" => "x"}))

      assert conn.status == 403
      refute conn.resp_body =~ raw
      assert [] == submissions()
    end
  end

  describe "payload contract at the endpoint" do
    test "an unknown field is a 422 naming it and stores nothing", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      conn = post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x", "admin" => "true"})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["details"]["unknown_fields"] == ["admin"]
      assert [] == submissions()
    end

    test "an oversized field is a 413 and stores nothing (not a truncated row)", ctx do
      enable!(ctx.ws_a, ctx.proj_a)
      big = String.duplicate("x", 5_001)

      conn = post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x", "message" => big})
      assert json_response(conn, 413)["error"]["code"] == "payload_too_large"
      assert [] == submissions()
    end

    test "a declared body over 64 KiB is a 413 before any lookup", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      conn =
        build_conn()
        |> put_req_header("origin", @origin)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", "70000")
        |> post(form_path(ctx.ws_a, ctx.proj_a), Jason.encode!(%{"name" => "x"}))

      assert conn.status == 413
      assert [] == submissions()
    end

    test "a nested value and a non-object JSON body are refused", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      assert post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => %{"a" => "b"}}).status == 422
      assert post_form(form_path(ctx.ws_a, ctx.proj_a), ["name", "x"]).status == 422
      assert [] == submissions()
    end
  end

  describe "spam controls" do
    test "a filled honeypot gets the success shape and writes nothing", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      body =
        post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "bot", "bp_hp" => "http://spam"})
        |> json_response(201)

      assert body == %{"ok" => true}
      assert [] == submissions()
    end

    test "a link-stuffed post is stored as suspected, not dropped", ctx do
      enable!(ctx.ws_a, ctx.proj_a)
      links = Enum.map_join(1..4, " ", &"https://spam#{&1}.example.com")

      post_form(form_path(ctx.ws_a, ctx.proj_a), %{"message" => links}) |> json_response(201)

      assert [doc] = submissions()
      assert doc.content["spam"] == "suspected"
      assert doc.content["spam_reasons"] == ["links"]
    end
  end

  describe "rate limiting" do
    test "the per-address budget brakes the 21st post with a Retry-After", ctx do
      enable!(ctx.ws_a, ctx.proj_a)

      for _ <- 1..20,
          do: assert(post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x"}).status == 201)

      conn = post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x"})
      assert json_response(conn, 429)["error"]["code"] == "rate_limited"
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
      assert length(submissions()) == 20
    end

    test "the per-endpoint budget holds across addresses", ctx do
      enable!(ctx.ws_a, ctx.proj_a)
      binding_key = fn -> {:forms_endpoint, ctx.ws_a.id, ctx.proj_a.id, @dataset, @site} end

      # Spend the endpoint bucket directly (300 posts from 300 addresses is the
      # same state, slower), then post from a fresh address.
      conn0 = build_conn()

      for _ <- 1..300 do
        Barkpark.RateLimiter.check(
          Barkpark.RateLimiter.scoped_key(conn0, binding_key.()),
          capacity: 300,
          refill_per_sec: 300 / 3600
        )
      end

      conn = post_form(form_path(ctx.ws_a, ctx.proj_a), %{"name" => "x"})
      assert json_response(conn, 429)["error"]["code"] == "rate_limited"
      assert [] == submissions()
    end
  end

  test "the CORS preflight answers 204 without touching storage", ctx do
    enable!(ctx.ws_a, ctx.proj_a)

    conn =
      build_conn()
      |> put_req_header("origin", @origin)
      |> put_req_header("access-control-request-method", "POST")
      |> options(form_path(ctx.ws_a, ctx.proj_a))

    assert conn.status == 204
    assert [] == submissions()
  end
end
