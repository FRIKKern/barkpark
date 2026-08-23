defmodule BarkparkWeb.Integration.MediaWriteGateSingleJudgmentTest do
  @moduledoc """
  `task-6e22b3922dc42e8c` — the media write judgment has ONE owner:
  `BarkparkWeb.Plugs.RequireWritePermission`.

  Both `V1.MediaController.require_write/1` and its
  `V1.MediaCollectionsController` twin used to re-derive that judgment from
  `conn.assigns[:api_token]`. Two implementations of one decision drifted, and
  the drift was VISIBLE TO A CALLER:

    * **The gate said yes and the controller said no.** `call/2` falls THROUGH a
      failing token arm into `account_write?/1`; the controller arms RETURNED
      from theirs. A request carrying a read-only `:api_token` alongside a
      `:current_user` who is a write-capable member of the resolved workspace was
      GRANTED by the gate and then answered 403 by the controller.
    * **Two status codes for one condition.** The gate answers 403 for every
      refusal; the controllers answered 401 from their token-absent arm.

  The controller arms were NOT deleted — they now read `granted?/1`. That keeps
  the defense-in-depth and INVERTS the failure mode: a route that ever loses the
  plug carries no grant assign, so the write is refused rather than silently
  admitted. The last describe block is the test for exactly that.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Media, Tenancy}
  alias BarkparkWeb.Plugs.RequireWritePermission

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @ds "production"

  setup %{conn: conn} do
    ws = create_workspace!("wgate-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "wgate-p-#{System.unique_integer([:positive])}")
    ensure_default_scope!()
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp account_session!(conn, ws, role) do
    email = "wgate-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # A token whose permissions[] satisfies :read and NOT :write. It is a member of
  # `ws` so `ResolveWorkspace` (which authorizes on :read) admits it — otherwise
  # the request would be refused upstream and never reach the judgment under test.
  defp read_only_token!(ws) do
    raw = "wgate-ro-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "wgate read-only", @ds, ["read"])
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")
    raw
  end

  defp png_upload do
    path = Path.join(System.tmp_dir!(), "wgate-#{System.unique_integer([:positive])}.png")
    File.write!(path, Base.decode64!(@png_b64))
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "a.png", content_type: "image/png"}
  end

  defp scoped_upload(conn, ws, proj) do
    conn
    |> put_req_header("x-requested-with", "bp-media-picker")
    |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/upload", %{"file" => png_upload()})
  end

  defp cleanup(body) do
    case get_in(body, ["result", "path"]) || get_in(body, ["result", "fileInfo", "path"]) do
      p when is_binary(p) -> File.rm(Path.join(Media.upload_dir(), p))
      _ -> :ok
    end
  end

  describe "a principal the gate ADMITS is not overturned by the controller" do
    # THE DIVERGENCE, end to end. `OptionalSessionToken` assigns :api_token and
    # :current_user INDEPENDENTLY, so both can be on one conn. The gate's token
    # arm fails (read-only), falls through to `account_write?/1`, and the member
    # is granted. The old controller arm saw a non-nil :api_token, asked the
    # token question a second time, and returned 403 — the gate's yes, overturned
    # one frame later. This asserts 2xx.
    test "a write-capable member is admitted even while carrying a READ-ONLY bearer token",
         %{conn: conn, ws: ws, proj: proj} do
      {_u, conn} = account_session!(conn, ws, "member")
      raw = read_only_token!(ws)

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> scoped_upload(ws, proj)

      assert resp.status in [200, 201],
             "the write gate GRANTED this request (account arm) and the controller " <>
               "refused it anyway: #{resp.status} #{resp.resp_body}"

      cleanup(Jason.decode!(resp.resp_body))
    end
  end

  describe "the collapse did not widen the gate" do
    test "a read-only token with NO account session is still refused", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = read_only_token!(ws)

      resp =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("authorization", "Bearer #{raw}")
        |> scoped_upload(ws, proj)

      refute resp.status in [200, 201],
             "a read-only principal completed a media write: #{resp.resp_body}"

      assert resp.status == 403
    end

    test "an account session that is NOT a member of the target workspace is refused", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      other = create_workspace!("wgate-other-#{System.unique_integer([:positive])}")
      {_u, conn} = account_session!(conn, other, "admin")

      resp = scoped_upload(conn, ws, proj)

      refute resp.status in [200, 201]
    end
  end

  describe "the controller arm still FAILS CLOSED without the plug" do
    # The reason `require_write/1` was collapsed onto `granted?/1` instead of
    # DELETED. If a future pipeline edit drops RequireWritePermission from a
    # media write route, there is no grant assign — and the surviving controller
    # arm must refuse, not wave the write through on a token's own say-so.
    #
    # Asserted at the predicate, because a conn WITHOUT the plug cannot be built
    # through the router by construction: that is the whole point.
    test "granted?/1 is false on a conn the plug never ran on, whatever it carries" do
      raw = "wgate-admin-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "wgate admin", @ds, ["read", "write", "admin"])

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:api_token, token)
        |> Plug.Conn.assign(:share_writer, true)

      refute RequireWritePermission.granted?(conn),
             "an ungated conn read as write-permitted — the collapse fails OPEN"
    end

    test "granted?/1 is true only after the plug itself grants", %{ws: ws} do
      raw = "wgate-w-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "wgate writer", @ds, ["read", "write"])
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:api_token, token)
        |> RequireWritePermission.call([])

      refute conn.halted
      assert RequireWritePermission.granted?(conn)
    end

    # P5: the share-edit token holds no global :write perm and must keep passing,
    # or a share-token upload 403s despite the grant RequireShareEditToken made.
    test "a share_writer conn is granted by the plug, so the controller arm honours it" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:share_writer, true)
        |> RequireWritePermission.call([])

      refute conn.halted
      assert RequireWritePermission.granted?(conn)
    end
  end
end
