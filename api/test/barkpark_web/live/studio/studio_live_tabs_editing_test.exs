defmodule BarkparkWeb.Studio.StudioLiveTabsEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Repo}

  @dataset "production"

  setup do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    slug = "studio-tabs-#{System.unique_integer([:positive])}"

    legacy_blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "parent-unknown" => true,
        "tabs" => [
          %{
            "label" => "Legacy",
            "row-unknown" => %{"keep" => true},
            "blocks" => [
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Before"}],
                "child-unknown" => [1, 2]
              }
            ],
            "children" => [%{"id" => "opaque", "metadata" => "keep"}],
            "content" => %{"opaque" => true}
          }
        ]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Tabs",
          blocks: legacy_blocks
        })
      )

    legacy_content = Map.put(paper.content, "blocks", legacy_blocks)
    paper |> Ecto.Changeset.change(content: legacy_content) |> Repo.update!()

    %{slug: slug, legacy_content: legacy_content}
  end

  test "Studio tabs canvas persists projected identities only for the exact row-scoped write", %{
    conn: conn,
    slug: slug,
    legacy_content: legacy_content
  } do
    path = scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")
    {:ok, view, _html} = live(conn, path)

    projected = Content.ensure_block_ids(legacy_content["blocks"])
    [parent] = projected
    [row] = parent["tabs"]
    [body] = row["blocks"]

    assert is_binary(row["id"]) and row["id"] != ""
    assert is_binary(body["id"]) and body["id"] != ""

    assert has_element?(
             view,
             "[data-paper-container-kind='tabs'][data-paper-container-id='tabs']" <>
               "[data-paper-container-row-id='#{row["id"]}']"
           )

    assert stored_paper(slug).content == legacy_content

    request_id = Ecto.UUID.generate()

    params = %{
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => body["id"],
          "patch" => %{"content" => [%{"type" => "text", "value" => "After"}]}
        }
      ],
      "container_kind" => "tabs",
      "container_id" => "tabs",
      "container_row_id" => row["id"],
      "container_run_ids" => [body["id"]],
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => request_id
    }

    render_hook(view, "paper-ops", params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^request_id,
      rev: committed_rev
    })

    saved = stored_paper(slug)
    [saved_parent] = saved.content["blocks"]
    [saved_row] = saved_parent["tabs"]
    [saved_body] = saved_row["blocks"]
    assert saved_row["id"] == row["id"]
    assert saved_body["id"] == body["id"]
    assert saved_body["content"] == [%{"type" => "text", "value" => "After"}]
    assert saved_body["child-unknown"] == [1, 2]
    assert saved_row["row-unknown"] == %{"keep" => true}
    assert saved_row["children"] == [%{"id" => "opaque", "metadata" => "keep"}]
    assert saved_row["content"] == %{"opaque" => true}
    assert saved_parent["parent-unknown"] == true

    render_hook(view, "paper-ops", params)

    assert_reply(view, %{
      saved: true,
      replayed: true,
      request_id: ^request_id,
      rev: ^committed_rev
    })

    assert stored_paper(slug).content == saved.content

    changed_retry =
      put_in(
        params,
        ["ops", Access.at(0), "patch", "content"],
        [%{"type" => "text", "value" => "Changed retry"}]
      )

    render_hook(view, "paper-ops", changed_retry)
    assert_reply(view, %{saved: false, request_id: ^request_id})
    assert stored_paper(slug).content == saved.content

    wrong_row_request = Ecto.UUID.generate()

    wrong_row =
      params
      |> Map.put("request_id", wrong_row_request)
      |> Map.put("if_rev", socket_of(view).assigns.paper_rev)
      |> Map.put("container_row_id", "wrong-row")

    render_hook(view, "paper-ops", wrong_row)
    assert_reply(view, %{saved: false, request_id: ^wrong_row_request})
    assert stored_paper(slug).content == saved.content
  end

  defp stored_paper(slug), do: Content.get_paper(slug, @dataset)
  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
