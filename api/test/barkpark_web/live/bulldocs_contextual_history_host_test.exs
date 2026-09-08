defmodule BarkparkWeb.BulldocsContextualHistoryHostTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.BulldocsLive

  @dataset "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    slug = "public-history-host-#{System.unique_integer([:positive])}"

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
                   }
                 ]
               })
             )

    raw = "public-history-#{System.unique_integer([:positive])}"
    assert {:ok, token} = Auth.create_token(raw, "Public history", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _html} = live(conn, "/papers/#{slug}")
    render_click(view, "paper-toggle-edit", %{})

    %{slug: slug, token: token, view: view}
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

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp image_src(slug) do
    slug
    |> Content.get_paper()
    |> Map.fetch!(:content)
    |> Map.fetch!("blocks")
    |> Enum.find(&(&1["id"] == "figure"))
    |> get_in(["child", "src"])
  end
end
