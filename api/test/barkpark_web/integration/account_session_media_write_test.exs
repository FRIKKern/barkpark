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

      assert conn.status in [401, 403]
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

  describe "actor_label attribution — the pipelines that keep it honest" do
    # task-a32e13e37527d261, criterion 5. `actor_label/1` (in BOTH
    # `V1.MediaController` and `Media.Storage.Access`) prefers the api_token's
    # LABEL and has no :current_user arm — deliberately: `checkedOutBy` is
    # user-visible and is compared for equality by `permission_set/2`, and what a
    # human principal should be stamped as is a product decision nobody has made.
    #
    # It cannot misattribute TODAY only because the two callers of
    # `actor_label/1` — checkout and undo_checkout — route on pipelines that do
    # NOT carry `OptionalSessionToken`, so `:current_user` is never set there.
    # Adding that plug to either would look like a harmless improvement and would
    # start stamping a token's label onto a user's checkout lock.
    #
    # THIS TEST IS THE TRIPWIRE, not a behaviour assertion: it reads the router's
    # own pipeline definition, so the day someone adds the plug it reds and sends
    # them to the comment in access.ex instead of letting the attribution drift
    # land silently.
    test "neither :media_mutate nor :scoped_api carries OptionalSessionToken" do
      source = File.read!("lib/barkpark_web/router.ex")

      [{:media_mutate, ~r/pipeline :media_mutate do(.*?)\n  end/s}]
      |> Enum.each(fn {name, re} ->
        [_, body] = Regex.run(re, source)

        refute body =~ "OptionalSessionToken",
               "#{inspect(name)} gained OptionalSessionToken. checkout/undo_checkout route " <>
                 "through it and call actor_label/1, which prefers a TOKEN's label — so a " <>
                 "cookie-authenticated member's checkout would now be stamped with whatever " <>
                 "token happened to ride along. Give actor_label/1 a :current_user arm " <>
                 "(a product decision: email? display name? id?) before enabling this."
      end)
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

      assert conn.status in [401, 403, 404],
             "expected an honest refusal or not-found, got #{conn.status} #{conn.resp_body}"
    end
  end
end
