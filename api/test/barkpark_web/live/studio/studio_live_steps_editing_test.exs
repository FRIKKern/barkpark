defmodule BarkparkWeb.Studio.StudioLiveStepsEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    slug = "studio-steps-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Steps",
          blocks: [
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
        })
      )

    %{slug: slug}
  end

  test "Studio edits step metadata and scoped body, replays an add once, and survives remount",
       %{conn: conn, slug: slug} do
    path = scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#steps-form-steps")
    assert has_element?(view, "[data-paper-container-row-id='row']")

    title_request = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "steps",
      "step-count" => "1",
      "step-0-id" => "row",
      "step-0-title" => "After",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => title_request
    })

    assert_reply(view, %{saved: true, request_id: ^title_request})
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
    [parent] = stored_blocks(slug)
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
    after_add = stored_blocks(slug)
    assert Enum.map(hd(after_add)["steps"], & &1["id"]) == ["row", "second-row"]

    render_hook(view, "paper-edit-block", add_params)
    assert_reply(view, %{saved: true, request_id: ^add_request})
    assert stored_blocks(slug) == after_add

    {:ok, reloaded, html} = live(recycle(conn), path)
    assert html =~ "After body"
    assert socket_of(reloaded).assigns.paper_doc.content["blocks"] == after_add
  end

  defp stored_blocks(slug) do
    slug
    |> Content.get_paper(@dataset)
    |> get_in([Access.key!(:content), "blocks"])
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
