defmodule BarkparkWeb.PaperInventoryEditRoundtripTest do
  # No-data-loss by round trip, server half. The canvas half
  # (assets/paper-editor/src/canvas/__inventory_untouched.test.mjs) mounts every
  # pd-parity golden input block in one canvas, types " QZMRK" into the target
  # paragraph and pins the ONE op the editor emits. This test stores the same
  # inventory as a public paper, pushes that exact op through the public editor
  # (/papers/:slug, Edit, "paper-ops"), reloads, and asserts the stored paper
  # is byte-equivalent to the paper before the edit except the typed text.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @goldens Path.expand("../../support/fixtures/pd-parity", __DIR__)
  @target_id "inv-target"
  # The op __inventory_untouched.test.mjs asserts the canvas emits.
  @edit_op %{
    "op" => "patch-block",
    "id" => @target_id,
    "patch" => %{"content" => [%{"type" => "text", "value" => "Target QZMRK paragraph."}]}
  }

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    slug = "inventory-roundtrip-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: inventory()})
      )

    raw = "inventory-roundtrip-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(
        raw,
        "inventory roundtrip writer",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}), slug: slug}
  end

  test "one typed edit through the public editor changes only the typed text of the whole inventory",
       %{conn: conn, slug: slug} do
    before = Content.paper_blocks(slug, @dataset)
    assert length(before) > 60, "the whole golden inventory is stored (#{length(before)} blocks)"

    {:ok, view, _html} = live(conn, "/papers/#{slug}")
    render_click(view, "paper-toggle-edit", %{})

    # Entering Edit writes nothing.
    assert Content.paper_blocks(slug, @dataset) == before

    render_hook(view, "paper-ops", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => assigns_of(view).paper_rev,
      "ops" => [@edit_op]
    })

    assert assigns_of(view).save_status == "Auto-saved"

    expected =
      Enum.map(before, fn
        %{"id" => @target_id} = block -> Map.merge(block, @edit_op["patch"])
        block -> block
      end)

    after_save = Content.paper_blocks(slug, @dataset)
    assert Jason.encode!(after_save) == Jason.encode!(expected)

    {:ok, reloaded, _html} = live(conn, "/papers/#{slug}")
    render_click(reloaded, "paper-toggle-edit", %{})

    assert Jason.encode!(assigns_of(reloaded).edit_blocks) == Jason.encode!(expected)
    assert Content.paper_blocks(slug, @dataset) == after_save
  end

  defp inventory do
    blocks =
      @goldens
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        golden = @goldens |> Path.join(file) |> File.read!() |> Jason.decode!()

        case golden["input"] do
          [first | _] -> [first]
          %{} = input -> [input]
          _ -> []
        end
      end)
      |> Enum.filter(&is_binary(&1["type"]))
      |> Enum.map(&Map.merge(&1, %{"id" => "inv-#{&1["type"]}", "qa_meta" => "sentinel"}))

    target = %{
      "id" => @target_id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Target paragraph."}]
    }

    List.insert_at(blocks, div(length(blocks), 2), target)
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns
end
