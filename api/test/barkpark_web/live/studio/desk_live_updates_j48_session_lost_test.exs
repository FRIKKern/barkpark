defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ48SessionLostTest do
  @moduledoc """
  J48 (barkpark-studio JOURNEYS.md, reference `e2e/journeys/session.spec.ts`):
  the session is lost mid-edit. Writes stop (nothing is saved after the
  session is gone), the page says "You've been logged out", and signing in
  again comes back to the same desk.

  A browser signs in one of two ways, and sign-out ("POST /logout",
  `SessionController.delete/2`) ends each differently:

    * a token sign-in keeps `session["api_token_session"]`; sign-out DELETES
      that `Barkpark.Auth.TokenSession` row (`Auth.revoke_token_session/1`)
      and broadcasts nothing;
    * an account sign-in keeps `session["user_session"]`; sign-out revokes the
      row (`Accounts.revoke_user_session_token/1`), which broadcasts
      "disconnect" on the session's topic, and `LiveAuth`'s teardown hook
      redirects the open page to /login.

  This file does each sign-out the way the controller does it, then types.
  Auth is not this lane's to change: a red here states what is missing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures, only: [register_user: 1]
  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @type_name "desk_session_note"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk session notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dsess-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => "Session note", "content" => %{"summary" => "Before"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, url: "#{base}/#{@type_name};#{id}", id: id}
  end

  defp settle(view), do: render_async(view, 5_000)

  defp title_in_db(id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(@type_name, id, @dataset)
    doc && doc.title
  end

  defp type(view, title),
    do: view |> form("#editor-form") |> render_change(%{"doc" => %{"title" => title}})

  # A token sign-in as `SessionController.create/2` makes it: the session holds
  # only the opaque TokenSession id.
  defp token_sign_in(conn) do
    raw = "desk-session-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()

    {:ok, api_token} =
      Auth.create_token(raw, "desk-session", @dataset, ~w(read write admin), ws.id)

    {:ok, session_id} = Auth.create_token_session(raw, api_token)
    {Plug.Test.init_test_session(conn, %{"api_token_session" => session_id}), session_id}
  end

  # An account sign-in: a workspace admin's user session.
  defp account_sign_in(conn) do
    user = register_user("desk-session-#{System.unique_integer([:positive])}@example.com")
    ws = Tenancy.get_default_workspace()
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {Plug.Test.init_test_session(conn, %{"user_session" => raw}), raw}
  end

  describe "a token sign-in, signed out in another tab" do
    test "a keystroke after the sign-out writes nothing", %{conn: conn, url: url, id: id} do
      {conn, session_id} = token_sign_in(conn)
      {:ok, view, _html} = live(conn, url)
      settle(view)

      # Control: while signed in, typing saves.
      type(view, "Typed while signed in")
      assert title_in_db(id) == "Typed while signed in"

      # The other tab's sign-out, as the controller does it.
      assert {:ok, 1} = Auth.revoke_token_session(session_id)
      assert Auth.resolve_session_credential(session_id, nil) == :error

      _ = type(view, "Typed after sign-out")

      assert title_in_db(id) == "Typed while signed in",
             "a keystroke after the session was signed out was saved, as the signed-out token"
    end

    test "the page says the session is gone", %{conn: conn, url: url} do
      {conn, session_id} = token_sign_in(conn)
      {:ok, view, _html} = live(conn, url)
      settle(view)

      assert {:ok, 1} = Auth.revoke_token_session(session_id)

      # Either is "says so": a banner on the page, or the page sent to sign in.
      said? =
        case type(view, "Typed after sign-out") do
          {:error, {kind, _}} when kind in [:redirect, :live_redirect] -> true
          _html -> render(view) =~ ~r/logged out|signed out/i
        end

      assert said?,
             "the desk kept editing after its session was signed out and says nothing about it"
    end
  end

  describe "an account sign-in, signed out in another tab" do
    test "the open desk is sent to sign in, and nothing is written after", %{
      conn: conn,
      url: url,
      id: id
    } do
      {conn, raw} = account_sign_in(conn)
      {:ok, view, _html} = live(conn, url)
      settle(view)

      type(view, "Typed while signed in")
      assert title_in_db(id) == "Typed while signed in"

      assert {:ok, 1} = Accounts.revoke_user_session_token(raw)
      assert_redirect(view, "/login", 2_000)

      # The page is gone, so nothing more can be typed into it.
      refute Process.alive?(view.pid)
      assert title_in_db(id) == "Typed while signed in"
    end

    test "signing in again comes back to the same desk URL", %{conn: conn, url: url} do
      {conn, raw} = account_sign_in(conn)
      {:ok, view, _html} = live(conn, url)
      settle(view)

      assert {:ok, 1} = Accounts.revoke_user_session_token(raw)
      {to, _flash} = assert_redirect(view, 2_000)

      assert to =~ "return_to=" <> URI.encode_www_form(url),
             "the sign-out sent the desk to #{to}, which does not bring the editor back to #{url}"
    end
  end
end
