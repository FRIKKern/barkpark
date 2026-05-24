defmodule Barkpark.Media.CdnTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media
  alias Barkpark.Media.Cdn
  alias Barkpark.Media.MediaFile

  setup do
    original = Application.get_env(:barkpark, :media_cdn)
    on_exit(fn -> Application.put_env(:barkpark, :media_cdn, original) end)
    :ok
  end

  test "public_url leaves relative paths unchanged without CDN base" do
    assert Cdn.public_url("/media/files/2026/05/a.png") == "/media/files/2026/05/a.png"
  end

  test "public_url prefixes configured CDN base" do
    Application.put_env(:barkpark, :media_cdn, base_url: "https://cdn.example.com")

    assert Cdn.public_url("/media/files/a.png") == "https://cdn.example.com/media/files/a.png"
  end

  test "invalidation_paths includes original and renditions for images" do
    file = %MediaFile{
      id: Ecto.UUID.generate(),
      path: "2026/05/pixel.png",
      mime_type: "image/png"
    }

    paths = Cdn.invalidation_paths(file)
    assert "/media/files/2026/05/pixel.png" in paths
    assert Enum.any?(paths, &String.starts_with?(&1, "/media/renditions/"))
  end

  test "invalidate_paths posts to HTTP adapter" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/purge", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["paths"] == ["/media/files/x.png"]
      Plug.Conn.resp(conn, 204, "")
    end)

    Application.put_env(:barkpark, :media_cdn,
      invalidation: [adapter: :http, url: "http://127.0.0.1:#{bypass.port}/purge", secret: "s"]
    )

    assert :ok = Cdn.invalidate_paths(["/media/files/x.png"])
  end
end
