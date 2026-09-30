defmodule BarkparkWeb.Studio.PaperEditor.ReadonlyFallbackPaintTest do
  # r2b click-to-edit census: a block type with no editor (the chat rows) showed
  # only "… blocks are not editable yet" in Edit — the words the reader paints
  # vanished. The fallback now paints the reader HTML read-only above the note.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  for block <- [
        %{
          "id" => "plan",
          "type" => "chat-plan",
          "approval_status" => "pending",
          "title" => "Unify the renderers",
          "preview" => "Collapse five renderers to three, prove parity per block."
        },
        %{
          "id" => "approval",
          "type" => "chat-approval",
          "approval_status" => "pending",
          "summary" => "rm -rf api/_build/prod",
          "tool_name" => "Bash"
        },
        %{
          "id" => "diff",
          "type" => "chat-tool-diff",
          "input" => %{
            "file_path" => "lib/foo.ex",
            "old_string" => "def hello do\n  :old\nend",
            "new_string" => "def hello do\n  :new\nend"
          }
        }
      ] do
    @block block
    test "#{block["type"]}: Edit paints what the reader paints, read-only" do
      html =
        render_component(&PaperEditor.paper_block_fields/1,
          block: @block,
          root_slug: "paper",
          doc_key: "production:paper:paper",
          paper_rev: 1
        )

      reader = Render.render_block(@block, %{style: :article})
      assert reader != ""
      assert html =~ reader

      preview =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-test-id='paper-readonly-preview']")

      assert Enum.count(preview) == 1
      assert html =~ "blocks are not editable yet"
    end
  end
end
