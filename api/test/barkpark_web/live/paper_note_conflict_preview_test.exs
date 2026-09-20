defmodule BarkparkWeb.PaperNoteConflictPreviewTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1]

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.Studio.StudioLive.Handlers.Paper, as: PaperHandler
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: SharedPaper

  @dataset "production"

  setup do
    pin_paper_canvas!("1")
  end

  test "conflict resync pairs latest canvas source with canonical readonly Note paint", %{
    conn: conn
  } do
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

    raw = "note-conflict-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        raw,
        "Note conflict",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    slug = "note-conflict-#{System.unique_integer([:positive])}"
    original = %{"id" => "n", "type" => "note", "label" => "Label", "text" => "Old safe body"}

    sibling = %{
      "id" => "preserved",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Preserved published body"}],
      "vendor" => %{"nested" => [nil, 7]}
    }

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Note conflict",
          blocks: [original, sibling]
        })
      )

    {:ok, view, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    if has_element?(view, ~s([data-test-id="paper-edit-toggle"])) do
      view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
    end

    assert has_element?(view, "bp-paper-canvas")
    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.editor_view == :paper
    assert socket.assigns.paper_doc.doc_id == slug
    stale_rev = socket.assigns.paper_rev
    assert is_integer(stale_rev)

    latest = %{
      "id" => "n",
      "type" => "note",
      "label" => "Label",
      "vendor" => %{"latest" => [nil, 9]},
      "slots" => %{
        "body" => [
          %{
            "id" => "body-p",
            "type" => "paragraph",
            "vendor" => true,
            "content" => [
              %{"id" => "text-leaf", "type" => "text", "value" => "Latest <body>"},
              %{"id" => "code-leaf", "type" => "code", "value" => " & code", "keep" => [1, nil]}
            ]
          }
        ],
        "unknown" => [%{"id" => "unknown", "keep" => true}]
      }
    }

    {:ok, _} =
      Content.apply_paper_block_ops(
        slug,
        [%{"op" => "replace-block", "id" => "n", "block" => latest}],
        @dataset
      )

    persisted = Content.get_paper(slug, @dataset)
    assert persisted.content["blocks"] === [latest, sibling]
    request_id = Ecto.UUID.generate()

    # Exercise the production handler with the stale session snapshot. Clear
    # prior pushes so an opening/PubSub paint cannot falsely satisfy this test.
    socket = %{socket | private: Map.put(socket.private, :live_temp, %{})}

    assert {:reply, %{saved: false, conflict: true, request_id: ^request_id}, resynced} =
             PaperHandler.paper_ops(
               %{
                 "request_id" => request_id,
                 "if_rev" => stale_rev,
                 "ops" => [%{"op" => "patch-block", "id" => "n", "patch" => %{"text" => "Stale"}}]
               },
               socket
             )

    events = Phoenix.LiveView.Utils.get_push_events(resynced)

    assert ["bp:canvas-update", %{request_id: ^request_id, runs: runs}] =
             Enum.find(events, fn [name, _] -> name == "bp:canvas-update" end)

    assert Enum.any?(runs, &(&1.blocks === [latest, sibling]))

    assert ["bp:task-preview", _] =
             Enum.find(events, fn [name, _] -> name == "bp:task-preview" end)

    assert ["bp:block-html", %{renders: renders}] =
             Enum.find(events, fn [name, _] -> name == "bp:block-html" end)

    assert Enum.find(renders, &(&1["block_id"] == "n")) === SharedPaper.note_render(latest)
    assert Content.get_paper(slug, @dataset).content === persisted.content
  end
end
