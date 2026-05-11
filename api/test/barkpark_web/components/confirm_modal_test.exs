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
end
