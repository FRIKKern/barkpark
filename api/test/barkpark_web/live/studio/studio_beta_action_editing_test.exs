defmodule BarkparkWeb.Studio.StudioBetaActionEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Content.Document

  @dataset "production"
  @doc_type "beta_action_editing"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta Action editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    raw = "beta-action-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "Beta Action editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  test "generic Beta edits a nested grid Action with exact replay and reload", %{conn: conn} do
    blocks = [grid_section()]
    doc = create_document!("canonical", blocks)
    {view, path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "[data-test-id='paper-action-contextual-editor']")
    assert has_element?(view, "#action-form-beta-action")
    refute has_element?(view, "[data-paper-container-kind='action']")
    assert stored_blocks(doc.doc_id) == blocks
    before_noop = stored_document(doc.doc_id)

    for {id, fields} <- [
          {"absent-action",
           %{
             "action-label" => "",
             "action-href" => "",
             "action-priority" => "secondary"
           }},
          {"nil-action",
           %{
             "action-label" => "",
             "action-href" => "",
             "action-priority" => "secondary"
           }},
          {"unknown-priority",
           %{
             "action-label" => "Quiet",
             "action-href" => "/quiet",
             "action-priority" => "quiet"
           }}
        ] do
      no_op = Ecto.UUID.generate()

      render_hook(
        view,
        "paper-block-autosave",
        Map.merge(fields, %{
          "block_id" => id,
          "if_rev" => socket_of(view).assigns.editor_doc.rev,
          "request_id" => no_op
        })
      )

      assert_reply(view, %{saved: true, request_id: ^no_op})
      assert stored_document(doc.doc_id) == before_noop
    end

    request = Ecto.UUID.generate()

    params = %{
      "block_id" => "beta-action",
      "action-label" => "Open the Beta result",
      "action-href" => "/beta/result",
      "action-priority" => "primary",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => request
    }

    render_hook(view, "paper-block-autosave", params)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^request, rev: saved_rev})

    [saved_section] = stored_blocks(doc.doc_id)
    [before_section] = blocks
    saved_action = Enum.find(saved_section["blocks"], &(&1["id"] == "beta-action"))
    before_action = Enum.find(before_section["blocks"], &(&1["id"] == "beta-action"))
    assert Map.drop(saved_section, ["blocks"]) == Map.drop(before_section, ["blocks"])

    assert Map.drop(saved_action, ["label", "href", "priority"]) ==
             Map.drop(before_action, ["label", "href", "priority"])

    assert Map.take(saved_action, ["label", "href", "priority"]) == %{
             "label" => "Open the Beta result",
             "href" => "/beta/result",
             "priority" => "primary"
           }

    assert Enum.reject(saved_section["blocks"], &(&1["id"] == "beta-action")) ==
             Enum.reject(before_section["blocks"], &(&1["id"] == "beta-action"))

    {:ok, replay, _} = live(conn, path)
    replay |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    render_hook(replay, "paper-block-autosave", params)
    assert_reply(replay, %{saved: true, replayed: true, request_id: ^request, rev: ^saved_rev})
    assert stored_blocks(doc.doc_id) == [saved_section]
    assert has_element?(replay, "#action-label-beta-action[value='Open the Beta result']")

    forged = Ecto.UUID.generate()

    render_hook(replay, "paper-block-autosave", %{
      "block_id" => "malformed-action",
      "action-label" => "Must not persist",
      "if_rev" => socket_of(replay).assigns.editor_doc.rev,
      "request_id" => forged
    })

    assert_reply(replay, %{saved: false, request_id: ^forged})
    assert stored_blocks(doc.doc_id) == [saved_section]
  end

  test "generic Beta mounts legacy Actions without writing identity or defaults", %{conn: conn} do
    blocks = [
      %{
        "type" => "section",
        "layout" => %{"mode" => "grid", "tracks" => 2},
        "blocks" => [
          %{"type" => "action", "unknown" => %{"keep" => true}},
          %{"type" => "action", "label" => nil, "href" => nil, "priority" => nil}
        ]
      }
    ]

    doc = legacy_document!("legacy", blocks)
    before = stored_document(doc.doc_id)
    {view, _path} = mount_beta(conn, doc.doc_id)
    assert has_element?(view, "[data-test-id='paper-action-editor']")
    assert stored_document(doc.doc_id) == before
  end

  defp grid_section do
    %{
      "id" => "beta-grid",
      "type" => "section",
      "layout" => %{"mode" => "grid", "tracks" => 3, "gap" => "md"},
      "variant" => "wide",
      "unknown-section" => ["keep"],
      "blocks" => [
        action("beta-action", %{
          "label" => "Original Beta action",
          "href" => "/beta/original",
          "priority" => "secondary",
          "span" => 2,
          "order" => 3,
          "unknown" => %{"keep" => true}
        }),
        %{"id" => "beta-sibling", "type" => "paragraph", "content" => text("Sibling")},
        action("absent-action", %{}),
        action("nil-action", %{"label" => nil, "href" => nil, "priority" => nil}),
        action("unknown-priority", %{
          "label" => "Quiet",
          "href" => "/quiet",
          "priority" => "quiet"
        }),
        action("malformed-action", %{"href" => ["opaque"], "unknown" => "keep"})
      ]
    }
  end

  defp create_document!(label, blocks) do
    id = "beta-action-#{label}-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => id, "title" => label, "content" => %{"blocks" => blocks}},
        @dataset
      )

    doc
  end

  defp legacy_document!(label, blocks) do
    id = "beta-action-#{label}-#{System.unique_integer([:positive])}"
    {:ok, doc} = Content.create_document(@doc_type, %{"doc_id" => id, "title" => label}, @dataset)

    Repo.update_all(from(d in Document, where: d.id == ^doc.id),
      set: [content: %{"blocks" => blocks}]
    )

    stored_document(doc.doc_id)
  end

  defp mount_beta(conn, doc_id) do
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{Content.published_id(doc_id)}")
    {:ok, view, _} = live(conn, path)
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    {view, path}
  end

  defp action(id, extra), do: Map.merge(%{"id" => id, "type" => "action"}, extra)
  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp stored_blocks(doc_id), do: stored_document(doc_id).content["blocks"]

  defp stored_document(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
