defmodule BarkparkWeb.Integration.V1MediaTypeFiltersTest do
  @moduledoc """
  task-774f99d9dd029e24 — the file picker's filters on GET /v1/media/:ds:
  `exclude_type=image` and `mime=application/pdf,text/*` (exact types and
  `type/*` families), applied server-side so `total`/`hasMore` page them, and
  combinable with the existing filters. A bad entry is a 400 naming it.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Media}

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @ds "production"

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "v1-media-type-filters", [
      "read",
      "write",
      "admin"
    ])

    files =
      for {name, bytes} <- [
            {"pixel.png", Base.decode64!(@png_b64)},
            {"doc.pdf", "%PDF-1.4\n%fixture\n"},
            {"note.txt", "plain text"},
            {"data.json", ~s({"a": 1})}
          ],
          into: %{} do
        path = Path.join(System.tmp_dir!(), "tf-#{System.unique_integer([:positive])}-#{name}")
        File.write!(path, bytes <> "#{System.unique_integer([:positive])}")

        id =
          scoped_conn()
          |> put_req_header("authorization", "Bearer barkpark-dev-token")
          |> post("/v1/media/#{@ds}/upload", %{"file" => %Plug.Upload{path: path, filename: name}})
          |> json_response(201)
          |> get_in(["result", "id"])

        {:ok, file} = Media.get_file(id)
        {name, file}
      end

    %{files: files}
  end

  defp list(query) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> get("/v1/media/#{@ds}?#{query}")
  end

  defp ids(query),
    do: json_response(list(query), 200)["result"]["assets"] |> MapSet.new(& &1["id"])

  defp ids_of(files, names), do: MapSet.new(names, &files[&1].id)

  test "the fixture mime types are what the filters assume", %{files: f} do
    assert f["pixel.png"].mime_type == "image/png"
    assert f["doc.pdf"].mime_type == "application/pdf"
    assert f["note.txt"].mime_type =~ "text/plain"
    assert f["data.json"].mime_type == "application/json"
  end

  test "exclude_type=image drops images and keeps everything else", %{files: f} do
    got = ids("exclude_type=image&limit=100")
    refute f["pixel.png"].id in got
    assert MapSet.subset?(ids_of(f, ["doc.pdf", "note.txt", "data.json"]), got)
  end

  test "mime=application/pdf,text/* keeps exactly the PDF and the text family", %{files: f} do
    got = ids("mime=application/pdf,text/*&limit=100")
    assert MapSet.subset?(ids_of(f, ["doc.pdf", "note.txt"]), got)
    refute f["pixel.png"].id in got
    refute f["data.json"].id in got
  end

  test "the two combine with each other and with the existing type prefix", %{files: f} do
    got = ids("mime=image/*,application/*&exclude_type=image&limit=100")
    assert MapSet.subset?(ids_of(f, ["doc.pdf", "data.json"]), got)
    refute f["pixel.png"].id in got

    got = ids("type=application/&mime=application/pdf,text/*&limit=100")
    assert f["doc.pdf"].id in got
    refute f["note.txt"].id in got
  end

  test "paginated server-side: total counts the filtered set, pages walk it", %{files: f} do
    body = json_response(list("mime=application/pdf,text/*&limit=1"), 200)["result"]
    assert length(body["assets"]) == 1
    assert body["total"] >= 2
    assert body["hasMore"] == true

    page2 = json_response(list("mime=application/pdf,text/*&limit=1&offset=1"), 200)["result"]
    refute hd(page2["assets"])["id"] == hd(body["assets"])["id"]
    refute f["pixel.png"].id in MapSet.new(page2["assets"], & &1["id"])
  end

  test "an invalid entry is a 400 that names it" do
    for {query, named} <- [
          {"mime=application/pdf,not-a-mime", "not-a-mime"},
          {"mime=*/*", "*/*"},
          {"mime=text/*x", "text/*x"},
          {"exclude_type=image/png", "image/png"},
          {"exclude_type=%25", "%"}
        ] do
      resp = list(query)
      assert resp.status == 400, "#{query} answered #{resp.status}"
      assert json_response(resp, 400)["error"]["message"] =~ inspect(named)
    end

    too_many = Enum.map_join(1..21, ",", &"text/x#{&1}")
    assert json_response(list("mime=#{too_many}"), 400)["error"]["message"] =~ "at most 20"
  end
end
