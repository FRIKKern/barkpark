defmodule BarkparkWeb.Studio.StudioDuplicateDocGrantTargetTest do
  @moduledoc """
  LiveView authz sweep (r4a): `duplicate-doc` let a DOC-scoped write grantee
  create documents.

  `LiveScope.attach_write_gate/2` resolves each mutating event's target scope.
  `new-document` targets the TYPE (no doc id), so a grant naming one document
  cannot create. `duplicate-doc` fell through to the default arm, which targets
  the OPEN document — the granted one — so the gate admitted it, and
  `Content.clone_document/4` minted a brand-new document id in the desk.

  The fix gives `duplicate-doc` the same type-level target as `new-document`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("dup-tgt-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "dup-tgt-proj")
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

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "drafts.granted-post", "title" => "GRANTED"},
        @dataset,
        opts
      )

    {:ok, conn: conn, ws: ws, proj: proj, opts: opts}
  end

  defp post_count(opts) do
    "post" |> Content.list_documents(@dataset, opts ++ [perspective: :raw]) |> length()
  end

  defp open_granted(conn, ctx) do
    {:ok, view, _} =
      live(conn, "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/#{@dataset}/studio/post/granted-post")

    assert :sys.get_state(view.pid).socket.assigns[:editor_doc],
           "fixture: the granted document must be open in the editor"

    view
  end

  test "a DOC-scoped write grantee cannot duplicate (= create) a document", ctx do
    email = "dup-tgt-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    bind_grant!(ctx.ws, user, %{capabilities: ["read"], project_id: ctx.proj.id})

    bind_grant!(ctx.ws, user, %{
      capabilities: ["read", "write"],
      project_id: ctx.proj.id,
      dataset: @dataset,
      type: "post",
      doc_id: "granted-post"
    })

    {:ok, raw} = Accounts.create_user_session_token(user)
    view = open_granted(Plug.Test.init_test_session(ctx.conn, %{"user_session" => raw}), ctx)

    before = post_count(ctx.opts)
    render_click(view, "duplicate-doc", %{})

    assert post_count(ctx.opts) == before,
           "a doc-scoped write grant created a new document through duplicate-doc"
  end

  test "a TYPE-scoped write grantee may still duplicate (control)", ctx do
    email = "dup-tgt-type-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    bind_grant!(ctx.ws, user, %{
      capabilities: ["read", "write"],
      project_id: ctx.proj.id,
      dataset: @dataset,
      type: "post"
    })

    {:ok, raw} = Accounts.create_user_session_token(user)
    view = open_granted(Plug.Test.init_test_session(ctx.conn, %{"user_session" => raw}), ctx)

    before = post_count(ctx.opts)
    render_click(view, "duplicate-doc", %{})

    assert post_count(ctx.opts) == before + 1
  end
end
