defmodule BarkparkWeb.Integration.AccountSessionMediaWriteTest do
  @moduledoc """
  `gfr-w1-account-session-bearer-gap` — an ACCOUNT (`user_session`) member can
  complete a scoped media WRITE without ever holding a bearer token.

  ## What was broken, and what it was NOT

  No account/SSO login writes `session["api_token"]`, so
  `RequireBearerOrSessionToken` — which read only Authorization and that session
  key — refused a legitimate workspace member. **Nobody gained access from the
  gap; a member was BLOCKED by it.** `ResolveWorkspace` already admitted them.

  ## Why the gate arm ALONE was not enough

  `RequireWritePermission` matches `%{api_token: token} <- conn.assigns` and
  fails CLOSED, so an account principal cleared the gate and then collected a
  403 anyway. Both arms are required, and each is mutation-proven below.

  ## SCOPED ONLY, and structurally so

  On `:scoped_media_mutate`, `ResolveWorkspace` runs BEFORE the gate, so the
  URL-derived workspace is on the conn. On the FLAT `:media_mutate` nothing has
  resolved one yet — `DeriveWorkspaceFromToken` and `AssignDefaultScope` run
  after — so the account arm declines. Accepting it there would let the write be
  stamped to and metered against the singleton Default workspace: the
  stamps-to-Default defect D15/D16 paid off. The last test pins that refusal.

  ## No credential is created or rendered

  `data-token=""` for an account session stays the correct end state. The
  components take the cookie branch instead, which is why the CSRF header test
  below is load-bearing rather than decorative.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Media, Tenancy}

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @ds "production"

  setup %{conn: conn} do
    ws = create_workspace!("acct-media-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "acct-media-p-#{System.unique_integer([:positive])}")
    ensure_default_scope!()
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp account_session!(conn, ws, role) do
    email = "acct-media-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp png_upload do
    path = Path.join(System.tmp_dir!(), "acct-#{System.unique_integer([:positive])}.png")
    File.write!(path, Base.decode64!(@png_b64))
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "a.png", content_type: "image/png"}
  end

  defp scoped_upload(conn, ws, proj, opts \\ []) do
    conn =
      if Keyword.get(opts, :csrf, true),
        do: put_req_header(conn, "x-requested-with", "bp-media-picker"),
        else: conn

    post(conn, "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/upload", %{
      "file" => png_upload()
    })
  end

  defp cleanup(body) do
    case get_in(body, ["result", "fileInfo", "path"]) || get_in(body, ["fileInfo", "path"]) do
      p when is_binary(p) -> File.rm(Path.join(Media.upload_dir(), p))
      _ -> :ok
    end
  end

  describe "an account-session member, holding NO bearer" do
    test "completes a scoped media upload", %{conn: conn, ws: ws, proj: proj} do
      {_u, conn} = account_session!(conn, ws, "member")
      conn = scoped_upload(conn, ws, proj)

      assert conn.status in [200, 201],
             "an account member was refused a scoped upload: #{conn.status} #{conn.resp_body}"

      cleanup(Jason.decode!(conn.resp_body))
    end

    test "is REFUSED without the x-requested-with header — the cookie branch is CSRF-gated",
         %{conn: conn, ws: ws, proj: proj} do
      {_u, conn} = account_session!(conn, ws, "member")
      conn = scoped_upload(conn, ws, proj, csrf: false)

      refute conn.status in [200, 201],
             "a cookie-authenticated write succeeded with no CSRF header"

      # WHICH GATE — AND IT IS NOT THE ONE THE TEST NAME IMPLIES. The refusal
      # observed here is the CSRF gate: 403 with code "csrf_required", not the
      # membership or permission gate. The old assertion accepted unauthorized or
      # forbidden alike, and hid that: it was green on a CSRF rejection that never
      # reached the authorisation check the test is about. Pinning the code is
      # what makes the gap visible; widening it again would re-hide it.
      assert conn.status == 403
      err = Jason.decode!(conn.resp_body)["error"]
      assert err["code"] == "csrf_required"
    end

    test "a NON-member with a valid account session is still refused", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      other = create_workspace!("acct-media-other-#{System.unique_integer([:positive])}")
      {_u, conn} = account_session!(conn, other, "admin")
      conn = scoped_upload(conn, ws, proj)

      refute conn.status in [200, 201]
    end
  end

  describe "the flat pipeline still refuses an account session — deliberately" do
    test "flat /media/upload does not admit a cookie-only principal — even a Default member",
         %{conn: conn, ws: ws} do
      # THE DEFAULT MEMBERSHIP IS THE WHOLE TEST, and without it this case is
      # VACUOUS. On the flat pipeline `AssignDefaultScope` stamps
      # :current_workspace to the singleton Default; a user who is NOT a member
      # of Default is then refused by the membership check anyway — so the test
      # passed with the scoped-only guard REMOVED, certifying nothing. Measured
      # exactly that before this line was added.
      #
      # Make the principal a Default member and the guard becomes the ONLY thing
      # standing between a flat cookie write and a document stamped to the
      # singleton Default workspace (D15/D16).
      {default_ws, _default_proj} = ensure_default_scope!()
      {user, conn} = account_session!(conn, ws, "admin")
      {:ok, _} = Tenancy.Auth.create_membership(default_ws.id, user.id, "admin", "user")

      conn =
        conn
        |> put_req_header("x-requested-with", "bp-media-picker")
        |> post("/media/upload", %{"file" => png_upload(), "dataset" => @ds})

      IO.inspect({conn.status, String.slice(conn.resp_body, 0, 150)}, label: "FLAT")

      refute conn.status in [200, 201],
             "a flat account-session write was ADMITTED and would be stamped to the " <>
               "singleton Default workspace — the D15/D16 defect"
    end
  end

  describe "PREMISE EXPERIMENT (task-a32e13e37527d261) — the write gate says yes, ensure_edit says no" do
    # Plugins-off: the media plugin (its mediaAsset document and schema back the /v1/media doors)
    @tag :requires_plugins
    test "an account-session member PATCHes an asset's metadata", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_u, conn} = account_session!(conn, ws, "member")

      upload = scoped_upload(conn, ws, proj)
      assert upload.status in [200, 201], "fixture upload failed: #{upload.resp_body}"
      body = Jason.decode!(upload.resp_body)
      file_id = body["result"]["id"]
      assert is_binary(file_id), "no file id in #{upload.resp_body}"

      patched =
        scoped_conn()
        |> Plug.Test.init_test_session(%{})
        |> then(fn c -> elem(account_session!(c, ws, "member"), 1) end)
        |> put_req_header("x-requested-with", "bp-media-picker")
        |> patch("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{file_id}", %{
          "title" => "renamed by an account member"
        })

      IO.inspect({patched.status, String.slice(patched.resp_body, 0, 200)},
        label: "ACCOUNT-SESSION PATCH"
      )

      cleanup(body)

      assert patched.status == 200,
             "the write gate admitted this member and ensure_edit refused: " <>
               "#{patched.status} #{patched.resp_body}"
    end
  end

  describe "the checkout lock names an account by id (task-36a302b2e981d5e1)" do
    # Ruling (lead, run7 2026-10-06): a human principal is stamped by stable id,
    # never email. ONE `Media.Storage.Actor` is used by the checkout routes and
    # by the metadata-edit gate. This describe used to be a tripwire claiming
    # an account session never reaches checkout. It does: the scoped routes
    # carry it, and the old controller copy stamped the EMAIL while the gate's
    # copy had no account arm, so an editor was locked out of metadata on an
    # asset they had checked out themselves.

    defp checkout_post(conn, ws, proj, file_id, verb) do
      conn
      |> put_req_header("x-requested-with", "bp-media-picker")
      |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{file_id}/#{verb}")
    end

    defp asset_doc(file_id) do
      {:ok, file} = Media.get_file(file_id, [])
      Media.asset_doc_for_file(file, @ds, Media.Storage.MediaFile.scope_opts(file))
    end

    defp as_member(user, ws), do: %{assigns: %{current_user: user, current_workspace: ws}}

    defp uploaded!(conn, ws, proj) do
      upload = scoped_upload(conn, ws, proj)
      assert upload.status in [200, 201], "fixture upload failed: #{upload.resp_body}"
      Jason.decode!(upload.resp_body)["result"]["id"]
    end

    test "checkout stamps user:<id>, the holder may edit metadata, another member may not",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = account_session!(conn, ws, "member")
      file_id = uploaded!(conn, ws, proj)

      resp = checkout_post(conn, ws, proj, file_id, "checkout")
      assert resp.status == 200, resp.resp_body
      body = Jason.decode!(resp.resp_body)["result"]
      assert body["checkoutLabel"] == "you"
      refute resp.resp_body =~ user.email

      doc = asset_doc(file_id)
      assert doc.content["checkedOutBy"] == "user:" <> user.id

      refute Barkpark.Media.Storage.Access.metadata_write_denied?(
               as_member(user, ws),
               "mediaAsset",
               doc
             ),
             "the holder is locked out of their own checkout"

      {other, other_conn} = account_session!(scoped_conn(), ws, "member")

      assert Barkpark.Media.Storage.Access.metadata_write_denied?(
               as_member(other, ws),
               "mediaAsset",
               doc
             )

      seen = other_conn |> get("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{file_id}")
      assert Jason.decode!(seen.resp_body)["result"]["checkoutLabel"] == "another editor"
      refute seen.resp_body =~ user.email
    end

    test "a legacy email-stamped checkout still belongs to that account and releases",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = account_session!(conn, ws, "member")
      file_id = uploaded!(conn, ws, proj)

      # A row written before the ruling: the controller stamped the email.
      doc = asset_doc(file_id)

      {:ok, _} =
        Barkpark.Content.upsert_document(
          "mediaAsset",
          %{
            "doc_id" => doc.doc_id,
            "title" => doc.title,
            "content" => Map.put(doc.content, "checkedOutBy", user.email)
          },
          @ds,
          [source: :api] ++
            Media.Storage.MediaFile.scope_opts(elem(Media.get_file(file_id, []), 1))
        )

      legacy = asset_doc(file_id)
      assert legacy.content["checkedOutBy"] == user.email

      refute Barkpark.Media.Storage.Access.metadata_write_denied?(
               as_member(user, ws),
               "mediaAsset",
               legacy
             )

      label = conn |> get("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{file_id}")
      assert Jason.decode!(label.resp_body)["result"]["checkoutLabel"] == "you"

      released = checkout_post(conn, ws, proj, file_id, "undo-checkout")
      assert released.status == 200, released.resp_body
      assert asset_doc(file_id).content["checkedOutBy"] in [nil, ""]
    end
  end

  describe "the token-less principals reach admin?/1 without raising" do
    # REGRESSION. `require_write/1` gained an ACCOUNT ARM, so a principal with no
    # `:api_token` now reaches `undo_checkout`'s `admin?(conn)`. That helper called
    # `Auth.has_permission?(token, ...)`, which is `permission in (token.permissions
    # || [])` — a nil token RAISES BadMapError rather than answering false, turning
    # an authorization question into a 500. Shipped briefly on main in #12932 and
    # closed here.
    #
    # The raise is OLDER than the account arm: `share_writer` also short-circuits
    # `require_write/1` with no token, so this path could already 500 for a
    # share-token holder before any account session existed.
    test "an account-session member hitting undo_checkout is answered, never 500ed",
         %{conn: conn, ws: ws, proj: proj} do
      {_u, conn} = account_session!(conn, ws, "member")

      # A REAL file id, not a random UUID. With a random id `Media.get_file/2`
      # fails and the `with` short-circuits BEFORE `actor_label/1` and
      # `admin?/1` are reached — the test would pass without exercising the
      # raise at all. Upload first, then act on that id.
      upload = scoped_upload(conn, ws, proj)
      assert upload.status in [200, 201], "fixture upload failed: #{upload.resp_body}"
      file_id = Jason.decode!(upload.resp_body)["result"]["id"]
      assert is_binary(file_id), "no file id in #{upload.resp_body}"

      conn =
        scoped_conn()
        |> Plug.Test.init_test_session(%{})
        |> then(fn c -> elem(account_session!(c, ws, "member"), 1) end)
        |> put_req_header("x-requested-with", "bp-media-picker")
        |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{file_id}/undo-checkout")

      refute conn.status == 500,
             "a token-less principal raised instead of being answered: #{conn.status} #{conn.resp_body}"

      # WHICH ANSWER. This used to pin a 404 `not_found`, but that 404 was not a
      # gate. It was the bug task-b9bca4e256a79387 fixed: `Checkout` read the
      # asset doc WITHOUT the blob's scope, resolved the dataset inside the
      # Default project, and so could never find an asset living in this
      # (non-Default) workspace. The caller is a MEMBER of the workspace, not a
      # cross-tenant visitor, so there is nothing to hide from them. With the read
      # scoped, the member reaches `admin?/1` (the raise this test exists for),
      # is answered `false`, and the holder-only release of an asset nobody
      # holds succeeds: 200, with this file's id in the body.
      assert conn.status == 200,
             "expected the member's undo-checkout to be answered, got #{conn.status} #{conn.resp_body}"

      assert Jason.decode!(conn.resp_body)["result"]["id"] == file_id
    end
  end
end
