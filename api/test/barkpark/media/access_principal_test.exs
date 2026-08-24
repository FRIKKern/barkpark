defmodule Barkpark.Media.Storage.AccessPrincipalTest do
  @moduledoc """
  task-a32e13e37527d261 — `Barkpark.Media.Storage.Access` carried a THIRD
  principal model, token-only, while the media write gate admits three kinds.

  These are the DB-backed principal tests. The pure-logic suite stays in
  `access_test.exs` (async, no sandbox); membership is a real row, so it lives
  here.

  ## What moved, and what deliberately did NOT

  `authenticated?/1` was `match?(%{assigns: %{api_token: %_{}}}, conn)`. An
  account-session workspace member — no bearer anywhere — was therefore
  UNAUTHENTICATED to this module, so `permission_set/2` withheld
  `edit_metadata`, and `delivery_ok?/3` refused them a `private` asset. Measured
  end-to-end at 403 on a metadata PATCH (see
  `account_session_media_write_test.exs`).

  ## THE ARM THIS SUITE EXISTS TO PIN

  The obvious widening — "a `%User{}` is present" — is WRONG and would have
  opened a real leak. `OptionalSessionToken` sets `:current_user` BEFORE
  `RequireShareScope`/`ResolveWorkspace` on `:shared_media_api`, and
  `ResolveWorkspace` returns the conn untouched when `share_public` is true
  (plus two further non-member admit arms: the Default-workspace public
  allowance and the grant path). A signed-in NON-MEMBER therefore reaches this
  module holding a `%User{}`, and bare presence would have handed them `view` +
  `use_original` on a `private` asset through a public share link.

  So the arm asks the WORKSPACE question — `Tenancy.Auth.authorize(user, ws_id,
  :read)` — and the non-member test below is the one that fails if anyone ever
  relaxes it back to presence.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.Access
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy

  setup do
    ws = create_workspace!("acc-princ-#{System.unique_integer([:positive])}")
    {:ok, ws: ws}
  end

  defp user!(ws, role) do
    email = "acc-princ-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    if role do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    end

    user
  end

  # The conn shape a cookie-authenticated request carries at this module: a
  # :current_user, a :current_workspace resolved from the URL, and NO :api_token.
  defp account_conn(user, ws) do
    %Plug.Conn{
      request_path: "/media/files/sample.png",
      query_params: %{},
      assigns: %{current_user: user, current_workspace: ws}
    }
  end

  defp token_conn(permissions) do
    %Plug.Conn{
      request_path: "/media/files/sample.png",
      query_params: %{},
      assigns: %{api_token: %ApiToken{label: "t", permissions: permissions}}
    }
  end

  defp file, do: %MediaFile{id: Ecto.UUID.generate()}
  defp private_doc, do: %Document{content: %{"bp_visibility" => "private"}}
  defp public_doc, do: %Document{content: %{}}

  describe "the account arm — a workspace MEMBER is a recognised principal" do
    test "a member may view a private asset", %{ws: ws} do
      conn = account_conn(user!(ws, "member"), ws)

      assert Access.allowed?(conn, file(), private_doc(), :view),
             "a workspace member was refused a private asset they can administer"
    end

    test "a member may edit metadata", %{ws: ws} do
      conn = account_conn(user!(ws, "member"), ws)

      assert Access.allowed?(conn, file(), public_doc(), :edit_metadata)
    end

    test "an owner is recognised too", %{ws: ws} do
      conn = account_conn(user!(ws, "owner"), ws)

      assert Access.allowed?(conn, file(), private_doc(), :view)
    end
  end

  describe "THE LEAK NOT INTRODUCED — a signed-in NON-member stays refused" do
    # If `authenticated?/1` is ever relaxed to "a %User{} is present", every
    # test in this describe reds. That is the point of it.
    test "a non-member gets NO permissions on a private asset", %{ws: ws} do
      other = create_workspace!("acc-princ-other-#{System.unique_integer([:positive])}")
      conn = account_conn(user!(other, "admin"), ws)

      assert Access.permissions(conn, file(), private_doc()) == [],
             "a signed-in non-member — the public-share-link shape — was granted " <>
               "access to another workspace's private asset"

      refute Access.allowed?(conn, file(), private_doc(), :view)
      refute Access.allowed?(conn, file(), private_doc(), :original)
    end

    test "a user with NO membership anywhere is refused", %{ws: ws} do
      conn = account_conn(user!(nil, nil), ws)

      refute Access.allowed?(conn, file(), private_doc(), :view)
    end

    test "a member with NO resolved workspace on the conn is refused", %{ws: ws} do
      user = user!(ws, "admin")
      conn = %Plug.Conn{request_path: "/x", query_params: %{}, assigns: %{current_user: user}}

      refute Access.allowed?(conn, file(), private_doc(), :view),
             "the predicate answered without a workspace to answer ABOUT"
    end

    test "a non-member is still refused edit_metadata", %{ws: ws} do
      other = create_workspace!("acc-princ-other2-#{System.unique_integer([:positive])}")
      conn = account_conn(user!(other, "owner"), ws)

      refute Access.allowed?(conn, file(), public_doc(), :edit_metadata)
    end
  end

  describe "admin?/1 no longer raises on a token-less principal (the tripwire)" do
    # `Auth.has_permission?/2` is `permission in (token.permissions || [])`, so a
    # nil token RAISED BadMapError. It was unreachable only while `auth` meant
    # token presence; the account arm makes it live. A doc checked out by ANOTHER
    # actor is what forces `permission_set/2` to consult `admin?/1`.
    @checked_out %Document{content: %{"checkedOutBy" => "someone-else"}}

    test "a token-less MEMBER is answered, not raised — and is denied the lock override",
         %{ws: ws} do
      conn = account_conn(user!(ws, "member"), ws)

      refute Access.allowed?(conn, file(), @checked_out, :edit_metadata),
             "a plain member overrode another actor's checkout lock"

      # `use_original` is stripped alongside edit_metadata for a non-admin who
      # does not hold the lock.
      refute Access.allowed?(conn, file(), @checked_out, :original)
    end

    test "a token-less workspace ADMIN overrides the lock", %{ws: ws} do
      conn = account_conn(user!(ws, "admin"), ws)

      assert Access.allowed?(conn, file(), @checked_out, :edit_metadata),
             "a workspace admin could not override another actor's checkout lock"
    end

    test "a token-less NON-member is answered false, never raised", %{ws: ws} do
      other = create_workspace!("acc-princ-other3-#{System.unique_integer([:positive])}")
      conn = account_conn(user!(other, "owner"), ws)

      refute Access.allowed?(conn, file(), @checked_out, :edit_metadata)
    end
  end

  describe "the token arm is unchanged (control)" do
    test "a read-only token still counts as authenticated", %{ws: _ws} do
      conn = token_conn(["read"])

      assert Access.allowed?(conn, file(), private_doc(), :view)
      # Parity note: ANY token satisfies this module; write authority is
      # enforced upstream by require_write/1, never here.
      assert Access.allowed?(conn, file(), public_doc(), :edit_metadata)
    end

    test "an anonymous conn is still refused a private asset" do
      conn = %Plug.Conn{request_path: "/x", query_params: %{}, assigns: %{}}

      refute Access.allowed?(conn, file(), private_doc(), :view)
    end
  end
end
