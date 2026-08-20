defmodule BarkparkWeb.Integration.StaticCacheHeadersTest do
  @moduledoc """
  Exact-string pins on the cache policy of the endpoint's single `Plug.Static`
  (`BarkparkWeb.Endpoint`, the `plug Plug.Static` at "/").

  Why pins and not a smoke test: the before-state was a bare plug with no
  `headers:` and no `cache_control_for_etags:`, so every static shipped
  Plug.Static's default `cache-control: public`. Browsers then heuristically
  cached the unversioned Studio shell (`/assets/bp-*.js`, `/fonts/*.woff2`)
  ACROSS deploys, and a returning operator saw stale UI until a hard refresh.
  The fix is a pure shortening — `public` → `no-cache` — and `no-cache` means
  "revalidate", not "don't store": the browser keeps the bytes and asks with
  `If-None-Match`, and Plug.Static answers 304 off the etag.

  Two keys, two branches. `Plug.Static.serve_static/5` writes
  `cache_control_for_etags` in `put_cache_header/6` and merges `headers:` only
  on the `{:stale, conn}` (200) branch — the `{:fresh, conn}` (304) branch
  sends without touching `headers:`. So the 200 test and the 304 test below are
  NOT redundant: each covers a branch the other cannot reach, and either key
  alone leaves one of them shipping `public`.

  Every assertion is a full-list equality (`== ["no-cache"]`), never `=~` or a
  head match, so an added second `cache-control` value is a failure rather than
  a silent pass.

  Scope note: `/assets/bp-pdrender.wasm.gz` is built at deploy time and is
  absent from the source tree, so it cannot be pinned here — the same policy
  covers it at runtime and the post-merge curl transcript is its proof.
  `/assets/app.js` and `/assets/app.css` do not exist on this surface (404) and
  are deliberately not pinned.

  Non-goal (cch charter D139): nothing here compares etags to detect staleness.
  Plug.Static's etag is `phash2({size, mtime})` of the file it serves — never
  content identity — so an etag is only ever a revalidation token.
  """
  use BarkparkWeb.ConnCase, async: true

  # Real files under `BarkparkWeb.static_paths()`, one per served root:
  # a Studio asset, a self-hosted font, and the two top-level statics.
  @pinned_statics [
    "/assets/bp-graph.js",
    "/fonts/Inter-var.woff2",
    "/favicon.ico",
    "/robots.txt"
  ]

  describe "static assets ship no-cache on the 200 branch" do
    for path <- @pinned_statics do
      test "GET #{path} → 200 with cache-control exactly no-cache", %{conn: conn} do
        conn = get(conn, unquote(path))

        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["no-cache"]
      end
    end

    test "the 200 carries an etag, so no-cache can be answered by revalidation", %{conn: conn} do
      conn = get(conn, "/assets/bp-graph.js")

      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      assert etag != ""
    end

    test "a ?vsn= fingerprinted request is pinned too", %{conn: conn} do
      conn = get(conn, "/assets/bp-graph.js?vsn=d")

      assert conn.status == 200
      # This is the `headers:` key's job, and the reason it is not redundant
      # with `cache_control_for_etags:`. A `vsn=` query string takes a separate
      # clause of `Plug.Static.put_cache_header/6` whose default is
      # `public, max-age=31536000, immutable` — only the merged `headers:` map
      # overrides it. Drop that key and a fingerprinted URL (Phoenix's own
      # static_path form) ships a year of immutable caching.
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "vary stays Accept-Encoding (the gzip: flag is load-bearing)", %{conn: conn} do
      conn = get(conn, "/assets/bp-graph.js")

      assert conn.status == 200
      # `gzip: not code_reloading?` is what makes Plug.Static advertise the two
      # representations. Removing the flag is a byte no-op today (no .gz
      # siblings exist) but silently drops this header, so caches would stop
      # keying encodings apart. Pinned here so that removal is a red test.
      assert get_resp_header(conn, "vary") == ["Accept-Encoding"]
    end
  end

  describe "conditional requests take the 304 branch, still pinned" do
    test "replaying the captured etag → 304 that ALSO carries no-cache", %{conn: conn} do
      first = get(conn, "/assets/bp-graph.js")
      assert first.status == 200
      assert [etag] = get_resp_header(first, "etag")

      second =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/assets/bp-graph.js")

      assert second.status == 304
      assert second.resp_body == ""

      # This is the `cache_control_for_etags:` proof. The 304 branch never
      # merges `headers:`, so without that second key this list would be
      # ["public"] — the revalidation answer itself would license heuristic
      # caching and the stale shell would survive the fix.
      assert get_resp_header(second, "cache-control") == ["no-cache"]
    end

    test "a font revalidates the same way (no immutable arm on this surface)", %{conn: conn} do
      first = get(conn, "/fonts/Inter-var.woff2")
      assert first.status == 200
      assert [etag] = get_resp_header(first, "etag")

      second =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/fonts/Inter-var.woff2")

      assert second.status == 304
      assert get_resp_header(second, "cache-control") == ["no-cache"]
    end
  end
end
