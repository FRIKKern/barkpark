defmodule Barkpark.Content.PreviewTextIconTest do
  @moduledoc """
  A `list_preview.media` alternative that picks an icon by a stored value, as
  a Sanity `prepare` that returns an icon component does.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PreviewText

  defp none(_), do: nil

  @kind %{
    "icon" => %{
      "path" => "kind",
      "map" => %{"guide" => "compass", "faq" => "help-circle", "draft" => nil},
      "else" => "document",
      "empty" => "folder"
    }
  }

  test "a value names its icon in the map" do
    assert PreviewText.media_item(@kind, %{"kind" => "guide"}, &none/1) == {:icon, "compass"}
    assert PreviewText.media_item(@kind, %{"kind" => "faq"}, &none/1) == {:icon, "help-circle"}
  end

  test "else covers a value the map does not name, empty a missing one" do
    assert PreviewText.media_item(@kind, %{"kind" => "recipe"}, &none/1) == {:icon, "document"}
    assert PreviewText.media_item(@kind, %{}, &none/1) == {:icon, "folder"}
    assert PreviewText.media_item(@kind, %{"kind" => ""}, &none/1) == {:icon, "folder"}
  end

  test "a nil icon, or no else or empty, picks nothing" do
    assert PreviewText.media_item(@kind, %{"kind" => "draft"}, &none/1) == nil

    bare = %{"icon" => %{"path" => "kind", "map" => %{"guide" => "compass"}}}
    assert PreviewText.media_item(bare, %{"kind" => "recipe"}, &none/1) == nil
    assert PreviewText.media_item(bare, %{}, &none/1) == nil
  end

  test "a number reads as its digits, and a list of paths takes the first with a value" do
    by_code = %{"icon" => %{"path" => ["outer.code", "code"], "map" => %{"7" => "star"}}}
    assert PreviewText.media_item(by_code, %{"code" => 7}, &none/1) == {:icon, "star"}
    assert PreviewText.media_item(by_code, %{"code" => 7.0}, &none/1) == {:icon, "star"}

    assert PreviewText.media_item(by_code, %{"outer" => %{"code" => 7}, "code" => 1}, &none/1) ==
             {:icon, "star"}
  end

  test "an image path before the pick wins when it holds an image" do
    spec = ["cover", @kind]
    url = "https://images.example.com/c.jpg"

    assert PreviewText.media_item(spec, %{"cover" => url, "kind" => "guide"}, &none/1) ==
             {:url, url}

    assert PreviewText.media_item(spec, %{"kind" => "guide"}, &none/1) == {:icon, "compass"}
    assert PreviewText.media(spec, %{"cover" => url}, &none/1) == url
    assert PreviewText.media(spec, %{"kind" => "guide"}, &none/1) == nil
  end

  test "the pick follows references, and ref_ids names them for a page load" do
    spec = %{"icon" => %{"path" => "section.code", "map" => %{"north" => "pin"}}}
    root = %{"section" => %{"_ref" => "sec-1"}}

    assert PreviewText.ref_ids([spec], root) == ["sec-1"]

    deref = fn
      "sec-1" -> %{"code" => "north"}
      _ -> nil
    end

    assert PreviewText.media_item(spec, root, deref) == {:icon, "pin"}
  end

  test "media? is true for a spec with only an icon pick; media_paths lists image paths" do
    assert PreviewText.media?(@kind)
    assert PreviewText.media?(["cover", @kind])
    refute PreviewText.media?(nil)
    assert PreviewText.media_paths(["cover", @kind]) == ["cover"]
  end
end
