defmodule BarkparkWeb.Integration.V1MediaSecondFolderTest do
  @moduledoc """
  An asset added to a SECOND folder appears in that folder.

  Membership lives on the asset document: `collection` (the primary, first
  folder) plus `collections` (every folder). The search filter matched the
  list with jsonb containment, but handed Postgrex a PRE-ENCODED JSON string,
  which its jsonb codec encoded again, so the parameter became a jsonb string
  scalar no array contains. Only the primary matched: the second folder listed
  0 assets while the asset document named it (r4-lane-c dogfood).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "v1-media-second-folder", [
      "read",
      "write",
      "admin"
    ])

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp folder!(title) do
    id = "col-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.upsert_document(
        "mediaCollection",
        %{"doc_id" => id, "title" => title, "content" => %{"kind" => "folder", "slug" => id}},
        "production",
        source: :api
      )

    doc
  end

  defp upload!(conn) do
    path = Path.join(System.tmp_dir!(), "second-folder-#{:rand.uniform(1_000_000)}.png")
    File.write!(path, Base.decode64!(@png_b64))
    upload = %Plug.Upload{path: path, filename: "pixel.png", content_type: "image/png"}

    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => upload})
    |> json_response(201)
  end

  defp add!(conn, folder, file_id) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/collections/#{folder.doc_id}/members", %{
      "assetId" => file_id
    })
    |> json_response(200)
  end

  defp folder_total(conn, folder) do
    conn
    |> authed()
    |> get(~p"/v1/media/production/collections/#{folder.doc_id}/assets")
    |> json_response(200)
    |> get_in(["result", "total"])
  end

  @tag :requires_plugins
  test "an asset in two folders is listed in both", %{conn: conn} do
    first = folder!("First")
    second = folder!("Second")
    created = upload!(conn)
    file_id = created["result"]["id"]

    add!(conn, first, file_id)
    add!(conn, second, file_id)

    assert folder_total(conn, first) == 1
    assert folder_total(conn, second) == 1, "the asset is missing from its second folder"

    File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
    Media.Renditions.delete_for_file(file_id)
    Assets.delete_for_blob(file_id, "production")
    Content.delete_document(first.doc_id, "mediaCollection", "production")
    Content.delete_document(second.doc_id, "mediaCollection", "production")
  end
end
