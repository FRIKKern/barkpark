defmodule BarkparkWeb.InvitationEmailTest do
  @moduledoc """
  task-a3c4164ea2f56ccd: inviting an existing confirmed account emails the
  invitee, naming the workspace and the inviter, with a link to /invitations.

  Pinned here: the mail goes to the invitee only, carries no token (accepting
  needs the invitee's own sign-in), is in the workspace's language (en, nb),
  and a repeat invite of a pending invitee sends nothing more.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("inv-mail-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    raw = "inv-mail-admin-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "inv-mail-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")

    {:ok, invitee} =
      Accounts.register_user(%{
        email: "invitee-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    invitee = Accounts.confirm_provisioned_user(invitee)

    %{ws: ws, project: project, admin_raw: raw, admin_token: raw, invitee: invitee}
  end

  defp invite(ctx, email) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{ctx.admin_raw}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/members",
      Jason.encode!(%{email: email, role: "member"})
    )
  end

  # Every mail the test process receives within the window.
  defp mails(acc \\ []) do
    receive do
      {:email, email} -> mails([email | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  test "the invitee gets one English mail naming the workspace, linking /invitations, no token",
       ctx do
    assert invite(ctx, ctx.invitee.email).status == 202

    assert_receive {:email, mail}, 1_000
    assert [{_, to}] = mail.to
    assert to == ctx.invitee.email
    assert mail.cc == [] and mail.bcc == []
    assert mail.subject =~ ctx.ws.name
    assert mail.text_body =~ ctx.ws.name
    assert mail.text_body =~ BarkparkWeb.Endpoint.url() <> "/invitations"
    # A token-invited mail does not name the token.
    assert mail.text_body =~ "A workspace admin"
    refute mail.text_body =~ ctx.admin_token

    # No token of any kind rides the link: the URL is exactly /invitations.
    [link] = Regex.run(~r{https?://\S+}, mail.text_body)
    assert URI.parse(link).path == "/invitations"
    assert URI.parse(link).query == nil

    assert mails() == []
  end

  test "a repeat invite of a pending invitee sends nothing more", ctx do
    assert invite(ctx, ctx.invitee.email).status == 202
    assert_receive {:email, _}, 1_000

    assert invite(ctx, ctx.invitee.email).status == 409
    assert mails() == []
  end

  test "a Norwegian workspace sends the Norwegian copy", ctx do
    {:ok, _} = Tenancy.set_workspace_locale(ctx.ws, "nb-NO")
    assert invite(ctx, ctx.invitee.email).status == 202

    assert_receive {:email, mail}, 1_000
    assert mail.subject =~ "Du er invitert til"
    assert mail.text_body =~ "Se invitasjonen"
    assert mail.text_body =~ "/invitations"
  end

  test "a new email is seated directly and gets no invitation mail", ctx do
    new_email = "fresh-#{System.unique_integer([:positive])}@example.com"
    assert invite(ctx, new_email).status == 201
    assert mails() == []
  end

  test "a personal token's owner is named in the mail", ctx do
    {:ok, admin} =
      Accounts.register_user(%{
        email: "inviter-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    admin = Accounts.confirm_provisioned_user(admin)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, admin.id, "admin", "user")

    pat = "inv-mail-pat-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(pat, "pat", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, token.id, "admin", "api_token")
    token |> Ecto.Changeset.change(owner_user_id: admin.id) |> Barkpark.Repo.update!()

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{pat}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/members",
        Jason.encode!(%{email: ctx.invitee.email, role: "member"})
      )

    assert resp.status == 202
    assert_receive {:email, mail}, 1_000
    assert mail.text_body =~ admin.email
  end
end
