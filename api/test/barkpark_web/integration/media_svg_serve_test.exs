defmodule BarkparkWeb.Integration.MediaSvgServeTest do
  @moduledoc """
  SVG on the media serve routes (task-3047d0a672092b0e).

  Measured on gyl against cdn.sanity.io with a browser Accept header, for a
  Sanity-imported SVG logo:

    * `?auto=format`: Sanity 200 `image/svg+xml`, Barkpark 400 not_transformable.
    * `?w=100`: Sanity 200 `image/svg+xml`, Barkpark 400.
    * no parameters: Sanity 200 `image/svg+xml`, Barkpark 200
      `application/octet-stream; charset=utf-8`, which an `<img>` does not render.

  `@sanity/image-url` adds `auto=format` and `w` to every SVG URL it builds.
  An SVG now answers size, crop and `auto=format` parameters with the stored
  SVG, typed `image/svg+xml` with no charset, and carries a CSP that blocks
  script plus `nosniff`, on the Sanity image route and on `/media/files`.

  Binary types lose the `; charset=utf-8` Plug appends by default
  (task-701191424b8d15e8).
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media}
  alias Barkpark.Plugins.Media.Assets

  @project_id "zl2pw2j0"
  @svg ~s|<svg xmlns="http://www.w3.org/2000/svg" width="132" height="39"><script>alert(document.domain)</script><rect width="132" height="39" fill="#c00"/></svg>|

  # What a browser sends for an <img>.
  @img_accept "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    raw = "svg-serve-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "svg-serve", "production", ["read", "write"], ws.id)

    ctx = %{raw: raw, base: "/w/#{ws.slug}/p/#{proj.slug}"}
    sha1 = sha1_for(System.unique_integer([:positive]))

    svg =
      upload(ctx, "logo.svg", @svg, "image/svg+xml", %{
        "sourceId" => "image-#{sha1}-132x39-svg"
      })

    Map.merge(ctx, %{sha1: sha1, svg: svg})
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("accept", @img_accept)
  end

  defp sha1_for(n), do: :crypto.hash(:sha, "svg-#{n}") |> Base.encode16(case: :lower)

  defp upload(ctx, filename, bytes, content_type, extra) do
    path = Path.join(System.tmp_dir!(), "svg-#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    file = %Plug.Upload{path: path, filename: filename, content_type: content_type}

    resp =
      as(ctx.raw)
      |> put_req_header("accept", "application/json")
      |> post("#{ctx.base}/v1/media/production/upload", Map.put(extra, "file", file))

    assert resp.status in [200, 201], resp.resp_body
    result = json_response(resp, resp.status)["result"]

    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), result["path"]))
      Media.Renditions.delete_for_file(result["id"])
      Assets.delete_for_blob(result["id"], "production")
    end)

    result
  end

  def sanity_url(ctx, query),
    do: "#{ctx.base}/images/#{@project_id}/production/#{ctx.sha1}-132x39.svg#{query}"

  def files_url(ctx, query), do: "#{ctx.base}/media/files/#{ctx.svg["path"]}#{query}"

  defp assert_svg_original(resp) do
    assert resp.status == 200, resp.resp_body
    assert get_resp_header(resp, "content-type") == ["image/svg+xml"]
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(resp, "content-disposition") == ["inline"]
    assert [csp] = get_resp_header(resp, "content-security-policy")
    assert csp =~ "script-src 'none'"
    assert csp =~ "sandbox"
    assert resp.resp_body == @svg
  end

  # The three measured cases, plus the crop and size parameters
  # `@sanity/image-url` emits for a hotspot or a fixed box.
  @queries [
    {"no parameters", ""},
    {"auto=format", "?auto=format"},
    {"w=100", "?w=100"},
    {"w and auto=format together", "?w=100&auto=format"},
    {"rect, h and fit=crop", "?rect=0,0,66,39&w=50&h=20&fit=crop"}
  ]

  for {label, query} <- @queries do
    test "Sanity image route, #{label}: the SVG unchanged as image/svg+xml", ctx do
      ctx |> sanity_url(unquote(query)) |> then(&get(as(ctx.raw), &1)) |> assert_svg_original()
    end

    test "/media/files, #{label}: the SVG unchanged as image/svg+xml", ctx do
      ctx |> files_url(unquote(query)) |> then(&get(as(ctx.raw), &1)) |> assert_svg_original()
    end
  end

  # task-71cb73cb5f89acef — defence in depth: opened as a page, an SVG is also
  # a download; an <img> (or a client that sends no Sec-Fetch-Dest) keeps it
  # inline. Both answers keep the sandbox CSP and nosniff, and vary on the header.
  for {route, url_fun} <- [{"Sanity image route", :sanity_url}, {"/media/files", :files_url}] do
    test "#{route}: opened as a page the SVG is an attachment, as an image inline", ctx do
      url = apply(__MODULE__, unquote(url_fun), [ctx, ""])

      for {dest, disposition} <- [
            {"document", "attachment"},
            {"image", "inline"},
            {nil, "inline"}
          ] do
        conn = as(ctx.raw)
        conn = if dest, do: put_req_header(conn, "sec-fetch-dest", dest), else: conn
        resp = get(conn, url)

        assert resp.status == 200, "#{inspect(dest)}: #{resp.resp_body}"
        assert get_resp_header(resp, "content-disposition") == [disposition], inspect(dest)
        assert get_resp_header(resp, "content-type") == ["image/svg+xml"]
        assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
        assert [csp] = get_resp_header(resp, "content-security-policy")
        assert csp =~ "default-src 'none'" and csp =~ "sandbox"
        assert [vary] = get_resp_header(resp, "vary")
        assert vary =~ "Sec-Fetch-Dest"
        assert resp.resp_body == @svg
      end
    end
  end

  test "an explicit fm still asks for a raster and is refused", ctx do
    for url <- [sanity_url(ctx, "?fm=png"), files_url(ctx, "?w=100&fm=webp")] do
      resp = get(as(ctx.raw), url)
      assert resp.status == 400, resp.resp_body
      assert json_response(resp, 400)["error"]["code"] == "not_transformable"
    end
  end

  test "an invalid transform value on an SVG is still a 400", ctx do
    resp = get(as(ctx.raw), sanity_url(ctx, "?w=abc"))
    assert resp.status == 400
    assert json_response(resp, 400)["error"]["code"] == "invalid_transform_param"
  end

  test "another workspace's token cannot read the SVG through either route", ctx do
    other = create_workspace!()
    raw = "svg-serve-other-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "other", "production", ["read"], other.id)

    for url <- [sanity_url(ctx, "?auto=format"), files_url(ctx, "?w=100")] do
      assert get(as(raw), url).status in [403, 404]
    end
  end

  describe "binary content types carry no charset (task-701191424b8d15e8)" do
    test "a PNG original and its transform", ctx do
      {:ok, image} = Image.new(40, 20, color: [0, 128, 255])

      png_path =
        Path.join(System.tmp_dir!(), "svg-test-#{System.unique_integer([:positive])}.png")

      {:ok, _} = Image.write(image, png_path)
      on_exit(fn -> File.rm(png_path) end)

      png = upload(ctx, "dot.png", File.read!(png_path), "image/png", %{})
      url = "#{ctx.base}/media/files/#{png["path"]}"

      original = get(as(ctx.raw), url)
      assert original.status == 200
      assert get_resp_header(original, "content-type") == ["image/png"]

      resized = get(as(ctx.raw), url <> "?w=20&fm=png")
      assert resized.status == 200, resized.resp_body
      assert get_resp_header(resized, "content-type") == ["image/png"]

      auto = get(as(ctx.raw), url <> "?w=20&auto=format")
      assert auto.status == 200, auto.resp_body
      assert [type] = get_resp_header(auto, "content-type")
      assert type in ["image/avif", "image/webp"]
    end
  end
end
