defmodule BarkparkWeb.Studio.RichTextLinkTypesTest do
  @moduledoc """
  task-088575052b459f3e: the Classic rich-text editor's link row offers an
  internal link to a document only when the server says which types it may
  point at. Studio reads them from the `to` of the `internalLink` reference on
  the dataset's `link` object type (the gyldendal.no twin's, which mirrors its
  Sanity `linkAnnotation`) and stamps them on `<bp-rich-text-editor>` as
  `data-link-types`, with the picker's words and the scope it searches in.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @dataset "production"

  @body [
    %{
      "_type" => "block",
      "_key" => "b1",
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => "s1", "text" => "Hei", "marks" => []}]
    }
  ]

  defp schema!(name, fields, extra \\ %{}) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          extra
        ),
        @dataset
      )
  end

  defp article_schema!(type) do
    schema!(type, [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "body", "title" => "Innhold", "type" => "richText"}
    ])
  end

  defp open!(type) do
    doc_id = "#{type}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_document(
        type,
        %{
          "doc_id" => DraftId.draft_id(doc_id),
          "title" => "Artikkel",
          "content" => %{"body" => @body}
        },
        @dataset,
        source: :api
      )

    raw = "rte-link-types-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "rte-link-types",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    conn = build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc_id}"))
    html
  end

  defp editor_tag(html) do
    [tag] = Regex.run(~r/<bp-rich-text-editor[^>]*>/, html)
    tag
  end

  test "a body's editor carries the link object's internalLink types" do
    schema!(
      "link",
      [
        %{"name" => "title", "type" => "string"},
        %{
          "name" => "internalLink",
          "type" => "reference",
          "to" => [%{"type" => "rtlArticle"}, %{"type" => "product"}, %{"type" => "contributor"}]
        },
        %{"name" => "url", "type" => "url"}
      ],
      %{"kind" => "object"}
    )

    article_schema!("rtlArticle")
    tag = editor_tag(open!("rtlArticle"))

    assert tag =~ ~s(data-link-types="rtlArticle,product,contributor")
    assert tag =~ ~s(dataset="production")
    assert tag =~ ~s(scope-prefix=")
    assert tag =~ "data-picker-strings="
  end

  test "with no link object type the editor offers an address only" do
    article_schema!("rtlPlain")
    tag = editor_tag(open!("rtlPlain"))

    refute tag =~ "data-link-types"
    refute tag =~ "data-picker-strings"
  end
end
