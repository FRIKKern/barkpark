defmodule BarkparkWeb.MediaServeCorsTest do
  @moduledoc """
  jf-w1-media-cors-upstream — `access-control-allow-origin: *` on the four
  PUBLIC media serve GETs, and on nothing else.

  ## The ruling this pins (lead ruling, 2026-09-02 09:32Z)

      `access-control-allow-origin: *` on the four public media serve GETs
      (/media/files, /media/renditions, /media/index, /media/meta) — GET/HEAD
      only. NEVER `access-control-allow-credentials: true`. The response must
      not vary on cookies/session: each route must authorize by the URL
      (unguessable id, signed ref, the anon-read clamp), not by ambient auth.

  ## Why `*` is safe HERE and nowhere else on the core API

  The scope rides `[:api, :strict_bearer_media_read]`. NEITHER pipeline mounts
  `:fetch_session` or `OptionalSessionToken`, so `conn.assigns[:current_user]`
  is NEVER set on these four routes — `Access.account_member?/1` (the only
  session-reading arm of `Access.authenticated?/1`) is false by construction.
  What is left authorizes strictly by the URL: the server-generated blob path
  or the row id, the `SignedUrl` `?_=&exp=` signature, `AssignDefaultScope`'s
  path-derived workspace pin, and `Access.allowed?/4` on the asset's own
  visibility tier. A `Authorization: Bearer` header can widen the answer, but a
  browser never attaches one cross-origin, and with no
  `access-control-allow-credentials` it will not attach cookies either. So a
  hostile origin reading these bytes learns exactly what an anonymous `curl`
  learns — which is the whole reason `*` costs nothing here.

  `session_invariance` below is the test that keeps that true: it fires the
  same GET twice, once bare and once carrying a REAL logged-in account session
  (`"user_session"`) AND a session api_token, and demands byte-identical
  status + body. If someone later adds `OptionalSessionToken` to either
  pipeline, that test reds and the `*` grant must be re-argued.

  ## Ordering

  `:media_public_cors` is piped FIRST, before `:api`, so a response produced by
  a HALTING plug (the 401 from `:strict_bearer_media_read`'s
  `strict_on_presented`, a 429 from `RateLimit`) still carries the header and
  the browser can read the real status instead of an opaque CORS failure.
  `serves the header even on the strict-bearer 401` pins that ordering.

  ## No OPTIONS route, deliberately

  These are SIMPLE cross-origin GETs (no custom request headers), which the
  browser never preflights, so the scope declares no `{:options, …}` route and
  `PublicCors`'s OPTIONS arm is unreachable here. `Plugs.DatasetCors` at the
  endpoint still fail-closes any preflight that does arrive from a
  non-allowlisted origin, unchanged by this work.

  MUTATION PROOF: dropping `:media_public_cors` from the serve scope's
  `pipe_through` reds every test in the "serve GETs" and "signed URL" describes
  by name; restoring it goes green. The write-route and session-invariance
  tests stay green across that mutation, which is exactly the invariant they
  pin (the mount touches ONLY the four GETs).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.Storage.SignedUrl
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  # A cross-origin caster. Deliberately NOT one of `DatasetCors`'s
  # `@always_allowed_origins` (barkpark.cloud / *.vercel.app) nor of the
  # `:default_cors_origins` app config (`[]` in config.exs for the test env) —
  # so the endpoint-level reflector is a NO-OP and the header under assertion
  # can only have come from the router mount this task adds.
  @origin "https://jarl.no"

  @path "2026/09/media-cors-cast.bin"
  @bytes "ASCIINEMA-CAST-BYTES"

  setup do
    on_exit(fn -> _ = Blobstore.delete(@path) end)

    # The flat `/media` routes carry no tenancy slugs, so AssignDefaultScope
    # pins the read to the seeded DEFAULT workspace/project. The fixture row
    # must live there or every serve GET 404s (media fixtures need dataset_id).
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    {:ok, _} = Blobstore.put_bytes(@path, @bytes)

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: Path.basename(@path),
        original_name: Path.basename(@path),
        path: @path,
        mime_type: "application/octet-stream",
        size: byte_size(@bytes),
        dataset: "production",
        workspace_id: ws.id,
        project_id: project.id,
        dataset_id: dataset.id
      })
      |> Repo.insert!()

    %{ws: ws, project: project, media_file: file}
  end

  # Every request in this file carries the cross-origin `Origin` header — that
  # is the whole subject under test.
  defp cross_origin(conn), do: put_req_header(conn, "origin", @origin)

  defp acao(conn), do: get_resp_header(conn, "access-control-allow-origin")
  defp acac(conn), do: get_resp_header(conn, "access-control-allow-credentials")

  # The ruling's hard NEVER, asserted on every single response in this file.
  defp assert_open_and_uncredentialed(conn) do
    assert acao(conn) == ["*"]
    assert acac(conn) == []
    conn
  end

  defp assert_no_cors(conn) do
    assert acao(conn) == []
    assert acac(conn) == []
    conn
  end

  describe "the four public media serve GETs carry ACAO: *" do
    test "GET /media/files/*path — 200, the asciinema cast case" do
      conn = build_conn() |> cross_origin() |> get("/media/files/#{@path}")

      assert conn.status == 200
      assert conn.resp_body == @bytes
      assert_open_and_uncredentialed(conn)
    end

    test "GET /media/files/*path — 404 carries it too (route-level, not content-level)" do
      conn = build_conn() |> cross_origin() |> get("/media/files/2026/09/no-such-blob.bin")

      assert conn.status == 404
      assert_open_and_uncredentialed(conn)
    end

    test "GET /media — the index, 200" do
      conn = build_conn() |> cross_origin() |> get("/media")

      assert conn.status == 200
      assert %{"files" => _, "count" => _} = json_response(conn, 200)
      assert_open_and_uncredentialed(conn)
    end

    test "GET /media/:id/meta — 200", ctx do
      conn = build_conn() |> cross_origin() |> get("/media/#{ctx.media_file.id}/meta")

      assert conn.status == 200
      assert_open_and_uncredentialed(conn)
    end

    test "GET /media/:id/meta — 404 on an unknown id" do
      conn = build_conn() |> cross_origin() |> get("/media/#{Ecto.UUID.generate()}/meta")

      assert conn.status == 404
      assert_open_and_uncredentialed(conn)
    end

    test "GET /media/renditions/:id/:preset — 404 on an unknown id" do
      conn =
        build_conn()
        |> cross_origin()
        |> get("/media/renditions/#{Ecto.UUID.generate()}/thumb")

      assert conn.status == 404
      assert_open_and_uncredentialed(conn)
    end

    test "serves the header even on the strict-bearer 401 (the CORS mount runs FIRST)" do
      conn =
        build_conn()
        |> cross_origin()
        |> put_req_header("authorization", "Bearer definitely-not-a-real-token")
        |> get("/media/files/#{@path}")

      assert conn.status == 401
      assert_open_and_uncredentialed(conn)
    end

    test "HEAD /media/files/*path carries it (Plug.Head routes HEAD onto the GET)" do
      conn = build_conn() |> cross_origin() |> head("/media/files/#{@path}")

      assert conn.status == 200
      assert_open_and_uncredentialed(conn)
    end
  end

  describe "signed URL" do
    test "a signed media fetch still serves AND carries the header", ctx do
      request_path = "/media/files/#{@path}"
      signed = SignedUrl.sign(request_path, ctx.media_file.id)

      # Sanity: the signature really is on the URL (a bare path would make this
      # test pass for the wrong reason).
      assert signed =~ "_="
      assert signed =~ "exp="

      conn = build_conn() |> cross_origin() |> get(signed)

      assert conn.status == 200
      assert conn.resp_body == @bytes
      assert_open_and_uncredentialed(conn)
    end
  end

  describe "media WRITE routes gain NO CORS header" do
    test "POST /media/upload — 401, and no ACAO" do
      conn = build_conn() |> cross_origin() |> post("/media/upload", %{})

      assert conn.status == 401
      assert_no_cors(conn)
    end

    test "DELETE /media/:id — 401, and no ACAO", ctx do
      conn = build_conn() |> cross_origin() |> delete("/media/#{ctx.media_file.id}")

      assert conn.status == 401
      assert_no_cors(conn)
    end
  end

  describe "session invariance — the no-ambient-auth premise the ruling demands" do
    test "the same GET answers identically with and without a logged-in session", ctx do
      # Deliberately an ADMIN of the very workspace these flat routes resolve
      # to: the STRONGEST session we can hand the request. If any branch on
      # this route read ambient auth, this is the session that would change
      # the answer.
      {:ok, user} =
        Accounts.register_user(%{
          email: "media-cors-#{System.unique_integer([:positive])}@example.com",
          password: "correct-horse-battery-staple-1"
        })

      {:ok, _} = Tenancy.Auth.create_membership(ctx.ws.id, user.id, "admin", "user")
      {:ok, session_raw} = Accounts.create_user_session_token(user)

      bare = build_conn() |> cross_origin() |> get("/media/files/#{@path}")

      with_session =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "user_session" => session_raw,
          "api_token" => "a-session-token-this-pipeline-never-reads"
        })
        |> cross_origin()
        |> get("/media/files/#{@path}")

      # Identical status AND identical bytes: nothing on this route consults
      # the session, so the cookie cannot change the answer.
      assert bare.status == with_session.status
      assert bare.status == 200
      assert bare.resp_body == with_session.resp_body

      # And the header is present in BOTH — the grant does not depend on being
      # anonymous either.
      assert_open_and_uncredentialed(bare)
      assert_open_and_uncredentialed(with_session)
    end

    test "the meta read is session-invariant too", ctx do
      bare = build_conn() |> cross_origin() |> get("/media/#{ctx.media_file.id}/meta")

      with_session =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "api_token" => "a-session-token-this-pipeline-never-reads"
        })
        |> cross_origin()
        |> get("/media/#{ctx.media_file.id}/meta")

      assert bare.status == with_session.status
      assert bare.resp_body == with_session.resp_body
      assert_open_and_uncredentialed(bare)
      assert_open_and_uncredentialed(with_session)
    end
  end

  describe "the endpoint-level DatasetCors reflector is untouched" do
    test "an ALLOWLISTED origin still gets the reflected origin, not the wildcard" do
      conn =
        build_conn()
        |> put_req_header("origin", "https://barkpark.cloud")
        |> get("/media/files/#{@path}")

      assert conn.status == 200
      # DatasetCors runs in a before_send callback at the endpoint and
      # `put_resp_header`s the reflected origin over whatever the router set.
      # Recording that here so a future reader does not read `*` as universal.
      assert acao(conn) == ["https://barkpark.cloud"]
      assert acac(conn) == []
      assert get_resp_header(conn, "vary") == ["Origin"]
    end
  end
end
