defmodule BarkparkWeb.Studio.Desk.FieldTextTest do
  @moduledoc """
  A read-only document pane prints rich text as its text, and the other
  values as the TanStack Studio's read-only form shows them, not as JSON
  (feel walks 2026-11-13: a post's Body read as 750 px of `{ "blocks": [`;
  Tags, SEO and a slug as their JSON).
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

  describe "show/2" do
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

    test "rich text with no text is a dash; a string or a number prints as it is" do
      assert FieldText.show(%{"blocks" => []}) == "—"
      assert FieldText.show(nil) == "—"
      assert FieldText.show("plain") == "plain"
      assert FieldText.show(3) == "3"
    end

    # Feel walk 2: Tags read `[ "fixture", "t2" ]`, SEO its JSON, a slug
    # `{ "current": … }`, Featured "false". TanStack's read-only form shows values.
    test "a slug is its text, a yes/no is Yes or No" do
      assert FieldText.show(%{"_type" => "slug", "current" => "a-slug"}, %{"type" => "slug"}) ==
               "a-slug"

      assert FieldText.show(true, %{"type" => "boolean"}) == "Yes"
      assert FieldText.show(false, %{"type" => "boolean"}) == "No"
    end

    test "a list of plain values is a comma list, not JSON" do
      assert FieldText.show(["fixture", "t2"], %{
               "type" => "array",
               "of" => [%{"type" => "string"}]
             }) ==
               "fixture, t2"

      assert FieldText.show([1, 2], %{}) == "1, 2"
      assert FieldText.show([], %{"type" => "array"}) == "—"
    end

    test "an object is a Label: value line per field, the schema's titles and order first" do
      seo = %{
        "_type" => "seo",
        "metaTitle" => "Post 26",
        "metaDescription" => "Fixture SEO.",
        "extra_note" => "x"
      }

      field = %{
        "type" => "object",
        "fields" => [
          %{"name" => "metaTitle", "title" => "Meta title"},
          %{"name" => "metaDescription", "title" => "Meta description"}
        ]
      }

      assert FieldText.show(seo, field) ==
               "Meta title: Post 26\nMeta description: Fixture SEO.\nExtra note: x"

      # Without the schema's fields, the keys are the labels.
      assert FieldText.show(%{"metaTitle" => "T"}, %{}) == "Meta title: T"
      # A list of objects: a line each.
      assert FieldText.show([
               %{"_key" => "a", "label" => "One"},
               %{"_key" => "b", "label" => "Two"}
             ]) ==
               "Label: One\nLabel: Two"
    end

    test "a date is the workspace's day; a date-time is a marker the pane prints with its time" do
      assert FieldText.show("2026-09-27", %{"type" => "date"}) == "27.09.2026"

      shown = FieldText.show("2026-09-27T09:00:00Z", %{"type" => "datetime"})

      assert [{:date_time, "2026-09-27T09:00:00Z", "27.09.2026"}] =
               Barkpark.Content.PreviewText.split_date_times(shown)

      # Not a date after all: as it is.
      assert FieldText.show("soon", %{"type" => "datetime"}) == "soon"
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
            %{"name" => "body", "title" => "Body", "type" => "richText"},
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "array",
              "of" => [%{"type" => "string"}]
            },
            %{
              "name" => "seo",
              "title" => "SEO",
              "type" => "object",
              "fields" => [%{"name" => "metaTitle", "title" => "Meta title", "type" => "string"}]
            },
            %{"name" => "featured", "title" => "Featured", "type" => "boolean"},
            %{"name" => "publishedAt", "title" => "Published at", "type" => "datetime"}
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
          "content" => %{
            "author" => %{"_ref" => author, "_type" => "reference"},
            "body" => @body,
            "tags" => ["fixture", "t2"],
            "seo" => %{"_type" => "seo", "metaTitle" => "Post 26"},
            "featured" => false,
            "publishedAt" => "2026-09-27T09:00:00Z"
          }
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
    assert has_element?(view, pane <> " dd", "fixture, t2")
    assert has_element?(view, pane <> " dd", "Meta title: Post 26")
    assert has_element?(view, pane <> " dd", "No")

    # A date-time with its time, as the editor's datetime field: the server
    # says UTC; bp-desk.js shows it in the viewer's zone when it is added, and
    # no patch writes the UTC text back over that.
    at =
      pane <>
        ~s( dd time[data-desk-at][datetime="2026-09-27T09:00:00Z"][phx-update="ignore"][phx-mounted])

    assert has_element?(view, at, "27.09.2026 09:00 UTC")
    refute has_element?(view, pane <> " dd time[data-preview-day]")

    refute has_element?(view, pane <> " dd", "[")
    refute has_element?(view, pane <> " dd", "{")
  end
end
