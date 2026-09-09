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
               "paper-block-autosave",
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
