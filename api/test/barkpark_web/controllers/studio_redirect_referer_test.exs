defmodule BarkparkWeb.StudioRedirectRefererTest do
  @moduledoc """
  Teleport killed (sdl-w1-teleport, charter Decision 3).

  A flat Studio link (`/studio/:dataset`, bare `/studio`, or a legacy
  `/studio/:ds/onixedit/book/:id`) carries NO workspace in the URL. The old
  resolver answered that by unconditionally landing you in your FIRST
  slug-ordered membership — so a user working in workspace `beta` who followed
  a flat link was silently teleported to `acme` (it sorts first).

  `BarkparkWeb.Studio.ScopeResolver` now prefers the workspace named in the
  `Referer`'s `/w/:ws/p/:proj` prefix when the token is a member of it — a
  membership-verified scope PREFERENCE, never an auth input. These tests pin
  that preference AND its safety envelope: a missing, cross-origin,
  unparseable, or non-member Referer all fall back to the pre-existing
  first-membership behavior.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    # `acme` sorts before `beta`, so first-membership resolution (the fallback)
    # always picks acme — the teleport target we are killing.
    ws_acme = create_ws!("sdl-acme-#{n}")
    proj_acme = create_proj!(ws_acme, "acme-p-#{n}")
    ws_beta = create_ws!("sdl-beta-#{n}")
    proj_beta = create_proj!(ws_beta, "beta-p-#{n}")

    # A workspace the token is NOT a member of (non-member Referer case).
    ws_gamma = create_ws!("sdl-gamma-#{n}")
    proj_gamma = create_proj!(ws_gamma, "gamma-p-#{n}")

    raw = "sdl-referer-#{n}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "sdl-referer-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    # Member of acme AND beta (both), NOT gamma.
    {:ok, _} = Tenancy.Auth.create_membership(ws_acme.id, token.id, "member")
    {:ok, _} = Tenancy.Auth.create_membership(ws_beta.id, token.id, "member")

    member_conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: member_conn,
     ws_acme: ws_acme,
     proj_acme: proj_acme,
     ws_beta: ws_beta,
     proj_beta: proj_beta,
     ws_gamma: ws_gamma,
     proj_gamma: proj_gamma}
  end

  defp create_ws!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    ws
  end

  defp create_proj!(ws, slug) do
    {:ok, proj} = Tenancy.create_project(ws, %{slug: slug, name: slug})
    proj
  end

  # A same-origin absolute Referer for the test host (ConnCase's default host).
  defp referer(conn, path), do: "http://#{conn.host}#{path}"

  describe "flat /studio/:dataset — Referer scope preference" do
    test "a member's Referer to workspace beta lands them in beta, NOT acme (teleport killed)",
         %{conn: conn, ws_beta: ws_beta, proj_beta: proj_beta} do
      ref = referer(conn, "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio/post/x1")

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", ref)
        |> get("/studio/#{@dataset}")

      target = redirected_to(conn, 302)
      assert target == "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio"
    end

    test "the Referer carries BOTH workspace and project through", %{
      conn: conn,
      ws_beta: ws_beta,
      proj_beta: proj_beta
    } do
      ref = referer(conn, "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio")

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", ref)
        |> get("/studio/#{@dataset}/post/x1")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio/post/x1"
    end

    test "always 302, never 301 (target depends on Referer/session)", %{
      conn: conn,
      ws_beta: ws_beta,
      proj_beta: proj_beta
    } do
      ref = referer(conn, "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio")

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", ref)
        |> get("/studio/#{@dataset}")

      assert conn.status == 302
    end
  end

  describe "safety: Referer is a preference, never auth — fall back to first-membership" do
    test "no Referer → first-membership acme", %{
      conn: conn,
      ws_acme: ws_acme,
      proj_acme: proj_acme
    } do
      conn = get(conn, "/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_acme.slug}/p/#{proj_acme.slug}/d/#{@dataset}/studio"
    end

    test "cross-origin Referer → ignored, first-membership acme", %{
      conn: conn,
      ws_acme: ws_acme,
      proj_acme: proj_acme,
      ws_beta: ws_beta,
      proj_beta: proj_beta
    } do
      # Same path, but an attacker-controlled host: must NOT steer scope.
      ref = "https://evil.example/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio"

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", ref)
        |> get("/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_acme.slug}/p/#{proj_acme.slug}/d/#{@dataset}/studio"
    end

    test "non-member Referer → ignored, first-membership acme", %{
      conn: conn,
      ws_acme: ws_acme,
      proj_acme: proj_acme,
      ws_gamma: ws_gamma,
      proj_gamma: proj_gamma
    } do
      ref = referer(conn, "/w/#{ws_gamma.slug}/p/#{proj_gamma.slug}/d/#{@dataset}/studio")

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", ref)
        |> get("/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_acme.slug}/p/#{proj_acme.slug}/d/#{@dataset}/studio"
    end

    test "unparseable / non-scope Referer → ignored, first-membership acme", %{
      conn: conn,
      ws_acme: ws_acme,
      proj_acme: proj_acme
    } do
      conn =
        conn
        |> Plug.Conn.put_req_header("referer", "http://#{conn.host}/some/other/page")
        |> get("/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_acme.slug}/p/#{proj_acme.slug}/d/#{@dataset}/studio"
    end
  end

  describe "legacy /studio/:ds/onixedit/book/:id inherits the same preference" do
    test "a member's Referer to beta retargets the book editor into beta", %{
      conn: conn,
      ws_beta: ws_beta,
      proj_beta: proj_beta
    } do
      ref = referer(conn, "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio")

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", ref)
        |> get("/studio/#{@dataset}/onixedit/book/b1")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_beta.slug}/p/#{proj_beta.slug}/d/#{@dataset}/studio/book/b1"
    end
  end
end
