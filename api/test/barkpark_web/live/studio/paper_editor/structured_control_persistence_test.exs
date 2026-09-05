defmodule BarkparkWeb.Studio.PaperEditor.StructuredControlPersistenceTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    slug = "structured-controls-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: seed_blocks()
        })
      )

    %{slug: slug}
  end

  test "Studio persists table, section, action, and card control patches across reload", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    assert has_element?(view, ~s([data-test-id="studio-paper-block-editor"]))

    render_hook(view, "paper-ops", control_batch(assigns_of(view).paper_rev))
    assert_control_state(slug)

    {:ok, reloaded, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    html = render(reloaded)

    assert html =~ "New action"
    assert html =~ "Card action"
    assert_control_state(slug)
  end

  test "public reader editor persists the same structured control patches across reload", %{
    conn: conn,
    slug: slug
  } do
    writer = writer_conn(conn)
    {:ok, view, _html} = live(writer, "/papers/#{slug}")
    render_click(view, "paper-toggle-edit", %{})

    render_hook(view, "paper-ops", control_batch(assigns_of(view).paper_rev))
    assert_control_state(slug)

    {:ok, reloaded, _html} = live(writer, "/papers/#{slug}")
    html = render_click(reloaded, "paper-toggle-edit", %{})

    assert html =~ "New action"
    assert html =~ "Card action"
    assert_control_state(slug)
  end

  defp seed_blocks do
    [
      %{
        "id" => "control-action",
        "type" => "action",
        "label" => "Old action",
        "href" => "/old",
        "priority" => "secondary",
        "tracking" => "keep-action"
      },
      %{
        "id" => "control-table",
        "type" => "table",
        "head" => [[%{"type" => "text", "value" => "Old"}]],
        "rows" => [[[%{"type" => "text", "value" => "Cell"}]]],
        "caption" => "keep-table"
      },
      %{
        "id" => "control-section",
        "type" => "section",
        "title" => "Section",
        "blocks" => [
          %{
            "id" => "section-body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Nested"}]
          }
        ],
        "note" => "keep-section"
      },
      %{
        "id" => "control-card",
        "type" => "card",
        "tone" => "info",
        "slots" => %{
          "title" => [%{"type" => "heading", "text" => "Card title"}],
          "body" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Card body"}]
            }
          ]
        }
      }
    ]
  end

  defp control_batch(if_rev) do
    %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => if_rev,
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "control-action",
          "patch" => %{"label" => "New action", "href" => "/new", "priority" => "primary"}
        },
        %{
          "op" => "patch-block",
          "id" => "control-table",
          "patch" => %{
            "head" => [
              [%{"type" => "text", "value" => "Name"}],
              [%{"type" => "text", "value" => "Value"}]
            ],
            "rows" => [
              [
                [%{"type" => "text", "value" => "Alpha"}],
                [%{"type" => "text", "value" => "1"}]
              ],
              [
                [%{"type" => "text", "value" => "Beta"}],
                [%{"type" => "text", "value" => "2"}]
              ]
            ]
          }
        },
        %{
          "op" => "patch-block",
          "id" => "control-section",
          "patch" => %{"layout" => %{"mode" => "grid", "tracks" => 3}}
        },
        %{
          "op" => "patch-block",
          "id" => "control-card",
          "patch" => %{
            "slots" => %{
              "title" => [%{"type" => "heading", "text" => "Card title"}],
              "body" => [
                %{
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "Card body"}]
                }
              ],
              "media" => [
                %{
                  "type" => "image",
                  "src" => "/media/card.png",
                  "alt" => "Card image"
                }
              ],
              "action" => [
                %{
                  "type" => "action",
                  "label" => "Card action",
                  "href" => "/card",
                  "priority" => "primary"
                }
              ]
            }
          }
        }
      ]
    }
  end

  defp assert_control_state(slug) do
    blocks = Content.paper_blocks(slug, @dataset)
    by_id = Map.new(blocks, &{&1["id"], &1})

    assert by_id["control-action"] == %{
             "id" => "control-action",
             "type" => "action",
             "label" => "New action",
             "href" => "/new",
             "priority" => "primary",
             "tracking" => "keep-action"
           }

    assert by_id["control-table"]["caption"] == "keep-table"
    assert length(by_id["control-table"]["head"]) == 2
    assert length(by_id["control-table"]["rows"]) == 2

    assert by_id["control-section"]["layout"] == %{"mode" => "grid", "tracks" => 3}
    assert by_id["control-section"]["note"] == "keep-section"
    assert hd(by_id["control-section"]["blocks"])["id"] == "section-body"

    assert by_id["control-card"]["tone"] == "info"

    assert by_id["control-card"]["slots"]["media"] == [
             %{
               "type" => "image",
               "src" => "/media/card.png",
               "alt" => "Card image"
             }
           ]

    assert by_id["control-card"]["slots"]["action"] == [
             %{
               "type" => "action",
               "label" => "Card action",
               "href" => "/card",
               "priority" => "primary"
             }
           ]
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp writer_conn(conn) do
    raw = "structured-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(raw, "structured control writer", @dataset, ["read", "write"])

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end
end
