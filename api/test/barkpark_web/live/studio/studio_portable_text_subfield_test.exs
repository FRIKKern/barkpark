defmodule BarkparkWeb.Studio.StudioPortableTextSubfieldTest do
  @moduledoc """
  Portable Text in a richText field opens in the Classic rich-text editor and
  saves back as Portable Text: at the top level of a document
  (task-5fe67fc396077304), in the body of a page-builder item and in a custom
  block's dialog (task-eba86f7ba252cb20).

  The schemas, text, ids and keys are synthetic. Each test edits one paragraph
  and reads back the same blocks, keys, marks and mark definitions except the
  edited text.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.PortableText
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  @schemas [
    %{
      "name" => "ptCallout",
      "kind" => "object",
      "title" => "Callout",
      "fields" => [
        %{"name" => "label", "type" => "string"},
        %{"name" => "text", "type" => "richText"}
      ]
    },
    %{
      "name" => "ptSection",
      "kind" => "object",
      "title" => "Text section",
      "fields" => [
        %{"name" => "heading", "type" => "string"},
        %{"name" => "body", "type" => "richText"},
        %{"name" => "intro", "type" => "richText"}
      ]
    },
    %{
      "name" => "ptLanding",
      "title" => "Landing",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{
          "name" => "sections",
          "type" => "arrayOf",
          "ordered" => true,
          "of" => [%{"name" => "ptSection", "type" => "ptSection"}]
        }
      ]
    },
    %{
      "name" => "ptEssay",
      "title" => "Essay",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "body", "type" => "richText"},
        %{"name" => "summary", "type" => "richText"}
      ]
    }
  ]

  defp span(key, text, marks \\ []),
    do: %{"_key" => key, "_type" => "span", "text" => text, "marks" => marks}

  defp para(key, children, mark_defs \\ []),
    do: %{
      "_key" => key,
      "_type" => "block",
      "style" => "normal",
      "markDefs" => mark_defs,
      "children" => children
    }

  # Marks, a link annotation and a custom block: what an editor must not lose.
  defp body(prefix) do
    [
      %{
        "_key" => prefix <> "01",
        "_type" => "block",
        "style" => "h2",
        "markDefs" => [],
        "children" => [span(prefix <> "01s0", "A synthetic heading")]
      },
      para(
        prefix <> "02",
        [
          span(prefix <> "02s0", "Plain words, then "),
          span(prefix <> "02s1", "strong words", ["strong"]),
          span(prefix <> "02s2", " and a "),
          span(prefix <> "02s3", "link", [prefix <> "m1"])
        ],
        [%{"_key" => prefix <> "m1", "_type" => "link", "href" => "https://example.com/a"}]
      ),
      para(prefix <> "03", [span(prefix <> "03s0", "The paragraph the test edits.")]),
      %{"_key" => prefix <> "04", "_type" => "ptCallout", "label" => "Kept as stored"},
      para(prefix <> "05", [
        span(prefix <> "05s0", "A last paragraph with "),
        span(prefix <> "05s1", "emphasis", ["em"])
      ])
    ]
  end

  defp edited(blocks, key, text) do
    Enum.map(blocks, fn
      %{"_key" => ^key, "children" => [first | _]} = b ->
        %{b | "children" => [%{first | "text" => text}]}

      b ->
        b
    end)
  end

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "ptsub-#{suffix}", name: "PT subfields"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "ptsub-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "ptsub", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    for s <- @schemas, do: {:ok, _} = Content.upsert_schema(s, @dataset, scope)

    sections = [
      %{
        "_key" => "aa00c0de0001",
        "_type" => "ptSection",
        "heading" => "First",
        "body" => body("aa")
      },
      %{
        "_key" => "bb00c0de0002",
        "_type" => "ptSection",
        "heading" => "Second",
        "body" => body("bb"),
        "intro" => body("ii")
      }
    ]

    essay_body =
      List.replace_at(body("ee"), 3, %{
        "_key" => "ee04",
        "_type" => "ptCallout",
        "label" => "A callout",
        "text" => body("cc")
      })

    publish!("ptLanding", "landing-1", %{"title" => "Landing", "sections" => sections}, scope)

    publish!(
      "ptEssay",
      "essay-1",
      %{"title" => "Essay", "body" => essay_body, "summary" => body("ss")},
      scope
    )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn, ws: ws, proj: proj, scope: scope, sections: sections, essay_body: essay_body}
  end

  defp publish!(type, id, content, scope) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{
          "doc_id" => id,
          "title" => content["title"],
          "status" => "published",
          "content" => content
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document(id, type, @dataset, scope)
  end

  defp doc_path(ws, proj, type, id),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{id}"

  defp draft!(type, id, scope) do
    {:ok, doc} = Content.get_document("drafts." <> id, type, @dataset, scope)
    doc.content
  end

  describe "a richText body at the top level" do
    test "an edited paragraph saves as Portable Text; marks, links and blocks keep their bytes",
         %{conn: conn, ws: ws, proj: proj, scope: scope, essay_body: stored} do
      {:ok, view, html} = live(conn, doc_path(ws, proj, "ptEssay", "essay-1"))
      assert html =~ ~s(name="doc[body]")
      assert html =~ "bp-rich-text-editor"

      want = edited(stored, "ee03", "The paragraph after an edit.")

      view
      |> form("#editor-form")
      |> render_change(%{"doc[body]" => PortableText.to_html(want), "_target" => ["doc[body]"]})

      assert draft!("ptEssay", "essay-1", scope)["body"] == want
    end
  end

  describe "a richText field with another name at the top level" do
    test "an edit keeps the custom block and every key",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "ptEssay", "essay-1"))
      want = edited(body("ss"), "ss03", "An edited summary paragraph.")

      view
      |> form("#editor-form")
      |> render_change(%{
        "doc[summary]" => PortableText.to_html(want),
        "_target" => ["doc[summary]"]
      })

      assert draft!("ptEssay", "essay-1", scope)["summary"] == want
    end
  end

  describe "a richText body inside a page-builder item" do
    test "the body opens in the rich-text editor, not as read-only JSON",
         %{conn: conn, ws: ws, proj: proj} do
      {:ok, view, html} = live(conn, doc_path(ws, proj, "ptLanding", "landing-1"))

      assert has_element?(
               view,
               ~s([data-pt-subfield="doc[sections][1].body"] bp-rich-text-editor)
             )

      assert html =~ ~s(name="doc[sections][1].body")
      refute html =~ "stored as structured data this field&#39;s editor cannot show"
    end

    test "editing a paragraph keeps every other block, the other item and the item _key",
         %{conn: conn, ws: ws, proj: proj, scope: scope, sections: stored} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "ptLanding", "landing-1"))

      [first, second] = stored
      want_body = edited(second["body"], "bb03", "An edited paragraph in the second item.")

      view
      |> form("#editor-form")
      |> render_change(%{
        "doc[sections][1].body" => PortableText.to_html(want_body),
        "_target" => ["doc[sections][1].body"]
      })

      saved = draft!("ptLanding", "landing-1", scope)["sections"]
      assert saved == [first, %{second | "body" => want_body}]
    end

    test "a richText subfield with another name keeps its block keys on an edit",
         %{conn: conn, ws: ws, proj: proj, scope: scope, sections: stored} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "ptLanding", "landing-1"))

      [first, second] = stored
      want_intro = edited(second["intro"], "ii05", "An edited intro.")

      view
      |> form("#editor-form")
      |> render_change(%{
        "doc[sections][1].intro" => PortableText.to_html(want_intro),
        "_target" => ["doc[sections][1].intro"]
      })

      saved = draft!("ptLanding", "landing-1", scope)["sections"]
      assert saved == [first, %{second | "intro" => want_intro}]
    end

    test "an untouched body saves unchanged when another field of the item is edited",
         %{conn: conn, ws: ws, proj: proj, scope: scope, sections: stored} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "ptLanding", "landing-1"))

      view
      |> form("#editor-form", %{"doc[sections][0].heading" => "Renamed"})
      |> render_change(%{"_target" => ["doc[sections][0].heading"]})

      [first, second] = stored

      assert draft!("ptLanding", "landing-1", scope)["sections"] == [
               %{first | "heading" => "Renamed"},
               second
             ]
    end
  end

  describe "a richText field inside a custom block's dialog" do
    test "the dialog edits the block's Portable Text and the body keeps every other block",
         %{conn: conn, ws: ws, proj: proj, scope: scope, essay_body: stored} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "ptEssay", "essay-1"))

      render_hook(view, "pt-block-open", %{"field" => "body", "key" => "ee04"})

      assert has_element?(
               view,
               ~s(#bp-object-dialog [data-pt-subfield="doc[__object].text"] bp-rich-text-editor)
             )

      callout = Enum.at(stored, 3)
      want_text = edited(callout["text"], "cc05", "Edited inside the dialog.")
      name = "doc[__object].text"

      view
      |> form("#bp-object-dialog-form-ee04")
      |> render_change(%{name => PortableText.to_html(want_text), "_target" => [name]})

      # The browser's hidden input holds the editor's HTML when Save is pressed.
      view
      |> form("#bp-object-dialog-form-ee04")
      |> render_submit(%{name => PortableText.to_html(want_text)})

      refute has_element?(view, "#bp-object-dialog")

      assert draft!("ptEssay", "essay-1", scope)["body"] ==
               List.replace_at(stored, 3, %{callout | "text" => want_text})
    end
  end
end
