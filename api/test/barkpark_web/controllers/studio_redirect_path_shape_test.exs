defmodule BarkparkWeb.StudioRedirectPathShapeTest do
  @moduledoc """
  `?path=` is caller-controlled on the BARE-SLASH routes of both Studio
  redirect scopes, and an anonymous GET could 500 on it.

  Each `StudioRedirectController` action is mounted twice — a glob and a
  bare slash:

      get("/",      StudioRedirectController, :studio)         # /studio/:dataset
      get("/*path", StudioRedirectController, :studio)
      get("/",      StudioRedirectController, :legacy_scoped)  # /w/:ws/p/:proj/studio/:dataset
      get("/*path", StudioRedirectController, :legacy_scoped)

  On the glob route `"path"` is a path_param, so it is always a list of
  binaries and `Enum.join/2` over it is safe. On the bare-slash route the
  router binds NO `"path"` path_param, so a query-string `path` survives
  into `params` with whatever shape the caller chose (Phoenix merges
  path_params OVER query params — with no key to override, the query value
  stands). `Enum.join("x", "/")` raises `Protocol.UndefinedError`, and both
  routes are reachable with no token at all: `:browser` + `:soft_token`
  (OptionalSessionToken) coerce nothing, and `protect_from_forgery` does not
  gate GET.

  These tests pin the shape guard on both arms, and the positive controls
  pin that a real glob tail still rewrites exactly as before.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.TenancyFixtures

  @dataset "production"

  # Every hostile shape a query string can give `"path"` that is not the
  # list-of-binaries a router glob produces.
  @hostile_query [
    {"a bare binary", "path=x"},
    {"a map", "path[k]=v"},
    {"an empty binary", "path="},
    {"a nested list", "path[][]=a"},
    {"a list holding a map", "path[][k]=v"}
  ]

  describe "flat /studio/:dataset (bare-slash route, anonymous)" do
    for {shape, qs} <- @hostile_query do
      test "?#{qs} (#{shape}) does not 500", %{conn: conn} do
        conn = get(conn, "/studio/#{@dataset}?#{unquote(qs)}")

        refute conn.status == 500
        assert conn.status in 300..499
        refute conn.resp_body =~ "Protocol.UndefinedError"
        refute conn.resp_body =~ "Enum.join"
      end
    end
  end

  describe "legacy scoped /w/:ws/p/:proj/studio/:dataset (bare-slash route, anonymous)" do
    for {shape, qs} <- @hostile_query do
      test "?#{qs} (#{shape}) does not 500", %{conn: conn} do
        conn = get(conn, "/w/acme/p/site/studio/#{@dataset}?#{unquote(qs)}")

        refute conn.status == 500
        assert conn.status in 300..499
        refute conn.resp_body =~ "Protocol.UndefinedError"
        refute conn.resp_body =~ "Enum.join"
      end
    end

    test "a hostile ?path= still rewrites to the /d/ canonical, query preserved", %{conn: conn} do
      conn = get(conn, "/w/acme/p/site/studio/#{@dataset}?path=x")

      assert redirected_to(conn, 302) == "/w/acme/p/site/d/#{@dataset}/studio?path=x"
    end
  end

  describe "positive control — a real glob tail still redirects" do
    test "legacy scoped keeps the path tail", %{conn: conn} do
      conn = get(conn, "/w/acme/p/site/studio/#{@dataset}/post/p1")

      assert redirected_to(conn, 302) == "/w/acme/p/site/d/#{@dataset}/studio/post/p1"
    end

    test "flat studio keeps the path tail", %{conn: conn} do
      {ws, project} = TenancyFixtures.ensure_default_scope!()

      conn = get(conn, "/studio/#{@dataset}/post/p1")

      assert redirected_to(conn, 302) ==
               "/w/#{ws.slug}/p/#{project.slug}/d/#{@dataset}/studio/post/p1"
    end

    test "flat studio with no tail redirects to the scoped root", %{conn: conn} do
      {ws, project} = TenancyFixtures.ensure_default_scope!()

      conn = get(conn, "/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws.slug}/p/#{project.slug}/d/#{@dataset}/studio"
    end
  end
end
