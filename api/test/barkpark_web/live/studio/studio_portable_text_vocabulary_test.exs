defmodule BarkparkWeb.Studio.StudioPortableTextVocabularyTest do
  @moduledoc """
  Stage S3 of the Portable Text plan: the Classic rich-text editor reads the
  field's declared vocabulary.

    * The toolbar offers the declared styles, lists and decorators
      (`data-vocabulary`). A field that declares none renders as before.
    * An annotation is made and edited in the object dialog, built from the
      fields its declaration names: `docLink.page`, `link.href` and a
      `linkAnnotation` with an `internalLink` and no `linkType`.
    * An inline object is inserted and edited in the same dialog.
    * The HTML bridge keeps every `_key`: editing one span in each declared
      shape changes only that span's `text`.

  The schemas copy the shapes of a Sanity site's rich-text types under
  made-up names; every text, id and key is made up.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.PortableText
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  # ── Vocabularies, in Sanity's array-of-blocks shape ─────────────────────

  defp styles(names), do: Enum.map(names, &%{"title" => &1, "value" => &1})
  defp decorators(names), do: Enum.map(names, &%{"title" => &1, "value" => &1})

  @link_annotation_fields [
    %{"name" => "linkType", "type" => "string"},
    %{"name" => "isExternal", "type" => "boolean"},
    %{"name" => "internalLink", "type" => "reference", "to" => [%{"type" => "ptPage"}]},
    %{"name" => "url", "type" => "string"},
    %{"name" => "openInNewTab", "type" => "boolean"},
    %{"name" => "email", "type" => "string"},
    %{"name" => "linkParams", "type" => "string"}
  ]

  @module_link_fields [
    %{"name" => "linkType", "type" => "string"},
    %{"name" => "internalLink", "type" => "reference", "to" => [%{"type" => "ptPage"}]},
    %{"name" => "url", "type" => "url"},
    %{"name" => "email", "type" => "email"}
  ]

  @doc_link_fields [
    %{"name" => "href", "type" => "string"},
    %{"name" => "page", "type" => "reference", "to" => [%{"type" => "ptDocPage"}]},
    %{"name" => "anchor", "type" => "string"},
    %{"name" => "title", "type" => "string"}
  ]

  defp block_array(name, opts) do
    block =
      %{
        "type" => "block",
        "styles" => styles(opts[:styles]),
        "lists" => Enum.map(opts[:lists], &%{"title" => &1, "value" => &1}),
        "marks" => %{
          "decorators" => decorators(opts[:decorators]),
          "annotations" => opts[:annotations] || []
        }
      }
      |> then(fn b -> if opts[:inline], do: Map.put(b, "of", opts[:inline]), else: b end)

    %{
      "name" => name,
      "type" => "array",
      "of" => [block | Enum.map(opts[:of] || [], &%{"type" => &1})]
    }
  end

  defp annotation(name, fields), do: %{"name" => name, "type" => "object", "fields" => fields}

  defp block_content(name, of) do
    block_array(name,
      styles: ~w(normal h2 h3 h4),
      lists: ~w(bullet number),
      decorators: ~w(strong em underline strike-through),
      annotations: [annotation("linkAnnotation", @link_annotation_fields)],
      of: of
    )
  end

  defp doc_body(name, of) do
    block_array(name,
      styles: ~w(normal h1 h2 h3 h4 h5 h6),
      lists: ~w(bullet number),
      decorators: ~w(strong em code strike-through),
      annotations: [annotation("docLink", @doc_link_fields)],
      inline: [%{"type" => "docBreak"}, %{"type" => "docInlineImage"}],
      of: of
    )
  end

  defp simple(name, annotations) do
    block_array(name,
      styles: ~w(normal),
      lists: ~w(bullet number),
      decorators: ~w(strong em underline),
      annotations: annotations
    )
  end

  @object_schemas [
    %{
      "name" => "ptQuote",
      "kind" => "object",
      "fields" => [%{"name" => "quote", "type" => "string"}]
    },
    %{
      "name" => "ptMedia",
      "kind" => "object",
      "fields" => [%{"name" => "caption", "type" => "string"}]
    },
    %{
      "name" => "docCallout",
      "kind" => "object",
      "fields" => [%{"name" => "text", "type" => "string"}]
    },
    %{
      "name" => "docBreak",
      "kind" => "object",
      "fields" => [%{"name" => "style", "type" => "string"}]
    },
    %{
      "name" => "docInlineImage",
      "kind" => "object",
      "fields" => [%{"name" => "alt", "type" => "string"}, %{"name" => "src", "type" => "string"}]
    }
  ]

  defp schemas do
    @object_schemas ++
      [
        %{
          "name" => "ptFaqItem",
          "kind" => "object",
          "fields" => [
            %{"name" => "question", "type" => "string"},
            simple("answer", [annotation("linkAnnotation", @link_annotation_fields)])
          ]
        },
        %{"name" => "ptPage", "fields" => [%{"name" => "title", "type" => "string"}]},
        %{"name" => "ptDocPage", "fields" => [%{"name" => "title", "type" => "string"}]},
        %{
          "name" => "ptTwin",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            block_content("blockContent", ["ptQuote"]),
            simple("simpleBlockContent", []),
            block_content("articleBlockContent", ["ptMedia", "ptQuote"]),
            doc_body("docBody", ["docCallout"]),
            simple("moduleBody", [annotation("link", @module_link_fields)]),
            simple("cardText", [annotation("linkAnnotation", @link_annotation_fields)]),
            block_array("accordionBody",
              styles: ~w(normal h3),
              lists: ~w(bullet),
              decorators: ~w(strong em underline),
              annotations: [annotation("link", @module_link_fields)]
            ),
            doc_body("tableCell", []),
            simple("plainLinks", [
              annotation("link", [%{"name" => "href", "type" => "url"}])
            ]),
            %{"name" => "notes", "type" => "richText"},
            %{
              "name" => "faqs",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => [%{"name" => "ptFaqItem", "type" => "ptFaqItem"}]
            }
          ]
        }
      ]
  end

  # ── Stored values ─────────────────────────────────────────────────────

  defp span(key, text, marks \\ []),
    do: %{"_key" => key, "_type" => "span", "text" => text, "marks" => marks}

  defp block(key, children, opts \\ []) do
    %{
      "_key" => key,
      "_type" => "block",
      "style" => opts[:style] || "normal",
      "markDefs" => opts[:defs] || [],
      "children" => children
    }
    |> then(fn b ->
      if opts[:list], do: Map.merge(b, %{"listItem" => opts[:list], "level" => 1}), else: b
    end)
  end

  # A linkAnnotation as Sanity stores it: no linkType, an internal reference.
  defp internal_link(key),
    do: %{
      "_key" => key,
      "_type" => "linkAnnotation",
      "internalLink" => %{"_type" => "reference", "_ref" => "page-about"}
    }

  defp body(p, kind) do
    {defs, linked} =
      case kind do
        :link_annotation ->
          {[internal_link(p <> "m1")], [p <> "m1"]}

        :module_link ->
          {[
             %{
               "_key" => p <> "m1",
               "_type" => "link",
               "linkType" => "external",
               "url" => "https://example.org/a"
             }
           ], [p <> "m1"]}

        :doc_link ->
          {[
             %{
               "_key" => p <> "m1",
               "_type" => "docLink",
               "page" => %{"_type" => "reference", "_ref" => "docpage-intro"},
               "anchor" => "start"
             }
           ], [p <> "m1"]}

        :href_link ->
          {[%{"_key" => p <> "m1", "_type" => "link", "href" => "https://example.org/b"}],
           [p <> "m1"]}

        :none ->
          {[], ["em"]}
      end

    inline =
      if kind == :doc_link,
        do: [%{"_type" => "docBreak", "_key" => p <> "i1", "style" => "soft"}],
        else: []

    [
      block(p <> "01", [span(p <> "01s0", "A made-up heading")],
        style: if(kind in [:none, :module_link], do: "normal", else: "h2")
      ),
      block(
        p <> "02",
        [
          span(p <> "02s0", "Plain words, then "),
          span(p <> "02s1", "strong words", ["strong"]),
          span(p <> "02s2", " and a ")
        ] ++
          inline ++
          [span(p <> "02s3", "marked part", linked), span(p <> "02s4", " to end.")],
        defs: defs
      ),
      block(p <> "03", [span(p <> "03s0", "The editable sentence sits here.")]),
      block(p <> "04", [span(p <> "04s0", "First item")], list: "bullet"),
      block(p <> "05", [span(p <> "05s0", "Closing words")])
    ]
  end

  defp with_custom(blocks, key, type, fields),
    do: List.insert_at(blocks, 3, Map.merge(%{"_key" => key, "_type" => type}, fields))

  @shapes [
    {"blockContent", "bc", :link_annotation},
    {"simpleBlockContent", "sb", :none},
    {"articleBlockContent", "ab", :link_annotation},
    {"docBody", "db", :doc_link},
    {"moduleBody", "mb", :module_link},
    {"cardText", "ct", :link_annotation},
    {"accordionBody", "pb", :module_link},
    {"tableCell", "tc", :doc_link},
    {"plainLinks", "pl", :href_link}
  ]

  defp twin_content do
    fields =
      for {name, p, kind} <- @shapes, into: %{} do
        value =
          case name do
            "blockContent" ->
              with_custom(body(p, kind), "bcq1", "ptQuote", %{"quote" => "Kept"})

            "articleBlockContent" ->
              with_custom(body(p, kind), "abm1", "ptMedia", %{"caption" => "Kept"})

            "docBody" ->
              with_custom(body(p, kind), "dbc1", "docCallout", %{"text" => "Kept"})

            _ ->
              body(p, kind)
          end

        {name, value}
      end

    Map.merge(fields, %{
      "faqs" => [
        %{
          "_key" => "faq1",
          "_type" => "ptFaqItem",
          "question" => "A made-up question?",
          "answer" => body("fa", :link_annotation)
        }
      ]
    })
  end

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "ptvocab-#{suffix}", name: "PT vocabulary"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "ptvocab-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "ptvocab", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    for s <- schemas(),
        do: {:ok, _} = Content.upsert_schema(Map.put_new(s, "title", s["name"]), @dataset, scope)

    publish!("ptPage", "page-about", "About", %{}, scope)
    publish!("ptDocPage", "docpage-intro", "Intro", %{}, scope)
    publish!("ptDocPage", "docpage-setup", "Setup", %{}, scope)
    publish!("ptTwin", "twin-1", "Twin article", twin_content(), scope)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     ws: ws,
     proj: proj,
     scope: scope}
  end

  defp publish!(type, id, title, content, scope) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "title" => title, "status" => "published", "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document(id, type, @dataset, scope)
  end

  defp doc_path(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/ptTwin/twin-1"

  defp draft!(scope) do
    {:ok, doc} = Content.get_document("drafts.twin-1", "ptTwin", @dataset, scope)
    doc.content
  end

  defp stored!(scope) do
    {:ok, doc} = Content.get_document("twin-1", "ptTwin", @dataset, scope)
    doc.content
  end

  # Every path at which two JSON values differ.
  defp diff(a, b, path \\ [])
  defp diff(a, a, _path), do: []

  defp diff(%{} = a, %{} = b, path) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.flat_map(&diff(Map.get(a, &1), Map.get(b, &1), path ++ [&1]))
  end

  defp diff(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} -> diff(x, y, path ++ [i]) end)
  end

  defp diff(_a, _b, path), do: [path]

  defp vocabulary(html, name) do
    [_, json] =
      Regex.run(~r/data-bridge-target="bp-rt-hidden-#{name}"[^>]*data-vocabulary="([^"]*)"/, html)

    json |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&") |> Jason.decode!()
  end

  describe "editing one span" do
    for {name, p, _kind} <- @shapes do
      test "in #{name} changes only that span's text",
           %{conn: conn, ws: ws, proj: proj, scope: scope} do
        name = unquote(name)
        p = unquote(p)
        stored = stored!(scope)[name]
        {:ok, view, _html} = live(conn, doc_path(ws, proj))

        html = PortableText.to_html(stored)
        assert html =~ "The editable sentence sits here."
        posted = String.replace(html, "editable sentence", "edited sentence")

        view
        |> form("#editor-form")
        |> render_change(%{"doc[#{name}]" => posted, "_target" => ["doc[#{name}]"]})

        saved = draft!(scope)[name]
        idx = Enum.find_index(stored, &(&1["_key"] == p <> "03"))
        assert diff(stored, saved) == [[idx, "children", 0, "text"]]

        assert get_in(Enum.at(saved, idx), ["children", Access.at(0), "text"]) ==
                 "The edited sentence sits here."
      end
    end

    test "in faqItem.answer changes only that span's text",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      [faq] = stored!(scope)["faqs"]
      {:ok, view, html} = live(conn, doc_path(ws, proj))
      assert html =~ ~s(name="doc[faqs][0].answer")

      posted =
        faq["answer"]
        |> PortableText.to_html()
        |> String.replace("editable sentence", "edited sentence")

      view
      |> form("#editor-form")
      |> render_change(%{
        "doc[faqs][0].answer" => posted,
        "_target" => ["doc[faqs][0].answer"]
      })

      [saved] = draft!(scope)["faqs"]
      assert diff(faq, saved) == [["answer", 2, "children", 0, "text"]]
    end
  end

  describe "the toolbar" do
    test "reads the declared styles, lists and decorators", %{conn: conn, ws: ws, proj: proj} do
      {:ok, _view, html} = live(conn, doc_path(ws, proj))

      simple = vocabulary(html, "simpleBlockContent")
      assert simple["styles"] == ["normal"]
      refute Enum.any?(simple["styles"], &String.starts_with?(&1, "h"))
      assert simple["decorators"] == ~w(strong em underline)
      assert simple["annotations"] == []

      blocks = vocabulary(html, "blockContent")
      assert blocks["styles"] == ~w(normal h2 h3 h4)
      assert blocks["annotations"] == [%{"name" => "linkAnnotation", "title" => "linkAnnotation"}]

      doc = vocabulary(html, "docBody")
      assert doc["decorators"] == ~w(strong em code strike-through)
      assert Enum.map(doc["inline"], & &1["name"]) == ~w(docBreak docInlineImage)
    end

    test "a field that declares no vocabulary renders without it", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {:ok, _view, html} = live(conn, doc_path(ws, proj))
      [tag] = Regex.run(~r/<bp-rich-text-editor[^>]*bp-rt-hidden-notes[^>]*>/, html)
      refute tag =~ "data-vocabulary"
    end
  end

  # The editor marks the selection under a new key and posts its HTML.
  defp add_annotation(view, field, type, key, scope) do
    stored = stored!(scope)[field]

    html =
      stored
      |> PortableText.to_html()
      |> String.replace(
        "editable sentence",
        ~s(<span data-pt-def="#{key}">editable sentence</span>)
      )

    render_hook(view, "pt-def-insert", %{
      "field" => field,
      "type" => type,
      "key" => key,
      "html" => html
    })

    assert_push_event(view, "bp:pt-def-ready", %{key: ^key, ok: true})
    assert has_element?(view, ~s(#bp-object-dialog[data-object-key="#{key}"]))
  end

  defp marked_block(saved, p), do: Enum.find(saved, &(&1["_key"] == p <> "03"))

  describe "the annotation dialog" do
    test "a docLink to a doc page writes page._ref", %{
      conn: conn,
      ws: ws,
      proj: proj,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      add_annotation(view, "docBody", "docLink", "dl00new1", scope)

      view
      |> form("#bp-object-dialog-form-dl00new1")
      |> render_submit(%{"doc[__object].page" => "docpage-setup"})

      assert_push_event(view, "bp:pt-def-update", %{key: "dl00new1"})

      block = marked_block(draft!(scope)["docBody"], "db")

      assert block["markDefs"] == [
               %{
                 "_key" => "dl00new1",
                 "_type" => "docLink",
                 "page" => %{"_ref" => "docpage-setup", "_type" => "reference"}
               }
             ]

      assert [_, %{"text" => "editable sentence", "marks" => ["dl00new1"]}, _] = block["children"]
    end

    test "a link writes href", %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      add_annotation(view, "plainLinks", "link", "lk00new1", scope)

      view
      |> form("#bp-object-dialog-form-lk00new1", %{
        "doc[__object].href" => "https://example.org/c"
      })
      |> render_submit()

      assert_push_event(view, "bp:pt-def-update", %{
        key: "lk00new1",
        href: "https://example.org/c"
      })

      block = marked_block(draft!(scope)["plainLinks"], "pl")

      assert block["markDefs"] == [
               %{"_key" => "lk00new1", "_type" => "link", "href" => "https://example.org/c"}
             ]
    end

    test "a linkAnnotation saves an internalLink without linkType",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      add_annotation(view, "blockContent", "linkAnnotation", "la00new1", scope)

      view
      |> form("#bp-object-dialog-form-la00new1")
      |> render_submit(%{"doc[__object].internalLink" => "page-about"})

      [def] = marked_block(draft!(scope)["blockContent"], "bc")["markDefs"]

      assert def == %{
               "_key" => "la00new1",
               "_type" => "linkAnnotation",
               "internalLink" => %{"_ref" => "page-about", "_type" => "reference"}
             }

      findings =
        Barkpark.Content.PortableTextValidation.findings(
          Barkpark.Content.RichTextFormat.normalise_field(
            block_content("blockContent", ["ptQuote"])
          ),
          draft!(scope)["blockContent"],
          "blockContent",
          :error
        )

      assert findings == []
    end

    test "a stored annotation opens with its fields and saves by its _key",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      render_hook(view, "pt-def-open", %{"field" => "docBody", "key" => "dbm1"})
      assert has_element?(view, ~s(#bp-object-dialog[data-object-key="dbm1"]))

      view
      |> form("#bp-object-dialog-form-dbm1", %{"doc[__object].anchor" => "later"})
      |> render_submit()

      stored = stored!(scope)["docBody"]
      saved = draft!(scope)["docBody"]
      idx = Enum.find_index(stored, &(&1["_key"] == "db02"))
      assert diff(stored, saved) == [[idx, "markDefs", 0, "anchor"]]
    end

    test "Remove takes the annotation off its text", %{
      conn: conn,
      ws: ws,
      proj: proj,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      render_hook(view, "pt-def-open", %{"field" => "cardText", "key" => "ctm1"})
      view |> element("[data-object-dialog-remove]") |> render_click()
      assert_push_event(view, "bp:pt-def-remove", %{key: "ctm1"})

      block = Enum.find(draft!(scope)["cardText"], &(&1["_key"] == "ct02"))
      assert block["markDefs"] == []
      assert Enum.all?(block["children"], &("ctm1" not in &1["marks"]))
      assert Enum.map_join(block["children"], & &1["text"]) =~ "marked part"
    end

    test "an annotation type the field does not declare is refused",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      html = PortableText.to_html(stored!(scope)["simpleBlockContent"])

      render_hook(view, "pt-def-insert", %{
        "field" => "simpleBlockContent",
        "type" => "link",
        "key" => "nope0001",
        "html" => html
      })

      assert_push_event(view, "bp:pt-def-ready", %{key: "nope0001", ok: false})
      refute has_element?(view, "#bp-object-dialog")
    end
  end

  describe "inline objects" do
    test "an inline object is inserted at the caret and edited",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      stored = stored!(scope)["docBody"]
      key = "im00new1"

      placeholder =
        ~s(<span data-pt-object="{&quot;_key&quot;:&quot;#{key}&quot;}" contenteditable="false" data-pt-pending="#{key}">Inserting…</span>)

      html =
        stored
        |> PortableText.to_html()
        |> String.replace("sits here.", "sits here." <> placeholder)

      render_hook(view, "pt-inline-insert", %{
        "field" => "docBody",
        "type" => "docInlineImage",
        "key" => key,
        "html" => html
      })

      assert_push_event(view, "bp:pt-inline-ready", %{key: ^key, html: chip})
      assert chip =~ "data-pt-object"
      assert has_element?(view, ~s(#bp-object-dialog[data-object-type="docInlineImage"]))

      view
      |> form("#bp-object-dialog-form-#{key}", %{"doc[__object].alt" => "A made-up picture"})
      |> render_submit()

      assert_push_event(view, "bp:pt-inline-update", %{key: ^key})

      block = Enum.find(draft!(scope)["docBody"], &(&1["_key"] == "db03"))

      assert [
               %{"_key" => "db03s0", "text" => "The editable sentence sits here."},
               %{"_type" => "docInlineImage", "_key" => ^key, "alt" => "A made-up picture"}
             ] = block["children"]
    end

    test "a stored inline object opens and saves by its _key",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj))
      render_hook(view, "pt-inline-open", %{"field" => "docBody", "key" => "dbi1"})
      assert has_element?(view, ~s(#bp-object-dialog[data-object-type="docBreak"]))

      view
      |> form("#bp-object-dialog-form-dbi1", %{"doc[__object].style" => "hard"})
      |> render_submit()

      stored = stored!(scope)["docBody"]
      saved = draft!(scope)["docBody"]
      idx = Enum.find_index(stored, &(&1["_key"] == "db02"))
      assert diff(stored, saved) == [[idx, "children", 3, "style"]]
    end
  end
end
