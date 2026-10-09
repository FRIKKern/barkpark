defmodule BarkparkWeb.Studio.ModalA11yTest do
  @moduledoc """
  wbqs-api-studio-modal-a11y — the unpublish-guard-modal and the
  valueref-writeback-modal were the last two Studio modals missing the
  role=dialog / aria-modal / aria-labelledby / phx-window-keydown /
  phx-key=escape quintet every sibling modal in
  `BarkparkWeb.Studio.Components.Modals` already carries. Template-attribute
  only — the close handlers (`close-unpublish-guard`,
  `valueref-writeback-close`) already existed and worked; this asserts the
  markup now exposes the dialog semantics AND that Escape actually reaches
  the existing handler and closes the modal.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @schema_name "post"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @schema_name,
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"},
            %{"name" => "rel", "title" => "Related", "type" => "reference", "refType" => "post"}
          ]
        },
        @dataset
      )

    {:ok, target_draft} =
      Content.create_document(
        @schema_name,
        %{"doc_id" => "ma11y-target", "title" => "Target Post", "content" => %{"body" => "t"}},
        @dataset
      )

    {:ok, _} =
      Content.publish_document(Content.published_id(target_draft.doc_id), @schema_name, @dataset)

    {:ok, ref_draft} =
      Content.create_document(
        @schema_name,
        %{
          "doc_id" => "ma11y-referrer",
          "title" => "Referrer Post",
          "content" => %{"body" => "r", "rel" => "ma11y-target"}
        },
        @dataset
      )

    {:ok, _} =
      Content.publish_document(Content.published_id(ref_draft.doc_id), @schema_name, @dataset)

    {:ok, _edge} =
      Content.add_edge("ma11y-referrer", "ma11y-target", "references",
        dataset: @dataset,
        plugin_source: nil
      )

    {:ok, conn: conn}
  end

  describe "unpublish-guard-modal" do
    test "exposes dialog role, labelled title, and escape-close", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ma11y-target"))

      html = render_click(view, "unpublish", %{})

      assert html =~ ~s(data-test-id="unpublish-guard-modal")
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="unpublish-guard-modal-title")
      assert html =~ ~s(id="unpublish-guard-modal-title")
      assert html =~ ~s(phx-window-keydown="close-unpublish-guard")
      assert html =~ ~s(phx-key="escape")
    end

    test "Escape closes it and the doc stays published", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ma11y-target"))

      html = render_click(view, "unpublish", %{})
      assert html =~ ~s(data-test-id="unpublish-guard-modal")

      html = render_keydown(view, "close-unpublish-guard", %{"key" => "Escape"})

      refute html =~ ~s(data-test-id="unpublish-guard-modal")

      assert {:ok, pub} = Content.get_document("ma11y-target", @schema_name, @dataset)
      assert pub.status == "published"
    end
  end

  # role/aria/Escape alone left focus on the opener behind the dialog: Tab
  # walked the page underneath it. ModalFocus moves focus in, traps Tab and
  # hands focus back to the opener on close, as on every Modals dialog.
  defp dialog(html, test_id) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-test-id="#{test_id}"]))
  end

  describe "focus moves into the dialog" do
    test "the unpublish guard carries ModalFocus and starts on Cancel", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ma11y-target"))

      guard = view |> render_click("unpublish", %{}) |> dialog("unpublish-guard-modal")

      assert LazyHTML.attribute(guard, "phx-hook") == ["ModalFocus"]
      assert LazyHTML.attribute(guard, "id") == ["unpublish-guard-dialog"]

      first = LazyHTML.query(guard, "[data-modal-focus]")

      assert LazyHTML.attribute(first, "phx-click") == ["close-unpublish-guard"],
             "the safe choice, Cancel, must take focus first in a destructive dialog"
    end

    test "the shared-value dialog carries ModalFocus", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ma11y-target"))

      panel =
        view
        |> render_hook("paper-valueref-inspect", %{"target" => "ma11y-target", "field" => "title"})
        |> dialog("valueref-writeback-modal")

      assert LazyHTML.attribute(panel, "phx-hook") == ["ModalFocus"]
      assert LazyHTML.attribute(panel, "id") == ["valueref-writeback-dialog"]
    end
  end

  describe "valueref-writeback-modal" do
    test "exposes dialog role, labelled title, and escape-close", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ma11y-target"))

      html =
        render_hook(view, "paper-valueref-inspect", %{
          "target" => "ma11y-target",
          "field" => "title"
        })

      assert html =~ ~s(data-test-id="valueref-writeback-modal")
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="valueref-writeback-modal-title")
      assert html =~ ~s(id="valueref-writeback-modal-title")
      assert html =~ ~s(phx-window-keydown="valueref-writeback-close")
      assert html =~ ~s(phx-key="escape")
    end

    test "Escape closes it", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ma11y-target"))

      html =
        render_hook(view, "paper-valueref-inspect", %{
          "target" => "ma11y-target",
          "field" => "title"
        })

      assert html =~ ~s(data-test-id="valueref-writeback-modal")

      html = render_keydown(view, "valueref-writeback-close", %{"key" => "Escape"})

      refute html =~ ~s(data-test-id="valueref-writeback-modal")
    end
  end
end
