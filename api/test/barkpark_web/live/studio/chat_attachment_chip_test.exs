defmodule BarkparkWeb.Studio.ChatAttachmentChipTest do
  @moduledoc """
  The Studio file chip's name and size (review of #26299, carried on
  task-1a110556c4cdb791). The name is isolated with `<bdi>`, so a name in a
  right-to-left script cannot reorder the size beside it, and the size label
  never says "1000.0 KB" and uses the locale's decimal mark.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.ChatAttachmentChip

  test "the size label moves to MB before it would round up to 1000.0 KB" do
    Gettext.with_locale(BarkparkWeb.Gettext, "en", fn ->
      assert ChatAttachmentChip.size_label(999) == "999 B"
      assert ChatAttachmentChip.size_label(1000) == "1.0 KB"
      assert ChatAttachmentChip.size_label(999_949) == "999.9 KB"
      assert ChatAttachmentChip.size_label(999_950) == "1.0 MB"
      assert ChatAttachmentChip.size_label(999_999) == "1.0 MB"
      assert ChatAttachmentChip.size_label(3_000_000) == "3.0 MB"
    end)
  end

  test "the size label uses a decimal comma in Norwegian" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert ChatAttachmentChip.size_label(12_345) == "12,3 KB"
      assert ChatAttachmentChip.size_label(2_900_000) == "2,9 MB"
      assert ChatAttachmentChip.size_label(512) == "512 B"
    end)
  end

  test "the name is isolated in a bdi element, and a missing name shows File" do
    hebrew = "קובץ.csv"
    html = render_component(&ChatAttachmentChip.chip/1, file: %{name: hebrew, byte_size: 12})
    assert html =~ "<bdi>#{hebrew}</bdi>"

    html = render_component(&ChatAttachmentChip.chip/1, file: %{name: nil, byte_size: 12})
    assert html =~ "<bdi>File</bdi>"
  end
end
