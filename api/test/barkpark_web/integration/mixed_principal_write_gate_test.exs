defmodule BarkparkWeb.Integration.MixedPrincipalWriteGateTest do
  @moduledoc """
  task-90f53226cec546d5: a request carrying BOTH a signed-in user and a bearer
  token is admitted to a scoped workspace by `ResolveWorkspace` on EITHER
  principal, but `RequireWritePermission` granted the write on the token's
  global `write` bit alone, without asking whether that token belongs to THIS
  workspace. A read-only member plus a write token minted in any other
  workspace therefore wrote here (upload, delete, share). When the token is not
  itself allowed into the workspace, the user's role now decides.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Media, Repo, Tenancy}
  alias Barkpark.Tenancy.{Role, RolePermission}

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @ds "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    ws = create_workspace!("mixed-b-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "mixed-p-#{System.unique_integer([:positive])}")
    other = create_workspace!("mixed-a-#{System.unique_integer([:positive])}")

    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: "viewer", workspace_id: ws.id}))

    {:ok, _} =
      Repo.insert(
        RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
      )

    # A write token the caller legitimately holds in ANOTHER workspace.
    raw = "mixed-foreign-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "foreign write", @ds, ["read", "write"], other.id)

    {:ok, conn: conn, ws: ws, proj: proj, foreign: raw}
  end

  defp session_as!(conn, ws, role) do
    email = "mixed-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp upload(conn, ws, proj, bearer) do
    path = Path.join(System.tmp_dir!(), "mixed-#{System.unique_integer([:positive])}.png")
    File.write!(path, Base.decode64!(@png_b64))
    on_exit(fn -> File.rm(path) end)

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> bearer)
      |> put_req_header("x-requested-with", "bp-media-picker")
      |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/upload", %{
        "file" => %Plug.Upload{path: path, filename: "a.png", content_type: "image/png"}
      })

    with {:ok, body} <- Jason.decode(resp.resp_body),
         p when is_binary(p) <-
           get_in(body, ["result", "fileInfo", "path"]) || get_in(body, ["fileInfo", "path"]) do
      File.rm(Path.join(Media.upload_dir(), p))
    end

    resp
  end

  test "a read-only member plus a foreign write token cannot write", ctx do
    conn = session_as!(ctx.conn, ctx.ws, "viewer")
    resp = upload(conn, ctx.ws, ctx.proj, ctx.foreign)

    assert resp.status == 403,
           "a viewer wrote through a token from another workspace: #{resp.status} #{resp.resp_body}"
  end

  test "CONTROL: a write-capable member with the same foreign token still writes", ctx do
    conn = session_as!(ctx.conn, ctx.ws, "member")
    resp = upload(conn, ctx.ws, ctx.proj, ctx.foreign)
    assert resp.status in 200..299, "#{resp.status} #{resp.resp_body}"
  end
end
