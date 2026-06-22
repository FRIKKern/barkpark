defmodule Barkpark.Media.Storage.SignedUrlTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.Storage.SignedUrl

  test "sign and verify round-trip" do
    path = "/media/files/2026/05/sample.png"
    file_id = Ecto.UUID.generate()
    signed = SignedUrl.sign(path, file_id, ttl: 3600)

    assert signed =~ "_="
    assert signed =~ "exp="

    params =
      signed
      |> URI.parse()
      |> Map.get(:query)
      |> Plug.Conn.Query.decode()

    assert SignedUrl.verify?(file_id, path, params)
  end

  test "rejects expired signature" do
    path = "/media/renditions/#{Ecto.UUID.generate()}/thumb"
    file_id = Ecto.UUID.generate()
    signed = SignedUrl.sign(path, file_id, ttl: -10)

    params =
      signed
      |> URI.parse()
      |> Map.get(:query)
      |> Plug.Conn.Query.decode()

    refute SignedUrl.verify?(file_id, path, params)
  end

  test "rejects tampered path" do
    path = "/media/files/2026/05/sample.png"
    file_id = Ecto.UUID.generate()
    signed = SignedUrl.sign(path, file_id)

    params =
      signed
      |> URI.parse()
      |> Map.get(:query)
      |> Plug.Conn.Query.decode()

    refute SignedUrl.verify?(file_id, "/media/files/other.png", params)
  end
end
