defmodule BarkparkWeb.Studio.PaperEditor.CardContextualFormTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "media source-only replacement preserves exact existing carrier metadata" do
    for type <- [:absent, nil, "image"], src <- [:absent, nil, "", "/before.png"] do
      media = %{
        "id" => "media-owner",
        "alt" => nil,
        "width" => 640,
        "height" => 320,
        "future" => %{"keep" => [true, nil, 3]}
      }

      media = if type == :absent, do: media, else: Map.put(media, "type", type)
      media = if src == :absent, do: media, else: Map.put(media, "src", src)

      block =
        card(%{
          "qa" => "unchanged",
          "slots" => %{
            "media" => [media],
            "future" => %{"opaque" => true},
            "action" => [%{"type" => "action", "label" => "Read", "href" => "/keep"}]
          }
        })

      assert {:ok, op} =
               Blocks.resolve_block_form([block], %{
                 "block_id" => block["id"],
                 "card-media-src" => "/after.png"
               })

      assert Map.merge(block, op["patch"]) ==
               put_in(block, ["slots", "media"], [Map.put(media, "src", "/after.png")])

      assert {:ok, %{}} =
               Blocks.validate_block_patch(block, %{
                 "card-media-src" => if(src in [:absent, nil], do: "", else: src)
               })
    end
  end

  test "label-only source changes exactly one field in an existing action" do
    for priority <- [nil, "secondary", "primary", "quiet"],
        label <- [nil, "", "  Read  "] do
      action = %{
        "id" => "action-owner",
        "type" => "action",
        "label" => label,
        "href" => nil,
        "priority" => priority,
        "future" => %{"keep" => [1, true]}
      }

      block =
        card(%{
          "unknown" => true,
          "slots" => %{
            "action" => [action],
            "future" => %{"opaque" => true},
            "body" => [%{"type" => "paragraph", "content" => inline("Body")}]
          }
        })

      assert {:ok, op} =
               Blocks.resolve_block_form([block], %{
                 "block_id" => block["id"],
                 "card-action-label" => "  New <literal>  "
               })

      changed = Map.merge(block, op["patch"])

      assert changed ==
               put_in(block, ["slots", "action"], [Map.put(action, "label", "  New <literal>  ")])

      assert {:ok, %{}} =
               Blocks.validate_block_patch(block, %{"card-action-label" => label || ""})
    end

    missing_label = card(%{"slots" => %{"action" => [%{"type" => "action", "href" => "/go"}]}})
    assert {:ok, %{}} = Blocks.validate_block_patch(missing_label, %{"card-action-label" => ""})

    for action <- [
          [%{"type" => "action", "label" => 12}],
          [%{"type" => "action"}, %{"type" => "action"}],
          [%{"type" => "button", "label" => "Other carrier"}]
        ] do
      assert {:error, _} =
               Blocks.resolve_block_form([card(%{"slots" => %{"action" => action}})], %{
                 "block_id" => "card",
                 "card-action-label" => "Refused"
               })
    end
  end

  test "title-only source changes exactly one field in an existing plain heading" do
    for content <- [:absent, nil, []], level <- [:absent, nil, 1, 2, 3, "1", "2", "3"] do
      title =
        %{
          "type" => "heading",
          "text" => "Before",
          "id" => "title-owner",
          "opaque" => %{"keep" => [true, nil, 1, 1.0]}
        }
        |> then(fn value ->
          if content === :absent, do: value, else: Map.put(value, "content", content)
        end)
        |> then(fn value ->
          if level === :absent, do: value, else: Map.put(value, "level", level)
        end)

      block =
        card(%{
          "tone" => "calm",
          "slots" => %{
            "title" => [title],
            "body" => [%{"type" => "paragraph", "content" => inline("Body")}],
            "future" => %{"keep" => true}
          },
          "unknown" => [1, 2]
        })

      assert {:ok, op} =
               Blocks.resolve_block_form([block], %{
                 "block_id" => "card",
                 "card-title" => "  After <literal>  "
               })

      assert Map.merge(block, op["patch"]) ==
               put_in(block, ["slots", "title"], [
                 Map.put(title, "text", "  After <literal>  ")
               ])

      assert {:ok, %{"patch" => %{}}} =
               Blocks.resolve_block_form([block], %{
                 "block_id" => "card",
                 "card-title" => "Before"
               })
    end
  end

  test "title-only source fails closed for ambiguous or non-plain title carriers" do
    valid = %{"type" => "heading", "text" => "Before"}

    invalid_titles = [
      :absent,
      nil,
      [],
      [valid, valid],
      [Map.delete(valid, "type")],
      [Map.put(valid, "type", nil)],
      [Map.put(valid, "type", "paragraph")],
      [Map.delete(valid, "text")],
      [Map.put(valid, "text", nil)],
      [Map.put(valid, "text", 42)],
      [Map.put(valid, "content", [%{"type" => "text", "value" => "Rich"}])],
      [Map.put(valid, "content", "Rich")],
      [Map.put(valid, "level", 4)],
      [Map.put(valid, "level", "4")]
    ]

    for title <- invalid_titles do
      slots =
        case title do
          :absent -> %{}
          value -> %{"title" => value}
        end

      assert {:error, {:source_validation, :invalid_card_title}} =
               Blocks.resolve_block_form([card(%{"slots" => slots})], %{
                 "block_id" => "card",
                 "card-title" => "After"
               })
    end

    assert {:error, {:source_validation, :invalid_card_title}} =
             Blocks.resolve_block_form(
               [
                 card(%{"slots" => %{"title" => [valid]}}),
                 card(%{"slots" => %{"title" => [valid]}})
               ],
               %{"block_id" => "card", "card-title" => "After"}
             )

    assert {:error, :block_not_found} =
             Blocks.resolve_block_form([], %{"block_id" => "card", "card-title" => "After"})

    assert {:error, {:source_validation, :invalid_card_title}} =
             Blocks.resolve_block_form([card(%{"slots" => %{"title" => [valid]}})], %{
               "block_id" => "card",
               "card-title" => 42
             })

    assert {:error, {:source_validation, :invalid_card_title}} =
             Blocks.resolve_block_form([card(%{"slots" => %{"title" => [valid]}})], %{
               "block_id" => "card",
               "card-title" => "After",
               "foreign" => "refused"
             })

    nested_duplicate = [
      card(%{"slots" => %{"title" => [valid]}}),
      %{
        "id" => "section",
        "type" => "section",
        "blocks" => [card(%{"slots" => %{"title" => [valid]}})]
      }
    ]

    assert {:error, {:source_validation, :invalid_card_title}} =
             Blocks.resolve_block_form(nested_duplicate, %{
               "block_id" => "card",
               "card-title" => "After"
             })
  end

  test "card form state projects strict singleton chrome without normalizing source" do
    assert Blocks.card_form_state(%{"id" => "bare", "type" => "card"}) ==
             {:ok,
              %{
                tone: "",
                title: "",
                media_src: "",
                media_alt: "",
                action_label: "",
                action_href: "",
                action_priority: "secondary"
              }}

    block =
      card(%{
        "tone" => "legacy-tone",
        "slots" => %{
          "title" => [%{"type" => "heading", "text" => "Title", "level" => 3}],
          "body" => [%{"type" => "paragraph", "content" => inline("Body")}],
          "media" => [%{"src" => "/image.png", "alt" => "Image", "width" => 400}],
          "action" => [
            %{
              "type" => "action",
              "label" => "Read",
              "href" => "/read",
              "priority" => "legacy-priority"
            }
          ],
          "future" => %{"opaque" => true}
        }
      })

    assert {:ok, state} = Blocks.card_form_state(block)
    assert state.tone == "legacy-tone"
    assert state.title == "Title"
    assert state.media_src == "/image.png"
    assert state.media_alt == "Image"
    assert state.action_label == "Read"
    assert state.action_href == "/read"
    assert state.action_priority == "legacy-priority"
  end

  test "card form state rejects malformed known slots while accepting missing and nil slots" do
    assert {:ok, _state} = Blocks.card_form_state(card(%{"slots" => nil}))

    assert {:ok, _state} =
             Blocks.card_form_state(
               card(%{
                 "slots" => %{
                   "title" => nil,
                   "body" => [],
                   "media" => nil,
                   "action" => [],
                   "future" => "opaque"
                 }
               })
             )

    for slots <- [
          "opaque",
          %{"title" => %{}},
          %{"title" => ["opaque"]},
          %{"title" => [%{"type" => "heading"}, %{"type" => "heading"}]},
          %{"title" => [%{"type" => "paragraph", "text" => "Wrong"}]},
          %{"title" => [%{"type" => "heading", "text" => %{}}]},
          %{"body" => [%{"type" => "heading", "content" => []}]},
          %{"body" => [%{"type" => "paragraph", "content" => %{}}]},
          %{"media" => [%{"type" => "video", "src" => "/x"}]},
          %{"media" => [%{"type" => "image", "src" => %{}}]},
          %{"action" => [%{"type" => "button", "label" => "Go"}]},
          %{"action" => [%{"type" => "action", "priority" => %{}}]}
        ] do
      assert Blocks.card_form_state(card(%{"slots" => slots})) ==
               {:error, :malformed_card}
    end
  end

  test "card form requires known binary wire fields and rejects the whole malformed submission" do
    block = card(%{"unknown" => "keep"})

    assert Blocks.validate_block_patch(block, %{}) == {:error, :invalid_card_form}

    assert Blocks.validate_block_patch(block, %{"block_id" => "card"}) ==
             {:error, :invalid_card_form}

    assert Blocks.validate_block_patch(block, %{"card-title" => "Title", "card-extra" => "x"}) ==
             {:error, :invalid_card_form}

    assert Blocks.validate_block_patch(block, %{"card-title" => %{}}) ==
             {:error, :invalid_card_form}

    assert Blocks.build_block_patch(block, %{"card-title" => %{}}) == %{}
  end

  test "absent and nil chrome survives projected no-op submissions byte-exactly" do
    for block <- [card(%{}), card(%{"tone" => nil, "slots" => nil})] do
      assert Blocks.validate_block_patch(block, blank_params()) == {:ok, %{}}
    end

    legacy =
      card(%{
        "tone" => "legacy-tone",
        "slots" => %{
          "action" => [%{"type" => "action", "priority" => "legacy-priority"}],
          "future" => [%{"keep" => true}]
        }
      })

    params =
      blank_params()
      |> Map.put("card-tone", "legacy-tone")
      |> Map.put("card-action-priority", "legacy-priority")

    assert Blocks.validate_block_patch(legacy, params) == {:ok, %{}}
  end

  test "title edits and clears copy only the first singleton element" do
    title = %{"type" => "heading", "text" => "Old", "level" => 3, "unknown" => [1]}
    body = %{"type" => "paragraph", "content" => inline("Body"), "unknown" => true}

    block =
      card(%{
        "slots" => %{
          "title" => [title],
          "body" => [body],
          "future" => %{"keep" => true}
        }
      })

    assert {:ok, %{"slots" => edited}} =
             Blocks.validate_block_patch(block, %{"card-title" => "New"})

    assert edited["title"] == [Map.put(title, "text", "New")]
    assert edited["body"] == [body]
    assert edited["future"] == %{"keep" => true}

    assert {:ok, %{"slots" => cleared}} =
             Blocks.validate_block_patch(block, %{"card-title" => ""})

    assert cleared["title"] == [Map.put(title, "text", "")]
    assert cleared["body"] == [body]

    assert {:ok, %{"slots" => created}} =
             Blocks.validate_block_patch(card(%{}), %{"card-title" => "New"})

    assert created == %{"title" => [%{"type" => "heading", "text" => "New"}]}
  end

  test "generic Card forms refuse title writes to content-authoritative headings only" do
    rich_title = %{
      "type" => "heading",
      "text" => "Projected text",
      "content" => [%{"type" => "text", "value" => "Authoritative"}],
      "opaque" => %{"keep" => true}
    }

    block =
      card(%{
        "slots" => %{
          "title" => [rich_title],
          "media" => [%{"type" => "image", "src" => "/before.png"}]
        }
      })

    assert {:error, :invalid_card_form} =
             Blocks.validate_block_patch(block, %{"card-title" => "Overwrite"})

    assert {:error, :invalid_card_form} =
             Blocks.validate_block_patch(block, %{
               "card-title" => "Projected text",
               "card-media-src" => "/after.png"
             })

    assert {:ok, %{"slots" => slots}} =
             Blocks.validate_block_patch(block, %{"card-media-src" => "/after.png"})

    assert slots["title"] == [rich_title]
    assert get_in(slots, ["media", Access.at(0), "src"]) == "/after.png"
  end

  test "media edits preserve typeless legacy metadata and blank clear never drops its slot" do
    media = %{"src" => "/old.png", "alt" => "Old", "width" => 640, "unknown" => true}
    block = card(%{"slots" => %{"media" => [media], "future" => "keep"}})

    assert {:ok, %{"slots" => edited}} =
             Blocks.validate_block_patch(block, %{
               "card-media-src" => "/new.png",
               "card-media-alt" => "New"
             })

    assert edited["media"] == [Map.merge(media, %{"src" => "/new.png", "alt" => "New"})]
    assert edited["future"] == "keep"

    assert {:ok, %{"slots" => cleared}} =
             Blocks.validate_block_patch(block, %{
               "card-media-src" => "",
               "card-media-alt" => ""
             })

    assert cleared["media"] == [Map.merge(media, %{"src" => "", "alt" => ""})]

    assert Blocks.validate_block_patch(card(%{}), %{"card-media-alt" => "Alt only"}) ==
             {:ok, %{}}

    assert {:ok, %{"slots" => created}} =
             Blocks.validate_block_patch(card(%{}), %{
               "card-media-src" => "/new.png",
               "card-media-alt" => "Alt"
             })

    assert created["media"] == [
             %{"type" => "image", "src" => "/new.png", "alt" => "Alt"}
           ]

    nil_src = %{"type" => "image", "src" => nil, "alt" => "Old", "future" => true}

    assert {:ok, %{"slots" => preserved_null}} =
             Blocks.validate_block_patch(card(%{"slots" => %{"media" => [nil_src]}}), %{
               "card-media-src" => "",
               "card-media-alt" => "New"
             })

    assert preserved_null["media"] == [Map.put(nil_src, "alt", "New")]
  end

  test "action edits preserve metadata, retain blank-cleared elements, and canonicalize priority changes" do
    action = %{
      "type" => "action",
      "label" => "Old",
      "href" => "/old",
      "priority" => "primary",
      "unknown" => [1]
    }

    block = card(%{"slots" => %{"action" => [action], "future" => true}})

    assert {:ok, %{"slots" => edited}} =
             Blocks.validate_block_patch(block, %{
               "card-action-label" => "New",
               "card-action-href" => "/new",
               "card-action-priority" => "secondary"
             })

    assert edited["action"] == [
             action
             |> Map.merge(%{"label" => "New", "href" => "/new"})
             |> Map.delete("priority")
           ]

    assert edited["future"] == true

    assert {:ok, %{"slots" => cleared}} =
             Blocks.validate_block_patch(block, %{
               "card-action-label" => "",
               "card-action-href" => ""
             })

    assert cleared["action"] == [Map.merge(action, %{"label" => "", "href" => ""})]

    assert Blocks.validate_block_patch(card(%{}), %{"card-action-priority" => "primary"}) ==
             {:ok, %{}}

    assert {:ok, %{"slots" => created}} =
             Blocks.validate_block_patch(card(%{}), %{
               "card-action-label" => "Go",
               "card-action-href" => "/go",
               "card-action-priority" => "primary"
             })

    assert created["action"] == [
             %{
               "type" => "action",
               "label" => "Go",
               "href" => "/go",
               "priority" => "primary"
             }
           ]

    null_siblings = %{
      "type" => "action",
      "label" => nil,
      "href" => "/old",
      "priority" => nil,
      "future" => true
    }

    assert {:ok, %{"slots" => preserved_null}} =
             Blocks.validate_block_patch(card(%{"slots" => %{"action" => [null_siblings]}}), %{
               "card-action-label" => "",
               "card-action-href" => "/new",
               "card-action-priority" => "secondary"
             })

    assert preserved_null["action"] == [Map.put(null_siblings, "href", "/new")]
  end

  test "tone and action priority changes use closed vocab while unchanged legacy values survive" do
    block =
      card(%{
        "tone" => "legacy-tone",
        "slots" => %{
          "action" => [
            %{"type" => "action", "label" => "Go", "priority" => "legacy-priority"}
          ]
        }
      })

    assert Blocks.validate_block_patch(block, %{"card-tone" => "legacy-tone"}) == {:ok, %{}}

    assert Blocks.validate_block_patch(block, %{
             "card-action-priority" => "legacy-priority"
           }) == {:ok, %{}}

    assert Blocks.validate_block_patch(block, %{"card-tone" => "invented"}) ==
             {:error, :invalid_card_form}

    assert Blocks.validate_block_patch(block, %{"card-action-priority" => "invented"}) ==
             {:error, :invalid_card_form}

    assert Blocks.validate_block_patch(block, %{"card-tone" => ""}) ==
             {:ok, %{"tone" => nil}}

    assert Blocks.validate_block_patch(block, %{"card-tone" => "ok"}) ==
             {:ok, %{"tone" => "ok"}}
  end

  defp card(extra), do: Map.merge(%{"id" => "card", "type" => "card"}, extra)

  defp blank_params do
    %{
      "card-tone" => "",
      "card-title" => "",
      "card-media-src" => "",
      "card-media-alt" => "",
      "card-action-label" => "",
      "card-action-href" => "",
      "card-action-priority" => "secondary"
    }
  end

  defp inline(text), do: [%{"type" => "text", "value" => text}]
end
