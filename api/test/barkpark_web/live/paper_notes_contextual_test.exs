defmodule BarkparkWeb.PaperNotesContextualTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1]

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Content.Document
  alias Barkpark.Repo.IdempotencyStore.Key
  alias Barkpark.PortableDoc.{Render, Slots}
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  @dataset "production"
  @beta_type "plural_notes_contextual"

  test "reader-shaped preview and closed existing-row controls use effective carriers" do
    block = grid()
    assert {:ok, state} = Blocks.notes_form_state(block)
    assert length(state.items) == 2

    for {row, item} <- Enum.zip(state.items, block["items"]) do
      assert row.label == Slots.note_label_text(item)
      assert row.lead == Slots.note_lead_text(item)
      assert row.body == Slots.note_body_text(item)
    end

    html =
      render_component(&PaperEditor.paper_block_fields/1, block: block, canvas_enabled: false)

    tree = LazyHTML.from_fragment(html)
    assert html =~ Render.render_block(block, %{style: :article})
    assert Enum.count(LazyHTML.query(tree, "details#notes-controls-notes-grid:not([open])")) == 1

    assert LazyHTML.text(LazyHTML.query(tree, "#notes-controls-notes-grid > summary")) ==
             "Edit notes"

    assert LazyHTML.attribute(LazyHTML.query(tree, "#notes-form-notes-grid"), "phx-change") == [
             "paper-block-autosave"
           ]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='notes-count']"), "value") == ["2"]

    for {row, index} <- Enum.with_index(state.items),
        {field, label} <- [{"label", "Label"}, {"lead", "Lead (optional)"}, {"body", "Body"}] do
      id = "notes-#{index}-#{field}-notes-grid"

      assert LazyHTML.text(LazyHTML.query(tree, "label[for='#{id}']")) ==
               "Note #{index + 1} #{label}"

      assert LazyHTML.text(LazyHTML.query(tree, "textarea##{id}[name='notes-#{index}-#{field}']")) ==
               Map.fetch!(row, String.to_existing_atom(field))
    end

    assert Enum.empty?(LazyHTML.query(tree, "[name='notes-action'], [contenteditable]"))
  end

  test "full no-op and each field edit preserve all enclosing metadata and untouched rows" do
    block = grid()
    assert {:ok, %{}} === Blocks.validate_block_patch(block, form_params(block))

    for index <- 0..1, field <- ~w(label lead body) do
      item = Enum.at(block["items"], index)
      singular = Map.merge(item, %{"id" => "singular", "type" => "note"})

      assert {:ok, expected_patch} =
               Blocks.validate_block_patch(singular, %{("note-" <> field) => "Edited"})

      assert {:ok, patch} =
               Blocks.validate_block_patch(block, %{
                 "notes-count" => "2",
                 "notes-#{index}-#{field}" => "Edited"
               })

      expected = List.update_at(block["items"], index, &Map.merge(&1, expected_patch))
      assert patch === %{"items" => expected}
      assert Map.merge(block, patch) === Map.put(block, "items", expected)
    end
  end

  test "two-row simultaneous edits replace complete items without rebuilding any row" do
    block = grid()

    params =
      form_params(block)
      |> Map.merge(%{"notes-0-lead" => "Updated lead", "notes-1-body" => "Updated body"})

    expected =
      block
      |> put_in(["items", Access.at(0), "lead"], "Updated lead")
      |> put_in(
        [
          "items",
          Access.at(1),
          "slots",
          "body",
          Access.at(0),
          "content",
          Access.at(0),
          "children",
          Access.at(0),
          "value"
        ],
        "Updated body"
      )
      |> put_in(["items", Access.at(1), "text"], "Updated body")

    assert {:ok, %{"items" => items}} = Blocks.validate_block_patch(block, params)
    assert items === expected["items"]
    assert Map.merge(block, %{"items" => items}) === expected
  end

  test "flat missing nil empty and integer fields keep their exact representation on no-op" do
    for value <- [:absent, nil, "", 7], slots <- [:absent, nil, %{}, %{"lead" => []}] do
      item = Enum.reduce(~w(label lead text), %{"vendor" => [1]}, &put_optional(&2, &1, value))
      item = put_optional(item, "slots", slots)
      block = %{"id" => "g", "type" => "notes", "items" => [item, %{"vendor" => [2]}]}
      assert {:ok, %{}} === Blocks.validate_block_patch(block, form_params(block))
    end
  end

  test "slot edits synchronize only matching binary twins, including structural clear" do
    for {field, flat} <- [{"label", "label"}, {"lead", "lead"}, {"body", "text"}],
        shadow <- [:absent, nil, 7, "", "different", "Original"] do
      item = %{
        "id" => "row",
        "slots" => %{field => [paragraph(field, "Original")], "unknown" => %{"keep" => true}}
      }

      item = put_optional(item, flat, shadow)
      block = %{"id" => "g", "type" => "notes", "items" => [%{"text" => "Unchanged"}, item]}

      expected =
        put_in(
          item,
          [
            "slots",
            field,
            Access.at(0),
            "content",
            Access.at(0),
            "children",
            Access.at(0),
            "value"
          ],
          ""
        )

      expected = if shadow == "Original", do: Map.put(expected, flat, ""), else: expected

      assert {:ok, %{"items" => [untouched, changed]}} =
               Blocks.validate_block_patch(block, %{
                 "notes-count" => "2",
                 "notes-1-#{field}" => ""
               })

      assert untouched === hd(block["items"])
      assert changed === expected
    end
  end

  test "flat clears and direct content body edits retain their original storage carriers" do
    block = %{
      "id" => "g",
      "type" => "notes",
      "items" => [
        %{"label" => "Label", "lead" => "Lead", "text" => "Body", "vendor" => [1]},
        %{"text" => "", "content" => inline("Content body"), "vendor" => [2]}
      ]
    }

    assert {:ok, %{"items" => [flat, content]}} =
             Blocks.validate_block_patch(block, %{
               "notes-count" => "2",
               "notes-0-label" => "",
               "notes-0-lead" => "",
               "notes-0-body" => "",
               "notes-1-body" => ""
             })

    assert flat === %{"label" => nil, "lead" => nil, "text" => "", "vendor" => [1]}
    assert content === %{"text" => "", "content" => inline(""), "vendor" => [2]}

    assert {:ok, %{}} ===
             Blocks.validate_block_patch(
               Map.put(block, "items", [flat, content]),
               %{
                 "notes-count" => "2",
                 "notes-0-label" => "",
                 "notes-0-lead" => "",
                 "notes-0-body" => "",
                 "notes-1-body" => ""
               }
             )
  end

  test "empty, malformed and mixed grids are wholly read-only and reject forged edits" do
    for items <- [
          nil,
          [],
          "opaque",
          ["legacy"],
          [nil],
          [[]],
          [%URI{}],
          [%{"text" => "safe"}, %URI{}],
          [%{"text" => "safe"}, "legacy"],
          [%{"slots" => []}],
          [%{"slots" => %{"label" => []}}],
          [%{"label" => false}],
          [
            %{
              "content" => [
                %{"type" => "text", "value" => "a"},
                %{"type" => "text", "value" => "b"}
              ]
            }
          ],
          [%{"text" => "Primary", "content" => inline("Dormant")}]
        ] do
      block = %{"id" => "g", "type" => "notes", "items" => items}
      assert {:error, _} = Blocks.notes_form_state(block)

      assert {:error, _} =
               Blocks.validate_block_patch(block, %{
                 "notes-count" => "1",
                 "notes-0-body" => "Forged"
               })

      html =
        render_component(&PaperEditor.paper_block_fields/1, block: block, canvas_enabled: false)

      tree = LazyHTML.from_fragment(html)
      assert html =~ Render.render_block(block, %{style: :article})
      assert Enum.count(LazyHTML.query(tree, "#notes-controls-g:not([open])")) == 1

      assert LazyHTML.text(LazyHTML.query(tree, "#notes-controls-g > summary")) ==
               "Read-only notes"

      assert LazyHTML.text(LazyHTML.query(tree, "#notes-controls-g .bp-paper-contextual-panel")) =~
               "original content is preserved"

      assert Enum.empty?(
               LazyHTML.query(
                 tree,
                 "#notes-controls-g form, #notes-controls-g input, #notes-controls-g textarea, #notes-controls-g select, #notes-controls-g button, #notes-controls-g [contenteditable]"
               )
             )
    end

    for block <- [
          %{"type" => "notes", "items" => [%{}]},
          %{"id" => " ", "type" => "notes", "items" => [%{}]}
        ] do
      assert {:error, _} = Blocks.notes_form_state(block)
    end
  end

  test "count and field vocabulary are validated against the current block" do
    block = grid()

    for params <- [
          %{"notes-0-label" => "X"},
          %{"notes-count" => nil},
          %{"notes-count" => 2},
          %{"notes-count" => "1", "notes-0-label" => "X"},
          %{"notes-count" => "invalid", "notes-0-label" => "X"},
          %{"notes-count" => "2", "notes-0-label" => nil},
          %{"notes-count" => "2", "notes-0-body" => %{}},
          %{"notes-count" => "2", "notes-2-label" => "X"},
          %{"notes-count" => "2", "notes--1-body" => "X"},
          %{"notes-count" => "2", "notes-0-other" => "X"},
          %{"notes-count" => "2", "notes-action" => "remove:0"}
        ] do
      assert {:error, _} = Blocks.validate_block_patch(block, params)

      assert {:error, _} =
               Blocks.resolve_block_form([block], Map.put(params, "block_id", block["id"]))
    end

    stale_source = Map.put(form_params(block), "block_id", block["id"])
    current = Map.put(block, "items", block["items"] ++ [%{"text" => "New row"}])
    assert {:error, _} = Blocks.resolve_block_form([current], stale_source)
  end

  describe "ordinary Beta document" do
    setup %{conn: conn} do
      ensure_default_scope!()
      pin_paper_canvas!("1")

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => @beta_type,
            "title" => "Plural Notes",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "body", "type" => "richText", "editor" => "blocks"}
            ]
          },
          @dataset
        )

      token = "plural-notes-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(
          token,
          "Plural Notes",
          @dataset,
          ["read", "write"],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token})}
    end

    test "no-op receipt preserves exact row; save ACK replay stale refusal and reload retain all metadata",
         %{conn: conn} do
      original = grid()

      sibling = %{
        "id" => "sibling",
        "type" => "paragraph",
        "content" => inline("Keep sibling"),
        "vendor" => %{"untouched" => [1]}
      }

      doc = create_document!([original, sibling])
      view = mount_beta(conn, doc.doc_id)
      assert has_element?(view, "#notes-controls-notes-grid:not([open])")
      refute has_element?(view, "[phx-hook='BarkparkPaperCanvas']")
      before = Repo.get!(Document, doc.id)

      no_op = wire(view, Map.put(form_params(original), "block_id", original["id"]))
      receipt_keys = receipt_keys()
      render_hook(view, "paper-block-autosave", no_op)
      request = no_op["request_id"]
      assert_reply(view, %{saved: true, request_id: ^request, rev: unchanged_rev})
      assert unchanged_rev == before.rev
      assert_no_op_receipt(receipt_keys, before)
      assert Repo.get!(Document, doc.id) === before

      params =
        form_params(original)
        |> Map.merge(%{
          "block_id" => original["id"],
          "notes-0-lead" => "Updated lead",
          "notes-1-body" => "Updated body"
        })
        |> then(&wire(view, &1))

      render_hook(view, "paper-block-autosave", params)
      request = params["request_id"]
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false, rev: saved_rev})
      assert saved_rev != before.rev

      expected =
        original
        |> put_in(["items", Access.at(0), "lead"], "Updated lead")
        |> put_in(
          [
            "items",
            Access.at(1),
            "slots",
            "body",
            Access.at(0),
            "content",
            Access.at(0),
            "children",
            Access.at(0),
            "value"
          ],
          "Updated body"
        )
        |> put_in(["items", Access.at(1), "text"], "Updated body")

      saved = Repo.get!(Document, doc.id)
      assert saved.content["blocks"] === [expected, sibling]
      assert saved.content["body"]["blocks"] === [expected, sibling]

      assert saved.content["body"]["html"] ==
               Render.render_blocks([expected, sibling], %{style: :article})

      assert Map.drop(saved.content, ~w(blocks body preview)) ===
               Map.drop(before.content, ~w(blocks body preview))

      assert Map.drop(saved.content["body"], ~w(blocks html)) ===
               Map.drop(before.content["body"], ~w(blocks html))

      render_hook(view, "paper-block-autosave", params)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true, rev: ^saved_rev})
      assert Repo.get!(Document, doc.id) === saved

      stale =
        params
        |> Map.put("request_id", Ecto.UUID.generate())
        |> Map.put("if_rev", before.rev)
        |> Map.put("notes-0-label", "Stale")

      render_hook(view, "paper-block-autosave", stale)
      request = stale["request_id"]
      assert_reply(view, %{saved: false, request_id: ^request})
      assert Repo.get!(Document, doc.id) === saved

      for forged <- [
            %{"notes-count" => "1", "notes-0-label" => "Forged"},
            %{"notes-count" => "2", "notes-2-body" => "Forged"},
            %{"notes-count" => "2", "notes-0-body" => %{}},
            %{"notes-count" => "2", "notes-action" => "add"}
          ] do
        forged = wire(view, Map.put(forged, "block_id", original["id"]))
        render_hook(view, "paper-block-autosave", forged)
        request = forged["request_id"]
        assert_reply(view, %{saved: false, request_id: ^request})
        assert Repo.get!(Document, doc.id) === saved
      end

      reloaded = mount_beta(conn, doc.doc_id)
      assert has_element?(reloaded, "#notes-controls-notes-grid:not([open])")
      assert reloaded |> element("#notes-0-lead-notes-grid") |> render() =~ "Updated lead"
      assert reloaded |> element("#notes-1-body-notes-grid") |> render() =~ "Updated body"
      assert render(reloaded) =~ Render.render_block(expected, %{style: :article})
      assert Repo.get!(Document, doc.id) === saved

      final_no_op = wire(reloaded, Map.put(form_params(expected), "block_id", expected["id"]))
      receipt_keys = receipt_keys()
      render_hook(reloaded, "paper-block-autosave", final_no_op)
      request = final_no_op["request_id"]
      assert_reply(reloaded, %{saved: true, request_id: ^request, rev: ^saved_rev})
      assert_no_op_receipt(receipt_keys, saved)
      assert Repo.get!(Document, doc.id) === saved
    end

    test "unsafe stored grid rejects a forged autosave without any stored row change", %{
      conn: conn
    } do
      block = Map.put(grid(), "items", [%{"text" => "Safe"}, "Legacy row"])
      doc = create_document!([block])

      # The current creation writer rescues string items into text maps. Seed
      # the historical stored shape directly so this tests unsafe admission,
      # rather than the writer's safe, normalized replacement.
      doc =
        doc
        |> Ecto.Changeset.change(content: Map.put(doc.content, "blocks", [block]))
        |> Repo.update!()

      before = Repo.get!(Document, doc.id)
      assert before.content["blocks"] === [block]
      view = mount_beta(conn, doc.doc_id)
      assert has_element?(view, "#notes-controls-notes-grid:not([open])")
      refute has_element?(view, "#notes-form-notes-grid")

      params =
        wire(view, %{"block_id" => block["id"], "notes-count" => "2", "notes-0-body" => "Forged"})

      render_hook(view, "paper-block-autosave", params)
      request = params["request_id"]
      assert_reply(view, %{saved: false, request_id: ^request})
      assert Repo.get!(Document, doc.id) === before
    end
  end

  defp receipt_keys, do: Repo.all(Key) |> Enum.map(& &1.key_hash) |> MapSet.new()

  defp assert_no_op_receipt(before_keys, doc) do
    [stored_receipt] = Repo.all(Key) |> Enum.reject(&MapSet.member?(before_keys, &1.key_hash))
    assert stored_receipt.state == "completed"
    receipt = Jason.decode!(stored_receipt.response_body)
    assert receipt["no_op"] == true
    assert receipt["rev"] == doc.rev
    assert receipt["written_row_id"] == doc.id
  end

  defp grid do
    %{
      "id" => "notes-grid",
      "type" => "notes",
      "vendor" => %{"grid" => [1, %{"keep" => true}]},
      "items" => [
        %{
          "id" => "flat-row",
          "label" => "Flat label",
          "lead" => "Flat lead",
          "text" => "Flat body",
          "vendor" => %{"item" => [1]}
        },
        %{
          "id" => "slotted-row",
          "type" => "note",
          "label" => "Divergent label",
          "lead" => nil,
          "text" => "Slot body",
          "vendor" => %{"item" => [2]},
          "slots" => %{
            "label" => [paragraph("slot-label", "Slot label")],
            "lead" => [paragraph("slot-lead", "Slot lead")],
            "body" => [paragraph("slot-body", "Slot body")],
            "unknown" => %{"opaque" => [1, 2]}
          }
        }
      ]
    }
  end

  defp paragraph(id, value),
    do: %{
      "id" => id,
      "type" => "paragraph",
      "vendor" => %{"paragraph" => true},
      "content" => inline(value)
    }

  defp inline(value),
    do: [
      %{
        "type" => "strong",
        "vendor" => %{"wrapper" => [1]},
        "children" => [%{"type" => "code", "value" => value, "vendor" => %{"leaf" => [2]}}]
      }
    ]

  defp put_optional(map, key, :absent), do: Map.delete(map, key)
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp form_params(block) do
    assert {:ok, state} = Blocks.notes_form_state(block)

    Enum.with_index(state.items)
    |> Enum.reduce(%{"notes-count" => Integer.to_string(length(state.items))}, fn {item, index},
                                                                                  params ->
      Map.merge(params, %{
        "notes-#{index}-label" => item.label,
        "notes-#{index}-lead" => item.lead,
        "notes-#{index}-body" => item.body
      })
    end)
  end

  defp create_document!(blocks) do
    {:ok, doc} =
      Content.create_document(
        @beta_type,
        %{
          "doc_id" => "plural-notes-#{System.unique_integer([:positive])}",
          "title" => "Plural Notes",
          "content" => %{
            "blocks" => blocks,
            "body" => %{"vendor" => %{"body" => [1]}},
            "vendor" => %{"document" => [1]}
          }
        },
        @dataset
      )

    doc
  end

  defp mount_beta(conn, id) do
    {:ok, view, _} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@beta_type}/#{Content.published_id(id)}"))

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    view
  end

  defp wire(view, params),
    do:
      Map.merge(params, %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => :sys.get_state(view.pid).socket.assigns.editor_doc.rev
      })
end
