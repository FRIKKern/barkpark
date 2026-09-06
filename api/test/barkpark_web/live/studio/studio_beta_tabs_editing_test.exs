defmodule BarkparkWeb.Studio.StudioBetaTabsEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @doc_type "beta_tabs_editing"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta tabs editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "parent-unknown" => %{"keep" => true},
        "tabs" => [
          %{
            "id" => "row-a",
            "label" => "Before",
            "row-unknown" => [1, 2],
            "blocks" => [paragraph("body-a", "Before body", %{"child-unknown" => true})],
            "children" => [%{"id" => "opaque", "metadata" => "keep"}],
            "content" => %{"opaque" => true}
          },
          %{
            "id" => "row-b",
            "label" => "Second",
            "row-unknown" => "keep-b",
            "blocks" => [paragraph("body-b", "Second body")]
          }
        ]
      }
    ]

    id = "beta-tabs-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => id, "title" => "Tabs", "content" => %{"blocks" => blocks}},
        @dataset
      )

    {:ok, doc: doc}
  end

  test "generic Beta edits nested content and stable panels with replay-safe actions", %{
    conn: conn,
    doc: doc
  } do
    raw = "beta-tabs-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta tabs editing", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{doc.doc_id}")
    {:ok, view, _html} = live(conn, path)

    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="studio-doc-beta-editor")
    assert has_element?(view, "#tabs-form-tabs")
    assert has_element?(view, "[data-tab-row-id='row-a']")
    assert has_element?(view, "#paper-ed-body-a")

    socket = socket_of(view)
    assert socket.assigns.editor_view == :form
    assert socket.assigns.editor_mode == :beta
    assert socket.assigns.editor_type == @doc_type
    assert socket.assigns.editor_doc.doc_id == doc.doc_id
    assert socket.assigns.editor_blocks_synth? == false
    assert socket.assigns[:paper_doc] == nil

    body_request = Ecto.UUID.generate()

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "body-a",
      "patch" => %{
        "content" => [%{"type" => "text", "value" => "After body"}]
      },
      "if_rev" => socket.assigns.editor_doc.rev,
      "request_id" => body_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^body_request})
    after_body = stored_parent(doc.doc_id)
    assert nested_body(after_body, "row-a")["content"] == text("After body")
    assert nested_body(after_body, "row-a")["child-unknown"] == true

    label_request = Ecto.UUID.generate()

    label_params =
      after_body
      |> panel_params()
      |> Map.put("panel-0-label", "After")
      |> write_meta(view, label_request)

    render_hook(view, "paper-block-autosave", label_params)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^label_request})
    labeled = stored_parent(doc.doc_id)
    assert hd(labeled["tabs"])["label"] == "After"
    assert hd(labeled["tabs"])["row-unknown"] == [1, 2]
    assert hd(labeled["tabs"])["children"] == [%{"id" => "opaque", "metadata" => "keep"}]
    assert hd(labeled["tabs"])["content"] == %{"opaque" => true}
    assert labeled["parent-unknown"] == %{"keep" => true}

    up_params =
      labeled
      |> panel_params()
      |> Map.put("panel-action", "up:row-b")
      |> write_meta(view, Ecto.UUID.generate())

    reordered = apply_and_replay(view, doc.doc_id, up_params)
    assert Enum.map(reordered["tabs"], & &1["id"]) == ["row-b", "row-a"]
    assert Enum.find(reordered["tabs"], &(&1["id"] == "row-a"))["label"] == "After"

    add_request = Ecto.UUID.generate()

    add_params =
      reordered
      |> panel_params()
      |> Map.merge(%{
        "panel-action" => "add",
        "panel-new-row-id" => "row-new",
        "panel-new-child-id" => "unused-child"
      })
      |> write_meta(view, add_request)

    render_hook(view, "paper-edit-block", add_params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^add_request,
      rev: add_rev
    })

    after_add = stored_parent(doc.doc_id)
    assert Enum.map(after_add["tabs"], & &1["id"]) == ["row-b", "row-a", "row-new"]

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "[data-tab-row-id='row-new']")
    render_hook(reloaded, "paper-edit-block", add_params)

    assert_reply(reloaded, %{
      saved: true,
      replayed: true,
      request_id: ^add_request,
      rev: ^add_rev
    })

    assert stored_parent(doc.doc_id) == after_add

    remove_params =
      after_add
      |> panel_params()
      |> Map.put("panel-action", "remove:row-new")
      |> write_meta(reloaded, Ecto.UUID.generate())

    after_remove = apply_and_replay(reloaded, doc.doc_id, remove_params)
    assert Enum.map(after_remove["tabs"], & &1["id"]) == ["row-b", "row-a"]
    final_row_a = Enum.find(after_remove["tabs"], &(&1["id"] == "row-a"))
    assert final_row_a["row-unknown"] == [1, 2]
    assert final_row_a["children"] == [%{"id" => "opaque", "metadata" => "keep"}]
    assert final_row_a["content"] == %{"opaque" => true}
    assert hd(final_row_a["blocks"])["child-unknown"] == true
    assert after_remove["parent-unknown"] == %{"keep" => true}

    before_invalid = stored_document(doc.doc_id)
    invalid_request = Ecto.UUID.generate()

    invalid_params =
      after_remove
      |> panel_params()
      |> Map.put("panel-0-id", "wrong-row")
      |> write_meta(reloaded, invalid_request)

    render_hook(reloaded, "paper-block-autosave", invalid_params)

    assert_reply(reloaded, %{
      saved: false,
      rejected: "validation",
      current_rev: current_rev,
      request_id: ^invalid_request
    })

    assert current_rev == before_invalid.rev
    assert stored_document(doc.doc_id).rev == before_invalid.rev
    assert stored_parent(doc.doc_id) == hd(before_invalid.content["blocks"])
  end

  defp apply_and_replay(view, doc_id, params) do
    request_id = params["request_id"]
    render_hook(view, "paper-edit-block", params)

    assert_reply(view, %{
      saved: true,
      replayed: false,
      request_id: ^request_id,
      rev: committed_rev
    })

    after_write = stored_parent(doc_id)
    render_hook(view, "paper-edit-block", params)

    assert_reply(view, %{
      saved: true,
      replayed: true,
      request_id: ^request_id,
      rev: ^committed_rev
    })

    assert stored_parent(doc_id) == after_write
    after_write
  end

  defp panel_params(parent) do
    parent["tabs"]
    |> Enum.with_index()
    |> Enum.reduce(
      %{
        "block_id" => parent["id"],
        "panel-count" => Integer.to_string(length(parent["tabs"])),
        "panel-new-row-id" => "unused-new-row",
        "panel-new-child-id" => "unused-new-child"
      },
      fn {row, index}, params ->
        params
        |> Map.put("panel-#{index}-id", row["id"])
        |> Map.put("panel-#{index}-label", to_string(row["label"] || ""))
      end
    )
  end

  defp write_meta(params, view, request_id) do
    params
    |> Map.put("if_rev", socket_of(view).assigns.editor_doc.rev)
    |> Map.put("request_id", request_id)
  end

  defp stored_parent(doc_id), do: stored_document(doc_id).content["blocks"] |> hd()

  defp stored_document(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc
  end

  defp nested_body(parent, row_id) do
    parent["tabs"]
    |> Enum.find(&(&1["id"] == row_id))
    |> Map.fetch!("blocks")
    |> hd()
  end

  defp paragraph(id, value, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "content" => text(value)}, extra)
  end

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
