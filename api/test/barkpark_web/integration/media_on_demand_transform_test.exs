defmodule BarkparkWeb.Integration.MediaOnDemandTransformTest do
  @moduledoc """
  Upload stores the original and its metadata in one document write and
  builds no renditions; sizes, crops and formats are made on the first GET
  and cached (task-50cabce448b02af7, FRIKKern/barkpark#23016).

  Uses the `:image` dep's bundled libvips NIF, which the mix-test lane has; it
  does not need the `vips` CLI that `:requires_vips` tests need.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the media plugin owns mediaAsset, its upload hook and the media routes
  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content.Revision
  alias Barkpark.Media
  alias Barkpark.Media.Transform
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  # Counts backend calls, then delegates to the real libvips backend.
  defmodule CountingBackend do
    @behaviour Barkpark.Media.ImageBackend
    alias Barkpark.Media.ImageBackend.Vix

    def count, do: :counters.get(Application.fetch_env!(:barkpark, __MODULE__), 1)

    @impl true
    def render(src, dest, spec, wm) do
      bump()
      Vix.render(src, dest, spec, wm)
    end

    @impl true
    def transform(src, dest, plan, wm) do
      bump()
      # Widen the race window so concurrent first requests overlap.
      Process.sleep(100)
      Vix.transform(src, dest, plan, wm)
    end

    @impl true
    def available?, do: true

    @impl true
    def avif?, do: Vix.avif?()

    defp bump, do: :counters.add(Application.fetch_env!(:barkpark, __MODULE__), 1, 1)
  end

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "on-demand-transform", [
      "read",
      "write",
      "admin"
    ])

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  # 600x400 JPEG: left half red, right half blue, so a crop's position shows
  # in its pixels.
  defp two_tone_jpeg do
    {:ok, red} = Image.new(300, 400, color: [255, 0, 0])
    {:ok, blue} = Image.new(300, 400, color: [0, 0, 255])
    {:ok, joined} = Vix.Vips.Operation.join(red, blue, :VIPS_DIRECTION_HORIZONTAL)
    path = Path.join(System.tmp_dir!(), "two-tone-#{System.unique_integer([:positive])}.jpg")
    {:ok, _} = Image.write(joined, path, quality: 95)
    path
  end

  defp upload(conn, extra \\ %{}) do
    file = %Plug.Upload{
      path: two_tone_jpeg(),
      filename: "two-tone.jpg",
      content_type: "image/jpeg"
    }

    created =
      conn
      |> authed()
      |> post(~p"/v1/media/production/upload", Map.put(extra, "file", file))
      |> json_response(201)

    on_exit(fn -> cleanup(created) end)
    created["result"]
  end

  defp cleanup(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  defp renditions_dir(id), do: Path.join([Media.upload_dir(), "_renditions", id])

  defp transform_files(id) do
    case File.ls(Path.join(renditions_dir(id), "t")) do
      {:ok, names} -> Enum.reject(names, &String.starts_with?(&1, "."))
      _ -> []
    end
  end

  defp get_image(url, headers \\ []) do
    conn = Enum.reduce(headers, scoped_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
    get(conn, url)
  end

  defp content_type(resp) do
    [value] = get_resp_header(resp, "content-type")
    value |> String.split(";") |> hd()
  end

  defp decode(body) do
    {:ok, image} = Image.from_binary(body)
    image
  end

  defp size(image), do: {Image.width(image), Image.height(image)}

  # Mean colour of the image's centre pixel, as {r, g, b}.
  defp centre_rgb(image) do
    {:ok, [r, g, b | _]} =
      Vix.Vips.Image.get_pixel(image, div(Image.width(image), 2), div(Image.height(image), 2))

    {round(r), round(g), round(b)}
  end

  defp swap_backend(module) do
    original = Application.get_env(:barkpark, :image_backend)
    Application.put_env(:barkpark, :image_backend, module)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :image_backend)
        val -> Application.put_env(:barkpark, :image_backend, val)
      end
    end)
  end

  describe "upload" do
    test "stores the original and its metadata in one write, and builds no renditions",
         %{conn: conn} do
      result = upload(conn, %{"tags" => "cover,spring"})
      id = result["id"]

      refute File.exists?(renditions_dir(id)),
             "upload must not build renditions; found #{inspect(File.ls(renditions_dir(id)))}"

      doc = Assets.find_by_media_file_id(id, "production")
      assert doc.content["bp_processing_status"] == "ready"
      assert doc.content["fileInfo"]["width"] == "600"
      assert doc.content["fileInfo"]["height"] == "400"
      assert "data:image/jpeg;base64," <> _ = doc.content["fileInfo"]["lqip"]
      assert doc.content["tags"] == ["cover", "spring"]
      assert doc.content["bp_cdn_status"] in ["skipped", "published"]

      writes =
        Repo.aggregate(
          from(r in Revision, where: r.doc_id in [^"asset-#{id}", ^"drafts.asset-#{id}"]),
          :count
        )

      assert writes == 1, "expected one asset document write per upload, saw #{writes}"
    end
  end

  describe "GET /media/files/*path with transform parameters" do
    test "w resizes, is cached after the first request, and revalidates", %{conn: conn} do
      result = upload(conn)
      url = result["originalUrl"] <> "?w=300"

      first = get_image(url)
      assert first.status == 200
      assert content_type(first) == "image/jpeg"
      assert get_resp_header(first, "cache-control") == ["public, max-age=2592000"]
      assert get_resp_header(first, "vary") == ["Accept"]
      assert size(decode(first.resp_body)) == {300, 200}

      [cached] = transform_files(result["id"])
      cached_path = Path.join([renditions_dir(result["id"]), "t", cached])
      {:ok, %File.Stat{mtime: mtime}} = File.stat(cached_path, time: :posix)

      second = get_image(url)
      assert second.resp_body == first.resp_body
      assert transform_files(result["id"]) == [cached]
      assert {:ok, %File.Stat{mtime: ^mtime}} = File.stat(cached_path, time: :posix)

      [etag] = get_resp_header(first, "etag")
      assert get_image(url, [{"if-none-match", etag}]).status == 304
    end

    test "fit=crop with fm=webp returns the exact box in WebP", %{conn: conn} do
      result = upload(conn)
      resp = get_image(result["originalUrl"] <> "?w=200&h=200&fit=crop&fm=webp&q=60")

      assert resp.status == 200
      assert content_type(resp) == "image/webp"
      assert size(decode(resp.resp_body)) == {200, 200}
    end

    test "auto=format serves WebP or AVIF to a browser that accepts it", %{conn: conn} do
      result = upload(conn)

      resp =
        get_image(result["originalUrl"] <> "?w=100&auto=format", [
          {"accept", "image/avif,image/webp,*/*"}
        ])

      assert resp.status == 200
      assert content_type(resp) in ["image/avif", "image/webp"]

      plain = get_image(result["originalUrl"] <> "?w=100&auto=format", [{"accept", "*/*"}])
      assert content_type(plain) == "image/jpeg"
    end

    test "rect cuts a pixel area before resizing", %{conn: conn} do
      result = upload(conn)
      resp = get_image(result["originalUrl"] <> "?rect=300,0,300,200&w=150")

      assert resp.status == 200
      image = decode(resp.resp_body)
      assert size(image) == {150, 100}
      {r, _g, b} = centre_rgb(image)
      assert b > 200 and r < 60, "rect from the blue half should be blue"
    end

    test "fp-x/fp-y moves the crop; the stored focal point applies when the URL has none",
         %{conn: conn} do
      result = upload(conn)
      base = result["originalUrl"] <> "?w=100&h=100&fit=crop"

      {r, _, b} = get_image(base <> "&fp-x=0.05&fp-y=0.5").resp_body |> decode() |> centre_rgb()
      assert r > 200 and b < 60, "a focal point on the left should crop the red half"

      {r, _, b} = get_image(base <> "&fp-x=0.95&fp-y=0.5").resp_body |> decode() |> centre_rgb()
      assert b > 200 and r < 60, "a focal point on the right should crop the blue half"

      {:ok, file} = Media.get_file(result["id"])

      {:ok, _} =
        Media.patch_asset_metadata(
          file,
          %{"focalPoint" => %{"x" => "0.95", "y" => "0.5"}},
          "production"
        )

      {r, _, b} = get_image(base).resp_body |> decode() |> centre_rgb()
      assert b > 200 and r < 60, "the stored focal point (right) should apply"
    end

    test "concurrent first requests render the transform once", %{conn: conn} do
      result = upload(conn)
      prev = Application.get_env(:barkpark, CountingBackend)
      Application.put_env(:barkpark, CountingBackend, :counters.new(1, []))

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:barkpark, CountingBackend)
          val -> Application.put_env(:barkpark, CountingBackend, val)
        end
      end)

      swap_backend(CountingBackend)

      url = result["originalUrl"] <> "?w=240&h=240&fit=crop"

      bodies =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> get_image(url) end) end)
        |> Enum.map(&Task.await(&1, 30_000))
        |> Enum.map(fn resp ->
          assert resp.status == 200
          resp.resp_body
        end)

      assert bodies |> Enum.uniq() |> length() == 1
      assert CountingBackend.count() == 1
      assert length(transform_files(result["id"])) == 1
    end

    test "an invalid value is a 400 naming the parameter", %{conn: conn} do
      result = upload(conn)
      resp = get_image(result["originalUrl"] <> "?w=wide")

      assert resp.status == 400
      body = json_response(resp, 400)
      assert body["error"]["code"] == "invalid_transform_param"
      assert body["error"]["details"]["param"] == "w"
    end

    test "past the per-asset variant cap a new size is refused; cached ones still serve",
         %{conn: conn} do
      original = Application.get_env(:barkpark, Transform, [])
      Application.put_env(:barkpark, Transform, Keyword.put(original, :max_variants_per_asset, 2))
      on_exit(fn -> Application.put_env(:barkpark, Transform, original) end)

      result = upload(conn)
      assert get_image(result["originalUrl"] <> "?w=10").status == 200
      assert get_image(result["originalUrl"] <> "?w=20").status == 200

      refused = get_image(result["originalUrl"] <> "?w=30")
      assert refused.status == 429
      assert json_response(refused, 429)["error"]["code"] == "transform_variant_limit"

      assert get_image(result["originalUrl"] <> "?w=10").status == 200
    end
  end

  describe "named presets" do
    test "existing rendition URLs are built lazily on first request", %{conn: conn} do
      result = upload(conn)
      refute File.exists?(renditions_dir(result["id"]))

      thumb = get_image(result["renditions"]["thumb"])
      assert thumb.status == 200
      assert content_type(thumb) == "image/jpeg"
      assert size(decode(thumb.resp_body)) == {320, 213}

      hero = get_image(result["renditions"]["hero"])
      assert hero.status == 200
      assert content_type(hero) == "image/webp"

      og = get_image(result["renditions"]["og"])
      assert size(decode(og.resp_body)) == {1200, 630}

      assert File.exists?(Path.join(renditions_dir(result["id"]), "thumb.jpg"))
    end
  end
end
