defmodule BarkparkWeb.StudioComponents.HistoryModalWordingTest do
  @moduledoc """
  Document history names each action in words and each Restore button names
  the version it restores (task-880a2d3f48ccbfcb). It showed the stored code
  ("discardDraft", uppercased to DISCARDDRAFT by the badge style), and every
  row's button was named just "Restore".
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.Modals

  defp rev(id, action, at) do
    %{id: id, action: action, title: "Fjellet", inserted_at: at}
  end

  test "actions read as words and each Restore names its version" do
    html =
      render_component(&Modals.history_modal/1, %{
        show_history: true,
        revisions: [
          rev("r1", "discardDraft", ~U[2026-10-06 03:48:59Z]),
          rev("r2", "update", ~U[2026-10-06 07:25:45Z]),
          rev("r3", "publish", ~U[2026-10-06 02:51:56Z])
        ]
      })

    assert html =~ "Draft discarded"
    refute html =~ ">discardDraft<"
    assert html =~ "Edited"
    assert html =~ "Published"

    # The server names the clock (UTC); Hooks.LocalTime swaps in the viewer's
    # own from data-local-label (task-7a12da688a06f880).
    assert html =~
             ~s|aria-label="Restore the version from Oct 06, 2026 at 07:25:45 UTC (Edited)"|

    assert html =~ ~s|data-local-label="Restore the version from {time} (Edited)"|

    assert html =~
             ~s|aria-label="Restore the version from Oct 06, 2026 at 03:48:59 UTC (Draft discarded)"|
  end

  test "an action with no label falls back to its code" do
    html =
      render_component(&Modals.history_modal/1, %{
        show_history: true,
        revisions: [rev("r1", "compactSnapshot", ~U[2026-10-06 03:48:59Z])]
      })

    assert html =~ "compactSnapshot"
  end
end
