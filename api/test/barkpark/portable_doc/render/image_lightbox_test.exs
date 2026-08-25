defmodule Barkpark.PortableDoc.Render.ImageLightboxTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @image %{
    "id" => "evidence-image",
    "type" => "image",
    "src" => "https://img.test/before-after.png?x=1&y=2",
    "alt" => "Before & \"after\"",
    "width" => 1440,
    "height" => 900
  }

  test "article images carry the reader lightbox hook without losing image data" do
    html = Render.render_block(@image, %{style: :article})

    assert html ==
             ~s(<img src="https://img.test/before-after.png?x=1&amp;y=2" alt="Before &amp; &quot;after&quot;" data-bp-lightboxable="true" style="max-width:100%;height:auto" width="1440" height="900">)
  end

  test "default and email rendering remain bare and byte-identical" do
    expected =
      ~s(<img src="https://img.test/before-after.png?x=1&amp;y=2" alt="Before &amp; &quot;after&quot;" style="max-width:100%;height:auto" width="1440" height="900">)

    assert Render.render_block(@image) == expected
    assert Render.render_block(@image, %{style: :email}) == expected
    refute expected =~ "data-bp-lightboxable"
  end
end
