defmodule BarkparkWeb.Studio.DeskFieldPasteTest do
  @moduledoc """
  "Paste field" on the desk (`Desk.FieldActions`, `Handlers.FieldPaste`), as
  the TanStack Studio's (`clipboard.ts` `transfer`): the clipboard's item is
  read against the target field's schema and saved as a typed edit of that
  one field. Every other stored value stays byte-identical. A copy that does
  not fit, a kind that cannot be pasted and a forged item are refused in
  words and nothing is written.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.Handlers.FieldPaste

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @toast "desk:field-toast"
  @incompatible "Source and target schema types are not compatible"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "fpaste_#{n}"
    author = "fpauthor_#{n}"
    other = "fpother_#{n}"
    f = fn name, t, extra -> Map.merge(%{"name" => name, "title" => name, "type" => t}, extra) end

    for name <- [author, other] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => "public",
            "fields" => [f.("title", "string", %{})]
          },
          @dataset
        )
    end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Paste #{type}",
          "visibility" => "public",
          "fields" => [
            f.("title", "string", %{}),
            f.("excerpt", "text", %{}),
            f.("count", "number", %{}),
            f.("flag", "boolean", %{}),
            f.("off", "boolean", %{}),
            f.("when", "datetime", %{}),
            f.("choice", "select", %{"options" => ["a", "b", "c"]}),
            f.("reviewer", "reference", %{"refType" => author}),
            f.("cover", "image", %{}),
            f.("cta", "composite", %{
              "fields" => [
                %{"name" => "url", "type" => "string"},
                %{"name" => "label", "type" => "string"}
              ]
            }),
            f.("tags", "arrayOf", %{"of" => [%{"type" => "string"}]}),
            f.("links", "arrayOf", %{
              "of" => [
                %{
                  "type" => "composite",
                  "fields" => [
                    %{"name" => "title", "type" => "string"},
                    %{"name" => "url", "type" => "string"}
                  ]
                }
              ]
            }),
            f.("box", "composite", %{
              "fields" => [
                %{"name" => "kind", "type" => "select", "options" => ["url", "internal"]},
                %{"name" => "label", "type" => "string"}
              ]
            }),
            f.("boxes", "arrayOf", %{
              "of" => [
                %{
                  "type" => "composite",
                  "fields" => [
                    %{"name" => "kind", "type" => "select", "options" => ["url", "internal"]},
                    %{"name" => "label", "type" => "string"}
                  ]
                }
              ]
            }),
            f.("level", "select", %{"options" => [1, 2, 3]}),
            f.("outer", "composite", %{
              "fields" => [
                %{
                  "name" => "inner",
                  "type" => "composite",
                  "fields" => [%{"name" => "url", "type" => "string"}]
                },
                %{"name" => "note", "type" => "string"}
              ]
            }),
            f.("body", "richText", %{}),
            f.("fixed", "string", %{
              "readOnly" => %{"field" => "choice", "operator" => "eq", "value" => "b"}
            }),
            f.("absent", "string", %{}),
            f.("hidden", "string", %{
              "visibleWhen" => %{"field" => "excerpt", "operator" => "eq", "value" => "show it"}
            })
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(author, %{"doc_id" => "fpa-#{n}", "title" => "Ada"}, @dataset)

    {:ok, _} =
      Content.create_document(
        other,
        %{"doc_id" => "fpo-#{n}", "title" => "Not an author"},
        @dataset
      )

    id = "fpaste-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Target",
          "excerpt" => "Old excerpt",
          "count" => 7,
          "flag" => false,
          "off" => false,
          "when" => "2026-01-02T03:04:00Z",
          "choice" => "b",
          "cover" => %{"url" => "/media/files/x.png", "assetId" => "asset-1", "alt" => "X"},
          "cta" => %{"url" => "https://old.test", "label" => "Old"},
          "tags" => ["one", "two"],
          "links" => [%{"_key" => "l1", "title" => "Docs", "url" => "https://docs.test"}],
          "fixed" => "locked while choice is b"
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-fpaste-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-fpaste", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     id: id,
     author: "fpa-#{n}",
     other: "fpo-#{n}",
     author_type: author,
     desk: "#{root}/_desk/#{type};#{id}"}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # Barkpark's own copy, as `FieldClip.field_copy/4` writes it.
  defp clip(sig, value, extra \\ %{}) do
    field = Map.merge(%{"name" => "from", "sig" => sig, "value" => value}, extra)

    Jason.encode!(%{
      "type" => "sanityClipboardItem",
      "isDocument" => false,
      "schemaTypeName" => "x",
      "value" => value,
      "barkpark" => %{"kind" => "field", "field" => field}
    })
  end

  defp paste(view, name, clip),
    do: render_hook(view, "desk-field-paste", %{"field" => name, "clip" => clip})

  # The stored document the editor writes: its draft once there is one.
  defp stored(c) do
    case Content.get_document(DraftId.draft_id(c.id), c.type, @dataset) do
      {:ok, draft} -> draft
      _ -> elem(Content.get_document(c.id, c.type, @dataset), 1)
    end
  end

  defp snapshot(c) do
    doc = stored(c)
    Map.put(doc.content, "title", doc.title)
  end

  # Pastes, then says what the paste changed: `{field => {before, after}}`.
  defp changes(c, view, name, clip) do
    before = snapshot(c)
    paste(view, name, clip)
    now = snapshot(c)

    for key <- Enum.uniq(Map.keys(before) ++ Map.keys(now)),
        Map.fetch(before, key) != Map.fetch(now, key),
        into: %{},
        do: {key, {before[key], now[key]}}
  end

  defp refused(c, view, name, clip, why) do
    assert changes(c, view, name, clip) == %{}, "#{name} was written"

    assert_push_event(view, @toast, %{
      tone: "critical",
      title: "Invalid clipboard item",
      description: ^why
    })
  end

  describe "a paste writes the one field and nothing else" do
    test "text into the title, and the form shows it", c do
      view = desk(c)

      assert changes(c, view, "title", clip("string", "Short excerpt for post 22.")) ==
               %{"title" => {"Target", "Short excerpt for post 22."}}

      assert view |> element(~s(#{@form} input[id="title"])) |> render() =~
               ~s(value="Short excerpt for post 22.")

      refute_push_event(view, @toast, _, 50)
    end

    test "each scalar kind", c do
      view = desk(c)

      assert changes(c, view, "excerpt", clip("string", "New")) == %{
               "excerpt" => {"Old excerpt", "New"}
             }

      assert changes(c, view, "count", clip("number", 3)) == %{"count" => {7, 3}}
      assert changes(c, view, "count", clip("number", 2.5)) == %{"count" => {3, 2.5}}
      assert changes(c, view, "flag", clip("boolean", true)) == %{"flag" => {false, true}}
      assert changes(c, view, "flag", clip("boolean", false)) == %{"flag" => {true, false}}
      assert changes(c, view, "choice", clip("string", "c")) == %{"choice" => {"b", "c"}}
      # A field with nothing stored takes its first value.
      assert changes(c, view, "absent", clip("string", "Now here")) == %{
               "absent" => {nil, "Now here"}
             }
    end

    # TanStack's isEmpty does not count "" as empty: it pastes, as a clear.
    test "a copied empty text clears the text it is pasted into", c do
      view = desk(c)

      # As a typed clear of that field is stored: the key goes.
      assert changes(c, view, "excerpt", clip("string", "")) ==
               %{"excerpt" => {"Old excerpt", nil}}
    end

    # The form buffer takes the paste as it takes a typed edit (`PostedEdits`):
    # the page draws the pasted value, so the next change anywhere posts it,
    # not the value from before the paste.
    test "a keystroke elsewhere after a paste does not write the old value back", c do
      view = desk(c)
      paste(view, "title", clip("string", "Pasted title"))
      paste(view, "count", clip("number", 41))

      view |> form("#editor-form") |> render_change(%{"doc" => %{"excerpt" => "Typed after"}})
      now = snapshot(c)

      assert now["excerpt"] == "Typed after"
      assert now["title"] == "Pasted title"
      assert now["count"] == 41
    end

    test "a number pastes into a text as its digits (Sanity's transferValue)", c do
      view = desk(c)
      assert changes(c, view, "title", clip("number", 3)) == %{"title" => {"Target", "3"}}

      assert changes(c, view, "excerpt", clip("number", 3.0)) == %{
               "excerpt" => {"Old excerpt", "3"}
             }

      assert changes(c, view, "excerpt", clip("number", 2.5)) == %{"excerpt" => {"3", "2.5"}}
    end

    test "a reference to a document of the field's type, stored as the canonical object", c do
      view = desk(c)
      sig = "reference:#{c.author_type}"
      ref = %{"_ref" => c.author, "_type" => "reference", "_weak" => true, "_key" => "evil"}

      assert changes(c, view, "reviewer", clip(sig, ref)) ==
               %{"reviewer" => {nil, %{"_ref" => c.author, "_type" => "reference"}}}
    end

    test "an object keeps its declared subfields; underscore keys are dropped", c do
      view = desk(c)
      sig = "object:label=string,url=string"
      value = %{"_type" => "evil", "_key" => "k", "url" => "https://new.test", "label" => "New"}

      assert changes(c, view, "cta", clip(sig, value)) ==
               %{
                 "cta" =>
                   {%{"url" => "https://old.test", "label" => "Old"},
                    %{"url" => "https://new.test", "label" => "New"}}
               }
    end

    # The save path's own rule for an edited object: a stored subfield the
    # post does not carry is kept. A paste is such a post.
    test "an object that lacks a subfield leaves that subfield's stored value", c do
      view = desk(c)
      only = clip("object:label=string,url=string", %{"url" => "https://only.test"})

      assert changes(c, view, "cta", only) ==
               %{
                 "cta" =>
                   {%{"url" => "https://old.test", "label" => "Old"},
                    %{"url" => "https://only.test", "label" => "Old"}}
               }
    end

    test "a list of texts replaces; a text or a number is added as one more row", c do
      view = desk(c)

      assert changes(c, view, "tags", clip("array:string", ["x", "y", "z"])) ==
               %{"tags" => {["one", "two"], ["x", "y", "z"]}}

      assert changes(c, view, "tags", clip("string", "more")) ==
               %{"tags" => {["x", "y", "z"], ["x", "y", "z", "more"]}}

      assert changes(c, view, "tags", clip("number", 4)) ==
               %{"tags" => {["x", "y", "z", "more"], ["x", "y", "z", "more", "4"]}}
    end

    test "a list of objects: every row gets a fresh _key, never the copied one", c do
      view = desk(c)
      sig = "array:object:title=string,url=string"

      rows = [
        %{"_key" => "l1", "_type" => "evil", "title" => "A", "url" => "https://a.test"},
        %{"_key" => "l1", "title" => "B"}
      ]

      assert %{"links" => {[%{"_key" => "l1"}], [first, second]}} =
               changes(c, view, "links", clip(sig, rows))

      assert Map.delete(first, "_key") == %{"title" => "A", "url" => "https://a.test"}
      assert Map.delete(second, "_key") == %{"title" => "B"}
      assert first["_key"] =~ ~r/^[0-9a-f]{12}$/
      assert second["_key"] =~ ~r/^[0-9a-f]{12}$/
      assert first["_key"] != second["_key"]

      # A copied row (Sanity's item copy: a one-row list, `append`) is added.
      one = [%{"_key" => first["_key"], "title" => "C"}]

      assert %{"links" => {[^first, ^second], [^first, ^second, third]}} =
               changes(c, view, "links", clip(sig, one, %{"append" => true}))

      assert third["title"] == "C"
      refute third["_key"] in [first["_key"], second["_key"]]
    end

    test "a copy made by Copy field in one document pastes into another's", c do
      view = desk(c)

      view
      |> element(~s(#{@form} #field-actions-menu button[data-desk-field-copy]))
      |> render_click(%{"field" => "excerpt"})

      assert_push_event(view, "desk:field-copied", %{json: json})

      assert changes(c, view, "title", json) == %{"title" => {"Target", "Old excerpt"}}
    end

    test "Sanity's own item (no Barkpark copy inside) pastes by its schema type", c do
      view = desk(c)

      item = %{
        "type" => "sanityClipboardItem",
        "isDocument" => false,
        "schemaTypeName" => "text",
        "valuePath" => ["x"],
        "value" => "From Sanity"
      }

      assert changes(c, view, "title", Jason.encode!(item)) == %{
               "title" => {"Target", "From Sanity"}
             }
    end
  end

  describe "a paste that does not fit is refused in words and nothing is written" do
    test "text into a number, a number into a boolean", c do
      view = desk(c)
      refused(c, view, "count", clip("string", "Short"), @incompatible)
      refused(c, view, "flag", clip("number", 1), @incompatible)
    end

    test "a select names the value it refuses", c do
      view = desk(c)
      refused(c, view, "choice", clip("string", "3"), ~s(Value "3" is not allowed in "a,b,c"))
    end

    # Review of #26467: a select took any string once it sat inside an object.
    test "a select takes only its options at every depth: field, subfield, list row", c do
      view = desk(c)
      why = ~s(Value "evil" is not allowed in "url,internal")
      box = "object:kind=string,label=string"

      refused(
        c,
        view,
        "choice",
        clip("string", "evil"),
        ~s(Value "evil" is not allowed in "a,b,c")
      )

      refused(c, view, "box", clip(box, %{"kind" => "evil", "label" => "L"}), why)

      refused(
        c,
        view,
        "boxes",
        clip("array:" <> box, [%{"kind" => "url"}, %{"kind" => "evil"}]),
        why
      )

      refused(c, view, "box", clip(box, %{"kind" => 7}), @incompatible)

      assert changes(c, view, "box", clip(box, %{"kind" => "internal", "label" => "L"})) ==
               %{"box" => {nil, %{"kind" => "internal", "label" => "L"}}}

      assert %{"boxes" => {nil, [%{"kind" => "url", "_key" => _}]}} =
               changes(c, view, "boxes", clip("array:" <> box, [%{"kind" => "url"}]))
    end

    # Re-review of #26467: the form offers "2"; the paste refused it.
    test "a select whose options are numbers takes the values the form offers", c do
      view = desk(c)
      assert changes(c, view, "level", clip("string", "2")) == %{"level" => {nil, "2"}}
      refused(c, view, "level", clip("string", "9"), ~s(Value "9" is not allowed in "1,2,3"))
    end

    test "a number no field should hold: 10^400, and a float past the range", c do
      view = desk(c)
      why = "The number is too large to paste"

      refused(c, view, "count", clip("number", Integer.pow(10, 400)), why)
      refused(c, view, "count", clip("number", -Integer.pow(10, 400)), why)
      refused(c, view, "title", clip("number", Integer.pow(10, 400)), why)
      refused(c, view, "count", clip("number", 9_007_199_254_740_992), why)

      assert changes(c, view, "count", clip("number", 9_007_199_254_740_991)) ==
               %{"count" => {7, 9_007_199_254_740_991}}

      # JSON has no infinity; a literal past a float's range is not a number at all.
      raw = String.replace(clip("number", 12_345), "12345", "1e999")
      assert changes(c, view, "count", raw) == %{}
      assert_push_event(view, @toast, %{title: _})
    end

    test "a reference of another type, to no document, or to a document of another type", c do
      view = desk(c)
      sig = "reference:#{c.author_type}"

      refused(
        c,
        view,
        "reviewer",
        clip("reference:post", %{"_ref" => c.author}),
        ~s(References of type "post" is not allowed in reference field that accepts types "#{c.author_type}")
      )

      for id <- ["no-such-doc", c.other, "bad id!", ""] do
        assert changes(c, view, "reviewer", clip(sig, %{"_ref" => id})) == %{}, id
        assert_push_event(view, @toast, %{tone: "critical", title: "Invalid clipboard item"})
      end
    end

    test "a list of another member type", c do
      view = desk(c)

      refused(
        c,
        view,
        "tags",
        clip("array:object:title=string", [%{"_type" => "link", "title" => "A"}]),
        ~s(Value of type "link" is not allowed in this array field)
      )
    end

    test "the kinds that do not paste: image, rich text, date-time", c do
      view = desk(c)

      for {name, sig, value, type} <- [
            {"cover", "image", %{"url" => "/media/files/y.png", "assetId" => "asset-2"}, "image"},
            {"body", "richText", [%{"_type" => "block", "children" => []}], "richText"},
            {"when", "datetime", "2027-05-06T07:08:00Z", "datetime"}
          ] do
        refused(
          c,
          view,
          name,
          clip(sig, value),
          ~s(A field of type "#{type}" cannot be pasted into)
        )
      end
    end

    test "an item that lies about itself: the field's schema decides, not the item", c do
      view = desk(c)
      refused(c, view, "title", clip("string", %{"evil" => true}), @incompatible)
      refused(c, view, "title", clip("string", ["a"]), @incompatible)
      refused(c, view, "count", clip("number", "7"), @incompatible)
      refused(c, view, "flag", clip("boolean", "true"), @incompatible)
      refused(c, view, "tags", clip("array:string", ["ok", %{"x" => 1}]), @incompatible)
      refused(c, view, "tags", clip("array:string", "not a list"), @incompatible)

      refused(
        c,
        view,
        "cta",
        clip("object:label=string,url=string", %{"url" => "u", "extra" => "x"}),
        @incompatible
      )

      refused(
        c,
        view,
        "cta",
        clip("object:label=string,url=string", %{"url" => %{"deep" => 1}}),
        @incompatible
      )

      refused(
        c,
        view,
        "links",
        clip("array:object:title=string,url=string", [%{"title" => 1}]),
        @incompatible
      )

      rows = for i <- 1..501, do: "row #{i}"
      refused(c, view, "tags", clip("array:string", rows), @incompatible)
    end

    test "an item over the size cap", c do
      view = desk(c)
      big = clip("string", String.duplicate("x", 262_144))
      assert changes(c, view, "title", big) == %{}
      assert_push_event(view, @toast, %{tone: "critical", title: "Invalid clipboard item"})
    end
  end

  describe "nothing to paste" do
    test "no copied field on the clipboard: other text, a copied document, an empty value", c do
      view = desk(c)

      for clip <- [
            "plain words",
            "{}",
            Jason.encode!(%{"type" => "other"}),
            Jason.encode!(%{
              "type" => "sanityClipboardItem",
              "isDocument" => true,
              "schemaTypeName" => "post",
              "value" => %{"title" => "Doc"}
            }),
            Jason.encode!(%{
              "type" => "sanityClipboardItem",
              "barkpark" => %{"kind" => "document", "docType" => "post", "fields" => []}
            }),
            clip("array:string", []),
            clip("object:label=string,url=string", %{"_key" => "k"}),
            clip("string", nil)
          ] do
        assert changes(c, view, "title", clip) == %{}
        assert_push_event(view, @toast, %{tone: "default", title: "Nothing to paste"})
      end
    end

    # Review of #26467: these wrote nothing and said nothing.
    test "an object with no subfield to write: an empty one, or one holding only nulls", c do
      view = desk(c)
      sig = "object:label=string,url=string"

      for value <- [
            %{},
            %{"url" => nil, "label" => nil},
            %{"_type" => "x", "_key" => "k", "url" => nil}
          ] do
        assert changes(c, view, "cta", clip(sig, value)) == %{}
        assert_push_event(view, @toast, %{tone: "default", title: "Nothing to paste"})
      end
    end

    # Re-review of #26467: wrote nothing and said nothing.
    test "an object whose only content is an empty object inside it", c do
      view = desk(c)
      sig = "object:inner=object:url=string,note=string"

      for value <- [
            %{"inner" => %{}},
            %{"inner" => %{"url" => nil}},
            %{"inner" => %{"_key" => "k"}}
          ] do
        assert changes(c, view, "outer", clip(sig, value)) == %{}
        assert_push_event(view, @toast, %{tone: "default", title: "Nothing to paste"})
      end

      assert changes(c, view, "outer", clip(sig, %{"inner" => %{}, "note" => "N"})) ==
               %{"outer" => {nil, %{"note" => "N"}}}
    end

    test "an event sent by hand with no field, no item or an unknown field does nothing", c do
      view = desk(c)
      before = snapshot(c)

      for params <- [
            %{},
            %{"field" => "title"},
            %{"field" => "nope", "clip" => clip("string", "x")},
            %{"field" => 1, "clip" => 2}
          ] do
        render_hook(view, "desk-field-paste", params)
      end

      assert snapshot(c) == before
      refute_push_event(view, @toast, _, 50)
    end
  end

  describe "a field that cannot be edited" do
    test "hidden by its visibleWhen: a paste sent by hand writes nothing", c do
      view = desk(c)
      assert changes(c, view, "hidden", clip("string", "forced")) == %{}
      refute_push_event(view, @toast, _, 50)
    end

    test "locked by its rule: Paste is off in the menu and a paste sent by hand writes nothing",
         c do
      view = desk(c)

      # The button says so; bp-desk.js turns the one menu's Paste off for it.
      assert has_element?(view, ~s(#{@form} button[data-desk-field="fixed"][data-desk-paste-off]))

      assert has_element?(
               view,
               ~s|#{@form} button[data-desk-field="title"]:not([data-desk-paste-off])|
             )

      assert changes(c, view, "fixed", clip("string", "forced")) == %{}
      refute_push_event(view, @toast, _, 50)
    end
  end

  describe "FieldPaste.plan/4" do
    test "answers with the params a typed edit of that field posts" do
      field = %{"name" => "title", "type" => "string"}

      assert FieldPaste.plan(field, "old", clip("string", "new"), fn _, _ -> false end) ==
               {:save, %{"doc" => %{"title" => "new"}, "_target" => ["doc", "title"]}}

      assert FieldPaste.plan(field, "old", "nope", fn _, _ -> false end) == :nothing

      assert FieldPaste.plan(%{"type" => "string"}, "old", clip("string", "new"), fn _, _ ->
               true
             end) == :nothing
    end
  end
end
