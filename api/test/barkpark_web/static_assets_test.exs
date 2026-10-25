defmodule BarkparkWeb.StaticAssetsTest do
  @moduledoc """
  The `/assets` files the root layout links carry a content hash in their
  URL and are served `immutable` for that hash; any other hash gets the
  current bytes with `no-cache`, and the plain names keep `no-cache`
  (task-66122189b7af6ea2).
  """
  # Writes probe files into priv/static/assets and touches :persistent_term.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StaticAssets

  @immutable ["public, max-age=31536000, immutable"]

  # The 27 files the root layout linked as plain /assets names before this
  # change, in page order.
  @root_files ~w(
    bp-paper-editor-shell.css bp-media-picker.css
    bp-rich-text-editor.js bp-search-intel.js bp-asset-explorer.js
    bp-asset-browser.js bp-media-picker.js bp-reference-picker.js
    bp-document-preview.js bp-overflow-menu.js bp-paper-editor.bundle.js
    phoenix.js phoenix_live_view.js
    bp-modal-focus.js bp-sheet-formula.js bp-sheet-pointing.js bp-sheet-grid.js
    bp-graph.js bp-tmux-terminal.js bp-paper-mermaid.js bp-chat-composer.js
    bp-chat-turn-clock.js bp-chat-palette.js bp-paper-editor-hooks.js
    bp-array-focus.js bp-tab-keys.js bp-datetime-field.js
  )

  defp file_hash(name), do: StaticAssets.digest(File.read!(StaticAssets.file(name)))

  describe "path/1" do
    test "puts the SHA-256 of the file's bytes in the URL" do
      hash = file_hash("phoenix.js")
      assert String.length(hash) == 16
      assert StaticAssets.path("phoenix.js") == "/assets/v/#{hash}/phoenix.js"
    end

    test "a missing file or an unsafe name keeps its plain URL" do
      assert StaticAssets.path("no-such-file.js") == "/assets/no-such-file.js"
      assert StaticAssets.hash("../mix.exs") == nil
      assert StaticAssets.hash(".hidden.js") == nil
      assert StaticAssets.fresh_hash("a/b.js") == nil
    end
  end

  describe "the served Studio page" do
    test "links every root layout /assets file under its content hash", %{conn: conn} do
      conn = init_test_session(conn, %{})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      urls =
        ~r{(?:src|href)="(/assets/[^"]+)"}
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      {hashed, other} = Enum.split_with(urls, &String.starts_with?(&1, "/assets/v/"))

      assert Enum.map(hashed, &Path.basename/1) == @root_files

      for url <- hashed do
        ["", "assets", "v", hash, name] = String.split(url, "/")
        assert hash == file_hash(name), "#{url} does not carry the hash of #{name}'s bytes"
      end

      # Every other /assets link on the page is a root layout asset with its
      # own hash (BarkparkWeb.RootAssets): no plain, revalidated name is left.
      assert other != []
      assert Enum.all?(other, &String.starts_with?(&1, "/assets/root/")), inspect(other)
    end

    test "the datetime hook still finds its script by the hashed src" do
      root = File.read!(Path.expand("../../lib/barkpark_web/layouts/root.html.heex", __DIR__))
      assert root =~ ~s|const SCRIPT = 'script[src$="/bp-datetime-field.js"]';|
      refute root =~ ~s|script[src^="/assets/|
    end
  end

  describe "GET /assets/v/<hash>/<name>" do
    test "the current hash is served immutable with the file's bytes", %{conn: conn} do
      conn = get(conn, StaticAssets.path("phoenix.js"))

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == @immutable
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "javascript"
      assert conn.resp_body == File.read!(StaticAssets.file("phoenix.js"))
    end

    test "every root layout file answers immutable for its own hash" do
      for name <- @root_files do
        conn = get(build_conn(), StaticAssets.path(name))
        assert conn.status == 200, name
        assert get_resp_header(conn, "cache-control") == @immutable, name
      end
    end

    test "a stylesheet keeps its css content type", %{conn: conn} do
      conn = get(conn, StaticAssets.path("bp-media-picker.css"))
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/css"
    end

    test "an old hash gets the current bytes with no-cache", %{conn: conn} do
      conn = get(conn, "/assets/v/AAAAAAAAAAAAAAAA/phoenix.js")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert conn.resp_body == File.read!(StaticAssets.file("phoenix.js"))
    end

    test "a 304 on the current hash still says immutable", %{conn: conn} do
      first = get(conn, StaticAssets.path("phoenix.js"))
      [etag] = get_resp_header(first, "etag")

      again =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get(StaticAssets.path("phoenix.js"))

      assert again.status == 304
      assert get_resp_header(again, "cache-control") == @immutable
    end

    test "HEAD answers like GET", %{conn: conn} do
      conn = head(conn, StaticAssets.path("phoenix.js"))
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == @immutable
    end

    test "an unknown or unsafe name is not served", %{conn: conn} do
      assert get(conn, "/assets/v/AAAAAAAAAAAAAAAA/no-such-file.js").status == 404

      # The plug passes an unsafe name on untouched; Plug.Static then refuses
      # it with its own 400, as it does for the plain /assets path.
      assert_raise Plug.Static.InvalidPathError, fn ->
        get(build_conn(), "/assets/v/AAAAAAAAAAAAAAAA/..%2Fmix.exs")
      end
    end

    test "with compress: false, as in dev, both hashes still answer" do
      opts = BarkparkWeb.Plugs.StaticAssets.init(compress: false)

      for {url, cc} <- [
            {StaticAssets.path("phoenix.js"), @immutable},
            {"/assets/v/AAAAAAAAAAAAAAAA/phoenix.js", ["no-cache"]}
          ] do
        conn =
          Plug.Test.conn(:get, url)
          |> put_req_header("accept-encoding", "gzip, br")
          |> BarkparkWeb.Plugs.StaticAssets.call(opts)

        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == cc
        assert get_resp_header(conn, "content-encoding") == []
      end
    end

    test "the plain name keeps no-cache", %{conn: conn} do
      conn = get(conn, "/assets/phoenix.js")
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end

  describe "a file that changes on disk" do
    setup do
      name = "bp-static-assets-probe-#{System.unique_integer([:positive])}.js"
      probe = StaticAssets.file(name)

      on_exit(fn ->
        for f <- [probe, probe <> ".gz", probe <> ".br"], do: File.rm(f)
        :persistent_term.erase({StaticAssets, name})
      end)

      %{name: name, probe: probe}
    end

    test "gets a new URL, and the old URL drops to no-cache", %{name: name, probe: probe} do
      File.write!(probe, "window.probe = 1;\n")
      old = StaticAssets.path(name)
      assert get(build_conn(), old) |> get_resp_header("cache-control") == @immutable

      File.write!(probe, "window.probe = 22;\n")
      # A new size is a new stat, so the memo is not trusted.
      new = StaticAssets.path(name)
      refute new == old

      assert get(build_conn(), new) |> get_resp_header("cache-control") == @immutable

      stale = get(build_conn(), old)
      assert get_resp_header(stale, "cache-control") == ["no-cache"]
      assert stale.resp_body == "window.probe = 22;\n"
    end

    test "a stale memo never earns immutable", %{name: name, probe: probe} do
      File.write!(probe, "window.probe = 3;\n")
      real = StaticAssets.hash(name)

      # Pin a wrong hash under the file's current stat, as if the bytes had
      # changed without the stat changing.
      {sig, ^real} = :persistent_term.get({StaticAssets, name})
      :persistent_term.put({StaticAssets, name}, {sig, "ZZZZZZZZZZZZZZZZ"})

      assert StaticAssets.path(name) == "/assets/v/ZZZZZZZZZZZZZZZZ/#{name}"
      conn = get(build_conn(), StaticAssets.path(name))
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "a compressed sibling is used only when its mtime matches the file's",
         %{name: name, probe: probe} do
      body = String.duplicate("window.probe = 4;\n", 50)
      File.write!(probe, body)
      File.write!(probe <> ".gz", :zlib.gzip(body))
      {:ok, %{mtime: mtime}} = File.stat(probe, time: :posix)
      File.touch!(probe <> ".gz", mtime)

      fetch = fn ->
        build_conn()
        |> put_req_header("accept-encoding", "gzip")
        |> get(StaticAssets.path(name))
      end

      matched = fetch.()
      assert get_resp_header(matched, "content-encoding") == ["gzip"]
      assert get_resp_header(matched, "cache-control") == @immutable

      # A sibling left from other bytes (the deploy has not rebuilt it yet).
      File.write!(probe <> ".gz", :zlib.gzip("window.old = 1;\n"))
      File.touch!(probe <> ".gz", mtime - 60)

      unmatched = fetch.()
      assert get_resp_header(unmatched, "content-encoding") == []
      assert unmatched.resp_body == body
      assert get_resp_header(unmatched, "cache-control") == @immutable
    end
  end
end
