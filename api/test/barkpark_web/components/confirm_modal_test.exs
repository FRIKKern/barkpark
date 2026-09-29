defmodule BarkparkWeb.Components.ConfirmModalTest do
  @moduledoc """
  Smoke coverage for `BarkparkWeb.Components.ConfirmModal` (Task #16 —
  schema action registry). Pins the visual contract — backdrop dialog,
  title heading, two-stage button row — so later visual edits don't
  silently regress the modal.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.ConfirmModal

  describe "confirm_modal/1 — initial stage" do
    test "renders title, body, cancel + confirm buttons" do
      html =
        render_component(&ConfirmModal.confirm_modal/1, %{
          id: "m1",
          title: "Publish to Bokbasen?",
          body: "Dry-run first, then ask again.",
          on_cancel: "close-confirm-modal",
          on_confirm: "confirm-modal-dryrun"
        })

      assert html =~ ~s(data-test-id="confirm-modal")
      assert html =~ ~s(id="m1")
      assert html =~ ~s(role="dialog")
      assert html =~ "Publish to Bokbasen?"
      assert html =~ "Dry-run first, then ask again."
      assert html =~ ~s(phx-click="close-confirm-modal")
      assert html =~ ~s(phx-click="confirm-modal-dryrun")
      assert html =~ ~s(data-test-id="confirm-modal-cancel")
      assert html =~ ~s(data-test-id="confirm-modal-confirm")
    end

    test "does not render the 'real' button on initial stage" do
      html =
        render_component(&ConfirmModal.confirm_modal/1, %{
          id: "m1",
          title: "Title",
          on_cancel: "cancel",
          on_confirm: "confirm",
          on_real: "real-event"
        })

      refute html =~ ~s(data-test-id="confirm-modal-real")
    end

    test "omits body paragraph when body is nil" do
      html =
        render_component(&ConfirmModal.confirm_modal/1, %{
          id: "m1",
          title: "Just a title",
          on_cancel: "cancel",
          on_confirm: "confirm"
        })

      # Title appears in <h2>; no <p> body block should render
      assert html =~ "Just a title"
      refute html =~ ~s(<p class="text-sm text-muted")
    end
  end

  describe "confirm_modal/1 — dryrun stage" do
    test "renders the 'real' button when on_real is set and stage=dryrun" do
      html =
        render_component(&ConfirmModal.confirm_modal/1, %{
          id: "m1",
          title: "Title",
          stage: "dryrun",
          on_cancel: "cancel",
          on_confirm: "confirm",
          on_real: "real-event"
        })

      assert html =~ ~s(data-test-id="confirm-modal-real")
      assert html =~ ~s(phx-click="real-event")
    end

    test "still hides 'real' button when on_real is nil even at dryrun stage" do
      html =
        render_component(&ConfirmModal.confirm_modal/1, %{
          id: "m1",
          title: "Title",
          stage: "dryrun",
          on_cancel: "cancel",
          on_confirm: "confirm"
        })

      refute html =~ ~s(data-test-id="confirm-modal-real")
    end
  end

  describe "the scrim is a stylesheet rule, not an inline style (spd-w5f)" do
    # The rendered markup is the honest subject here: `root.html.heex` can hold
    # a perfect `.bp-modal-overlay` rule while the component still ALSO emits
    # its own `style="position: fixed; …; background: rgba(0,0,0,0.4)"`, and the
    # inline one wins the cascade. Only the emitted HTML says which is live.
    setup do
      %{
        html:
          render_component(&ConfirmModal.confirm_modal/1, %{
            id: "m1",
            title: "Title",
            body: "Body",
            on_cancel: "cancel",
            on_confirm: "confirm"
          })
      }
    end

    test "the overlay carries the class and no inline position/background", %{html: html} do
      assert html =~ ~s(class="bp-modal-overlay"),
             "the scrim lost the class its root.html.heex rule is keyed on"

      refute html =~ "position:",
             "confirm_modal emits an inline `position:` again — that is invisible " <>
               "to the root stylesheet and re-grows @inline_fixed_inventory in " <>
               "test/barkpark_web/studio/editor_panel_containment_test.exs"

      refute html =~ "background:",
             "confirm_modal emits an inline `background:` again — a colour " <>
               "declaration here is not scanned by scripts/studio-literal-check.sh"
    end

    test "no raw colour literal survives anywhere in the markup", %{html: html} do
      for literal <- ["rgba(", "rgb(", "#0", "#f"] do
        refute String.contains?(html, literal),
               "confirm_modal emits the raw colour literal #{inspect(literal)}; the " <>
                 "sanctioned form is a token, e.g. hsl(var(--bp-scrim-hsl) / 0.45)"
      end
    end

    test "z-index 1000 is gone — the scrim uses the Studio tier system", %{html: html} do
      refute html =~ "z-index",
             "the overlay declares its own z-index; the tiers (50/51/60) live in " <>
               "root.html.heex so they can be compared against each other"
    end
  end
end
