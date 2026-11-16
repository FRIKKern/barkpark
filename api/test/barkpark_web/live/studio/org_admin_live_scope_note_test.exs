defmodule BarkparkWeb.Studio.OrgAdminLiveScopeNoteTest do
  # task-89a0f72db9b90297: since #26648 a viewer who is not a listed operator
  # sees only the organizations they administer in full. The page must say so
  # in one plain line, never claim "No organizations yet." when organizations
  # exist but are hidden, and never name or count the hidden ones.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Tenancy}

  @note "Organization settings are shown only for organizations you administer in full."
  @note_nb "Organisasjonsinnstillinger vises bare for organisasjoner du administrerer fullt ut."
  @none "No organizations yet."

  setup do
    prev =
      {Application.get_env(:barkpark, :operator_emails),
       Application.get_env(:barkpark, :operator_token_ids)}

    on_exit(fn ->
      {emails, ids} = prev
      restore(:operator_emails, emails)
      restore(:operator_token_ids, ids)
    end)

    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    n = System.unique_integer([:positive])
    {org_a, ws_a} = org_with_ws("onote-a-#{n}")
    {org_b, _ws_b} = org_with_ws("onote-b-#{n}")

    raw = "org-note-#{n}"

    {:ok, token} =
      Auth.create_token(raw, "admin of A", "production", ~w(read write admin), ws_a.id)

    %{raw: raw, token: token, org_a: org_a, org_b: org_b, n: n}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {org, ws}
  end

  defp open(conn, raw),
    do: live(init_test_session(conn, %{"api_token" => raw}), "/studio/org-admin")

  test "a scoped admin is told plainly which organizations they see, and nothing about the rest",
       %{conn: conn, raw: raw, org_a: org_a, org_b: org_b} do
    {:ok, _view, html} = open(conn, raw)

    assert html =~ @note
    assert html =~ ~s(data-org="#{org_a.slug}")
    refute html =~ org_b.slug
    refute html =~ @none
  end

  test "an admin who administers no organization sees the line, not \"No organizations yet.\"",
       %{conn: conn, n: n} do
    raw = "org-note-flat-#{n}"
    {:ok, _} = Auth.create_token(raw, "seatless admin", "production", ~w(read write admin), nil)

    {:ok, _view, html} = open(conn, raw)

    assert html =~ @note
    refute html =~ @none
    refute html =~ "data-org="
  end

  # The org-admin page is flat (no workspace), so it puts no Studio locale and
  # renders English like the rest of its chrome; the catalog carries nb-NO for
  # when it does.
  test "the line has a Norwegian translation" do
    on_exit(fn -> Gettext.put_locale(BarkparkWeb.Gettext, "en") end)
    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")

    assert Gettext.gettext(BarkparkWeb.Gettext, @note) == @note_nb
  end

  test "a listed operator sees every organization and no scope line",
       %{conn: conn, raw: raw, token: token, org_b: org_b} do
    Application.put_env(:barkpark, :operator_token_ids, [token.id])

    {:ok, _view, html} = open(conn, raw)

    refute html =~ @note
    assert html =~ ~s(data-org="#{org_b.slug}")
  end
end
