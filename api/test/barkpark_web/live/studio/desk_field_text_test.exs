defmodule BarkparkWeb.Studio.Desk.FieldTextTest do
  @moduledoc """
  A read-only document pane prints rich text as its text, not as JSON
  (feel walk 2026-11-13: a post's Body read as 750 px of `{ "blocks": [`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.FieldText

  @dataset "production"
  @body %{
    "blocks" => [
      %{
        "type" => "heading",
        "level" => 2,
        "content" => [%{"type" => "text", "value" => "Heading"}]
      },
      %{
        "type" => "paragraph",
        "content" => [
          %{"type" => "text", "value" => "Body "},
          %{"type" => "text", "value" => "bold", "marks" => ["strong"]},
          %{"type" => "text", "value" => " text."}
        ]
      }
    ]
  }

  describe "show/1" do
    test "a PortableDoc value reads as its text, a paragraph per block" do
      assert FieldText.show(@body) == "Heading\n\nBody bold text."
    end

    test "Sanity-style portable text reads as its spans" do
      blocks = [
        %{
          "_type" => "block",
          "children" => [
            %{"_type" => "span", "text" => "One "},
            %{"_type" => "span", "text" => "two"}
          ]
        },
        %{"_type" => "block", "children" => [%{"_type" => "span", "text" => "Three"}]}
      ]

      assert FieldText.show(blocks) == "One two\n\nThree"
    end

    test "rich text with no text is a dash; other values print as before" do
      assert FieldText.show(%{"blocks" => []}) == "—"
      assert FieldText.show(nil) == "—"
      assert FieldText.show("plain") == "plain"
      assert FieldText.show(3) == "3"
      assert FieldText.show(%{"current" => "a-slug"}) =~ ~s("current": "a-slug")
    end

    test "long rich text is cut at 600 characters" do
      long = %{
        "blocks" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => String.duplicate("a", 700)}]
          }
        ]
      }

      assert String.length(FieldText.show(long)) == 602
    end
  end

  test "a read-only document pane prints a rich-text field as text", %{conn: conn} do
    type = "desk_ft_post"
    ref_type = "desk_ft_author"
    n = System.unique_integer([:positive])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => ref_type,
          "title" => "Authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [ref_type]},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    author = "dft-a-#{n}"
    post = "dft-p-#{n}"

    {:ok, _} =
      Content.create_document(ref_type, %{"doc_id" => author, "title" => "Ada"}, @dataset)

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => post,
          "title" => "A post",
          "content" => %{"author" => %{"_ref" => author, "_type" => "reference"}, "body" => @body}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-ft-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-ft",
        @dataset,
        ["read", "write", "admin"],
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    # The post is read-only once its author opens after it.
    {:ok, view, _html} =
      live(conn, "#{base}/#{type};#{post};#{author},type=#{ref_type},parentRefPath=author")

    render_async(view, 5_000)

    pane = ~s([data-pane-index="2"])
    assert has_element?(view, pane <> " .pane-header-title", "A post")
    assert has_element?(view, pane <> " dd", "Body bold text.")
    refute has_element?(view, pane <> " dd", ~s("blocks"))
  end
end
