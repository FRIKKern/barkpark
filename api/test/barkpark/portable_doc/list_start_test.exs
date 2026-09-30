defmodule Barkpark.PortableDoc.ListStartTest do
  # An ordered list's first number (`start`) from markdown to every Elixir
  # surface: FromMarkdown carries it, the article and email HTML honour it, and
  # BPML pull/push keeps it. Absent or 1 means numbering from 1, byte-unchanged.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Bpml, FromMarkdown, Render}

  defp list(extra) do
    Map.merge(
      %{
        "type" => "list",
        "ordered" => true,
        "items" => [
          [%{"type" => "text", "value" => "five"}],
          [%{"type" => "text", "value" => "six"}]
        ]
      },
      extra
    )
  end

  describe "FromMarkdown" do
    test "a list beginning at 5 carries start: 5" do
      assert [%{"type" => "list", "ordered" => true, "start" => 5}] =
               FromMarkdown.blocks("5. five\n6. six\n")
    end

    test "a list beginning at 1 keeps its shape (no start key)" do
      assert [block] = FromMarkdown.blocks("1. one\n2. two\n")
      refute Map.has_key?(block, "start")
      assert Map.keys(block) |> Enum.sort() == ["items", "ordered", "type"]
    end

    test "a list beginning at 0 carries start: 0; a bullet list never carries start" do
      assert [%{"start" => 0}] = FromMarkdown.blocks("0. zero\n1. one\n")
      assert [bullets] = FromMarkdown.blocks("- a\n- b\n")
      refute Map.has_key?(bullets, "start")
    end
  end

  describe "HTML" do
    test "article: an ordered list with start 5 opens <ol start=\"5\">" do
      assert Render.render_blocks([list(%{"start" => 5})], %{style: :article}) =~
               ~s(<ol start="5"><li>)
    end

    test "article: absent start and start 1 render the same bare <ol>" do
      absent = Render.render_blocks([list(%{})], %{style: :article})
      one = Render.render_blocks([list(%{"start" => 1})], %{style: :article})
      assert absent =~ "<ol><li>"
      assert one == absent
    end

    test "email: the inline-styled <ol> carries start" do
      html = Render.render_blocks([list(%{"start" => 5})], %{style: :email})
      assert html =~ ~s(<ol start="5" style=")
      refute Render.render_blocks([list(%{})], %{style: :email}) =~ "start="
    end

    test "start is ignored on a bullet list and on a non-integer value" do
      refute Render.render_blocks([list(%{"ordered" => false, "start" => 5})], %{style: :article}) =~
               "start="

      refute Render.render_blocks([list(%{"start" => "5"})], %{style: :article}) =~ "start="
    end

    test "a nested ordered list honours its own start" do
      nested =
        list(%{
          "items" => [
            %{
              "content" => [%{"type" => "text", "value" => "outer"}],
              "children" => [list(%{"start" => 3})]
            }
          ]
        })

      html = Render.render_blocks([nested], %{style: :article})
      assert html =~ ~s(<ol><li>)
      assert html =~ ~s(<ol start="3">)
    end
  end

  describe "BPML" do
    test "start survives print → parse" do
      block = list(%{"id" => "l1", "start" => 5})
      bpml = Bpml.print_blocks([block])
      assert bpml =~ ~s(start="5")
      assert {:ok, [parsed]} = Bpml.parse_blocks(bpml)
      assert parsed["start"] == 5
      assert parsed["ordered"] == true
    end

    test "a list without start prints no start attribute" do
      refute Bpml.print_blocks([list(%{"id" => "l1"})]) =~ "start="
    end
  end
end
