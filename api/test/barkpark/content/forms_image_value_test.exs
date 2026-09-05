defmodule Barkpark.Content.FormsImageValueTest do
  @moduledoc """
  Gyldendal parity E1 — an `image` field's picker value is a STRING on the
  wire (a bare URL or a JSON object). At the save boundary the object is decoded
  into a map so consumers read `content.cover.focalX` as a number; a bare URL
  stays a string; the map rides back to the picker as its JSON string.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Forms

  defp schema(fields), do: %{fields: fields}

  test "a JSON object value is decoded into a map; a bare URL stays a string" do
    s = schema([%{"name" => "cover", "type" => "image"}, %{"name" => "hero", "type" => "image"}])

    params = %{
      "cover" => ~s({"url":"/x.png","assetId":"a1","alt":"Cover","focalX":0.5,"focalY":0.25}),
      "hero" => "/hero.png"
    }

    content = Forms.build_content(params, s)

    assert content["cover"] == %{
             "url" => "/x.png",
             "assetId" => "a1",
             "alt" => "Cover",
             "focalX" => 0.5,
             "focalY" => 0.25
           }

    assert content["hero"] == "/hero.png"
  end

  test "a string that only looks like JSON is kept as-is for the validator to refuse" do
    s = schema([%{"name" => "cover", "type" => "image"}])
    assert Forms.build_content(%{"cover" => "{not json"}, s)["cover"] == "{not json"
  end

  test "doc_to_form hands a decoded image map back to the picker as its JSON string" do
    s = schema([%{"name" => "cover", "type" => "image"}])

    doc = %{
      title: "T",
      status: "draft",
      content: %{"cover" => %{"url" => "/x.png", "assetId" => "a1", "focalX" => 0.5}}
    }

    form = Forms.doc_to_form(doc, s)
    assert is_binary(form["cover"])

    assert Jason.decode!(form["cover"]) == %{
             "url" => "/x.png",
             "assetId" => "a1",
             "focalX" => 0.5
           }
  end
end
