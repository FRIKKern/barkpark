defmodule BarkparkWeb.Studio.PaperRemoteCaretsTest do
  @moduledoc """
  task-c522237b9f37de21 — two LiveView sessions on one paper never saw each
  other's caret: the canvas emits `bp-canvas-selection` and can draw
  `setRemoteSelections`, and the presence API carries a selection (#22510),
  but the LiveView paper host wired neither end. The caret now rides this
  socket's presence meta (`paper-selection`), and every other session on the
  paper gets `bp:remote-selections` with it; it clears when that session
  leaves or blurs. A session never receives its own caret, and a malformed
  selection is never stored.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-10-10-remote-carets"

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    blocks = [
      %{
        "id" => "p-1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Hello carets."}]
      }
    ]

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: @slug, dataset: @dataset, blocks: blocks})
      )

    :ok
  end

  defp open_as(conn, user_id, user_name) do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"user_id" => user_id, "user_name" => user_name})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    view
  end

  @selection %{
    "anchor" => %{"blockId" => "p-1", "offset" => 0},
    "head" => %{"blockId" => "p-1", "offset" => 5}
  }

  test "each session sees the other's caret, never its own, and it clears on leave", %{conn: conn} do
    alice = open_as(conn, "caret-alice", "Alice")
    bob = open_as(build_conn(), "caret-bob", "Bob")

    render_hook(alice, "paper-selection", %{"selection" => @selection})
    _ = render(bob)

    assert_push_event(bob, "bp:remote-selections", %{list: [caret]})
    assert caret.name == "Alice"
    assert caret.anchor == @selection["anchor"]
    assert caret.head == @selection["head"]
    assert is_binary(caret.color)

    _ = render(alice)
    refute_push_event(alice, "bp:remote-selections", %{list: [%{name: "Alice"} | _]})

    # Bob's caret reaches Alice.
    render_hook(bob, "paper-selection", %{"selection" => @selection})
    _ = render(alice)
    assert_push_event(alice, "bp:remote-selections", %{list: [%{name: "Bob"}]})

    # Alice leaves: Bob's list drops her.
    GenServer.stop(alice.pid)
    Process.sleep(50)
    _ = render(bob)
    assert_push_event(bob, "bp:remote-selections", %{list: []})
  end

  test "a blur clears the caret, and a malformed selection is never stored", %{conn: conn} do
    alice = open_as(conn, "caret-alice2", "Alice")
    bob = open_as(build_conn(), "caret-bob2", "Bob")

    render_hook(alice, "paper-selection", %{"selection" => @selection})
    _ = render(bob)
    assert_push_event(bob, "bp:remote-selections", %{list: [%{name: "Alice"}]})

    render_hook(alice, "paper-selection", %{"selection" => %{"anchor" => "nope"}})
    _ = render(bob)
    refute_push_event(bob, "bp:remote-selections", %{list: [%{anchor: "nope"} | _]})

    render_hook(alice, "paper-selection", %{"selection" => nil})
    _ = render(bob)
    assert_push_event(bob, "bp:remote-selections", %{list: []})
  end
end
