defmodule BarkparkWeb.InvitationPageTest do
  @moduledoc """
  task-5306379c9be40c89 — an invited user had no browser way to accept: only
  the JSON `/v1/auth/invitations` existed, and the not-a-member page gave no
  hint. The refusal page now shows the caller's OWN pending invitation to that
  workspace with Accept and Decline, and `/invitations` lists them all.

  The no-enumeration rule holds: a caller with no invitation to the workspace
  gets a byte-identical page for a real workspace and an unknown slug.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Invitation

  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)

    n = System.unique_integer([:positive])
    {:ok, home} = Tenancy.create_workspace(%{slug: "inv-home-#{n}", name: "Home #{n}"})
    {:ok, _} = Tenancy.create_project(home, %{slug: "default", name: "Default"})

    {:ok, target} =
      Tenancy.create_workspace(%{slug: "inv-target-#{n}", name: "Fjord Forlag #{n}"})

    {:ok, project} = Tenancy.create_project(target, %{slug: "default", name: "Default"})
    {:ok, _} = Tenancy.create_dataset(project, %{slug: "production", name: "production"})
    {:ok, other} = Tenancy.create_workspace(%{slug: "inv-other-#{n}", name: "Other #{n}"})
    {:ok, _} = Tenancy.create_project(other, %{slug: "default", name: "Default"})

    {:ok, n: n, home: home, target: target, other: other}
  end

  defp sign_in(conn, email, home) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, _} = TenancyAuth.create_membership(home.id, user.id, "admin", "user")
    conn = post(conn, "/login/account", %{"email" => email, "password" => @password})
    {recycle(conn), user}
  end

  defp invite!(workspace, user, role \\ "member") do
    Repo.insert!(%Invitation{workspace_id: workspace.id, user_id: user.id, role: role})
  end

  defp studio(ws_slug), do: "/w/#{ws_slug}/p/default/d/production/studio"

  test "an invited user opening the workspace sees the invitation and can accept it",
       %{conn: conn, n: n, home: home, target: target} do
    {conn, user} = sign_in(conn, "invited-#{n}@example.com", home)
    invitation = invite!(target, user)

    refused = get(conn, studio(target.slug))
    assert refused.status == 403
    assert refused.resp_body =~ "You&#39;re invited to Fjord Forlag #{n}"
    assert refused.resp_body =~ ~s(action="/invitations/#{invitation.id}/accept")
    assert refused.resp_body =~ ~s(action="/invitations/#{invitation.id}/decline")
    assert refused.resp_body =~ ~s(name="_csrf_token")

    accepted = post(recycle(refused), "/invitations/#{invitation.id}/accept")
    assert redirected_to(accepted) == studio(target.slug)
    assert Repo.get(Invitation, invitation.id) == nil
    assert TenancyAuth.member?(user.id, target.id, :user)

    assert get(recycle(accepted), studio(target.slug)).status == 200
  end

  test "decline removes the invitation and returns to the list",
       %{conn: conn, n: n, home: home, target: target} do
    {conn, user} = sign_in(conn, "declines-#{n}@example.com", home)
    invitation = invite!(target, user)

    declined = post(conn, "/invitations/#{invitation.id}/decline")
    assert redirected_to(declined) == "/invitations"
    assert Repo.get(Invitation, invitation.id) == nil

    assert get(recycle(declined), studio(target.slug)).resp_body =~
             "not a member of this workspace"
  end

  # task-a065eac6d95635f4: the declined row simply vanished; nothing said the
  # decline worked. The page it returns to says so, under the heading and at the
  # start of the title (what a screen reader reads first), once.
  test "decline says so on the page it returns to, and only once",
       %{conn: conn, n: n, home: home, target: target} do
    {conn, user} = sign_in(conn, "declined-says-#{n}@example.com", home)
    invitation = invite!(target, user)

    declined = post(conn, "/invitations/#{invitation.id}/decline")
    back = get(recycle(declined), "/invitations")

    assert back.resp_body =~ "You declined the invitation to Fjord Forlag #{n}."
    assert back.resp_body =~ "<title>Invitation declined · Studio · Invitations</title>"

    again = get(recycle(back), "/invitations")
    refute again.resp_body =~ "You declined"
    assert again.resp_body =~ "<title>Studio · Invitations</title>"
  end

  test "an invited caller's not-a-member page is titled as an invitation; an uninvited one is not",
       %{conn: conn, n: n, home: home, target: target, other: other} do
    {conn, user} = sign_in(conn, "titled-#{n}@example.com", home)
    invite!(target, user)

    assert get(conn, studio(target.slug)).resp_body =~ "<title>Studio · Invitation</title>"
    assert get(conn, studio(other.slug)).resp_body =~ "<title>Studio · Not a member</title>"
  end

  test "with no invitation there, a real workspace and an unknown slug get the identical page",
       %{conn: conn, n: n, home: home, target: target, other: other} do
    {conn, user} = sign_in(conn, "elsewhere-#{n}@example.com", home)
    # An invitation to a DIFFERENT workspace must not change either page.
    invite!(target, user)

    real = get(conn, studio(other.slug))
    unknown = get(recycle(real), studio("inv-nonexistent-#{n}"))

    assert real.status == 403 and unknown.status == 403
    assert real.resp_body == unknown.resp_body
    refute real.resp_body =~ "invited"
    assert real.resp_body =~ ~s(href="/invitations")
  end

  test "/invitations lists every pending invitation with accept and decline",
       %{conn: conn, n: n, home: home, target: target, other: other} do
    {conn, user} = sign_in(conn, "lists-#{n}@example.com", home)
    a = invite!(target, user)
    b = invite!(other, user, "admin")

    page = get(conn, "/invitations")
    assert page.status == 200
    assert page.resp_body =~ "Your invitations"
    assert page.resp_body =~ "Fjord Forlag #{n}"
    assert page.resp_body =~ "Other #{n}"
    for i <- [a, b], do: assert(page.resp_body =~ ~s(action="/invitations/#{i.id}/accept"))
    assert page.resp_body =~ ~s(aria-label="Accept the invitation to Fjord Forlag #{n}")

    empty =
      get(scoped_conn() |> sign_in("none-#{n}@example.com", home) |> elem(0), "/invitations")

    assert empty.resp_body =~ "You have no pending invitations."
  end

  test "someone else's invitation is never accepted through this door",
       %{conn: conn, n: n, home: home, target: target} do
    {:ok, owner} = Accounts.register_user(%{email: "owner-#{n}@example.com", password: @password})
    theirs = invite!(target, owner)
    {conn, _user} = sign_in(conn, "intruder-#{n}@example.com", home)

    resp = post(conn, "/invitations/#{theirs.id}/accept")
    assert resp.status == 422
    assert resp.resp_body =~ "That invitation is no longer open."
    assert Repo.get(Invitation, theirs.id) != nil
  end

  test "an anonymous visitor is sent to sign in first", %{conn: conn} do
    assert redirected_to(get(conn, "/invitations")) == "/login?return_to=%2Finvitations"
  end

  test "the invitation reads in the caller's own Studio language",
       %{conn: conn, n: n, home: home, target: target} do
    {:ok, _} = Tenancy.set_workspace_locale(home, "nb-NO")
    {conn, user} = sign_in(conn, "norsk-#{n}@example.com", home)
    invite!(target, user)

    body = get(conn, studio(target.slug)).resp_body
    assert body =~ ~s(<html lang="nb-NO")
    assert body =~ "Du er invitert til Fjord Forlag #{n}"
    assert body =~ "Godta invitasjonen"

    list = get(conn, "/invitations").resp_body
    assert list =~ "Invitasjonene dine"

    invitation = Repo.get_by!(Invitation, user_id: user.id)
    declined = post(conn, "/invitations/#{invitation.id}/decline")
    back = get(recycle(declined), "/invitations").resp_body
    assert back =~ "Du avslo invitasjonen til Fjord Forlag #{n}."
    assert back =~ "<title>Invitasjonen er avslått · Studio · Invitasjoner</title>"
  end
end
