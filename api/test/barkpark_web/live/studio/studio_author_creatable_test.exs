defmodule BarkparkWeb.Studio.StudioAuthorCreatableTest do
  @moduledoc """
  Form submissions offered "+" and "Nytt dokument" in Studio, and both always
  failed with a bare "Kunne ikke opprette": only the public intake can write a
  submission. A type whose desk block declares `"authorCreatable": false` now
  gets no "New" in Studio. It hides the buttons only; the write path still
  answers a create with its own refusal.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"
  @admin "author-creatable-admin"

  test "a desk block with authorCreatable false says the type is not author-creatable" do
    refute PaneBuilder.author_creatable?(%{desk: %{"authorCreatable" => false}})
    assert PaneBuilder.author_creatable?(%{desk: %{}})
    assert PaneBuilder.author_creatable?(%{desk: %{"authorCreatable" => true}})
    assert PaneBuilder.author_creatable?(nil)
  end

  test "Forms declares its submissions not author-creatable" do
    [submission | _] = Barkpark.Plugins.Forms.register_schemas([])
    assert submission.name == "form_submission"
    refute PaneBuilder.author_creatable?(submission)
  end

  describe "the list pane" do
    setup %{conn: conn} do
      TenancyFixtures.ensure_default_scope!()

      {:ok, _} =
        Auth.create_token(
          @admin,
          "author creatable admin",
          @dataset,
          ["read", "write", "admin"],
          TenancyFixtures.default_workspace_id!()
        )

      for {name, desk} <- [{"intake_log", %{"authorCreatable" => false}}, {"field_log", %{}}] do
        {:ok, _} =
          Content.upsert_schema(
            %{
              "name" => name,
              "title" => name,
              "visibility" => "public",
              "desk" => desk,
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            @dataset
          )
      end

      {:ok, conn: Plug.Test.init_test_session(conn, %{"api_token" => @admin})}
    end

    test "offers no New for a type that is not author-creatable", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/intake_log"))
      refute has_element?(view, ~s(button[phx-click="new-document"]))
    end

    # task-631d6ea85517e668: hiding the button was the only guard, so a
    # hand-pushed `new-document` still made a document. The server refuses.
    test "old Studio: a pushed new-document for it makes no document and says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/intake_log"))

      html = render_hook(view, "new-document", %{"type" => "intake_log"})

      assert count("intake_log") == 0
      assert html =~ "cannot be made here"
    end

    test "desk: a pushed new-document for it makes no document and says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/_desk/intake_log"))

      html = render_hook(view, "new-document", %{"type" => "intake_log", "desk-pane" => "1"})

      assert count("intake_log") == 0
      assert html =~ "cannot be made here"
    end

    test "control: a pushed new-document for an ordinary type still makes one", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/field_log"))

      render_hook(view, "new-document", %{"type" => "field_log"})

      assert count("field_log") == 1
    end

    # #25897 review: a type the dataset does not have fell through to a
    # create, so a hand-pushed name made a document of a junk type.
    test "a pushed new-document for a type the dataset does not have makes nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/field_log"))

      for junk <- ["no_such_type", ~s(intake_log"><script>), "INTAKE_LOG"] do
        html = render_hook(view, "new-document", %{"type" => junk})
        assert count(junk) == 0, junk
        assert html =~ "is not a document type in this dataset"
      end
    end

    test "Duplicate is not offered on a document of it, and a pushed duplicate-doc makes none",
         %{conn: conn} do
      {:ok, _} =
        Content.create_document(
          "intake_log",
          %{"doc_id" => "intake-1", "title" => "Intake one", "content" => %{}},
          @dataset
        )

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/intake_log/intake-1"))

      refute has_element?(view, ~s([phx-click="duplicate-doc"]))

      render_hook(view, "duplicate-doc", %{})

      assert count("intake_log") == 1
    end

    test "control: Duplicate is still offered on an ordinary type", %{conn: conn} do
      {:ok, _} =
        Content.create_document(
          "field_log",
          %{"doc_id" => "field-1", "title" => "Field one", "content" => %{}},
          @dataset
        )

      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/field_log/field-1"))

      assert has_element?(view, ~s([phx-click="duplicate-doc"]))
    end

    test "still offers New for an ordinary type", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/field_log"))
      assert has_element?(view, ~s(.pane-add-btn[phx-click="new-document"]))
      assert has_element?(view, ~s(.btn-primary[phx-click="new-document"]))
    end
  end

  defp count(type) do
    import Ecto.Query

    Barkpark.Repo.aggregate(from(d in Barkpark.Content.Document, where: d.type == ^type), :count)
  end
end
