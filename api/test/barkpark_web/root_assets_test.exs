defmodule BarkparkWeb.RootAssetsTest do
  @moduledoc """
  The root layout's inline stylesheets and body scripts are served as hashed,
  cacheable files, and the page links them where the blocks stood
  (task-cca3c6d48e57097e).
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.RootAssets
  alias BarkparkWeb.RootAssets.Splitter

  @admin_token "barkpark-dev-token"

  describe "Splitter.split/1" do
    test "cuts style blocks and body nonce scripts, keeps the head script and line numbers" do
      source = """
      <head>
        <script nonce={assigns[:csp_nonce]}>
          prePaint();
        </script>
        <style>
          a { color: red; }
          <%= paper_stylesheet() %>
          b { color: blue; }
        </style>
        <link rel="stylesheet" href="/assets/x.css" />
        <style>
          c { color: green; }
        </style>
      </head>
      <body>
        <script nonce={assigns[:csp_nonce]}>
          let liveSocket = 1;
        </script>
        <p>after</p>
      </body>
      """

      {out, assets} = Splitter.split(source)

      assert Enum.map(assets, fn {name, kind, _} -> {name, kind} end) == [
               {"studio-root-1.css", :css},
               {"studio-root-2.css", :css},
               {"studio-root-1.js", :js}
             ]

      [{_, :css, parts1}, {_, :css, parts2}, {_, :js, parts3}] = assets
      assert [a, :paper_stylesheet, b] = parts1
      assert a =~ "a { color: red; }"
      assert b =~ "b { color: blue; }"
      assert parts2 == ["    c { color: green; }\n"]
      assert parts3 == ["    let liveSocket = 1;\n"]

      # The head script stays inline.
      assert out =~ "prePaint();"
      refute out =~ "color: red"
      refute out =~ "liveSocket"

      # Cascade order: first sheet, the static link, second sheet.
      i1 = :binary.match(out, ~s|RootAssets.path("studio-root-1.css")|) |> elem(0)
      ix = :binary.match(out, ~s|/assets/x.css|) |> elem(0)
      i2 = :binary.match(out, ~s|RootAssets.path("studio-root-2.css")|) |> elem(0)
      assert i1 < ix and ix < i2

      # Every line after a cut keeps its number.
      line_of = fn text, needle ->
        text |> String.split("\n") |> Enum.find_index(&String.contains?(&1, needle))
      end

      assert line_of.(out, "<p>after</p>") == line_of.(source, "<p>after</p>")
    end

    test "a block holding another EEx tag fails" do
      assert_raise ArgumentError, fn ->
        Splitter.split("<head>\n<style>\n<%= other() %>\n</style>\n</head>\n")
      end
    end
  end

  describe "the compiled root layout" do
    test "every extracted body is in root.html.heex, byte for byte" do
      template = File.read!(RootAssets.template_path())

      for name <- RootAssets.names() do
        {_type, body, _hash} = RootAssets.fetch(name)

        for chunk <- String.split(body, Barkpark.PortableDoc.Render.Stylesheet.css()) do
          assert String.contains?(template, chunk), "#{name} carries bytes the template does not"
        end
      end
    end

    test "the Studio page links each asset once, in page order, and inlines none of them", %{
      conn: conn
    } do
      html =
        conn
        |> init_test_session(%{"api_token" => @admin_token})
        |> get(scoped_studio("/d/production/studio"))
        |> html_response(200)

      positions =
        for name <- RootAssets.names() do
          assert [{pos, _}] = :binary.matches(html, RootAssets.path(name))
          pos
        end

      assert positions == Enum.sort(positions)
      refute html =~ "new LiveView.LiveSocket("
      assert BarkparkWeb.RootAssetsInline.inline(html) =~ "new LiveView.LiveSocket("
    end
  end

  describe "GET /assets/root/<hash>/<name>" do
    test "the current hash is cached for a year as immutable", %{conn: conn} do
      for name <- RootAssets.names() do
        {type, body, _hash} = RootAssets.fetch(name)
        resp = get(conn, RootAssets.path(name))

        assert resp.status == 200
        assert resp.resp_body == body
        assert get_resp_header(resp, "content-type") == [type]
        assert get_resp_header(resp, "cache-control") == ["public, max-age=31536000, immutable"]
      end
    end

    test "an old hash gets the current body, not cached", %{conn: conn} do
      [name | _] = RootAssets.names()
      {_type, body, _hash} = RootAssets.fetch(name)
      resp = get(conn, "/assets/root/not-the-hash/#{name}")

      assert resp.status == 200
      assert resp.resp_body == body
      assert get_resp_header(resp, "cache-control") == ["no-cache"]
    end

    test "an unknown name is not served here", %{conn: conn} do
      resp = get(conn, "/assets/root/x/nope.css")
      assert resp.status == 404
    end
  end
end
