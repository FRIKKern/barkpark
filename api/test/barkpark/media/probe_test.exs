defmodule Barkpark.Media.ProbeTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.Probe

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  test "reads PNG dimensions from IHDR" do
    path = write_temp!(Base.decode64!(@png_b64), "probe.png")

    assert {:ok, %{width: 1, height: 1, exif: %{}}} = Probe.probe(path, "image/png")
  end

  test "returns unsupported for non-image bytes" do
    path = write_temp!("hello", "probe.txt")
    assert {:error, :unsupported} = Probe.probe(path, "text/plain")
  end

  defp write_temp!(bytes, name) do
    path = Path.join(System.tmp_dir!(), "probe-#{:rand.uniform(999_999)}-#{name}")
    File.write!(path, bytes)
    path
  end
end
