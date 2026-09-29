defmodule BarkparkWeb.PaperContextualCreationTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1]

  alias Barkpark.{Auth, Content}
  alias Barkpark.PortableDoc.Render

  @dataset "production"
  @beta_type "contextual_creation"

  setup %{conn: conn} do
    ensure_default_scope!()
    pin_paper_canvas!("1")

    for type <- ["paper", @beta_type] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Contextual creation",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset
        )
    end

    token = "contextual-creation-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        token,
        "Contextual creation",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token})}
  end

  for host <- [:public, :studio, :beta], type <- ~w(paper-links expandable bar-chart) do
    test "#{host}: create, edit, remount and delete #{type} without changing siblings", %{
      conn: conn
    } do
      host = unquote(host)
      type = unquote(type)
      {id, original} = create_document!(host)
      view = mount_editor(conn, host, id)

      assert has_element?(view, ~s([data-test-id="paper-add-block"] option[value="#{type}"]))
      add_params = wire_params(view, %{"block-type" => type})
      view |> element(~s([data-test-id="paper-add-block"])) |> render_submit(add_params)
      request = add_params["request_id"]
      assert_reply(view, %{saved: true, request_id: ^request})

      [sibling, created] = stored_blocks(host, id)
      assert sibling == original
      assert created["type"] == type
      assert String.starts_with?(created["id"], "b-")
      assert has_element?(view, editor_selector(type))
      assert_seed(created)

      edit_created(view, created)
      [^original, edited] = stored_blocks(host, id)
      assert_edited(edited)

      # A stale authoring event cannot overwrite the newly persisted component.
      stale =
        Map.merge(add_params, %{
          "block_id" => created["id"],
          "request_id" => Ecto.UUID.generate(),
          "title" => "Stale",
          "summary" => "Stale"
        })

      render_hook(view, "paper-block-autosave", stale)
      stale_request = stale["request_id"]
      assert_reply(view, %{saved: false, request_id: ^stale_request})
      assert stored_blocks(host, id) == [original, edited]

      reloaded = mount_editor(conn, host, id)
      assert has_element?(reloaded, editor_selector(type))
      assert mounted_blocks(reloaded, host) == [original, edited]
      assert render(reloaded) =~ edited_copy(type)
      reader = Render.render_block(edited, %{style: :article})
      assert reader =~ edited_copy(type)

      delete_params = wire_params(reloaded, %{"id" => created["id"]})
      render_hook(reloaded, "paper-delete-block", delete_params)
      delete_request = delete_params["request_id"]
      assert_reply(reloaded, %{saved: true, request_id: ^delete_request})
      assert stored_blocks(host, id) == [original]
      assert mounted_blocks(mount_editor(conn, host, id), host) == [original]
    end
  end

  for host <- [:public, :studio, :beta],
      {type, key} <- [{"bar-chart", "max"}, {"paper-links", "layout"}],
      shape <- [:absent, nil, "", "  ", %{"future" => [1]}] do
    test "#{host}: #{type} optional #{inspect(shape)} survives full forms, edits, clears and remount",
         %{conn: conn} do
      host = unquote(host)
      type = unquote(type)
      key = unquote(key)
      shape = unquote(Macro.escape(shape))
      block = BarkparkWeb.Studio.StudioLive.Blocks.default_block(type, "optional")
      block = put_source_shape(block, key, shape)
      block = Map.put(block, "vendor", %{"nested" => [1, 2]})
      block = if type == "bar-chart", do: Map.put(block, "title", "Legacy title"), else: block
      {id, sibling} = create_document!(host, [block])
      view = mount_editor(conn, host, id)
      selector = "##{type}-form-optional"
      submit(view, selector, %{})
      assert stored_blocks(host, id) == [sibling, block]

      edits =
        if type == "bar-chart",
          do: %{"bar-0-label" => "Edited row"},
          else: %{"ref-action" => "add"}

      submit(view, selector, edits)
      [^sibling, edited] = stored_blocks(host, id)
      assert Map.fetch(edited, key) == Map.fetch(block, key)
      assert edited["vendor"] == block["vendor"]
      assert edited["title"] == block["title"]
      reloaded = mount_editor(conn, host, id)
      assert mounted_blocks(reloaded, host) == [sibling, edited]
      value = if type == "bar-chart", do: "20", else: "compact"
      submit(reloaded, selector, %{key => value})
      [^sibling, changed] = stored_blocks(host, id)
      assert changed[key] == if(type == "bar-chart", do: 20, else: "compact")
      submit(reloaded, selector, %{key => ""})
      [^sibling, cleared] = stored_blocks(host, id)
      assert Map.fetch!(cleared, key) == nil
      assert Map.drop(cleared, [key]) == Map.drop(edited, [key])
      assert mounted_blocks(mount_editor(conn, host, id), host) == [sibling, cleared]
    end
  end

  for host <- [:public, :studio, :beta],
      shape <- [:absent, nil, false, true, "true", "", 0, %{"future" => true}] do
    test "#{host}: chart visibility #{inspect(shape)} and numeric strings survive whole-form editing",
         %{conn: conn} do
      host = unquote(host)
      shape = unquote(Macro.escape(shape))

      block =
        BarkparkWeb.Studio.StudioLive.Blocks.default_block("bar-chart", "whole-chart")
        |> Map.delete("values")

      block = put_source_shape(block, "values", shape)

      rows = [
        %{"label" => "First", "value" => "12.00", "vendor" => %{"nested" => [1]}},
        %{"label" => "Second", "value" => "6"}
      ]

      block = Map.put(block, "bars", rows)
      {id, sibling} = create_document!(host, [block])
      view = mount_editor(conn, host, id)
      selector = "#bar-chart-form-whole-chart"
      submit(view, selector, %{})
      assert stored_blocks(host, id) === [sibling, block]
      submit(view, selector, %{"bar-0-label" => "Changed"})
      edited = put_in(block, ["bars", Access.at(0), "label"], "Changed")
      assert stored_blocks(host, id) === [sibling, edited]
      reloaded = mount_editor(conn, host, id)
      assert mounted_blocks(reloaded, host) === [sibling, edited]

      # Use the real checkbox form selection and its hidden unchecked fallback.
      toggle = not (block["values"] == true)
      params = wire_params(reloaded, %{})
      reloaded |> form(selector, %{"values" => toggle}) |> render_submit(params)
      request = params["request_id"]
      assert_reply(reloaded, %{saved: true, request_id: ^request})
      toggled = Map.put(edited, "values", toggle)
      assert stored_blocks(host, id) === [sibling, toggled]
      submit(reloaded, selector, %{"bar-0-value" => "15.5"})
      changed = put_in(toggled, ["bars", Access.at(0), "value"], 15.5)
      assert stored_blocks(host, id) === [sibling, changed]
      assert mounted_blocks(mount_editor(conn, host, id), host) === [sibling, changed]
    end
  end

  for host <- [:public, :studio, :beta], shape <- [:absent, nil, ""] do
    test "#{host}: chart label #{inspect(shape)} survives no-op, unrelated edits and deliberate edits",
         %{conn: conn} do
      host = unquote(host)
      shape = unquote(Macro.escape(shape))

      row =
        put_source_shape(
          %{"value" => "12.00", "vendor" => %{"nested" => [1, nil]}},
          "label",
          shape
        )

      other_row = %{"label" => "Keep", "value" => "6", "vendor" => %{"opaque" => true}}

      block =
        BarkparkWeb.Studio.StudioLive.Blocks.default_block("bar-chart", "label-chart")
        |> Map.put("bars", [row, other_row])

      {id, sibling} = create_document!(host, [block])
      view = mount_editor(conn, host, id)
      selector = "#bar-chart-form-label-chart"
      submit(view, selector, %{})
      assert stored_blocks(host, id) === [sibling, block]
      reloaded = mount_editor(conn, host, id)
      assert mounted_blocks(reloaded, host) === [sibling, block]

      submit(reloaded, selector, %{"bar-1-label" => "Changed sibling row", "bar-0-value" => "15"})

      changed =
        block
        |> put_in(["bars", Access.at(0), "value"], 15)
        |> put_in(["bars", Access.at(1), "label"], "Changed sibling row")

      assert stored_blocks(host, id) === [sibling, changed]
      reloaded = mount_editor(conn, host, id)
      assert mounted_blocks(reloaded, host) === [sibling, changed]

      submit(reloaded, selector, %{"bar-0-label" => "Authored label"})
      authored = put_in(changed, ["bars", Access.at(0), "label"], "Authored label")
      assert stored_blocks(host, id) === [sibling, authored]
      submit(reloaded, selector, %{"bar-0-label" => ""})
      cleared = put_in(authored, ["bars", Access.at(0), "label"], "")
      assert stored_blocks(host, id) === [sibling, cleared]
      assert mounted_blocks(mount_editor(conn, host, id), host) === [sibling, cleared]
    end
  end

  defp put_source_shape(block, _key, :absent), do: block
  defp put_source_shape(block, key, value), do: Map.put(block, key, value)

  defp assert_seed(%{"type" => "paper-links"} = block) do
    assert block["refs"] == []
    refute Render.render_block(block, %{style: :article}) =~ "/papers/"
  end

  defp assert_seed(%{"type" => "expandable"} = block) do
    assert [%{"id" => child_id, "type" => "paragraph"}] = block["children"]
    assert child_id != block["id"]
    assert block["open"] == false
    refute Map.has_key?(block, "blocks")
  end

  defp assert_seed(%{"type" => "bar-chart"} = block) do
    assert Enum.all?(block["bars"], &(&1["value"] > 0))
    html = Render.render_block(block, %{style: :article})
    assert html =~ "Sample A"
    assert html =~ "width:100%"
    assert html =~ "width:50%"
  end

  defp edit_created(view, %{"type" => "paper-links", "id" => id}) do
    submit(view, "#paper-links-form-#{id}", %{"ref-action" => "add"})

    submit(view, "#paper-links-form-#{id}", %{
      "ref-0-slug" => "authored-destination",
      "ref-0-title" => "Authored reference",
      "ref-0-prefer-authored-copy" => "true"
    })

    submit(view, "#paper-links-title-form-#{id}", %{"title" => "Related work"})
  end

  defp edit_created(view, %{"type" => "expandable", "id" => id, "children" => [child]}) do
    submit(view, "#expandable-form-#{id}", %{"summary" => "Authored details", "open" => "true"})
    params = wire_params(view, %{"block_id" => child["id"], "text" => "Authored nested body"})
    render_hook(view, "paper-block-autosave", params)
    request = params["request_id"]
    assert_reply(view, %{saved: true, request_id: ^request})
  end

  defp edit_created(view, %{"type" => "bar-chart", "id" => id}) do
    submit(view, "#bar-chart-form-#{id}", %{
      "bar-0-label" => "Authored count",
      "bar-0-value" => "12",
      "bar-1-value" => "3",
      "values" => "true"
    })
  end

  defp submit(view, selector, params) do
    params = wire_params(view, params)
    view |> form(selector) |> render_submit(params)
    request = params["request_id"]
    assert_reply(view, %{saved: true, request_id: ^request})
  end

  defp assert_edited(%{"type" => "paper-links"} = block) do
    assert block["title"] == "Related work"

    assert [
             %{
               "slug" => "authored-destination",
               "title" => "Authored reference",
               "prefer_authored_copy" => true
             }
           ] = block["refs"]
  end

  defp assert_edited(%{"type" => "expandable"} = block) do
    assert block["summary"] == "Authored details"
    assert block["open"] == true

    assert [
             %{
               "type" => "paragraph",
               "content" => [%{"type" => "text", "value" => "Authored nested body"}]
             }
           ] = block["children"]
  end

  defp assert_edited(%{"type" => "bar-chart"} = block) do
    refute Map.has_key?(block, "title")
    assert block["values"] == true

    assert [%{"label" => "Authored count", "value" => 12}, %{"label" => "Sample B", "value" => 3}] =
             block["bars"]
  end

  defp edited_copy("paper-links"), do: "Authored reference"
  defp edited_copy("expandable"), do: "Authored details"
  defp edited_copy("bar-chart"), do: "Authored count"
  defp editor_selector("paper-links"), do: ~s([data-test-id="paper-links-contextual-editor"])
  defp editor_selector("expandable"), do: ~s([data-test-id="paper-expandable-editor"])
  defp editor_selector("bar-chart"), do: ~s([data-test-id="paper-bar-chart-contextual-editor"])

  defp create_document!(host, extra_blocks \\ []) do
    id = "contextual-creation-#{System.unique_integer([:positive])}"

    original = %{
      "id" => "preserved",
      "type" => "paragraph",
      "content" => [
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "Keep sibling"}]}
      ],
      "vendor" => %{"nested" => [1, %{"keep" => true}]}
    }

    stored_id =
      if host == :beta do
        {:ok, doc} =
          Content.create_document(
            @beta_type,
            %{
              "doc_id" => id,
              "title" => "Creation",
              "content" => %{"blocks" => [original | extra_blocks]}
            },
            @dataset
          )

        doc.doc_id
      else
        {:ok, _} =
          Content.upsert_paper(
            Barkpark.LabelFixtures.paper_attrs(%{
              "slug" => id,
              "title" => "Creation",
              "blocks" => [original | extra_blocks]
            })
          )

        id
      end

    {stored_id, original}
  end

  defp mount_editor(conn, host, id) do
    path =
      case host do
        :public -> "/papers/#{id}"
        :studio -> scoped_studio("/d/#{@dataset}/studio/paper/#{id}")
        :beta -> scoped_studio("/d/#{@dataset}/studio/#{@beta_type}/#{Content.published_id(id)}")
      end

    {:ok, view, _} = live(conn, path)

    case host do
      :public -> render_click(view, "paper-toggle-edit", %{})
      :studio -> :ok
      :beta -> view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    end

    view
  end

  defp stored_blocks(:beta, id) do
    {:ok, doc} = Content.get_document(id, @beta_type, @dataset)
    doc.content["blocks"]
  end

  defp stored_blocks(_, id), do: Content.get_paper(id, @dataset).content["blocks"]

  defp mounted_blocks(view, :beta),
    do: :sys.get_state(view.pid).socket.assigns.editor_doc.content["blocks"]

  defp mounted_blocks(view, :studio),
    do: :sys.get_state(view.pid).socket.assigns.paper_doc.content["blocks"]

  defp mounted_blocks(view, :public), do: :sys.get_state(view.pid).socket.assigns.edit_blocks

  defp wire_params(view, params) do
    assigns = :sys.get_state(view.pid).socket.assigns
    rev = if assigns[:editor_mode] == :beta, do: assigns.editor_doc.rev, else: assigns.paper_rev
    Map.merge(params, %{"request_id" => Ecto.UUID.generate(), "if_rev" => rev})
  end
end
