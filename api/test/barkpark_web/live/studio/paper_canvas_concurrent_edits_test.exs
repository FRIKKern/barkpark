defmodule BarkparkWeb.Studio.PaperCanvasConcurrentEditsTest do
  @moduledoc """
  task-e0987185b4de61e3 — two Studio tabs on one paper, A editing the first
  paragraph and B the last at the same moment. The server takes A's batch and
  refuses B's on the old revision; only A's edit survived, because B's canvas
  stopped on "Save paused" (or threw its paragraph away on Use latest).

  The server half of the rebase the canvas now does on its own: the refusal
  says `conflict` with the newer revision and pushes that version's blocks to
  B, carrying A's paragraph, which is what B's canvas checks its ops against.
  B's id-keyed batch, resent unchanged on that revision, saves, and both
  edits persist. Each tab ends up holding the other's edit. The client side
  (no banner, automatic resend, same-paragraph conflicts still held) is pinned
  in `__paper_concurrent_rebase.test.mjs` and `__paper_rebase_canvas_mounted`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-10-10-two-tab-concurrent"

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

    blocks =
      for {id, text} <- [{"p-first", "First."}, {"p-mid", "Middle."}, {"p-last", "Last."}] do
        %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
      end

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: @slug, dataset: @dataset, blocks: blocks})
      )

    :ok
  end

  defp mount(conn) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    view
  end

  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp patch_text(id, text) do
    %{
      "op" => "patch-block",
      "id" => id,
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    }
  end

  defp text_of(blocks, id) do
    case Enum.find(blocks, &(&1["id"] == id)) do
      %{"content" => [%{"value" => value} | _]} -> value
      _ -> nil
    end
  end

  defp stored_blocks do
    case Content.get_public_paper(@slug, @dataset) do
      %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
      _ -> []
    end
  end

  test "two tabs editing different paragraphs at once both persist, and each sees the other",
       %{conn: conn} do
    tab_a = mount(conn)
    tab_b = mount(conn)
    base = paper_rev(tab_a)
    assert paper_rev(tab_b) == base

    # A and B both author on the same base revision.
    a_id = Ecto.UUID.generate()

    render_hook(tab_a, "paper-ops", %{
      "request_id" => a_id,
      "if_rev" => base,
      "ops" => [patch_text("p-first", "First. A")]
    })

    assert_reply(tab_a, %{saved: true, rev: a_rev})

    b_id = Ecto.UUID.generate()

    render_hook(tab_b, "paper-ops", %{
      "request_id" => b_id,
      "if_rev" => base,
      "ops" => [patch_text("p-last", "Last. B")]
    })

    assert_reply(tab_b, %{saved: false, conflict: true, current_rev: ^a_rev, request_id: ^b_id})

    # The refusal hands B the newer version, A's paragraph included: the blocks
    # B's canvas checks its batch against before resending it.
    assert_push_event(tab_b, "bp:canvas-update", %{rev: ^a_rev, request_id: ^b_id, runs: runs})
    latest = Enum.flat_map(runs, & &1.blocks)
    assert text_of(latest, "p-first") == "First. A"
    assert text_of(latest, "p-last") == "Last."

    # B's id-keyed batch, resent unchanged on that revision, saves.
    b_retry = Ecto.UUID.generate()

    render_hook(tab_b, "paper-ops", %{
      "request_id" => b_retry,
      "if_rev" => a_rev,
      "ops" => [patch_text("p-last", "Last. B")]
    })

    assert_reply(tab_b, %{saved: true, rev: b_rev})
    assert b_rev != a_rev

    stored = stored_blocks()
    assert text_of(stored, "p-first") == "First. A", "A's edit survived"
    assert text_of(stored, "p-last") == "Last. B", "B's edit survived"
    assert text_of(stored, "p-mid") == "Middle."

    # Tab A receives B's save with both paragraphs.
    _ = render(tab_a)
    assert_push_event(tab_a, "bp:canvas-update", %{rev: ^b_rev, request_id: nil, runs: a_runs})
    seen_by_a = Enum.flat_map(a_runs, & &1.blocks)
    assert text_of(seen_by_a, "p-first") == "First. A"
    assert text_of(seen_by_a, "p-last") == "Last. B"
  end
end
