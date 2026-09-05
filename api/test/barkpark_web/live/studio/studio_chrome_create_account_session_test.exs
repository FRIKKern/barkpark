defmodule BarkparkWeb.Studio.StudioChromeCreateAccountSessionTest do
  @moduledoc """
  Gyldendal field report #34 follow-up
  (`gfr-w1-followup-account-session-chrome-create`): the chrome's create
  affordances refused an ACCOUNT session.

  `StudioChrome.chrome_fallback/3` gated both on
  `match?(%Barkpark.Auth.ApiToken{}, socket.assigns[:api_token])`, which is nil
  for a `user_session` principal (`OptionalSessionToken` assigns
  `:current_user`). So `create-workspace` fell through to "Sign in to create a
  workspace" and `create-project` to "Sign in to create a project" — for a
  person who IS signed in. #34 gave that person their workspace LIST back; this
  gives them the create button's server half.

  ## The fixture kind is the whole test

  Every principal in the account describes is a `user_session` %User{}, never a
  token; `studio_chrome_test.exs` already pins the token arm and passed
  throughout, which is exactly why this shipped. The anonymous describe is the
  no-widening arm: "Sign in to create" must stay an ASSERT there while it is a
  REFUTE above.

  MediaLive is the surface because `chrome_fallback/3` only runs on NON-
  StudioLive views (StudioLive keeps its own richer handlers — which carry the
  SAME defect in `handlers/scope.ex`, out of this slice's fence).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("chrome-acct-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "chrome-acct-p"})

    {default_ws, default_proj} = ensure_default_scope!()

    %{conn: conn, ws: ws, proj: proj, default_ws: default_ws, default_proj: default_proj}
  end

  defp media_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media"

  # An ACCOUNT principal — a real %User{} with `principal_type: "user"`
  # memberships and a `user_session` in the session, the same shape
  # `studio_account_session_scope_test.exs` uses.
  defp user_session!(conn, memberships) do
    email = "chrome-acct-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  describe "an ACCOUNT session creates from the scope menu" do
    test "create-workspace mints the workspace and a \"user\" owner membership for the account",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = user_session!(conn, [{ws, "member"}])

      {:ok, view, _html} = live(conn, media_url(ws, proj))

      name = "acct-made-#{System.unique_integer([:positive])}"
      result = render_submit(view, "create-workspace", %{"name" => name})

      # A successful create push_navigates into the new scope, so the result is
      # a `{:error, {:live_redirect, ...}}` tuple rather than HTML. Inspect it
      # so the REFUTE below reads the whole answer either way — a flash-only
      # (non-redirecting) regression would still be caught.
      redirected? = match?({:error, {:live_redirect, _}}, result)

      assert redirected?,
             "an account session must be navigated into the workspace it just created, got: #{inspect(result)}"

      # The lie is gone: this principal is signed in.
      refute inspect(result) =~ "Sign in to create"

      created = Tenancy.get_workspace_by_slug(name)

      assert created,
             "an account session must actually create the workspace (pre-fix: silent no-op + a false flash)"

      owner = Tenancy.Auth.membership(user, created.id)

      assert owner, "the creator must hold a user-kind membership in the workspace they made"
      assert owner.principal_type == "user"
      assert owner.role == "owner"
    end

    test "create-project creates under the mounted workspace for an account member", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = user_session!(conn, [{ws, "member"}])

      {:ok, view, _html} = live(conn, media_url(ws, proj))

      name = "acct-proj-#{System.unique_integer([:positive])}"
      result = render_submit(view, "create-project", %{"name" => name})

      redirected? = match?({:error, {:live_redirect, _}}, result)

      assert redirected?,
             "an account member must be navigated into the project they just created, got: #{inspect(result)}"

      refute inspect(result) =~ "Sign in to create"

      created = Enum.find(Tenancy.list_projects(ws.id), &(&1.name == name))

      assert created, "an account member must actually create the project"

      assert Enum.any?(Tenancy.list_datasets(created.id), &(&1.slug == @dataset)),
             "create-project must seed the production dataset, same as the token arm"
    end
  end

  # Anonymous can only mount the seeded Default scope (a scoped workspace 403s
  # a non-member at mount), which is exactly the public-demo surface this slice
  # must not widen.
  describe "an ANONYMOUS session still refuses, in the same words as before" do
    test "create-workspace answers \"Sign in to create a workspace\"", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      {:ok, view, _html} = live(conn, media_url(default_ws, default_proj))

      name = "anon-must-not-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-workspace", %{"name" => name})

      assert html =~ "Sign in to create a workspace"
      refute Tenancy.get_workspace_by_slug(name)
    end

    test "create-project answers \"Sign in to create a project\"", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      {:ok, view, _html} = live(conn, media_url(default_ws, default_proj))

      name = "anon-proj-must-not-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-project", %{"name" => name})

      assert html =~ "Sign in to create a project"
      refute Enum.any?(Tenancy.list_projects(default_ws.id), &(&1.name == name))
    end
  end
end
