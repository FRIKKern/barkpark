defmodule BarkparkWeb.StudioComponents.PresenceNavTest do
  # DataCase-backed: resolve_presence_doc_title/2 calls Content.get_document,
  # which needs the Repo sandbox checked out even when the doc doesn't exist
  # (the lookup falls back to the raw doc_id without raising).
  use Barkpark.DataCase, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.StudioComponents.EditorFields

  defp base_assigns do
    %{
      user_id: "me-1",
      user_name: "Ada",
      user_color: "#336699",
      presences: [],
      editor_doc: nil,
      dataset: "production",
      current_workspace: nil,
      current_project: nil
    }
  end

  describe "presence_nav/1 accessibility" do
    test "a clickable remote collaborator renders as a real button with an accessible name" do
      remote = %{
        user_id: "u-2",
        name: "Grace",
        color: "#cc3300",
        doc_id: "post-123",
        type: "post"
      }

      html =
        render_component(&EditorFields.presence_nav/1, %{
          base_assigns()
          | presences: [remote]
        })

      # A <button>, not a bare <div>, carries the jump handler.
      assert html =~ ~s(<button)
      assert html =~ ~s(phx-click="jump-to-user")
      assert html =~ ~s(phx-value-doc-id="post-123")
      assert html =~ ~s(phx-value-type="post")

      # It has a non-empty aria-label naming the collaborator.
      assert html =~ ~r/aria-label="Jump to Grace[^"]*"/
    end

    test "the self me-group renders as a button with an aria-label" do
      html = render_component(&EditorFields.presence_nav/1, base_assigns())

      assert html =~ ~s(phx-click="show-profile")
      assert html =~ ~r/<button[^>]*class="presence-me-group"[^>]*aria-label="Ada[^"]*"/
    end

    test "the avatar glyphs inside the buttons are aria-hidden" do
      remote = %{
        user_id: "u-2",
        name: "Grace",
        color: "#cc3300",
        doc_id: "post-123",
        type: "post"
      }

      html =
        render_component(&EditorFields.presence_nav/1, %{
          base_assigns()
          | presences: [remote]
        })

      assert html =~ ~s(aria-hidden="true")
    end
  end
end
