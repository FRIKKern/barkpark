defmodule BarkparkWeb.Studio.PaperEditor.StepsHostIdentityTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper
  alias BarkparkWeb.BulldocsLive.Edit

  test "Paper field lookup shares projected step identities without changing stored content" do
    blocks = [
      %{
        "type" => "steps",
        "steps" => [
          %{"title" => "Legacy", "children" => [%{"type" => "field-number", "value" => 3}]}
        ]
      }
    ]

    projected = Barkpark.Content.ensure_block_ids(blocks)
    child = hd(hd(projected)["steps"])["children"] |> hd()
    paper = %{doc_id: "paper", content: %{"blocks" => blocks}}
    socket = %Phoenix.LiveView.Socket{assigns: %{paper_doc: paper, edit_blocks: blocks}}
    assert Paper.paper_block_by_id(socket, child["id"]) == child
    assert Edit.block_by_id(socket, child["id"]) == child
    assert socket.assigns.paper_doc.content["blocks"] == blocks
  end

  test "generic Beta loads projected identities without modifying the source" do
    block = %{
      "type" => "steps",
      "steps" => [%{"title" => "Legacy", "blocks" => [%{"type" => "paragraph", "content" => []}]}]
    }

    {projected, nil} = Paper.project_editor_blocks([block])
    child = hd(hd(projected)["steps"])["blocks"] |> hd()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{editor_view: :form, editor_mode: :beta, editor_blocks: projected}
    }

    assert Paper.paper_top_level_blocks(socket) == projected
    assert Paper.paper_block_by_id(socket, child["id"]) == child
    refute Map.has_key?(block, "id")
    refute Map.has_key?(hd(block["steps"]), "id")
  end

  test "ambiguous identities never enter the generic Beta baseline" do
    blocks = [
      %{"id" => "same", "type" => "paragraph", "content" => []},
      %{"id" => "same", "type" => "paragraph", "content" => []}
    ]

    assert Paper.project_editor_blocks(blocks) == {[], {:duplicate_id, "same"}}
  end
end
