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
            "/fonts/Inter-var.woff2"
          ] do
        conn = get(path)
        assert conn.status == 200, "expected #{path} to be served (200), got #{conn.status}"
      end
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
