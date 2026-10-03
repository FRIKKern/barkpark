defmodule BarkparkWeb.Studio.DeskStatusFilterListsTest do
  @moduledoc """
  A type with a `status` select gets Draft / Published / Archived lists under
  its desk node (`Structure.doc_type_with_filters/1`). Opening one must show
  the documents with that status — not the All list plus a "could not open
  this document" card naming the filter node's id.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "status",
              "title" => "Status",
              "type" => "select",
              "options" => ["draft", "published", "archived"]
            }
          ]
        },
        @dataset
      )

    # The desk filter is `status=<opt>`, which `Content.Query` reads from the
    # row status column (the Studio status select writes it there).
    for {id, status} <- [{"pa", "archived"}, {"pd", "draft"}] do
      {:ok, doc} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => "Post #{status}"},
          @dataset
        )

      doc |> Ecto.Changeset.change(status: status) |> Barkpark.Repo.update!()
    end

    :ok
  end

  test "the Archived list opens and lists only archived posts", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/post-archived"))

    refute html =~ "Studio could not open this document"
    assert html =~ "Post archived"
    refute html =~ "Post draft"
  end
end
