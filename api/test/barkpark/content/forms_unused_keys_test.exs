defmodule Barkpark.Content.FormsUnusedKeysTest do
  @moduledoc """
  task-b9f103b5b2666124 — the Classic form's LiveView `_unused_` bookkeeping
  keys must never decide a stored shape.

  LiveView's client posts, beside every input the author has not touched, a
  sibling key with the `_unused_` prefix on its LAST segment: an untouched
  `doc[keywords][0]` also posts `doc[keywords][_unused_0]`. Measured in a real
  browser on 2026-09-30 (add an empty Keywords row, then type in Title): the
  row map arrived as `%{"0" => "", "_unused_0" => ""}`, failed the
  all-index-keys test, and was STORED as that map — the list vanished on
  reload and publish refused "expected a list".

  The params below are the exact decoded shape the browser posted.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Forms

  @schema %{
    fields: [
      %{"name" => "title", "type" => "string"},
      %{"name" => "keywords", "type" => "arrayOf", "of" => %{"type" => "string"}},
      %{
        "name" => "seo",
        "type" => "composite",
        "fields" => [
          %{"name" => "metaTitle", "type" => "string"},
          %{"name" => "metaDescription", "type" => "text"}
        ]
      },
      %{
        "name" => "banners",
        "type" => "arrayOf",
        "of" => %{
          "type" => "composite",
          "fields" => [%{"name" => "title", "type" => "string"}]
        }
      }
    ]
  }

  test "an untouched arrayOf row with its _unused_ sibling becomes a list" do
    posted = %{
      "title" => "Third X",
      "keywords" => %{"0" => "", "_unused_0" => ""}
    }

    assert %{"keywords" => [""], "title" => "Third X"} = Forms.coerce_params(posted, @schema)
  end

  test "a touched row next to an untouched one keeps index order and drops the marker" do
    posted = %{"keywords" => %{"1" => "cms", "0" => "headless", "_unused_2" => "", "2" => ""}}
    assert %{"keywords" => ["headless", "cms", ""]} = Forms.coerce_params(posted, @schema)
  end

  test "composite rows inside an arrayOf lose the marker too" do
    posted = %{
      "banners" => %{
        "0" => %{"title" => "Crime", "_unused_title" => ""},
        "_unused_0" => ""
      }
    }

    assert %{"banners" => [row]} = Forms.coerce_params(posted, @schema)
    assert row == %{"title" => "Crime"}
  end

  test "a top-level composite drops the marker and keeps real subfields" do
    posted = %{"seo" => %{"metaTitle" => "SEO", "_unused_metaDescription" => ""}}
    assert %{"seo" => %{"metaTitle" => "SEO"} = seo} = Forms.coerce_params(posted, @schema)
    refute Map.has_key?(seo, "_unused_metaDescription")
  end

  test "values already in storage shape pass through unchanged" do
    posted = %{"keywords" => ["a", "b"], "seo" => %{"metaTitle" => "x"}}
    assert Forms.coerce_params(posted, @schema) == posted
  end
end
