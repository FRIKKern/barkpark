defmodule BarkparkWeb.Studio.StudioContextualHistoryHostTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    slug = "studio-contextual-history-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "figure",
              "type" => "figure",
              "child" => %{
                "id" => "image",
                "type" => "image",
                "src" => "/before.png",
                "alt" => "Keep authored alt"
              }
            },
            %{
              "id" => "paragraph",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Before"}]
            }
          ]
        })
      )

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{paper.doc_id}"))

    {:ok, view: view, socket: :sys.get_state(view.pid).socket, slug: slug}
  end

  test "classifies the history step as a write event" do
    assert Caps.classify("paper-history-step") == :write
  end

  test "a request-identified image edit exposes an opaque step and undo/redo replay exactly",
       %{socket: socket, slug: slug} do
    forward_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              changed: true,
              request_id: ^forward_id,
              replayed: false,
              rev: forward_rev,
              history_step: %{version: 1, ref: ^forward_id, action: "undo"}
            }, forward_socket} =
             StudioLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"src" => "/after.png"},
                 "request_id" => forward_id,
                 "if_rev" => socket.assigns.paper_rev
               },
               socket
             )

    assert image_src(slug) == "/after.png"
    undo_id = Ecto.UUID.generate()

    undo_params = %{
      "history_ref" => forward_id,
      "action" => "undo",
      "request_id" => undo_id,
      "if_rev" => forward_rev
    }

    assert {:reply,
            %{
              saved: true,
              request_id: ^undo_id,
              replayed: false,
              rev: undo_rev,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"}
            }, undo_socket} =
             StudioLive.handle_event("paper-history-step", undo_params, forward_socket)

    assert image_src(slug) == "/before.png"

    assert {:reply,
            %{
              saved: true,
              request_id: ^undo_id,
              replayed: true,
              rev: ^undo_rev,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"}
            }, replay_socket} =
             StudioLive.handle_event("paper-history-step", undo_params, undo_socket)

    assert image_src(slug) == "/before.png"
    redo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              request_id: ^redo_id,
              replayed: false,
              rev: _redo_rev,
              history_step: %{version: 1, ref: ^redo_id, action: "undo"}
            }, _redo_socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => undo_id,
                 "action" => "redo",
                 "request_id" => redo_id,
                 "if_rev" => undo_rev
               },
               replay_socket
             )

    assert image_src(slug) == "/after.png"
  end

  test "single block form saves expose history while unsupported edits expose explicit nil", %{
    socket: socket
  } do
    caption_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              changed: true,
              request_id: ^caption_id,
              replayed: false,
              history_step: %{version: 1, ref: ^caption_id, action: "undo"}
            }, caption_socket} =
             StudioLive.handle_event(
               "paper-block-autosave",
               %{
                 "block_id" => "figure",
                 "caption" => "A caption",
                 "request_id" => caption_id,
                 "if_rev" => socket.assigns.paper_rev
               },
               socket
             )

    paragraph_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              changed: true,
              request_id: ^paragraph_id,
              replayed: false,
              history_step: nil
            }, _paragraph_socket} =
             StudioLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "paragraph",
                 "patch" => %{
                   "content" => [%{"type" => "text", "value" => "Unsupported history"}]
                 },
                 "request_id" => paragraph_id,
                 "if_rev" => caption_socket.assigns.paper_rev
               },
               caption_socket
             )
  end

  test "history steps require exactly the four protocol keys and the Paper pane", %{
    socket: socket,
    slug: slug
  } do
    before = Content.get_paper(slug, @dataset)

    valid_shape = %{
      "history_ref" => Ecto.UUID.generate(),
      "action" => "undo",
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => socket.assigns.paper_rev
    }

    assert {:reply, %{saved: false}, _socket} =
             StudioLive.handle_event(
               "paper-history-step",
               Map.put(valid_shape, "private_receipt", %{}),
               socket
             )

    beta_socket = Phoenix.Component.assign(socket, editor_view: :form, editor_mode: :beta)

    assert {:reply, %{saved: false}, _socket} =
             StudioLive.handle_event("paper-history-step", valid_shape, beta_socket)

    assert Content.get_paper(slug, @dataset).content === before.content
  end

  defp image_src(slug) do
    slug
    |> Content.get_paper(@dataset)
    |> then(&get_in(&1.content, ["blocks", Access.at(0), "child", "src"]))
  end
end
