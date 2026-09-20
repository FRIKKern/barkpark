defmodule BarkparkWeb.PaperNoteContextualTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1]
  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.Papers.Hollow
  alias BarkparkWeb.Studio.StudioLive.Blocks

  @dataset "production"
  @beta_type "note_contextual"

  setup %{conn: conn} do
    ensure_default_scope!()
    pin_paper_canvas!("0")

    for type <- ["paper", @beta_type] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Note contextual",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "body", "type" => "richText"}
            ]
          },
          @dataset
        )
    end

    token = "note-contextual-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        token,
        "Note contextual",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token})}
  end

  for host <- [:public, :studio, :beta] do
    test "#{host}: typed note creation uses menu and remounts in fallback mode", %{conn: conn} do
      host = unquote(host)

      sibling = %{
        "id" => "preserved",
        "type" => "paragraph",
        "content" => [
          %{"type" => "strong", "children" => [%{"type" => "text", "value" => "Keep sibling"}]}
        ],
        "vendor" => %{"nested" => [1, %{"keep" => true}]}
      }

      id = create_document!(host, [sibling])
      assert stored_blocks(host, id) == [sibling]
      view = mount_editor(conn, host, id)
      assert has_element?(view, ~s([data-test-id="paper-add-block"] option[value="note"]))
      params = wire(view, %{"block-type" => "note"})
      view |> element(~s([data-test-id="paper-add-block"])) |> render_submit(params)
      request = params["request_id"]
      assert_reply(view, %{saved: true, request_id: ^request})
      assert [^sibling, created] = stored_blocks(host, id)
      assert created == Blocks.default_block("note", created["id"])
      assert has_element?(mount_editor(conn, host, id), "#note-form-#{created["id"]}")
      assert stored_blocks(host, id) == [sibling, created]
    end

    test "#{host}: slot edit saves, acknowledges, replays and remounts without rewriting metadata",
         %{conn: conn} do
      host = unquote(host)
      original = slotted()

      sibling = %{
        "id" => "sibling",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Keep"}],
        "vendor" => [1]
      }

      id = create_document!(host, [original, sibling])
      assert stored_blocks(host, id) == [original, sibling]
      view = mount_editor(conn, host, id)
      assert has_element?(view, "#note-controls-n:not([open])")
      refute has_element?(view, "[phx-hook='BarkparkPaperCanvas']")

      no_op =
        wire(view, %{
          "block_id" => "n",
          "note-label" => "Label",
          "note-lead" => "Lead",
          "note-body" => "Body"
        })

      before = stored(host, id)
      render_hook(view, "paper-block-autosave", no_op)
      request = no_op["request_id"]
      assert_reply(view, %{saved: true, request_id: ^request})
      assert stored(host, id).content == before.content
      assert stored(host, id).rev == before.rev

      params =
        wire(view, %{
          "block_id" => "n",
          "note-label" => "Changed",
          "note-lead" => "Lead",
          "note-body" => "Body"
        })

      view |> form("#note-form-n") |> render_submit(params)
      request = params["request_id"]
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false, rev: saved_rev})

      expected =
        put_in(
          original,
          [
            "slots",
            "label",
            Access.at(0),
            "content",
            Access.at(0),
            "children",
            Access.at(0),
            "value"
          ],
          "Changed"
        )

      assert stored_blocks(host, id) == [expected, sibling]

      render_hook(view, "paper-edit-block", params)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true, rev: ^saved_rev})
      assert stored_blocks(host, id) == [expected, sibling]

      reloaded = mount_editor(conn, host, id)
      assert render(reloaded) =~ "Changed"
      assert has_element?(reloaded, "#note-form-n")
      assert stored_blocks(host, id) == [expected, sibling]

      for invalid <- [
            %{"note-unknown" => "x"},
            %{"note-label" => 1},
            %{"note-body" => %{"forged" => "x"}}
          ] do
        before = stored(host, id)
        forged = wire(reloaded, Map.put(invalid, "block_id", "n"))
        render_hook(reloaded, "paper-block-autosave", forged)
        request = forged["request_id"]
        assert_reply(reloaded, %{saved: false, request_id: ^request})
        assert stored(host, id).content == before.content
        assert stored(host, id).rev == before.rev
      end
    end

    test "#{host}: content fallback stays in place through body edit and clear", %{conn: conn} do
      host = unquote(host)

      original = %{
        "id" => "n",
        "type" => "note",
        "label" => "Note",
        "text" => "",
        "content" => [%{"type" => "code", "value" => "Body", "vendor" => [1]}]
      }

      sibling = %{
        "id" => "preserved",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Keep sibling"}],
        "vendor" => %{"nested" => [1, %{"keep" => true}]}
      }

      cleared = put_in(original, ["content", Access.at(0), "value"], "")
      refute Hollow.hollow?([original])
      assert Hollow.hollow?([cleared])
      refute Hollow.hollow?([cleared, sibling])

      # Clearing the Note must not also remove the published Paper's last body content.
      id = create_document!(host, [original, sibling])
      assert stored_blocks(host, id) == [original, sibling]
      view = mount_editor(conn, host, id)
      assert has_element?(view, "#note-form-n")

      for text <- ["Edited", ""] do
        params = wire(view, %{"block_id" => "n", "note-body" => text})
        render_hook(view, "paper-block-autosave", params)
        request = params["request_id"]
        assert_reply(view, %{saved: true, request_id: ^request})

        assert stored_blocks(host, id) == [
                 put_in(original, ["content", Access.at(0), "value"], text),
                 sibling
               ]
      end

      assert has_element?(mount_editor(conn, host, id), "#note-form-n")
      assert stored_blocks(host, id) == [cleared, sibling]
    end

    test "#{host}: malformed note shows raw preview and forged editing makes no database change",
         %{conn: conn} do
      host = unquote(host)

      original = %{
        "id" => "n",
        "type" => "note",
        "label" => "Note",
        "text" => "Primary",
        "content" => [%{"type" => "text", "value" => "Dormant"}]
      }

      id = create_document!(host, [original])
      view = mount_editor(conn, host, id)
      assert has_element?(view, ~s([data-test-id="paper-note-preview"]))
      refute has_element?(view, "#note-form-n")
      assert render(view) =~ "cannot be edited safely"
      before = stored(host, id)
      params = wire(view, %{"block_id" => "n", "note-body" => ""})
      render_hook(view, "paper-block-autosave", params)
      request = params["request_id"]
      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored(host, id).content == before.content
      assert stored(host, id).rev == before.rev
    end
  end

  test "Beta stays contextual even when the Paper canvas is enabled", %{conn: conn} do
    System.put_env("BARKPARK_PAPER_CANVAS", "1")
    id = create_document!(:beta, [Blocks.default_block("note", "n")])
    view = mount_editor(conn, :beta, id)
    assert has_element?(view, "#note-form-n")
    refute has_element?(view, "[phx-hook='BarkparkPaperCanvas']")
    params = wire(view, %{"block_id" => "n", "note-body" => "Authored Beta body"})
    render_hook(view, "paper-block-autosave", params)
    request = params["request_id"]
    assert_reply(view, %{saved: true, request_id: ^request})
    assert hd(stored_blocks(:beta, id))["text"] == "Authored Beta body"
  end

  defp slotted do
    %{
      "id" => "n",
      "type" => "note",
      "label" => "shadow",
      "vendor" => [1],
      "slots" =>
        Map.new([{"label", "Label"}, {"lead", "Lead"}, {"body", "Body"}], fn {field, value} ->
          {field,
           [
             %{
               "id" => "n-" <> field,
               "type" => "paragraph",
               "vendor" => [2],
               "content" => [
                 %{
                   "type" => "strong",
                   "vendor" => [3],
                   "children" => [%{"type" => "text", "value" => value, "vendor" => [4]}]
                 }
               ]
             }
           ]}
        end)
        |> Map.put("unknown", %{"opaque" => true})
    }
  end

  defp create_document!(host, blocks) do
    id = "note-contextual-#{System.unique_integer([:positive])}"

    doc =
      if host == :beta do
        {:ok, doc} =
          Content.create_document(
            @beta_type,
            %{"doc_id" => id, "title" => "Notes", "content" => %{"blocks" => blocks}},
            @dataset
          )

        doc
      else
        {:ok, doc} =
          Content.upsert_paper(
            Barkpark.LabelFixtures.paper_attrs(%{
              "slug" => id,
              "title" => "Notes",
              "blocks" => blocks
            })
          )

        doc
      end

    doc.doc_id
  end

  defp mount_editor(conn, host, id) do
    path =
      case host do
        :public -> "/papers/#{id}"
        :studio -> scoped_studio("/d/#{@dataset}/studio/paper/#{id}")
        :beta -> scoped_studio("/d/#{@dataset}/studio/#{@beta_type}/#{Content.published_id(id)}")
      end

    {:ok, view, _} = live(conn, path)

    enter_editor(view, host)
    view
  end

  defp enter_editor(view, :public), do: render_click(view, "paper-toggle-edit", %{})

  defp enter_editor(view, :studio),
    do: view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()

  defp enter_editor(view, :beta),
    do: view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

  defp stored(:beta, id) do
    {:ok, doc} = Content.get_document(id, @beta_type, @dataset)
    doc
  end

  defp stored(_, id), do: Content.get_paper(id, @dataset)
  defp stored_blocks(host, id), do: stored(host, id).content["blocks"]

  defp wire(view, params) do
    assigns = :sys.get_state(view.pid).socket.assigns
    rev = if assigns[:editor_mode] == :beta, do: assigns.editor_doc.rev, else: assigns.paper_rev
    Map.merge(params, %{"request_id" => Ecto.UUID.generate(), "if_rev" => rev})
  end
end
