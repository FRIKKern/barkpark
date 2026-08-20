defmodule BarkparkCloud.Web.StaticAllowlistTest do
  @moduledoc """
  Pins the Plug.Static `only:` allowlist in BarkparkCloud.Web.Router against future
  loosening. The SPA is served straight from priv/static, so any file that
  lands there — the `__preview__/` harness (mock.js, scenarios.mjs, serve.mjs),
  a future `/styleguide.html`, a stray fixture — becomes web-reachable the
  moment it is added to `only:`. This test proves the DEV-ONLY preview harness
  and an un-allowlisted page are NOT served (404) while the real app assets ARE
  (200), so shipping the preview tooling can never accidentally expose it.

  Static-file serving needs no DB — plain ExUnit + Plug.Test, mirroring the
  router web tests' direct `Router.call/2` style.
  """
  use ExUnit.Case, async: true
  import Plug.Test

  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp get(path), do: Router.call(conn(:get, path), @opts)

  describe "Plug.Static allowlist" do
    test "the real SPA assets ARE served" do
      for path <- [
            "/app.js",
            "/app.css",
            "/index.html",
            "/styleguide.html",
            "/robots.txt",
            "/fonts/Inter-var.woff2"
          ] do
        conn = get(path)
        assert conn.status == 200, "expected #{path} to be served (200), got #{conn.status}"
      end
    end

    test "/robots.txt is Disallow-all, byte-for-byte, and actually reachable" do
      # THREE things have to be true at once for the console's crawl policy to
      # exist, and until this test each of them could fail silently:
      #   1. cloud/priv/static/robots.txt is on disk,
      #   2. `robots.txt` is in the `only:` allowlist above (without it the
      #      request falls through Plug.Static to `match _` and answers a JSON
      #      404 — a robots.txt that no crawler ever sees),
      #   3. the bytes say Disallow-all.
      # The 200 loop above catches (1) and (2); the body assertion catches (3).
      # Asserting against the file on disk rather than a re-typed literal is
      # deliberate — a copy in the test would drift from the shipped file and
      # pin nothing.
      expected = File.read!(Path.join(:code.priv_dir(:barkpark_cloud), "static/robots.txt"))

      conn = get("/robots.txt")

      assert conn.status == 200
      assert conn.resp_body == expected
      assert conn.resp_body =~ "User-agent: *"
      assert conn.resp_body =~ "Disallow: /"

      # The console is a control plane: nothing here may be Allow-ed. A stray
      # `Allow:` line would open a crawl surface the moment it landed.
      refute conn.resp_body =~ "Allow:"
    end

    test "the __preview__ harness is NOT served (dev-only, never shipped)" do
      for path <- [
            "/__preview__/mock.js",
            "/__preview__/scenarios.mjs",
            "/__preview__/serve.mjs",
            "/__preview__/smoke.mjs"
          ] do
        conn = get(path)
        assert conn.status == 404, "#{path} must NOT be web-reachable (got #{conn.status})"
      end
    end

    test "an un-allowlisted file (e.g. the shared fixture) is NOT served" do
      # /styleguide.html joined the allowlist (charter decision 27 — the living
      # spec / human sign-off surface); the fixture stays private.
      conn = get("/__fixtures__/event_types.json")
      assert conn.status == 404
    end

    test "the allowlist never shadows the /v1 API namespace" do
      # A /v1 path falls through Plug.Static to the matchers; a bogus one is a
      # JSON 404 from `match _`, never a static-file hit.
      conn = get("/v1/definitely-not-a-route")
      assert conn.status == 404
      assert conn.resp_body =~ "not_found"
    end
  end
end
