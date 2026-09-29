defmodule BarkparkWeb.PaperNestedDefaultReplayTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1]

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.BulldocsLive
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @beta_type "nested_default_replay"

  setup %{conn: conn} do
    ensure_default_scope!()
    pin_paper_canvas!("1")

    for type <- ["paper", @beta_type] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Nested default replay",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "body", "type" => "richText"}
            ]
          },
          @dataset
        )
    end

    raw = "nested-default-replay-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(
        raw,
        "Nested default replay",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}), token: token}
  end

  for host <- [:public, :studio, :beta],
      type <- ~w(expandable steps tabs section form questionnaire),
      event <- ["paper-add-block", "paper-slash-insert"] do
    test "#{host}: lost #{event} acknowledgement replays the original #{type} tree and receipt",
         %{
           conn: conn,
           token: token
         } do
      host = unquote(host)
      type = unquote(type)
      event = unquote(event)
      {id, sibling} = create_document!(host)
      assert stored_blocks(host, id) == [sibling]
      socket = mount_editor(conn, host, id)
      request_id = Ecto.UUID.generate()
      rev = revision(socket, host)

      params =
        Map.merge(
          creation_params(event, type),
          %{"request_id" => request_id, "if_rev" => rev}
        )

      assert {:reply, original_receipt, committed_socket} =
               create_block(host, event, params, socket)

      assert %{saved: true, request_id: ^request_id, replayed: false, rev: saved_rev} =
               original_receipt

      refute saved_rev == rev
      assert stored_revision(host, id) == saved_rev
      assert [^sibling, created] = stored_blocks(host, id)
      child_ids = child_ids(Map.delete(created, "id"))

      expected_child_count = %{
        "section" => 0,
        "expandable" => 1,
        "steps" => 2,
        "tabs" => 2,
        "form" => 1,
        "questionnaire" => 1
      }

      assert length(child_ids) == expected_child_count[type]
      assert length(Enum.uniq([created["id"] | child_ids])) == 1 + length(child_ids)

      # Retry the exact envelope, including its now-stale revision, as after a lost ACK.
      assert {:reply, replay_receipt, replayed_socket} =
               create_block(host, event, params, committed_socket)

      assert replay_receipt == %{original_receipt | replayed: true}
      assert [^sibling, replayed] = stored_blocks(host, id)
      assert replayed == created
      assert stored_revision(host, id) == saved_rev
      assert child_ids(Map.delete(replayed, "id")) == child_ids
      assert created == Blocks.default_block(type, created["id"])

      # The same receipt must still pass fresh authorization; replay is not a write bypass.
      {:ok, _} = Auth.revoke_token(token)

      assert {:reply, %{saved: false, request_id: ^request_id}, _} =
               create_block(host, event, params, replayed_socket)

      assert stored_blocks(host, id) == [sibling, created]
      assert stored_revision(host, id) == saved_rev
    end
  end

  test "stable construction preserves overrides without re-seeding the tree" do
    for type <- ~w(expandable steps tabs section callout field-string) do
      block = Blocks.default_block(type, Blocks.new_block_id("same-request"))
      overrides = %{"fieldName" => "body", "role" => "ingress", "locked" => true}
      stabilized = Paper.request_stable_block(Map.merge(block, overrides), "same-request")
      assert Map.take(stabilized, Map.keys(overrides)) == overrides

      assert Map.drop(stabilized, Map.keys(overrides)) ==
               Blocks.default_block(type, stabilized["id"])
    end

    callout =
      Blocks.default_block("callout", Blocks.new_block_id("same-request"))
      |> Map.merge(%{"tone" => "warning", "collapsible" => true, "collapsed" => true})

    assert Map.delete(Paper.request_stable_block(callout, "same-request"), "id") ==
             Map.delete(callout, "id")
  end

  test "stable construction followed by nested overrides is deterministic" do
    for {type, carrier, key, value} <- [
          {"expandable", "children", "content", [%{"type" => "text", "value" => "Authored"}]},
          {"form", "questions", "prompt", "Authored question"},
          {"questionnaire", "questions", "prompt", "Authored question"}
        ] do
      construct = fn ->
        type
        |> Blocks.default_block(Blocks.new_block_id("nested-override"))
        |> put_in([carrier, Access.at(0), key], value)
      end

      first = construct.()
      retry = construct.()
      assert retry == first
      assert get_in(retry, [carrier, Access.at(0), key]) == value
      assert child_ids(retry) == child_ids(first)
      assert Paper.request_stable_block(retry, "nested-override") == first
    end
  end

  test "request IDs retain the existing hash scheme and unidentified IDs remain fresh" do
    assert Blocks.new_block_id("same-request") == "b-eDJ7Nrseecf5"
    refute Blocks.new_block_id(nil) == Blocks.new_block_id(nil)
    refute Blocks.new_block_id() == Blocks.new_block_id()
  end

  defp child_ids(%{} = value) do
    Enum.flat_map(value, fn
      {"id", id} -> [id]
      {_, nested} -> child_ids(nested)
    end)
  end

  defp child_ids(value) when is_list(value), do: Enum.flat_map(value, &child_ids/1)
  defp child_ids(_), do: []

  defp create_block(:public, event, params, socket),
    do: BulldocsLive.handle_event(event, params, socket)

  defp create_block(_, event, params, socket),
    do: StudioLive.handle_event(event, params, socket)

  defp revision(socket, :beta), do: socket.assigns.editor_doc.rev
  defp revision(socket, _), do: socket.assigns.paper_rev

  defp creation_params("paper-add-block", type), do: %{"block-type" => type}
  defp creation_params("paper-slash-insert", type), do: %{"type" => type}

  defp create_document!(host) do
    id = "nested-default-replay-#{System.unique_integer([:positive])}"

    sibling = %{
      "id" => "preserved-sibling",
      "type" => "paragraph",
      "content" => [
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "Keep sibling"}]}
      ],
      "vendor" => %{"nested" => [1, %{"keep" => true}]}
    }

    doc = persist_document!(host, id, sibling)
    {doc.doc_id, sibling}
  end

  defp persist_document!(:beta, id, sibling) do
    {:ok, doc} =
      Content.create_document(
        @beta_type,
        %{"doc_id" => id, "title" => "Replay", "content" => %{"blocks" => [sibling]}},
        @dataset
      )

    doc
  end

  defp persist_document!(_, id, sibling) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => id,
          "title" => "Replay",
          "blocks" => [sibling]
        })
      )

    doc
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
    :sys.get_state(view.pid).socket
  end

  defp enter_editor(view, :public), do: render_click(view, "paper-toggle-edit", %{})

  defp enter_editor(view, :beta),
    do: view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

  defp enter_editor(view, :studio) do
    if has_element?(view, ~s([data-test-id="paper-edit-toggle"])) do
      view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
    end
  end

  defp stored(:beta, id) do
    {:ok, doc} = Content.get_document(id, @beta_type, @dataset)
    doc
  end

  defp stored(_, id), do: Content.get_paper(id, @dataset)
  defp stored_blocks(host, id), do: stored(host, id).content["blocks"]
  defp stored_revision(:beta, id), do: stored(:beta, id).rev
  defp stored_revision(host, id), do: stored(host, id).content["rev"]
end
