defmodule BarkparkWeb.BulldocsLiveStepsEditingTest do
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  alias Barkpark.{Auth, Content}

  test "row title and scoped body save through the mounted reader and survive reload", %{
    conn: conn
  } do
    suffix = System.unique_integer([:positive])
    ws = create_workspace!("reader-steps-#{suffix}")
    project = create_project!(ws)
    slug = "reader-steps-#{suffix}"

    blocks = [
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [
          %{
            "id" => "row",
            "title" => "Before",
            "unknown" => "keep",
            "children" => [
              %{
                "id" => "body",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Before body"}]
              }
            ]
          }
        ]
      }
    ]

    assert {:ok, _} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 "slug" => slug,
                 "title" => "Steps",
                 "workspace_id" => ws.id,
                 "project_id" => project.id,
                 "blocks" => blocks
               })
             )

    raw = "steps-writer-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "Steps writer", "production", ["read", "write"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    path = "/w/#{ws.slug}/p/#{project.slug}/papers/#{slug}"
    {:ok, view, _} = live(conn, path)
    render_click(view, "paper-toggle-edit", %{})
    assert has_element?(view, "#steps-form-steps")
    assert has_element?(view, "[data-paper-container-row-id='row']")
    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "steps",
      "step-count" => "1",
      "step-0-id" => "row",
      "step-0-title" => "After",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => request_id
    })

    assert_reply(view, %{saved: true, request_id: ^request_id})
    body_request = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "body",
          "patch" => %{
            "content" => [%{"type" => "text", "value" => "After body"}]
          }
        }
      ],
      "container_kind" => "steps",
      "container_id" => "steps",
      "container_row_id" => "row",
      "container_run_ids" => ["body"],
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => body_request
    })

    assert_reply(view, %{saved: true, request_id: ^body_request})
    saved = Content.get_paper(slug, "production", workspace_id: ws.id, project_id: project.id)
    [parent] = saved.content["blocks"]
    [row] = parent["steps"]
    assert row["title"] == "After"
    assert row["unknown"] == "keep"
    assert hd(row["children"])["content"] == [%{"type" => "text", "value" => "After body"}]

    add_request = Ecto.UUID.generate()

    add_params = %{
      "block_id" => "steps",
      "step-count" => "1",
      "step-0-id" => "row",
      "step-0-title" => "After",
      "step-action" => "add",
      "step-new-row-id" => "second-row",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => add_request
    }

    render_hook(view, "paper-edit-block", add_params)
    assert_reply(view, %{saved: true, request_id: ^add_request})
    after_add = Content.get_paper(slug, "production", workspace_id: ws.id, project_id: project.id)
    assert length(hd(after_add.content["blocks"])["steps"]) == 2
    render_hook(view, "paper-edit-block", add_params)
    assert_reply(view, %{saved: true, request_id: ^add_request})

    after_retry =
      Content.get_paper(slug, "production", workspace_id: ws.id, project_id: project.id)

    assert after_retry.content == after_add.content

    {:ok, reloaded, html} = live(conn, path)
    assert html =~ "After body"
    render_click(reloaded, "paper-toggle-edit", %{})
    render_hook(reloaded, "paper-edit-block", add_params)
    assert_reply(reloaded, %{saved: true, request_id: ^add_request, replayed: true})

    render_hook(
      reloaded,
      "paper-edit-block",
      Map.put(add_params, "step-0-title", "Changed retry")
    )

    assert_reply(reloaded, %{saved: false, request_id: ^add_request})
    final = Content.get_paper(slug, "production", workspace_id: ws.id, project_id: project.id)
    assert final.content == after_add.content
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
