defmodule BarkparkCloud.Web.RouterHeadAndFaviconTest do
  @moduledoc """
  Two small honesty fixes in the shell, pinned.

  **HEAD.** `Plug.Router` only declares `get`/`post`/… clauses, so before
  `plug(Plug.Head)` every HEAD request in this control plane — `curl -I`, an
  uptime checker, a link previewer — fell through to the `match _` catch-all and
  got a 404 about a path that plainly exists. One plug gives every GET route its
  HEAD twin: same status, same headers, empty body. The body is dropped by the
  ADAPTER (`Bandit.Adapter.send_resp_body?/1` in prod, `Plug.Adapters.Test.Conn`
  here) — which is the only layer that can also drop it for a `send_file/3`
  response, since `send_file` streams past `resp_body` entirely.

  **favicon.** `favicon.ico` sat in the `Plug.Static` allowlist while the file
  did not exist, so every browser tab request 404'd. The file now exists: the
  console's own `.wordmark-mark` evergreen on the `button.svg` plate, rasterized
  at 16/32/48 — no new art.

  DB-free: nothing on these paths touches the Repo, so this runs `async: true`
  off a bare `ExUnit.Case`.
  """
  use ExUnit.Case, async: true
  import Plug.Test

  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # Every path this router answers with the SPA shell (see the "Dashboard SPA"
  # block in router.ex). All four are `send_file/3` responses.
  @shell_paths ["/", "/dashboard", "/new", "/activate"]

  # Plug.Test's adapter decides HEAD-ness from the state it was BUILT with, so
  # the method is set at conn/2 time — the empty body is the adapter's real
  # behaviour, not something this test simulates after the fact.
  defp request(method, path) do
    method |> conn(path) |> Router.call(@opts)
  end

  describe "favicon.ico" do
    test "GET /favicon.ico serves a real icon file (this used to 404)" do
      conn = request(:get, "/favicon.ico")

      assert conn.status == 200
      # ICO magic: reserved=0, type=1 (icon), then the image count.
      assert <<0, 0, 1, 0, count::little-16, _rest::binary>> = conn.resp_body
      assert count == 3, "expected the 16/32/48 multi-size icon"
      assert byte_size(conn.resp_body) > 1000
    end

    test "the file on disk is the one Plug.Static reaches for" do
      path = Application.app_dir(:barkpark_cloud, "priv/static/favicon.ico")
      assert File.exists?(path)
      assert File.read!(path) == request(:get, "/favicon.ico").resp_body
    end
  end

  describe "HEAD mirrors GET" do
    test "HEAD on every SPA shell path answers 200 with an empty body" do
      for path <- @shell_paths do
        get = request(:get, path)
        head = request(:head, path)

        assert get.status == 200, "#{path} GET should be 200"
        assert head.status == get.status, "HEAD #{path} must mirror the GET status"
        assert head.resp_body == "", "HEAD #{path} must carry no body"

        assert get_resp_header(head, "content-type") == get_resp_header(get, "content-type"),
               "HEAD #{path} must carry the same headers as the GET"
      end
    end

    test "HEAD on a static asset mirrors its GET too (favicon, css, js)" do
      for path <- ["/favicon.ico", "/app.css", "/app.js"] do
        get = request(:get, path)
        head = request(:head, path)

        assert get.status == 200
        assert head.status == 200
        assert head.resp_body == ""
        assert get_resp_header(head, "content-type") == get_resp_header(get, "content-type")
      end
    end

    test "HEAD on an unknown path still 404s — mirroring, not blanket 200s" do
      get = request(:get, "/nope-not-a-route")
      head = request(:head, "/nope-not-a-route")

      assert get.status == 404
      assert head.status == 404
      assert head.resp_body == ""
    end

    test "GET bodies are untouched — the HEAD plug is not silently emptying them" do
      # Guards against a vacuous green: if Plug.Head ever leaked into GET, every
      # assertion above would still pass while the console served nothing.
      assert request(:get, "/") |> Map.fetch!(:resp_body) =~ "<title>Barkpark Cloud</title>"
    end
  end

  defp get_resp_header(conn, key), do: Plug.Conn.get_resp_header(conn, key)
end
