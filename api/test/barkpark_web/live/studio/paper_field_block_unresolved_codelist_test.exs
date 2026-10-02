defmodule BarkparkWeb.Studio.PaperFieldBlockUnresolvedCodelistTest do
  # r2b click-to-edit census: a codelist block whose list is not registered on
  # the instance rendered only a disabled "(no codelist registered…)" select in
  # Edit — the label and stored code the reader paints ("Language", "nb")
  # vanished. Edit now paints the reader's own line read-only above the control.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.PaperFieldBlock

  test "an unregistered codelist paints the reader's label and code in Edit" do
    block = %{"id" => "cl", "type" => "codelist", "label" => "Language", "value" => "nb"}
    html = render_component(PaperFieldBlock, id: "paper-fb-cl", block: block)

    reader = Render.render_block(block, %{style: :article})
    assert reader =~ "nb"
    assert html =~ ~s(data-test-id="paper-codelist-unresolved-paint")
    assert html =~ reader
    assert html =~ ~s(data-codelist-empty="true"), "the control itself is unchanged"
  end
end
