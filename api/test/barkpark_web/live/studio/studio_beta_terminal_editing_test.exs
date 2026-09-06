defmodule BarkparkWeb.Studio.StudioBetaTerminalEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Content.Document

  @dataset "production"
  @doc_type "beta_terminal_editing"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta Terminal editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    raw = "beta-terminal-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta Terminal editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  test "generic Beta edits a slotted Stage inside Terminal without changing its carrier", %{
    conn: conn
  } do
    stage = %{
      "id" => "stage",
      "type" => "stage",
      "source" => "queue.ex:42",
      "qa" => "stage",
      "slots" => %{
        "title" => [
          %{
            "id" => "title",
            "type" => "paragraph",
            "content" => [
              %{"id" => "text", "type" => "text", "value" => "Original", "qa" => "leaf"}
            ]
          }
        ],
        "future" => [1, 2]
      }
    }

    original = [
      %{"id" => "terminal", "type" => "terminal", "children" => [stage], "qa" => "terminal"}
    ]

    doc = legacy_document!("stage", original)
    {view, path} = mount_beta(conn, doc.doc_id)
    assert has_element?(view, "#stage-form-stage")
    before = stored_document(doc.doc_id)
    request = Ecto.UUID.generate()

    wire = %{
      "block_id" => "stage",
      "stage-title" => "Changed in Beta",
      "if_rev" => before.rev,
      "request_id" => request
    }

    render_hook(view, "paper-edit-block", wire)
    assert_reply(view, %{saved: true, request_id: ^request, replayed: false, rev: saved_rev})

    expected =
      put_in(
        original,
        [
          Access.at(0),
          "children",
          Access.at(0),
          "slots",
          "title",
          Access.at(0),
          "content",
          Access.at(0),
          "value"
        ],
        "Changed in Beta"
      )

    assert stored_blocks(doc.doc_id) == expected
    render_hook(view, "paper-edit-block", wire)
    assert_reply(view, %{saved: true, request_id: ^request, replayed: true, rev: ^saved_rev})
    assert stored_blocks(doc.doc_id) == expected
    {:ok, reloaded, _} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "[data-test-id='paper-stage-preview']", "Changed in Beta")
    assert stored_blocks(doc.doc_id) == expected
  end

  test "generic Beta external refetch carries unsupported Terminal revision and identity", %{
    conn: conn
  } do
    original = [
      %{
        "id" => "terminal",
        "type" => "terminal",
        "children" => [paragraph("child", "Preserved draft source")],
        "custom" => [1, 2]
      }
    ]

    doc = legacy_document!("external", original)
    {view, _path} = mount_beta(conn, doc.doc_id)
    boundary = "#paper-terminal-boundary-terminal"
    assert has_element?(view, boundary <> "[data-paper-terminal-supported='true']")

    assert {:ok, _} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               %{"op" => "patch-block", "id" => "terminal", "patch" => %{"blocks" => []}},
               @dataset,
               if_rev: socket_of(view).assigns.editor_doc.rev
             )

    current_rev = stored_document(doc.doc_id).rev
    # Generic Beta refreshes its DOM without the Paper-only block-update event.
    # The stable boundary must carry authority for its actual updated hook.
    render(view)
    assert has_element?(view, boundary <> "[data-paper-terminal-supported='false']")
    assert has_element?(view, boundary <> "[data-paper-terminal-rev='#{current_rev}']")

    assert has_element?(
             view,
             boundary <>
               "[data-paper-terminal-document-key='#{@dataset}:#{@doc_type}:#{Content.published_id(doc.doc_id)}']"
           )

    assert stored_blocks(doc.doc_id) == List.update_at(original, 0, &Map.put(&1, "blocks", []))
  end

  test "generic Beta preserves raw chrome no-ops and saves chrome and nested body independently",
       %{
         conn: conn
       } do
    original = [
      paragraph("neighbor", "Preserved neighbor"),
      %{
        "id" => "terminal",
        "type" => "terminal",
        "title" => 7,
        "footer" => nil,
        "live" => "live",
        "children" => [
          paragraph("terminal-child", "Original child")
          |> Map.put("child-meta", %{"keep" => true})
        ],
        "terminal-meta" => [1, 2]
      }
    ]

    doc = legacy_document!("canonical", original)
    before = stored_document(doc.doc_id)
    {view, path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "[data-test-id='paper-terminal-editor']")
    assert has_element?(view, "#paper-ed-terminal-child")
    refute has_element?(view, "[data-paper-container-kind='terminal']")

    no_op_request = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "terminal",
      "title" => "7",
      "footer" => "",
      "live" => "true",
      "if_rev" => before.rev,
      "request_id" => no_op_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^no_op_request})
    assert stored_document(doc.doc_id) == before

    chrome_request = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "terminal",
      "title" => "Edited shell",
      "footer" => "q quit",
      "live" => "false",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => chrome_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^chrome_request})

    after_chrome =
      update_in(original, [Access.at(1)], fn terminal ->
        Map.merge(terminal, %{"title" => "Edited shell", "footer" => "q quit", "live" => false})
      end)

    assert stored_blocks(doc.doc_id) == after_chrome

    child_request = Ecto.UUID.generate()

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "terminal-child",
      "patch" => %{"content" => text("Edited nested child")},
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => child_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^child_request})

    expected =
      put_in(
        after_chrome,
        [Access.at(1), "children", Access.at(0), "content"],
        text("Edited nested child")
      )

    assert stored_blocks(doc.doc_id) == expected

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert has_element?(reloaded, "#terminal-title-terminal[value='Edited shell']")
    assert has_element?(reloaded, "#terminal-footer-terminal[value='q quit']")
    refute has_element?(reloaded, "#terminal-live-terminal[checked]")
    assert has_element?(reloaded, "#paper-ed-terminal-child")
    assert stored_blocks(doc.doc_id) == expected
  end

  test "generic Beta empty add is replayable and rejects stale vectors and global ID collisions",
       %{
         conn: conn
       } do
    original = [
      paragraph("reserved-child", "Reserved"),
      %{
        "id" => "empty-terminal",
        "type" => "terminal",
        "children" => [],
        "terminal-meta" => %{"keep" => true}
      },
      %{"id" => "stale-terminal", "type" => "terminal", "children" => []}
    ]

    doc = legacy_document!("empty", original)
    before = stored_document(doc.doc_id)
    {view, path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "#terminal-structure-form-empty-terminal button[value='add']")

    collision_request = Ecto.UUID.generate()

    render_hook(view, "paper-edit-block", %{
      "block_id" => "empty-terminal",
      "terminal-child-count" => "0",
      "terminal-new-child-id" => "reserved-child",
      "terminal-action" => "add",
      "if_rev" => before.rev,
      "request_id" => collision_request
    })

    assert_reply(view, %{saved: false, request_id: ^collision_request})
    assert stored_document(doc.doc_id) == before

    add_request = Ecto.UUID.generate()

    add_wire = %{
      "block_id" => "empty-terminal",
      "terminal-child-count" => "0",
      "terminal-new-child-id" => "new-terminal-child",
      "terminal-action" => "add",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => add_request
    }

    render_hook(view, "paper-edit-block", add_wire)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^add_request, rev: saved_rev})

    expected =
      put_in(original, [Access.at(1), "children"], [paragraph("new-terminal-child", "")])

    assert stored_blocks(doc.doc_id) == expected

    render_hook(view, "paper-edit-block", add_wire)
    assert_reply(view, %{saved: true, replayed: true, request_id: ^add_request, rev: ^saved_rev})
    assert stored_blocks(doc.doc_id) == expected

    stale_request = Ecto.UUID.generate()

    render_hook(view, "paper-edit-block", %{
      "block_id" => "stale-terminal",
      "terminal-child-count" => "0",
      "terminal-new-child-id" => "stale-child",
      "terminal-action" => "add",
      "if_rev" => before.rev,
      "request_id" => stale_request
    })

    assert_reply(view, %{saved: false, request_id: ^stale_request})
    assert stored_blocks(doc.doc_id) == expected

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "#paper-ed-new-terminal-child")
    refute has_element?(reloaded, "#terminal-structure-form-empty-terminal button[value='add']")
    assert stored_blocks(doc.doc_id) == expected
  end

  test "generic Beta keeps malformed and dual Terminal bodies read-only and refuses form writes",
       %{
         conn: conn
       } do
    original = [
      %{
        "id" => "dual-terminal",
        "type" => "terminal",
        "children" => [],
        "blocks" => [paragraph("hidden", "Opaque")],
        "custom" => "keep"
      },
      %{
        "id" => "malformed-terminal",
        "type" => "terminal",
        "children" => %{"opaque" => true},
        "custom" => [1, 2]
      }
    ]

    doc = legacy_document!("readonly", original)
    before = stored_document(doc.doc_id)
    {view, path} = mount_beta(conn, doc.doc_id)

    assert has_element?(
             view,
             "[data-test-id='paper-terminal-readonly']",
             "original content is preserved"
           )

    refute has_element?(view, "[data-test-id='paper-terminal-editor']")
    refute has_element?(view, "[data-test-id='paper-terminal-structure-editor']")

    for id <- ["dual-terminal", "malformed-terminal"] do
      request = Ecto.UUID.generate()

      render_hook(view, "paper-block-autosave", %{
        "block_id" => id,
        "title" => "Forged",
        "footer" => "",
        "live" => "false",
        "if_rev" => socket_of(view).assigns.editor_doc.rev,
        "request_id" => request
      })

      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored_document(doc.doc_id) == before
    end

    request = Ecto.UUID.generate()

    render_hook(view, "paper-edit-block", %{
      "block_id" => "dual-terminal",
      "terminal-child-count" => "0",
      "terminal-new-child-id" => "forged-child",
      "terminal-action" => "add",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => request
    })

    assert_reply(view, %{saved: false, request_id: ^request})
    assert stored_document(doc.doc_id) == before

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "[data-test-id='paper-terminal-readonly']")
    assert stored_document(doc.doc_id) == before
  end

  defp mount_beta(conn, doc_id) do
    path = studio_path(doc_id)
    {:ok, view, _html} = live(conn, path)
    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="studio-doc-beta-editor")
    {view, path}
  end

  defp legacy_document!(label, blocks) do
    id = "beta-terminal-#{label}-#{System.unique_integer([:positive])}"
    {:ok, doc} = Content.create_document(@doc_type, %{"doc_id" => id, "title" => label}, @dataset)

    Repo.update_all(from(d in Document, where: d.id == ^doc.id),
      set: [content: %{"blocks" => blocks}]
    )

    stored_document(doc.doc_id)
  end

  defp paragraph(id, value),
    do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp stored_blocks(doc_id), do: stored_document(doc_id).content["blocks"]

  defp stored_document(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc
  end

  defp studio_path(doc_id) do
    scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{Content.published_id(doc_id)}")
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
