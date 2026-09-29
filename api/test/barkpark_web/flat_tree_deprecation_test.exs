defmodule BarkparkWeb.FlatTreeDeprecationTest do
  @moduledoc """
  Every flat `/v1` route that has a `/w/:workspace_slug/p/:project_slug`
  mirror answers `deprecation: true` and a `link` to that mirror with
  `rel="successor-version"`, and no `sunset` (task-0bb1b96ae30cb4a4; the
  Sunset date waits for owner item 55).

  The mirror set is computed HERE from `Router.__routes__/0`, independently of
  the plug, and each mirrored route gets a real anonymous request. So a flat
  pipeline that loses the plug reds this file naming its routes, and a new
  mirrored flat route on a pipeline that never had the plug reds it too.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, TenancyFixtures}
  alias BarkparkWeb.Plugs.FlatTreeDeprecation
  alias BarkparkWeb.Router

  @scoped_prefix "/w/:workspace_slug/p/:project_slug"
  @probe "zzdeprecationprobezz"
  @link_rel "; rel=\"successor-version\""

  describe "router walk" do
    test "every mirrored flat route answers Deprecation: true + its successor Link, no Sunset" do
      mirrored = mirrored_flat_routes()

      # Not vacuous: the census of 2026-09-25 counted 86. A collapse to a
      # handful means the enumeration broke, not that the tree got smaller.
      assert length(mirrored) >= 50,
             "only #{length(mirrored)} mirrored flat routes found; the enumeration is broken"

      assert {"GET", "/v1/data/query/:dataset/:type"} in mirrored

      problems =
        for {verb, path} <- mirrored,
            problem = header_problem(verb, path),
            do: "#{verb} #{path} — #{problem}"

      assert problems == [],
             """
             #{length(problems)} of #{length(mirrored)} mirrored flat routes do not answer the
             deprecation headers. Mount BarkparkWeb.Plugs.FlatTreeDeprecation FIRST in the
             pipeline these routes ride:

             #{Enum.join(problems, "\n")}
             """
    end

    test "names every flat route with no scoped mirror; the plug marks none of them" do
      unmirrored = unmirrored_flat_routes()

      IO.puts(
        "\n[flat-tree-deprecation] #{length(unmirrored)} flat /v1 routes have NO " <>
          "#{@scoped_prefix} mirror and carry no Deprecation header:\n" <>
          Enum.map_join(unmirrored, "\n", fn {verb, path} -> "  #{verb} #{path}" end)
      )

      marked =
        for {verb, path} <- unmirrored,
            FlatTreeDeprecation.successor_for(Router, verb, path) != nil,
            do: "#{verb} #{path}"

      assert marked == [],
             "the plug names a successor that does not exist:\n#{Enum.join(marked, "\n")}"
    end

    test "an unmirrored flat route answers no Deprecation header on a real request" do
      {verb, path} = {"GET", "/v1/capabilities"}
      refute {verb, path} in mirrored_flat_routes(), "#{path} gained a mirror; pick another route"
      assert {verb, path} in flat_routes()

      conn = request(verb, path)
      assert get_resp_header(conn, "deprecation") == []
      assert get_resp_header(conn, "link") == []
    end
  end

  describe "the successor URL" do
    test "names the resolved default scope and substitutes the path params" do
      {ws, project} = TenancyFixtures.ensure_default_scope!()
      conn = get(scoped_conn(), "/v1/data/query/production/post")

      assert get_resp_header(conn, "deprecation") == ["true"]
      assert get_resp_header(conn, "sunset") == []

      assert get_resp_header(conn, "link") ==
               ["</w/#{ws.slug}/p/#{project.slug}/v1/data/query/production/post>" <> @link_rel]
    end

    test "never copies the query string" do
      conn = get(scoped_conn(), "/v1/data/query/production/post?token=secret&limit=1")
      [link] = get_resp_header(conn, "link")
      refute link =~ "secret"
      assert link =~ "/v1/data/query/production/post>"
    end

    test "percent-encodes a path param that needs it" do
      conn = get(scoped_conn(), "/v1/data/doc/production/post/a%20b")
      [link] = get_resp_header(conn, "link")
      assert link =~ "/v1/data/doc/production/post/a%20b>"
    end

    test "a halted request keeps the unresolved slugs as placeholders" do
      # :flat_admin_api halts at RequireToken, before any scope is assigned.
      conn = get(scoped_conn(), "/v1/webhooks/production")
      assert conn.status == 401
      assert get_resp_header(conn, "deprecation") == ["true"]
      assert get_resp_header(conn, "link") == [wrap("#{@scoped_prefix}/v1/webhooks/production")]
    end

    test "a token bound to a non-Default workspace names that workspace, project stays a placeholder" do
      ws_b = TenancyFixtures.create_workspace!()
      token = "flat-deprecation-ws-b-token"
      {:ok, _} = Auth.create_token(token, "flat-deprecation-b", "production", ["read"], ws_b.id)

      conn =
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/production/post")

      assert get_resp_header(conn, "link") ==
               [wrap("/w/#{ws_b.slug}/p/:project_slug/v1/data/query/production/post")]
    end
  end

  describe "unchanged surfaces" do
    test "a scoped route carries no Deprecation, Sunset or Link" do
      {ws, project} = TenancyFixtures.ensure_default_scope!()
      conn = get(scoped_conn(), "/w/#{ws.slug}/p/#{project.slug}/v1/data/query/production/post")

      assert get_resp_header(conn, "deprecation") == []
      assert get_resp_header(conn, "sunset") == []
      assert get_resp_header(conn, "link") == []
    end

    test "legacy /api/schemas keeps its own Sunset and successor Link" do
      conn = get(scoped_conn(), "/api/schemas")

      assert get_resp_header(conn, "deprecation") == ["true"]
      assert get_resp_header(conn, "sunset") == ["Wed, 31 Dec 2026 23:59:59 GMT"]
      assert get_resp_header(conn, "link") == ["</v1/data/query>" <> @link_rel]
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp wrap(path), do: "<#{path}>" <> @link_rel

  defp flat_routes do
    for %{verb: verb, path: "/v1" <> _ = path} <- Router.__routes__(),
        do: {verb |> to_string() |> String.upcase(), path}
  end

  defp scoped_routes do
    MapSet.new(
      for %{verb: verb, path: @scoped_prefix <> _ = path} <- Router.__routes__(),
          do: {verb |> to_string() |> String.upcase(), path}
    )
  end

  defp mirrored_flat_routes do
    scoped = scoped_routes()
    for {verb, path} <- flat_routes(), {verb, @scoped_prefix <> path} in scoped, do: {verb, path}
  end

  defp unmirrored_flat_routes, do: flat_routes() -- mirrored_flat_routes()

  defp probe_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> @probe
      "*" <> _ -> @probe
      segment -> segment
    end)
  end

  defp request(verb, path) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, verb, probe_path(path), "{}")
  end

  # nil when the route answers correctly, else what is wrong with it.
  defp header_problem(verb, path) do
    conn = request(verb, path)
    expected_suffix = probe_path(path) <> ">" <> @link_rel

    cond do
      get_resp_header(conn, "deprecation") != ["true"] ->
        "status #{conn.status}, deprecation #{inspect(get_resp_header(conn, "deprecation"))}"

      get_resp_header(conn, "sunset") != [] ->
        "carries sunset #{inspect(get_resp_header(conn, "sunset"))}"

      not successor_link?(get_resp_header(conn, "link"), expected_suffix) ->
        "link #{inspect(get_resp_header(conn, "link"))}, expected </w/<ws>/p/<proj>#{expected_suffix}"

      true ->
        nil
    end
  rescue
    error -> "raised #{inspect(error.__struct__)} before a response was sent"
  end

  defp successor_link?([link], suffix) do
    case Regex.run(~r{^</w/([^/]+)/p/([^/]+)(/.*)$}, link) do
      [_, _ws, _proj, rest] -> rest == suffix
      _ -> false
    end
  end

  defp successor_link?(_links, _suffix), do: false
end
