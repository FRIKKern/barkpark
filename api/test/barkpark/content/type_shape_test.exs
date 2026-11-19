defmodule Barkpark.Content.TypeShapeTest do
  @moduledoc """
  `Content.TypeShape`: a `url` field's value of the wrong shape, as the
  TanStack Studio's `typeRule` finds it (`lib/validation.ts`), down objects
  and array items, under an item's kind.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.TypeShape

  @links %{
    "name" => "links",
    "title" => "Links",
    "type" => "arrayOf",
    "of" => %{
      "type" => "composite",
      "options" => %{
        "typeField" => "kind",
        "fieldsByType" => %{"externalLink" => ["title", "url"], "docLink" => ["title", "target"]}
      },
      "fields" => [
        %{"name" => "kind", "type" => "select"},
        %{"name" => "title", "type" => "string"},
        %{"name" => "url", "title" => "URL", "type" => "url"},
        %{"name" => "target", "type" => "reference"}
      ]
    }
  }

  @schema %{
    "fields" => [
      %{"name" => "site", "type" => "url"},
      %{
        "name" => "cta",
        "type" => "composite",
        "fields" => [%{"name" => "url", "type" => "url"}]
      },
      %{"name" => "sites", "type" => "arrayOf", "of" => %{"type" => "url"}},
      @links
    ]
  }

  defp codes(content), do: content |> TypeShape.findings(@schema) |> Enum.map(&{&1.path, &1.code})

  test "url_problem/1 answers as the TanStack Studio's url rule" do
    for ok <- [
          "https://example.com",
          "http://example.com:8080/a b?q=1#x",
          "  https://x.no  ",
          "http://[::1]/"
        ],
        do: assert(TypeShape.url_problem(ok) == nil, ok)

    for bad <- [
          "not a url",
          "/relative",
          "example.com",
          "http://",
          "https://exa mple.com",
          "http://x:99999"
        ],
        do: assert(TypeShape.url_problem(bad) == :url_invalid, bad)

    assert TypeShape.url_problem("mailto:a@b.no") == :url_scheme
    assert TypeShape.url_problem("ftp://files.example.com") == :url_scheme
    assert TypeShape.url_problem("https://user:pw@example.com") == :url_credentials
    assert TypeShape.url_problem("https://user@example.com") == :url_credentials
  end

  test "a bad url in an array item is found under its row, with TanStack's words" do
    links = [
      %{"_key" => "l1", "kind" => "externalLink", "title" => "Bad link", "url" => "not a url"}
    ]

    assert [%{path: "/links/0/url", code: :url_invalid, message: "Not a valid URL", params: %{}}] =
             TypeShape.findings(%{"links" => links}, @schema)
  end

  test "top-level, object and plain array items are checked; blanks are not" do
    content = %{
      "site" => "nope",
      "cta" => %{"url" => "mailto:a@b.no"},
      "sites" => ["https://ok.no", "https://u:p@x.no", ""],
      "links" => []
    }

    assert codes(content) == [
             {"/site", :url_invalid},
             {"/cta/url", :url_scheme},
             {"/sites/1", :url_credentials}
           ]

    assert codes(%{"site" => "", "cta" => %{}, "sites" => nil}) == []
  end

  test "an item's field its kind does not show is not checked, as TanStack's" do
    hidden = [%{"_key" => "d1", "kind" => "docLink", "url" => "not a url"}]
    assert codes(%{"links" => hidden}) == []

    no_kind = [%{"_key" => "n1", "url" => "not a url"}]
    assert codes(%{"links" => no_kind}) == [{"/links/0/url", :url_invalid}]
  end

  test "a typed array's item is checked by the member its _type names" do
    schema = %{
      "fields" => [
        %{
          "name" => "blocks",
          "type" => "arrayOf",
          "of" => [%{"name" => "cta", "fields" => [%{"name" => "href", "type" => "url"}]}]
        }
      ]
    }

    content = %{
      "blocks" => [%{"_type" => "cta", "href" => "x"}, %{"_type" => "other", "href" => "x"}]
    }

    assert [%{path: "/blocks/0/href", code: :url_invalid}] = TypeShape.findings(content, schema)
  end

  test "a struct schema's fields, no content and no schema" do
    assert [%{path: "/site"}] = TypeShape.findings(%{"site" => "x"}, %{fields: @schema["fields"]})
    assert TypeShape.findings(nil, @schema) == []
    assert TypeShape.findings(%{"site" => "x"}, nil) == []
  end
end
