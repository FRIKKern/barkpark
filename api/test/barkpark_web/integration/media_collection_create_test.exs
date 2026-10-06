defmodule BarkparkWeb.Integration.MediaCollectionCreateTest do
  @moduledoc """
  task-c09196a99fad3d3a — a member makes a media folder from an account session.

  The Media library's "New folder" posted a create + publish batch to the
  scoped document mutate door. That door's pipeline (`:scoped_mutate`) is
  token-only, so an account (cookie) session — every SSO / password user —
  collected 403. Ruling (a): a media-scoped `POST /v1/media/:ds/collections`
  on the cookie-aware, CSRF-checked, membership-gated `:scoped_media_mutate`.
  `:scoped_mutate` stays token-only.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Media.Storage.Collections

  @ds "production"

  setup %{conn: conn} do
    ws = create_workspace!("mcol-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "mcol-p-#{System.unique_integer([:positive])}")
    ensure_default_scope!()
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp account_session!(conn, ws, role) do
    email = "mcol-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp create(conn, ws, proj, title, opts \\ []) do
    conn =
      if Keyword.get(opts, :csrf, true),
        do: put_req_header(conn, "x-requested-with", "bp-asset-explorer"),
        else: conn

    post(conn, "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/collections", %{"title" => title})
  end

  defp folders(ws, proj) do
    @ds
    |> Collections.list(workspace_id: ws.id, project_id: proj.id)
    |> Enum.map(&{&1.doc_id, &1.title})
  end

  test "an account-session member creates a folder, and the answer is the stored folder", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    resp = conn |> account_session!(ws, "member") |> create(ws, proj, "  Covers  ")

    assert resp.status == 200, "member refused: #{resp.status} #{resp.resp_body}"
    result = Jason.decode!(resp.resp_body)["result"]
    assert result["id"] =~ ~r/^col-[0-9a-f]{16}$/
    assert result["title"] == "Covers"
    assert result["kind"] == "folder"

    # Stored, published and in THIS workspace: the list read sees it.
    assert {result["id"], "Covers"} in folders(ws, proj)
  end

  test "a non-member with a valid account session is refused and nothing is written", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    other = create_workspace!("mcol-other-#{System.unique_integer([:positive])}")
    resp = conn |> account_session!(other, "admin") |> create(ws, proj, "Intruder")

    refute resp.status in [200, 201]
    assert folders(ws, proj) == []
  end

  test "a cookie session without x-requested-with is refused at the CSRF gate", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    resp = conn |> account_session!(ws, "member") |> create(ws, proj, "No header", csrf: false)

    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "csrf_required"
    assert folders(ws, proj) == []
  end

  test "a token client still creates a folder", %{conn: conn, ws: ws, proj: proj} do
    raw = "mcol-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "mcol writer", @ds, ["read", "write"], ws.id)

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> create(ws, proj, "From the API", csrf: false)

    assert resp.status == 200, "token refused: #{resp.status} #{resp.resp_body}"
    id = Jason.decode!(resp.resp_body)["result"]["id"]
    assert {id, "From the API"} in folders(ws, proj)
  end

  test "a blank title is refused before anything is written", %{conn: conn, ws: ws, proj: proj} do
    resp = conn |> account_session!(ws, "member") |> create(ws, proj, "   ")

    assert resp.status == 400
    assert folders(ws, proj) == []
  end
end
