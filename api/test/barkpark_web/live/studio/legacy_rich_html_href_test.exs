defmodule BarkparkWeb.Studio.LegacyRichHtmlHrefTest do
  @moduledoc """
  task-b11051e39ebe3a30 (found in the review of #28371): a richText field
  whose stored value is an HTML string, not Portable Text, was handed to the
  desk editor as it is stored, so a `javascript:` anchor written by the API
  or an import reached the editor's page.

  The editor now draws the string with every `<a href>` judged by
  `Content.LinkHref`, as the Portable Text path is: a refused address is drawn
  as its words. The hidden input keeps the stored string, so an edit of
  another field keeps the stored bytes.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Components.Fields.LocalizedTextField

  @dataset "production"

  # The addresses a browser follows as script or a data page, in the
  # spellings a raw-text check misses.
  @refused [
    ~s|<a href="javascript:alert(1)">x</a>|,
    ~s|<a href="JaVaScRiPt:alert(1)">x</a>|,
    ~s|<a href=" java\tscript:alert(1)">x</a>|,
    ~s|<a href="javascript&#58;alert(1)">x</a>|,
    ~s|<a href="&#106;avascript:alert(1)">x</a>|,
    ~s|<a href='vbscript:msgbox(1)'>x</a>|,
    ~s|<a href=javascript:alert(1)>x</a>|,
    ~s|<a href="data:text/html,<script>alert(1)</script>">x</a>|,
    ~s|<a href="data:image/svg+xml,<svg onload=alert(1)>">x</a>|,
    ~s|<a title=">" href="data:image/png;base64,AAAA">x</a>|,
    ~s|<a/href="javascript:alert(1)">x</a>|,
    ~s|<a id="i"href="javascript:alert(1)">x</a>|,
    ~s|<A HREF="javascript:alert(1)">x</A>|,
    ~s|<a hr<!-- -->ef="data:image/png;base64,AAAA">x</a>|
  ]

  @kept [
    {~s|<a href="https://x.example/a?b=1&amp;c=2">y</a>|, "https://x.example/a?b=1&c=2"},
    {~s|<a href="mailto:a@x.example">y</a>|, "mailto:a@x.example"},
    {~s|<a href="/p/1">y</a>|, "/p/1"},
    {~s|<a href="#internal:doc-1">y</a>|, "#internal:doc-1"}
  ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "legacyrt_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Legacy rich text #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "legacyrt-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "legacyrt", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  # The body goes straight into storage: a row an import or an older client
  # wrote before the write path refused a script address in an HTML string
  # (task-5272840f43511e20). A write now refuses a new one.
  defp doc!(c, body) do
    id = "legacyrt-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{
          "doc_id" => id,
          "title" => "T",
          "content" => %{"body" => "<p>seed</p>", "notes" => "n0"}
        },
        @dataset
      )

    import Ecto.Query

    {1, _} =
      Barkpark.Repo.update_all(
        from(d in Barkpark.Content.Document, where: d.doc_id == ^("drafts." <> id)),
        set: [content: %{"body" => body, "notes" => "n0"}]
      )

    id
  end

  defp open(c, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  # The HTML the editor puts in its page: its `value` attribute, parsed as a
  # browser parses it.
  defp editor_html(html) do
    [value] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("bp-rich-text-editor") |> attr("value")

    LazyHTML.from_fragment(value)
  end

  defp attr(nodes, name), do: LazyHTML.attribute(nodes, name)

  defp hidden(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s|input[type="hidden"][name="#{name}"]|)
    |> attr("value")
  end

  # What a browser would follow: the address with its control characters and
  # spaces dropped, in lower case.
  defp scheme_of(href),
    do: href |> String.replace(~r/[\x00-\x20]/, "") |> String.downcase()

  defp unsafe_hrefs(doc) do
    doc
    |> LazyHTML.query("[href]")
    |> attr("href")
    |> Enum.filter(&String.starts_with?(scheme_of(&1), ~w(javascript: vbscript: data:)))
  end

  describe "the desk editor" do
    test "draws a stored javascript: anchor without its address, and keeps the words", c do
      body = ~s|<p>see <a href="javascript:alert(1)">x</a> here</p>|
      id = doc!(c, body)
      html = render(open(c, id))

      doc = editor_html(html)
      assert unsafe_hrefs(doc) == []
      # Drawn as its words, as a refused Portable Text link is.
      assert doc |> LazyHTML.query("a[href]") |> Enum.count() == 0
      assert LazyHTML.text(doc) == "see x here"
      # The form still posts the stored string.
      assert hidden(html, "doc[body]") == [body]
    end

    test "an edit of another field keeps the stored string byte-identical", c do
      body = ~s|<p><a href="javascript:alert(1)">x</a> <img src=x onerror=alert(1)></p>|
      id = doc!(c, body)
      view = open(c, id)

      view
      |> form("[data-pane-editing] #editor-form", %{"doc" => %{"notes" => "typed"}})
      |> render_change(%{"_target" => ["doc", "notes"]})

      {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
      assert doc.content["notes"] == "typed"
      assert doc.content["body"] === body
    end

    test "an edit of the field itself keeps the refused address, inert", c do
      id = doc!(c, ~s|<p>see <a href="javascript:alert(1)">x</a></p>|)
      view = open(c, id)

      # What the editor posts after a keystroke: its drawn copy, typed into.
      [drawn] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("bp-rich-text-editor")
        |> attr("value")

      edited = String.replace(drawn, "see ", "see, typed, ")

      BarkparkWeb.EditorPost.change(view, %{
        "doc" => %{"body" => edited},
        "_target" => ["doc", "body"]
      })

      {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
      assert doc.content["body"] =~ ~s|data-refused-href="javascript:alert(1)"|
      refute doc.content["body"] =~ ~s|href="#"|

      again = editor_html(render(open(c, id)))
      assert again |> LazyHTML.query("a") |> attr("data-refused-href") == ["javascript:alert(1)"]
      assert unsafe_hrefs(again) == []
      assert LazyHTML.text(again) == "see, typed, x"
    end

    # task-5272840f43511e20: a post the editor did not make (devtools, a
    # scripted form) bringing a script address in is refused on save, as the
    # API's is: the row keeps what it had.
    test "a save that brings a javascript: href into the field does not store it", c do
      id = doc!(c, "<p>clean</p>")
      view = open(c, id)

      BarkparkWeb.EditorPost.change(view, %{
        "doc" => %{"body" => ~s|<p>see <a href="javascript:alert(3)">x</a></p>|},
        "_target" => ["doc", "body"]
      })

      {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
      refute doc.content["body"] =~ "javascript:"
      assert doc.content["body"] == "<p>clean</p>"
      # The writer is told why, at the field.
      assert render(view) =~ "link address not allowed"
    end

    test "a https anchor stays a link", c do
      id = doc!(c, ~s|<p><a href="https://x.example/a">y</a></p>|)
      doc = editor_html(render(open(c, id)))

      assert doc |> LazyHTML.query("a") |> attr("href") == ["https://x.example/a"]
    end
  end

  describe "the drawn string" do
    defp drawn(body) do
      render_component(&BarkparkWeb.Components.FieldInputs.input/1, %{
        field: %{"type" => "richText", "name" => "body"},
        editor_form: %{"body" => body}
      })
      |> editor_html()
    end

    for {payload, i} <- Enum.with_index(@refused) do
      @payload payload
      test "refused #{i}: #{inspect(payload)} reaches the page with no such href" do
        doc = drawn("<p>" <> @payload <> "</p>")
        assert unsafe_hrefs(doc) == []
        assert LazyHTML.text(doc) =~ "x"
      end
    end

    for {{payload, href}, i} <- Enum.with_index(@kept) do
      @payload payload
      @href href
      test "kept #{i}: #{inspect(payload)} stays a link" do
        doc = drawn("<p>" <> @payload <> "</p>")
        assert doc |> LazyHTML.query("a") |> attr("href") == [@href]
      end
    end

    test "an event handler does not reach the page" do
      for payload <- [
            ~s|<img src=x onerror=alert(1)>|,
            ~s|<img src="x"onerror="alert(1)">|,
            ~s|<img/onerror=alert(1) src=x>|,
            ~s|<p ONCLICK="alert(1)">x</p>|
          ] do
        doc = drawn("<div>" <> payload <> "</div>")
        names = doc |> LazyHTML.query("*") |> LazyHTML.attributes() |> List.flatten()
        assert Enum.filter(names, fn {k, _} -> String.starts_with?(k, "on") end) == [], payload
      end
    end

    # #28402 review B1: a handler between the letters of a tag name joined
    # the name back together after the regex scrub's element pass.
    test "a tag name split by a handler does not come back as the element" do
      for {payload, tag} <- [
            {~s|<me onx=""ta http-equiv="refresh" content="0;url=https://e.example/">|, "meta"},
            {~s|<ifr onx=""ame srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;">|, "iframe"},
            {~s|<ifr onx=""ame src="https://e.example/" style="position:fixed;inset:0">|,
             "iframe"},
            {~s|<ba onx=""se href="https://e.example/">|, "base"},
            {~s|<fo onx=""rm action="https://e.example/">|, "form"},
            {~s|<obj onx=""ect data="https://e.example/">|, "object"}
          ] do
        doc = drawn("<p>a</p>" <> payload)
        assert doc |> LazyHTML.query(tag) |> Enum.count() == 0, payload
        assert doc |> LazyHTML.query("[http-equiv], [srcdoc], [action]") |> Enum.count() == 0
      end
    end

    # S1 / N2: the copy is drawn inside #editor-form, so a stored control
    # would post a value for another field.
    test "no form control is drawn, so nothing stored adds to the form's post" do
      doc =
        drawn(
          ~s|<p>body<input name="doc[title]" value="pwned"><button name="x" value="y">b</button>| <>
            ~s|<label for="title">l</label></p><fieldset><legend>g</legend>f</fieldset>|
        )

      assert doc
             |> LazyHTML.query("input, button, label, fieldset, legend, select, textarea, [name]")
             |> Enum.count() == 0

      assert LazyHTML.text(doc) == "bodyblgf"
    end

    # S2: a stored style could draw a link over the whole Studio.
    test "no style is drawn" do
      doc =
        drawn(
          ~s|<p><a href="https://e.example/" style="position:fixed;inset:0;z-index:99999">Sign in</a></p>| <>
            ~s|<p style="color:#ff0000">t</p>|
        )

      assert doc |> LazyHTML.query("[style]") |> Enum.count() == 0
      assert doc |> LazyHTML.query("a") |> attr("href") == ["https://e.example/"]
    end

    # M1: the refused address is kept, inert, not replaced by "#".
    test "a refused link keeps its address as data-refused-href, and draws no href" do
      doc = drawn(~s|<p><a href="javascript:alert(1)">x</a></p>|)
      assert doc |> LazyHTML.query("a") |> attr("data-refused-href") == ["javascript:alert(1)"]
      assert doc |> LazyHTML.query("[href]") |> Enum.count() == 0
    end

    # #28402 review r2, S1: inside #editor-form a stored name or id shadows
    # the form's, the document's or a later field's own names.
    test "no id or name is drawn" do
      for payload <- [
            ~s|<img name="getAttribute" src="x"><img id="submit" src="x"><img name="elements" src="x">|,
            ~s|<img name="querySelector" src="x"><img name="getElementById" src="x">|,
            ~s|<span id="bp-rt-hidden-body2">clob</span>|
          ] do
        doc = drawn("<p>a" <> payload <> "</p>")
        assert doc |> LazyHTML.query("[id], [name]") |> Enum.count() == 0, payload
      end
    end

    test "the reader moves a stored id into the body's namespace and drops an img's name" do
      assert Barkpark.PortableDoc.HtmlSanitizer.sanitize(~s|<p id="a"><img name="n" src="x"></p>|) ==
               ~s|<p id="bp-anchor-a"><img src="x"></p>|
    end

    # S2: the editor's strikethrough writes <strike>; a redraw kept only the
    # words, and the next edit stored them without it.
    test "the editor's own strikethrough is kept, byte for byte" do
      for body <- [~s|<strike>x</strike>|, ~s|<p>a <strike>more z</strike> b</p>|] do
        assert Barkpark.Content.LegacyRichHtml.for_editor(body) == body
        assert Barkpark.PortableDoc.HtmlSanitizer.sanitize(body) == body
      end
    end

    test "the drawn copy is a fixed point: drawn again it is the same" do
      for body <- [
            ~s|<p><a href="javascript:alert(1)">x</a> <input name="a"> <a href="https://e.example/">y</a></p>|,
            ~s|<ul><li>a<div><aside><li>b</li></aside></div></li></ul>|
          ] do
        once = Barkpark.Content.LegacyRichHtml.for_editor(body)
        assert Barkpark.Content.LegacyRichHtml.for_editor(once) == once
      end
    end

    test "the reader drops data-refused-href: it is the editor's mark only" do
      assert Barkpark.PortableDoc.HtmlSanitizer.sanitize(
               ~s|<p><a data-refused-href="javascript:alert(1)">x</a></p>|
             ) == "<p><a>x</a></p>"
    end

    test "a localized rich row draws the same way, and posts the stored string" do
      body = ~s|<p><a href="javascript:alert(1)">x</a></p>|

      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: %Barkpark.Content.SchemaDefinition.Field{
            name: "cap",
            type: "localizedText",
            title: "Cap",
            languages: ["nob"],
            format: :rich,
            fallback_chain: ["nob"]
          },
          value: %{"nob" => body}
        })

      assert unsafe_hrefs(editor_html(html)) == []

      assert [^body] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("input[data-lang]")
               |> attr("value")
    end
  end
end
