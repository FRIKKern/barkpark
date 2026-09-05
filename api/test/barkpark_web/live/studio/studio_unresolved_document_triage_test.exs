defmodule BarkparkWeb.Studio.StudioUnresolvedDocumentTriageTest do
  @moduledoc """
  Gyldendal field report #35c: the editor's "could not open this document"
  card said, for EVERY miss, "it may have been deleted, or it may live in
  another workspace or project". Stated regardless of truth, that hint sent the
  customer's debugging the wrong way for two weeks (the real cause was an
  unscoped schema lookup, friction log #49).

  The card now names the cause it can prove with a scoped read:

    * ABSENT       — no such row here, and in no other workspace the principal
                     is a member of. No hint.
    * ELSEWHERE    — the id exists in another workspace the SAME principal can
                     reach: the card names it and links to the document there.
    * OUT OF REACH — the row exists in this scope but the caller's grant does
                     not cover it (grant-narrowed read; the un-narrowed re-read
                     finds it).

  And the leak test: a document that exists only in a workspace the principal
  is NOT a member of renders ABSENT — no name, no link.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccessFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @schema %{
    "name" => "publication",
    "title" => "Utgivelse",
    "icon" => "book",
    "visibility" => "public",
    "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
  }

  defp workspace!(slug_prefix) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "#{slug_prefix}-#{suffix}",
        name: "WS #{slug_prefix} #{suffix}"
      })

    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    scope = [workspace_id: ws.id, project_id: proj.id]
    {:ok, _} = Content.upsert_schema(@schema, @dataset, scope)
    {ws, proj, scope}
  end

  defp token!(memberships) do
    default_ws = Tenancy.get_default_workspace()
    raw = "gfr35c-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "gfr35c", @dataset, ["read", "write"], default_ws.id)
    for ws <- memberships, do: {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")
    raw
  end

  defp desk_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp squash(html), do: String.replace(html, ~r/\s+/, " ")

  setup %{conn: conn} do
    {ws_a, proj_a, scope_a} = workspace!("gfr35c-a")
    {ws_b, proj_b, scope_b} = workspace!("gfr35c-b")
    {ws_c, _proj_c, scope_c} = workspace!("gfr35c-c")

    # The SAME id in B (member) and C (not a member); nothing in A.
    {:ok, _} =
      Content.create_document(
        "publication",
        %{"doc_id" => "pub-shared", "title" => "Lives In B", "status" => "published"},
        @dataset,
        scope_b
      )

    {:ok, _} =
      Content.create_document(
        "publication",
        %{"doc_id" => "pub-only-c", "title" => "Lives In C", "status" => "published"},
        @dataset,
        scope_c
      )

    raw = token!([ws_a, ws_b])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     ws_a: ws_a,
     proj_a: proj_a,
     scope_a: scope_a,
     ws_b: ws_b,
     proj_b: proj_b,
     ws_c: ws_c}
  end

  test "ABSENT — an id that exists nowhere the principal can reach: no workspace hint", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, _view, html} = live(conn, desk_url(ws_a, proj_a) <> "/publication/pub-nope")

    assert html =~ ~s(data-reason="not_found")
    assert html =~ ~s(data-cause="absent")
    assert squash(html) =~ "It may have been deleted."
    refute html =~ "another workspace"
    refute html =~ "studio-unresolved-open-elsewhere"
  end

  test "ELSEWHERE — the id lives in another workspace the principal is a member of: named and linked",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b} do
    {:ok, _view, html} = live(conn, desk_url(ws_a, proj_a) <> "/publication/pub-shared")

    assert html =~ ~s(data-cause="elsewhere")
    assert html =~ ws_b.name
    assert html =~ ~s(data-test-id="studio-unresolved-open-elsewhere")
    assert html =~ desk_url(ws_b, proj_b) <> "/publication/pub-shared"
    refute html =~ "It may have been deleted"
  end

  test "NO LEAK — the id exists only in a workspace the principal is NOT a member of: ABSENT, no name",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, ws_c: ws_c} do
    {:ok, _view, html} = live(conn, desk_url(ws_a, proj_a) <> "/publication/pub-only-c")

    assert html =~ ~s(data-cause="absent")
    refute html =~ ws_c.name
    refute html =~ ws_c.slug
    refute html =~ "another workspace"
  end

  test "OUT OF REACH — the row exists here but the caller's grant does not cover it: says so, names the grant",
       %{ws_a: ws_a, proj_a: proj_a, scope_a: scope_a} do
    {:ok, _} =
      Content.create_document(
        "publication",
        %{"doc_id" => "pub-in-a", "title" => "In A", "status" => "published"},
        @dataset,
        scope_a
      )

    # A grantee whose grant covers ONLY type "post" in A — not "publication".
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    # A FRESH conn: the setup conn carries the member token's session, and a
    # token principal outranks a user session, so the member would simply open
    # the document and the arm under test would never be reached.
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{"user_session" => raw})

    bind_grant!(ws_a, user, %{
      project_id: proj_a.id,
      dataset: @dataset,
      type: "post",
      capabilities: ["read"]
    })

    {:ok, _view, html} = live(conn, desk_url(ws_a, proj_a) <> "/publication/pub-in-a")
    assert html =~ ~s(data-cause="out_of_reach")

    assert squash(html) =~ "access grant does not cover it"

    assert html =~ "type post"
    refute html =~ "It may have been deleted"
    refute html =~ "another workspace"
  end
end
