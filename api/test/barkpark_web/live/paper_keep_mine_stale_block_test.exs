defmodule BarkparkWeb.PaperKeepMineStaleBlockTest do
  @moduledoc """
  Two editors on one Paper (task-7a92f596371dc4c1). Editor A types one key in block 1;
  the rich editor's batch for that key also patches block 4 with A's copy of it.
  rich_one_key_batch.json holds that batch; __keep_mine_batch.test.mjs runs the real
  canvas under the real page hooks, types the key, opens the conflict banner, presses
  "Keep mine", and checks that both sends carry exactly the fixture's ops. Editor B
  changed block 4 a moment before.

    * With no click, A's batch is refused on the old revision and block 4 holds B's
      words.
    * "Keep mine" resends the same ops on the revision the refusal named. Block 4 must
      still hold B's words: A kept a key in block 1, not a copy of block 4.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.BulldocsLive

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/paper-editor/rich_one_key_batch.json", __DIR__)
  @b_words "Install the bp CLI with Homebrew:"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    ensure_default_scope!()
    fixture = @fixture |> File.read!() |> Jason.decode!()
    slug = "keep-mine-stale-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Keep mine probe",
          "blocks" => fixture["blocks"]
        })
      )

    {:ok, a, _html} = live(writer_conn(conn), "/papers/#{slug}")
    {:ok, b, _html} = live(writer_conn(conn), "/papers/#{slug}")
    render_click(a, "paper-toggle-edit", %{})
    render_click(b, "paper-toggle-edit", %{})
    initial_rev = socket_of(a).assigns.paper_rev
    assert socket_of(b).assigns.paper_rev == initial_rev

    # B changes block 4 and saves first.
    assert {:reply, %{saved: true, rev: b_rev}, _b_socket} =
             BulldocsLive.handle_event(
               "paper-ops",
               %{
                 "request_id" => Ecto.UUID.generate(),
                 "if_rev" => initial_rev,
                 "ops" => [
                   %{
                     "op" => "patch-block",
                     "id" => "b4",
                     "patch" => %{"content" => [%{"type" => "text", "value" => @b_words}]}
                   }
                 ]
               },
               socket_of(b)
             )

    assert words(slug, "b4") == @b_words

    # A types one key in block 1 before B's save reaches it: A's batch goes on the
    # revision A opened.
    a_request = Ecto.UUID.generate()

    assert {:reply, %{saved: false, request_id: ^a_request, conflict: true, current_rev: ^b_rev},
            a_socket} =
             BulldocsLive.handle_event(
               "paper-ops",
               %{"request_id" => a_request, "if_rev" => initial_rev, "ops" => fixture["ops"]},
               socket_of(a)
             )

    %{slug: slug, ops: fixture["ops"], a_socket: a_socket, b_rev: b_rev}
  end

  test "with no click, block 4 holds the other editor's words", %{slug: slug} do
    assert words(slug, "b4") == @b_words
    refute words(slug, "b1") =~ "x"
  end

  test "Keep mine on a key in block 1 keeps the other editor's block 4", ctx do
    # What Keep mine sends (__keep_mine_batch.test.mjs): the same ops, a new request
    # id, the revision the refusal named.
    assert {:reply, %{saved: true}, _socket} =
             BulldocsLive.handle_event(
               "paper-ops",
               %{"request_id" => Ecto.UUID.generate(), "if_rev" => ctx.b_rev, "ops" => ctx.ops},
               ctx.a_socket
             )

    assert words(ctx.slug, "b1") =~ "xThe workspace your AI works in."

    assert words(ctx.slug, "b4") == @b_words,
           "Keep mine on a block-1 key wrote A's stale copy of block 4 over B's newer edit"
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp words(slug, id) do
    %{content: %{"blocks" => blocks}} = Content.get_public_paper(slug, @dataset)
    blocks |> Enum.find(&(&1["id"] == id)) |> Map.get("content", []) |> text()
  end

  defp text(runs) when is_list(runs), do: Enum.map_join(runs, &text/1)
  defp text(%{"children" => children}), do: text(children)
  defp text(%{"value" => value}) when is_binary(value), do: value
  defp text(_), do: ""

  defp writer_conn(conn) do
    raw = "keep-mine-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(
        raw,
        "keep mine writer",
        @dataset,
        ["read", "write"],
        default_workspace_id!()
      )

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end
end
