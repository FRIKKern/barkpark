defmodule BarkparkWeb.Studio.ShareDialogFooterLayoutTest do
  @moduledoc """
  task-27f26cb43a3c59c7: the item share dialog's footer (the edit-link note and
  the two create-link buttons) was a nowrap flex row, so at phone width the
  primary "Create edit link" ran past the dialog behind an inner scrollbar and
  the note was squeezed to one word per line. The row wraps and the note can
  take its own line. Reads the shipped stylesheet; the layout is checked in a
  browser.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  test "the share footer wraps and its note yields a row of its own" do
    css = File.read!(@root)

    [_, footer] = Regex.run(~r/\.item-share-footer \{([^}]*)\}/, css)
    assert footer =~ "flex-wrap: wrap"

    [_, note] = Regex.run(~r/\.item-share-footer > \.shares-note \{([^}]*)\}/, css)
    assert note =~ "flex: 1 1 12rem"
    assert note =~ "min-width: 0"

    # The two buttons wrap as ONE group, so the primary action is never
    # orphaned on a row of its own beside the note.
    [_, actions] = Regex.run(~r/\.item-share-actions \{([^}]*)\}/, css)
    assert actions =~ "display: flex"
    assert actions =~ "margin-left: auto"
  end

  test "both create-link buttons sit inside the one actions group" do
    src =
      File.read!(
        Path.expand(
          "../../../../lib/barkpark_web/components/studio_components/modals.ex",
          __DIR__
        )
      )

    [_, group] = Regex.run(~r/<div class="item-share-actions">(.*?)\n              <\/div>/s, src)
    assert group =~ ~s(phx-value-access="read")
    assert group =~ ~s(phx-value-access="edit")
  end
end
