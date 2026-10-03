defmodule BarkparkWeb.Studio.PaperCanvasExternalEchoTest do
  @moduledoc """
  Two Studio tabs on one paper. Tab B saves a canvas paragraph; tab A must get
  B's confirmed blocks on its canvas (`bp:canvas-update`, no request id, B's
  revision), not only the table echo.

  Found dogfooding the canvas (2026-10-03, task-df54fe4732460302):
  tab A's data-canvas-blocks attribute updated, but the canvas wrapper is
  phx-update="ignore", so A's editor kept the old paragraph. The table echo
  pushed with the frame advanced A's confirmed revision anyway, so A's next
  edit to that paragraph was sent on B's revision, accepted, and silently
  overwrote B's text.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-10-03-two-tab-canvas"

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
        "id" => "p-first",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "First paragraph."}]
      },
      %{
        "id" => "t-mid",
        "type" => "table",
        "rows" => [
          [[%{"type" => "text", "value" => "one"}], [%{"type" => "text", "value" => "1"}]]
        ]
      },
      %{
        "id" => "p-last",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Last paragraph."}]
      }
    ]

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

  test "a canvas save in one tab reaches the other tab's canvas with the saved blocks",
       %{conn: conn} do
    tab_a = mount(conn)
    tab_b = mount(conn)

    request_id = Ecto.UUID.generate()

    render_hook(tab_b, "paper-ops", %{
      "request_id" => request_id,
      "if_rev" => paper_rev(tab_b),
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "p-last",
          "patch" => %{"content" => [%{"type" => "text", "value" => "Last paragraph. B1"}]}
        }
      ]
    })

    stored_rev = paper_rev(tab_b)

    # Let tab A process the broadcast before asserting on its pushes.
    _ = render(tab_a)
    assert paper_rev(tab_a) == stored_rev

    assert_push_event(tab_a, "bp:canvas-update", %{runs: runs, rev: ^stored_rev} = payload)
    assert payload.request_id == nil

    last_run = Enum.find(runs, fn run -> Enum.any?(run.blocks, &(&1["id"] == "p-last")) end)
    assert last_run, "tab A's canvas gets the run holding the paragraph tab B changed"

    assert Enum.find(last_run.blocks, &(&1["id"] == "p-last"))["content"] ==
             [%{"type" => "text", "value" => "Last paragraph. B1"}]
  end
end
