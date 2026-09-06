defmodule BarkparkWeb.Studio.StudioBetaFigureEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Content.Document

  @dataset "production"
  @doc_type "beta_figure_editing"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta Figure editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    raw = "beta-figure-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta Figure editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  test "generic Beta persists a Figure caption and singular rich child with exact retries", %{
    conn: conn
  } do
    blocks = [
      figure(%{
        "caption" => "Before caption",
        "outer-unknown" => %{"keep" => true},
        "child" => paragraph("figure-child", "Before child", %{"child-unknown" => [1, 2]})
      })
    ]

    doc = create_document!("canonical", blocks)
    {view, path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "[data-test-id='paper-figure-editor']")
    assert has_element?(view, "#figure-form-figure input[name='caption'][value='Before caption']")
    assert has_element?(view, "#paper-ed-figure-child")
    refute has_element?(view, "[data-paper-container-kind='figure']")
    assert socket_of(view).assigns[:paper_doc] == nil

    child_request = Ecto.UUID.generate()

    child_params = %{
      "op" => "patch-block",
      "id" => "figure-child",
      "patch" => %{
        "content" => [%{"type" => "text", "value" => "After child"}]
      },
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => child_request
    }

    render_hook(view, "paper-op", child_params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^child_request,
      rev: child_rev
    })

    [after_child] = stored_blocks(doc.doc_id)
    assert is_map(after_child["child"])
    assert after_child["child"]["content"] == text("After child")
    assert after_child["child"]["child-unknown"] == [1, 2]
    assert after_child["caption"] == "Before caption"
    assert after_child["outer-unknown"] == %{"keep" => true}

    {:ok, replay_view, _html} = live(conn, path)
    replay_view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    render_hook(replay_view, "paper-op", child_params)

    assert_reply(replay_view, %{
      saved: true,
      replayed: true,
      request_id: ^child_request,
      rev: ^child_rev
    })

    assert stored_blocks(doc.doc_id) == [after_child]

    changed_retry = put_in(child_params, ["patch", "content"], text("Changed retry"))
    render_hook(replay_view, "paper-op", changed_retry)
    assert_reply(replay_view, %{saved: false, request_id: ^child_request})
    assert stored_blocks(doc.doc_id) == [after_child]

    caption_request = Ecto.UUID.generate()

    caption_params = %{
      "block_id" => "figure",
      "caption" => "After caption",
      "if_rev" => socket_of(replay_view).assigns.editor_doc.rev,
      "request_id" => caption_request
    }

    render_hook(replay_view, "paper-block-autosave", caption_params)

    assert_reply(replay_view, %{
      saved: true,
      replayed: false,
      request_id: ^caption_request,
      rev: caption_rev
    })

    [after_caption] = stored_blocks(doc.doc_id)
    assert after_caption == Map.put(after_child, "caption", "After caption")

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "#paper-ed-figure-child")
    assert has_element?(reloaded, "input[name='caption'][value='After caption']")
    render_hook(reloaded, "paper-block-autosave", caption_params)

    assert_reply(reloaded, %{
      saved: true,
      replayed: true,
      request_id: ^caption_request,
      rev: ^caption_rev
    })

    assert stored_blocks(doc.doc_id) == [after_caption]
  end

  test "legacy id-less Figure child stays projected until an accepted revision-fenced mutation",
       %{
         conn: conn
       } do
    legacy = [
      figure(%{
        "caption" => "Legacy caption",
        "outer-unknown" => "keep",
        "child" => %{
          "type" => "paragraph",
          "content" => text("Legacy child"),
          "child-unknown" => %{"keep" => true}
        }
      })
    ]

    doc = legacy_document!("idless", legacy)
    before = stored_document(doc.doc_id)
    path = studio_path(doc.doc_id)
    {:ok, view, _html} = live(conn, path)
    [projected] = socket_of(view).assigns.editor_blocks
    projected_child_id = projected["child"]["id"]

    assert projected_child_id == "figure-child-0"
    assert stored_document(doc.doc_id) == before

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(view, "[data-test-id='paper-figure-editor']")
    assert has_element?(view, "#paper-ed-#{projected_child_id}")
    assert stored_document(doc.doc_id) == before

    view |> element(~s([data-test-id="editor-mode-classic"])) |> render_click()
    assert stored_document(doc.doc_id) == before
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(view, "#paper-ed-#{projected_child_id}")
    assert stored_document(doc.doc_id) == before

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => projected_child_id,
      "patch" => %{"content" => text("Persisted child")},
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => request_id
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^request_id})
    [persisted] = stored_blocks(doc.doc_id)
    assert persisted["child"]["id"] == projected_child_id
    assert persisted["child"]["content"] == text("Persisted child")
    assert persisted["child"]["child-unknown"] == %{"keep" => true}
    assert persisted["outer-unknown"] == "keep"
  end

  test "a Figure child ID duplicated by a sibling keeps generic Beta unavailable", %{conn: conn} do
    duplicate = "duplicate-child"

    blocks = [
      figure(%{"child" => paragraph(duplicate, "Inside")}),
      paragraph(duplicate, "Outside")
    ]

    doc = legacy_document!("duplicate", blocks)
    before = stored_document(doc.doc_id)
    path = studio_path(doc.doc_id)
    {:ok, view, html} = live(conn, path)
    socket = socket_of(view)

    assert socket.assigns.editor_mode == :classic
    assert socket.assigns.editor_blocks == []
    assert socket.assigns.editor_blocks_identity_error == {:duplicate_id, duplicate}
    refute html =~ ~s(data-test-id="editor-mode-beta")
    assert has_element?(view, ~s([data-test-id="studio-beta-identity-error"]))
    refute has_element?(view, "[data-test-id='paper-figure-editor']")

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => duplicate,
      "patch" => %{"content" => text("Forged")},
      "if_rev" => socket.assigns.editor_doc.rev,
      "request_id" => request_id
    })

    assert_reply(view, %{saved: false, request_id: ^request_id})
    assert stored_document(doc.doc_id) == before
  end

  defp mount_beta(conn, doc_id) do
    path = studio_path(doc_id)
    {:ok, view, _html} = live(conn, path)
    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="studio-doc-beta-editor")
    {view, path}
  end

  defp create_document!(label, blocks) do
    id = "beta-figure-#{label}-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => id, "title" => label, "content" => %{"blocks" => blocks}},
        @dataset
      )

    doc
  end

  defp legacy_document!(label, blocks) do
    id = "beta-figure-#{label}-#{System.unique_integer([:positive])}"
    {:ok, doc} = Content.create_document(@doc_type, %{"doc_id" => id, "title" => label}, @dataset)

    Repo.update_all(from(d in Document, where: d.id == ^doc.id),
      set: [content: %{"blocks" => blocks}]
    )

    stored_document(doc.doc_id)
  end

  defp figure(extra), do: Map.merge(%{"id" => "figure", "type" => "figure"}, extra)

  defp paragraph(id, value, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "content" => text(value)}, extra)
  end

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
