defmodule Barkpark.Content.Forms.CodelistCodeTest do
  @moduledoc """
  task-141a4243ed18f4c5: a typed codelist value (`CodelistShape`, #27955)
  and a pasted one (`FieldPaste`, #27970) are read by one rule, "is this a
  code". Each value below is a code to both or to neither, so neither limit
  can move alone.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Forms.CodelistShape
  alias BarkparkWeb.Studio.StudioLive.Handlers.FieldPaste

  @field %{"name" => "c", "type" => "codelist"}
  @schema %{fields: [@field]}

  # One grapheme of 301 bytes: short to the eye, long to the store.
  @heavy "e" <> String.duplicate("́", 150)

  @values [
    {"a known code", "FBA", true},
    {"64 characters", String.duplicate("F", 64), true},
    {"64 four-byte characters", String.duplicate("😀", 64), true},
    {"65 characters", String.duplicate("F", 65), false},
    {"one grapheme of 301 bytes", @heavy, false},
    {"a list", ["FBA"], false},
    {"a map", %{"code" => "FBA"}, false},
    {"a number", 7, false}
  ]

  defp typed?(value), do: CodelistShape.split(%{"c" => value}, @schema) == {%{"c" => value}, []}

  defp pasted?(value),
    do: match?({:ok, _}, FieldPaste.value(@field, nil, "codelist", value, fn _, _ -> false end))

  for {label, value, code?} <- @values do
    test "#{label}: #{if code?, do: "a code", else: "not a code"} typed and pasted alike" do
      value = unquote(Macro.escape(value))
      assert CodelistShape.code?(value) == unquote(code?)
      assert typed?(value) == unquote(code?)
      assert pasted?(value) == unquote(code?)
    end
  end

  test "nothing clears: nil and the unset marker are codes, as a typed clear is" do
    assert CodelistShape.code?(nil)
    assert CodelistShape.code?(%Barkpark.Content.Forms.Unset{})
    assert typed?(nil)
  end

  test "the limit is one number" do
    assert CodelistShape.max_length() == 64
  end
end
