defmodule Barkpark.PortableDoc.Render.StringMarksTest do
  @moduledoc """
  BPML (`bp paper push`) stores a text leaf's marks as bare strings,
  `%{"marks" => ["code"]}`, while the editor writes `%{"type" => "code"}` maps.
  The reader must paint both spellings alike.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  defp para(marks) do
    %{
      "type" => "paragraph",
      "id" => "p",
      "content" => [%{"type" => "text", "value" => "word", "marks" => marks}]
    }
  end

  for {name, tag} <- [
        {"strong", "font-weight:bold"},
        {"em", "font-style:italic"},
        {"code", "<code"}
      ] do
    test "a bare-string #{name} mark renders like its map twin" do
      assert Render.render_block(para([unquote(name)])) =~ unquote(tag)

      assert Render.render_block(para([unquote(name)])) ==
               Render.render_block(para([%{"type" => unquote(name)}]))
    end
  end
end
