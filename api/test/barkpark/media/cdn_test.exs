defmodule Barkpark.Media.Delivery.CdnTest do
  # async: false — this module toggles the global :media_cdn Application env, and
  # Cdn reads config straight from Application.get_env (no test-scoped injection
  # path), so concurrent tests reading :media_cdn would race. Correctness over a
  # tiny parallelism gain.
  use ExUnit.Case, async: false

  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Media.MediaFile

  setup do
    original = Application.get_env(:barkpark, :media_cdn)

    # When the key was never set, restore by DELETING it — put_env(..., nil)
    # leaves a literal nil that crashes Cdn.base_url/0's Keyword.get in any
    # later test (Application.get_env(:barkpark, :media_cdn, []) returns the
    # stored nil, not the default).
    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :media_cdn)
        val -> Application.put_env(:barkpark, :media_cdn, val)
      end
    end)

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
    test_pid = self()

    # Capture the request into the test process instead of asserting inside the
    # Bypass handler. An assertion failure here would raise in the Cowboy/Bypass
    # process (not the test process), surfacing as a connection error or on-exit
    # verification failure that races the test's :ok return rather than a clean
    # assertion. We forward method/path/body and assert in the test process.
    Bypass.expect_once(bypass, "POST", "/purge", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:cdn_request, conn.method, conn.request_path, body})
      Plug.Conn.resp(conn, 204, "")
    end)

    Application.put_env(:barkpark, :media_cdn,
      invalidation: [adapter: :http, url: "http://127.0.0.1:#{bypass.port}/purge", secret: "s"]
    )

    assert :ok = Cdn.invalidate_paths(["/media/files/x.png"])

    assert_receive {:cdn_request, "POST", "/purge", body}
    assert Jason.decode!(body)["paths"] == ["/media/files/x.png"]
  end
end
