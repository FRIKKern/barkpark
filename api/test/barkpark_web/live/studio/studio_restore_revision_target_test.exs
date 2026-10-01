defmodule BarkparkWeb.Studio.StudioRestoreRevisionTargetTest do
  @moduledoc """
  LiveView authz sweep (r4a): `restore-revision` restored WHATEVER revision id
  the client sent, not a revision of the document that is open.

  `Handlers.History.restore_revision/2` passed the client's revision id to
  `Content.restore_revision/4`, which writes `drafts.<rev.doc_id>` — the
  revision's OWN document — using the OPEN editor's type. The write checks
  around the event look only at the open document:

    * `LiveScope.attach_write_gate/2` builds its target from `editor_doc`;
    * `Caps` checks the tier, not the target.

  So a grantee holding a write grant on ONE document (plus read reach on the
  project) could open that document and send `restore-revision` with a
  revision id of ANOTHER document, overwriting its draft outside the grant.
  For any member it also wrote a draft under the wrong type when the two
  documents' types differ.

  The fix refuses a revision whose document is not the open document.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("restore-tgt-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "restore-tgt-proj")
    {:ok, _} = Barkpark.Tenancy.get_or_create_dataset(proj, @dataset)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    opts = [workspace_id: ws.id, project_id: proj.id]

    upsert = fn id, title ->
      {:ok, _} =
        Content.upsert_document("post", %{"doc_id" => id, "title" => title}, @dataset, opts)
    end

    upsert.("drafts.granted-post", "GRANTED")
    upsert.("drafts.other-post", "OTHER-OLD")
    upsert.("drafts.other-post", "OTHER-CURRENT")

    other_old_rev =
      "drafts.other-post"
      |> Content.list_revisions("post", @dataset, opts)
      |> Enum.find(&(&1.title == "OTHER-OLD"))

    assert other_old_rev, "fixture: the other document must have an OTHER-OLD revision"

    {:ok, conn: conn, ws: ws, proj: proj, opts: opts, other_old_rev: other_old_rev}
  end

  defp grantee_conn(conn, ws, proj) do
    email = "restore-tgt-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

    bind_grant!(ws, user, %{
      capabilities: ["read", "write"],
      project_id: proj.id,
      dataset: @dataset,
      type: "post",
      doc_id: "granted-post"
    })

    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp other_title(opts) do
    case Content.get_document("drafts.other-post", "post", @dataset, opts) do
      %{title: title} -> title
      {:ok, %{title: title}} -> title
      other -> other
    end
  end

  test "a doc-scoped write grantee cannot restore ANOTHER document's revision", ctx do
    conn = grantee_conn(ctx.conn, ctx.ws, ctx.proj)

    {:ok, view, _} =
      live(conn, "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/#{@dataset}/studio/post/granted-post")

    assert :sys.get_state(view.pid).socket.assigns[:editor_doc],
           "fixture: the granted document must be open in the editor"

    render_click(view, "restore-revision", %{"id" => to_string(ctx.other_old_rev.id)})

    assert other_title(ctx.opts) == "OTHER-CURRENT",
           "restore-revision overwrote a document outside the open editor (and outside the grant): " <>
             inspect(other_title(ctx.opts))
  end

  test "a member restoring a revision of the OPEN document still works (control)", ctx do
    raw = "restore-tgt-member-" <> Ecto.UUID.generate()

    {:ok, tok} =
      Barkpark.Auth.create_token(raw, "restore member", @dataset, ["read", "write"], ctx.ws.id)

    if is_nil(Barkpark.Tenancy.Auth.membership(tok, ctx.ws.id)),
      do: {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ctx.ws.id, tok.id, "member")

    conn = Plug.Test.init_test_session(ctx.conn, %{"api_token" => raw})

    {:ok, view, _} =
      live(conn, "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/#{@dataset}/studio/post/other-post")

    render_click(view, "restore-revision", %{"id" => to_string(ctx.other_old_rev.id)})

    assert other_title(ctx.opts) == "OTHER-OLD"
  end
end
