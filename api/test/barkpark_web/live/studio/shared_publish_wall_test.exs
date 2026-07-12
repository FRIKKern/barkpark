defmodule BarkparkWeb.Studio.StudioLive.SharedPublishWallTest do
  @moduledoc """
  Studio surfacing of the publish wall (authoring-excellence D14): a
  label-spine rejection must render its documentation-grade field/rule/fix
  detail in the flash — NEVER degrade to the content-free "Action failed".

  `do_action/3` is exercised directly with a minimal LiveView socket (it is
  the single seam every editor action — publish included — funnels through),
  so the assertion pins the exact flash the author reads.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared

  @details %{
    field: "tags",
    rule: "A published document requires a `tags` array.",
    fix: "Add 1–12 weighted tags: [{tag, strength, rationale}]."
  }

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        editor_doc: %{doc_id: "p1"},
        editor_type: "paper"
      }
    }
  end

  test "a label_spine rejection renders field — rule — fix, not 'Action failed'" do
    {:noreply, socket} =
      Shared.do_action(
        socket(),
        fn _doc, _type -> {:error, {:label_spine, @details}} end,
        "Published"
      )

    flash = Phoenix.Flash.get(socket.assigns.flash, :error)

    assert flash =~ "Publish blocked"
    assert flash =~ @details.field
    assert flash =~ @details.rule
    assert flash =~ @details.fix
    refute flash == "Action failed"
  end

  test "a non-wall error still falls through to the generic failure flash" do
    {:noreply, socket} =
      Shared.do_action(socket(), fn _doc, _type -> {:error, :boom} end, "Published")

    assert Phoenix.Flash.get(socket.assigns.flash, :error) == "Action failed"
  end

  describe "format_wall_details/1" do
    test "renders a single field/rule/fix map as one documentation line" do
      assert Shared.format_wall_details(@details) ==
               Enum.join([@details.field, @details.rule, @details.fix], " — ")
    end

    test "renders a LIST of violations joined for the flash" do
      line = Shared.format_wall_details([@details, %{field: "description", rule: "r", fix: "f"}])
      assert line =~ @details.rule
      assert line =~ " · "
      assert line =~ "description — r — f"
    end

    test "an unknown detail shape degrades LOUDLY (inspected), never silently" do
      assert Shared.format_wall_details(:weird) == inspect(:weird)
      assert Shared.format_wall_details(%{other: "shape"}) == inspect(%{other: "shape"})
    end
  end
end
