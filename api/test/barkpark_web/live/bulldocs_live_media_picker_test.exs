defmodule BarkparkWeb.BulldocsLiveMediaPickerTest do
  @moduledoc """
  Public-reader persistence half of the mounted field-image picker contract.

  The client regression drives the real media browser and upload control; this
  test submits those exact serialized values through the authorized public
  Paper wire and proves storage plus a fresh scoped mount preserve them.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    suffix = System.unique_integer([:positive])
    ws = create_workspace!("reader-media-picker-#{suffix}")
    project = create_project!(ws)
    slug = "reader-media-picker-paper-#{suffix}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "title" => "Reader media picker #{suffix}",
        "workspace_id" => ws.id,
        "project_id" => project.id,
        "blocks" => [
          %{
            "id" => "cover",
            "type" => "field-image",
            "fieldName" => "coverImage",
            "label" => "Cover",
            "value" => ""
          },
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body"}]
          }
        ]
      })

    assert {:ok, _paper} = Content.upsert_paper(attrs)

    raw = "reader-media-picker-writer-#{suffix}"

    {:ok, _token} =
      Auth.create_token(raw, "reader media picker writer", @dataset, ["read", "write"], ws.id)

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      raw: raw,
      ws: ws,
      project: project,
      slug: slug
    }
  end

  test "selected and uploaded field-image values persist through the public editor and reload",
       ctx do
    path = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/papers/#{ctx.slug}"
    {:ok, view, _html} = live(ctx.conn, path)

    editing = render_click(view, "paper-toggle-edit", %{})
    assert editing =~ ~s(data-canvas-picker-browse="true")
    assert editing =~ ~s(data-canvas-scope-prefix="/w/#{ctx.ws.slug}/p/#{ctx.project.slug}")

    selected_value =
      Jason.encode!(%{
        "url" => "/media/selected.png",
        "assetId" => "asset-selected",
        "alt" => "Selected cover"
      })

    assert_saved_image(view, selected_value)
    assert stored_image(ctx) == expected_image(selected_value)

    uploaded_value =
      Jason.encode!(%{
        "url" => "/media/uploaded.png",
        "assetId" => "asset-uploaded"
      })

    assert_saved_image(view, uploaded_value)
    assert stored_image(ctx) == expected_image(uploaded_value)

    reloaded_conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})
    {:ok, reloaded, _html} = live(reloaded_conn, path)
    render_click(reloaded, "paper-toggle-edit", %{})

    assert Enum.find(socket_of(reloaded).assigns.edit_blocks, &(&1["id"] == "cover")) ==
             expected_image(uploaded_value)
  end

  defp assert_saved_image(view, value) do
    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "request_id" => request_id,
      "if_rev" => socket_of(view).assigns.paper_rev,
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "cover",
          "patch" => %{"value" => value}
        }
      ]
    })

    assert_reply(view, %{saved: true, request_id: ^request_id})
  end

  defp stored_image(ctx) do
    ctx.slug
    |> Content.get_paper(@dataset, workspace_id: ctx.ws.id, project_id: ctx.project.id)
    |> get_in([Access.key!(:content), "blocks"])
    |> Enum.find(&(&1["id"] == "cover"))
  end

  defp expected_image(value) do
    %{
      "id" => "cover",
      "type" => "field-image",
      "fieldName" => "coverImage",
      "label" => "Cover",
      "value" => value
    }
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
