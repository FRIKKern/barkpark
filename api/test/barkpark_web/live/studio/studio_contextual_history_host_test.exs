defmodule BarkparkWeb.Studio.StudioContextualHistoryHostTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Blocks

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
    target_slug = "#{slug}-target"
    sibling_slug = "#{slug}-sibling"

    for linked_slug <- [target_slug, sibling_slug] do
      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: linked_slug,
            dataset: @dataset,
            blocks: [
              %{
                "id" => "linked-copy",
                "type" => "paragraph",
                "text" => "Linked source stays untouched."
              }
            ]
          })
        )
    end

    refs = [
      %{
        "slug" => target_slug,
        "prefer_authored_copy" => true,
        "title" => "Original target title",
        "description" => "Original target description",
        "unknown" => %{"keep" => [true, nil, 1, 1.0]}
      },
      %{
        "slug" => sibling_slug,
        "title" => "Sibling title",
        "description" => "Sibling description",
        "unknown" => %{"sibling" => true}
      }
    ]

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
            },
            %{
              "id" => "links",
              "type" => "paper-links",
              "title" => "Original links heading",
              "description" => "Original links description",
              "refs" => refs,
              "unknown" => [1, 2]
            }
          ]
        })
      )

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{paper.doc_id}"))

    {:ok,
     view: view,
     socket: :sys.get_state(view.pid).socket,
     slug: slug,
     refs: refs,
     target_slug: target_slug}
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
            } = forward_reply, forward_socket} =
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

    assert Enum.sort(Map.keys(forward_reply)) ==
             [:changed, :history_step, :replayed, :request_id, :rev, :saved]

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
            } = undo_reply, undo_socket} =
             StudioLive.handle_event("paper-history-step", undo_params, forward_socket)

    assert Enum.sort(Map.keys(undo_reply)) ==
             [:history_step, :replayed, :request_id, :rev, :saved]

    assert image_src(slug) == "/before.png"

    replay_halt = %{reason: "A newer lifecycle gate halted this editor"}
    halted_socket = Phoenix.Component.assign(undo_socket, paper_halt: replay_halt)

    assert {:reply,
            %{
              saved: true,
              request_id: ^undo_id,
              replayed: true,
              rev: ^undo_rev,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"}
            }, replay_socket} =
             StudioLive.handle_event("paper-history-step", undo_params, halted_socket)

    assert image_src(slug) == "/before.png"
    assert replay_socket.assigns.paper_halt == replay_halt
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

  test "a source no-op follows op_count but exposes no history step", %{socket: socket} do
    request_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              changed: true,
              request_id: ^request_id,
              replayed: false,
              history_step: nil
            }, _socket} =
             StudioLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"src" => "/before.png"},
                 "request_id" => request_id,
                 "if_rev" => socket.assigns.paper_rev
               },
               socket
             )
  end

  test "Studio paper-links description ACK undoes and redoes without touching neighbours", %{
    refs: refs,
    socket: socket,
    slug: slug
  } do
    forward_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              history_step: %{version: 1, ref: ^forward_id, action: "undo"},
              rev: forward_rev
            }, forward_socket} =
             StudioLive.handle_event(
               "paper-block-autosave",
               %{
                 "block_id" => "links",
                 "description" => "  Studio description  ",
                 "request_id" => forward_id,
                 "if_rev" => socket.assigns.paper_rev
               },
               socket
             )

    assert paper_links(slug)["description"] == "  Studio description  "
    undo_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true, rev: undo_rev}, undone_socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => undo_id,
                 "if_rev" => forward_rev
               },
               forward_socket
             )

    assert paper_links(slug)["description"] == "Original links description"

    assert {:reply, %{saved: true}, _redone_socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => undo_id,
                 "action" => "redo",
                 "request_id" => Ecto.UUID.generate(),
                 "if_rev" => undo_rev
               },
               undone_socket
             )

    links = paper_links(slug)
    assert links["description"] == "  Studio description  "
    assert links["title"] == "Original links heading"
    assert links["refs"] === refs
    assert links["unknown"] == [1, 2]
  end

  test "Studio authored reference description exposes opaque v1 history and preserves linked state",
       %{
         refs: refs,
         socket: socket,
         slug: slug,
         target_slug: target_slug
       } do
    [target, sibling] = refs
    linked_before = Content.get_paper(target_slug, @dataset).content
    forward_id = Ecto.UUID.generate()
    updated_target = Map.put(target, "description", "  Studio authored description  ")

    assert {:reply,
            %{
              saved: true,
              changed: true,
              replayed: false,
              request_id: ^forward_id,
              history_step: %{version: 1, ref: ^forward_id, action: "undo"},
              rev: forward_rev
            } = forward_reply, forward_socket} =
             StudioLive.handle_event(
               "paper-block-autosave",
               reference_copy_params(
                 target,
                 "description",
                 "  Studio authored description  ",
                 forward_id,
                 socket.assigns.paper_rev
               ),
               socket
             )

    assert Enum.sort(Map.keys(forward_reply)) ==
             [:changed, :history_step, :replayed, :request_id, :rev, :saved]

    refute inspect(forward_reply) =~ "Original target description"
    assert [^updated_target, ^sibling] = paper_links(slug)["refs"]
    assert Content.get_paper(target_slug, @dataset).content === linked_before

    undo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              replayed: false,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"},
              rev: undo_rev
            }, undone_socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => undo_id,
                 "if_rev" => forward_rev
               },
               forward_socket
             )

    assert paper_links(slug)["refs"] === refs
    assert Content.get_paper(target_slug, @dataset).content === linked_before

    redo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              replayed: false,
              history_step: %{version: 1, ref: ^redo_id, action: "undo"}
            }, _redone_socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => undo_id,
                 "action" => "redo",
                 "request_id" => redo_id,
                 "if_rev" => undo_rev
               },
               undone_socket
             )

    assert [^updated_target, ^sibling] = paper_links(slug)["refs"]
    assert Content.get_paper(target_slug, @dataset).content === linked_before
  end

  test "Studio authored reference history rejects a newer selected-field value", %{
    refs: refs,
    socket: socket,
    slug: slug,
    target_slug: target_slug
  } do
    [target, sibling] = refs
    linked_before = Content.get_paper(target_slug, @dataset).content
    forward_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true, rev: forward_rev}, forward_socket} =
             StudioLive.handle_event(
               "paper-block-autosave",
               reference_copy_params(
                 target,
                 "title",
                 "Saved title",
                 forward_id,
                 socket.assigns.paper_rev
               ),
               socket
             )

    newer_target = Map.put(target, "title", "Newer title")

    assert {:ok, %{rev: newer_rev}} =
             Content.apply_paper_block_op(
               slug,
               %{
                 "op" => "patch-block",
                 "id" => "links",
                 "patch" => %{"refs" => [newer_target, sibling]}
               },
               @dataset,
               if_rev: forward_rev
             )

    request_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: false,
              request_id: ^request_id,
              rejected: "history_conflict",
              conflict: true,
              current_rev: ^newer_rev
            }, _socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => request_id,
                 "if_rev" => newer_rev
               },
               forward_socket
             )

    assert [^newer_target, ^sibling] = paper_links(slug)["refs"]
    assert Content.get_paper(target_slug, @dataset).content === linked_before
  end

  test "credential, revoked-token, and read-only refusals happen before history lookup", %{
    socket: socket,
    slug: slug
  } do
    forward_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true, rev: forward_rev}, forward_socket} =
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

    params = %{
      "history_ref" => forward_id,
      "action" => "undo",
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => forward_rev
    }

    refused_sockets = [
      Phoenix.Component.assign(forward_socket,
        current_user: nil,
        api_token: nil,
        api_token_credential_present?: true
      ),
      Phoenix.Component.assign(forward_socket,
        current_user: nil,
        api_token: %{id: "revoked-token"},
        api_token_raw: "not-a-valid-token",
        api_token_credential_present?: true
      ),
      Phoenix.Component.assign(forward_socket, editor_type: "session")
    ]

    for refused <- refused_sockets do
      assert {:reply, %{saved: false, rejected: "history_unavailable"}, _socket} =
               StudioLive.handle_event("paper-history-step", params, refused)

      assert image_src(slug) == "/after.png"
    end

    assert {:reply, %{saved: true}, _socket} =
             StudioLive.handle_event("paper-history-step", params, forward_socket)

    assert image_src(slug) == "/before.png"
  end

  test "terminal failures expose only the safe rejected vocabulary", %{socket: socket} do
    missing = %{
      "history_ref" => Ecto.UUID.generate(),
      "action" => "undo",
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => socket.assigns.paper_rev
    }

    assert {:reply, %{saved: false, rejected: "history_unavailable"}, _socket} =
             StudioLive.handle_event("paper-history-step", missing, socket)

    assert {:reply, %{saved: false, rejected: "invalid_history_request"}, _socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{missing | "action" => "erase", "request_id" => Ecto.UUID.generate()},
               socket
             )

    forward_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true, rev: forward_rev}, forward_socket} =
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

    undo_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true, rev: undo_rev}, undo_socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => undo_id,
                 "if_rev" => forward_rev
               },
               forward_socket
             )

    assert {:reply, %{saved: false, rejected: "history_ref_consumed"}, _socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => Ecto.UUID.generate(),
                 "if_rev" => undo_rev
               },
               undo_socket
             )
  end

  test "same-field divergence returns the fresh current revision without host effects", %{
    socket: socket,
    slug: slug
  } do
    forward_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true}, forward_socket} =
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

    assert {:ok, %{rev: newer_rev}} =
             Content.apply_paper_block_op(
               slug,
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"src" => "/newer.png"}
               },
               @dataset,
               if_rev: forward_socket.assigns.paper_rev
             )

    request_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: false,
              request_id: ^request_id,
              rejected: "history_conflict",
              conflict: true,
              current_rev: ^newer_rev
            }, _socket} =
             StudioLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => request_id,
                 "if_rev" => newer_rev
               },
               forward_socket
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

    assert {:reply, %{saved: false, rejected: "invalid_history_request"}, _socket} =
             StudioLive.handle_event(
               "paper-history-step",
               Map.put(valid_shape, "private_receipt", %{}),
               socket
             )

    beta_socket = Phoenix.Component.assign(socket, editor_view: :form, editor_mode: :beta)

    assert {:reply, %{saved: false, rejected: "invalid_history_request"}, _socket} =
             StudioLive.handle_event("paper-history-step", valid_shape, beta_socket)

    assert Content.get_paper(slug, @dataset).content === before.content
  end

  defp image_src(slug) do
    slug
    |> Content.get_paper(@dataset)
    |> then(&get_in(&1.content, ["blocks", Access.at(0), "child", "src"]))
  end

  defp paper_links(slug) do
    slug
    |> Content.get_paper(@dataset)
    |> Map.fetch!(:content)
    |> Map.fetch!("blocks")
    |> Enum.find(&(&1["id"] == "links"))
  end

  defp reference_copy_params(ref, field, value, request_id, if_rev) do
    %{
      "block_id" => "links",
      "paper-link-ref-index" => "0",
      "paper-link-ref-slug" => ref["slug"],
      "paper-link-ref-field" => field,
      "paper-link-ref-value" => value,
      "paper-link-ref-guard" => Blocks.paper_link_ref_guard(ref),
      "request_id" => request_id,
      "if_rev" => if_rev
    }
  end
end
