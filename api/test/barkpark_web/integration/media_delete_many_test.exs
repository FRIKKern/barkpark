defmodule BarkparkWeb.Integration.MediaDeleteManyTest do
  @moduledoc """
  task-60a5883edeb49cbe: `POST /v1/media/:dataset/delete-many` deletes up to 100
  media files in one request. An id with no file in the dataset is `gone` and
  counts as done; a referenced file is refused without stopping the others.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Media}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @ds "media-delete-many"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup %{conn: conn} do
    ws = create_workspace!("media-many-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "mainImage", "type" => "image"}
          ]
        },
        @ds,
        scope
      )

    raw = "media-many-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "writer", @ds, ["read", "write"], ws.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("x-requested-with", "bp-media-picker")

    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp base(ws, proj, ds \\ @ds), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{ds}"

  defp upload!(conn, ws, proj, ds \\ @ds) do
    tmp = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-pixel.png")
    # Unique trailing bytes: identical uploads share one file id.
    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "pixel.png", content_type: "image/png"}

    resp = post(conn, base(ws, proj, ds) <> "/upload", %{"file" => upload})
    assert resp.status in [200, 201], "upload failed: #{resp.status} #{resp.resp_body}"
    result = Jason.decode!(resp.resp_body)["result"]

    on_exit(fn ->
      case Repo.get(MediaFile, result["id"]) do
        %MediaFile{path: path} when is_binary(path) ->
          File.rm(Path.join(Media.upload_dir(), path))

        _ ->
          :ok
      end
    end)

    {result["id"], Content.published_id(result["assetDocId"])}
  end

  defp delete_many(conn, ws, proj, body), do: post(conn, base(ws, proj) <> "/delete-many", body)

  test "deletes every file in one request; an id already gone counts as done, and a retry is a 200",
       %{conn: conn, ws: ws, proj: proj} do
    {a, _} = upload!(conn, ws, proj)
    {b, _} = upload!(conn, ws, proj)
    missing = Ecto.UUID.generate()

    assert %{"result" => %{"deleted" => [^a, ^b], "gone" => [^missing], "refused" => []}} =
             json_response(delete_many(conn, ws, proj, %{"ids" => [a, b, missing]}), 200)

    refute Repo.get(MediaFile, a)
    refute Repo.get(MediaFile, b)

    assert %{"result" => %{"deleted" => [], "gone" => [^a, ^b, ^missing]}} =
             json_response(delete_many(conn, ws, proj, %{"ids" => "#{a},#{b},#{missing}"}), 200)
  end

  test "a referenced file is refused 409, the others still go, and force deletes it",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {used, used_ref} = upload!(conn, ws, proj)
    {free, _} = upload!(conn, ws, proj)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"title" => "uses it", "mainImage" => %{"asset" => %{"_ref" => used_ref}}},
        @ds,
        scope
      )

    body = json_response(delete_many(conn, ws, proj, %{"ids" => [used, free]}), 409)

    assert %{
             "code" => "conflict",
             "details" => %{
               "deleted" => [^free],
               "gone" => [],
               "refused" => [%{"id" => ^used, "code" => "conflict", "referencedByCount" => 1}]
             }
           } = body["error"]

    assert Repo.get(MediaFile, used)
    refute Repo.get(MediaFile, free)

    assert %{"result" => %{"deleted" => [^used]}} =
             json_response(delete_many(conn, ws, proj, %{"ids" => [used], "force" => true}), 200)

    refute Repo.get(MediaFile, used)
  end

  test "a file of another dataset is not deleted through this one",
       %{conn: conn, ws: ws, proj: proj} do
    {other, _} = upload!(conn, ws, proj, "media-delete-many-other")

    assert %{"result" => %{"deleted" => [], "gone" => [^other]}} =
             json_response(delete_many(conn, ws, proj, %{"ids" => [other]}), 200)

    assert Repo.get(MediaFile, other)
  end

  test "no ids, or more than 100, is refused before anything is deleted",
       %{conn: conn, ws: ws, proj: proj} do
    {a, _} = upload!(conn, ws, proj)

    assert json_response(delete_many(conn, ws, proj, %{"ids" => []}), 422)

    many = [a | Enum.map(1..100, fn _ -> Ecto.UUID.generate() end)]
    assert json_response(delete_many(conn, ws, proj, %{"ids" => many}), 422)
    assert Repo.get(MediaFile, a)
  end

  test "a read-only token is refused 403", %{conn: conn, ws: ws, proj: proj} do
    {a, _} = upload!(conn, ws, proj)
    raw = "media-many-ro-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "reader", @ds, ["read"], ws.id)

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> delete_many(ws, proj, %{"ids" => [a]})

    assert resp.status == 403
    assert Repo.get(MediaFile, a)
  end
end
