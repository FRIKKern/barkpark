defmodule BarkparkWeb.Studio.SheetPublishPublicCopyTest do
  @moduledoc """
  Owner ruling #58 (2026-10-03; task-eec10eeab544e619 Q2, sheets half):
  publishing a sheet makes it public — `/sheets/:slug` serves any published
  sheet to anyone, whatever the schema's visibility. Studio says so before
  the click (the Publish control's label, which is also its tooltip and
  aria-label) and after it (the success flash). Other types keep the plain
  "Publish" / "Published".

  The flash names the `/sheets/:slug` page only where it exists: that reader
  serves the seeded Default workspace's `production` sheets only. Elsewhere it
  says what is true (lead ruling on task-976a2df147626749).
  """
  use Barkpark.DataCase, async: false

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

  defp sheet(ws_id), do: %{doc_id: "drafts.s1", workspace_id: ws_id}

  test "in the Default workspace the flash says it is public and names its page" do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    msg = Doc.publish_success_message("sheet", sheet(ws.id), "production")
    assert msg =~ "anyone can now read this one at /sheets/s1"
  end

  test "elsewhere the flash names no public page" do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    for {doc, dataset} <- [
          {sheet(Ecto.UUID.generate()), "production"},
          {sheet(ws.id), "staging"},
          {sheet(nil), "production"}
        ] do
      msg = Doc.publish_success_message("sheet", doc, dataset)
      assert msg =~ "readable through the API under this workspace's sharing rules"
      refute msg =~ "/sheets/"
      refute msg =~ "anyone can"
    end
  end

  test "other types keep the plain Published flash" do
    assert Doc.publish_success_message("post", sheet(nil), "production") == "Published"
  end
end
