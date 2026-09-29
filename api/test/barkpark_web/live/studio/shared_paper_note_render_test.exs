defmodule BarkparkWeb.Studio.SharedPaperNoteRenderTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  defp unsafe_note do
    %{
      "id" => "unsafe-note",
      "type" => "note",
      "label" => "divergent shadow",
      "custom" => %{"keep" => [nil, 7]},
      "html" => "<script>untrusted source</script>",
      "slots" => %{
        "label" => [
          %{
            "id" => "label-p",
            "type" => "paragraph",
            "meta" => true,
            "content" => [%{"type" => "text", "value" => "Shown"}]
          }
        ],
        "body" => [
          %{
            "id" => "body-p",
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "value" => "Unsafe <text>", "meta" => %{"keep" => true}},
              %{"type" => "code", "value" => "& code", "id" => "code-leaf", "custom" => [nil, 3]}
            ]
          }
        ],
        "unknown" => [%{"extra" => "keep"}]
      }
    }
  end

  test "unsafe singular note paint is the escaped canonical reader row bound to exact source" do
    block = unsafe_note()

    assert Paper.note_render(block) === %{
             "block_id" => "unsafe-note",
             "source_block" => block,
             "html" => Components.note_item_html(block)
           }

    html = Paper.note_render(block)["html"]

    assert html ==
             ~s(<div class="bp-note"><span class="bp-note__k">Shown</span>) <>
               ~s(<div class="bp-note__d">Unsafe &lt;text&gt;&amp; code</div></div>)

    refute html =~ "<script"
    refute html =~ "contenteditable"
    refute html =~ "<code"
  end

  test "lead trim, body content fallback and metadata use the canonical reader without source changes" do
    block = %{
      "id" => "fallback-note",
      "type" => "note",
      "lead" => " <Lead> ",
      "text" => nil,
      "content" => [%{"type" => "text", "value" => "one"}, %{"type" => "code", "value" => "two"}],
      "opaque" => %{"ids" => ["nested-id"]}
    }

    assert Paper.note_render(block) === %{
             "block_id" => block["id"],
             "source_block" => block,
             "html" => Components.note_item_html(block)
           }

    assert Paper.note_render(block)["html"] =~ "<b>&lt;Lead&gt;</b> onetwo"
  end

  test "bp:block-html includes singular notes, including nested opaque carriers, without changing blocks" do
    block = unsafe_note()
    nested = %{block | "id" => "nested-note"}
    blocks = [block, %{"id" => "section", "type" => "section", "blocks" => [nested]}]

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        editor_view: :form,
        editor_mode: :beta,
        editor_blocks: blocks,
        dataset: "production"
      },
      private: %{live_temp: %{}}
    }

    painted = Paper.push_block_renders(socket)
    assert painted.assigns.editor_blocks === blocks

    assert [["bp:block-html", %{renders: renders}]] =
             Phoenix.LiveView.Utils.get_push_events(painted)

    assert renders === [Paper.note_render(block), Paper.note_render(nested)]
  end
end
