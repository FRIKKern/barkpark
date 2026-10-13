defmodule BarkparkWeb.Studio.DisconnectGrantTargetTest do
  @moduledoc """
  r4a Q8 (task-651462bb70d1be7f): confirm-delete / confirm-unpublish with
  `disconnect=true` strip the reference out of EVERY document that points at the
  target. The LiveScope write gate checks only the event's target (the open
  document), so a grantee whose WRITE grant names one document — and whose READ
  grant shows the whole project — used to rewrite referencing documents it may
  not write.

  Now a grant-graded socket's disconnect refuses as a whole when any referencing
  document is outside its write grants: nothing is stripped, the target is not
  deleted or unpublished, and the flash says why. A grantee whose write grant
  covers the referencers still disconnects.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}

  @dataset "production"
  @type_name "post"

  setup %{conn: conn} do
    ws = create_workspace!("q8dis-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "q8dis-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "related",
              "title" => "Related",
              "type" => "reference",
              "to" => [%{"type" => @type_name}]
            }
          ]
        },
        @dataset,
        scope
      )

    publish!("q8-target", "Target", %{}, scope)
    publish!("q8-ref", "Referrer", %{"related" => "q8-target"}, scope)

    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp publish!(id, title, content, scope) do
    {:ok, draft} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.publish_document(Content.published_id(draft.doc_id), @type_name, @dataset, scope)
  end

  defp grantee_conn(conn, ws, proj, write_overrides) do
    email = "q8dis-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)

    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

    bind_grant!(
      ws,
      user,
      Map.merge(
        %{capabilities: ["read", "write"], project_id: proj.id, dataset: @dataset},
        write_overrides
      )
    )

    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp open!(conn, ws, proj, id) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{@type_name}/#{id}")

    view
  end

  defp stored(id, scope) do
    case Content.get_document(id, @type_name, @dataset, scope) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  test "a doc-scoped write grant cannot disconnect a referencer outside it: nothing written, nothing deleted",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    conn = grantee_conn(conn, ws, proj, %{type: @type_name, doc_id: "q8-target"})
    view = open!(conn, ws, proj, "q8-target")

    html = render_click(view, "delete-doc", %{})
    assert html =~ "Referrer", "read reach: the modal must list the referencer"

    html = render_click(view, "confirm-delete", %{"disconnect" => "true"})

    assert stored("q8-ref", scope).content["related"] == "q8-target",
           "the referencer is outside the write grant; its reference must stay"

    assert stored("q8-target", scope),
           "the refused disconnect must not go on to delete the target"

    assert html =~ "outside your access grant"
  end

  test "the same refusal on confirm-unpublish", %{conn: conn, ws: ws, proj: proj, scope: scope} do
    conn = grantee_conn(conn, ws, proj, %{type: @type_name, doc_id: "q8-target"})
    view = open!(conn, ws, proj, "q8-target")

    # Sent directly: the event needs only the open document, and a client can
    # send it without the guard modal (whose edge-based preview may be empty
    # before the projector runs).
    html = render_click(view, "confirm-unpublish", %{"disconnect" => "true"})

    assert stored("q8-ref", scope).content["related"] == "q8-target"
    assert stored("q8-target", scope), "the published target must still be there"
    assert html =~ "outside your access grant"
  end

  test "a type-wide write grant still disconnects and deletes (the legitimate path)",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    conn = grantee_conn(conn, ws, proj, %{type: @type_name})
    view = open!(conn, ws, proj, "q8-target")

    _ = render_click(view, "delete-doc", %{})
    _ = render_click(view, "confirm-delete", %{"disconnect" => "true"})

    refute Map.has_key?(stored("q8-ref", scope).content, "related")
    refute stored("q8-target", scope)
  end
end
