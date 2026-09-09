defmodule BarkparkWeb.BulldocsContextualHistoryHostTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.BulldocsLive
  alias BarkparkWeb.Studio.StudioLive.Blocks

  @dataset "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    slug = "public-history-host-#{System.unique_integer([:positive])}"
    target_slug = "#{slug}-target"
    sibling_slug = "#{slug}-sibling"

    for linked_slug <- [target_slug, sibling_slug] do
      assert {:ok, _paper} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: linked_slug,
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

    assert {:ok, _paper} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 slug: slug,
                 blocks: [
                   %{"id" => "intro", "type" => "paragraph", "text" => "Keep me."},
                   %{
                     "id" => "figure",
                     "type" => "figure",
                     "caption" => "Original caption",
                     "child" => %{
                       "id" => "image",
                       "type" => "image",
                       "src" => "/before.png",
                       "alt" => "Authored description"
                     }
                   },
                   %{
                     "id" => "links",
                     "type" => "paper-links",
                     "title" => "Original links heading",
                     "description" => "Original links description",
                     "refs" => refs,
                     "unknown" => [1, 2]
                   },
                   %{
                     "id" => "card",
                     "type" => "card",
                     "tone" => "calm",
                     "slots" => %{
                       "title" => [%{"type" => "heading", "text" => "Card title"}],
                       "body" => [%{"type" => "paragraph", "content" => []}],
                       "media" => [
                         %{
                           "type" => "image",
                           "src" => "/card-before.png",
                           "alt" => "Card alt",
                           "width" => 640,
                           "height" => 320,
                           "opaque" => %{"keep" => [true, nil, 1, 1.0]}
                         }
                       ],
                       "action" => [
                         %{"type" => "action", "label" => "Read", "href" => "/read"}
                       ],
                       "unknown" => %{"slot" => true}
                     },
                     "unknown" => %{"card" => true}
                   }
                 ]
               })
             )

    raw = "public-history-#{System.unique_integer([:positive])}"
    assert {:ok, token} = Auth.create_token(raw, "Public history", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _html} = live(conn, "/papers/#{slug}")
    render_click(view, "paper-toggle-edit", %{})

    %{
      slug: slug,
      token: token,
      view: view,
      refs: refs,
      target_slug: target_slug
    }
  end

  test "Public exposes opaque history refs and applies and replays one authorized step", %{
    slug: slug,
    view: view
  } do
    forward_id = Ecto.UUID.generate()

    assert {:reply, forward, socket} =
             BulldocsLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"src" => "/after.png"},
                 "request_id" => forward_id,
                 "if_rev" => socket_of(view).assigns.paper_rev
               },
               socket_of(view)
             )

    assert forward == %{
             saved: true,
             changed: true,
             request_id: forward_id,
             replayed: false,
             rev: forward.rev,
             history_step: %{version: 1, ref: forward_id, action: "undo"}
           }

    refute inspect(forward) =~ "/before.png"
    undo_id = Ecto.UUID.generate()

    params = %{
      "history_ref" => forward_id,
      "action" => "undo",
      "request_id" => undo_id,
      "if_rev" => forward.rev
    }

    assert {:reply, undo, undone_socket} =
             BulldocsLive.handle_event("paper-history-step", params, socket)

    assert undo == %{
             saved: true,
             request_id: undo_id,
             replayed: false,
             rev: undo.rev,
             history_step: %{version: 1, ref: undo_id, action: "redo"}
           }

    assert image_src(slug) == "/before.png"

    newer_halt = %{reason: :newer_lifecycle_halt}
    halted_socket = Phoenix.Component.assign(undone_socket, :paper_halt, newer_halt)

    assert {:reply, replay, replayed_socket} =
             BulldocsLive.handle_event("paper-history-step", params, halted_socket)

    assert replay == %{undo | replayed: true}
    assert replayed_socket.assigns.paper_halt == newer_halt
    assert image_src(slug) == "/before.png"
  end

  test "Public reauthorizes before history lookup and exact payloads fail closed", %{
    slug: slug,
    token: token,
    view: view
  } do
    ref = Ecto.UUID.generate()

    assert {:reply, forward, saved_socket} =
             BulldocsLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"src" => "/after.png"},
                 "request_id" => ref,
                 "if_rev" => socket_of(view).assigns.paper_rev
               },
               socket_of(view)
             )

    before = Content.get_paper(slug).content

    invalid = %{
      "history_ref" => ref,
      "action" => "undo",
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => forward.rev,
      "private_inverse" => %{"src" => "/forged.png"}
    }

    assert {:reply, %{saved: false, history_step: nil}, socket} =
             BulldocsLive.handle_event("paper-history-step", invalid, saved_socket)

    assert Content.get_paper(slug).content == before
    assert {:ok, _revoked} = Auth.revoke_token(token)

    valid = Map.delete(invalid, "private_inverse")

    assert {:reply, %{saved: false, history_step: nil}, _socket} =
             BulldocsLive.handle_event("paper-history-step", valid, socket)

    assert Content.get_paper(slug).content == before
  end

  test "unsupported exact and legacy writes return an explicit nil history step", %{
    view: view
  } do
    request_id = Ecto.UUID.generate()

    assert {:reply, exact, socket} =
             BulldocsLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"alt" => "New description"},
                 "request_id" => request_id,
                 "if_rev" => socket_of(view).assigns.paper_rev
               },
               socket_of(view)
             )

    assert exact.history_step == nil
    assert exact.changed == true

    assert {:reply, legacy, _socket} =
             BulldocsLive.handle_event(
               "paper-op",
               %{
                 "op" => "patch-block",
                 "id" => "image",
                 "patch" => %{"alt" => "Legacy description"},
                 "if_rev" => exact.rev
               },
               socket
             )

    assert legacy.history_step == nil
    assert legacy.changed == true
  end

  test "Public paper-links heading ACK undoes and redoes without touching references", %{
    slug: slug,
    refs: refs,
    view: view
  } do
    forward_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              history_step: %{version: 1, ref: ^forward_id, action: "undo"},
              rev: forward_rev
            }, forward_socket} =
             BulldocsLive.handle_event(
               "paper-block-autosave",
               %{
                 "block_id" => "links",
                 "title" => "  Public heading  ",
                 "request_id" => forward_id,
                 "if_rev" => socket_of(view).assigns.paper_rev
               },
               socket_of(view)
             )

    assert paper_links(slug)["title"] == "  Public heading  "
    assert paper_links(slug)["refs"] === refs

    undo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"},
              rev: undo_rev
            }, undone_socket} =
             BulldocsLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => undo_id,
                 "if_rev" => forward_rev
               },
               forward_socket
             )

    assert paper_links(slug)["title"] == "Original links heading"
    redo_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true}, _redone_socket} =
             BulldocsLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => undo_id,
                 "action" => "redo",
                 "request_id" => redo_id,
                 "if_rev" => undo_rev
               },
               undone_socket
             )

    links = paper_links(slug)
    assert links["title"] == "  Public heading  "
    assert links["description"] == "Original links description"
    assert links["unknown"] == [1, 2]
  end

  test "Public authored reference title exposes only opaque v1 history and round-trips exactly",
       %{
         slug: slug,
         refs: refs,
         target_slug: target_slug,
         view: view
       } do
    [target, sibling] = refs
    linked_before = Content.get_paper(target_slug).content
    forward_id = Ecto.UUID.generate()
    updated_target = Map.put(target, "title", "  Public authored title  ")

    assert {:reply,
            %{
              saved: true,
              changed: true,
              replayed: false,
              request_id: ^forward_id,
              history_step: %{version: 1, ref: ^forward_id, action: "undo"},
              rev: forward_rev
            } = forward_reply, forward_socket} =
             BulldocsLive.handle_event(
               "paper-edit-block",
               reference_copy_params(
                 target,
                 "title",
                 "  Public authored title  ",
                 forward_id,
                 socket_of(view).assigns.paper_rev
               ),
               socket_of(view)
             )

    refute inspect(forward_reply) =~ "Original target title"
    assert [^updated_target, ^sibling] = paper_links(slug)["refs"]
    assert Content.get_paper(target_slug).content === linked_before

    undo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              replayed: false,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"},
              rev: undo_rev
            }, undone_socket} =
             BulldocsLive.handle_event(
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
    assert Content.get_paper(target_slug).content === linked_before

    redo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              replayed: false,
              history_step: %{version: 1, ref: ^redo_id, action: "undo"}
            }, _redone_socket} =
             BulldocsLive.handle_event(
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
    assert Content.get_paper(target_slug).content === linked_before
  end

  test "Public Card media source history preserves the current carrier through undo and redo", %{
    slug: slug,
    view: view
  } do
    original_card = card(slug)
    original_media = card_media(slug)
    forward_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              changed: true,
              replayed: false,
              request_id: ^forward_id,
              history_step: %{version: 1, ref: ^forward_id, action: "undo"},
              rev: forward_rev
            } = forward_reply, forward_socket} =
             BulldocsLive.handle_event(
               "paper-block-autosave",
               %{
                 "block_id" => "card",
                 "card-media-src" => "/card-after.png",
                 "request_id" => forward_id,
                 "if_rev" => socket_of(view).assigns.paper_rev
               },
               socket_of(view)
             )

    refute inspect(forward_reply) =~ "/card-before.png"
    saved_media = card_media(slug)
    assert saved_media === Map.put(original_media, "src", "/card-after.png")

    concurrent_media =
      saved_media
      |> Map.put("alt", "Concurrent Public alt")
      |> Map.put("width", 1280)
      |> Map.put("opaque", %{"later" => [false, nil]})

    concurrent_slots = Map.put(card(slug)["slots"], "media", [concurrent_media])

    assert {:ok, %{rev: concurrent_rev}} =
             Content.apply_paper_block_op(
               slug,
               %{
                 "op" => "patch-block",
                 "id" => "card",
                 "patch" => %{"slots" => concurrent_slots}
               },
               @dataset,
               if_rev: forward_rev
             )

    undo_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: true,
              history_step: %{version: 1, ref: ^undo_id, action: "redo"},
              rev: undo_rev
            }, undone_socket} =
             BulldocsLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => forward_id,
                 "action" => "undo",
                 "request_id" => undo_id,
                 "if_rev" => concurrent_rev
               },
               forward_socket
             )

    assert card_media(slug) === Map.put(concurrent_media, "src", original_media["src"])
    assert Map.delete(card(slug), "slots") === Map.delete(original_card, "slots")
    redo_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true}, _redone_socket} =
             BulldocsLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => undo_id,
                 "action" => "redo",
                 "request_id" => redo_id,
                 "if_rev" => undo_rev
               },
               undone_socket
             )

    assert card_media(slug) === concurrent_media
  end

  test "Public Card media history rejects newer sources and carrier type drift", %{
    slug: slug,
    view: view
  } do
    forward_id = Ecto.UUID.generate()

    assert {:reply, %{saved: true, rev: forward_rev}, forward_socket} =
             BulldocsLive.handle_event(
               "paper-edit-block",
               %{
                 "block_id" => "card",
                 "card-media-src" => "/card-after.png",
                 "request_id" => forward_id,
                 "if_rev" => socket_of(view).assigns.paper_rev
               },
               socket_of(view)
             )

    newer_media = Map.put(card_media(slug), "src", "/card-newer.png")
    newer_slots = Map.put(card(slug)["slots"], "media", [newer_media])

    assert {:ok, %{rev: newer_rev}} =
             patch_card_slots(slug, newer_slots, forward_rev)

    assert_history_conflict(forward_socket, forward_id, newer_rev)
    typeless_media = newer_media |> Map.put("src", "/card-after.png") |> Map.delete("type")
    typeless_slots = Map.put(card(slug)["slots"], "media", [typeless_media])

    assert {:ok, %{rev: typeless_rev}} =
             patch_card_slots(slug, typeless_slots, newer_rev)

    assert_history_conflict(forward_socket, forward_id, typeless_rev)
    assert card_media(slug) === typeless_media
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp image_src(slug) do
    slug
    |> Content.get_paper()
    |> Map.fetch!(:content)
    |> Map.fetch!("blocks")
    |> Enum.find(&(&1["id"] == "figure"))
    |> get_in(["child", "src"])
  end

  defp paper_links(slug) do
    slug
    |> Content.get_paper()
    |> Map.fetch!(:content)
    |> Map.fetch!("blocks")
    |> Enum.find(&(&1["id"] == "links"))
  end

  defp card(slug) do
    slug
    |> Content.get_paper()
    |> Map.fetch!(:content)
    |> Map.fetch!("blocks")
    |> Enum.find(&(&1["id"] == "card"))
  end

  defp card_media(slug), do: get_in(card(slug), ["slots", "media", Access.at(0)])

  defp patch_card_slots(slug, slots, if_rev) do
    Content.apply_paper_block_op(
      slug,
      %{"op" => "patch-block", "id" => "card", "patch" => %{"slots" => slots}},
      @dataset,
      if_rev: if_rev
    )
  end

  defp assert_history_conflict(socket, history_ref, if_rev) do
    request_id = Ecto.UUID.generate()

    assert {:reply,
            %{
              saved: false,
              request_id: ^request_id,
              rejected: "history_conflict",
              conflict: true,
              current_rev: ^if_rev
            }, _socket} =
             BulldocsLive.handle_event(
               "paper-history-step",
               %{
                 "history_ref" => history_ref,
                 "action" => "undo",
                 "request_id" => request_id,
                 "if_rev" => if_rev
               },
               socket
             )
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
