defmodule BarkparkWeb.Gettext.DeadMsgidsTest do
  @moduledoc """
  task-c1ffb567fb4ae1cd: twelve msgids outlived their callers (the legacy
  picker modal, #28174; the desk's refs row, #26135; the pane's bare "Sort by",
  #25653), so `mix gettext.extract --merge` removed them on every run. They
  are gone from the template and both catalogues.
  """
  use ExUnit.Case, async: true

  @files ~w(
    priv/gettext/default.pot
    priv/gettext/en/LC_MESSAGES/default.po
    priv/gettext/nb_NO/LC_MESSAGES/default.po
  )

  @dead [
    "Image upload failed. Please try again with a supported file.",
    "No documents found",
    "No images yet. Upload one above.",
    "References",
    "Search...",
    "Select Image",
    "Select reference",
    "Sort by",
    "That file type isn't supported — use a JPG, PNG, GIF, WEBP, or SVG.",
    "That image couldn't be uploaded.",
    "That image is too large — the limit is 10 MB.",
    "You can only upload one image at a time."
  ]

  test "none of the twelve dead msgids is left in the .pot or either .po" do
    for file <- @files do
      text = File.read!(Path.join(File.cwd!(), file))
      left = Enum.filter(@dead, &String.contains?(text, ~s(msgid "#{&1}"\n)))
      assert left == [], "#{file} still holds #{inspect(left)}"
    end
  end
end
