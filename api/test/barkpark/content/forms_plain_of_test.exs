defmodule Barkpark.Content.FormsPlainOfTest do
  @moduledoc """
  task-7655868c8b346c43: an `arrayOf` declared with `of` as a list of one
  member that is not an object (`of: [%{"type" => "string"}]`, Sanity's
  shape) is the same array as `of: %{"type" => "string"}`. It was a typed
  array: Add made a read-only `{_key, _type: "string"}` row, and a posted
  reference id was saved bare instead of as `{_ref, _type}`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Forms
  alias BarkparkWeb.Studio.StudioLive.Handlers.Fields

  defp array(of), do: %{"name" => "items", "type" => "arrayOf", "of" => of}

  test "one member that is not an object is the one-map `of`" do
    for member <- [
          %{"type" => "string"},
          %{"type" => "reference", "refType" => "author"},
          %{"type" => "image", "fields" => [%{"name" => "alt", "type" => "string"}]},
          %{"type" => "string", "name" => "tag"}
        ] do
      assert Forms.plain_of(array([member])) == array(member), inspect(member)
    end
  end

  test "an object member, several members and the map shape stay as declared" do
    object = %{"type" => "composite", "fields" => [%{"name" => "title", "type" => "string"}]}

    named = %{
      "name" => "sec",
      "type" => "composite",
      "fields" => [%{"name" => "h", "type" => "string"}]
    }

    for field <- [
          array([object]),
          array([named]),
          array([%{"type" => "string"}, %{"type" => "number"}]),
          array(%{"type" => "string"}),
          %{"name" => "title", "type" => "string"}
        ] do
      assert Forms.plain_of(field) == field, inspect(field)
    end
  end

  test "a posted list is saved as the one-map `of` saves it" do
    for member <- [%{"type" => "string"}, %{"type" => "reference", "refType" => "author"}] do
      list_schema = %{name: "post", fields: [array([member])]}
      map_schema = %{name: "post", fields: [array(member)]}
      posted = %{"items" => %{"0" => "abc", "1" => "def"}}

      assert Forms.coerce_params(posted, list_schema) == Forms.coerce_params(posted, map_schema),
             inspect(member)
    end

    assert %{"items" => [%{"_ref" => "abc", "_type" => "reference"}]} =
             Forms.coerce_params(%{"items" => %{"0" => "abc"}}, %{
               name: "post",
               fields: [array([%{"type" => "reference", "refType" => "author"}])]
             })
  end

  test "Add appends a plain item, as for the one-map `of`" do
    member = %{"type" => "string"}

    assert Fields.add_row(["a"], array([member]), nil) ==
             Fields.add_row(["a"], array(member), nil)

    refute Enum.any?(Fields.add_row(["a"], array([member]), nil), &is_map/1)
  end
end
