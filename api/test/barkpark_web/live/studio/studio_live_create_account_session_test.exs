defmodule BarkparkWeb.Studio.StudioLiveCreateAccountSessionTest do
  @moduledoc """
  The StudioLive half of the #16012 fix (task-9e08889c692fb231).

  #16012 taught `StudioChrome.chrome_fallback/3` to create for an ACCOUNT
  session, but `chrome_fallback/3` only runs on NON-StudioLive views. The MAIN
  Studio surface keeps its own richer handlers in
  `live/studio/studio_live/handlers/scope.ex`, and those still carried the
  identical `%Barkpark.Auth.ApiToken{}` gate: `create_workspace/2` and
  `create_project/2` flashed "Sign in to create a …" at a person who IS signed
  in. The layout's `can_create={assigns[:api_token] != nil}` hid the buttons
  and forms that reach them, so the affordance was dead end-to-end.

  ## The fixture kind is the whole test

  Every principal in the account describes is a `user_session` %User{}, never a
  token. `studio_live_workspace_switcher_test.exs` already pins the TOKEN arm
  and passed throughout — which is exactly why this shipped. The anonymous
  describe is the no-widening arm: "Sign in to create" must stay an ASSERT
  there while it is a REFUTE above.

  ## Mutation proof (run on the patched tree, 2026-09-04)

    * revert `handlers/scope.ex` alone (both gates back to `:api_token`) → the
      TWO account create arms red on `refute html =~ "Sign in to create"`;
      both anonymous arms, the signed-in-non-member arm (the caps gate owns
      that one) and both render arms stay green.
    * revert the layout's `can_create` line alone → exactly one red, "the New
      workspace button is PRESENT for an account session"; every other arm
      green.

  Both outputs are pasted in the PR body.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy

  @dataset "production"

  # The switcher's create affordance, by its STABLE markup marker — the
  # `phx-value-target` on the toggle button, never a bare class-name substring
  # (the Studio page inlines a `<style>` block whose `.scope-menu-create` rules
  # would satisfy a class-only grep on every render).
  @new_workspace_button ~s{phx-value-target="workspace"}

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()

    ws = create_workspace!("sl-acct-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "sl-acct-p-#{System.unique_integer([:positive])}")

    %{conn: conn, ws: ws, proj: proj, default_ws: default_ws, default_proj: default_proj}
  end

  defp studio_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  # An ACCOUNT principal — a real %User{} with `principal_type: "user"`
  # memberships and a `user_session` in the session, the same shape
  # `studio_account_session_scope_test.exs` uses.
  defp user_session!(conn, memberships) do
    email = "sl-acct-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  describe "StudioLive's OWN handlers, with an ACCOUNT session" do
    test "create-workspace mints the workspace and a \"user\" owner membership, and rescopes into it",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = user_session!(conn, [{ws, "member"}])

      {:ok, view, _html} = live(conn, studio_url(ws, proj))

      name = "sl-acct-made-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-workspace", %{"name" => name})

      # The lie is gone: this principal is signed in.
      refute html =~ "Sign in to create"

      created = Tenancy.get_workspace_by_slug(name)

      assert created,
             "an account session must actually create the workspace (pre-fix: no write + a false flash)"

      owner = Tenancy.Auth.membership(user, created.id)

      assert owner, "the creator must hold a user-kind membership in the workspace they made"
      assert owner.principal_type == "user"
      assert owner.role == "owner"

      # StudioLive navigates by re-assigning its own scope (not a redirect).
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.id == created.id
      assert assigns.create_open == nil
    end

    test "create-project creates under the mounted workspace for an account member", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = user_session!(conn, [{ws, "member"}])

      {:ok, view, _html} = live(conn, studio_url(ws, proj))

      name = "sl-acct-proj-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-project", %{"name" => name})

      refute html =~ "Sign in to create"

      created = Enum.find(Tenancy.list_projects(ws.id), &(&1.name == name))

      assert created, "an account member must actually create the project"

      assert Enum.any?(Tenancy.list_datasets(created.id), &(&1.slug == @dataset)),
             "create-project must seed the production dataset, same as the token arm"
    end

    test "a signed-in NON-member is refused HONESTLY — never told to sign in", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      # A registered account with NO memberships anywhere. It can still MOUNT
      # the seeded Default scope (a scoped, non-default workspace 403s a
      # non-member at mount), so this is the only reachable shape of "signed
      # in, but not a member of the workspace I am looking at".
      {_user, conn} = user_session!(conn, [])

      {:ok, view, _html} = live(conn, studio_url(default_ws, default_proj))

      name = "sl-nonmember-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-project", %{"name" => name})

      refute html =~ "Sign in to create",
             "this person IS signed in — the refusal must not claim otherwise"

      # WHERE the refusal comes from is the point. `Caps.gate/3` classifies
      # `create-project` as `:write` and HALTS a principal-carrying socket
      # without write before `Handlers.Scope` ever runs — which is why this
      # module deliberately carries no membership arm of its own (it would be
      # unreachable). The socket flash is the gate's, and it is honest.
      flash = :sys.get_state(view.pid).socket.assigns.flash

      refused? = flash["error"] == "You don't have access to do that."

      assert refused?,
             "a signed-in non-member must be refused by the caps gate, got: #{inspect(flash)}"

      refute Enum.any?(Tenancy.list_projects(default_ws.id), &(&1.name == name))
    end
  end

  # The no-widening arm: a genuinely anonymous session still gets the OLD
  # sentences, verbatim.
  describe "an ANONYMOUS session still refuses, in the same words as before" do
    test "create-workspace answers \"Sign in to create a workspace\"", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      {:ok, view, _html} = live(conn, studio_url(default_ws, default_proj))

      name = "sl-anon-must-not-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-workspace", %{"name" => name})

      assert html =~ "Sign in to create a workspace"
      refute Tenancy.get_workspace_by_slug(name)
    end

    test "create-project answers \"Sign in to create a project\"", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      {:ok, view, _html} = live(conn, studio_url(default_ws, default_proj))

      name = "sl-anon-proj-must-not-#{System.unique_integer([:positive])}"
      html = render_submit(view, "create-project", %{"name" => name})

      assert html =~ "Sign in to create a project"
      refute Enum.any?(Tenancy.list_projects(default_ws.id), &(&1.name == name))
    end
  end

  # The layout half. `can_create` decided the BUTTON, so the server fix above
  # is unreachable by a real click until this renders.
  describe "the switcher's create affordance is RENDERED for a principal" do
    test "the New workspace button is PRESENT for an account session", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = user_session!(conn, [{ws, "member"}])

      {:ok, view, _html} = live(conn, studio_url(ws, proj))

      open = render_click(view, "scope-menu-toggle", %{})

      present? = open =~ @new_workspace_button

      assert present?,
             "an account session must see the ＋ New workspace toggle in the open scope menu " <>
               "(pre-fix: can_create read :api_token, nil for every account session)"
    end

    test "the New workspace button is ABSENT for an anonymous session", %{
      conn: conn,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      {:ok, view, _html} = live(conn, studio_url(default_ws, default_proj))

      open = render_click(view, "scope-menu-toggle", %{})

      present? = open =~ @new_workspace_button

      refute present?,
             "an anonymous session has no principal to own a new workspace — the toggle must stay hidden"
    end
  end
end
