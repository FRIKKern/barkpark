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

  # A statement that reads every document's content as text to find a delivery
  # URL: the single-blob LIKE scan or the batched split.
  defp textual_scan?(sql), do: sql =~ "::text LIKE" or sql =~ "string_to_array"

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

  # task-597c98acab512fbf: on a 2 vCPU VM a 50-id request took 172.7 s because
  # each id ran the where-used census twice, and each census scanned every
  # document's content as text twice. The batch now takes one census for all
  # its ids, and still refuses each referenced file on its own.
  test "one textual where-used scan per request, and each referenced file is still refused",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {by_url, _} = upload!(conn, ws, proj)
    {by_ref, by_ref_asset} = upload!(conn, ws, proj)
    free = for _ <- 1..4, do: elem(upload!(conn, ws, proj), 0)

    url_file = Repo.get!(MediaFile, by_url)

    # A raw URL in block JSON, the shape only the textual scan sees.
    Repo.insert!(%Barkpark.Content.Document{
      doc_id: "embeds-#{System.unique_integer([:positive])}",
      type: "paper",
      dataset: @ds,
      title: "Embeds a blob by URL",
      status: "published",
      rev: "rev-#{System.unique_integer([:positive])}",
      content: %{"blocks" => [%{"_type" => "image", "src" => "/media/files/" <> url_file.path}]}
    })

    {:ok, _} =
      Content.create_document(
        "post",
        %{"title" => "uses it", "mainImage" => %{"asset" => %{"_ref" => by_ref_asset}}},
        @ds,
        scope
      )

    ids = [by_url | free] ++ [by_ref]

    {resp, sqls} =
      Barkpark.QueryCounter.sql(fn -> delete_many(conn, ws, proj, %{"ids" => ids}) end)

    body = json_response(resp, 409)
    assert body["error"]["details"]["deleted"] == free
    assert Enum.map(body["error"]["details"]["refused"], & &1["id"]) == [by_url, by_ref]
    assert Enum.all?(body["error"]["details"]["refused"], &(&1["referencedByCount"] == 1))

    textual_scans = Enum.count(sqls, &textual_scan?/1)

    assert textual_scans == 1,
           "expected one textual where-used scan for #{length(ids)} ids, saw #{textual_scans}"

    for id <- free, do: refute(Repo.get(MediaFile, id))
    assert Repo.get(MediaFile, by_url)
    assert Repo.get(MediaFile, by_ref)
  end

  test "WhereUsed.referrers_many/1 answers what referrers/1 answers for each file",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {by_url, _} = upload!(conn, ws, proj)
    {by_ref, by_ref_asset} = upload!(conn, ws, proj)
    {by_sanity, _} = upload!(conn, ws, proj)
    {unused, _} = upload!(conn, ws, proj)

    url_file = Repo.get!(MediaFile, by_url)
    sanity_file = Repo.get!(MediaFile, by_sanity)

    for n <- 1..2 do
      Repo.insert!(%Barkpark.Content.Document{
        doc_id: "embeds-#{n}-#{System.unique_integer([:positive])}",
        type: "paper",
        dataset: @ds,
        title: "Embeds a blob by URL",
        status: if(n == 1, do: "published", else: "draft"),
        rev: "rev-#{System.unique_integer([:positive])}",
        content: %{"blocks" => [%{"src" => "/media/files/" <> url_file.path}]}
      })
    end

    {:ok, _} =
      Content.create_document(
        "post",
        %{"title" => "by ref", "mainImage" => %{"asset" => %{"_ref" => by_ref_asset}}},
        @ds,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "title" => "by sanity id",
          "mainImage" => %{"asset" => %{"_ref" => "image-#{sanity_file.sha1}-1x1-png"}}
        },
        @ds,
        scope
      )

    files = Enum.map([by_url, by_ref, by_sanity, unused], &Repo.get!(MediaFile, &1))
    many = Barkpark.Media.WhereUsed.referrers_many(files)

    shape = fn %{count: count, sample: sample} ->
      {count, sample |> Enum.map(& &1.doc_id) |> Enum.sort()}
    end

    for file <- files do
      assert shape.(Map.fetch!(many, file.id)) ==
               shape.(Barkpark.Media.WhereUsed.referrers(file))
    end

    assert {2, _} = shape.(many[by_url])
    assert {1, _} = shape.(many[by_ref])
    assert {1, _} = shape.(many[by_sanity])
    assert {0, []} = shape.(many[unused])
  end

  test "a forced batch is witnessed from one census and deletes referenced files",
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

    {resp, sqls} =
      Barkpark.QueryCounter.sql(fn ->
        delete_many(conn, ws, proj, %{"ids" => [used, free], "force" => true})
      end)

    assert %{"result" => %{"deleted" => [^used, ^free], "refused" => []}} =
             json_response(resp, 200)

    assert Enum.count(sqls, &textual_scan?/1) == 1
    refute Repo.get(MediaFile, used)
    refute Repo.get(MediaFile, free)
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
