defmodule BarkparkCloud.Web.DeployButtonDocsTest do
  @moduledoc """
  dwb-9 — the "Deploy with Barkpark" badge and its launch page stay true after a
  route or repository change.

  Two documents make promises about this control plane: the badge snippet in the
  root `README.md`, and `docs/setup/DEPLOY-WITH-BARKPARK.md`, which walks the
  one-click path and gives a `curl` launch command. Every expected value here is
  DERIVED from the thing the document describes, never typed into this file:

    * routes — `RouterTierLens.route_keys/0` (the `get`/`post` macros in
      `router.ex`) AND a live dispatch through `Router.call/2`, which must not
      fall through to the catch-all `match _` 404;
    * template slugs — `Templates.slugs/0` (the `/v1/templates` catalog `/new`
      renders), `Registry.known_templates/0` (what `POST /v1/launch` accepts),
      and `templates/<slug>/barkpark.template.json` on disk;
    * "ships a site app" — `Templates.AppFiles.app_template?/1`;
    * the `/new` path and the query keys it reads — `isNewFlow()` and every
      `newParams().get("…")` in `cloud/priv/static/app.js`;
    * the provisioning step table — `SERVER_STEP_ORDER` and
      `SERVER_STEP_LABELS` in the same file;
    * the public host — `config :barkpark_cloud, :dashboard_url`.

  So renaming `/new`, dropping `POST /v1/launch`, deleting or renaming a
  template, or adding a template without documenting it reds here.

  Both documents live outside `cloud/`. They are declared in the Cloud
  dispatcher's path set (`scripts/cloud-path-escape-check.sh`), so a PR that
  edits only the README or the page still runs this file.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test

  alias BarkparkCloud.{Registry, Templates}
  alias BarkparkCloud.RouterTierLens, as: Lens
  alias BarkparkCloud.Templates.AppFiles
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @readme_path Path.expand("../../../../README.md", __DIR__)
  @page_path Path.expand("../../../../docs/setup/DEPLOY-WITH-BARKPARK.md", __DIR__)
  @templates_root Path.expand("../../../../templates", __DIR__)
  @app_js_path Path.expand("../../../priv/static/app.js", __DIR__)
  @page_rel "docs/setup/DEPLOY-WITH-BARKPARK.md"

  @badge_re ~r/\[!\[[^\]]*\]\(([^)\s]+)\)\]\(([^)\s]+)\)/
  @url_re ~r{https?://[^\s)\]"'`<>]+}
  @backtick_route_re ~r/`(GET|POST|PUT|PATCH|DELETE) (\/[^`\s]*)`/
  @curl_re ~r/curl\s+-X\s+(GET|POST|PUT|PATCH|DELETE)\s+(https?:\/\/\S+)(.*?)(?:\n\s*\n|```)/s
  @curl_body_re ~r/-d\s+'([^']*)'/
  @template_row_re ~r/^\| `([a-z0-9-]+)` \| (yes|no) \|$/m
  @step_row_re ~r/^ {3}\| `([a-z]+)` \| (.+?) \|$/m

  ## Sources

  defp read!(path) do
    unless File.regular?(path),
      do: flunk("#{path} is missing — the document moved or was deleted")

    File.read!(path)
  end

  defp readme, do: read!(@readme_path)
  defp page, do: read!(@page_path)
  defp app_js, do: read!(@app_js_path)

  defp public_host do
    url = Application.fetch_env!(:barkpark_cloud, :dashboard_url)
    %URI{host: host} = URI.parse(url)
    host
  end

  # The path app.js treats as the deploy flow, read from isNewFlow().
  defp new_flow_path do
    case Regex.run(
           ~r/function isNewFlow\(\) \{ return pathClean\(location\.pathname\) === "([^"]+)"; \}/,
           app_js()
         ) do
      [_, path] ->
        path

      _ ->
        flunk(
          "app.js no longer declares isNewFlow() in the shape this test reads — re-point the extractor"
        )
    end
  end

  # Every query key the /new flow reads, from newParams().get("…").
  defp new_flow_params do
    keys = Regex.scan(~r/newParams\(\)\.get\("([^"]+)"\)/, app_js()) |> Enum.map(&List.last/1)
    if keys == [], do: flunk("app.js reads no newParams().get(…) keys — the extractor is blind")
    MapSet.new(keys)
  end

  # The /new flow reads the template from this key: the one newTemplateSlug() returns.
  defp template_param do
    case Regex.run(
           ~r/function newTemplateSlug\(\) \{ return newParams\(\)\.get\("([^"]+)"\); \}/,
           app_js()
         ) do
      [_, key] -> key
      _ -> flunk("app.js no longer declares newTemplateSlug() in the shape this test reads")
    end
  end

  defp server_steps do
    order =
      case Regex.run(~r/var SERVER_STEP_ORDER = \[([^\]]*)\];/, app_js()) do
        [_, body] -> Regex.scan(~r/"([a-z]+)"/, body) |> Enum.map(&List.last/1)
        _ -> flunk("app.js no longer declares SERVER_STEP_ORDER")
      end

    labels =
      case Regex.run(~r/var SERVER_STEP_LABELS = \{(.*?)\};/s, app_js()) do
        [_, body] -> Regex.scan(~r/(\w+): "([^"]*)"/, body) |> Map.new(fn [_, k, v] -> {k, v} end)
        _ -> flunk("app.js no longer declares SERVER_STEP_LABELS")
      end

    Enum.map(order, &{&1, Map.fetch!(labels, &1)})
  end

  ## Checks

  defp assert_known_template(slug, where) do
    assert slug in Templates.slugs(),
           "#{where} names template #{inspect(slug)}, which is not in the /v1/templates catalog " <>
             "(Templates.slugs/0 = #{inspect(Templates.slugs())}); /new would show the picker instead"

    assert Registry.known_template?(slug),
           "#{where} names template #{inspect(slug)}, which POST /v1/launch refuses (not in Registry.known_templates/0)"

    manifest = Path.join([@templates_root, slug, "barkpark.template.json"])

    assert File.regular?(manifest),
           "#{where} names template #{inspect(slug)}, but #{manifest} does not exist"
  end

  defp dispatch(method, path) do
    concrete = String.replace(path, ~r/:[a-z_]+/, Ecto.UUID.generate())
    Router.call(conn(method |> String.downcase() |> String.to_atom(), concrete), @opts)
  end

  defp unmatched?(conn) do
    conn.status == 404 and Jason.decode(conn.resp_body) == {:ok, %{"error" => "not_found"}}
  end

  # The files Plug.Static serves at the root, read from the router's `only:` list.
  defp static_assets do
    case Regex.run(~r/plug\(Plug\.Static,.*?only: ~w\(([^)]*)\)/s, Lens.source()) do
      [_, list] ->
        String.split(list)

      _ ->
        flunk(
          "router.ex no longer declares a Plug.Static `only:` allowlist in the shape this test reads"
        )
    end
  end

  # A URL is either a static asset the router serves or a declared route.
  defp assert_url(%URI{path: "/" <> file = path} = uri, where) do
    if file in static_assets() do
      conn = dispatch("GET", path)
      assert conn.status == 200, "#{where}: #{URI.to_string(uri)} answered #{conn.status}"
      conn
    else
      assert_route("GET", path, where)
    end
  end

  defp assert_route(method, path, where) do
    assert {method, path} in Lens.route_keys(),
           "#{where} documents `#{method} #{path}`, but router.ex declares no such route"

    conn = dispatch(method, path)

    refute unmatched?(conn),
           "#{where} documents `#{method} #{path}`; the router answered with the catch-all 404"
  end

  # A reference to the /new flow. Every documented link that carries a query is
  # one (the page links nothing else with a query), so the path must be the one
  # app.js handles, every query key one app.js reads, and a concrete template
  # value a known template.
  defp assert_new_flow_ref(%URI{path: path, query: query}, where) do
    assert path == new_flow_path(),
           "#{where} links #{inspect(path)}, but app.js runs the deploy flow at #{inspect(new_flow_path())}"

    params = URI.decode_query(query || "")

    for key <- Map.keys(params) do
      assert key in new_flow_params(),
             "#{where} passes ?#{key}= to #{path}, which app.js never reads (it reads #{inspect(MapSet.to_list(new_flow_params()))})"
    end

    case Map.fetch(params, template_param()) do
      {:ok, "<" <> _placeholder} -> :placeholder
      {:ok, slug} -> assert_known_template(slug, where) && slug
      :error -> :no_template
    end
  end

  defp public_urls(text) do
    host = public_host()

    @url_re
    |> Regex.scan(text)
    |> Enum.map(fn [u] -> URI.parse(u) end)
    |> Enum.filter(&(&1.host == host))
  end

  # A badge: an SVG the router serves on the public host, linking to the /new
  # flow with a template that ships a site app (the badge promises a live site).
  defp assert_badges(text, where) do
    badges = Regex.scan(@badge_re, text)

    assert badges != [],
           "#{where} carries no [![…](img)](target) badge — the extractor found nothing to check"

    for [_, img, target] <- badges do
      img_uri = URI.parse(img)
      target_uri = URI.parse(target)
      assert img_uri.host == public_host(), "badge image #{img} is not on #{public_host()}"
      assert target_uri.host == public_host(), "badge target #{target} is not on #{public_host()}"

      svg = assert_url(img_uri, "#{where} badge image")
      assert [ctype | _] = Plug.Conn.get_resp_header(svg, "content-type")

      assert ctype =~ "image/svg+xml",
             "#{where} badge image #{img_uri.path} is served as #{ctype}"

      assert_route("GET", target_uri.path, "#{where} badge")
      slug = assert_new_flow_ref(target_uri, "#{where} badge")

      assert is_binary(slug),
             "#{where} badge target #{target} carries no ?#{template_param()}= value"

      assert AppFiles.app_template?(slug),
             "#{where} badge launches #{inspect(slug)}, which ships no site app — the badge promises a live site"
    end
  end

  ## Tests

  test "the README badge and the page's snippet point at the /new flow with a served SVG" do
    assert_badges(readme(), "README.md")
    assert_badges(page(), "the launch page's snippet")
    assert readme() =~ "(#{@page_rel})", "README.md no longer links the launch page #{@page_rel}"
  end

  test "every barkpark.cloud URL, /new reference and backticked route in the launch page resolves" do
    text = page()

    urls = public_urls(text)

    assert length(urls) >= 3,
           "found #{length(urls)} #{public_host()} URLs in the page — the extractor is blind"

    curl_urls =
      @curl_re
      |> Regex.scan(text)
      |> Enum.map(fn [_, _m, u | _] -> URI.parse(u) end)
      |> MapSet.new()

    for uri <- urls, uri not in curl_urls do
      assert_url(uri, "launch page URL")
      if uri.query, do: assert_new_flow_ref(uri, "launch page URL #{URI.to_string(uri)}")
    end

    routes = Regex.scan(@backtick_route_re, text)

    assert length(routes) >= 8,
           "found #{length(routes)} backticked routes in the page — the extractor is blind"

    for [_, method, raw] <- routes do
      uri = URI.parse(raw)
      assert_route(method, uri.path, "launch page")
      if uri.query, do: assert_new_flow_ref(uri, "launch page `#{method} #{raw}`")
    end

    # Bare path-with-query spans (the resume link), outside a URL or a route
    # span. Matched by SHAPE, not by the /new literal, so a renamed flow path
    # cannot make them silently disappear from the check.
    for [_, raw] <- Regex.scan(~r/`(\/[^`\s?]*\?[^`\s]+)`/, text) do
      assert_route("GET", URI.parse(raw).path, "launch page `#{raw}`")
      assert_new_flow_ref(URI.parse(raw), "launch page `#{raw}`")
    end
  end

  test "the page's curl launch command names a real route and a launchable template" do
    commands = Regex.scan(@curl_re, page())

    assert commands != [],
           "the launch page carries no `curl -X METHOD URL` command — the extractor is blind"

    for [_, method, url, rest] <- commands do
      uri = URI.parse(url)
      assert uri.host == public_host(), "curl command targets #{uri.host}, not #{public_host()}"
      assert_route(method, uri.path, "curl command")

      case Regex.run(@curl_body_re, rest) do
        [_, json] ->
          body = Jason.decode!(json)
          if slug = body["template"], do: assert_known_template(slug, "curl command body")

        nil ->
          :ok
      end
    end
  end

  test "the page's template table is exactly the catalog, with the right site-app column" do
    rows =
      Regex.scan(@template_row_re, page()) |> Map.new(fn [_, slug, yn] -> {slug, yn == "yes"} end)

    assert MapSet.new(Map.keys(rows)) == MapSet.new(Templates.slugs()),
           "the page's template table lists #{inspect(Enum.sort(Map.keys(rows)))}; " <>
             "the catalog is #{inspect(Templates.slugs())}"

    for {slug, ships_app} <- rows do
      assert_known_template(slug, "template table")

      assert ships_app == AppFiles.app_template?(slug),
             "template table says #{slug} ships a site app: #{ships_app}; AppFiles says #{AppFiles.app_template?(slug)}"
    end
  end

  test "the page's provisioning step table matches the console's step order and labels" do
    rows = Regex.scan(@step_row_re, page()) |> Enum.map(fn [_, k, label] -> {k, label} end)

    assert rows == server_steps(),
           "the page's step table is #{inspect(rows)}; app.js renders #{inspect(server_steps())}"
  end
end
