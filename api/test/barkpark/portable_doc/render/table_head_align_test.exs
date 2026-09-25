defmodule Barkpark.PortableDoc.Render.TableHeadAlignTest do
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.{Bpml, Render}
  alias Barkpark.PortableDoc.Render.Compose

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp table do
    %{
      "id" => "t1",
      "type" => "table",
      "headCol" => true,
      "head" => [text("Item"), %{"content" => text("Qty"), "align" => "right"}],
      "rows" => [[%{"content" => text("Apple"), "align" => "center"}, text("3")], [[], text("5")]],
      "spans" => [%{"row" => 0, "col" => 0, "rowspan" => 2, "colspan" => 1}]
    }
  end

  test "article renders row headers, alignment and spans together" do
    html = Render.render_block(table(), %{style: :article, doctype: false})
    assert html =~ ~s(<th scope="row")
    assert html =~ ~s(rowspan="2")
    assert html =~ ~s(style="text-align:center")
    assert html =~ ~s(style="text-align:right")
    assert length(Regex.scan(~r/scope="row"/, html)) == 1
    assert html =~ ~s(<td class="bp-table__td"><span>5</span></td>)
  end

  test "header column and aligned head/body cells survive BPML with spans" do
    source = table()
    bpml = Bpml.print_blocks([source])
    assert bpml =~ ~s(headcol="true")
    assert bpml =~ ~s(<th align="right">Qty</th>)
    assert bpml =~ ~s(<td rowspan="2" align="center">Apple</td>)
    assert {:ok, [^source]} = Bpml.parse_blocks(bpml)
  end

  test "unrecognized alignment and nonboolean header column never enter render attributes" do
    source = %{
      "type" => "table",
      "headCol" => "true",
      "rows" => [[%{"content" => text("Safe"), "align" => "right; color:red"}]]
    }

    pd = Compose.compose_block(source, :article)
    refute Map.has_key?(pd, "headCol")
    refute Map.has_key?(pd, "aligns")
    html = Render.render_block(source, %{style: :article, doctype: false})
    refute html =~ "scope="
    refute html =~ "color:red"
  end
end
