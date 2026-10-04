defmodule BarkparkWeb.Studio.SheetPublishPublicCopyTest do
  @moduledoc """
  Owner ruling #58 (2026-10-03; task-eec10eeab544e619 Q2, sheets half):
  publishing a sheet makes it public — `/sheets/:slug` serves any published
  sheet to anyone, whatever the schema's visibility. Studio says so before
  the click (the Publish control's label, which is also its tooltip and
  aria-label) and after it (the success flash). Other types keep the plain
  "Publish" / "Published".
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.DocActions
  alias BarkparkWeb.Studio.StudioLive.Handlers.Doc

  defp publish_action(type) do
    %{
      editor_doc: %{doc_id: "drafts.s1"},
      editor_type: type,
      editor_schema: nil,
      editor_is_draft: true,
      published_doc: nil,
      content_preview_visible: false,
      content_preview_rendered: nil,
      diff_visible: false
    }
    |> DocActions.default_doc_actions(%{})
    |> Enum.find(&(&1["name"] == "publish"))
  end

  test "a sheet's Publish control says publishing makes it public" do
    assert publish_action("sheet")["label"] == "Publish — makes this sheet public"
  end

  test "other types keep the plain Publish label" do
    assert publish_action("post")["label"] == "Publish"
    assert publish_action(nil)["label"] == "Publish"
  end

  test "the success flash for a sheet says it is now public" do
    assert Doc.publish_success_message("sheet") =~ "public"
    assert Doc.publish_success_message("post") == "Published"
  end
end
