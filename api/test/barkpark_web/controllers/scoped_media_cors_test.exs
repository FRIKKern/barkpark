defmodule BarkparkWeb.ScopedMediaCorsTest do
  @moduledoc """
  jf-w1-scoped-media-cors-followup — the RECORDED DECISION for the share-aware
  SCOPED media serve surface:

      GET /w/:ws/p/:project/media
      GET /w/:ws/p/:project/media/:id/meta
      GET /w/:ws/p/:project/media/files/*path
      GET /w/:ws/p/:project/media/renditions/:id/:preset

  **These routes deliberately DO NOT carry `access-control-allow-origin: *`,
  and this file pins that absence.** They are the sibling of the four FLAT
  media serve GETs that DID get the wildcard in #15408 — and the reason they
  are treated differently is structural, not an oversight.

  ## The ruling (lead ruling, inherited from #15408)

  A media serve route may carry `access-control-allow-origin: *` only where ALL
  THREE hold:

    1. the route is GET/HEAD only;
    2. it is never served with credentials (no `access-control-allow-credentials`);
    3. it authorizes **by URL** — a share token or signed path in the URL
       itself — rather than by a session cookie or ambient browser credential.

  ## The per-route verdict: (1) and (2) hold, (3) FAILS — on all four

  The flat scope rides `[:media_public_cors, :api, :strict_bearer_media_read]`,
  and NEITHER of those pipelines mounts `:fetch_session` or
  `OptionalSessionToken` — `:current_user` is unassignable there, so
  `Media.Storage.Access.account_member?/1` (the only session-reading arm of
  `Access.authenticated?/1`) is false by construction. That is what made the
  flat responses provably session-INVARIANT, and #15408 pins it with a test.

  The scoped scope rides `:shared_media_api`, which opens with

      plug(:fetch_session)
      plug(BarkparkWeb.Plugs.OptionalSessionToken)

  and `OptionalSessionToken` assigns BOTH `:api_token` (from
  `session["api_token"]`) and `:current_user` (from `session["user_session"]`).
  It is mounted on purpose and cannot be removed: these routes are loaded by
  bare browser `<img>` tags from the scoped Studio media library, which carry
  the session cookie and can never attach a Bearer header. So condition (3)
  fails by DESIGN, permanently, on every route in the scope — and unlike the
  flat surface there is no invariant left to pin.

  `session variance` below proves that, rather than asserting it in prose: the
  same URL with no share configured answers 403 to an anonymous caller and 200
  to the identical request carrying only a member's account-session cookie.
  The cookie alone flips the answer. That is exactly the ambient authority
  condition (3) exists to keep out from under a wildcard grant.

  ## Why the absence, concretely

  `*` alone is not itself an exploit — with no
  `access-control-allow-credentials` a browser will not expose a
  cookie-carrying cross-origin response. The costs are the two that condition
  (3) is a proxy for:

    * **Cache safety.** A static `*` is emitted with no `Vary` at all, over a
      body that varies by Cookie with no `Vary: Cookie` anywhere. Any shared
      cache in front (CDN, corporate proxy) may store a signed-in member's
      private listing under the bare URL and hand it to the next reader. The
      flat routes cannot hit this — their responses do not vary. These can.
    * **No holdable invariant.** The flat grant is safe *because* a test reds
      the moment a session plug appears. Here the session plug is already
      there and load-bearing, so nothing stops a later
      `access-control-allow-credentials: true` from turning the wildcard into
      a real credentialed cross-origin read.

  ## The sanctioned cross-origin path for these routes

  Cross-origin reads of scoped media are NOT impossible today — the filing's
  premise is too strong. `BarkparkWeb.Plugs.DatasetCors` runs at the ENDPOINT,
  strips the `/w/:ws/p/:project` tenancy prefix (`take_tenancy_prefix/1`) and
  matches `["media" | _]` against the remainder, so a scoped media GET already
  reflects any origin on the dataset's `cors_origins` allow-list, with
  `Vary: Origin`. That is the per-tenant, opt-in, cache-correct grant, and it
  is the answer for a site like `jarl.no`: allowlist the origin on the
  dataset. `the sanctioned reflector` pins it.

  MUTATION PROOF: prepend `:media_public_cors` to the scoped media scope's
  `pipe_through` and every test in "no wildcard" and "the sanctioned
  reflector" reds by name; remove it and they go green.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Sharing
  alias Barkpark.Tenancy

  import Barkpark.TenancyFixtures

  @dataset "production"

  # A cross-origin reader that is deliberately NOT on `DatasetCors`'s
  # `@always_allowed_origins` (barkpark.cloud / *.vercel.app) and not in
  # `:default_cors_origins` (`[]` in the test env) — so the endpoint reflector
  # is a guaranteed no-op and any header seen here could only have come from a
  # router-level wildcard mount.
  @origin "https://jarl.no"

  # One that IS always allowed — the sanctioned path.
  @allowlisted_origin "https://barkpark.cloud"

  setup do
    ws = create_workspace!("scoped-media-cors")
    project = create_project!(ws, "scoped-media-cors-p")
    file = put_media!(ws, project, "SCOPED-BYTES")

    %{ws: ws, project: project, media_file: file}
  end

  defp put_media!(ws, project, bytes) do
    name = "scoped-cors-#{System.unique_integer([:positive])}.png"
    rel = "uploads/scoped-media-cors-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: byte_size(bytes),
      dataset: @dataset,
      workspace_id: ws.id,
      project_id: project.id
    })
    |> Repo.insert!()
  end

  defp media_root(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/media"

  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  defp media_share(ws, project), do: "#{ws.slug}/#{project.slug}/#{@dataset}:media:read"

  defp cross_origin(conn), do: put_req_header(conn, "origin", @origin)
  defp acao(conn), do: get_resp_header(conn, "access-control-allow-origin")
  defp acac(conn), do: get_resp_header(conn, "access-control-allow-credentials")

  # The recorded decision, asserted on every scoped response in this file: no
  # wildcard, and never a credential grant.
  defp assert_no_wildcard(conn) do
    refute "*" in acao(conn)
    assert acac(conn) == []
    conn
  end

  # ── no wildcard, on the 200 shapes ────────────────────────────────────────
  describe "no wildcard on the scoped serve GETs — 200 shape" do
    setup %{ws: ws, project: project} do
      with_shares(media_share(ws, project))
      :ok
    end

    test "GET /w/:ws/p/:project/media (index)", %{ws: ws, project: project} do
      conn = build_conn() |> cross_origin() |> get(media_root(ws, project))

      assert conn.status == 200
      assert_no_wildcard(conn)
      # Not merely "no wildcard" — no grant of ANY kind for this origin.
      assert acao(conn) == []
    end

    test "GET /w/:ws/p/:project/media/:id/meta", %{ws: ws, project: project, media_file: file} do
      conn =
        build_conn() |> cross_origin() |> get("#{media_root(ws, project)}/#{file.id}/meta")

      assert conn.status == 200
      assert_no_wildcard(conn)
      assert acao(conn) == []
    end

    test "GET /w/:ws/p/:project/media/files/*path serves the bytes with no grant",
         %{ws: ws, project: project, media_file: file} do
      conn =
        build_conn() |> cross_origin() |> get("#{media_root(ws, project)}/files/#{file.path}")

      assert conn.status == 200
      assert conn.resp_body == "SCOPED-BYTES"
      assert_no_wildcard(conn)
      assert acao(conn) == []
    end
  end

  # ── no wildcard, on the 404 shapes ────────────────────────────────────────
  describe "no wildcard on the scoped serve GETs — 404 shape" do
    setup %{ws: ws, project: project} do
      with_shares(media_share(ws, project))
      :ok
    end

    test "a serve path matching no row", %{ws: ws, project: project} do
      conn =
        build_conn()
        |> cross_origin()
        |> get("#{media_root(ws, project)}/files/uploads/nope/absent.png")

      assert conn.status == 404
      assert_no_wildcard(conn)
    end

    test "a meta id matching no row", %{ws: ws, project: project} do
      conn =
        build_conn()
        |> cross_origin()
        |> get("#{media_root(ws, project)}/#{Ecto.UUID.generate()}/meta")

      assert conn.status in [403, 404]
      assert_no_wildcard(conn)
    end

    test "a rendition id matching no row", %{ws: ws, project: project} do
      conn =
        build_conn()
        |> cross_origin()
        |> get("#{media_root(ws, project)}/renditions/#{Ecto.UUID.generate()}/thumb")

      refute conn.status == 200
      assert_no_wildcard(conn)
    end
  end

  # ── scoped WRITES carry nothing either ────────────────────────────────────
  describe "scoped media writes carry no CORS grant" do
    test "POST .../v1/media/:dataset/upload (anonymous)", %{ws: ws, project: project} do
      with_shares(media_share(ws, project))

      conn =
        build_conn()
        |> cross_origin()
        |> post("/w/#{ws.slug}/p/#{project.slug}/v1/media/#{@dataset}/upload", %{})

      refute conn.status == 200
      assert_no_wildcard(conn)
      assert acao(conn) == []
    end

    test "DELETE .../v1/media/:dataset/:id (anonymous)", %{
      ws: ws,
      project: project,
      media_file: file
    } do
      with_shares(media_share(ws, project))

      conn =
        build_conn()
        |> cross_origin()
        |> delete("/w/#{ws.slug}/p/#{project.slug}/v1/media/#{@dataset}/#{file.id}")

      refute conn.status == 200
      assert_no_wildcard(conn)
      assert acao(conn) == []
    end
  end

  # ── THE CRUX: condition (3) fails, demonstrated ───────────────────────────
  describe "session variance — why condition (3) fails on this surface" do
    test "the SAME URL answers 403 anonymous and 200 on a member's cookie alone",
         %{ws: ws, project: project} do
      # No share at all: the only thing that can open this scope is membership,
      # and on this pipeline membership is resolvable from the session cookie.
      Application.delete_env(:barkpark, :shares)

      {:ok, user} =
        Accounts.register_user(%{
          email: "scoped-media-cors-#{System.unique_integer([:positive])}@example.com",
          password: "correct-horse-battery-staple-1"
        })

      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "admin", "user")
      {:ok, session_raw} = Accounts.create_user_session_token(user)

      bare = build_conn() |> cross_origin() |> get(media_root(ws, project))

      with_cookie =
        build_conn()
        |> Plug.Test.init_test_session(%{"user_session" => session_raw})
        |> cross_origin()
        |> get(media_root(ws, project))

      # The ambient credential — and NOTHING in the URL — is what opens it.
      assert bare.status in [401, 403, 404]
      assert with_cookie.status == 200
      refute bare.status == with_cookie.status

      # Neither answer carries a wildcard. If one did, this exact response —
      # the one the cookie unlocked — would be the body a static `*` invites a
      # shared cache to hand to the anonymous reader above.
      assert_no_wildcard(bare)
      assert_no_wildcard(with_cookie)
    end
  end

  # ── the sanctioned cross-origin path ──────────────────────────────────────
  describe "the sanctioned reflector — allowlisted origins DO get a grant" do
    test "an always-allowed origin is reflected on a scoped media serve GET, with Vary",
         %{ws: ws, project: project, media_file: file} do
      with_shares(media_share(ws, project))

      conn =
        build_conn()
        |> put_req_header("origin", @allowlisted_origin)
        |> get("#{media_root(ws, project)}/files/#{file.path}")

      assert conn.status == 200
      # DatasetCors strips the /w/:ws/p/:project prefix and matches ["media"|_]
      # on the remainder — so the scoped surface was never CORS-silent.
      assert acao(conn) == [@allowlisted_origin]
      assert acac(conn) == []
      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "a non-allowlisted origin gets nothing — the delta the row really names",
         %{ws: ws, project: project, media_file: file} do
      with_shares(media_share(ws, project))

      conn =
        build_conn() |> cross_origin() |> get("#{media_root(ws, project)}/files/#{file.path}")

      assert conn.status == 200
      assert acao(conn) == []
    end
  end
end
